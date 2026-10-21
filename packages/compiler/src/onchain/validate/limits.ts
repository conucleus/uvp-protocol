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
// 单一依赖键（signalKey）可挂的 hook 数上限（与合约同名常量同值同批）：
// UVPStateMachine 对某键的 dependencyIndex 全量循环求值，一键挂 N 个 hook
// 让该事实每次提交 O(N) 乃至 OOG——per-key 扇出与总键数是两个独立爆炸面。
const MAX_HOOKS_PER_DEPENDENCY_KEY = 16;
// 能力表/绑定表无规模上限：链上只承诺一棵 capabilitiesRoot（finalize 与
// 表规模脱钩），成员资格由使用方携 proof 验证；表规模的现实边界由编译
// 产物与 calldata 承载能力约束。

export { MAX_ONCHAIN_HOOK_DELAY_SECONDS, MAX_PLAN_DEPENDENCIES, MAX_HOOKS_PER_DEPENDENCY_KEY };

/**
 * E12 镜像：UVPStateMachine.commitPlan 对去重后的 dependency key 总数执行
 * MAX_PLAN_DEPENDENCIES=1024 上限（TooManyDependencies）——预检同口径拒绝；
 * 同时对每个依赖键挂载的 hook 数执行 MAX_HOOKS_PER_DEPENDENCY_KEY 上限
 * （依赖键求值面 per-key 扇出闸）。
 */
function planDependencyCountIssues(
  hooks: readonly OnchainCompiledHook[],
): readonly string[] {
  const keys = new Set<string>();
  const hooksPerKey = new Map<string, Set<string>>();
  for (const hook of hooks) {
    for (const dependency of hook.dependencies) {
      keys.add(dependency.signalKey);
      const hookIds = hooksPerKey.get(dependency.signalKey) ?? new Set<string>();
      hookIds.add(hook.hookId);
      hooksPerKey.set(dependency.signalKey, hookIds);
    }
  }
  if (keys.size > MAX_PLAN_DEPENDENCIES) {
    return [
      `distinct dependency keys ${keys.size} exceed the contract limit ${MAX_PLAN_DEPENDENCIES} (commitPlan reverts TooManyDependencies)`,
    ];
  }
  for (const [signalKey, hookIds] of hooksPerKey) {
    if (hookIds.size > MAX_HOOKS_PER_DEPENDENCY_KEY) {
      return [
        `dependency key ${signalKey} fans out to ${hookIds.size} hooks, exceeding the per-key limit ${MAX_HOOKS_PER_DEPENDENCY_KEY} (the contract evaluates every hook hanging off a dependency key on each fact submission; unbounded fan-out makes each submission O(N))`,
      ];
    }
  }
  return [];
}

export { planDependencyCountIssues };
