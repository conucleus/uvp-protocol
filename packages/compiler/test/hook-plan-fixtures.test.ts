import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import test from "node:test";
import {
  compileZhixuHookPlan,
  type ZhixuDefinition,
} from "../src/index.js";

/**
 * 链轨 hook_plan 语料（uvp-core fixtures 的 1:1 迁移）：11 个 target=hook_plan
 * fixture 的成功侧在这里断言 shell 形状（platform/hookIds/dependency 计数）；
 * 负例与 capabilities/admissions 归 uvp-core analyze 的共享校验，不在 TS 侧
 * 重复钉，corpus 清单本身作为迁移覆盖的账本。
 */

interface HookPlanFixture {
  readonly name: string;
  readonly semanticVersion: string;
  readonly target: string;
  readonly portable: boolean;
  readonly input: ZhixuDefinition;
  readonly expect: {
    readonly errorContains?: string;
    readonly platform?: string;
    readonly hookIds?: readonly string[];
    readonly hookDependencyCounts?: Readonly<Record<string, number>>;
  };
}

interface CorpusEntry {
  readonly directory: string;
  readonly file: string;
  readonly fixture: HookPlanFixture;
}

function fixtureDirectory(directory: string): URL {
  return new URL(`../fixtures/${directory}/`, import.meta.url);
}

function loadCorpus(): readonly CorpusEntry[] {
  const entries: CorpusEntry[] = [];
  for (const directory of ["zhixu", "evm"]) {
    for (const file of readdirSync(fixtureDirectory(directory)).sort()) {
      if (!file.endsWith(".json")) {
        continue;
      }
      const fixture = JSON.parse(
        readFileSync(new URL(file, fixtureDirectory(directory)), "utf8"),
      ) as HookPlanFixture;
      if (fixture.target === "hook_plan") {
        entries.push({ directory, file, fixture });
      }
    }
  }
  return entries;
}

function names(entries: readonly CorpusEntry[]): readonly string[] {
  return entries.map((entry) => entry.file).sort();
}

test("hook_plan fixture corpus stays at 10 (9 zhixu + 1 evm)", () => {
  const corpus = loadCorpus();
  assert.equal(corpus.length, 10);
  assert.equal(corpus.filter((entry) => entry.directory === "zhixu").length, 9);
  assert.equal(corpus.filter((entry) => entry.directory === "evm").length, 1);

  const negatives = corpus.filter(
    (entry) => entry.fixture.expect.errorContains !== undefined,
  );
  const executable = corpus.filter(
    (entry) => entry.fixture.expect.errorContains === undefined,
  );
  assert.deepEqual(names(negatives), [
    "onchain_watcher_only_stage_rejected.json",
    "onchain_zero_hook_stage_rejected.json",
    "static_executor_missing_rejected.json",
  ]);
  assert.equal(executable.length, 7);
});

test("hook_plan success fixtures compile to the migrated shell expectations", () => {
  const corpus = loadCorpus();
  for (const entry of corpus) {
    const { fixture } = entry;
    const expected = fixture.expect;
    if (expected.errorContains !== undefined) {
      continue;
    }
    const plan = compileZhixuHookPlan(fixture.input);
    if (expected.platform !== undefined) {
      assert.equal(
        plan.platform.type,
        expected.platform,
        `${fixture.name}: platform type`,
      );
    }
    if (expected.hookIds !== undefined) {
      assert.deepEqual(
        plan.compiledHooks.map((hook) => hook.hookId).sort(),
        [...expected.hookIds].sort(),
        `${fixture.name}: compiled hook ids`,
      );
    }
    for (const [hookId, dependencyCount] of Object.entries(
      expected.hookDependencyCounts ?? {},
    )) {
      const hook = plan.compiledHooks.find((candidate) => candidate.hookId === hookId);
      assert.ok(hook, `${fixture.name}: missing hook ${hookId}`);
      assert.equal(
        hook.dependencies.length,
        dependencyCount,
        `${fixture.name}: dependency count for ${hookId}`,
      );
    }
  }
});
