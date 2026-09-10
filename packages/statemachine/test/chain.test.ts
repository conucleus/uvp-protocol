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

  // Golden legality gate: the fixture's DELAY-carrying hook (TIMEOUT) must be
  // a non-trigger watcher. order-trigger hooks carrying DELAY are unregistrable
  // on-chain (UVPStateMachine._validateHook reverts InvalidInstruction at
  // commitPlan), so a golden fixture must not carry that shape.
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
        compiledHooks: [
          {
            hookId: andLatestWaitHookId,
            stageId: andLatestWaitStageId,
            stageIdentifier: "latest-wait-stage",
            hookName: "latest-wait-hook",
            // order-trigger（mint/dock）hook 携 DELAY 在 commitPlan 即 revert
            // InvalidInstruction——链上不可注册；本场景只验证 AND 延时分支
            // 的等待语义，按合法 watcher（none）形态构造。
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
  // order-link 出生（triggerOrderFromSignalFromModule → _markTriggerHookReady）
  // 不 _recordSignal 但 emit HookStatusChanged(→reg) + HookReady +
  // StageMaterialized。native oracle 从 HookReady 推导出生事实（唯一实现）：
  // 流可回放，expected==observed，且终态回填 hook=reg + 阶段物化。
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
  // 出生事实不落子单信号集：链上 order-link 路径不 _recordSignal，
  // 派生不得伪造 SignalSubmitted 状态。
  assert.deepEqual(childOrder?.signals, {});
});

test("chain replay exposes duplicated birth HookReady as a mismatch", () => {
  // 合约 HookReady 只在 !readyEmitted 时发出（_markOrderTriggerHookReady），
  // 逐字重复的出生 HookReady 是流异常——native 推导只接受第一次断言，
  // 第二条必须以 missing-observed 暴露，不得静默吸收。
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

test("compareChainEvents stays a total order with mixed transactionIndex presence (P2-5)", () => {
  // 2609100741 P2-5 / 2609100328 疑点12：旧口径只在"双方都有且不等"时才比
  // transactionIndex，混合有无时落到 logIndex/txHash——反例三元组
  // A(无 txIdx, log 5) / B(txIdx 0, log 5) / C(txIdx 1, log 3) 按两两比较
  // 得出 A==B、B<C、A>C 的矛盾序，排序结果依赖输入顺序。修复后缺失
  // txIdx 恒排末位且同维度一致应用：全序确定、无环。
  const hash = `0x${"ab".repeat(32)}` as `0x${string}`;
  const event = (
    blockNumber: number,
    transactionIndex: number | undefined,
    logIndex: number,
    transactionHash: `0x${string}`,
  ): Parameters<typeof compareChainEvents>[0] => ({
    eventName: "OrderRegistered",
    blockNumber,
    ...(transactionIndex === undefined ? {} : { transactionIndex }),
    logIndex,
    transactionHash,
  });
  const A = event(1, undefined, 5, hash);
  const B = event(1, 0, 5, hash);
  const C = event(1, 1, 3, hash);

  // 旧口径的环：A==B（logIndex 相等后落 txHash 相等）但 B<C 而 A>C。
  // 新口径：缺失 txIdx 排末位 → B < C < A，三对两两一致。
  assert.equal(compareChainEvents(B, C) < 0, true);
  assert.equal(compareChainEvents(C, A) < 0, true);
  assert.equal(compareChainEvents(B, A) < 0, true);
  assert.equal(compareChainEvents(A, B) > 0, true);
  assert.equal(compareChainEvents(A, A), 0);
  assert.equal(compareChainEvents(B, B), 0);

  // 排序结果与输入顺序无关（确定性/传递性的可观察面）。
  const permutations = [
    [A, B, C],
    [A, C, B],
    [B, A, C],
    [B, C, A],
    [C, A, B],
    [C, B, A],
  ];
  const ordered = permutations.map((items) => [...items].sort(compareChainEvents));
  for (const candidate of ordered) {
    assert.deepEqual(candidate, [B, C, A]);
  }

  // 性质检查：构造集上比较器满足反对称 + 传递（无环）。
  const pool = [
    event(1, undefined, 0, hash),
    event(1, 0, 0, hash),
    event(1, 0, 3, hash),
    event(1, 2, 1, hash),
    event(2, undefined, 0, hash),
    event(2, 7, 9, hash),
    A,
    B,
    C,
  ];
  for (const x of pool) {
    for (const y of pool) {
      const xy = compareChainEvents(x, y);
      const yx = compareChainEvents(y, x);
      // 反对称（含相等当且仅当同键）。Math.sign(±0) 得 ±0，node:assert 的
      // strictEqual 按 Object.is 区分——先归一到普通 0。
      assert.equal(Math.sign(xy) || 0, -(Math.sign(yx) || 0) || 0);
      const sameKey =
        x.blockNumber === y.blockNumber &&
        x.transactionIndex === y.transactionIndex &&
        x.logIndex === y.logIndex &&
        x.transactionHash === y.transactionHash;
      assert.equal(xy === 0, sameKey);
      for (const z of pool) {
        const yz = compareChainEvents(y, z);
        const xz = compareChainEvents(x, z);
        // 传递性：x<y && y<z ⇒ x<z（用 sign 归一 NaN 防假阴）。
        if (xy < 0 && yz < 0) {
          assert.equal(xz < 0, true);
        }
      }
    }
  }
});
