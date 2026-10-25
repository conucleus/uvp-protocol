import type { OnchainCompiledHook } from "../../types/index.js";

/**
 * 合约上限镜像与规模预检。
 */

const MAX_ONCHAIN_HOOK_DELAY_SECONDS = 2_592_000;
const MAX_PLAN_DEPENDENCIES = 1024;
const MAX_HOOKS_PER_DEPENDENCY_KEY = 16;

export { MAX_ONCHAIN_HOOK_DELAY_SECONDS, MAX_PLAN_DEPENDENCIES, MAX_HOOKS_PER_DEPENDENCY_KEY };

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
