import assert from "node:assert/strict";
import test from "node:test";
import { compileZhixuHookPlan, type ZhixuDefinition } from "@uvp-eth/compiler";
import { createRuntimeDispatcher, createStaticSignalHandler } from "@uvp-eth/executor-kit";
import type { HookReadyEffect } from "@uvp-eth/statemachine";
import {
  InMemoryRuntimeEventStore,
  RuntimeHost,
  type DispatchContext,
  type RuntimeDispatcher,
  type RuntimeDispatchResult
} from "../src/index.js";

const t0 = "2026-04-27T00:00:00.000Z";
const t3 = "2026-04-27T00:00:03.000Z";
const t6 = "2026-04-27T00:00:06.000Z";

const zhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "runtime_host_demo",
    uid: "runtime-host-demo"
  },
  spec: {
    platform: {
      type: "cloud"
    },
    nucleation: {
      id: "core"
    },
    taskPatterns: [
      {
        name: "init",
        stages: [
          {
            name: "main",
            source: "buyer",
            trigger: ["TRIGGER"],
            receiveSignals: {
              TRIGGER: "::OUTSIDE"
            },
            sendSignals: ["cmp"],
            executor: {
              supplierType: "organization",
              supplierID: "init-executor"
            }
          }
        ]
      },
      {
        name: "exec",
        stages: [
          {
            name: "main",
            source: "buyer",
            trigger: ["START"],
            receiveSignals: {
              START: "buyer::init.main.cmp",
              TIMEOUT: "buyer::(init.main.cmp +5s) & ~exec.main.cmp"
            },
            sendSignals: ["cmp"],
            executor: {
              supplierType: "organization",
              supplierID: "exec-executor"
            }
          }
        ]
      }
    ]
  }
};

const plan = compileZhixuHookPlan(zhixu);

async function createKitHost(): Promise<RuntimeHost> {
  const host = await RuntimeHost.create({
    store: new InMemoryRuntimeEventStore(),
    dispatcher: createRuntimeDispatcher({
      handlers: {
        "exec.main#START": createStaticSignalHandler({
          source: "buyer",
          stageIdentifier: "exec.main",
          signalName: "exec.main.cmp",
          senderId: "exec-executor",
          idempotencyKey: (effect) => `${effect.orderId}:${effect.hookId}:cmp`,
          receivedAt: t3
        })
      }
    }),
    eventIdPrefix: "kit-e2e",
    now: () => t0
  });
  await host.registerPlan(plan);
  await host.registerOrder({
    planId: plan.planId,
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    receivedAt: t0
  });
  return host;
}

class MockDispatcher implements RuntimeDispatcher {
  readonly calls: HookReadyEffect[] = [];
  readonly failHookIds = new Set<string>();

  async dispatch(effect: HookReadyEffect, _context: DispatchContext): Promise<RuntimeDispatchResult> {
    this.calls.push(effect);
    if (this.failHookIds.has(effect.hookId)) {
      return { status: "failed", error: `mock failure for ${effect.hookId}` };
    }
    return { status: "succeeded" };
  }
}

async function createHost(dispatcher = new MockDispatcher()): Promise<{
  readonly host: RuntimeHost;
  readonly store: InMemoryRuntimeEventStore;
  readonly dispatcher: MockDispatcher;
}> {
  const store = new InMemoryRuntimeEventStore();
  const host = await RuntimeHost.create({
    store,
    dispatcher,
    eventIdPrefix: "test",
    now: () => t0
  });
  await host.registerPlan(plan);
  await host.registerOrder({
    planId: plan.planId,
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    receivedAt: t0
  });
  return { host, store, dispatcher };
}

test("runs a semantic e2e signal -> dispatch -> callback -> replay flow", async () => {
  const host = await createKitHost();

  await host.receiveSignal({
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "init.main",
    signalName: "init.main.cmp",
    senderId: "init-executor",
    idempotencyKey: "init-cmp",
    receivedAt: t0
  });

  assert.deepEqual(host.getPendingDispatches().map((item) => item.hookId), ["exec.main#START"]);
  assert.deepEqual(host.getPendingTimers().map((item) => [item.hookId, item.dueAt]), [
    ["exec.main#TIMEOUT", "2026-04-27T00:00:05.000Z"]
  ]);

  const dispatchEvents = await host.drainDispatchQueue();
  assert.deepEqual(dispatchEvents.map((event) => event.type), ["DispatchSucceeded"]);

  assert.deepEqual(host.getPendingTimers(), []);
  const state = host.getState();
  const order = state.orders[`${plan.zhixuId}::order-1`];
  assert.equal(order?.hookStatuses["exec.main#START"]?.status, "dispatched");
  assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");
  assert.equal(order?.signals["buyer::exec.main.cmp"]?.senderId, "exec-executor");
  assert.deepEqual(await host.replay(), state);
});

test("does not dispatch duplicate idempotency keys twice", async () => {
  const { host, dispatcher } = await createHost();
  const signal = {
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "init.main",
    signalName: "init.main.cmp",
    senderId: "init-executor",
    idempotencyKey: "same-signal",
    receivedAt: t0
  };

  await host.receiveSignal(signal);
  await host.receiveSignal(signal);
  await host.drainDispatchQueue();

  assert.equal(dispatcher.calls.length, 1);
  assert.equal(host.getState().orders[`${plan.zhixuId}::order-1`]?.signals["buyer::init.main.cmp"]?.eventId, "test:3:SignalReceived");
});

test("records dispatcher failures as fail hook state", async () => {
  const dispatcher = new MockDispatcher();
  dispatcher.failHookIds.add("exec.main#START");
  const { host } = await createHost(dispatcher);

  await host.receiveSignal({
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "init.main",
    signalName: "init.main.cmp",
    senderId: "init-executor",
    receivedAt: t0
  });
  const results = await host.drainDispatchQueue();

  assert.equal(results[0]?.type, "DispatchFailed");
  const order = host.getState().orders[`${plan.zhixuId}::order-1`];
  assert.equal(order?.hookStatuses["exec.main#START"]?.status, "fail");
  assert.equal(order?.hookStatuses["exec.main#START"]?.lastError, "mock failure for exec.main#START");
});

test("runs due timers and promotes waiting hooks to dispatch queue", async () => {
  const { host } = await createHost();

  await host.receiveSignal({
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "init.main",
    signalName: "init.main.cmp",
    senderId: "init-executor",
    receivedAt: t0
  });

  const timerEvents = await host.runDueTimers(t6);
  assert.deepEqual(timerEvents.map((event) => event.hookId), ["exec.main#TIMEOUT"]);
  assert.deepEqual(host.getPendingDispatches().map((item) => item.hookId), [
    "exec.main#START",
    "exec.main#TIMEOUT"
  ]);
});

test("removes pending timers when a negative signal cancels the hook", async () => {
  const { host } = await createHost();

  await host.receiveSignal({
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "init.main",
    signalName: "init.main.cmp",
    senderId: "init-executor",
    receivedAt: t0
  });
  await host.receiveSignal({
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "exec.main",
    signalName: "exec.main.cmp",
    senderId: "exec-executor",
    receivedAt: t3
  });

  assert.deepEqual(host.getPendingTimers(), []);
  assert.deepEqual(await host.runDueTimers(t6), []);
  assert.equal(host.getState().orders[`${plan.zhixuId}::order-1`]?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");
});

test("rebuilds pending dispatch and timer projections from event log after restart", async () => {
  const { host, store } = await createHost();
  await host.receiveSignal({
    zhixuId: plan.zhixuId,
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "init.main",
    signalName: "init.main.cmp",
    senderId: "init-executor",
    receivedAt: t0
  });

  const restarted = await RuntimeHost.create({
    store,
    dispatcher: new MockDispatcher(),
    eventIdPrefix: "restart",
    now: () => t0
  });

  assert.deepEqual(restarted.getPendingDispatches().map((item) => item.hookId), ["exec.main#START"]);
  assert.deepEqual(restarted.getPendingTimers().map((item) => item.hookId), ["exec.main#TIMEOUT"]);
  assert.deepEqual(restarted.getState(), await restarted.replay());
});
