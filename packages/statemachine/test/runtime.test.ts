import assert from "node:assert/strict";
import test from "node:test";
import { compileZhixuHookPlan, type ZhixuDefinition } from "@uvp-eth/compiler";
import {
  RuntimeTransitionError,
  replayRuntimeEvents,
  type RuntimeEvent,
  type RuntimeHookPlan
} from "../src/index.js";

const now = "2026-04-27T00:00:00.000Z";
const due = "2026-04-27T00:00:05.000Z";
const afterDue = "2026-04-27T00:00:06.000Z";

const zhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "runtime_demo",
    uid: "runtime-demo"
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

const plan = compileZhixuHookPlan(zhixu) as RuntimeHookPlan;

function baseEvents(): RuntimeEvent[] {
  return [
    {
      eventId: "plan-1",
      type: "PlanRegistered",
      plan
    },
    {
      eventId: "order-1",
      type: "OrderRegistered",
      planId: plan.planId,
      zhixuId: "runtime-demo",
      orderId: "order-1",
      receivedAt: now
    }
  ];
}

test("emits HookReady when a positive signal satisfies a hook", () => {
  const state = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor",
      receivedAt: now,
      idempotencyKey: "idem-1"
    }
  ]);

  const order = state.orders["runtime-demo::order-1"];
  assert.equal(order?.hookStatuses["exec.main#START"]?.status, "reg");
  assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "wait");
  assert.deepEqual(state.effects.map((effect) => effect.type), ["HookReady", "HookWaiting"]);
});

test("does not retrigger duplicate signals", () => {
  const signal = {
    eventId: "signal-1",
    type: "SignalReceived" as const,
    zhixuId: "runtime-demo",
    orderId: "order-1",
    source: "buyer",
    stageIdentifier: "init.main",
    signalName: "init.main.cmp",
    senderId: "init-executor",
    receivedAt: now,
    idempotencyKey: "idem-1"
  };
  const state = replayRuntimeEvents([
    ...baseEvents(),
    signal,
    {
      ...signal,
      eventId: "signal-duplicate"
    }
  ]);

  assert.equal(state.effects.filter((effect) => effect.type === "HookReady").length, 1);
});

test("keeps first-writer-wins for duplicate business signals without idempotency keys", () => {
  const state = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor-a",
      receivedAt: now
    },
    {
      eventId: "signal-2",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor-b",
      receivedAt: "2026-04-27T00:00:01.000Z"
    }
  ]);

  const order = state.orders["runtime-demo::order-1"];
  assert.equal(order?.signals["buyer::init.main.cmp"]?.eventId, "signal-1");
  assert.equal(order?.signals["buyer::init.main.cmp"]?.senderId, "init-executor-a");
  assert.equal(state.effects.filter((effect) => effect.type === "HookReady").length, 1);
});

test("timer due promotes waiting hooks to ready", () => {
  const state = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor",
      receivedAt: now
    },
    {
      eventId: "timer-1",
      type: "TimerDue",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      hookId: "exec.main#TIMEOUT",
      now: afterDue
    }
  ]);

  const order = state.orders["runtime-demo::order-1"];
  assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "reg");
  assert.equal(
    state.effects.some((effect) => effect.type === "HookWaiting" && effect.dueAt === due),
    true
  );
});

test("negative signal cancels delayed hook before due time", () => {
  const state = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor",
      receivedAt: now
    },
    {
      eventId: "signal-2",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "exec.main",
      signalName: "exec.main.cmp",
      senderId: "exec-executor",
      receivedAt: "2026-04-27T00:00:03.000Z"
    },
    {
      eventId: "timer-1",
      type: "TimerDue",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      hookId: "exec.main#TIMEOUT",
      now: afterDue
    }
  ]);

  const order = state.orders["runtime-demo::order-1"];
  assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");
  assert.equal(state.effects.some((effect) => effect.type === "HookCancelled"), true);
});

test("negative signal cancels delayed hook before positive anchor arrives", () => {
  const state = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "exec.main",
      signalName: "exec.main.cmp",
      senderId: "exec-executor",
      receivedAt: now
    }
  ]);

  const order = state.orders["runtime-demo::order-1"];
  assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");
  assert.equal(state.effects.some((effect) => effect.type === "HookCancelled"), true);
});

test("negative signal can cancel a registered hook before dispatch succeeds", () => {
  const cancellablePlan = compileZhixuHookPlan({
    ...zhixu,
    metadata: {
      name: "runtime_cancellable",
      uid: "runtime-cancellable"
    },
    spec: {
      ...zhixu.spec,
      taskPatterns: [
        zhixu.spec.taskPatterns[0]!,
        {
          name: "exec",
          stages: [
            {
              name: "main",
              source: "buyer",
              trigger: ["START"],
              receiveSignals: {
                START: "buyer::init.main.cmp & ~exec.main.err"
              },
              sendSignals: ["cmp", "err"],
              executor: {
                supplierType: "organization",
                supplierID: "exec-executor"
              }
            }
          ]
        }
      ]
    }
  }) as RuntimeHookPlan;
  const state = replayRuntimeEvents([
    {
      eventId: "plan-1",
      type: "PlanRegistered",
      plan: cancellablePlan
    },
    {
      eventId: "order-1",
      type: "OrderRegistered",
      planId: cancellablePlan.planId,
      zhixuId: "runtime-cancellable",
      orderId: "order-1",
      receivedAt: now
    },
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-cancellable",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor",
      receivedAt: now
    },
    {
      eventId: "signal-2",
      type: "SignalReceived",
      zhixuId: "runtime-cancellable",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "exec.main",
      signalName: "exec.main.err",
      senderId: "exec-executor",
      receivedAt: "2026-04-27T00:00:01.000Z"
    }
  ]);

  const order = state.orders["runtime-cancellable::order-1"];
  assert.equal(order?.hookStatuses["exec.main#START"]?.status, "cxl");
  assert.deepEqual(state.effects.map((effect) => effect.type), ["HookReady", "HookCancelled"]);
});

test("dispatch success and failure settle hook runtime states", () => {
  const succeeded = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor",
      receivedAt: now
    },
    {
      eventId: "dispatch-1",
      type: "DispatchSucceeded",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      hookId: "exec.main#START",
      receivedAt: now
    }
  ]);

  assert.equal(
    succeeded.orders["runtime-demo::order-1"]?.hookStatuses["exec.main#START"]?.status,
    "dispatched"
  );
  assert.equal(
    succeeded.orders["runtime-demo::order-1"]?.signals["buyer::exec.main.cmp"],
    undefined
  );

  const failed = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor",
      receivedAt: now
    },
    {
      eventId: "dispatch-1",
      type: "DispatchFailed",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      hookId: "exec.main#START",
      receivedAt: now,
      error: "executor unavailable"
    }
  ]);

  assert.equal(
    failed.orders["runtime-demo::order-1"]?.hookStatuses["exec.main#START"]?.status,
    "fail"
  );
});

test("business cmp is represented only by a SignalReceived event", () => {
  const state = replayRuntimeEvents([
    ...baseEvents(),
    {
      eventId: "signal-1",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "init.main",
      signalName: "init.main.cmp",
      senderId: "init-executor",
      receivedAt: now
    },
    {
      eventId: "dispatch-1",
      type: "DispatchSucceeded",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      hookId: "exec.main#START",
      receivedAt: now
    },
    {
      eventId: "signal-2",
      type: "SignalReceived",
      zhixuId: "runtime-demo",
      orderId: "order-1",
      source: "buyer",
      stageIdentifier: "exec.main",
      signalName: "exec.main.cmp",
      senderId: "exec-executor",
      receivedAt: "2026-04-27T00:00:03.000Z"
    }
  ]);

  const order = state.orders["runtime-demo::order-1"];
  assert.equal(order?.hookStatuses["exec.main#START"]?.status, "dispatched");
  assert.equal(order?.signals["buyer::exec.main.cmp"]?.senderId, "exec-executor");
  assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");
});

test("rejects dispatch results before hook is ready", () => {
  assert.throws(
    () =>
      replayRuntimeEvents([
        ...baseEvents(),
        {
          eventId: "dispatch-1",
          type: "DispatchSucceeded",
          zhixuId: "runtime-demo",
          orderId: "order-1",
          hookId: "exec.main#START",
          receivedAt: now
        }
      ]),
    RuntimeTransitionError
  );
  assert.throws(
    () =>
      replayRuntimeEvents([
        ...baseEvents(),
        {
          eventId: "dispatch-1",
          type: "DispatchFailed",
          zhixuId: "runtime-demo",
          orderId: "order-1",
          hookId: "exec.main#START",
          receivedAt: now,
          error: "executor unavailable"
        }
      ]),
    RuntimeTransitionError
  );
});
