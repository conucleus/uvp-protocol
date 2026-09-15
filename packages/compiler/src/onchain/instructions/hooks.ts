import type {
  HookConditionAst,
  HookExpressionAst,
} from "@uvp-eth/hook-core";
import { HookPlanCompilationError } from "../../hook-plan.js";
import { OnchainHookPlanArtifactValidationError } from "../validate/artifact.js";
import {
  FILE_TYPES,
  selectorBindingKey,
  SUPPLIER_TYPES,
} from "../validate/capabilities.js";
import {
  compareSelectorBindings,
  compareSignalCapabilities,
} from "../canonical/ordering.js";
import {
  ZERO_HASH,
  opaqueContentHash,
  onchainRouteHash,
  onchainRouteId,
  onchainSelectorBindingHash,
  onchainSignalCapabilityHash,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
  routeHashFromDigests,
} from "../hash/route.js";
import { assertNever } from "../shape.js";
import type {
  HookPlanExecutorRoute,
  OnchainExecutorRoute,
  OnchainExecutorRouteRef,
  OnchainHookInstruction,
  OnchainSignalCapability,
  OnchainStageSelectorBinding,
  OrderTriggerKind,
  SelectedStageBinding,
  SignalCapability,
} from "../../types/index.js";

/**
 * hook 编译转换（自 onchain-hook-plan.ts 原样迁入）：条件 AST → 栈机指令、
 * hook 周边声明（executor route / selector binding / signal capability）→
 * 链轨形态。闭集词表与去重键复用 validate/capabilities，承诺派生复用
 * hash/route，排序比较子复用 canonical/ordering。
 */

function compileHookInstructions(
  ast: HookExpressionAst,
  stageIdentifier: string,
  options: { readonly orderTriggerKind: OrderTriggerKind },
): readonly OnchainHookInstruction[] {
  return compileConditionInstructions(ast.condition, ast.source, stageIdentifier, options);
}

function compileConditionInstructions(
  condition: HookConditionAst,
  source: string,
  stageIdentifier: string,
  options: { readonly orderTriggerKind: OrderTriggerKind },
): readonly OnchainHookInstruction[] {
  switch (condition.kind) {
    case "signal":
      return [signalInstruction(source, condition.signalName)];
    case "subscription":
      // 出生订阅上链的现行三线口径（只描述现状，行为不动）：
      // - outside 出生（triggerOrderFromOutsideFor）：出生事实记录在【新
      //   订单】上，mint hook 在新订单内求值并物化新订单的阶段；
      // - order-link 出生（triggerOrderFromSignalFromModule）：新单 plan 的
      //   trigger hook 定义只用来【预检】origin 订单的信号状态
      //   （_requireTriggerHookReadyForOrder），随后直接标记 Ready 并物化
      //   【新订单】的阶段——源订单只被读取，绝不被链接路径求值或物化；
      // - dock 出生（openDockedOrder）：entrance 事实由模块写入新订单后
      //   标记 Ready。
      // 编译为一条 SIGNAL 指令即可，链上不存在独立的订阅投递子系统。非出
      // 生阶段（route=fanin 按类扇入 / 按单路由）的订阅是云侧运行时投递语
      // 义，仍不上链。
      if (options.orderTriggerKind === "none") {
        throw new HookPlanCompilationError([
          `on-chain HookPlan only supports subscription entries on order-trigger hooks `
          + `(::ANCHOR(@${condition.source}::${condition.signal}) in stage "${source}"); `
          + "non-birth subscriptions are cloud-side runtime deliveries "
          + "(see uvp-core docs/specs/subscription-mint-spec.md)"
        ]);
      }
      return [signalInstruction(condition.source, condition.signal)];
    case "not":
      return [
        ...compileConditionInstructions(condition.expr, source, stageIdentifier, options),
        { op: "NOT" },
      ];
    case "and":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source, stageIdentifier, options),
        ),
        { op: "AND", arity: condition.terms.length },
      ];
    case "or":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source, stageIdentifier, options),
        ),
        { op: "OR", arity: condition.terms.length },
      ];
    case "delay":
      // order-trigger hook 内禁止 DELAY（_validateHook 镜像，产出侧第一
      // 道）：出生事实与订单创建同笔交易，Delay(SIGNAL) 必得 Wait，出生
      // 路径永久 InvalidTriggerHook。
      if (options.orderTriggerKind !== "none") {
        throw new HookPlanCompilationError([
          `on-chain order-trigger hook (${options.orderTriggerKind}) must not contain DELAY `
          + `(@${source}::…+${condition.durationSeconds}s); birth facts settle at order creation `
          + "(contract _validateHook reverts InvalidInstruction)",
        ]);
      }
      return [
        ...compileConditionInstructions(condition.expr, source, stageIdentifier, options),
        { op: "DELAY", delaySeconds: condition.durationSeconds },
      ];
    default:
      assertNever(condition);
  }
}

function signalInstruction(
  source: string,
  signalName: string,
): OnchainHookInstruction {
  const sourceId = onchainSourceId(source);
  const signalId = onchainSignalId(signalName);
  return {
    op: "SIGNAL",
    source,
    signalName,
    sourceId,
    signalId,
    signalKey: onchainSignalKey(sourceId, signalId),
  };
}

function compileExecutorRoute(
  route: HookPlanExecutorRoute,
): OnchainExecutorRoute {
  // 与 Rust 编译入口同口径：supplierID 拒空白（不只是空串）——空白 id 是
  // "有值"的假形态，烧进 executorHash 后消费侧无法寻址执行者。
  if (
    route.executor.supplierID === undefined ||
    route.executor.supplierID.trim().length === 0
  ) {
    throw new HookPlanCompilationError([
      `executor route "${route.stageIdentifier}" (supplierType=${String(route.executor.supplierType)}) is missing a non-empty executor.supplierID`,
    ]);
  }
  // supplierType 闭集（rule executor-supplier-type-closed-enum 的链轨编译
  // 入口镜像）：闭集外字符串经 executorHash 进链上承诺后无合约守卫可拦。
  const supplierType = String(route.executor.supplierType);
  if (!SUPPLIER_TYPES.includes(supplierType.trim())) {
    throw new HookPlanCompilationError([
      `executor route "${route.stageIdentifier}" supplierType must be one of ${SUPPLIER_TYPES.join("|")} (case-sensitive), received ${JSON.stringify(supplierType)}`,
    ]);
  }
  // fileType 闭集（与云侧编译入口同集）：fileResources 进 resourcesHash
  // 承诺，拼错的 fileType 是确定性输入缺陷，不静默成承诺内容。
  if (route.fileResources !== undefined) {
    for (const [key, resource] of Object.entries(route.fileResources)) {
      if (!FILE_TYPES.includes(String(resource.fileType))) {
        throw new HookPlanCompilationError([
          `executor route "${route.stageIdentifier}" fileResources[${JSON.stringify(key)}].fileType must be one of ${FILE_TYPES.join("|")}, received ${JSON.stringify(resource.fileType)}`,
        ]);
      }
    }
  }
  const executorHash = opaqueContentHash(route.executor);
  const resourcesHash =
    route.fileResources === undefined ? ZERO_HASH : opaqueContentHash(route.fileResources);
  return {
    routeId: onchainRouteId(route.stageIdentifier),
    stageId: onchainStageId(route.stageIdentifier),
    stageIdentifier: route.stageIdentifier,
    executorType: String(route.executor.supplierType),
    executorId: route.executor.supplierID,
    executorHash,
    resourcesHash,
    routeHash: routeHashFromDigests(
      onchainStageId(route.stageIdentifier),
      route.stageIdentifier,
      executorHash,
      resourcesHash,
    ),
  };
}

function compileSelectorBindings(
  bindings: readonly SelectedStageBinding[],
): readonly OnchainStageSelectorBinding[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  const compiled: OnchainStageSelectorBinding[] = [];

  for (const binding of bindings) {
    const selectorStageId = onchainStageId(binding.selectorStageIdentifier);
    const targetStageId = onchainStageId(binding.targetStageIdentifier);
    const bindingKey = selectorBindingKey(selectorStageId, targetStageId);
    if (seen.has(bindingKey)) {
      issues.push(
        `duplicate selector binding ${binding.selectorStageIdentifier}->${binding.targetStageIdentifier}`,
      );
      continue;
    }
    seen.add(bindingKey);
    compiled.push({
      selectorStageIdentifier: binding.selectorStageIdentifier,
      targetStageIdentifier: binding.targetStageIdentifier,
      selectorStageId,
      targetStageId,
      bindingHash: onchainSelectorBindingHash(selectorStageId, targetStageId),
    });
  }

  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }

  return compiled.sort(compareSelectorBindings);
}

function compileSignalCapabilities(
  capabilities: readonly SignalCapability[],
): readonly OnchainSignalCapability[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  const compiled: OnchainSignalCapability[] = [];
  for (const capability of capabilities) {
    const stageId = onchainStageId(capability.stageIdentifier);
    const targetSourceId = onchainSourceId(capability.targetSource);
    const signalId = onchainSignalId(capability.targetSignalName);
    const key = [
      stageId,
      targetSourceId,
      signalId,
      capability.targetOrderRelation,
    ].join("\u0000");
    if (seen.has(key)) {
      issues.push(
        `duplicate signal capability ${capability.stageIdentifier}->${capability.targetSource}::${capability.targetSignalName}`,
      );
      continue;
    }
    seen.add(key);
    compiled.push({
      stageIdentifier: capability.stageIdentifier,
      stageId,
      source: capability.source,
      declaredSignal: capability.declaredSignal,
      targetSource: capability.targetSource,
      targetSourceId,
      targetSignalName: capability.targetSignalName,
      signalId,
      targetOrderRelation: capability.targetOrderRelation,
      capabilityHash: onchainSignalCapabilityHash(
        stageId,
        targetSourceId,
        signalId,
        capability.targetOrderRelation,
      ),
    });
  }
  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }
  return compiled.sort(compareSignalCapabilities);
}

function routeRefForRoute(
  route: HookPlanExecutorRoute,
): OnchainExecutorRouteRef {
  return {
    routeId: onchainRouteId(route.stageIdentifier),
    stageId: onchainStageId(route.stageIdentifier),
    routeHash: onchainRouteHash(route),
  };
}

export {
  compileHookInstructions,
  compileExecutorRoute,
  compileSelectorBindings,
  compileSignalCapabilities,
  routeRefForRoute,
};
