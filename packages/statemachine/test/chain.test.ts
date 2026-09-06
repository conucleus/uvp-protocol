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

  const cancelOrder = result.state.orders[
    "0x312bed89090d5be24d38a236e312f8734d64dff50f8da3376542bee659dbb35d::order-cancel"
  ];
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

  const timerOrder = result.state.orders[
    "0x312bed89090d5be24d38a236e312f8734d64dff50f8da3376542bee659dbb35d::order-timer"
  ];
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
            orderTriggerKind: "mint",
            emitReady: true,
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
      planId: andLatestWaitPlanId,
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
      planId: andLatestWaitPlanId,
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
      planId: andLatestWaitPlanId,
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

test("chain replay filters non-observable HookStatusChanged transitions (golden alignment)", async () => {
  // 合约在 HookReady 旁恒发 HookStatusChanged(→Ready)（_evaluateHook /
  // _markOrderTriggerHookReady），oracle 的 observed 面只产生 wait/cxl +
  // HookReady——喂进 →reg/→init 状态变化必然 missing-observed。normalize
  // 边界必须把它们滤掉；golden 流注入后回放仍须全绿。
  const events = await loadChainEvents();
  const injected: ChainModeEvent[] = [];
  for (const event of events) {
    injected.push(event);
    if (event.eventName === "HookReady") {
      injected.push({
        eventName: "HookStatusChanged",
        blockNumber: event.blockNumber,
        transactionIndex: event.transactionIndex ?? 0,
        logIndex: event.logIndex + 1000,
        transactionHash: event.transactionHash,
        planId: event.planId,
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        hookId: event.hookId,
        previousStatus: "init",
        newStatus: "reg"
      });
      injected.push({
        eventName: "HookStatusChanged",
        blockNumber: event.blockNumber,
        transactionIndex: event.transactionIndex ?? 0,
        logIndex: event.logIndex + 1001,
        transactionHash: event.transactionHash,
        planId: event.planId,
        zhixuId: event.zhixuId,
        orderId: event.orderId,
        hookId: event.hookId,
        previousStatus: "wait",
        newStatus: "init"
      });
    }
  }

  const result = replayChainEvents(injected);
  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);
});

test("chain replay derives order-link birth facts from HookReady", () => {
  // order-link 出生（triggerOrderFromSignalFromModule → _markTriggerHookReady）
  // 不 _recordSignal 但 emit HookStatusChanged(→reg) + HookReady +
  // StageMaterialized。TS 消费面从 HookReady 推导出生事实：流可回放，
  // expected==observed，且终态回填 hook=reg + 阶段物化。
  const planId = "0x000000000000000000000000000000000000000000000000000000000000b001";
  const hookId = "0x000000000000000000000000000000000000000000000000000000000000b101";
  const stageId = "0x000000000000000000000000000000000000000000000000000000000000b201";
  const srcId = "0x000000000000000000000000000000000000000000000000000000000000b301";
  const sigId = "0x000000000000000000000000000000000000000000000000000000000000b401";
  const keyId = "0x000000000000000000000000000000000000000000000000000000000000b501";
  const events: ChainModeEvent[] = [
    {
      eventName: "PlanRegistered",
      blockNumber: 1,
      logIndex: 0,
      transactionHash: "0x01",
      plan: {
        planId,
        zhixuId: "order-link-birth",
        version: "test",
        compiledHooks: [
          {
            hookId,
            stageId,
            stageIdentifier: "birth-stage",
            hookName: "birth",
            orderTriggerKind: "mint",
            emitReady: true,
            instructions: [{ op: "SIGNAL", sourceId: srcId, signalId: sigId, signalKey: keyId }]
          }
        ],
        dependencyIndex: { [keyId]: [hookId] }
      }
    },
    {
      eventName: "OrderRegistered",
      blockNumber: 2,
      logIndex: 0,
      transactionHash: "0x02",
      planId,
      zhixuId: "order-link-birth",
      orderId: "link-child",
      registeredAt: "2026-01-01T00:00:00.000Z"
    },
    {
      eventName: "OrderTriggered",
      blockNumber: 3,
      logIndex: 0,
      transactionHash: "0x03",
      orderId: "link-child",
      planId,
      triggerStageId: stageId,
      sourceId: srcId,
      signalId: sigId,
      submitter: "alice"
    },
    {
      eventName: "HookStatusChanged",
      blockNumber: 3,
      logIndex: 1,
      transactionHash: "0x03",
      planId,
      zhixuId: "order-link-birth",
      orderId: "link-child",
      hookId,
      previousStatus: "init",
      newStatus: "reg"
    },
    {
      eventName: "HookReady",
      blockNumber: 3,
      logIndex: 2,
      transactionHash: "0x03",
      planId,
      zhixuId: "order-link-birth",
      orderId: "link-child",
      hookId,
      stageIdentifier: "birth-stage",
      hookName: "birth"
    },
    {
      eventName: "StageMaterialized",
      blockNumber: 3,
      logIndex: 3,
      transactionHash: "0x03",
      planId,
      orderId: "link-child",
      stageId,
      triggerHookId: hookId,
      sourceId: srcId,
      signalId: sigId
    }
  ];

  const result = replayChainEvents(events);

  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);
  assert.equal(result.expected.length, 1);
  assert.equal(result.expected[0]?.eventName, "HookReady");
  const childOrder = result.state.orders[`${planId}::link-child`];
  assert.equal(childOrder?.hookStatuses[hookId]?.status, "reg");
  assert.equal(childOrder?.hookStatuses[hookId]?.readyEmitted, true);
  assert.equal(childOrder?.materializedStages[stageId], true);
  // 出生事实不落子单信号集：链上 order-link 路径不 _recordSignal，
  // 派生不得伪造 SignalSubmitted 状态。
  assert.deepEqual(childOrder?.signals, {});
});
