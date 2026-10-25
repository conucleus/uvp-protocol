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

  const timeoutHook = events
    .flatMap((event) =>
      event.eventName === "PlanRegistered" ? event.plan.compiledHooks : []
    )
    .find((hook) => hook.instructions.some((instruction) => instruction.op === "DELAY"));
  assert.notEqual(timeoutHook, undefined);
  assert.equal(timeoutHook?.orderTriggerKind, "none");

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
  assert.equal(cancelOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003001"]?.status, "ready");
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
  assert.equal(timerOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003001"]?.status, "ready");
  assert.equal(timerOrder?.hookStatuses["0x0000000000000000000000000000000000000000000000000000000000003002"]?.status, "ready");
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

test("chain replay registers admission-declared plans without replay-side filtering", async () => {
  const events = await loadChainEvents();
  const admissionPlanId = "0x000000000000000000000000000000000000000000000000000000000000a201";
  const belongsToAdmissionPlan = (event: ChainModeEvent): boolean =>
    event.eventName === "PlanRegistered"
      ? event.plan.planId === admissionPlanId
      : event.planId === admissionPlanId;
  const admissionEvents = events.filter(belongsToAdmissionPlan);
  assert.equal(admissionEvents.length, 4, "admission segment expected in the golden fixture");
  const planRegistered = admissionEvents.find(
    (event): event is Extract<typeof event, { eventName: "PlanRegistered" }> =>
      event.eventName === "PlanRegistered",
  );
  assert.ok(planRegistered, "admission PlanRegistered expected");
  assert.equal(planRegistered.plan.admissions?.length, 1);
  assert.deepEqual(
    planRegistered.plan.admissions?.[0]?.instructions.map((instruction) => instruction.op),
    ["SIGNAL", "DELAY", "NOT"],
  );

  const result = replayChainEvents(events);

  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);
  const order = result.state.orders[`${admissionPlanId}::order-admission`];
  assert.equal(
    order?.signals["0x000000000000000000000000000000000000000000000000000000000000a251"]?.senderId,
    "gate-executor",
  );
  assert.equal(
    order?.hookStatuses["0x000000000000000000000000000000000000000000000000000000000000a211"]?.status,
    "ready",
  );
  const admissionObservations = result.observed.filter(
    (observation) => observation.planId === admissionPlanId,
  );
  assert.deepEqual(admissionObservations.map((observation) => observation.eventName), ["HookReady"]);
});

test("chain-mode ordering is the canonical (blockNumber, logIndex) pair", () => {
  const hash = `0x${"ab".repeat(32)}` as `0x${string}`;
  const event = (
    blockNumber: number,
    transactionIndex: number | undefined,
    logIndex: number,
  ): Parameters<typeof compareChainEvents>[0] => ({
    eventName: "OrderRegistered",
    blockNumber,
    ...(transactionIndex === undefined ? {} : { transactionIndex }),
    logIndex,
    transactionHash: hash,
  });

  const late = event(10, 1, 7);
  const early = event(10, 3, 5);
  assert.equal(compareChainEvents(early, late) < 0, true);
  assert.equal(compareChainEvents(late, early) > 0, true);
  const sameKeyVariants = [
    event(10, 9, 5),
    event(10, 0, 5),
    event(10, undefined, 5),
  ];
  for (const variant of sameKeyVariants) {
    assert.equal(compareChainEvents(early, variant), 0);
    assert.equal(compareChainEvents(variant, early), 0);
  }
  assert.equal(compareChainEvents(event(9, 9, 9), event(10, 0, 0)) < 0, true);
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
        compiledHooks: [
          {
            hookId: andLatestWaitHookId,
            stageId: andLatestWaitStageId,
            stageIdentifier: "latest-wait-stage",
            hookName: "latest-wait-hook",
            orderTriggerKind: "none",
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
        newStatus: "ready"
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
      triggerHookId: hookId,
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
      newStatus: "ready"
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
  assert.equal(childOrder?.hookStatuses[hookId]?.status, "ready");
  assert.equal(childOrder?.hookStatuses[hookId]?.readyEmitted, true);
  assert.equal(childOrder?.materializedStages[stageId], true);
  assert.deepEqual(childOrder?.signals, {});
});

test("chain replay exposes duplicated birth HookReady as a mismatch", () => {
  const planId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000b011";
  const hookId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000b111";
  const stageId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000b211";
  const srcId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000b311";
  const sigId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000b411";
  const keyId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000b511";
  const hookReady = {
    eventName: "HookReady" as const,
    blockNumber: 3,
    logIndex: 0,
    transactionHash: "0x03" as const,
    planId,
    zhixuId: "order-link-birth",
    orderId: "link-child",
    hookId,
    stageIdentifier: "birth-stage",
    hookName: "birth"
  };
  const events: ChainModeEvent[] = [
    {
      eventName: "PlanRegistered",
      blockNumber: 1,
      logIndex: 0,
      transactionHash: "0x01",
      plan: {
        planId,
        zhixuId: "order-link-birth",
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
    hookReady,
    { ...hookReady, logIndex: 1 }
  ];

  let mismatchError: ChainReplayMismatchError | undefined;
  try {
    replayChainEvents(events);
  } catch (error) {
    assert.ok(error instanceof ChainReplayMismatchError);
    mismatchError = error;
  }
  assert.ok(mismatchError !== undefined, "duplicated birth HookReady must fail loudly");
  assert.equal(mismatchError.mismatches.length, 1);
  assert.equal(mismatchError.mismatches[0]?.reason, "missing-observed");
});

test("chain replay filters contract-impossible TimerPoked events (pokeTimer gate)", async () => {
  const events = await loadChainEvents();
  const planId = "0x312bed89090d5be24d38a236e312f8734d64dff50f8da3376542bee659dbb35d";
  const cancelHook = "0x0000000000000000000000000000000000000000000000000000000000003002";
  const timerHook = "0x0000000000000000000000000000000000000000000000000000000000003002";

  const impossible: ChainModeEvent[] = [
    {
      eventName: "TimerPoked",
      blockNumber: 5,
      logIndex: 0,
      transactionHash: "0x06",
      planId,
      zhixuId: "chain-oracle",
      orderId: "order-cancel",
      hookId: cancelHook,
      dueAt: "2026-04-27T00:00:05.000Z",
      pokedAt: "2026-04-27T00:00:06.000Z"
    },
    {
      eventName: "TimerPoked",
      blockNumber: 7,
      logIndex: 5,
      transactionHash: "0x08",
      planId,
      zhixuId: "chain-oracle",
      orderId: "order-timer",
      hookId: timerHook,
      dueAt: "2026-04-27T00:01:05.000Z",
      pokedAt: "2026-04-27T00:01:01.000Z"
    },
    {
      eventName: "TimerPoked",
      blockNumber: 9,
      logIndex: 3,
      transactionHash: "0x0b",
      planId,
      zhixuId: "chain-oracle",
      orderId: "order-timer",
      hookId: timerHook,
      dueAt: "2026-04-27T00:01:00.000Z",
      pokedAt: "2026-04-27T00:01:01.000Z"
    },
    {
      eventName: "TimerPoked",
      blockNumber: 10,
      logIndex: 4,
      transactionHash: "0x0c",
      planId,
      zhixuId: "chain-oracle",
      orderId: "order-timer",
      hookId: timerHook,
      pokedAt: "2026-04-27T00:01:01.000Z"
    } as unknown as ChainModeEvent
  ];

  const clean = replayChainEvents(events);
  const polluted = replayChainEvents([...events, ...impossible]);
  assert.deepEqual(polluted.mismatches, []);
  assert.deepEqual(polluted.observed, polluted.expected);
  assert.deepEqual(polluted.state, clean.state);
  assert.deepEqual(polluted.observed, clean.observed);
});

test("chain replay fails loudly when TimerPoked targets an unknown order/plan/hook", () => {
  const planId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e001";
  const hookId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e101";
  const quietHookId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e102";
  const stageId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e201";
  const sourceId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e301";
  const signalId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e401";
  const keyId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e501";
  const quietKeyId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000e502";
  const zhixuId = "unknown-target";
  const planRegistered: ChainModeEvent = {
    eventName: "PlanRegistered",
    blockNumber: 1,
    logIndex: 0,
    transactionHash: "0x01",
    plan: {
      planId,
      zhixuId,
      compiledHooks: [
        {
          hookId,
          stageId,
          stageIdentifier: "main",
          hookName: "TIMEOUT",
          orderTriggerKind: "none",
          emitReady: true,
          instructions: [
            { op: "SIGNAL", sourceId, signalId, signalKey: keyId },
            { op: "DELAY", delaySeconds: 5 },
          ],
        },
        {
          hookId: quietHookId,
          stageId,
          stageIdentifier: "main",
          hookName: "QUIET",
          orderTriggerKind: "none",
          emitReady: true,
          instructions: [
            { op: "SIGNAL", sourceId, signalId, signalKey: quietKeyId },
            { op: "DELAY", delaySeconds: 5 },
          ],
        },
      ],
      dependencyIndex: {
        [keyId]: [hookId],
        [quietKeyId]: [quietHookId],
      },
    },
  };
  const orderRegistered: ChainModeEvent = {
    eventName: "OrderRegistered",
    blockNumber: 2,
    logIndex: 0,
    transactionHash: "0x02",
    planId,
    zhixuId,
    orderId: "order-1",
    registeredAt: "2026-04-27T00:00:00.000Z",
  };
  const signalSubmitted: ChainModeEvent = {
    eventName: "SignalSubmitted",
    blockNumber: 3,
    logIndex: 0,
    transactionHash: "0x03",
    planId,
    zhixuId,
    orderId: "order-1",
    sourceId,
    signalId,
    signalKey: keyId,
    senderId: "pay-executor",
    submittedAt: "2026-04-27T00:00:00.000Z",
  };
  const statusWait: ChainModeEvent = {
    eventName: "HookStatusChanged",
    blockNumber: 4,
    logIndex: 0,
    transactionHash: "0x04",
    planId,
    zhixuId,
    orderId: "order-1",
    hookId,
    previousStatus: "init",
    newStatus: "wait",
    dueAt: "2026-04-27T00:00:05.000Z",
  };
  const base = [planRegistered, orderRegistered, signalSubmitted, statusWait];
  const poke = (overrides: {
    readonly planId?: `0x${string}`;
    readonly orderId?: string;
    readonly hookId?: string;
  }): ChainModeEvent => ({
    eventName: "TimerPoked",
    blockNumber: 6,
    logIndex: 0,
    transactionHash: "0x06",
    planId: overrides.planId ?? planId,
    zhixuId,
    orderId: overrides.orderId ?? "order-1",
    hookId: overrides.hookId ?? hookId,
    dueAt: "2026-04-27T00:00:05.000Z",
    pokedAt: "2026-04-27T00:00:06.000Z",
  });

  assert.throws(
    () => replayChainEvents([...base, poke({ orderId: "order-ghost" })]),
    /chain oracle missing order .*:unknown-target:order-ghost/,
  );
  assert.throws(
    () =>
      replayChainEvents([orderRegistered, signalSubmitted, statusWait, poke({})]),
    /chain oracle missing plan /,
  );
  assert.throws(
    () =>
      replayChainEvents([
        ...base,
        poke({ hookId: "0x000000000000000000000000000000000000000000000000000000000000e999" }),
      ]),
    /chain oracle missing hook 0x000000000000000000000000000000000000000000000000000000000000e999/,
  );
  const quietResult = replayChainEvents([
    ...base,
    poke({ hookId: quietHookId }),
  ]);
  assert.deepEqual(quietResult.mismatches, []);
  assert.deepEqual(quietResult.observed, quietResult.expected);
  assert.equal(
    quietResult.state.orders[`${planId}::order-1`]?.hookStatuses[quietHookId],
    undefined,
  );
});

test("chain replay sorts the stream into canonical order before gating", () => {
  const planId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000c001";
  const hookId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000c101";
  const stageId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000c201";
  const sourceId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000c301";
  const signalId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000c401";
  const keyId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000c501";
  const base = {
    planId,
    zhixuId: "canonical-reorder",
    orderId: "reorder-1",
  };
  const planRegistered: ChainModeEvent = {
    eventName: "PlanRegistered",
    blockNumber: 1,
    logIndex: 0,
    transactionHash: "0x01",
    plan: {
      planId,
      zhixuId: "canonical-reorder",
      compiledHooks: [
        {
          hookId,
          stageId,
          stageIdentifier: "main",
          hookName: "TIMEOUT",
          orderTriggerKind: "none",
          emitReady: true,
          instructions: [
            { op: "SIGNAL", sourceId, signalId, signalKey: keyId },
            { op: "DELAY", delaySeconds: 5 },
          ],
        },
      ],
      dependencyIndex: { [keyId]: [hookId] },
    },
  };
  const orderRegistered: ChainModeEvent = {
    eventName: "OrderRegistered",
    blockNumber: 2,
    logIndex: 0,
    transactionHash: "0x02",
    ...base,
    registeredAt: "2026-04-27T00:00:00.000Z",
  };
  const signalSubmitted: ChainModeEvent = {
    eventName: "SignalSubmitted",
    blockNumber: 3,
    logIndex: 0,
    transactionHash: "0x03",
    ...base,
    sourceId,
    signalId,
    signalKey: keyId,
    senderId: "pay-executor",
    submittedAt: "2026-04-27T00:00:00.000Z",
  };
  const statusWait: ChainModeEvent = {
    eventName: "HookStatusChanged",
    blockNumber: 4,
    logIndex: 0,
    transactionHash: "0x04",
    ...base,
    hookId,
    previousStatus: "init",
    newStatus: "wait",
    dueAt: "2026-04-27T00:00:05.000Z",
  };
  const timerPoked: ChainModeEvent = {
    eventName: "TimerPoked",
    blockNumber: 6,
    logIndex: 0,
    transactionHash: "0x05",
    ...base,
    hookId,
    dueAt: "2026-04-27T00:00:05.000Z",
    pokedAt: "2026-04-27T00:00:06.000Z",
  };
  const hookReady: ChainHookReadyEvent = {
    eventName: "HookReady",
    blockNumber: 7,
    logIndex: 0,
    transactionHash: "0x06",
    ...base,
    hookId,
    stageIdentifier: "main",
    hookName: "TIMEOUT",
  };
  const scrambled: ChainModeEvent[] = [
    timerPoked,
    hookReady,
    planRegistered,
    orderRegistered,
    signalSubmitted,
    statusWait,
  ];

  const result = replayChainEvents(scrambled);
  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);
  const runtime = result.state.orders[`${planId}::reorder-1`]?.hookStatuses[hookId];
  assert.equal(runtime?.status, "ready");

  assert.throws(
    () => replayChainEvents(scrambled, { sort: false }),
    /chain oracle missing order /,
  );
});

test("chain replay fails loudly when TimerPoked carries no pokedAt", () => {
  const planId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000d001";
  const hookId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000d101";
  const stageId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000d201";
  const sourceId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000d301";
  const signalId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000d401";
  const keyId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000d501";
  const base = {
    planId,
    zhixuId: "poked-at-required",
    orderId: "order-1",
  };
  const events: ChainModeEvent[] = [
    {
      eventName: "PlanRegistered",
      blockNumber: 1,
      logIndex: 0,
      transactionHash: "0x01",
      plan: {
        planId,
        zhixuId: "poked-at-required",
        compiledHooks: [
          {
            hookId,
            stageId,
            stageIdentifier: "main",
            hookName: "TIMEOUT",
            orderTriggerKind: "none",
            emitReady: true,
            instructions: [
              { op: "SIGNAL", sourceId, signalId, signalKey: keyId },
              { op: "DELAY", delaySeconds: 5 },
            ],
          },
        ],
        dependencyIndex: { [keyId]: [hookId] },
      },
    },
    {
      eventName: "OrderRegistered",
      blockNumber: 2,
      logIndex: 0,
      transactionHash: "0x02",
      ...base,
      registeredAt: "2026-04-27T00:00:00.000Z",
    },
    {
      eventName: "SignalSubmitted",
      blockNumber: 3,
      logIndex: 0,
      transactionHash: "0x03",
      ...base,
      sourceId,
      signalId,
      signalKey: keyId,
      senderId: "pay-executor",
      submittedAt: "2026-04-27T00:00:00.000Z",
    },
    {
      eventName: "HookStatusChanged",
      blockNumber: 4,
      logIndex: 0,
      transactionHash: "0x04",
      ...base,
      hookId,
      previousStatus: "init",
      newStatus: "wait",
      dueAt: "2026-04-27T00:00:05.000Z",
    },
  ];
  const pokeWithoutClock = {
    eventName: "TimerPoked",
    blockNumber: 5,
    logIndex: 0,
    transactionHash: "0x05",
    ...base,
    hookId,
    dueAt: "2026-04-27T00:00:05.000Z",
  } as unknown as ChainModeEvent;

  assert.throws(
    () => replayChainEvents([...events, pokeWithoutClock]),
    /TimerPoked .* is missing a valid pokedAt/,
  );
  assert.throws(
    () =>
      replayChainEvents([
        ...events,
        { ...pokeWithoutClock, pokedAt: 1777248006000 } as unknown as ChainModeEvent,
      ]),
    /is missing a valid pokedAt/,
  );
});

test("chain replay rejects non-integer sorting keys loudly", () => {
  const event = {
    eventName: "OrderRegistered" as const,
    logIndex: 0,
    transactionHash: "0x01" as const,
    planId: "0x01" as `0x${string}`,
    zhixuId: "demo",
    orderId: "order-1",
    registeredAt: "2026-04-27T00:00:00.000Z",
  };
  for (const bad of [
    { ...event, blockNumber: 1.5 },
    { ...event, blockNumber: Number.NaN },
    { ...event },
  ]) {
    assert.throws(
      () => replayChainEvents([bad as unknown as ChainModeEvent]),
      /sorting refuses to fold a non-integer to 0/,
    );
  }
});
