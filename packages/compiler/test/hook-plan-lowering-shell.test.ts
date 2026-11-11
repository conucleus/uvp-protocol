import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
  HookPlanCompilationError,
  type ZhixuDefinition,
} from "../src/index.js";
import { DOCK_ROUTE_SCHEMA_VERSION } from "../src/types/index.js";
import { resolutionManifestFor } from "./dock-demo.js";

/**
 * 链轨 hook_plan lowering 的 1:1 迁移（uvp-core tests.rs 链半）：trigger hook
 * 合成、hook 装饰（orderTriggerKind/emitReady/route）、dependencyIndex、
 * executorRoutes 与 dock shell 形状。共享校验、负例、capabilities/admissions
 * 归 uvp-core analyze，不在本文件重复。
 */

function targetPaymentDefinition(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "payment_execution" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "payment-core" },
      dockInterface: {
        payment_service: {
          orderModes: ["new"],
          inputs: {
            execute: { hook: "init#DOCK_EXECUTE" },
            cancel: { hook: "control#DOCK_CANCEL" },
          },
          outputs: {
            started: { signal: "payment::init.str" },
            completed: { signal: "payment::settle.cmp" },
            failed: { signal: "payment::settle.err" },
          },
        },
        payment_evidence: {
          orderModes: ["existing"],
          outputs: {
            cancelled: { signal: "payment::control.cxl" },
          },
        },
      },
      stages: [
        {
          name: "init",
          source: "payment",
          receiveSignals: { DOCK_EXECUTE: "payment::init.execute" },
          sendSignals: [{ name: "str" }],
          executor: { supplierType: "organization", supplierID: "payment-gateway" },
        },
        {
          name: "control",
          source: "payment",
          receiveSignals: { DOCK_CANCEL: "payment::control.cancel" },
          sendSignals: [{ name: "cxl" }],
          executor: { supplierType: "organization", supplierID: "payment-gateway" },
        },
        {
          name: "settle",
          source: "payment",
          receiveSignals: { SETTLE: "payment::init.str" },
          sendSignals: [{ name: "cmp" }, { name: "err" }],
          executor: { supplierType: "organization", supplierID: "payment-gateway" },
        },
      ],
    },
  };
}

function parentSettlementDefinition(targetUid: string): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "settlement" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "settlement-core" },
      stages: [
        {
          name: "confirm",
          source: "buyer",
          receiveSignals: { PLACE: "buyer::confirm.seed" },
          sendSignals: [{ name: "cmp" }, { name: "seed" }],
          executor: { supplierType: "organization", supplierID: "buyer-app" },
        },
        {
          name: "cancel",
          source: "buyer",
          receiveSignals: { ABORT: "buyer::cancel.seed" },
          sendSignals: [{ name: "cmp" }, { name: "seed" }],
          executor: { supplierType: "organization", supplierID: "buyer-app" },
        },
        {
          name: "execute_payment",
          source: "buyer",
          receiveSignals: {
            EXECUTE: "buyer::confirm.cmp",
            CANCEL: "buyer::cancel.cmp",
          },
          sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "err" }, { name: "cxl" }],
          executor: {
            supplierType: "zhixu",
            zhixuExecutorConfig: {
              target: { zhixu: targetUid },
              interface: "payment_service",
              order: { mode: "new" },
              inputMap: { EXECUTE: "execute" },
              signalMap: { str: "started", cmp: "completed", err: "failed" },
            },
          },
        },
      ],
    },
  };
}

test("dock interfaces and entrance hooks compile to the chain decoration", () => {
  const plan = compileZhixuHookPlan(targetPaymentDefinition());
  const dockInterface = plan.dockInterface;
  assert.ok(dockInterface, "a plan declaring dockInterface must carry its artifact");
  const interfaces = dockInterface.interfaces;
  assert.deepEqual(
    interfaces.map((entry) => entry.name),
    ["payment_evidence", "payment_service"],
  );
  assert.deepEqual(interfaces[0]?.orderModes, ["existing"]);
  assert.deepEqual(interfaces[0]?.inputs, []);
  assert.deepEqual(interfaces[1]?.orderModes, ["new"]);
  assert.deepEqual(
    interfaces[1]?.inputs.map((port) => [port.port, port.source, port.hookId]),
    [
      ["cancel", "payment", "control#DOCK_CANCEL"],
      ["execute", "payment", "init#DOCK_EXECUTE"],
    ],
  );
  assert.deepEqual(
    interfaces[1]?.outputs.map((port) => [port.port, port.canonicalOutputSignal]),
    [
      ["completed", "payment::settle.cmp"],
      ["failed", "payment::settle.err"],
      ["started", "payment::init.str"],
    ],
  );

  const entrance = plan.compiledHooks.find(
    (hook) => hook.hookId === "init#DOCK_EXECUTE",
  );
  assert.ok(entrance);
  assert.equal(entrance.orderTriggerKind, "dock");
  assert.equal(entrance.emitReady, true);
  const cancel = plan.compiledHooks.find(
    (hook) => hook.hookId === "control#DOCK_CANCEL",
  );
  assert.ok(cancel);
  assert.equal(cancel.orderTriggerKind, "dock");
  assert.equal(cancel.emitReady, true);
});

test("linked parent keeps the dock shell and omits linked executor routes", () => {
  const target = targetPaymentDefinition();
  const manifest = resolutionManifestFor(target);
  const targetUid = manifest.definitions[0]?.zhixu;
  assert.ok(targetUid, "the resolution manifest carries the published target uid");
  const plan = compileZhixuHookPlan(parentSettlementDefinition(targetUid), manifest);

  assert.equal(plan.schemaVersion, "uvp.hookPlan.v5");
  assert.equal(plan.zhixuName, "settlement");
  assert.ok(
    !plan.compiledHooks.some((hook) => hook.hookId.startsWith("signalMap.")),
    "linked signalMap routes must not leak synthetic hooks into the shell",
  );
  const execute = plan.compiledHooks.find(
    (hook) => hook.hookId === "execute_payment#EXECUTE",
  );
  assert.ok(execute);
  assert.equal(execute.orderTriggerKind, "none");
  assert.equal(execute.emitReady, true);
  assert.equal(
    plan.executorRoutes["execute_payment"],
    undefined,
    "a dock-linked stage routes through the dock route, not executorRoutes",
  );

  assert.equal(plan.dockRoutes.length, 1);
  const route = plan.dockRoutes[0];
  assert.ok(route);
  assert.equal(route.schemaVersion, DOCK_ROUTE_SCHEMA_VERSION);
  assert.equal(route.local.stageIdentifier, "execute_payment");
  assert.equal(route.orderMode, "new");
  assert.equal(route.target.zhixuUid, targetUid);
  assert.equal(route.target.interfaceName, "payment_service");
  assert.equal(route.inputBindings.length, 1);
  assert.equal(route.inputBindings[0]?.localHookName, "EXECUTE");
  assert.equal(route.inputBindings[0]?.targetPort, "execute");
  assert.deepEqual(
    route.outputBindings.map((binding) => [binding.localSignalName, binding.targetPort]).sort(),
    [
      ["cmp", "completed"],
      ["err", "failed"],
      ["str", "started"],
    ],
  );
});

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
          trigger: ["str", "ack"],
          receiveSignals: { PLACE: "customer::entry.seed" },
          sendSignals: [{ name: "str" }, { name: "ack" }, { name: "seed" }],
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

  const dockOnchain = compileZhixuOnchainHookPlan(targetPaymentDefinition());
  assert.deepEqual(
    dockOnchain.triggers.map((trigger) => [
      trigger.stageIdentifier,
      trigger.hookName,
      trigger.orderTriggerKind,
    ]),
    [
      ["control", "DOCK_CANCEL", "dock"],
      ["init", "DOCK_EXECUTE", "dock"],
    ],
  );
  const dockArgs = compileZhixuRegisterPlanArgs(targetPaymentDefinition());
  assert.equal(
    dockArgs.hooks.filter((hook) => hook.kind === "receive" && hook.flags === 6)
      .length,
    2,
    "dock entrances register with DOCK|EMIT_READY flags",
  );

  const target = targetPaymentDefinition();
  const manifest = resolutionManifestFor(target);
  const targetUid = manifest.definitions[0]?.zhixu;
  assert.ok(targetUid, "the resolution manifest carries the published target uid");
  const linked = compileZhixuOnchainHookPlan(
    parentSettlementDefinition(targetUid),
    manifest,
  );
  assert.deepEqual(linked.triggers, []);
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
          trigger: ["ack"],
          receiveSignals: { ack: "customer::entry.seed" },
          sendSignals: [{ name: "ack" }, { name: "seed" }],
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
