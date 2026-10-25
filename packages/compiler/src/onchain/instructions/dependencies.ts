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
 * hook 依赖编译与依赖索引组装。
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

function buildOnchainDependencyIndex(
  compiledHooks: readonly OnchainCompiledHook[],
): Record<HexString, readonly HexString[]> {
  const index = new Map<HexString, HexString[]>();
  for (const hook of compiledHooks) {
    for (const dependency of hook.dependencies) {
      const hookIds = index.get(dependency.signalKey) ?? [];
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
