import { HookPlanCompilationError } from "../hook-plan.js";
import { compareStageFileWriters } from "./canonical/ordering.js";
import { onchainStageId } from "./hash/route.js";
import { expectClosedKeySet, expectHexHash, expectNonEmptyString, isHexHash, isRecord } from "./shape.js";
import type { OnchainStageFileWriter } from "../types/index.js";

/**
 * 阶段文件写入目标声明：从定义快照读取 `spec.stages[].fileWriteTargets`，生成
 * 计划级 (writerStageId, targetStageId) 明文段；定义级 DSL 语义由 uvp-core
 * analyze 校验，本模块只做链轨产物边界的形状、阶段存在性与 EVM 注册上限。
 */

export const MAX_FILE_WRITERS = 64;

const STAGE_FILE_WRITER_FIELDS: readonly string[] = [
  "targetStageIdentifier",
  "targetStageId",
  "writerStageIdentifier",
  "writerStageId",
];

export function compileStageFileWriters(
  source: unknown,
  compiledStageIdentifiers: ReadonlySet<string>,
): readonly OnchainStageFileWriter[] {
  const issues: string[] = [];
  const entries: OnchainStageFileWriter[] = [];
  const seen = new Set<string>();
  for (const stage of sourceStages(source)) {
    if (!isRecord(stage)) {
      continue;
    }
    const writerStageIdentifier =
      typeof stage.name === "string" ? stage.name : undefined;
    const declaredTargets = stage.fileWriteTargets;
    if (declaredTargets === undefined) {
      continue;
    }
    if (writerStageIdentifier === undefined) {
      issues.push(
        "a spec.stages[] entry carrying fileWriteTargets has no string stage name",
      );
      continue;
    }
    if (!Array.isArray(declaredTargets)) {
      issues.push(
        `stage ${writerStageIdentifier} fileWriteTargets must be an array of stage names`,
      );
      continue;
    }
    for (const targetStageIdentifier of declaredTargets) {
      if (
        typeof targetStageIdentifier !== "string" ||
        targetStageIdentifier.trim().length === 0
      ) {
        issues.push(
          `stage ${writerStageIdentifier} fileWriteTargets entries must be non-empty stage names`,
        );
        continue;
      }
      if (targetStageIdentifier === writerStageIdentifier) {
        issues.push(
          `stage ${writerStageIdentifier} lists itself in fileWriteTargets; the stage's own executor is implicit and a self leaf is not a capability`,
        );
        continue;
      }
      if (!compiledStageIdentifiers.has(writerStageIdentifier)) {
        issues.push(
          `stage ${writerStageIdentifier} carries fileWriteTargets but has no compiled hooks; an unmaterialized writer stage has no on-chain identity`,
        );
        break;
      }
      if (!compiledStageIdentifiers.has(targetStageIdentifier)) {
        issues.push(
          `stage ${writerStageIdentifier} names file write target ${targetStageIdentifier}, which has no compiled hooks in this plan`,
        );
        continue;
      }
      const targetStageId = onchainStageId(targetStageIdentifier);
      const writerStageId = onchainStageId(writerStageIdentifier);
      const key = `${writerStageId}:${targetStageId}`;
      if (seen.has(key)) {
        issues.push(
          `duplicate file write target capability ${writerStageIdentifier}->${targetStageIdentifier}`,
        );
        continue;
      }
      seen.add(key);
      entries.push({
        targetStageIdentifier,
        targetStageId,
        writerStageIdentifier,
        writerStageId,
      });
    }
  }
  if (entries.length > MAX_FILE_WRITERS) {
    issues.push(
      `plan declares ${entries.length} file writer pairs, above the ${MAX_FILE_WRITERS} cap the state machine accepts at commit`,
    );
  }
  if (issues.length > 0) {
    throw new HookPlanCompilationError(issues);
  }
  return entries.sort(compareStageFileWriters);
}

export function validateOnchainStageFileWriters(
  bindings: readonly unknown[],
  compiledStages: ReadonlySet<string>,
): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  const writersPerTarget = new Map<string, number>();
  if (bindings.length > MAX_FILE_WRITERS) {
    issues.push(
      `stageFileWriters declares ${bindings.length} pairs, above the ${MAX_FILE_WRITERS} cap the state machine accepts at commit`,
    );
  }
  for (const [index, binding] of bindings.entries()) {
    const prefix = `stageFileWriters[${index}]`;
    if (!isRecord(binding)) {
      issues.push(`${prefix} must be an object`);
      continue;
    }
    expectClosedKeySet(binding, STAGE_FILE_WRITER_FIELDS, prefix, issues);
    expectNonEmptyString(
      binding.targetStageIdentifier,
      `${prefix}.targetStageIdentifier`,
      issues,
    );
    expectNonEmptyString(
      binding.writerStageIdentifier,
      `${prefix}.writerStageIdentifier`,
      issues,
    );
    expectHexHash(binding.targetStageId, `${prefix}.targetStageId`, issues);
    expectHexHash(binding.writerStageId, `${prefix}.writerStageId`, issues);
    if (
      typeof binding.targetStageIdentifier === "string" &&
      binding.targetStageIdentifier === binding.writerStageIdentifier
    ) {
      issues.push(
        `${prefix} binds ${binding.targetStageIdentifier} to itself; the stage's own executor is implicit and a self leaf is not a capability`,
      );
    }
    if (
      typeof binding.targetStageIdentifier === "string" &&
      compiledStages.size > 0 &&
      !compiledStages.has(binding.targetStageIdentifier)
    ) {
      issues.push(
        `${prefix}.targetStageIdentifier must be a stage with compiled hooks in this plan`,
      );
    }
    if (
      typeof binding.writerStageIdentifier === "string" &&
      compiledStages.size > 0 &&
      !compiledStages.has(binding.writerStageIdentifier)
    ) {
      issues.push(
        `${prefix}.writerStageIdentifier must be a stage with compiled hooks in this plan`,
      );
    }
    if (
      typeof binding.targetStageIdentifier === "string" &&
      typeof binding.targetStageId === "string" &&
      binding.targetStageId !== onchainStageId(binding.targetStageIdentifier)
    ) {
      issues.push(`${prefix}.targetStageId must be keccak256(targetStageIdentifier)`);
    }
    if (
      typeof binding.writerStageIdentifier === "string" &&
      typeof binding.writerStageId === "string" &&
      binding.writerStageId !== onchainStageId(binding.writerStageIdentifier)
    ) {
      issues.push(`${prefix}.writerStageId must be keccak256(writerStageIdentifier)`);
    }
    if (isHexHash(binding.targetStageId) && isHexHash(binding.writerStageId)) {
      const key = `${binding.targetStageId}:${binding.writerStageId}`;
      if (seen.has(key)) {
        issues.push(`duplicate file writer capability ${key}`);
      }
      seen.add(key);
    }
  }
  return issues;
}

function sourceStages(source: unknown): readonly unknown[] {
  if (!isRecord(source)) {
    return [];
  }
  const spec = source.spec;
  if (!isRecord(spec) || !Array.isArray(spec.stages)) {
    return [];
  }
  return spec.stages;
}
