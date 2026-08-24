import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  evaluateHookWithUvpCore,
  parseHookWithUvpCore,
  uvpCoreCompatibility
} from "../src/index.js";

const corpusUrl = new URL("../../../../uvp-core/fixtures/hook/semantics.v1.json", import.meta.url);

interface Corpus {
  readonly parseCases: readonly ParseCase[];
  readonly evalCases: readonly EvalCase[];
  readonly invalidCases: readonly InvalidCase[];
}

interface ParseCase {
  readonly name: string;
  readonly profile: string;
  readonly hookName: string;
  readonly hook: string;
  readonly expect: {
    readonly source: string;
    readonly mode: string;
    readonly upstreamSource?: string;
    readonly runtimeCondition: string;
    readonly normalizedExpression: string;
    readonly dependencies: readonly HookDependency[];
  };
}

interface EvalCase {
  readonly name: string;
  readonly profile: string;
  readonly hookName: string;
  readonly hook: string;
  readonly signals: readonly SignalFact[];
  readonly now: string;
  readonly expect: {
    readonly state: string;
    readonly readyAt?: string;
    readonly reasonContains?: string;
  };
}

interface InvalidCase {
  readonly name: string;
  readonly profile: string;
  readonly hookName: string;
  readonly hook: string;
  readonly messageContains: string;
}

interface HookDependency {
  readonly kind: "positive" | "negative" | "timer";
  readonly source: string;
  readonly signalName: string;
  readonly delaySeconds?: number;
}

interface SignalFact {
  readonly source: string;
  readonly signalName: string;
  readonly receivedAt: string;
}

interface CoreParseHookOutput {
  readonly source: string;
  readonly mode: string;
  readonly upstreamSource?: string;
  readonly runtimeCondition: string;
  readonly normalizedExpression: string;
  readonly dependencies: readonly HookDependency[];
  readonly cloudAst: unknown;
}

interface CoreEvalHookOutput {
  readonly state: string;
  readonly readyAt?: string;
  readonly reason?: string;
}

async function loadCorpus(): Promise<Corpus> {
  return JSON.parse(await readFile(corpusUrl, "utf8")) as Corpus;
}

test("uvp-core N-API parses hook semantic corpus", async () => {
  assert.deepEqual(uvpCoreCompatibility(), {
    coreVersion: "0.1.0",
    semanticVersion: "uvp-semantic/0.3"
  });
  const corpus = await loadCorpus();
  for (const item of corpus.parseCases) {
    const output = parseHookWithUvpCore({
      profile: item.profile,
      hookName: item.hookName,
      hook: item.hook
    }) as CoreParseHookOutput;

    assert.equal(output.source, item.expect.source, item.name);
    assert.equal(output.mode, item.expect.mode, item.name);
    assert.equal(output.upstreamSource ?? null, item.expect.upstreamSource ?? null, item.name);
    assert.equal(output.runtimeCondition, item.expect.runtimeCondition, item.name);
    assert.equal(output.normalizedExpression, item.expect.normalizedExpression, item.name);
    assert.deepEqual(output.dependencies, item.expect.dependencies, item.name);
  }
});

test("uvp-core N-API evaluates hook semantic corpus", async () => {
  const corpus = await loadCorpus();
  for (const item of corpus.evalCases) {
    const parsed = parseHookWithUvpCore({
      profile: item.profile,
      hookName: item.hookName,
      hook: item.hook
    }) as CoreParseHookOutput;
    const output = evaluateHookWithUvpCore({
      profile: item.profile,
      ast: parsed.cloudAst,
      signals: item.signals,
      now: item.now
    }) as CoreEvalHookOutput;

    assert.equal(output.state, item.expect.state, item.name);
    if (item.expect.readyAt) {
      assert.equal(output.readyAt, item.expect.readyAt, item.name);
    }
    if (item.expect.reasonContains) {
      assert.match(output.reason ?? "", new RegExp(item.expect.reasonContains), item.name);
    }
  }
});

test("uvp-core N-API rejects invalid hook semantic corpus", async () => {
  const corpus = await loadCorpus();
  for (const item of corpus.invalidCases) {
    let message = "";
    try {
      parseHookWithUvpCore({
        profile: item.profile,
        hookName: item.hookName,
        hook: item.hook
      });
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }
    assert.notEqual(message, "", item.name);
    assert.ok(message.includes(item.messageContains), item.name);
  }
});
