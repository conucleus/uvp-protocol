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

test("chain replay follows shared hook semantic corpus", async () => {
  const corpus = await loadCorpus();
  for (const item of corpus.replayCases) {
    const result = replayChainEvents(item.events);
    const signal = result.state.orders[item.expect.orderKey]?.signals[item.expect.signalKey];

    assert.equal(result.observed.length, item.expect.observedCount, item.name);
    assert.equal(result.mismatches.length, item.expect.mismatchCount, item.name);
    assert.equal(signal?.senderId, item.expect.senderId, item.name);
    assert.equal(signal?.eventId, item.expect.eventId, item.name);
  }
});
