import { isRecord } from "./shape.js";
import { onchainSourceId } from "./hash/route.js";
import type {
  BirthChannel,
  OnchainCompiledHook,
} from "../types/index.js";

/**
 * 链轨出生通道派生：canonical 序首个 order-trigger hook 及其 positive 出生依赖
 * 决定 plan 的 birthChannel；entry 依赖自带 `<stageIdentifier>.str` 与自源
 * sourceId，不读 capability 表、不引入映射。编译附加与 artifact 边界重算共用
 * 本实现（派生规则只此一处）。
 */

function deriveBirthChannel(
  hooks: readonly unknown[],
): BirthChannel | undefined {
  const trigger = hooks.find(
    (hook): hook is Record<string, unknown> =>
      isRecord(hook) &&
      (hook.orderTriggerKind === "mint" || hook.orderTriggerKind === "dock"),
  );
  if (trigger === undefined) {
    return undefined;
  }
  const fallback: BirthChannel =
    trigger.orderTriggerKind === "mint" ? "mint" : "dock";
  const stageIdentifier = trigger.stageIdentifier;
  const dependencies = Array.isArray(trigger.dependencies)
    ? trigger.dependencies
    : [];
  const birthDependency = dependencies.find(
    (dependency): dependency is Record<string, unknown> =>
      isRecord(dependency) &&
      dependency.kind === "positive" &&
      typeof dependency.source === "string" &&
      typeof dependency.sourceId === "string" &&
      typeof dependency.signalName === "string" &&
      typeof dependency.signalId === "string",
  );
  if (typeof stageIdentifier !== "string" || birthDependency === undefined) {
    return fallback;
  }
  const isEntry =
    trigger.orderTriggerKind === "mint" &&
    birthDependency.signalName === `${stageIdentifier}.str` &&
    birthDependency.sourceId === onchainSourceId(birthDependency.source as string);
  return isEntry ? "entry" : fallback;
}

export function onchainBirthChannelOf(
  hooks: readonly OnchainCompiledHook[],
): BirthChannel | undefined {
  return deriveBirthChannel(hooks);
}

export function onchainBirthChannelIssues(
  value: Record<string, unknown>,
): readonly string[] {
  const hooks = Array.isArray(value.compiledHooks)
    ? value.compiledHooks
    : undefined;
  if (hooks === undefined) {
    return [];
  }
  const expected = deriveBirthChannel(hooks);
  if (expected === undefined) {
    return value.birthChannel === undefined
      ? []
      : [
          "birthChannel must be omitted when the plan declares no order-trigger hook "
            + "(there is no birth line to describe)",
        ];
  }
  if (value.birthChannel !== expected) {
    return [
      `birthChannel must be ${expected} — derived from the plan's first order-trigger hook `
        + "and its positive birth dependency; an entry birth is the stage's own "
        + "<stageIdentifier>.str fact, every other order trigger keeps its mint/dock channel",
    ];
  }
  return [];
}
