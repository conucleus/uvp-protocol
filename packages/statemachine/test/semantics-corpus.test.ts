import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { replayChainEvents, type ChainModeEvent } from "../src/index.js";

const corpusUrl = new URL("../../../../uvp-core/fixtures/hook/semantics.v1.json", import.meta.url);

interface Corpus {
  readonly replayCases: readonly ReplayCase[];
}

interface ReplayCase {
  readonly name: string;
  readonly events: readonly ChainModeEvent[];
  readonly expect: {
    readonly orderKey: string;
    readonly signalKey: string;
    readonly senderId: string;
    readonly eventId: string;
    readonly observedCount: number;
    readonly mismatchCount: number;
  };
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

test("chain replay follows shared hook semantic corpus", async () => {
  const corpus = await loadCorpus();
  for (const item of corpus.replayCases) {
    const result = replayChainEvents(item.events.map(liftCorpusEventToFrozenChainEvent));
    const signal = result.state.orders[item.expect.orderKey]?.signals[item.expect.signalKey];

    assert.equal(result.observed.length, item.expect.observedCount, item.name);
    assert.equal(result.mismatches.length, item.expect.mismatchCount, item.name);
    assert.equal(signal?.senderId, item.expect.senderId, item.name);
    assert.equal(signal?.eventId, item.expect.eventId, item.name);
  }
});
