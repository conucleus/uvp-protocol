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
// 能力表/绑定表无规模上限：链上只承诺一棵 capabilitiesRoot（finalize 与
// 表规模脱钩），成员资格由使用方携 proof 验证；表规模的现实边界由编译
// 产物与 calldata 承载能力约束。

export { MAX_ONCHAIN_HOOK_DELAY_SECONDS, MAX_PLAN_DEPENDENCIES };

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

export { planDependencyCountIssues };
