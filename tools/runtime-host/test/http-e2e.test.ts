import assert from "node:assert/strict";
import test from "node:test";
import { compileZhixuHookPlan, type ZhixuDefinition } from "@uvp-eth/compiler";
import {
  createStaticSignalHandler,
  startExecutorServer
} from "@uvp-eth/executor-kit";
import type { RuntimeState } from "@uvp-eth/statemachine";
import {
  createHttpRuntimeDispatcher,
  InMemoryRuntimeEventStore,
  RuntimeHost,
  startRuntimeHostServer,
  type RuntimeHostServerHandle
} from "../src/index.js";

const t0 = "2026-04-27T00:00:00.000Z";
const t3 = "2026-04-27T00:00:03.000Z";
const runtimeToken = "runtime-test-token";
const executorToken = "executor-test-token";

const zhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "runtime_http_e2e",
    uid: "runtime-http-e2e"
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

test("runs runtime-host and executor-kit over HTTP", async () => {
  const executor = await startExecutorServer({
    executorId: "exec-executor",
    handlers: {
      "exec.main#START": createStaticSignalHandler({
        source: "buyer",
        stageIdentifier: "exec.main",
        signalName: "exec.main.cmp",
        senderId: "exec-executor",
        idempotencyKey: (effect) => `${effect.orderId}:${effect.hookId}:cmp`,
        receivedAt: t3
      })
    },
    executorToken,
    runtimeToken,
    now: () => t0
  });
  let runtime: RuntimeHostServerHandle | undefined;

  try {
    let callbackUrl = "";
    const store = new InMemoryRuntimeEventStore();
    const host = await RuntimeHost.create({
      store,
      dispatcher: createHttpRuntimeDispatcher({
        executorUrl: executor.url,
        executorToken,
        callbackUrl: () => callbackUrl
      }),
      eventIdPrefix: "http-e2e",
      now: () => t0
    });
    runtime = await startRuntimeHostServer({
      runtimeHost: host,
      token: runtimeToken
    });
    callbackUrl = `${runtime.url}/v0/signals`;

    await postJson(runtime.url, "/v0/plans", runtimeToken, { plan }, 201);
    await postJson(
      runtime.url,
      "/v0/orders",
      runtimeToken,
      {
        order: {
          planId: plan.planId,
          zhixuId: plan.zhixuId,
          orderId: "order-1",
          receivedAt: t0
        }
      },
      201
    );
    await postJson(
      runtime.url,
      "/v0/signals",
      runtimeToken,
      {
        signal: {
          zhixuId: plan.zhixuId,
          orderId: "order-1",
          source: "buyer",
          stageIdentifier: "init.main",
          signalName: "init.main.cmp",
          senderId: "init-executor",
          idempotencyKey: "init-cmp",
          receivedAt: t0
        }
      },
      202
    );

    const beforeDispatch = await getSnapshot(runtime.url, runtimeToken);
    assert.deepEqual(beforeDispatch.pendingDispatches.map((item) => item.hookId), ["exec.main#START"]);
    assert.deepEqual(beforeDispatch.pendingTimers.map((item) => item.hookId), ["exec.main#TIMEOUT"]);

    const drain = await postJson(runtime.url, "/v0/dispatch/drain", runtimeToken, {}, 200);
    assert.deepEqual(
      asRecordArray(asRecord(drain).events).map((event) => asRecord(event).type),
      ["DispatchSucceeded"]
    );

    const finalSnapshot = await eventually(async () => {
      const snapshot = await getSnapshot(runtime!.url, runtimeToken);
      const order = snapshot.state.orders[`${plan.zhixuId}::order-1`];
      return order?.signals["buyer::exec.main.cmp"] ? snapshot : undefined;
    });
    const order = finalSnapshot.state.orders[`${plan.zhixuId}::order-1`];

    assert.equal(order?.hookStatuses["exec.main#START"]?.status, "dispatched");
    assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");
    assert.equal(order?.signals["buyer::exec.main.cmp"]?.senderId, "exec-executor");
    assert.deepEqual(await host.replay(), host.getState());
  } finally {
    await runtime?.close();
    await executor.close();
  }
});

test("drains due timers over HTTP", async () => {
  const store = new InMemoryRuntimeEventStore();
  const host = await RuntimeHost.create({
    store,
    eventIdPrefix: "timer-http",
    now: () => t0
  });
  const runtime = await startRuntimeHostServer({
    runtimeHost: host,
    token: runtimeToken
  });

  try {
    await postJson(runtime.url, "/v0/plans", runtimeToken, { plan }, 201);
    await postJson(runtime.url, "/v0/orders", runtimeToken, {
      order: {
        planId: plan.planId,
        zhixuId: plan.zhixuId,
        orderId: "timer-order",
        receivedAt: t0
      }
    }, 201);
    await postJson(runtime.url, "/v0/signals", runtimeToken, {
      signal: {
        zhixuId: plan.zhixuId,
        orderId: "timer-order",
        source: "buyer",
        stageIdentifier: "init.main",
        signalName: "init.main.cmp",
        senderId: "init-executor",
        receivedAt: t0
      }
    }, 202);

    const response = await postJson(runtime.url, "/v0/timers/drain", runtimeToken, {
      now: "2026-04-27T00:00:06.000Z"
    }, 200);
    assert.deepEqual(
      asRecordArray(asRecord(response).events).map((event) => asRecord(event).hookId),
      ["exec.main#TIMEOUT"]
    );
  } finally {
    await runtime.close();
  }
});

interface SnapshotResponse {
  readonly state: RuntimeState;
  readonly pendingDispatches: readonly { readonly hookId: string }[];
  readonly pendingTimers: readonly { readonly hookId: string }[];
}

async function getSnapshot(baseUrl: string, token: string): Promise<SnapshotResponse> {
  const response = await fetch(new URL("/v0/state", baseUrl), {
    headers: {
      authorization: `Bearer ${token}`
    }
  });
  assert.equal(response.status, 200);
  return (await response.json()) as SnapshotResponse;
}

async function postJson(
  baseUrl: string,
  pathname: string,
  token: string,
  body: unknown,
  expectedStatus: number
): Promise<unknown> {
  const response = await fetch(new URL(pathname, baseUrl), {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });
  const json = (await response.json()) as unknown;
  assert.equal(response.status, expectedStatus, JSON.stringify(json));
  return json;
}

async function eventually<T>(read: () => Promise<T | undefined>, timeoutMs = 1_000): Promise<T> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const value = await read();
    if (value !== undefined) {
      return value;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("condition was not met before timeout");
}

function asRecord(value: unknown): Record<string, unknown> {
  assert.equal(typeof value, "object");
  assert.notEqual(value, null);
  assert.equal(Array.isArray(value), false);
  return value as Record<string, unknown>;
}

function asRecordArray(value: unknown): readonly Record<string, unknown>[] {
  assert.equal(Array.isArray(value), true);
  return value as readonly Record<string, unknown>[];
}
