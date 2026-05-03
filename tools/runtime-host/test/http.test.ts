import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import test from "node:test";
import { compileZhixuHookPlan, type ZhixuDefinition } from "@uvp-eth/compiler";
import { createHttpRuntimeDispatcher, InMemoryRuntimeEventStore, RuntimeHost, startRuntimeHostServer } from "../src/index.js";

const token = "runtime-test-token";
const t0 = "2026-04-27T00:00:00.000Z";

const zhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "runtime_http_demo",
    uid: "runtime-http-demo"
  },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    taskPatterns: [
      {
        name: "init",
        stages: [
          {
            name: "main",
            source: "buyer",
            trigger: ["TRIGGER"],
            receiveSignals: { TRIGGER: "::OUTSIDE" },
            sendSignals: ["cmp"],
            executor: { supplierType: "organization", supplierID: "init-executor" }
          }
        ]
      }
    ]
  }
};

const plan = compileZhixuHookPlan(zhixu);

test("runtime-host HTTP server protects state and accepts plan/order/signal events", async () => {
  const runtimeHost = await RuntimeHost.create({
    store: new InMemoryRuntimeEventStore(),
    now: () => t0,
    eventIdPrefix: "http-test"
  });
  const server = await startRuntimeHostServer({ runtimeHost, token, port: 0 });
  try {
    const health = await fetch(`${server.url}/healthz`);
    assert.equal(health.status, 200);

    const unauthorized = await fetch(`${server.url}/v0/state`);
    assert.equal(unauthorized.status, 401);

    assert.equal((await postJson(`${server.url}/v0/plans`, { plan })).status, 201);
    assert.equal(
      (await postJson(`${server.url}/v0/orders`, {
        order: {
          planId: plan.planId,
          zhixuId: plan.zhixuId,
          orderId: "order-1",
          receivedAt: t0
        }
      })).status,
      201
    );
    assert.equal(
      (await postJson(`${server.url}/v0/signals`, {
        signal: {
          zhixuId: plan.zhixuId,
          orderId: "order-1",
          source: "buyer",
          stageIdentifier: "init.main",
          signalName: "init.main.cmp",
          senderId: "init-executor",
          receivedAt: t0
        }
      })).status,
      202
    );

    const stateResponse = await fetch(`${server.url}/v0/state`, {
      headers: { authorization: `Bearer ${token}` }
    });
    const stateJson = await stateResponse.json() as { state?: { orders?: Record<string, unknown> } };
    assert.equal(stateResponse.status, 200);
    assert.ok(stateJson.state?.orders?.[`${plan.zhixuId}::order-1`]);
  } finally {
    await server.close();
  }
});

test("HTTP runtime dispatcher maps executor acceptance and failures", async () => {
  const executorToken = "executor-token";
  let capturedBody: unknown;
  const executor = createServer((request, response) => {
    void (async () => {
      if (request.headers.authorization !== `Bearer ${executorToken}`) {
        response.statusCode = 401;
        response.end("nope");
        return;
      }
      capturedBody = JSON.parse(await readBody(request)) as unknown;
      response.statusCode = 202;
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ accepted: true }));
    })();
  });
  await new Promise<void>((resolve) => executor.listen(0, "127.0.0.1", resolve));
  const address = executor.address();
  assert.equal(typeof address, "object");
  const executorUrl = `http://127.0.0.1:${(address as AddressInfo).port}`;
  try {
    const dispatcher = createHttpRuntimeDispatcher({
      executorUrl,
      executorToken,
      callbackUrl: "http://127.0.0.1:12345/v0/signals"
    });
    const success = await dispatcher.dispatch(
      {
        type: "HookReady",
        eventId: "event-1",
        zhixuId: "zhixu-1",
        orderId: "order-1",
        hookId: "exec.main#START",
        stageIdentifier: "exec.main",
        hookName: "START"
      },
      { state: {} as never }
    );
    assert.deepEqual(success, { status: "succeeded" });
    assert.equal((capturedBody as { effect?: { hookId?: string } }).effect?.hookId, "exec.main#START");

    const failure = await createHttpRuntimeDispatcher({
      executorUrl,
      executorToken: "wrong",
      callbackUrl: "http://127.0.0.1:12345/v0/signals"
    }).dispatch(
      {
        type: "HookReady",
        eventId: "event-2",
        zhixuId: "zhixu-1",
        orderId: "order-1",
        hookId: "exec.main#START",
        stageIdentifier: "exec.main",
        hookName: "START"
      },
      { state: {} as never }
    );
    assert.equal(failure.status, "failed");
  } finally {
    await new Promise<void>((resolve) => executor.close(() => resolve()));
  }
});

function postJson(url: string, body: unknown): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });
}

async function readBody(request: AsyncIterable<Buffer>): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf8");
}
