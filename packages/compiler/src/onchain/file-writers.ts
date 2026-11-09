import { HookPlanCompilationError } from "../hook-plan.js";
import { fileWriterLeaf } from "./capabilities-root.js";
import { compareStageFileWriters } from "./canonical/ordering.js";
import { onchainStageId } from "./hash/route.js";
import { expectClosedKeySet, expectHexHash, expectNonEmptyString, isHexHash, isRecord } from "./shape.js";
import type { OnchainStageFileWriter } from "../types/index.js";

/**
 * 阶段文件写入者能力叶：从定义快照读取 `spec.stages[].fileWriters`，生成
 * (targetStageId, writerStageId) 叶并入 capabilitiesRoot；DSL 语义校验
 * （存在/自引用/去重/上限的具名错误）归 uvp-core，本模块只做链轨产物边界
 * 的形状与承诺重算。
 */

export const MAX_FILE_WRITERS_PER_STAGE = 8;

const STAGE_FILE_WRITER_FIELDS: readonly string[] = [
  "targetStageIdentifier",
  "targetStageId",
  "writerStageIdentifier",
  "writerStageId",
  "fileWriterLeaf",
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
    const targetStageIdentifier =
      typeof stage.name === "string" ? stage.name : undefined;
    const declaredWriters = stage.fileWriters;
    if (declaredWriters === undefined) {
      continue;
    }
    if (targetStageIdentifier === undefined) {
      issues.push(
        "a spec.stages[] entry carrying fileWriters has no string stage name",
      );
      continue;
    }
    if (!Array.isArray(declaredWriters)) {
      issues.push(
        `stage ${targetStageIdentifier} fileWriters must be an array of stage names`,
      );
      continue;
    }
    if (declaredWriters.length > MAX_FILE_WRITERS_PER_STAGE) {
      issues.push(
        `stage ${targetStageIdentifier} declares ${declaredWriters.length} fileWriters, above the ${MAX_FILE_WRITERS_PER_STAGE} capability leaves a stage may grant`,
      );
      continue;
    }
    for (const writerStageIdentifier of declaredWriters) {
      if (
        typeof writerStageIdentifier !== "string" ||
        writerStageIdentifier.trim().length === 0
      ) {
        issues.push(
          `stage ${targetStageIdentifier} fileWriters entries must be non-empty stage names`,
        );
        continue;
      }
      if (writerStageIdentifier === targetStageIdentifier) {
        issues.push(
          `stage ${targetStageIdentifier} lists itself in fileWriters; the stage's own executor is implicit and a self leaf is not a capability`,
        );
        continue;
      }
      if (!compiledStageIdentifiers.has(targetStageIdentifier)) {
        issues.push(
          `stage ${targetStageIdentifier} carries fileWriters but has no compiled hooks; an unmaterialized target stage has no on-chain file map`,
        );
        break;
      }
      if (!compiledStageIdentifiers.has(writerStageIdentifier)) {
        issues.push(
          `stage ${targetStageIdentifier} names file writer ${writerStageIdentifier}, which has no compiled hooks in this plan`,
        );
        continue;
      }
      const targetStageId = onchainStageId(targetStageIdentifier);
      const writerStageId = onchainStageId(writerStageIdentifier);
      const key = `${targetStageId}:${writerStageId}`;
      if (seen.has(key)) {
        issues.push(
          `duplicate file writer capability ${targetStageIdentifier}->${writerStageIdentifier}`,
        );
        continue;
      }
      seen.add(key);
      entries.push({
        targetStageIdentifier,
        targetStageId,
        writerStageIdentifier,
        writerStageId,
        fileWriterLeaf: fileWriterLeaf(targetStageId, writerStageId),
      });
    }
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
    expectHexHash(binding.fileWriterLeaf, `${prefix}.fileWriterLeaf`, issues);
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
    if (
      isHexHash(binding.targetStageId) &&
      isHexHash(binding.writerStageId) &&
      binding.fileWriterLeaf !== fileWriterLeaf(binding.targetStageId, binding.writerStageId)
    ) {
      issues.push(
        `${prefix}.fileWriterLeaf must match keccak256("UVP_FILE_WRITER_V1", targetStageId, writerStageId)`,
      );
    }
    if (isHexHash(binding.targetStageId) && isHexHash(binding.writerStageId)) {
      const key = `${binding.targetStageId}:${binding.writerStageId}`;
      if (seen.has(key)) {
        issues.push(`duplicate file writer capability ${key}`);
      }
      seen.add(key);
      const current = writersPerTarget.get(binding.targetStageId) ?? 0;
      writersPerTarget.set(binding.targetStageId, current + 1);
      if (current + 1 === MAX_FILE_WRITERS_PER_STAGE + 1) {
        issues.push(
          `${prefix} exceeds the ${MAX_FILE_WRITERS_PER_STAGE} file writer capabilities bound for one target stage`,
        );
      }
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
