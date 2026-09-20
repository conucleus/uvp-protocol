import type { OnchainCompiledHook } from "../../types/index.js";

/**
 * 合约上限镜像与规模预检（自 onchain-hook-plan.ts 原样迁入）。
 */

// Mirrors UVPStateMachine.MAX_HOOK_DELAY_SECONDS (30 days): the contract
// reverts HookDelayTooLong above this bound, so the fail-closed artifact
// preflight must reject the same inputs instead of letting the transaction
// revert on-chain.
const MAX_ONCHAIN_HOOK_DELAY_SECONDS = 2_592_000;
// Mirrors UVPStateMachine.MAX_PLAN_DEPENDENCIES (1024): the contract reverts
// TooManyDependencies while registering the plan dependency index, so the
// preflight must reject plans with more than 1024 distinct dependency keys.
const MAX_PLAN_DEPENDENCIES = 1024;
// Documented cap on compiled signal capabilities (= the plan-wide total of
// sendSignals declarations). UVPPlanMetadataModule._registerSignalCapabilities
// writes one storage slot per capability at plan registration, so an
// oversized hand-signed table makes registration gas plan-controlled and
// unbounded; the contract reverts TooManySignalCapabilities at the same 256.
// Stage-ownership lookups are single-key owner-index reads
// (_signalStageId -> currentOrderFactStage), so the cap bounds registration
// cost, not per-submission queries. Rust uvp-core mirrors this cap.
const MAX_SIGNAL_CAPABILITIES = 256;
// Mirrors UVPPlanMetadataModule.MAX_SELECTOR_BINDINGS (M24): each binding
// costs ~90k gas in storage writes at finalize (binding struct + target-stage
// flag + key-list push), so an unbounded hand-signed table makes finalize
// plan-controlled gas (~324 bindings already exceed a 30M-gas block); the
// contract reverts TooManySelectorBindings at the same 128, keeping the
// full registration comfortably inside one block with >2x headroom.
const MAX_SELECTOR_BINDINGS = 128;

export {
  MAX_ONCHAIN_HOOK_DELAY_SECONDS,
  MAX_PLAN_DEPENDENCIES,
  MAX_SIGNAL_CAPABILITIES,
  MAX_SELECTOR_BINDINGS,
};

/**
 * E12 镜像：UVPStateMachine.commitPlan 对去重后的 dependency key 总数执行
 * MAX_PLAN_DEPENDENCIES=1024 上限（TooManyDependencies）——预检同口径拒绝。
 */
function planDependencyCountIssues(
  hooks: readonly OnchainCompiledHook[],
): readonly string[] {
  const keys = new Set<string>();
  for (const hook of hooks) {
    for (const dependency of hook.dependencies) {
      keys.add(dependency.signalKey);
    }
  }
  if (keys.size > MAX_PLAN_DEPENDENCIES) {
    return [
      `distinct dependency keys ${keys.size} exceed the contract limit ${MAX_PLAN_DEPENDENCIES} (commitPlan reverts TooManyDependencies)`,
    ];
  }
  return [];
}

/**
 * 能力表规模预检：sendSignals 声明总量（编译为 signalCapabilities）超过
 * MAX_SIGNAL_CAPABILITIES 时，UVPPlanMetadataModule 逐条写存储的注册循环
 * gas 随表规模无界增长（合约注册边界 revert TooManySignalCapabilities）
 * ——预检在编译/反序列化两个边界同口径拒绝。
 */
function signalCapabilityCountIssues(
  capabilities: readonly unknown[],
): readonly string[] {
  if (capabilities.length > MAX_SIGNAL_CAPABILITIES) {
    return [
      `signal capabilities ${capabilities.length} exceed the documented limit ${MAX_SIGNAL_CAPABILITIES} `
      + "(UVPPlanMetadataModule registers each capability with a storage write; unbounded plan-controlled registration gas)",
    ];
  }
  return [];
}

/**
 * 绑定表规模预检（M24）：selectorBindings（编译自 selectedStages）超过
 * MAX_SELECTOR_BINDINGS 时，finalizePlan 的逐条写存储注册循环 gas 随表
 * 规模无界增长（≈324 条在 30M block gas 内恒 OOG，planId 烧死在
 * committed 态）——预检与合约 finalize 边界（TooManySelectorBindings）
 * 同口径拒绝。
 */
function selectorBindingCountIssues(bindings: readonly unknown[]): readonly string[] {
  if (bindings.length > MAX_SELECTOR_BINDINGS) {
    return [
      `selector bindings ${bindings.length} exceed the documented limit ${MAX_SELECTOR_BINDINGS} `
        + "(UVPPlanMetadataModule registers each binding with storage writes; finalizePlan reverts "
        + "TooManySelectorBindings — unbounded plan-controlled registration gas)",
    ];
  }
  return [];
}

export { planDependencyCountIssues, signalCapabilityCountIssues, selectorBindingCountIssues };
