import { canonicalize } from "@uvp-eth/canonical-json";
import { hashCanonical } from "../hash.js";
import { definitionUid, stripAnnotations } from "../identity.js";
import {
  COMPILER_NAME,
  COMPILER_VERSION,
  HOOK_PLAN_SCHEMA_VERSION,
  type HexString,
  type HookPlanArtifact,
  type ZhixuDefinition,
} from "../types/index.js";

/**
 * hook_plan shell 的链轨承诺层：uvp-core 只产出中性壳（无哈希、无派生身份），
 * 本模块在壳上计算 planId / planHash 并固化 artifact 字段集。
 */

export const HOOK_PLAN_ID_DOMAIN = "uvp:hook-plan-id:v1";
export const HOOK_PLAN_HASH_DOMAIN = "uvp:hook-plan-artifact:v1";

export interface HookPlanShell {
  readonly schemaVersion: typeof HOOK_PLAN_SCHEMA_VERSION;
  readonly zhixuName: string;
  readonly platform: unknown;
  readonly compiledHooks: readonly unknown[];
  readonly dependencyIndex: Record<string, readonly string[]>;
  readonly supplierRoutes: Record<string, unknown>;
  readonly selectedStageBindings: readonly unknown[];
  readonly signalCapabilities: readonly unknown[];
  readonly admissions: readonly unknown[];
}

export function normalizePlatformPreimage(platform: unknown): unknown {
  if (
    typeof platform !== "object" ||
    platform === null ||
    Array.isArray(platform)
  ) {
    return platform;
  }
  const record = platform as { params?: unknown };
  if (
    record.params === undefined ||
    typeof record.params !== "object" ||
    record.params === null ||
    Object.keys(record.params).length > 0
  ) {
    return platform;
  }
  const normalized = { ...(platform as Record<string, unknown>) };
  delete normalized.params;
  return normalized;
}

export function assembleChainTrackHookPlan(
  definition: ZhixuDefinition,
  shell: HookPlanShell,
): HookPlanArtifact {
  const zhixuId = definitionUid(definition);
  const platform = shell.platform as HookPlanArtifact["platform"];
  const payload = {
    schemaVersion: HOOK_PLAN_SCHEMA_VERSION,
    zhixuId,
    zhixuName: shell.zhixuName,
    platform,
    compiledHooks: shell.compiledHooks as HookPlanArtifact["compiledHooks"],
    dependencyIndex: shell.dependencyIndex,
    supplierRoutes: shell.supplierRoutes as HookPlanArtifact["supplierRoutes"],
    selectedStageBindings:
      shell.selectedStageBindings as HookPlanArtifact["selectedStageBindings"],
    signalCapabilities:
      shell.signalCapabilities as HookPlanArtifact["signalCapabilities"],
    admissions: shell.admissions as HookPlanArtifact["admissions"],
    source: canonicalize(stripAnnotations(definition)),
  };
  return {
    ...payload,
    planHash: hashCanonical(HOOK_PLAN_HASH_DOMAIN, payload),
  };
}

export function hookPlanPayloadForHash(
  artifact: Omit<HookPlanArtifact, "planHash">,
): Record<string, unknown> {
  return {
    schemaVersion: artifact.schemaVersion,
    zhixuId: artifact.zhixuId,
    zhixuName: artifact.zhixuName,
    platform: artifact.platform,
    compiledHooks: artifact.compiledHooks,
    dependencyIndex: artifact.dependencyIndex,
    supplierRoutes: artifact.supplierRoutes,
    selectedStageBindings: artifact.selectedStageBindings,
    signalCapabilities: artifact.signalCapabilities,
    admissions: artifact.admissions,
    source: artifact.source,
  };
}

export function hookPlanHashOf(
  artifact: Omit<HookPlanArtifact, "planHash">,
): HexString {
  return hashCanonical(HOOK_PLAN_HASH_DOMAIN, hookPlanPayloadForHash(artifact));
}
