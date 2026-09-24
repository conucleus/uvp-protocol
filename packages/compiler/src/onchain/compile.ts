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
  type HookPlanArtifact,
  type OnchainCompiledAdmission,
  type OnchainHookPlanArtifact,
  type SignalCapability,
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
  // 适格面编译：IR admissions 条目 → 过滤档指令计划（orderTriggerKind
  // 恒 none：订阅原子沿用指令编译器的拒绝面，DELAY 放行——过滤档无
  // 出生路径）。admissionId = 被发射事实的 signalKey，合约适格存储按它
  // 寻址（提交路径只持有 (sourceId, signalId)，signalKey 是提交时可计算
  // 的唯一承诺键）；声明阶段的 source 从 signalCapabilities 解析
  // （sendSignals 声明恒产能力条目，relation=current 事实键在 plan 内
  // 唯一属主——同全名异 source 的错位声明在此暴露）。
  const admissions = compileSignalAdmissions(
    hookPlanArtifact.admissions,
    hookPlanArtifact.signalCapabilities,
  );
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
  // U2：出生通道键并集（mint 出生键 ∪ dock entrance 键）去重——编译入口
  // 与反序列化边界、合约注册门（DuplicateBirthChannelKey）三线同口径。
  const duplicateBirthKeyIssues = duplicateBirthChannelKeyIssues(compiledHooks);
  const dependencyCountIssues = planDependencyCountIssues(compiledHooks);
  const currentOrderFactKeyIssues = duplicateCurrentOrderFactKeyIssues(
    hookPlanArtifact.signalCapabilities.map((capability) => ({
      stage: capability.stageIdentifier,
      sourceId: onchainSourceId(capability.targetSource),
      signalId: onchainSignalId(capability.targetSignalName),
      isCurrentOrder: capability.targetOrderRelation === "current",
    })),
  );
  // 链轨接受域（UVPDockingModule 4.4 终态）：existing 路由与动态
  // （target:null）路由不再整体拒绝——静态路由（new/existing）全部进
  // dockRoutes，动态路由进 unresolvedDockRoutes 声明面（routeHash 目标槽
  // = 候选集 root，随 dockRoutesRoot 冻结）。链轨仍拒的形态收窄为：
  // 动态路由 orderMode=new（openDockedOrder 只按静态目标槽重算、无候选
  // 集回退，attachDockedOrder——唯一的动态消费方——钉 existing）。
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
  // 30 天延时上限等不能只在反序列化边界生效——否则手工/漂移的 IR 制品
  // 过 IR 校验后会在编译入口静默产出毒制品，交由 commitPlan revert。
  const hookShapeIssues: readonly string[] = compiledHooks.length === 0
    ? ["compiledHooks must not be empty (contract reverts EmptyPlan)"]
    : [
        ...validateOnchainCompiledHooks(compiledHooks, executorRoutes),
        ...canonicalOrderIssues(compiledHooks, hookOrderKey, "compiledHooks"),
      ];
  // 过滤档镜像预检（编译入口与反序列化边界同门）：hook 档非法而过滤档
  // 合法的形态（裸衰减根、Or 下/延时操作数内的否决位）必须在这里放行，
  // 任何把 hook 档锚点/位置闸混入适格面的漂移都在编译期暴露。
  const admissionShapeIssues: readonly string[] = [
    ...validateOnchainCompiledAdmissions(admissions),
    ...canonicalOrderIssues(admissions, admissionOrderKey, "admissions"),
  ];
  const preflightIssues = [
    ...crossStageIssues,
    ...materializationIssues,
    ...silentTriggerIssues,
    ...duplicateBirthKeyIssues,
    ...dependencyCountIssues,
    ...currentOrderFactKeyIssues,
    ...dockTrackIssues,
    ...unresolvedTrackIssues,
    ...hookShapeIssues,
    ...admissionShapeIssues,
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
  // 都在编译期暴露。dockRoutesRoot 是 finalize 冻结的最终根：静态叶 ∪
  // 动态叶（动态叶目标槽 = 候选集 root），IR 组装层同口径产根。
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
  // fail-closed：capabilitiesRoot 由 TS 侧从两表叶子重算并断言与 IR 侧
  // 一致（能力表/绑定表去重排序后的唯一树形态）。
  const soliditySelectorBindings = selectorBindings.map((binding) => ({
    selectorStageId: binding.selectorStageId,
    targetStageId: binding.targetStageId,
  }));
  const soliditySignalCapabilities = signalCapabilities.map((capability) => ({
    stageId: capability.stageId,
    targetSourceId: capability.targetSourceId,
    signalId: capability.signalId,
    targetOrderRelation: capability.targetOrderRelation === "current" ? (0 as const) : (1 as const),
  }));
  const capabilitiesRoot = capabilitiesRootOf(
    soliditySelectorBindings,
    soliditySignalCapabilities,
  );
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
    // 动态路由声明面（仅非空时入哈希与制品，与 IR 同约定）：planHash
    // 覆盖其全部字段（含候选清单与三项承诺）。
    ...(unresolvedDockRoutes === undefined
      ? {}
      : { unresolvedDockRoutes }),
    dockRoutesRoot: hookPlanArtifact.dockRoutesRoot,
    dockInterfaceRoot: hookPlanArtifact.dockInterfaceRoot,
    capabilitiesRoot,
    selectorBindings,
    signalCapabilities,
    admissions,
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

/**
 * IR admissions → 链轨适格面条目：指令经 compileHookInstructions
 * （orderTriggerKind=none 的过滤档路径），身份三元组 (admissionId,
 * stageId, signalId) 全部从声明重算——admissionId 占 CompactHook 的
 * hookId 槽（= 事实键 signalKey），signalId 占 hookName 槽（=
 * keccak(signalName)，hook 槽 word 布局的钩名位承载信号身份）。排序与
 * core 产物同键（stageIdentifier, signalName）。
 */
function compileSignalAdmissions(
  admissions: readonly CompiledHookPlanAdmission[],
  signalCapabilities: readonly SignalCapability[],
): OnchainCompiledAdmission[] {
  const sourceByDeclaredSignal = new Map<string, string>();
  for (const capability of signalCapabilities) {
    if (capability.targetOrderRelation !== "current") {
      continue;
    }
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
