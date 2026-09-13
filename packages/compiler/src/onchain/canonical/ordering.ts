import { compareCanonicalKey } from "../../hook-plan.js";
import { isRecord } from "../shape.js";
import type {
  OnchainCompiledHook,
  OnchainExecutorRoute,
  OnchainSignalCapability,
  OnchainStageSelectorBinding,
} from "../../types/index.js";

/**
 * 规范排序（自 onchain-hook-plan.ts 原样迁入）：
 * - compareOnchainHooks / compareExecutorRoutes / compareSelectorBindings /
 *   compareSignalCapabilities 是编译产物的确定性排序口径（同一 plan 只有
 *   唯一数组形态）；
 * - canonicalOrderIssues 是制品边界的规范序检查，键列与编译侧排序比较子
 *   同源，相邻逆序即报 issue。
 * 比较器全部复用根 hook-plan.ts 的 compareCanonicalKey（码点序 = Rust
 * str Ord），本文件不复制排序实现。
 */

function compareOnchainHooks(
  left: OnchainCompiledHook,
  right: OnchainCompiledHook,
): number {
  return (
    compareCanonicalKey(left.stageIdentifier, right.stageIdentifier) ||
    compareCanonicalKey(left.hookName, right.hookName) ||
    compareCanonicalKey(left.hookId, right.hookId)
  );
}

function compareExecutorRoutes(
  left: OnchainExecutorRoute,
  right: OnchainExecutorRoute,
): number {
  return (
    compareCanonicalKey(left.stageIdentifier, right.stageIdentifier) ||
    compareCanonicalKey(left.routeId, right.routeId)
  );
}

function compareSelectorBindings(
  left: OnchainStageSelectorBinding,
  right: OnchainStageSelectorBinding,
): number {
  return (
    compareCanonicalKey(left.selectorStageId, right.selectorStageId) ||
    compareCanonicalKey(left.targetStageId, right.targetStageId) ||
    compareCanonicalKey(left.bindingHash, right.bindingHash)
  );
}

function compareSignalCapabilities(
  left: OnchainSignalCapability,
  right: OnchainSignalCapability,
): number {
  return (
    compareCanonicalKey(left.stageId, right.stageId) ||
    compareCanonicalKey(left.targetSourceId, right.targetSourceId) ||
    compareCanonicalKey(left.signalId, right.signalId) ||
    compareCanonicalKey(left.targetOrderRelation, right.targetOrderRelation) ||
    compareCanonicalKey(left.capabilityHash, right.capabilityHash)
  );
}

export {
  compareOnchainHooks,
  compareExecutorRoutes,
  compareSelectorBindings,
  compareSignalCapabilities,
};

/**
 * 制品边界的规范序检查：键列与编译侧排序比较子同源（compareOnchainHooks
 * 等），相邻逆序即报 issue——重排数组后重签 planHash 的制品不再被放行，
 * 同一 plan 保持唯一数组形态（内容寻址前提）。
 */
function canonicalOrderIssues(
  items: readonly unknown[],
  keyOf: (item: Record<string, unknown>) => readonly string[],
  label: string,
): readonly string[] {
  const issues: string[] = [];
  let previous: readonly string[] | undefined;
  for (const [index, item] of items.entries()) {
    if (!isRecord(item)) {
      continue;
    }
    const key = keyOf(item);
    if (previous !== undefined) {
      let diverged = false;
      for (let position = 0; position < previous.length; position += 1) {
        const order = compareCanonicalKey(
          previous[position] as string,
          key[position] as string,
        );
        if (order > 0) {
          diverged = true;
          break;
        }
        if (order < 0) {
          break;
        }
      }
      if (diverged) {
        issues.push(
          `${label}[${index}] breaks the canonical order (${key.join(" < ")} must not precede ${(previous as readonly string[]).join(" < ")}); re-sort with the compiler's ordering before serializing`,
        );
      }
    }
    previous = key;
  }
  return issues;
}

function hookOrderKey(hook: Record<string, unknown>): readonly string[] {
  return [String(hook.stageIdentifier), String(hook.hookName), String(hook.hookId)];
}

function routeOrderKey(route: Record<string, unknown>): readonly string[] {
  return [String(route.stageIdentifier), String(route.routeId)];
}

function selectorBindingOrderKey(
  binding: Record<string, unknown>,
): readonly string[] {
  return [String(binding.selectorStageId), String(binding.targetStageId), String(binding.bindingHash)];
}

function signalCapabilityOrderKey(
  capability: Record<string, unknown>,
): readonly string[] {
  return [
    String(capability.stageId),
    String(capability.targetSourceId),
    String(capability.signalId),
    String(capability.targetOrderRelation),
    String(capability.capabilityHash),
  ];
}

export {
  canonicalOrderIssues,
  hookOrderKey,
  routeOrderKey,
  selectorBindingOrderKey,
  signalCapabilityOrderKey,
};
