import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
  HookPlanCompilationError,
  type ZhixuDefinition,
} from "../src/index.js";

/**
 * 链轨 hook_plan lowering 的 1:1 迁移（uvp-core tests.rs 链半）：trigger hook
 * 合成、hook 装饰（orderTriggerKind/emitReady/route）与 dependencyIndex。
 * 共享校验、负例、capabilities/admissions 归 uvp-core analyze，不在本文件重复。
 */

function triggerDefinition(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "trigger_entry" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "entry-core" },
      stages: [
        {
          name: "entry",
          source: "customer",
          receiveSignals: { PLACE: "customer::entry.seed" },
          sendSignals: [{ name: "str", trigger: true }, { name: "ack", trigger: true }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "journey-executor",
          },
        },
      ],
    },
  };
}

test("trigger signals lower to order-trigger hooks alongside receive hooks", () => {
  const onchain = compileZhixuOnchainHookPlan(triggerDefinition());
  assert.deepEqual(
    onchain.triggers.map((trigger) => [
      trigger.stageIdentifier,
      trigger.hookName,
      trigger.orderTriggerKind,
      trigger.source,
      trigger.signalName,
    ]),
    [
      ["entry", "ack", "trigger", "customer", "entry.ack"],
      ["entry", "str", "trigger", "customer", "entry.str"],
    ],
  );
  for (const trigger of onchain.triggers) {
    const hook = onchain.compiledHooks.find(
      (candidate) =>
        candidate.stageIdentifier === trigger.stageIdentifier &&
        candidate.hookName === trigger.hookName,
    );
    assert.ok(hook, `missing compiled trigger hook ${trigger.stageIdentifier}#${trigger.hookName}`);
    assert.deepEqual(
      hook.instructions.map((instruction) => instruction.op),
      ["SIGNAL"],
    );
    assert.equal(hook.emitReady, true);
    assert.deepEqual(
      hook.dependencies.map((dependency) => [
        dependency.kind,
        dependency.source,
        dependency.signalName,
      ]),
      [["positive", "customer", trigger.signalName]],
    );
  }
  const receiveHook = onchain.compiledHooks.find(
    (candidate) =>
      candidate.stageIdentifier === "entry" && candidate.hookName === "PLACE",
  );
  assert.equal(receiveHook?.orderTriggerKind, "none");
  assert.equal(receiveHook?.emitReady, true);

  const triggerArgs = compileZhixuRegisterPlanArgs(triggerDefinition());
  assert.equal(
    triggerArgs.hooks.filter(
      (hook) => hook.kind === "receive" && hook.flags === 5,
    ).length,
    2,
    "every trigger signal registers with MINT|EMIT_READY flags",
  );
});

test("trigger signals cannot reuse a receiveSignals channel name", () => {
  const colliding: ZhixuDefinition = {
    ...triggerDefinition(),
    spec: {
      ...triggerDefinition().spec,
      stages: [
        {
          name: "entry",
          source: "customer",
          receiveSignals: { ack: "customer::entry.seed" },
          sendSignals: [{ name: "ack", trigger: true }, { name: "seed" }],
          executor: {
            supplierType: "organization",
            supplierID: "journey-executor",
          },
        },
      ],
    },
  };
  assert.throws(
    () => compileZhixuHookPlan(colliding),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some(
        (issue) =>
          issue ===
          'trigger signal entry.ack of stage entry collides with the receiveSignals channel "ack": '
            + "the synthesized order-trigger hook and the receive hook would share hookId "
            + "<stage>#<channel>, and artifact hook ids are unique",
      ),
  );
});
