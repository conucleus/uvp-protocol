import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  ChainReplayMismatchError,
  replayChainEvents,
  type ChainModeEvent,
  type ChainReplayResult
} from "../src/index.js";

const corpusUrl = new URL("../../../../uvp-core/fixtures/hook/semantics.v1.json", import.meta.url);

interface MismatchDetail {
  readonly reason: string;
  readonly hook: string;
  readonly occurrence: number;
}

interface ReplayCase {
  readonly name: string;
  readonly events: readonly ChainModeEvent[];
  readonly expect: {
    readonly orderKey?: string;
    readonly signalKey?: string;
    readonly senderId?: string;
    readonly eventId?: string;
    readonly observedCount: number;
    readonly mismatchCount: number;
    readonly observedEvents?: readonly string[];
    readonly waitDueAt?: string;
    readonly finalHookStatuses?: Readonly<Record<string, Readonly<Record<string, string>>>>;
    readonly mismatchDetails?: readonly MismatchDetail[];
    readonly errorContains?: string;
  };
}

interface Corpus {
  readonly schemaVersion: string;
  readonly replayCases: readonly ReplayCase[];
}

async function loadCorpus(): Promise<Corpus> {
  return JSON.parse(await readFile(corpusUrl, "utf8")) as Corpus;
}

/**
 * The shared semantic corpus pins native-core semantics and predates the
 * frozen v0.10 chain-event contract: its replayCases carry the projected
 * pre-freeze HookStatusChanged shape (single `status`). replayChainEvents
 * only accepts frozen v0.10 events carrying previousStatus/newStatus, so
 * this test-side adapter lifts `status` onto `newStatus` before replaying.
 */
function liftCorpusEventToFrozenChainEvent(event: ChainModeEvent): ChainModeEvent {
  const raw = event as unknown as Record<string, unknown>;
  if (event.eventName !== "HookStatusChanged" || "newStatus" in raw) {
    return event;
  }
  if (typeof raw.status !== "string") {
    throw new Error(
      `corpus HookStatusChanged ${String(raw.hookId)} carries neither newStatus nor status`
    );
  }
  return { ...raw, newStatus: raw.status } as unknown as ChainModeEvent;
}

/**
 * 互证口径：同一份语料同时喂 Rust uvp-replay（native 测试）与本 TS oracle
 * 包装层。TS 侧不是复刻一份求值器，而是钉住适配层的门与投影（默认排序、
 * poke 守门、v0.10 形状抬升）不得分叉 native 结论——mismatch 条目经由
 * ChainReplayMismatchError 的 mismatch 集合逐条比对（reason/hook/
 * occurrence），干净条目比对全部观察细节。
 */
test("chain replay follows shared hook semantic corpus", async () => {
  const corpus = await loadCorpus();
  // 语料格式版本钉住：v2 迁移时这里必须先响亮失败（Rust/Go 消费测试同款）。
  assert.equal(
    corpus.schemaVersion,
    "uvp.hookSemanticsCorpus.v1",
    "corpus schemaVersion drifted; migrate every consumer before shipping the new file"
  );
  for (const item of corpus.replayCases) {
    if (item.expect.errorContains !== undefined) {
      let message = "";
      try {
        replayChainEvents(item.events.map(liftCorpusEventToFrozenChainEvent));
      } catch (error) {
        message = error instanceof Error ? error.message : String(error);
      }
      assert.notEqual(message, "", item.name);
      assert.ok(
        message.includes(item.expect.errorContains),
        `${item.name} error ${message} did not contain ${item.expect.errorContains}`
      );
      continue;
    }

    let result: ChainReplayResult | undefined;
    try {
      result = replayChainEvents(item.events.map(liftCorpusEventToFrozenChainEvent));
    } catch (error) {
      if (item.expect.mismatchCount > 0) {
        // 非空 mismatch 集合在导出面恒转为 ChainReplayMismatchError：断言
        // 集合本身（reason + hook + occurrence），而不是只数条数。
        assert.ok(
          error instanceof ChainReplayMismatchError,
          `${item.name} must surface mismatches as ChainReplayMismatchError`
        );
        const mismatches = error.mismatches as unknown as readonly Record<string, unknown>[];
        assert.equal(mismatches.length, item.expect.mismatchCount, item.name);
        const details = item.expect.mismatchDetails ?? [];
        assert.equal(mismatches.length, details.length, `${item.name} mismatch set size`);
        mismatches.forEach((mismatch, index) => {
          const detail = details[index];
          assert.ok(detail !== undefined, `${item.name} mismatch[${index}] has no pinned detail`);
          assert.equal(
            mismatch.reason,
            detail.reason,
            `${item.name} mismatch[${index}] reason`
          );
          assert.equal(mismatch.hook, detail.hook, `${item.name} mismatch[${index}] hook`);
          assert.equal(
            mismatch.occurrence,
            detail.occurrence,
            `${item.name} mismatch[${index}] occurrence`
          );
        });
        continue;
      }
      throw error;
    }

    assert.equal(result.observed.length, item.expect.observedCount, item.name);
    assert.equal(result.mismatches.length, item.expect.mismatchCount, item.name);
    if (item.expect.orderKey !== undefined && item.expect.signalKey !== undefined) {
      const signal = result.state.orders[item.expect.orderKey]?.signals[item.expect.signalKey];
      assert.equal(signal?.senderId, item.expect.senderId, item.name);
      assert.equal(signal?.eventId, item.expect.eventId, item.name);
    }
    if (item.expect.observedEvents !== undefined) {
      assert.deepEqual(
        result.observed.map((observation) => observation.eventName),
        item.expect.observedEvents,
        item.name
      );
    }
    if (item.expect.waitDueAt !== undefined) {
      const waits = result.observed.filter(
        (observation) =>
          observation.eventName === "HookStatusChanged" && observation.status === "wait"
      ) as Array<{ readonly dueAt?: string }>;
      assert.equal(waits.length, 1, `${item.name} expected exactly one wait observation`);
      assert.equal(waits[0]?.dueAt, item.expect.waitDueAt, item.name);
    }
    if (item.expect.finalHookStatuses !== undefined) {
      for (const [orderKey, hooks] of Object.entries(item.expect.finalHookStatuses)) {
        for (const [hookId, status] of Object.entries(hooks)) {
          assert.equal(
            result.state.orders[orderKey]?.hookStatuses[hookId]?.status,
            status,
            item.name
          );
        }
      }
    }
  }
});
