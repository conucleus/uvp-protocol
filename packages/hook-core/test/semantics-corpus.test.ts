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
  readonly schemaVersion: string;
  readonly parseCases: readonly ParseCase[];
  readonly evalCases: readonly EvalCase[];
  readonly invalidCases: readonly InvalidCase[];
}

interface ParseCase {
  readonly name: string;
  readonly profile: string;
  /** 校验档（uvp-hook-dsl Gate）：缺省 = 钩子档；filter = 发射适格面档。 */
  readonly gate?: "hook" | "filter";
  readonly hookName: string;
  readonly hook: string;
  readonly expect: {
    readonly source: string;
    readonly mode: string;
    readonly runtimeCondition: string;
    readonly normalizedExpression: string;
    readonly dependencies: readonly HookDependency[];
  };
}

interface EvalCase {
  readonly name: string;
  readonly profile: string;
  /** 校验档（uvp-hook-dsl Gate）：缺省 = 钩子档；filter = 发射适格面档。 */
  readonly gate?: "hook" | "filter";
  readonly hookName: string;
  readonly hook: string;
  readonly signals: readonly SignalFact[];
  readonly now: string;
  readonly expect: {
    readonly state: string;
    readonly readyAt?: string;
    readonly expiresAt?: string;
    readonly reasonContains?: string;
  };
}

interface InvalidCase {
  readonly name: string;
  readonly profile: string;
  /** 校验档（uvp-hook-dsl Gate）：缺省 = 钩子档；filter = 发射适格面档。 */
  readonly gate?: "hook" | "filter";
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
  readonly runtimeCondition: string;
  readonly normalizedExpression: string;
  readonly dependencies: readonly HookDependency[];
  readonly cloudAst: unknown;
}

interface CoreEvalHookOutput {
  readonly state: string;
  readonly readyAt?: string;
  readonly expiresAt?: string;
  readonly reason?: string;
}

async function loadCorpus(): Promise<Corpus> {
  const corpus = JSON.parse(await readFile(corpusUrl, "utf8")) as Corpus;
  // 语料格式版本钉住：v2 迁移时这里必须先响亮失败，消费面不得静默按旧
  // 口径解读新文件（Rust replay/Go 消费测试同款断言）。
  assert.equal(
    corpus.schemaVersion,
    "uvp.hookSemanticsCorpus.v1",
    "corpus schemaVersion drifted; migrate every consumer before shipping the new file"
  );
  return corpus;
}

test("uvp-core N-API parses hook semantic corpus", async () => {
  const compatibility = uvpCoreCompatibility();
  assert.equal(compatibility.coreVersion, "0.1.0");
  assert.equal(compatibility.semanticVersion, "uvp.semantic.v1");
  // 指纹门：uvp-node 的 JS 包装已 re-export buildFingerprint，指纹必须以
  // git-<rev> 形式在场并被纳入比对（no-git- 形态在 uvpCoreCompatibility
  // 内直接拒绝）。
  if ("buildFingerprint" in compatibility) {
    assert.match(compatibility.buildFingerprint ?? "", /^git-[0-9a-f]{7,40}$/);
  }
  const corpus = await loadCorpus();
  for (const item of corpus.parseCases) {
    const output = parseHookWithUvpCore({
      profile: item.profile,
      // 过滤档用例按条目声明的 gate 走（缺省 = 钩子档，与 serde default
      // 同口径）——漏传会把过滤档形态按钩子档误判。
      ...(item.gate === undefined ? {} : { gate: item.gate }),
      hookName: item.hookName,
      hook: item.hook
    }) as CoreParseHookOutput;

    assert.equal(output.source, item.expect.source, item.name);
    assert.equal(output.mode, item.expect.mode, item.name);
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
      ...(item.gate === undefined ? {} : { gate: item.gate }),
      hookName: item.hookName,
      hook: item.hook
    }) as CoreParseHookOutput;
    const output = evaluateHookWithUvpCore({
      profile: item.profile,
      // 求值的解码防御按 gate 运行对应校验档（eval_compiled_hook 同参）。
      ...(item.gate === undefined ? {} : { gate: item.gate }),
      ast: parsed.cloudAst,
      signals: item.signals,
      now: item.now
    }) as CoreEvalHookOutput;

    assert.equal(output.state, item.expect.state, item.name);
    if (item.expect.readyAt) {
      assert.equal(output.readyAt, item.expect.readyAt, item.name);
    }
    // 衰减维度对每个 eval 用例整体钉死（缺席 = 无限期），不做
    // "写了才比对"（与 Rust 语料测试同款）：否则带否决位的用例漏写
    // expiresAt 会被静默放过。语料 JSON 的显式 null 与 NAPI 输出的缺省
    // 键是同一个"无期限"语义（serde Option skip_serializing_if），比较前
    // 双侧归一，不为 null 形态单开第二种"有值"读法。
    assert.equal(output.expiresAt ?? null, item.expect.expiresAt ?? null, item.name);
    if (item.expect.reasonContains) {
      // Rust 语料消费是子串包含（contains）：否决位成熟用例的 reason 带
      // `+14d`，按 RegExp 解释会把加号当量词误判——同口径用 includes。
      assert.ok(
        (output.reason ?? "").includes(item.expect.reasonContains),
        item.name,
      );
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
        ...(item.gate === undefined ? {} : { gate: item.gate }),
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
