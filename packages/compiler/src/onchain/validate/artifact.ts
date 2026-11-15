import { planIdOf } from "../../hook-plan/assemble.js";
import { hashOnchainPlanPayload } from "../hash/plan.js";
import { capabilitiesRootOf } from "../capabilities-root.js";
import {
  canonicalOrderIssues,
  admissionOrderKey,
  executorBindingOrderKey,
  fileWriterOrderKey,
  hookOrderKey,
  routeOrderKey,
  selectorBindingOrderKey,
  signalCapabilityOrderKey,
} from "../canonical/ordering.js";
import { validateOnchainStageFileWriters } from "../file-writers.js";
import {
  executorBindingsRootOf,
  onchainSupplierId,
} from "../executor-bindings.js";
import {
  expectHexHash,
  expectLiteral,
  expectNonEmptyString,
  isHexHash,
  isRecord,
} from "../shape.js";
import { onchainPlanTriggerIssues } from "../triggers.js";
import {
  duplicateCurrentOrderFactKeyIssues,
  validateOnchainExecutorBindings,
  validateOnchainExecutorRoutes,
  validateOnchainSelectorBindings,
  validateOnchainSignalCapabilities,
} from "./capabilities.js";
import {
  birthStageStaticExecutorIssues,
  declaredStageIdentifiers,
  dockStageRouteIssues,
  dynamicStageRouteIssues,
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
  type ExecutorBinding,
  type HexString,
  type OnchainCompiledHook,
  type OnchainExecutorRoute,
  type OnchainHookPlanArtifact,
  type ZhixuPlatform,
} from "../../types/index.js";

/**
 * OnchainHookPlanArtifact 反序列化边界校验：封闭字段集、逐段形状/承诺
 * 校验编排与 planHash 重算。
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
  "triggers",
  "dependencyIndex",
  "executorRoutes",
  "capabilitiesRoot",
  "selectorBindings",
  "signalCapabilities",
  "stageFileWriters",
  "admissions",
  "executorBindings",
  "executorBindingsRoot",
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
  expectHexHash(value.capabilitiesRoot, "capabilitiesRoot", issues);
  issues.push(...capabilitiesRootCommitmentIssues(value));

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
  const stageFileWriters = Array.isArray(value.stageFileWriters)
    ? value.stageFileWriters
    : undefined;
  if (!stageFileWriters) {
    issues.push("stageFileWriters must be an array");
  }
  const admissions = Array.isArray(value.admissions)
    ? value.admissions
    : undefined;
  if (!admissions) {
    issues.push("admissions must be an array");
  }
  const executorBindings = Array.isArray(value.executorBindings)
    ? value.executorBindings
    : undefined;
  if (!executorBindings) {
    issues.push("executorBindings must be an array");
  }
  expectHexHash(value.executorBindingsRoot, "executorBindingsRoot", issues);

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
    issues.push(
      ...dockStageRouteIssues(compiledHooks, executorRoutes ?? []),
    );
    issues.push(
      ...dynamicStageRouteIssues(compiledHooks, executorRoutes ?? []),
    );
    issues.push(...planDependencyCountIssues(compiledHooks as readonly OnchainCompiledHook[]));
    issues.push(...onchainPlanTriggerIssues(value));
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
  if (executorBindings) {
    const { records, issues: bindingShapeIssues } =
      validateOnchainExecutorBindings(executorBindings);
    issues.push(...bindingShapeIssues);
    issues.push(
      ...canonicalOrderIssues(
        executorBindings,
        executorBindingOrderKey,
        "executorBindings",
      ),
    );
    if (records.length === executorBindings.length) {
      issues.push(
        ...executorBindingSemanticIssues(
          records,
          value.executorBindingsRoot,
          compiledHooks ?? [],
          executorRoutes ?? [],
        ),
      );
    }
  }
  if (stageFileWriters) {
    issues.push(
      ...validateOnchainStageFileWriters(
        stageFileWriters,
        new Set(
          (compiledHooks ?? []).flatMap((hook) =>
            isRecord(hook) && typeof hook.stageIdentifier === "string"
              ? [hook.stageIdentifier]
              : [],
          ),
        ),
      ),
      ...canonicalOrderIssues(
        stageFileWriters,
        fileWriterOrderKey,
        "stageFileWriters",
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
        triggers: value.triggers,
        dependencyIndex: value.dependencyIndex,
        executorRoutes: value.executorRoutes,
        capabilitiesRoot: value.capabilitiesRoot,
        selectorBindings: value.selectorBindings,
        signalCapabilities: value.signalCapabilities,
        stageFileWriters: value.stageFileWriters,
        admissions: value.admissions,
        executorBindings: value.executorBindings,
        executorBindingsRoot: value.executorBindingsRoot,
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

function capabilitiesRootCommitmentIssues(
  value: Record<string, unknown>,
): readonly string[] {
  const selectorBindings = Array.isArray(value.selectorBindings)
    ? value.selectorBindings
    : undefined;
  const signalCapabilities = Array.isArray(value.signalCapabilities)
    ? value.signalCapabilities
    : undefined;
  const stageFileWriters = Array.isArray(value.stageFileWriters)
    ? value.stageFileWriters
    : undefined;
  if (
    !selectorBindings ||
    !signalCapabilities ||
    !stageFileWriters ||
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

  const fileWriters: {
    targetStageId: HexString;
    writerStageId: HexString;
  }[] = [];
  for (const binding of stageFileWriters) {
    if (
      isRecord(binding) &&
      isHexHash(binding.targetStageId) &&
      isHexHash(binding.writerStageId)
    ) {
      fileWriters.push({
        targetStageId: binding.targetStageId,
        writerStageId: binding.writerStageId,
      });
    } else {
      return [];
    }
  }

  if (
    value.capabilitiesRoot !==
    capabilitiesRootOf(bindings, capabilities, fileWriters)
  ) {
    return [
      "capabilitiesRoot must match the recomputed root over selector bindings, signal capabilities, and stage file writers",
    ];
  }
  return [];
}

function executorBindingSemanticIssues(
  bindings: readonly ExecutorBinding[],
  declaredRoot: unknown,
  compiledHooks: readonly unknown[],
  executorRoutes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  if (
    isHexHash(declaredRoot) &&
    declaredRoot !== executorBindingsRootOf(bindings)
  ) {
    issues.push(
      "executorBindingsRoot must match the recomputed root over the executor binding leaves",
    );
  }

  const declaredStageIds = new Set(
    compiledHooks.flatMap((hook) =>
      isRecord(hook) && isHexHash(hook.stageId) ? [hook.stageId] : [],
    ),
  );
  const dynamicStageIds = new Set<string>();
  const dockStageIds = new Set<string>();
  const birthStageIds = new Set<string>();
  for (const hook of compiledHooks) {
    if (!isRecord(hook) || !isHexHash(hook.stageId)) {
      continue;
    }
    if (hook.dynamicExecutor === true) {
      dynamicStageIds.add(hook.stageId);
    }
    if (hook.dockExecutor === true) {
      dockStageIds.add(hook.stageId);
    }
    if (
      typeof hook.orderTriggerKind === "string" &&
      hook.orderTriggerKind !== "none"
    ) {
      birthStageIds.add(hook.stageId);
    }
  }

  const routesByStageId = new Map<
    string,
    { readonly stageIdentifier: string; readonly executorId: string }
  >();
  for (const route of executorRoutes) {
    if (
      isRecord(route) &&
      isHexHash(route.stageId) &&
      typeof route.stageIdentifier === "string" &&
      typeof route.executorId === "string" &&
      route.executorId.trim().length > 0
    ) {
      routesByStageId.set(route.stageId, {
        stageIdentifier: route.stageIdentifier,
        executorId: route.executorId,
      });
    }
  }

  const defaultBindingsPerStage = new Map<string, number>();
  for (const binding of bindings) {
    const label = binding.stageIdentifier;
    if (declaredStageIds.size > 0 && !declaredStageIds.has(binding.stageId)) {
      issues.push(
        `executor binding stage ${label} is not a stage declared in this plan`,
      );
      continue;
    }
    if (dynamicStageIds.has(binding.stageId)) {
      issues.push(
        `dynamic executor stage ${label} must not carry plan executor bindings; its supplier is assigned per order through the stage executor patch`,
      );
      continue;
    }
    if (dockStageIds.has(binding.stageId)) {
      issues.push(
        `dock stage ${label} must not carry plan executor bindings; its supplier is selected once through the stage executor patch (dkid)`,
      );
      continue;
    }
    if (binding.kind === 0) {
      const count = (defaultBindingsPerStage.get(binding.stageId) ?? 0) + 1;
      defaultBindingsPerStage.set(binding.stageId, count);
      if (count > 1) {
        issues.push(
          `stage ${label} must carry exactly one default executor binding`,
        );
      }
      const route = routesByStageId.get(binding.stageId);
      if (route === undefined) {
        issues.push(
          `default executor binding for stage ${label} requires the stage's own static executor route`,
        );
      } else if (binding.supplierId !== onchainSupplierId(route.executorId)) {
        issues.push(
          `default executor binding for stage ${label} must commit the supplierId derived from the route's executor.supplierID`,
        );
      }
      continue;
    }
    if (birthStageIds.has(binding.stageId)) {
      issues.push(
        `birth stage ${label} must not carry candidate executor bindings; birth-stage executors are immutable and cannot be per-order patch targets`,
      );
    }
    if (!routesByStageId.has(binding.stageId)) {
      issues.push(
        `candidate executor binding for stage ${label} requires the stage's own plain executor route`,
      );
    }
  }

  for (const [stageId, route] of routesByStageId) {
    if (!defaultBindingsPerStage.has(stageId)) {
      issues.push(
        `stage ${route.stageIdentifier} has a static executor route but no default executor binding`,
      );
    }
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
    Array.isArray(value.triggers) &&
    isHexArrayRecord(value.dependencyIndex) &&
    Array.isArray(value.executorRoutes) &&
    Array.isArray(value.selectorBindings) &&
    Array.isArray(value.signalCapabilities) &&
    Array.isArray(value.stageFileWriters) &&
    Array.isArray(value.admissions) &&
    Array.isArray(value.executorBindings) &&
    isHexHash(value.executorBindingsRoot) &&
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
