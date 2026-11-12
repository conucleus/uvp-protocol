import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  HookPlanCompilationError,
} from "../hook-plan.js";
import {
  OnchainHookPlanArtifactValidationError,
} from "./validate/artifact.js";
import {
  birthStageStaticExecutorIssues,
  crossStageDependencyIssues,
  declaredStageIdentifiers,
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
  executorCandidatesRootOf,
  isExecutorAddress,
  normalizeExecutorCandidates,
} from "./executor-candidates.js";
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
import {
  ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
  type CompiledHookPlanAdmission,
  type ExecutorCandidateInput,
  type HookPlanArtifact,
  type OnchainCompiledAdmission,
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
  const executorCandidateIssues: readonly string[] = (executorCandidates ?? []).map(
    (candidate) => {
      if (!declaredStages.has(candidate.stageIdentifier)) {
        return `executor candidate stage "${candidate.stageIdentifier}" is not a stage declared in this plan`;
      }
      if (
        compiledHooks.some(
          (hook) =>
            hook.stageIdentifier === candidate.stageIdentifier &&
            hook.orderTriggerKind !== "none",
        )
      ) {
        return `executor candidate stage "${candidate.stageIdentifier}" carries an order-trigger hook; birth-stage executors are immutable and cannot be per-order patch targets`;
      }
      if (
        compiledHooks.some(
          (hook) =>
            hook.stageIdentifier === candidate.stageIdentifier &&
            hook.dockExecutor,
        )
      ) {
        return `executor candidate stage "${candidate.stageIdentifier}" is a dock stage; its executor is selected once through the stage executor patch (dkid), never as a plan candidate`;
      }
      if (!isExecutorAddress(candidate.executor)) {
        return `executor candidate for stage "${candidate.stageIdentifier}" must be a non-zero 20-byte address, received ${JSON.stringify(candidate.executor)}`;
      }
      return "";
    },
  ).filter((issue) => issue.length > 0);

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
  const executorRoutes = Object.values(hookPlanArtifact.executorRoutes)
    .map(compileExecutorRoute)
    .sort(compareExecutorRoutes);
  const dockRouteIssues = dockStageRouteIssues(compiledHooks, executorRoutes);
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
  const preflightIssues = [
    ...crossStageIssues,
    ...materializationIssues,
    ...birthStageExecutorIssues,
    ...silentTriggerIssues,
    ...dependencyCountIssues,
    ...currentOrderFactKeyIssues,
    ...dockRouteIssues,
    ...hookShapeIssues,
    ...admissionShapeIssues,
    ...executorCandidateIssues,
  ];
  if (preflightIssues.length > 0) {
    throw new HookPlanCompilationError(preflightIssues);
  }
  const executorCandidateList = normalizeExecutorCandidates(
    executorCandidates ?? [],
    (stageIdentifier) => onchainStageId(stageIdentifier),
  );
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
  const executorCandidatesRoot = executorCandidatesRootOf(executorCandidateList);
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
    executorCandidates: executorCandidateList,
    executorCandidatesRoot,
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
