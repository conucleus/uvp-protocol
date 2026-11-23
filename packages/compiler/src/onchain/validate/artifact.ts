import { planIdOf } from "../../hook-plan/assemble.js";
import { hashOnchainPlanPayload } from "../hash/plan.js";
import { capabilitiesRootOf } from "../capabilities-root.js";
import {
  canonicalOrderIssues,
  admissionOrderKey,
  fileWriterOrderKey,
  hookOrderKey,
  routeOrderKey,
  selectorBindingOrderKey,
  signalCapabilityOrderKey,
  supplierBindingOrderKey,
} from "../canonical/ordering.js";
import { validateOnchainStageFileWriters } from "../file-writers.js";
import {
  supplierBindingsRootOf,
  supplierIdFromUuid,
} from "../supplier-bindings.js";
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
  validateOnchainSelectorBindings,
  validateOnchainSignalCapabilities,
  validateOnchainSupplierBindings,
  validateOnchainSupplierRoutes,
} from "./capabilities.js";
import {
  birthStageStaticSupplierIssues,
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
  type HexString,
  type OnchainCompiledHook,
  type OnchainHookPlanArtifact,
  type StageSupplierBinding,
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
  "supplierRoutes",
  "capabilitiesRoot",
  "selectorBindings",
  "signalCapabilities",
  "stageFileWriters",
  "admissions",
  "supplierBindings",
  "supplierBindingsRoot",
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

  const supplierRoutes = Array.isArray(value.supplierRoutes)
    ? value.supplierRoutes
    : undefined;
  if (!supplierRoutes) {
    issues.push("supplierRoutes must be an array");
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
  const supplierBindings = Array.isArray(value.supplierBindings)
    ? value.supplierBindings
    : undefined;
  if (!supplierBindings) {
    issues.push("supplierBindings must be an array");
  }
  expectHexHash(value.supplierBindingsRoot, "supplierBindingsRoot", issues);

  if (compiledHooks) {
    issues.push(
      ...validateOnchainCompiledHooks(compiledHooks, supplierRoutes ?? []),
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
          (supplierRoutes ?? [])
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
      ...birthStageStaticSupplierIssues(compiledHooks, supplierRoutes ?? []),
    );
    issues.push(
      ...dockStageRouteIssues(compiledHooks, supplierRoutes ?? []),
    );
    issues.push(
      ...dynamicStageRouteIssues(compiledHooks, supplierRoutes ?? []),
    );
    issues.push(...planDependencyCountIssues(compiledHooks as readonly OnchainCompiledHook[]));
    issues.push(...onchainPlanTriggerIssues(value));
  }

  if (supplierRoutes) {
    issues.push(...validateOnchainSupplierRoutes(supplierRoutes));
    issues.push(
      ...canonicalOrderIssues(supplierRoutes, routeOrderKey, "supplierRoutes"),
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
    if (signalCapabilities) {
      issues.push(
        ...admissionCapabilityIssues(admissions, signalCapabilities),
      );
    }
  }
  if (supplierBindings) {
    const { records, issues: bindingShapeIssues } =
      validateOnchainSupplierBindings(supplierBindings);
    issues.push(...bindingShapeIssues);
    issues.push(
      ...canonicalOrderIssues(
        supplierBindings,
        supplierBindingOrderKey,
        "supplierBindings",
      ),
    );
    if (records.length === supplierBindings.length) {
      issues.push(
        ...supplierBindingSemanticIssues(
          records,
          value.supplierBindingsRoot,
          compiledHooks ?? [],
          supplierRoutes ?? [],
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
        supplierRoutes: value.supplierRoutes,
        capabilitiesRoot: value.capabilitiesRoot,
        selectorBindings: value.selectorBindings,
        signalCapabilities: value.signalCapabilities,
        stageFileWriters: value.stageFileWriters,
        admissions: value.admissions,
        supplierBindings: value.supplierBindings,
        supplierBindingsRoot: value.supplierBindingsRoot,
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

function admissionCapabilityIssues(
  admissions: readonly unknown[],
  signalCapabilities: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const capabilities = new Map<
    string,
    {
      readonly stageId: unknown;
      readonly targetSourceId: unknown;
      readonly signalId: unknown;
    }
  >();
  for (const capability of signalCapabilities) {
    if (
      isRecord(capability) &&
      typeof capability.stageIdentifier === "string" &&
      typeof capability.targetSignalName === "string"
    ) {
      capabilities.set(
        `${capability.stageIdentifier}\u0000${capability.targetSignalName}`,
        {
          stageId: capability.stageId,
          targetSourceId: capability.targetSourceId,
          signalId: capability.signalId,
        },
      );
    }
  }
  for (const [index, admission] of admissions.entries()) {
    if (
      !isRecord(admission) ||
      typeof admission.stageIdentifier !== "string" ||
      typeof admission.signalName !== "string"
    ) {
      continue;
    }
    const prefix = `admissions[${index}]`;
    const capability = capabilities.get(
      `${admission.stageIdentifier}\u0000${admission.signalName}`,
    );
    if (capability === undefined) {
      issues.push(
        `${prefix} ${admission.stageIdentifier}::${admission.signalName} has no current-order signal capability for the declared emission; `
          + "the admission face addresses the emitted fact key (sourceId, signalId), which only the declaring stage's capability carries",
      );
      continue;
    }
    if (admission.stageId !== capability.stageId) {
      issues.push(
        `${prefix}.stageId must equal the capability stageId of the same declared emission`,
      );
    }
    if (admission.sourceId !== capability.targetSourceId) {
      issues.push(
        `${prefix}.sourceId must equal the capability targetSourceId of the same declared emission`,
      );
    }
    if (admission.signalId !== capability.signalId) {
      issues.push(
        `${prefix}.signalId must equal the capability signalId of the same declared emission`,
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
    targetOrderRelation: 0;
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

function supplierBindingSemanticIssues(
  bindings: readonly StageSupplierBinding[],
  declaredRoot: unknown,
  compiledHooks: readonly unknown[],
  supplierRoutes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  if (
    isHexHash(declaredRoot) &&
    declaredRoot !== supplierBindingsRootOf(bindings)
  ) {
    issues.push(
      "supplierBindingsRoot must match the recomputed root over the supplier binding leaves",
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
    {
      readonly stageIdentifier: string;
      readonly supplierID: string;
      readonly supplierId: HexString;
    }
  >();
  for (const route of supplierRoutes) {
    if (
      isRecord(route) &&
      isHexHash(route.stageId) &&
      typeof route.stageIdentifier === "string" &&
      typeof route.supplierID === "string" &&
      route.supplierID.trim().length > 0
    ) {
      let supplierId: HexString;
      try {
        supplierId = supplierIdFromUuid(route.supplierID);
      } catch {
        continue;
      }
      routesByStageId.set(route.stageId, {
        stageIdentifier: route.stageIdentifier,
        supplierID: route.supplierID,
        supplierId,
      });
    }
  }

  const defaultBindingsPerStage = new Map<string, number>();
  for (const binding of bindings) {
    const label = binding.stageIdentifier;
    if (declaredStageIds.size > 0 && !declaredStageIds.has(binding.stageId)) {
      issues.push(
        `supplier binding stage ${label} is not a stage declared in this plan`,
      );
      continue;
    }
    if (dynamicStageIds.has(binding.stageId)) {
      issues.push(
        `dynamic stage ${label} must not carry plan supplier bindings; its supplier is assigned per order through the stage supplier patch`,
      );
      continue;
    }
    if (dockStageIds.has(binding.stageId)) {
      issues.push(
        `dock stage ${label} must not carry plan supplier bindings; its supplier is selected once through the stage supplier patch (dkid)`,
      );
      continue;
    }
    if (binding.kind === 0) {
      const count = (defaultBindingsPerStage.get(binding.stageId) ?? 0) + 1;
      defaultBindingsPerStage.set(binding.stageId, count);
      if (count > 1) {
        issues.push(
          `stage ${label} must carry exactly one default supplier binding`,
        );
      }
      const route = routesByStageId.get(binding.stageId);
      if (route === undefined) {
        issues.push(
          `default supplier binding for stage ${label} requires the stage's own static supplier route`,
        );
      } else if (binding.supplierID !== route.supplierID) {
        issues.push(
          `default supplier binding for stage ${label} must commit the supplier UUID of the route's executor.supplierID`,
        );
      } else if (binding.supplierId !== route.supplierId) {
        issues.push(
          `default supplier binding for stage ${label} must commit the supplierId decoded from the route's executor.supplierID`,
        );
      }
      continue;
    }
    if (birthStageIds.has(binding.stageId)) {
      issues.push(
        `birth stage ${label} must not carry candidate supplier bindings; birth-stage suppliers are immutable and cannot be per-order patch targets`,
      );
    }
    if (!routesByStageId.has(binding.stageId)) {
      issues.push(
        `candidate supplier binding for stage ${label} requires the stage's own plain supplier route`,
      );
    }
  }

  for (const [stageId, route] of routesByStageId) {
    if (!defaultBindingsPerStage.has(stageId)) {
      issues.push(
        `stage ${route.stageIdentifier} has a static supplier route but no default supplier binding`,
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
    Array.isArray(value.supplierRoutes) &&
    Array.isArray(value.selectorBindings) &&
    Array.isArray(value.signalCapabilities) &&
    Array.isArray(value.stageFileWriters) &&
    Array.isArray(value.admissions) &&
    Array.isArray(value.supplierBindings) &&
    isHexHash(value.supplierBindingsRoot) &&
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
