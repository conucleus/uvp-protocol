import type { HookDependency } from "@uvp-eth/hook-core";
import { compareCanonicalKey } from "../../hook-plan.js";
import {
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
} from "../hash/route.js";
import type {
  HexString,
  OnchainCompiledHook,
  OnchainHookDependency,
} from "../../types/index.js";

/**
 * hook 依赖编译与依赖索引组装（自 onchain-hook-plan.ts 原样迁入）。
 */

function compileDependency(dependency: HookDependency): OnchainHookDependency {
  const sourceId = onchainSourceId(dependency.source);
  const signalId = onchainSignalId(dependency.signalName);
  return {
    kind: dependency.kind,
    source: dependency.source,
    signalName: dependency.signalName,
    sourceId,
    signalId,
    signalKey: onchainSignalKey(sourceId, signalId),
    ...(dependency.delaySeconds !== undefined
      ? { delaySeconds: dependency.delaySeconds }
      : {}),
  };
}

/**
 * Per-key hookIds MUST follow the compiledHooks (= commitPlan calldata) order:
 * UVPStateMachine._registerPlanHook pushes `input.hookId` while scanning the
 * submitted hooks array, and the replay oracle replays the per-key array
 * positionally. Sorting by hookId (keccak order) forks the contract's
 * dependencyIndex and flips the oracle's event pairing whenever the two
 * orders disagree on a key with ≥2 same-partition (trigger/watcher) hooks.
 */
function buildOnchainDependencyIndex(
  compiledHooks: readonly OnchainCompiledHook[],
): Record<HexString, readonly HexString[]> {
  const index = new Map<HexString, HexString[]>();
  for (const hook of compiledHooks) {
    for (const dependency of hook.dependencies) {
      const hookIds = index.get(dependency.signalKey) ?? [];
      // Mirror the contract's per-hook dependencyKey dedup: one hook can only
      // register once per key.
      if (!hookIds.includes(hook.hookId)) {
        hookIds.push(hook.hookId);
      }
      index.set(dependency.signalKey, hookIds);
    }
  }

  const output: Record<HexString, readonly HexString[]> = {};
  for (const [signalKey, hookIds] of [...index.entries()].sort(
    ([left], [right]) => compareCanonicalKey(left, right),
  )) {
    output[signalKey] = hookIds;
  }
  return output;
}

export { compileDependency, buildOnchainDependencyIndex };
