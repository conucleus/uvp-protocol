import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  HookPlanCompilationError,
} from "../hook-plan.js";
import { interfaceRootOf, merkleRoot } from "../dock.js";
import {
  OnchainHookPlanArtifactValidationError,
  onchainDockTrackIssues,
  onchainUnresolvedRouteIssues,
} from "./validate/artifact.js";
import {
  birthStageStaticExecutorIssues,
  crossStageDependencyIssues,
  declaredStageIdentifiers,
  duplicateBirthChannelKeyIssues,
  silentOrderTriggerIssues,
  unmaterializableStageIssues,
  validateOnchainCompiledAdmissions,
  validateOnchainCompiledHooks,
} from "./validate/hooks.js";
import { planDependencyCountIssues } from "./validate/limits.js";
import { duplicateCurrentOrderFactKeyIssues } from "./validate/capabilities.js";
import { capabilitiesRootOf } from "./capabilities-root.js";
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
  type DockResolutionManifest,
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
    hookPlanArtifact.dockRoutes.map((route) => route.local.stageIdentifier),
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
      if (!isExecutorAddress(candidate.executor)) {
        return `executor candidate for stage "${candidate.stageIdentifier}" must be a non-zero 20-byte address, received ${JSON.stringify(candidate.executor)}`;
      }
      return "";
    },
  ).filter((issue) => issue.length > 0);

  const crossStageIssues = crossStageDependencyIssues(compiledHooks);
  const materializationIssues = unmaterializableStageIssues(
    compiledHooks,
    declaredStageIdentifiers(
      hookPlanArtifact.signalCapabilities.map((capability) => capability.stageIdentifier),
      Object.keys(hookPlanArtifact.executorRoutes),
      hookPlanArtifact.dockRoutes.map((route) => route.local.stageIdentifier),
      hookPlanArtifact.selectedStageBindings.flatMap((binding) => [
        binding.selectorStageIdentifier,
        binding.targetStageIdentifier,
      ]),
    ),
  );
  const silentTriggerIssues = silentOrderTriggerIssues(compiledHooks);
  const duplicateBirthKeyIssues = duplicateBirthChannelKeyIssues(compiledHooks);
  const dependencyCountIssues = planDependencyCountIssues(compiledHooks);
  const currentOrderFactKeyIssues = duplicateCurrentOrderFactKeyIssues(
    hookPlanArtifact.signalCapabilities.map((capability) => ({
      stage: capability.stageIdentifier,
      sourceId: onchainSourceId(capability.targetSource),
      signalId: onchainSignalId(capability.targetSignalName),
    })),
  );
  const dockTrackIssues = onchainDockTrackIssues(hookPlanArtifact.dockRoutes);
  const unresolvedTrackIssues = onchainUnresolvedRouteIssues(
    hookPlanArtifact.unresolvedDockRoutes,
  );
  const executorRoutes = Object.values(hookPlanArtifact.executorRoutes)
    .map(compileExecutorRoute)
    .sort(compareExecutorRoutes);
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
    ...duplicateBirthKeyIssues,
    ...dependencyCountIssues,
    ...currentOrderFactKeyIssues,
    ...dockTrackIssues,
    ...unresolvedTrackIssues,
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
  const dockRoutes = hookPlanArtifact.dockRoutes;
  const unresolvedDockRoutes =
    hookPlanArtifact.unresolvedDockRoutes !== undefined &&
    hookPlanArtifact.unresolvedDockRoutes.length > 0
      ? hookPlanArtifact.unresolvedDockRoutes
      : undefined;
  const recomputedRoutesRoot = merkleRoot([
    ...dockRoutes.map((route) => route.routeHash),
    ...(unresolvedDockRoutes ?? []).map((route) => route.routeHash),
  ]);
  if (recomputedRoutesRoot !== hookPlanArtifact.dockRoutesRoot) {
    throw new OnchainHookPlanArtifactValidationError([
      "dockRoutesRoot does not match the recomputed root over dock route hashes",
    ]);
  }
  if (hookPlanArtifact.dockInterface !== null) {
    const recomputedInterfaceRoot = interfaceRootOf(hookPlanArtifact.dockInterface);
    if (recomputedInterfaceRoot !== hookPlanArtifact.dockInterfaceRoot) {
      throw new OnchainHookPlanArtifactValidationError([
        "dockInterfaceRoot does not match the recomputed root over interface leaves",
      ]);
    }
  }
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
  );
  const executorCandidatesRoot = executorCandidatesRootOf(executorCandidateList);
  const payload = {
    schemaVersion: ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    planId: hookPlanArtifact.planId,
    zhixuId: hookPlanArtifact.zhixuId,
    zhixuName: hookPlanArtifact.zhixuName,
    platform: hookPlanArtifact.platform,
    sourcePlanHash: hookPlanArtifact.planHash,
    compiledHooks,
    dependencyIndex,
    executorRoutes,
    dockInterface: hookPlanArtifact.dockInterface,
    dockRoutes,
    ...(unresolvedDockRoutes === undefined
      ? {}
      : { unresolvedDockRoutes }),
    dockRoutesRoot: hookPlanArtifact.dockRoutesRoot,
    dockInterfaceRoot: hookPlanArtifact.dockInterfaceRoot,
    capabilitiesRoot,
    selectorBindings,
    signalCapabilities,
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
  resolutionManifest?: DockResolutionManifest,
  executorCandidates?: readonly ExecutorCandidateInput[],
): OnchainHookPlanArtifact {
  return compileOnchainHookPlan(
    compileZhixuHookPlan(definition, resolutionManifest),
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
  resolutionManifest?: DockResolutionManifest,
  executorCandidates?: readonly ExecutorCandidateInput[],
): SolidityRegisterPlanArgs {
  return toSolidityRegisterPlanArgs(
    compileZhixuOnchainHookPlan(definition, resolutionManifest, executorCandidates),
  );
}
