import { compareCanonicalKey } from "../../hook-plan.js";
import { isRecord } from "../shape.js";
import type {
  OnchainCompiledAdmission,
  OnchainCompiledHook,
  OnchainExecutorRoute,
  OnchainSignalCapability,
  OnchainStageSelectorBinding,
} from "../../types/index.js";

/**
 * 编译产物的确定性排序口径（同一 plan 唯一数组形态）与制品边界的规范序
 * 检查；比较器复用根 hook-plan.ts 的 compareCanonicalKey（码点序 = Rust str Ord）。
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

function compareAdmissions(
  left: OnchainCompiledAdmission,
  right: OnchainCompiledAdmission,
): number {
  return (
    compareCanonicalKey(left.stageIdentifier, right.stageIdentifier) ||
    compareCanonicalKey(left.signalName, right.signalName) ||
    compareCanonicalKey(left.admissionId, right.admissionId)
  );
}

export {
  compareOnchainHooks,
  compareExecutorRoutes,
  compareSelectorBindings,
  compareSignalCapabilities,
  compareAdmissions,
};

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

function admissionOrderKey(admission: Record<string, unknown>): readonly string[] {
  return [
    String(admission.stageIdentifier),
    String(admission.signalName),
    String(admission.admissionId),
  ];
}

function executorCandidateOrderKey(
  candidate: Record<string, unknown>,
): readonly string[] {
  return [String(candidate.stageId), String(candidate.executor)];
}

export {
  canonicalOrderIssues,
  hookOrderKey,
  routeOrderKey,
  selectorBindingOrderKey,
  signalCapabilityOrderKey,
  admissionOrderKey,
  executorCandidateOrderKey,
};
