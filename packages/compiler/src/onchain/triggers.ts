import { HookPlanCompilationError } from "../hook-plan.js";
import { isHexHash, isRecord } from "./shape.js";
import type {
  OnchainCompiledHook,
  OnchainHookDependency,
  OnchainPlanTrigger,
} from "../types/index.js";

/**
 * 计划出生线枚举：每条 order-trigger hook 的单一正向依赖即出生事实；编译组装
 * 与 artifact 边界重算共用本派生（派生规则只此一处）。
 */

function singlePositiveDependencyOf(
  dependencies: readonly OnchainHookDependency[],
): OnchainHookDependency | undefined {
  const positive = dependencies.filter(
    (dependency) => dependency.kind === "positive",
  );
  return positive.length === 1 ? positive[0] : undefined;
}

function onchainPlanTriggersOf(
  hooks: readonly OnchainCompiledHook[],
): readonly OnchainPlanTrigger[] {
  const triggers: OnchainPlanTrigger[] = [];
  for (const hook of hooks) {
    if (hook.orderTriggerKind === "none") {
      continue;
    }
    const birthDependency = singlePositiveDependencyOf(hook.dependencies);
    if (birthDependency === undefined) {
      throw new HookPlanCompilationError([
        `order-trigger hook ${hook.stageIdentifier}#${hook.hookName} must carry exactly one positive dependency `
          + "(its birth fact); the trigger enumeration elects the fact a birth submission writes, "
          + "and the contract receives its (sourceId, signalId) explicitly",
      ]);
    }
    triggers.push({
      hookId: hook.hookId,
      stageIdentifier: hook.stageIdentifier,
      stageId: hook.stageId,
      hookName: hook.hookName,
      orderTriggerKind: hook.orderTriggerKind,
      source: birthDependency.source,
      signalName: birthDependency.signalName,
      sourceId: birthDependency.sourceId,
      signalId: birthDependency.signalId,
    });
  }
  return triggers;
}

function onchainPlanTriggerIssues(
  value: Record<string, unknown>,
): readonly string[] {
  const hooks = Array.isArray(value.compiledHooks)
    ? value.compiledHooks
    : undefined;
  if (hooks === undefined) {
    return [];
  }
  const issues: string[] = [];
  const expected: OnchainPlanTrigger[] = [];
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      (hook.orderTriggerKind !== "trigger" && hook.orderTriggerKind !== "dock")
    ) {
      continue;
    }
    if (
      !isHexHash(hook.hookId) ||
      typeof hook.stageIdentifier !== "string" ||
      !isHexHash(hook.stageId) ||
      typeof hook.hookName !== "string"
    ) {
      continue;
    }
    const dependencies = (Array.isArray(hook.dependencies) ? hook.dependencies : [])
      .filter(
        (dependency): dependency is OnchainHookDependency =>
          isRecord(dependency) &&
          (dependency.kind === "positive" ||
            dependency.kind === "negative" ||
            dependency.kind === "timer") &&
          typeof dependency.source === "string" &&
          typeof dependency.signalName === "string" &&
          isHexHash(dependency.sourceId) &&
          isHexHash(dependency.signalId) &&
          isHexHash(dependency.signalKey),
      );
    const label = `${hook.stageIdentifier}#${hook.hookName}`;
    const birthDependency = singlePositiveDependencyOf(dependencies);
    if (birthDependency === undefined) {
      issues.push(
        `order-trigger hook ${label} must carry exactly one positive dependency `
          + `(its birth fact); the trigger enumeration cannot elect a birth fact`,
      );
      continue;
    }
    expected.push({
      hookId: hook.hookId,
      stageIdentifier: hook.stageIdentifier,
      stageId: hook.stageId,
      hookName: hook.hookName,
      orderTriggerKind: hook.orderTriggerKind,
      source: birthDependency.source,
      signalName: birthDependency.signalName,
      sourceId: birthDependency.sourceId,
      signalId: birthDependency.signalId,
    });
  }
  const declared = value.triggers;
  if (!Array.isArray(declared)) {
    return [
      ...issues,
      "triggers must be an array enumerating the plan's order-trigger hooks "
        + "(write [] when the plan declares none)",
    ];
  }
  const mismatch =
    declared.length !== expected.length ||
    declared.some(
      (entry, index) =>
        !sameTrigger(entry, expected[index] as OnchainPlanTrigger),
    );
  if (mismatch) {
    issues.push(
      "triggers must enumerate every order-trigger hook of compiledHooks in canonical hook order, "
        + "each entry derived from that hook's single positive dependency; a missing, surplus, reordered, "
        + "or tampered entry is rejected",
    );
  }
  return issues;
}

function sameTrigger(declared: unknown, expected: OnchainPlanTrigger): boolean {
  if (!isRecord(declared)) {
    return false;
  }
  return (
    declared.hookId === expected.hookId &&
    declared.stageIdentifier === expected.stageIdentifier &&
    declared.stageId === expected.stageId &&
    declared.hookName === expected.hookName &&
    declared.orderTriggerKind === expected.orderTriggerKind &&
    declared.source === expected.source &&
    declared.signalName === expected.signalName &&
    declared.sourceId === expected.sourceId &&
    declared.signalId === expected.signalId
  );
}

export { onchainPlanTriggerIssues, onchainPlanTriggersOf };
