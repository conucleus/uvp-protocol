import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  ChainReplayMismatchError,
  compareChainEvents,
  replayChainEvents,
  type ChainHookReadyEvent,
  type ChainModeEvent
} from "../src/index.js";

const chainFixtureUrl = new URL("../fixtures/chain-hook-oracle.events.json", import.meta.url);
const andLatestWaitPlanId = "0x000000000000000000000000000000000000000000000000000000000000f001";
const andLatestWaitHookId = "0x000000000000000000000000000000000000000000000000000000000000f101";
const andLatestWaitStageId = "0x000000000000000000000000000000000000000000000000000000000000f201";
const andLatestWaitSourceA = "0x000000000000000000000000000000000000000000000000000000000000f301";
const andLatestWaitSourceB = "0x000000000000000000000000000000000000000000000000000000000000f302";
const andLatestWaitSignalA = "0x000000000000000000000000000000000000000000000000000000000000f401";
const andLatestWaitSignalB = "0x000000000000000000000000000000000000000000000000000000000000f402";
const andLatestWaitKeyA = "0x000000000000000000000000000000000000000000000000000000000000f501";
const andLatestWaitKeyB = "0x000000000000000000000000000000000000000000000000000000000000f502";

async function loadChainEvents(): Promise<ChainModeEvent[]> {
  return JSON.parse(await readFile(chainFixtureUrl, "utf8")) as ChainModeEvent[];
}

test("chain-mode replay matches hook expectations from stable chain events", async () => {
  const events = await loadChainEvents();
  const result = replayChainEvents(events);

  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);

  const cancelOrder = result.state.orders["chain-oracle::order-cancel"];
  assert.equal(
    cancelOrder?.signals["0x0000000000000000000000000000000000000000000000000000000000002001"]?.senderId,
    "init-executor-a"
  );
  assert.equal(
    cancelOrder?.signals["0x0000000000000000000000000000000000000000000000000000000000002001"]?.eventId,
    "2:0:0x03"
  );
  assert.equal(cancelOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003001"]?.status, "reg");
  assert.equal(cancelOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003002"]?.status, "cxl");

  const cancelStartReadyCount = result.observed.filter(
    (event) =>
      event.eventName === "HookReady" &&
      event.orderId === "order-cancel" &&
      event.hookId === "0x0000000000000000000000000000000000000000000000000000000000003001"
  ).length;
  assert.equal(cancelStartReadyCount, 1);

  const timerOrder = result.state.orders["chain-oracle::order-timer"];
  assert.equal(timerOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003001"]?.status, "reg");
  assert.equal(timerOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003002"]?.status, "reg");
  assert.equal(
    result.observed.some(
      (event) =>
        event.eventName === "HookReady" &&
        event.orderId === "order-timer" &&
        event.hookId === "0x0000000000000000000000000000000000000000000000000000000000003002"
    ),
    true
  );
});

test("chain-mode ordering uses the EVM transaction index within a block", () => {
  const first = {
    eventName: "OrderRegistered" as const,
    blockNumber: 10,
    transactionIndex: 1,
    logIndex: 0,
    transactionHash: "0xa1" as const
  };
  const second = {
    eventName: "OrderRegistered" as const,
    blockNumber: 10,
    transactionIndex: 2,
    logIndex: 0,
    transactionHash: "0xb1" as const
  };

  assert.equal(compareChainEvents(first, second) < 0, true);
});

test("chain-mode reports mismatched golden hook events", async () => {
  const events = await loadChainEvents();
  const readyIndex = events.findIndex(
    (event) => event.eventName === "HookReady" && event.orderId === "order-cancel"
  );
  assert.notEqual(readyIndex, -1);

  const badEvents = [...events];
  const badReady = badEvents[readyIndex] as ChainHookReadyEvent;
  badEvents[readyIndex] = {
    ...badReady,
    hookName: "WRONG"
  };

  let mismatchError: ChainReplayMismatchError | undefined;
  try {
    replayChainEvents(badEvents);
  } catch (error) {
    assert.ok(error instanceof ChainReplayMismatchError);
    mismatchError = error;
  }
  assert.ok(mismatchError !== undefined, "strict replay must throw on mismatch");
  assert.equal(mismatchError.mismatches.length, 1);
  assert.equal(mismatchError.mismatches[0]?.reason, "semantic-mismatch");
});

test("chain-mode keeps AND delayed branches waiting until the latest live timer", () => {
  const events: ChainModeEvent[] = [
    {
      eventName: "PlanRegistered",
      blockNumber: 1,
      logIndex: 0,
      transactionHash: "0x01",
      plan: {
        planId: andLatestWaitPlanId,
        zhixuId: "chain-parity",
        version: "test",
        compiledHooks: [
          {
            hookId: andLatestWaitHookId,
            stageId: andLatestWaitStageId,
            stageIdentifier: "latest-wait-stage",
            hookName: "latest-wait-hook",
            isTrigger: true,
            instructions: [
              {
                op: "SIGNAL",
                sourceId: andLatestWaitSourceA,
                signalId: andLatestWaitSignalA,
                signalKey: andLatestWaitKeyA
              },
              { op: "DELAY", delaySeconds: 5 },
              {
                op: "SIGNAL",
                sourceId: andLatestWaitSourceB,
                signalId: andLatestWaitSignalB,
                signalKey: andLatestWaitKeyB
              },
              { op: "DELAY", delaySeconds: 10 },
              { op: "AND", arity: 2 }
            ]
          }
        ],
        dependencyIndex: {
          [andLatestWaitKeyA]: [andLatestWaitHookId],
          [andLatestWaitKeyB]: [andLatestWaitHookId]
        }
      }
    },
    {
      eventName: "OrderRegistered",
      blockNumber: 2,
      logIndex: 0,
      transactionHash: "0x02",
      planId: andLatestWaitPlanId,
      zhixuId: "chain-parity",
      orderId: "and-latest-wait",
      registeredAt: "2026-04-27T00:00:00.000Z"
    },
    {
      eventName: "SignalSubmitted",
      blockNumber: 3,
      logIndex: 0,
      transactionHash: "0x03",
      zhixuId: "chain-parity",
      orderId: "and-latest-wait",
      sourceId: andLatestWaitSourceA,
      signalId: andLatestWaitSignalA,
      signalKey: andLatestWaitKeyA,
      senderId: "executor-a",
      submittedAt: "2026-04-27T00:00:00.000Z"
    },
    {
      eventName: "SignalSubmitted",
      blockNumber: 4,
      logIndex: 0,
      transactionHash: "0x04",
      zhixuId: "chain-parity",
      orderId: "and-latest-wait",
      sourceId: andLatestWaitSourceB,
      signalId: andLatestWaitSignalB,
      signalKey: andLatestWaitKeyB,
      senderId: "executor-b",
      submittedAt: "2026-04-27T00:00:00.000Z"
    },
    {
      eventName: "HookStatusChanged",
      blockNumber: 5,
      logIndex: 0,
      transactionHash: "0x05",
      zhixuId: "chain-parity",
      orderId: "and-latest-wait",
      hookId: andLatestWaitHookId,
      previousStatus: "init",
      newStatus: "wait",
      dueAt: "2026-04-27T00:00:10.000Z"
    }
  ];

  const result = replayChainEvents(events);

  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);
});
