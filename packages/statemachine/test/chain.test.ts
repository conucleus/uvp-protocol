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

test("chain replay registers admission-declared plans without replay-side filtering", async () => {
  // 发射适格面（UVPStateMachine commitPlan 的 flag=8 槽位）：PlanRegistered
  // 携带 admissions 时 native 注册门按 _validateAdmission 镜像校验指令形
  // 态（过滤档：根位衰减否决合法）。适格求值发生在提交一拍——回放流
  // 里被准入的发射只是普通 SignalSubmitted，拒绝面 revert 零事件：两种
  // 情况都不产生任何 admission 派生观察，回放与无适格 plan 同形。
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
  // 适格面对求值守卫/观察面零贡献：本段唯一的观察是 watcher 的 HookReady。
  const admissionObservations = result.observed.filter(
    (observation) => observation.planId === admissionPlanId,
  );
  assert.deepEqual(admissionObservations.map((observation) => observation.eventName), ["HookReady"]);
});

test("chain-mode ordering is the canonical (blockNumber, logIndex) pair", () => {
  // EVM 索引面的规范全序是 (blockNumber, logIndex)：logIndex 在块内跨
  // 交易唯一递增，transactionIndex 是可缺省的冗余 enrichment，不参与
  // 排序（native replay 的排序键只有这两个维度，镜像层多出的维度会把
  // 守门预排序与 native 求值序拆成两个口径）。
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

  // 块内只看 logIndex：txIdx 的大小/有无不参与比较。
  const late = event(10, 1, 7);
  const early = event(10, 3, 5);
  assert.equal(compareChainEvents(early, late) < 0, true);
  assert.equal(compareChainEvents(late, early) > 0, true);
  // 同 (blockNumber, logIndex) ⇒ 0：混合 txIdx 有无、txIdx 不同都相等，
  // 稳定排序保持到达序（与 native 稳定 sort 同口径）。
  const sameKeyVariants = [
    event(10, 9, 5),
    event(10, 0, 5),
    event(10, undefined, 5),
  ];
  for (const variant of sameKeyVariants) {
    assert.equal(compareChainEvents(early, variant), 0);
    assert.equal(compareChainEvents(variant, early), 0);
  }
  // 跨块由 blockNumber 决定，logIndex 反向不影响。
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

test("chain replay filters contract-impossible TimerPoked events (pokeTimer gate)", async () => {
  // UVPStateMachine.pokeTimer 对非 Wait 态 revert TimerNotWaiting、未到期
  // revert TimerNotDue——两类交易在链上不可能产出 TimerPoked 事件。golden
  // fixture 历史上携带过"已 cxl 的 hook 又被 poke"的序列（order-cancel 段），
  // 该事故暴露 oracle 不建模合约守门：不可产生的事件被无条件喂给 native
  // 回放。守门必须把这些事件挡在 native 层之外，且注入后回放终态与
  // 干净流逐字节一致（不可能事件是惰性的）。
  const events = await loadChainEvents();
  const planId = "0x312bed89090d5be24d38a236e312f8734d64dff50f8da3376542bee659dbb35d";
  const cancelHook = "0x0000000000000000000000000000000000000000000000000000000000003002";
  const timerHook = "0x0000000000000000000000000000000000000000000000000000000000003002";

  const impossible: ChainModeEvent[] = [
    // 已 cxl 的 hook 被 poke（TimerNotWaiting——golden 事故序列原样注入）。
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
    // Wait 态但未到期（TimerNotDue：pokedAt < dueAt）。
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
    // 事件自报的 dueAt 与守门状态不一致（守门值 00:01:05，事件自报
    // 00:01:00 伪造"已到期"）：到期判据只能取守门推导值，事件声称值
    // 仅作一致性核验——链上 pokeTimer 读的是合约存储，事件无权覆盖。
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
    // 冻结前形状（不带 dueAt 声称）：判定完全由守门值承担——pokedAt 仍
    // 小于守门 dueAt（00:01:05）即 TimerNotDue，不得因"事件未声称"放行。
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
  // 不可能事件不得改动回放终态（守门是过滤，不是吸收进求值）。
  assert.deepEqual(polluted.state, clean.state);
  assert.deepEqual(polluted.observed, clean.observed);
});

test("chain replay fails loudly when TimerPoked targets an unknown order/plan/hook", () => {
  // native evaluate_timer_hook 的目标解析序（order → plan → hook，uvp-replay
  // transition 与 facts 的查表）：缺任一目标整场响亮失败——查无此目标的
  // poke 只能出自损坏的事件流，静默滤除会把结构性毒流伪装成干净回放。
  // 镜像层按同一序抛错、用同款错误文案；已知 hook 但从未见过状态转移
  // （native eligibility 的 `_ => false` 分支）仍是静默跳过，不是响亮失败。
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

  // 查无此 order（事件三元组在订单登记簿外）。
  assert.throws(
    () => replayChainEvents([...base, poke({ orderId: "order-ghost" })]),
    /chain oracle missing order .*:unknown-target:order-ghost/,
  );
  // 查无此 plan：订单在册但流缺 PlanRegistered（native 按订单的 planId
  // 查 plan，同键缺注册同样整场失败）。
  assert.throws(
    () =>
      replayChainEvents([orderRegistered, signalSubmitted, statusWait, poke({})]),
    /chain oracle missing plan /,
  );
  // 查无此 hook（plan 的 compiledHooks 之外）。
  assert.throws(
    () =>
      replayChainEvents([
        ...base,
        poke({ hookId: "0x000000000000000000000000000000000000000000000000000000000000e999" }),
      ]),
    /chain oracle missing hook 0x000000000000000000000000000000000000000000000000000000000000e999/,
  );
  // 已知 hook 但从未见过状态转移（QUIET 未收到信号、无 wait 观察）：
  // native 的 eligibility 对无 runtime 的 hook 静默跳过，镜像层过滤而非
  // 抛错——回放保持干净，且终态不含 QUIET 的任何推导。
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

test("TimerPokeGate parses strictly-RFC3339 timestamps and compares in the seconds domain", () => {
  // native seconds_from_iso = chrono parse_from_rfc3339 + .timestamp()：
  // 严格 RFC3339 且秒域比较（链上 dueAt 是 uint64 秒）。date-only、无
  // 偏移、越界分量回卷等 Date.parse 的宽容面在 wait+due 分支下整场响亮
  // 失败；同秒内的亚秒差不构成"未到期"，声称值的一致性也在秒域核验。
  const planId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000f011";
  const hookId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000f111";
  const stageId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000f211";
  const sourceId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000f311";
  const signalId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000f411";
  const keyId: `0x${string}` = "0x000000000000000000000000000000000000000000000000000000000000f511";
  const zhixuId = "strict-rfc3339";
  const base: ChainModeEvent[] = [
    {
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
        ],
        dependencyIndex: { [keyId]: [hookId] },
      },
    },
    {
      eventName: "OrderRegistered",
      blockNumber: 2,
      logIndex: 0,
      transactionHash: "0x02",
      planId,
      zhixuId,
      orderId: "order-1",
      registeredAt: "2026-04-27T00:00:00.000Z",
    },
    {
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
    },
    {
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
    },
  ];
  const poke = (pokedAt: string, dueAt?: string): ChainModeEvent =>
    ({
      eventName: "TimerPoked",
      blockNumber: 6,
      logIndex: 0,
      transactionHash: "0x06",
      planId,
      zhixuId,
      orderId: "order-1",
      hookId,
      ...(dueAt === undefined ? {} : { dueAt }),
      pokedAt,
      // 缺省 dueAt 声称是冻结前形状，与该文件其他用例同款抬升手法。
    }) as unknown as ChainModeEvent;

  // 守门 dueAt / pokedAt 非法（chrono 拒绝的形态）整场响亮失败。
  for (const bad of [
    "2026-04-27",
    "2026-04-27T00:00:06",
    "2026-02-30T00:00:06.000Z",
    "2026-04-27T24:00:06.000Z",
    " 2026-04-27T00:00:06.000Z",
    "2026-04-27T00:00:06.000Z ",
  ]) {
    assert.throws(
      () => replayChainEvents([...base, poke(bad)]),
      /invalid chain oracle timestamp/,
      `pokedAt=${bad} must fail loudly as non-RFC3339`,
    );
  }
  const withBadTrackedDueAt = base.map((event) =>
    event.eventName === "HookStatusChanged"
      ? { ...event, dueAt: "2026-04-27" }
      : event,
  );
  assert.throws(
    () => replayChainEvents([...withBadTrackedDueAt, poke("2026-04-27T00:00:06.000Z")]),
    /invalid chain oracle timestamp 2026-04-27/,
  );

  // 秒域核验：声称值与守门值差在亚秒（同秒）时不再判"不一致"——
  // 链上 dueAt 本就是 uint64 秒，亚秒差异不是语义分歧；poke 放行后
  // native 重算出 HookReady。
  const admitted = replayChainEvents([
    ...base,
    poke("2026-04-27T00:00:06.000Z", "2026-04-27T00:00:05.900Z"),
    {
      eventName: "HookReady",
      blockNumber: 7,
      logIndex: 0,
      transactionHash: "0x07",
      planId,
      zhixuId,
      orderId: "order-1",
      hookId,
      stageIdentifier: "main",
      hookName: "TIMEOUT",
    },
  ]);
  assert.deepEqual(admitted.mismatches, []);
  assert.deepEqual(admitted.observed, admitted.expected);
  assert.equal(
    admitted.state.orders[`${planId}::order-1`]?.hookStatuses[hookId]?.status,
    "ready",
  );

  // 声称值是待核验的断言（native 无此通道）：date-only 的声称无法证明
  // 一致性，按不可能过滤——回放干净，hook 停留 wait，不得因"声称值
  // 在 Date.parse 下恰好折成同一天"而放行。
  const unverifiableClaim = replayChainEvents([...base, poke("2026-04-27T00:00:06.000Z", "2026-04-27")]);
  assert.deepEqual(unverifiableClaim.mismatches, []);
  assert.deepEqual(unverifiableClaim.observed, unverifiableClaim.expected);
  assert.equal(
    unverifiableClaim.state.orders[`${planId}::order-1`]?.hookStatuses[hookId]?.status,
    "wait",
  );
});

test("compareChainEvents stays a total order on the canonical key pair", () => {
  // 排序键只有 (blockNumber, logIndex)：txIdx 有无/大小不参与，键相同
  // 即比较结果为 0——反对称/传递性在含混合 txIdx 的构造集上成立，排序
  // 结果与输入顺序无关，同键事件保持到达序（稳定排序）。
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
  const A = event(1, undefined, 5);
  const B = event(1, 0, 5);
  const C = event(1, 1, 3);
  const pool = [
    event(1, undefined, 0),
    event(1, 0, 0),
    event(1, 0, 3),
    event(1, 2, 1),
    event(2, undefined, 0),
    event(2, 7, 9),
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
        x.blockNumber === y.blockNumber && x.logIndex === y.logIndex;
      assert.equal(xy === 0, sameKey);
      for (const z of pool) {
        const yz = compareChainEvents(y, z);
        const xz = compareChainEvents(x, z);
        if (xy < 0 && yz < 0) {
          assert.equal(xz < 0, true);
        }
      }
    }
  }
  // 同键三元组 {A, B}（block 1, log 5）稳定保序：无论输入顺序，A/B 的
  // 相对位置不变，C（log 3）恒在前。
  for (const items of [
    [A, B, C],
    [B, A, C],
    [C, A, B],
  ]) {
    const sorted = [...items].sort(compareChainEvents);
    assert.equal(sorted[0], C);
    assert.deepEqual(
      sorted.slice(1),
      items.filter((item) => item !== C),
    );
  }
});

test("chain replay sorts the stream into canonical order before gating", () => {
  // 到达序与规范序分叉的流：TimerPoked 在数组里先于 wait 转移出现，但
  // 块号在后。默认（sort 未显式给 false）必须先按 (blockNumber,
  // logIndex) 归位再守门/求值——按到达序守门会把合法 poke 按状态未知
  // 误删，链上 HookReady 变成 missing-observed 假 mismatch。native 侧
  // 对同一流默认即排序（共享语料 "timer poke replays after canonical
  // reordering" 是两侧同一钉子），镜像层默认口径必须与其一致。
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

  // 默认排序：合法 poke 被守门放行，native 重算出 HookReady，与链上
  // 观察配对成功。
  const result = replayChainEvents(scrambled);
  assert.deepEqual(result.mismatches, []);
  assert.deepEqual(result.observed, result.expected);
  const runtime = result.state.orders[`${planId}::reorder-1`]?.hookStatuses[hookId];
  assert.equal(runtime?.status, "ready");

  // 到达序模式（显式 sort:false，与 native 同口径关闭排序）：poke 先于
  // 订单登记到达，目标解析查无此 order——native 对同一流同样整场响亮
  // 失败（evaluate_timer_hook 的查表序），镜像层不得把它滤成"状态未知"
  // 后的 missing-observed 假 mismatch。这是"为什么要默认排序"的可观察面。
  assert.throws(
    () => replayChainEvents(scrambled, { sort: false }),
    /chain oracle missing order /,
  );
});

test("chain replay fails loudly when TimerPoked carries no pokedAt", () => {
  // pokedAt 是本 tick 的求值时钟：native 对 TimerPoked 一进门就要求
  // 字符串 pokedAt（缺失/非串整场回放响亮失败，uvp-replay 的
  // timer_poked_without_poked_at_fails_loudly 是权威侧钉子），镜像层同
  // 口径抛错——不得把毒事件静默滤成"不存在"。
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
  // 非字符串形态同罪（数字时钟不是可解析的 RFC3339 时刻）。
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
  // 排序键 (blockNumber, logIndex) 非整数（或缺失）时折 0 会把事件流
  // 静默重排成错误因果序——与 native 排序门同口径响亮失败。
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
