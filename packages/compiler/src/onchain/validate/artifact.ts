import { validateDockCommitments, validateUnresolvedDockRouteDeclarations } from "../../dock-validation.js";
import { planIdOf } from "../../dock-commitments.js";
import { hashOnchainPlanPayload } from "../hash/plan.js";
import { capabilitiesRootOf } from "../capabilities-root.js";
import {
  canonicalOrderIssues,
  admissionOrderKey,
  executorCandidateOrderKey,
  hookOrderKey,
  routeOrderKey,
  selectorBindingOrderKey,
  signalCapabilityOrderKey,
} from "../canonical/ordering.js";
import {
  executorCandidatesRootOf,
  isExecutorAddress,
} from "../executor-candidates.js";
import {
  expectClosedKeySet,
  expectHexHash,
  expectLiteral,
  expectNonEmptyString,
  isHexHash,
  isRecord,
} from "../shape.js";
import {
  duplicateCurrentOrderFactKeyIssues,
  validateOnchainExecutorRoutes,
  validateOnchainSelectorBindings,
  validateOnchainSignalCapabilities,
} from "./capabilities.js";
import {
  birthStageStaticExecutorIssues,
  declaredStageIdentifiers,
  duplicateBirthChannelKeyIssues,
  silentOrderTriggerIssues,
  unmaterializableStageIssues,
  validateOnchainCompiledAdmissions,
  validateOnchainCompiledHooks,
  validateOnchainDependencyIndex,
} from "./hooks.js";
import {
  planDependencyCountIssues,
} from "./limits.js";
import {
  ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
  type HexString,
  type OnchainCompiledHook,
  type OnchainHookPlanArtifact,
  type ZhixuPlatform,
} from "../../types/index.js";

/**
 * OnchainHookPlanArtifact 反序列化边界校验：封闭字段集、逐段形状/承诺
 * 校验编排与 planHash 重算；dock 承诺复用根 dock-validation.ts。
 */

export class OnchainHookPlanArtifactValidationError extends Error {
  readonly issues: readonly string[];

  constructor(issues: readonly string[]) {
    super(issues.join("; "));
    this.name = "OnchainHookPlanArtifactValidationError";
    this.issues = issues;
  }
}

const ONCHAIN_ARTIFACT_FIELDS: readonly string[] = [
  "schemaVersion",
  "planId",
  "zhixuId",
  "zhixuName",
  "platform",
  "sourcePlanHash",
  "compiledHooks",
  "dependencyIndex",
  "executorRoutes",
  "dockInterface",
  "dockRoutes",
  "unresolvedDockRoutes",
  "dockRoutesRoot",
  "dockInterfaceRoot",
  "capabilitiesRoot",
  "selectorBindings",
  "signalCapabilities",
  "admissions",
  "executorCandidates",
  "executorCandidatesRoot",
  "planHash",
];

export function validateOnchainHookPlanArtifact(
  value: unknown,
): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value)) {
    return ["artifact must be an object"];
  }

  for (const key of Object.keys(value)) {
    if (!ONCHAIN_ARTIFACT_FIELDS.includes(key)) {
      issues.push(
        `unknown field \`${key}\` on the artifact — planHash does not cover undeclared fields, so the artifact would not be the plan's unique byte form; remove it or recompile`,
      );
    }
  }

  expectLiteral(
    value.schemaVersion,
    ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    "schemaVersion",
    issues,
  );
  expectHexHash(value.planId, "planId", issues);
  expectNonEmptyString(value.zhixuId, "zhixuId", issues);
  expectNonEmptyString(value.zhixuName, "zhixuName", issues);
  if (!isPlatform(value.platform)) {
    issues.push("platform must be an object with a non-empty type");
  }
  expectHexHash(value.sourcePlanHash, "sourcePlanHash", issues);
  expectHexHash(value.planHash, "planHash", issues);
  if (
    isPlatform(value.platform) &&
    typeof value.zhixuId === "string" &&
    typeof value.zhixuName === "string"
  ) {
    try {
      const recomputedPlanId = planIdOf(
        value.zhixuId,
        value.zhixuName,
        value.platform,
      );
      if (typeof value.planId === "string" && value.planId !== recomputedPlanId) {
        issues.push(
          "planId must match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName)",
        );
      }
    } catch {
      issues.push(
        "planId preimage is not canonicalizable (platform carries non-JSON values)",
      );
    }
  }
  if (!Array.isArray(value.dockRoutes)) {
    issues.push("dockRoutes must be an array");
  }
  if (
    value.unresolvedDockRoutes !== undefined &&
    !Array.isArray(value.unresolvedDockRoutes)
  ) {
    issues.push("unresolvedDockRoutes must be an array when present");
  }
  expectHexHash(value.dockRoutesRoot, "dockRoutesRoot", issues);
  expectHexHash(value.dockInterfaceRoot, "dockInterfaceRoot", issues);
  expectHexHash(value.capabilitiesRoot, "capabilitiesRoot", issues);
  issues.push(...validateDockCommitments(value));
  issues.push(...capabilitiesRootCommitmentIssues(value));
  if (Array.isArray(value.dockRoutes)) {
    issues.push(...onchainDockTrackIssues(value.dockRoutes));
  }
  if (Array.isArray(value.unresolvedDockRoutes)) {
    issues.push(
      ...validateUnresolvedDockRouteDeclarations(
        value.unresolvedDockRoutes,
        "unresolvedDockRoutes",
      ),
      ...onchainUnresolvedRouteIssues(value.unresolvedDockRoutes),
    );
  }

  const compiledHooks = Array.isArray(value.compiledHooks)
    ? value.compiledHooks
    : undefined;
  if (!compiledHooks) {
    issues.push("compiledHooks must be an array");
  } else if (compiledHooks.length === 0) {
    issues.push("compiledHooks must not be empty (contract reverts EmptyPlan)");
  }

  const dependencyIndex = isHexArrayRecord(value.dependencyIndex)
    ? value.dependencyIndex
    : undefined;
  if (!dependencyIndex) {
    issues.push("dependencyIndex must be a record of 32-byte hex hash arrays");
  }

  const executorRoutes = Array.isArray(value.executorRoutes)
    ? value.executorRoutes
    : undefined;
  if (!executorRoutes) {
    issues.push("executorRoutes must be an array");
  }
  const selectorBindings = Array.isArray(value.selectorBindings)
    ? value.selectorBindings
    : undefined;
  if (!selectorBindings) {
    issues.push("selectorBindings must be an array");
  }
  const signalCapabilities = Array.isArray(value.signalCapabilities)
    ? value.signalCapabilities
    : undefined;
  if (!signalCapabilities) {
    issues.push("signalCapabilities must be an array");
  }
  const admissions = Array.isArray(value.admissions)
    ? value.admissions
    : undefined;
  if (!admissions) {
    issues.push("admissions must be an array");
  }
  const executorCandidates = Array.isArray(value.executorCandidates)
    ? value.executorCandidates
    : undefined;
  if (!executorCandidates) {
    issues.push("executorCandidates must be an array");
  }
  expectHexHash(value.executorCandidatesRoot, "executorCandidatesRoot", issues);

  if (compiledHooks) {
    issues.push(
      ...validateOnchainCompiledHooks(compiledHooks, executorRoutes ?? []),
    );
    issues.push(
      ...canonicalOrderIssues(compiledHooks, hookOrderKey, "compiledHooks"),
    );
    if (dependencyIndex) {
      issues.push(
        ...validateOnchainDependencyIndex(compiledHooks, dependencyIndex),
      );
    }
    issues.push(
      ...unmaterializableStageIssues(
        compiledHooks as readonly OnchainCompiledHook[],
        declaredStageIdentifiers(
          (signalCapabilities ?? []).map((capability) =>
            isRecord(capability) && typeof capability.stageIdentifier === "string"
              ? capability.stageIdentifier
              : undefined,
          ),
          (executorRoutes ?? [])
            .map((route) =>
              isRecord(route) && typeof route.stageIdentifier === "string"
                ? route.stageIdentifier
                : undefined,
            ),
          (Array.isArray(value.dockRoutes) ? value.dockRoutes : []).map(
            (route) =>
              isRecord(route) &&
              isRecord(route.local) &&
              typeof route.local.stageIdentifier === "string"
                ? route.local.stageIdentifier
                : undefined,
          ),
          (selectorBindings ?? []).flatMap((binding) =>
            isRecord(binding)
              ? [
                  typeof binding.selectorStageIdentifier === "string"
                    ? binding.selectorStageIdentifier
                    : undefined,
                  typeof binding.targetStageIdentifier === "string"
                    ? binding.targetStageIdentifier
                    : undefined,
                ]
              : [],
          ),
        ),
      ),
    );
    issues.push(
      ...silentOrderTriggerIssues(compiledHooks as readonly OnchainCompiledHook[]),
    );
    issues.push(
      ...birthStageStaticExecutorIssues(compiledHooks, executorRoutes ?? []),
    );
    issues.push(...duplicateBirthChannelKeyIssues(compiledHooks));
    issues.push(...planDependencyCountIssues(compiledHooks as readonly OnchainCompiledHook[]));
  }

  if (executorRoutes) {
    issues.push(...validateOnchainExecutorRoutes(executorRoutes));
    issues.push(
      ...canonicalOrderIssues(executorRoutes, routeOrderKey, "executorRoutes"),
    );
  }
  if (selectorBindings) {
    issues.push(...validateOnchainSelectorBindings(selectorBindings));
    issues.push(
      ...canonicalOrderIssues(
        selectorBindings,
        selectorBindingOrderKey,
        "selectorBindings",
      ),
    );
  }
  if (signalCapabilities) {
    issues.push(
      ...canonicalOrderIssues(
        signalCapabilities,
        signalCapabilityOrderKey,
        "signalCapabilities",
      ),
    );
    issues.push(...validateOnchainSignalCapabilities(signalCapabilities));
    issues.push(
      ...duplicateCurrentOrderFactKeyIssues(
        (signalCapabilities as readonly unknown[]).flatMap((capability) =>
          isRecord(capability) &&
          typeof capability.stageIdentifier === "string" &&
          typeof capability.targetSourceId === "string" &&
          typeof capability.signalId === "string"
            ? [
                {
                  stage: capability.stageIdentifier,
                  sourceId: capability.targetSourceId,
                  signalId: capability.signalId,
                },
              ]
            : [],
        ),
      ),
    );
  }
  if (admissions) {
    issues.push(...validateOnchainCompiledAdmissions(admissions));
    issues.push(
      ...canonicalOrderIssues(admissions, admissionOrderKey, "admissions"),
    );
  }
  if (executorCandidates) {
    issues.push(
      ...executorCandidateCommitmentIssues(executorCandidates, compiledHooks ?? [], value.executorCandidatesRoot),
    );
    issues.push(
      ...canonicalOrderIssues(
        executorCandidates,
        executorCandidateOrderKey,
        "executorCandidates",
      ),
    );
  }

  if (isPlanHashRecomputable(value)) {
    try {
      const expectedPlanHash = hashOnchainPlanPayload({
        schemaVersion: value.schemaVersion,
        planId: value.planId,
        zhixuId: value.zhixuId,
        zhixuName: value.zhixuName,
        platform: value.platform,
        sourcePlanHash: value.sourcePlanHash,
        compiledHooks: value.compiledHooks,
        dependencyIndex: value.dependencyIndex,
        executorRoutes: value.executorRoutes,
        dockInterface: value.dockInterface,
        dockRoutes: value.dockRoutes,
        ...(Array.isArray(value.unresolvedDockRoutes) &&
        value.unresolvedDockRoutes.length > 0
          ? { unresolvedDockRoutes: value.unresolvedDockRoutes }
          : {}),
        dockRoutesRoot: value.dockRoutesRoot,
        dockInterfaceRoot: value.dockInterfaceRoot,
        capabilitiesRoot: value.capabilitiesRoot,
        selectorBindings: value.selectorBindings,
        signalCapabilities: value.signalCapabilities,
        admissions: value.admissions,
        executorCandidates: value.executorCandidates,
        executorCandidatesRoot: value.executorCandidatesRoot,
      });
      if (value.planHash !== expectedPlanHash) {
        issues.push(
          "planHash must match the canonical on-chain HookPlan payload",
        );
      }
    } catch {
      issues.push(
        "planHash preimage is not canonicalizable (payload carries undefined or non-JSON values)",
      );
    }
  }

  return issues;
}

export function assertOnchainHookPlanArtifact(
  value: unknown,
): asserts value is OnchainHookPlanArtifact {
  const issues = validateOnchainHookPlanArtifact(value);
  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }
}

function onchainDockTrackIssues(routes: readonly unknown[]): readonly string[] {
  const issues: string[] = [];
  for (const [index, route] of routes.entries()) {
    if (!isRecord(route)) {
      continue;
    }
    const stageIdentifier =
      (isRecord(route.local) &&
        typeof route.local.stageIdentifier === "string" &&
        route.local.stageIdentifier) ||
      `dockRoutes[${index}]`;
    if (
      route.orderMode === "new" &&
      (Array.isArray(route.inputBindings) ? route.inputBindings.length : 0) !== 1
    ) {
      issues.push(
        `DOCK_BINDING_COUNT_INVALID: dock route ${stageIdentifier} uses order mode "new" and must declare exactly one input binding (the birth anchor), found ` +
          (Array.isArray(route.inputBindings) ? route.inputBindings.length : 0),
      );
    }
    const target = route.target;
    if (
      !isRecord(target) ||
      typeof target.zhixuUid !== "string" ||
      target.zhixuUid.trim().length === 0
    ) {
      issues.push(
        `dock route ${stageIdentifier} has no statically linked target block; ` +
          "a dynamic (null) route must be carried in unresolvedDockRoutes (its route leaf is already frozen into dockRoutesRoot via the candidate-root target slot), never in dockRoutes",
      );
    }
  }
  return issues;
}

function capabilitiesRootCommitmentIssues(
  value: Record<string, unknown>,
): readonly string[] {
  const selectorBindings = Array.isArray(value.selectorBindings)
    ? value.selectorBindings
    : undefined;
  const signalCapabilities = Array.isArray(value.signalCapabilities)
    ? value.signalCapabilities
    : undefined;
  if (
    !selectorBindings ||
    !signalCapabilities ||
    !isHexHash(value.capabilitiesRoot)
  ) {
    return [];
  }

  const bindings: {
    selectorStageId: HexString;
    targetStageId: HexString;
  }[] = [];
  for (const binding of selectorBindings) {
    if (
      isRecord(binding) &&
      isHexHash(binding.selectorStageId) &&
      isHexHash(binding.targetStageId)
    ) {
      bindings.push({
        selectorStageId: binding.selectorStageId,
        targetStageId: binding.targetStageId,
      });
    } else {
      return [];
    }
  }

  const capabilities: {
    stageId: HexString;
    targetSourceId: HexString;
    signalId: HexString;
    targetOrderRelation: 0 | 1;
  }[] = [];
  for (const capability of signalCapabilities) {
    if (
      isRecord(capability) &&
      isHexHash(capability.stageId) &&
      isHexHash(capability.targetSourceId) &&
      isHexHash(capability.signalId) &&
      capability.targetOrderRelation === "current"
    ) {
      capabilities.push({
        stageId: capability.stageId,
        targetSourceId: capability.targetSourceId,
        signalId: capability.signalId,
        targetOrderRelation: 0,
      });
    } else {
      return [];
    }
  }

  if (value.capabilitiesRoot !== capabilitiesRootOf(bindings, capabilities)) {
    return [
      "capabilitiesRoot must match the recomputed root over selector bindings and signal capabilities",
    ];
  }
  return [];
}

function executorCandidateCommitmentIssues(
  candidates: readonly unknown[],
  compiledHooks: readonly unknown[],
  declaredRoot: unknown,
): readonly string[] {
  const issues: string[] = [];
  const allowedKeys: readonly string[] = ["stageId", "executor", "stageIdentifier"];
  const shaped: { stageId: HexString; executor: HexString; stageIdentifier?: string }[] = [];
  for (const [index, candidate] of candidates.entries()) {
    const prefix = `executorCandidates[${index}]`;
    if (!isRecord(candidate)) {
      issues.push(
        `${prefix} must carry a 32-byte stageId and a non-zero 20-byte executor address`,
      );
      continue;
    }
    expectClosedKeySet(candidate, allowedKeys, prefix, issues);
    if (
      !isHexHash(candidate.stageId) ||
      typeof candidate.executor !== "string" ||
      !isExecutorAddress(candidate.executor)
    ) {
      issues.push(
        `${prefix} must carry a 32-byte stageId and a non-zero 20-byte executor address`,
      );
      continue;
    }
    if (candidate.executor !== candidate.executor.toLowerCase()) {
      issues.push(
        `${prefix}.executor must be the lowercase address form; the compiler never emits a mixed-case executor`,
      );
      continue;
    }
    shaped.push({
      stageId: candidate.stageId,
      executor: candidate.executor,
      ...(typeof candidate.stageIdentifier === "string"
        ? { stageIdentifier: candidate.stageIdentifier }
        : {}),
    });
  }
  if (shaped.length !== candidates.length || !isHexHash(declaredRoot)) {
    return issues;
  }
  if (declaredRoot !== executorCandidatesRootOf(shaped)) {
    issues.push(
      "executorCandidatesRoot must match the recomputed root over the candidate leaves",
    );
  }
  const declaredStageIds = new Set(
    compiledHooks.flatMap((hook) =>
      isRecord(hook) && isHexHash(hook.stageId) ? [hook.stageId] : [],
    ),
  );
  for (const candidate of shaped) {
    const stageLabel =
      candidate.stageIdentifier ??
      candidate.stageId;
    if (declaredStageIds.size > 0 && !declaredStageIds.has(candidate.stageId)) {
      issues.push(
        `executor candidate stage ${stageLabel} is not a stage declared in this plan`,
      );
      continue;
    }
    const birthTrigger = compiledHooks.some(
      (hook) =>
        isRecord(hook) &&
        hook.stageId === candidate.stageId &&
        typeof hook.orderTriggerKind === "string" &&
        hook.orderTriggerKind !== "none",
    );
    if (birthTrigger) {
      issues.push(
        `executor candidate stage ${stageLabel} carries an order-trigger hook; birth-stage executors are immutable and cannot be per-order patch targets`,
      );
    }
  }
  return issues;
}

function onchainUnresolvedRouteIssues(
  routes: readonly unknown[] | undefined,
): readonly string[] {
  if (!Array.isArray(routes)) {
    return [];
  }
  const issues: string[] = [];
  for (const [index, route] of routes.entries()) {
    if (!isRecord(route) || route.orderMode !== "new") {
      continue;
    }
    const stageIdentifier =
      (typeof route.stageIdentifier === "string" && route.stageIdentifier) ||
      `unresolvedDockRoutes[${index}]`;
    issues.push(
      `UNRESOLVED_DOCK_MODE: unresolved dock route ${stageIdentifier} declares order mode "new"; ` +
        "the chain terminal state has no dynamic consumer for new-mode routes — " +
        'openDockedOrder recomputes the static target slot only and attachDockedOrder (the dynamic path) pins order mode "existing"',
    );
  }
  return issues;
}

function isPlanHashRecomputable(
  value: Record<string, unknown>,
): value is Omit<OnchainHookPlanArtifact, "planHash"> & {
  readonly planHash: HexString;
} {
  return (
    value.schemaVersion === ONCHAIN_HOOK_PLAN_SCHEMA_VERSION &&
    isHexHash(value.planId) &&
    typeof value.zhixuId === "string" &&
    typeof value.zhixuName === "string" &&
    isPlatform(value.platform) &&
    isHexHash(value.sourcePlanHash) &&
    Array.isArray(value.compiledHooks) &&
    isHexArrayRecord(value.dependencyIndex) &&
    Array.isArray(value.executorRoutes) &&
    Array.isArray(value.selectorBindings) &&
    Array.isArray(value.signalCapabilities) &&
    Array.isArray(value.admissions) &&
    Array.isArray(value.executorCandidates) &&
    isHexHash(value.executorCandidatesRoot) &&
    Array.isArray(value.dockRoutes) &&
    (value.unresolvedDockRoutes === undefined ||
      Array.isArray(value.unresolvedDockRoutes)) &&
    (value.dockInterface === null || isRecord(value.dockInterface)) &&
    isHexHash(value.dockRoutesRoot) &&
    isHexHash(value.dockInterfaceRoot) &&
    isHexHash(value.capabilitiesRoot) &&
    isHexHash(value.planHash)
  );
}

function isHexArrayRecord(
  value: unknown,
): value is Record<HexString, readonly HexString[]> {
  if (!isRecord(value)) {
    return false;
  }
  return Object.entries(value).every(
    ([key, item]) =>
      isHexHash(key) &&
      Array.isArray(item) &&
      item.every((entry) => isHexHash(entry)),
  );
}

function isPlatform(value: unknown): value is ZhixuPlatform {
  return (
    isRecord(value) &&
    typeof value.type === "string" &&
    value.type.trim().length > 0 &&
    (value.provider === undefined || typeof value.provider === "string") &&
    (value.network === undefined || typeof value.network === "string") &&
    (value.version === undefined || typeof value.version === "string") &&
    (value.params === undefined ||
      (isRecord(value.params) &&
        Object.values(value.params).every((item) => typeof item === "string")))
  );
}

export { onchainDockTrackIssues, onchainUnresolvedRouteIssues };
