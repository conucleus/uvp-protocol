import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  HookPlanCompilationError,
} from "../hook-plan.js";
import {
  declaredStageIdentifiers,
  dynamicStageRouteIssues,
  dockStageRouteIssues,
  uncoveredDockStageIssues,
  silentOrderTriggerIssues,
  unmaterializableStageIssues,
  validateOnchainCompiledAdmissions,
  validateOnchainCompiledHooks,
} from "./validate/hooks.js";
import { planDependencyCountIssues } from "./validate/limits.js";
import { onchainPlanTriggersOf } from "./triggers.js";
import { capabilitiesRootOf } from "./capabilities-root.js";
import { compileStageFileWriters } from "./file-writers.js";
import {
  SUPPLIER_BINDING_KIND_CANDIDATE,
  SUPPLIER_BINDING_KIND_DEFAULT,
  resolveSupplierBindings,
  supplierBindingSetIssues,
  supplierBindingsRootOf,
  supplierIdFromUuid,
} from "./supplier-bindings.js";
import {
  canonicalOrderIssues,
  admissionOrderKey,
  compareAdmissions,
  compareOnchainHooks,
  compareSupplierRoutes,
  hookOrderKey,
} from "./canonical/ordering.js";
import { hashOnchainPlanPayload } from "./hash/plan.js";
import {
  onchainHookId,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
} from "./hash/route.js";
import {
  compileHookInstructions,
  compileSelectorBindings,
  compileSignalCapabilities,
  compileSupplierRoute,
  routeRefForRoute,
} from "./instructions/hooks.js";
import {
  buildOnchainDependencyIndex,
  compileDependency,
} from "./instructions/dependencies.js";
import { packSolidityRegisterPlanArgs } from "./solidity/registration.js";
import { isRecord } from "./shape.js";
import {
  ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
  type CompiledHookPlanAdmission,
  type HookPlanArtifact,
  type OnchainCompiledAdmission,
  type OnchainCompiledHook,
  type OnchainHookPlanArtifact,
  type OnchainSupplierRoute,
  type SignalCapability,
  type SolidityRegisterPlanArgs,
  type StageSupplierBindingInput,
  type SupplierCandidateInput,
  type ZhixuDefinition,
} from "../types/index.js";

/**
 * 链轨编译流水线编排：校验（preflight）→ 转换 → 排序（canonical 序）→
 * 哈希（planHash 承诺）→ 编码（Solidity 注册参数）。`compileZhixu*` 入口
 * 直接消费刚产出的 hook_plan shell，不再对内部 IR 二次 settle；只有公开的
 * 反序列化入口（`compileOnchainHookPlan` / `toSolidityRegisterPlanArgs`）
 * 才走 artifact 边界校验。
 */
export function compileOnchainHookPlan(
  hookPlanArtifact: HookPlanArtifact,
  supplierCandidates?: readonly SupplierCandidateInput[],
): OnchainHookPlanArtifact {
  assertHookPlanArtifact(hookPlanArtifact);
  return lowerOnchainHookPlan(hookPlanArtifact, supplierCandidates);
}

function lowerOnchainHookPlan(
  hookPlanArtifact: HookPlanArtifact,
  supplierCandidates?: readonly SupplierCandidateInput[],
): OnchainHookPlanArtifact {
  const compiledHooks = hookPlanArtifact.compiledHooks
    .map((hook) => ({
      hookId: onchainHookId(hook.stageIdentifier, hook.hookName),
      stageId: onchainStageId(hook.stageIdentifier),
      stageIdentifier: hook.stageIdentifier,
      hookName: hook.hookName,
      kind: hook.kind,
      orderTriggerKind: hook.orderTriggerKind,
      emitReady: hook.emitReady,
      dockExecutor: hook.dockExecutor,
      dynamicExecutor: hook.dynamicExecutor,
      instructions: compileHookInstructions(hook.ast, hook.stageIdentifier, {
        orderTriggerKind: hook.orderTriggerKind,
      }),
      dependencies: hook.dependencies.map(compileDependency),
      ...(hook.route ? { routeRef: routeRefForRoute(hook.route) } : {}),
    }))
    .sort(compareOnchainHooks);
  const admissions = compileSignalAdmissions(
    hookPlanArtifact.admissions,
    hookPlanArtifact.signalCapabilities,
  );
  const declaredStages = declaredStageIdentifiers(
    hookPlanArtifact.signalCapabilities.map((capability) => capability.stageIdentifier),
    Object.keys(hookPlanArtifact.supplierRoutes),
    hookPlanArtifact.selectedStageBindings.flatMap((binding) => [
      binding.selectorStageIdentifier,
      binding.targetStageIdentifier,
    ]),
  );
  const supplierRoutes = Object.values(hookPlanArtifact.supplierRoutes)
    .map(compileSupplierRoute)
    .sort(compareSupplierRoutes);
  const candidates = supplierCandidates ?? [];
  const supplierCandidateIssues = validateSupplierCandidates(
    compiledHooks,
    supplierRoutes,
    declaredStages,
    candidates,
  );
  const materializationIssues = unmaterializableStageIssues(
    compiledHooks,
    declaredStages,
  );
  const silentTriggerIssues = silentOrderTriggerIssues(compiledHooks);
  const dependencyCountIssues = planDependencyCountIssues(compiledHooks);
  const dockRouteIssues = dockStageRouteIssues(compiledHooks, supplierRoutes);
  const uncoveredDockIssues = uncoveredDockStageIssues(
    compiledHooks,
    supplierRoutes,
    hookPlanArtifact.selectedStageBindings,
  );
  const dynamicRouteIssues = dynamicStageRouteIssues(compiledHooks, supplierRoutes);
  const hookShapeIssues: readonly string[] = compiledHooks.length === 0
    ? ["compiledHooks must not be empty (contract reverts EmptyPlan)"]
    : [
        ...validateOnchainCompiledHooks(compiledHooks, supplierRoutes),
        ...canonicalOrderIssues(compiledHooks, hookOrderKey, "compiledHooks"),
      ];
  const admissionShapeIssues: readonly string[] = [
    ...validateOnchainCompiledAdmissions(admissions),
    ...canonicalOrderIssues(admissions, admissionOrderKey, "admissions"),
  ];
  const supplierBindings = resolveSupplierBindings(
    supplierBindingInputsOf(supplierRoutes, candidates),
    onchainStageId,
  );
  const bindingSetIssues = supplierBindingSetIssues(supplierBindings);
  const preflightIssues = [
    ...materializationIssues,
    ...silentTriggerIssues,
    ...dependencyCountIssues,
    ...dockRouteIssues,
    ...uncoveredDockIssues,
    ...dynamicRouteIssues,
    ...hookShapeIssues,
    ...admissionShapeIssues,
    ...supplierCandidateIssues,
    ...bindingSetIssues,
  ];
  if (preflightIssues.length > 0) {
    throw new HookPlanCompilationError(preflightIssues);
  }
  const supplierBindingsRoot = supplierBindingsRootOf(supplierBindings);
  const dependencyIndex = buildOnchainDependencyIndex(compiledHooks);
  const selectorBindings = compileSelectorBindings(
    hookPlanArtifact.selectedStageBindings,
  );
  const signalCapabilities = compileSignalCapabilities(
    hookPlanArtifact.signalCapabilities,
  );
  const stageFileWriters = compileStageFileWriters(
    hookPlanArtifact.source,
    new Set(compiledHooks.map((hook) => hook.stageIdentifier)),
  );
  const soliditySelectorBindings = selectorBindings.map((binding) => ({
    selectorStageId: binding.selectorStageId,
    targetStageId: binding.targetStageId,
  }));
  const soliditySignalCapabilities = signalCapabilities.map((capability) => ({
    stageId: capability.stageId,
    targetSourceId: capability.targetSourceId,
    signalId: capability.signalId,
    targetOrderRelation: 0 as const,
  }));
  const capabilitiesRoot = capabilitiesRootOf(
    soliditySelectorBindings,
    soliditySignalCapabilities,
    stageFileWriters,
  );
  const triggers = onchainPlanTriggersOf(compiledHooks);
  const payload = {
    schemaVersion: ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    zhixuId: hookPlanArtifact.zhixuId,
    zhixuName: hookPlanArtifact.zhixuName,
    platform: hookPlanArtifact.platform,
    sourcePlanHash: hookPlanArtifact.planHash,
    compiledHooks,
    triggers,
    dependencyIndex,
    supplierRoutes,
    capabilitiesRoot,
    selectorBindings,
    signalCapabilities,
    stageFileWriters,
    admissions,
    supplierBindings,
    supplierBindingsRoot,
  };

  return {
    ...payload,
    planHash: hashOnchainPlanPayload(payload),
  };
}

export function compileZhixuOnchainHookPlan(
  definition: ZhixuDefinition,
  supplierCandidates?: readonly SupplierCandidateInput[],
): OnchainHookPlanArtifact {
  return lowerOnchainHookPlan(
    compileZhixuHookPlan(definition),
    supplierCandidates,
  );
}

function supplierBindingInputsOf(
  supplierRoutes: readonly OnchainSupplierRoute[],
  candidates: readonly unknown[],
): readonly StageSupplierBindingInput[] {
  const defaults: StageSupplierBindingInput[] = supplierRoutes.map((route) => ({
    stageIdentifier: route.stageIdentifier,
    supplierID: route.supplierID,
    kind: SUPPLIER_BINDING_KIND_DEFAULT,
  }));
  const candidateBindings = candidates.flatMap<StageSupplierBindingInput>((candidate) => {
    if (!isRecord(candidate)) {
      return [];
    }
    const stageIdentifier = candidate.stageIdentifier;
    const supplierID = candidate.supplierID;
    if (
      typeof stageIdentifier !== "string" ||
      stageIdentifier.trim().length === 0 ||
      typeof supplierID !== "string" ||
      supplierID.trim().length === 0
    ) {
      return [];
    }
    try {
      supplierIdFromUuid(supplierID);
    } catch {
      return [];
    }
    return [{
      stageIdentifier,
      supplierID,
      kind: SUPPLIER_BINDING_KIND_CANDIDATE,
    }];
  });
  return [...defaults, ...candidateBindings];
}

function validateSupplierCandidates(
  hooks: readonly OnchainCompiledHook[],
  supplierRoutes: readonly OnchainSupplierRoute[],
  declaredStages: ReadonlySet<string>,
  candidates: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const routedStages = new Set(supplierRoutes.map((route) => route.stageIdentifier));
  for (const [index, candidate] of candidates.entries()) {
    if (!isRecord(candidate)) {
      issues.push(
        `supplierCandidates[${index}] must be an object with stageIdentifier and supplierID`,
      );
      continue;
    }
    const stageIdentifier = candidate.stageIdentifier;
    const supplierID = candidate.supplierID;
    if (
      typeof stageIdentifier !== "string" ||
      stageIdentifier.trim().length === 0
    ) {
      issues.push(
        `supplierCandidates[${index}].stageIdentifier must be a non-empty stage name`,
      );
      continue;
    }
    if (typeof supplierID !== "string" || supplierID.trim().length === 0) {
      issues.push(
        `supplier candidate for stage "${stageIdentifier}" must carry a non-empty supplierID UUID, received ${JSON.stringify(supplierID)}`,
      );
      continue;
    }
    try {
      supplierIdFromUuid(supplierID);
    } catch (error) {
      issues.push(
        `supplier candidate for stage "${stageIdentifier}": `
          + (error instanceof Error ? error.message : String(error)),
      );
      continue;
    }
    if (!declaredStages.has(stageIdentifier)) {
      issues.push(
        `supplier candidate stage "${stageIdentifier}" is not a stage declared in this plan`,
      );
      continue;
    }
    const stageHooks = hooks.filter(
      (hook) => hook.stageIdentifier === stageIdentifier,
    );
    if (stageHooks.some((hook) => hook.orderTriggerKind !== "none")) {
      issues.push(
        `supplier candidate stage "${stageIdentifier}" carries an order-trigger hook; birth-stage suppliers are immutable and cannot be per-order patch targets`,
      );
      continue;
    }
    if (stageHooks.some((hook) => hook.dockExecutor)) {
      issues.push(
        `supplier candidate stage "${stageIdentifier}" is a dock stage; its supplier is selected once through the stage supplier patch (dkid), never as a plan candidate`,
      );
      continue;
    }
    if (stageHooks.some((hook) => hook.dynamicExecutor)) {
      issues.push(
        `supplier candidate stage "${stageIdentifier}" is a dynamic stage; its supplier is assigned per order through the stage supplier patch and never carries a plan candidate binding`,
      );
      continue;
    }
    if (!routedStages.has(stageIdentifier)) {
      issues.push(
        `supplier candidate stage "${stageIdentifier}" has no static supplier route; only fixed/candidate/birth stages carry plan supplier bindings`,
      );
    }
  }
  return issues;
}

function compileSignalAdmissions(
  admissions: readonly CompiledHookPlanAdmission[],
  signalCapabilities: readonly SignalCapability[],
): OnchainCompiledAdmission[] {
  const sourceByDeclaredSignal = new Map<string, string>();
  for (const capability of signalCapabilities) {
    sourceByDeclaredSignal.set(
      `${capability.stageIdentifier}\u0000${capability.targetSignalName}`,
      capability.targetSource,
    );
  }
  return admissions
    .map((admission) => {
      const stageId = onchainStageId(admission.stageIdentifier);
      const signalId = onchainSignalId(admission.signalName);
      const declared = `${admission.stageIdentifier}\u0000${admission.signalName}`;
      const targetSource = sourceByDeclaredSignal.get(declared);
      if (targetSource === undefined) {
        throw new HookPlanCompilationError([
          `admission ${admission.stageIdentifier}::${admission.signalName} has no current-order signal capability for the declared emission; `
            + "the admission face addresses the emitted fact key (sourceId, signalId), which only the declaring stage's capability carries",
        ]);
      }
      const sourceId = onchainSourceId(targetSource);
      return {
        admissionId: onchainSignalKey(sourceId, signalId),
        stageId,
        stageIdentifier: admission.stageIdentifier,
        signalName: admission.signalName,
        signalId,
        sourceId,
        instructions: compileHookInstructions(
          admission.ast,
          admission.stageIdentifier,
          { orderTriggerKind: "none" },
        ),
        dependencies: admission.dependencies.map(compileDependency),
      };
    })
    .sort(compareAdmissions);
}

export function compileZhixuRegisterPlanArgs(
  definition: ZhixuDefinition,
  supplierCandidates?: readonly SupplierCandidateInput[],
): SolidityRegisterPlanArgs {
  return packSolidityRegisterPlanArgs(
    compileZhixuOnchainHookPlan(definition, supplierCandidates),
  );
}
