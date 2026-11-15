import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  HookPlanCompilationError,
} from "../hook-plan.js";
import {
  birthStageStaticExecutorIssues,
  crossStageDependencyIssues,
  declaredStageIdentifiers,
  dynamicStageRouteIssues,
  dockStageRouteIssues,
  silentOrderTriggerIssues,
  unmaterializableStageIssues,
  validateOnchainCompiledAdmissions,
  validateOnchainCompiledHooks,
} from "./validate/hooks.js";
import { planDependencyCountIssues } from "./validate/limits.js";
import { duplicateCurrentOrderFactKeyIssues } from "./validate/capabilities.js";
import { onchainPlanTriggersOf } from "./triggers.js";
import { capabilitiesRootOf } from "./capabilities-root.js";
import { compileStageFileWriters } from "./file-writers.js";
import {
  EXECUTOR_BINDING_KIND_CANDIDATE,
  EXECUTOR_BINDING_KIND_DEFAULT,
  executorBindingSetIssues,
  executorBindingsRootOf,
  resolveExecutorBindings,
} from "./executor-bindings.js";
import {
  canonicalOrderIssues,
  admissionOrderKey,
  compareAdmissions,
  compareExecutorRoutes,
  compareOnchainHooks,
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
  compileExecutorRoute,
  compileSelectorBindings,
  compileSignalCapabilities,
  routeRefForRoute,
} from "./instructions/hooks.js";
import {
  buildOnchainDependencyIndex,
  compileDependency,
} from "./instructions/dependencies.js";
import { toSolidityRegisterPlanArgs } from "./solidity/registration.js";
import { isRecord } from "./shape.js";
import {
  ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
  type CompiledHookPlanAdmission,
  type ExecutorBindingInput,
  type ExecutorCandidateInput,
  type HookPlanArtifact,
  type OnchainCompiledAdmission,
  type OnchainCompiledHook,
  type OnchainExecutorRoute,
  type OnchainHookPlanArtifact,
  type SignalCapability,
  type SolidityRegisterPlanArgs,
  type ZhixuDefinition,
} from "../types/index.js";

/**
 * 链轨编译流水线编排：校验（preflight）→ 转换 → 排序（canonical 序）→
 * 哈希（planHash 承诺）→ 编码（Solidity 注册参数）。
 */
export function compileOnchainHookPlan(
  hookPlanArtifact: HookPlanArtifact,
  executorCandidates?: readonly ExecutorCandidateInput[],
): OnchainHookPlanArtifact {
  assertHookPlanArtifact(hookPlanArtifact);

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
    Object.keys(hookPlanArtifact.executorRoutes),
    hookPlanArtifact.selectedStageBindings.flatMap((binding) => [
      binding.selectorStageIdentifier,
      binding.targetStageIdentifier,
    ]),
  );
  const executorRoutes = Object.values(hookPlanArtifact.executorRoutes)
    .map(compileExecutorRoute)
    .sort(compareExecutorRoutes);
  const candidates = executorCandidates ?? [];
  const executorCandidateIssues = validateExecutorCandidates(
    compiledHooks,
    executorRoutes,
    declaredStages,
    candidates,
  );
  const crossStageIssues = crossStageDependencyIssues(compiledHooks);
  const materializationIssues = unmaterializableStageIssues(
    compiledHooks,
    declaredStages,
  );
  const silentTriggerIssues = silentOrderTriggerIssues(compiledHooks);
  const dependencyCountIssues = planDependencyCountIssues(compiledHooks);
  const currentOrderFactKeyIssues = duplicateCurrentOrderFactKeyIssues(
    hookPlanArtifact.signalCapabilities.map((capability) => ({
      stage: capability.stageIdentifier,
      sourceId: onchainSourceId(capability.targetSource),
      signalId: onchainSignalId(capability.targetSignalName),
    })),
  );
  const dockRouteIssues = dockStageRouteIssues(compiledHooks, executorRoutes);
  const dynamicRouteIssues = dynamicStageRouteIssues(compiledHooks, executorRoutes);
  const birthStageExecutorIssues = birthStageStaticExecutorIssues(
    compiledHooks,
    executorRoutes,
  );
  const hookShapeIssues: readonly string[] = compiledHooks.length === 0
    ? ["compiledHooks must not be empty (contract reverts EmptyPlan)"]
    : [
        ...validateOnchainCompiledHooks(compiledHooks, executorRoutes),
        ...canonicalOrderIssues(compiledHooks, hookOrderKey, "compiledHooks"),
      ];
  const admissionShapeIssues: readonly string[] = [
    ...validateOnchainCompiledAdmissions(admissions),
    ...canonicalOrderIssues(admissions, admissionOrderKey, "admissions"),
  ];
  const executorBindings = resolveExecutorBindings(
    executorBindingInputsOf(executorRoutes, candidates),
    onchainStageId,
  );
  const bindingSetIssues = executorBindingSetIssues(executorBindings);
  const preflightIssues = [
    ...crossStageIssues,
    ...materializationIssues,
    ...birthStageExecutorIssues,
    ...silentTriggerIssues,
    ...dependencyCountIssues,
    ...currentOrderFactKeyIssues,
    ...dockRouteIssues,
    ...dynamicRouteIssues,
    ...hookShapeIssues,
    ...admissionShapeIssues,
    ...executorCandidateIssues,
    ...bindingSetIssues,
  ];
  if (preflightIssues.length > 0) {
    throw new HookPlanCompilationError(preflightIssues);
  }
  const executorBindingsRoot = executorBindingsRootOf(executorBindings);
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
  const solidityFileWriterBindings = stageFileWriters.map((binding) => ({
    targetStageId: binding.targetStageId,
    writerStageId: binding.writerStageId,
  }));
  const capabilitiesRoot = capabilitiesRootOf(
    soliditySelectorBindings,
    soliditySignalCapabilities,
    solidityFileWriterBindings,
  );
  const triggers = onchainPlanTriggersOf(compiledHooks);
  const payload = {
    schemaVersion: ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    planId: hookPlanArtifact.planId,
    zhixuId: hookPlanArtifact.zhixuId,
    zhixuName: hookPlanArtifact.zhixuName,
    platform: hookPlanArtifact.platform,
    sourcePlanHash: hookPlanArtifact.planHash,
    compiledHooks,
    triggers,
    dependencyIndex,
    executorRoutes,
    capabilitiesRoot,
    selectorBindings,
    signalCapabilities,
    stageFileWriters,
    admissions,
    executorBindings,
    executorBindingsRoot,
  };

  return {
    ...payload,
    planHash: hashOnchainPlanPayload(payload),
  };
}

export function compileZhixuOnchainHookPlan(
  definition: ZhixuDefinition,
  executorCandidates?: readonly ExecutorCandidateInput[],
): OnchainHookPlanArtifact {
  return compileOnchainHookPlan(
    compileZhixuHookPlan(definition),
    executorCandidates,
  );
}

function executorBindingInputsOf(
  executorRoutes: readonly OnchainExecutorRoute[],
  candidates: readonly unknown[],
): readonly ExecutorBindingInput[] {
  const defaults: ExecutorBindingInput[] = executorRoutes.map((route) => ({
    stageIdentifier: route.stageIdentifier,
    supplierID: route.executorId,
    kind: EXECUTOR_BINDING_KIND_DEFAULT,
  }));
  const candidateBindings = candidates.flatMap<ExecutorBindingInput>((candidate) => {
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
    return [{
      stageIdentifier,
      supplierID,
      kind: EXECUTOR_BINDING_KIND_CANDIDATE,
    }];
  });
  return [...defaults, ...candidateBindings];
}

function validateExecutorCandidates(
  hooks: readonly OnchainCompiledHook[],
  executorRoutes: readonly OnchainExecutorRoute[],
  declaredStages: ReadonlySet<string>,
  candidates: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const routedStages = new Set(executorRoutes.map((route) => route.stageIdentifier));
  for (const [index, candidate] of candidates.entries()) {
    if (!isRecord(candidate)) {
      issues.push(
        `executorCandidates[${index}] must be an object with stageIdentifier and supplierID`,
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
        `executorCandidates[${index}].stageIdentifier must be a non-empty stage name`,
      );
      continue;
    }
    if (typeof supplierID !== "string" || supplierID.trim().length === 0) {
      issues.push(
        `executor candidate for stage "${stageIdentifier}" must carry a non-empty supplierID, received ${JSON.stringify(supplierID)}`,
      );
      continue;
    }
    if (!declaredStages.has(stageIdentifier)) {
      issues.push(
        `executor candidate stage "${stageIdentifier}" is not a stage declared in this plan`,
      );
      continue;
    }
    const stageHooks = hooks.filter(
      (hook) => hook.stageIdentifier === stageIdentifier,
    );
    if (stageHooks.some((hook) => hook.orderTriggerKind !== "none")) {
      issues.push(
        `executor candidate stage "${stageIdentifier}" carries an order-trigger hook; birth-stage executors are immutable and cannot be per-order patch targets`,
      );
      continue;
    }
    if (stageHooks.some((hook) => hook.dockExecutor)) {
      issues.push(
        `executor candidate stage "${stageIdentifier}" is a dock stage; its executor is selected once through the stage executor patch (dkid), never as a plan candidate`,
      );
      continue;
    }
    if (stageHooks.some((hook) => hook.dynamicExecutor)) {
      issues.push(
        `executor candidate stage "${stageIdentifier}" is a dynamic stage; its supplier is assigned per order through the stage executor patch and never carries a plan candidate binding`,
      );
      continue;
    }
    if (!routedStages.has(stageIdentifier)) {
      issues.push(
        `executor candidate stage "${stageIdentifier}" has no static executor route; only fixed/candidate/birth stages carry plan executor bindings`,
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
  executorCandidates?: readonly ExecutorCandidateInput[],
): SolidityRegisterPlanArgs {
  return toSolidityRegisterPlanArgs(
    compileZhixuOnchainHookPlan(definition, executorCandidates),
  );
}
