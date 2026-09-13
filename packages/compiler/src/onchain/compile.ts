import {
  assertHookPlanArtifact,
  compileZhixuHookPlan,
  HookPlanCompilationError,
} from "../hook-plan.js";
import { dockRoutesRootOf, interfaceRootOf } from "../dock.js";
import {
  OnchainHookPlanArtifactValidationError,
  onchainDockTrackIssues,
  onchainUnresolvedRouteIssues,
} from "./validate/artifact.js";
import {
  crossStageDependencyIssues,
  declaredStageIdentifiers,
  silentOrderTriggerIssues,
  unmaterializableStageIssues,
  validateOnchainCompiledHooks,
} from "./validate/hooks.js";
import {
  planDependencyCountIssues,
  signalCapabilityCountIssues,
} from "./validate/limits.js";
import { duplicateCurrentOrderFactKeyIssues } from "./validate/capabilities.js";
import {
  canonicalOrderIssues,
  compareExecutorRoutes,
  compareOnchainHooks,
  hookOrderKey,
} from "./canonical/ordering.js";
import { hashOnchainPlanPayload } from "./hash/plan.js";
import {
  onchainHookId,
  onchainSignalId,
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
  type DockResolutionManifest,
  type HookPlanArtifact,
  type OnchainHookPlanArtifact,
  type SolidityRegisterPlanArgs,
  type ZhixuDefinition,
} from "../types/index.js";

/**
 * 链轨编译流水线编排（自 onchain-hook-plan.ts 原样迁入）：校验（preflight
 * 镜像门）→ 转换（指令/依赖/路由/能力）→ 排序（canonical 序）→ 哈希
 * （planHash 承诺）→ 编码（Solidity 注册参数）→ 返回产物。单向下游依赖
 * validate / instructions / canonical / hash / solidity，不反向。
 */
export function compileOnchainHookPlan(
  hookPlanArtifact: HookPlanArtifact,
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
  // 逐 hook 顺序语义与合约 _registerPlanHook 一致（见 crossStageDependencyIssues）。
  const crossStageIssues = crossStageDependencyIssues(compiledHooks);
  // 不可物化阶段（无 order-trigger / EMIT_READY hook 的阶段）不得挂任何
  // receive hook，且阶段声明不得编译为零 hook——纯 flags=0 watcher 不物化
  // 阶段，零 hook 阶段同样不物化，链上对该阶段的任何求值都是不可
  // 恢复死锁（Rust 编译器是第一道，这里是 artifact 边界的第二道）。
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
  const dependencyCountIssues = planDependencyCountIssues(compiledHooks);
  const capabilityCountIssues = signalCapabilityCountIssues(
    hookPlanArtifact.signalCapabilities,
  );
  const currentOrderFactKeyIssues = duplicateCurrentOrderFactKeyIssues(
    hookPlanArtifact.signalCapabilities.map((capability) => ({
      stage: capability.stageIdentifier,
      sourceId: onchainSourceId(capability.targetSource),
      signalId: onchainSignalId(capability.targetSignalName),
      isCurrentOrder: capability.targetOrderRelation === "current",
    })),
  );
  // 链轨拒绝：Rust 两个 profile 都放行 existing 与
  // 动态 target（hook plan 产物携带 unresolvedDockRoutes 声明面，§8.8），
  // 是否上链由宿主轨道决定——on-chain 编译在这里显式拒绝，不静默降级。
  // Rust hook_plan 不再对 target:null 兜底拒绝，这里是 on-chain 边界对
  // 未解析 route 的第一道门。
  const dockTrackIssues = onchainDockTrackIssues(hookPlanArtifact.dockRoutes);
  const unresolvedTrackIssues = onchainUnresolvedRouteIssues(
    hookPlanArtifact.unresolvedDockRoutes,
  );
  // executorRoutes 先于 preflight 组装：validateOnchainCompiledHooks 的
  // routeRef 引用检查需要它们在场（闭集/空 id 由 compileExecutorRoute 自行
  // 响亮拒绝）。
  const executorRoutes = Object.values(hookPlanArtifact.executorRoutes)
    .map(compileExecutorRoute)
    .sort(compareExecutorRoutes);
  // _validateHook 镜像预检（MAX_ONCHAIN_HOOK_DELAY_SECONDS 等常量自述
  // "fail-closed 预检必须拒绝同样输入"）：EmptyPlan/空指令栈/空依赖/
  // 30 天延时上限等此前只在反序列化边界生效——手工/漂移的 IR 制品过
  // IR 校验后会在编译入口静默产出毒制品，交由 commitPlan revert。
  const hookShapeIssues: readonly string[] = compiledHooks.length === 0
    ? ["compiledHooks must not be empty (contract reverts EmptyPlan)"]
    : [
        ...validateOnchainCompiledHooks(compiledHooks, executorRoutes),
        ...canonicalOrderIssues(compiledHooks, hookOrderKey, "compiledHooks"),
      ];
  const preflightIssues = [
    ...crossStageIssues,
    ...materializationIssues,
    ...silentTriggerIssues,
    ...dependencyCountIssues,
    ...capabilityCountIssues,
    ...currentOrderFactKeyIssues,
    ...dockTrackIssues,
    ...unresolvedTrackIssues,
    ...hookShapeIssues,
  ];
  if (preflightIssues.length > 0) {
    throw new HookPlanCompilationError(preflightIssues);
  }
  const dependencyIndex = buildOnchainDependencyIndex(compiledHooks);
  const selectorBindings = compileSelectorBindings(
    hookPlanArtifact.selectedStageBindings,
  );
  const signalCapabilities = compileSignalCapabilities(
    hookPlanArtifact.signalCapabilities,
  );
  // fail-closed：dock roots 由 TS 侧从 core 产物重算并断言一致，任何分叉
  // 都在编译期暴露。
  const dockRoutes = hookPlanArtifact.dockRoutes;
  const recomputedRoutesRoot = dockRoutesRootOf(dockRoutes);
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
    dockRoutesRoot: hookPlanArtifact.dockRoutesRoot,
    dockInterfaceRoot: hookPlanArtifact.dockInterfaceRoot,
    selectorBindings,
    signalCapabilities,
  };

  return {
    ...payload,
    planHash: hashOnchainPlanPayload(payload),
  };
}

export function compileZhixuOnchainHookPlan(
  definition: ZhixuDefinition,
  resolutionManifest?: DockResolutionManifest,
): OnchainHookPlanArtifact {
  return compileOnchainHookPlan(
    compileZhixuHookPlan(definition, resolutionManifest),
  );
}

// These args feed the two-step `commitPlan` + `finalizePlan` flow. The
// `RegisterPlanArgs` name is kept for API stability; renaming is a breaking
// change.
export function compileZhixuRegisterPlanArgs(
  definition: ZhixuDefinition,
  resolutionManifest?: DockResolutionManifest,
): SolidityRegisterPlanArgs {
  return toSolidityRegisterPlanArgs(
    compileZhixuOnchainHookPlan(definition, resolutionManifest),
  );
}
