/**
 * uvp-constraints.v1 一致性 harness（TS 线）。
 *
 * 约束注册表 `protocol/uvp-constraints.v1.json`（uvp-protocol 仓根）
 * 是跨语言接受面规则（zhixu / hook-dsl / dock / onchain-plan）的单一出处。
 * 本 harness：
 *   1. 钉住注册表 version + sha256 —— 任何一处改表，三线（TS/Rust/Go）测试同声报警；
 *   2. 对 applies 含 "ts" 的每条 rule 生成边界探针（满足/违反各一）打真 validator
 *      （zhixu-loader / onchain-hook-plan），断言真实错误文案锚点；
 *   3. ts 线没有探针 builder 的新 rule 会让本文件硬失败（防静默漏测）。
 *
 * 读不到注册表时硬失败并给出重建/路径指引，绝不 skip。
 */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { compileOnchainHookPlan } from "../src/onchain-hook-plan.js";
import { hookPlanHashOf } from "../src/dock-commitments.js";
import type { HookPlanArtifact } from "../src/types/index.js";
import {
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  loadZhixuDefinition,
  parseZhixuDefinition,
  validateOnchainHookPlanArtifact,
  ZhixuLoadError,
} from "../src/index.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// 注册表加载 + 版本/摘要钉
// ---------------------------------------------------------------------------

const CONSTRAINTS_ENV_VAR = "UVP_CONSTRAINTS_PATH";
// 默认路径：packages/compiler/test → 仓库根 protocol/。
const DEFAULT_CONSTRAINTS_PATH = join(
  __dirname,
  "..",
  "..",
  "..",
  "protocol",
  "uvp-constraints.v1.json",
);

const PINNED_VERSION = "uvp.constraints.v1" as const;
// sha256(uvp-constraints.v1.json)。改表必须三线同步更新：
//   uvp-protocol packages/compiler/test/constraints-registry.test.ts
//   uvp-core      crates/uvp-compiler/tests/constraints_registry.rs
//   miniprogram   pkg/compiler/validator/constraints_registry_test.go
const PINNED_SHA256 =
  "8aefc28d9a3be2a034b8d2ec5a232dba2515337818dc62de927fb4ea5141ec5a";

interface ConstraintsRule {
  readonly id: string;
  readonly applies: readonly string[];
  readonly constraint: { readonly type: string; readonly params: Record<string, unknown> };
  readonly error: { readonly ts: readonly string[] | string | null };
}

function loadConstraintsTable(): { raw: string; table: { version: string; rules: readonly ConstraintsRule[] } } {
  const path = process.env[CONSTRAINTS_ENV_VAR] ?? DEFAULT_CONSTRAINTS_PATH;
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    throw new Error(
      `[uvp-constraints] 读不到跨语言约束注册表（硬失败，不 skip）：${path}\n` +
        `  - 设置 ${CONSTRAINTS_ENV_VAR}=<uvp-constraints.v1.json 绝对路径> 覆盖；\n` +
        `  - 或在 uvp-protocol 仓 protocol/uvp-constraints.v1.json 确认文件存在。\n` +
        `  原始错误：${error instanceof Error ? error.message : String(error)}`,
    );
  }
  return { raw, table: JSON.parse(raw) };
}

const { raw: TABLE_RAW, table: TABLE } = loadConstraintsTable();

function sha256Of(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

test("constraints registry is pinned (version + sha256)", () => {
  assert.equal(
    TABLE.version,
    PINNED_VERSION,
    "约束注册表 version 漂移：三线 harness 必须同声报警",
  );
  assert.equal(
    sha256Of(TABLE_RAW),
    PINNED_SHA256,
    "约束注册表内容被修改：请逐条核对规则后同步更新三线 harness 的 sha256 钉" +
      "（uvp-protocol packages/compiler、uvp-core crates/uvp-compiler、Go pkg/compiler/validator）",
  );
});

test("every ts-applicable rule has a probe registered in this harness", () => {
  const expected = TABLE.rules.filter((rule) => rule.applies.includes("ts")).map((rule) => rule.id);
  assert.ok(
    expected.length > 0,
    "注册表中没有任何 ts 线规则：要么表被改坏，要么 harness 选择器失效",
  );
  for (const id of expected) {
    assert.ok(
      TS_PROBES.has(id),
      `注册表 rule ${id} 标注 applies 含 ts，但本 harness 没有注册探针；请补 probe，不要放行静默漏测`,
    );
  }
  for (const id of TS_PROBES.keys()) {
    assert.ok(
      expected.includes(id),
      `harness 注册了探针 ${id}，但注册表中它不再适用于 ts 线；请同步删除`,
    );
  }
});

// ---------------------------------------------------------------------------
// 探针基元
// ---------------------------------------------------------------------------

function expectZhixuLoadViolation(yaml: string, anchor: RegExp | string): void {
  assert.throws(
    () => parseZhixuDefinition(yaml, "constraints-probe"),
    (error: unknown) =>
      error instanceof ZhixuLoadError && error.message.includes(anchor instanceof RegExp ? anchor.source : anchor),
    `期望 parseZhixuDefinition 拒绝：${yaml}`,
  );
}

// ---------------------------------------------------------------------------
// 逐 rule 探针（satisfy / violate 各一，打真 validator）
// ---------------------------------------------------------------------------

const MINIMAL_ZHIXU_YAML = [
  "apiVersion: uvp/v0",
  "kind: Zhixu",
  "metadata:",
  "  name: constraints-probe",
  "spec:",
  "  taskPatterns: []",
].join("\n");

const FIXTURE_PATH = join(__dirname, "..", "fixtures", "uvp-update-zhixu-v2.yaml");

type Probe = () => void | Promise<void>;

const TS_PROBES = new Map<string, Probe>([
  ["zhixu-api-version-closed-enum", () => {
    parseZhixuDefinition(MINIMAL_ZHIXU_YAML, "constraints-probe"); // satisfy
    expectZhixuLoadViolation(
      MINIMAL_ZHIXU_YAML.replace("apiVersion: uvp/v0", "apiVersion: uvp/v1"),
      "apiVersion must be uvp/v0",
    );
  }],
  ["zhixu-kind-closed-enum", () => {
    parseZhixuDefinition(MINIMAL_ZHIXU_YAML, "constraints-probe"); // satisfy
    expectZhixuLoadViolation(
      MINIMAL_ZHIXU_YAML.replace("kind: Zhixu", "kind: NotZhixu"),
      "kind must be Zhixu",
    );
  }],
  ["metadata-name-required", () => {
    parseZhixuDefinition(MINIMAL_ZHIXU_YAML, "constraints-probe"); // satisfy
    expectZhixuLoadViolation(
      MINIMAL_ZHIXU_YAML.replace("  name: constraints-probe\n", ""),
      "metadata.name is required",
    );
  }],
  ["metadata-name-slug-shape", () => {
    parseZhixuDefinition(MINIMAL_ZHIXU_YAML, "constraints-probe"); // satisfy
    expectZhixuLoadViolation(
      MINIMAL_ZHIXU_YAML.replace("constraints-probe", "Constraints_Probe"),
      "must match ^[a-z][a-z0-9_-]{0,99}$",
    );
  }],
  ["metadata-name-max-length", () => {
    parseZhixuDefinition(MINIMAL_ZHIXU_YAML, "constraints-probe"); // satisfy
    expectZhixuLoadViolation(
      MINIMAL_ZHIXU_YAML.replace("constraints-probe", "p".repeat(101)),
      "must match ^[a-z][a-z0-9_-]{0,99}$",
    );
  }],
  ["metadata-uid-not-an-input", () => {
    parseZhixuDefinition(MINIMAL_ZHIXU_YAML, "constraints-probe"); // satisfy
    expectZhixuLoadViolation(
      MINIMAL_ZHIXU_YAML.replace(
        "  name: constraints-probe\n",
        "  name: constraints-probe\n  uid: zx-probe\n",
      ),
      "unknown field `uid`",
    );
  }],
  ["hook-delay-seconds-range", async () => {
    const definition = await loadZhixuDefinition(FIXTURE_PATH);
    const artifact = compileZhixuOnchainHookPlan(definition);
    // satisfy：fixture 产物内所有 delaySeconds 都在 [1, 2592000]。
    assert.deepEqual(validateOnchainHookPlanArtifact(artifact), []);
    const instruction = {
      ...artifact.compiledHooks[0]!.instructions[0]!,
    } as Record<string, unknown>;
    for (const [delaySeconds, anchor] of [
      [0, "delaySeconds must be a positive safe integer"],
      [2592001, "must not exceed 2592000"],
    ] as const) {
      const mutated = structuredClone(artifact);
      const hooks = mutated.compiledHooks as unknown as Array<{ instructions: Array<Record<string, unknown>> }>;
      hooks[0]!.instructions = [{ ...instruction, op: "DELAY", delaySeconds }];
      const issues = validateOnchainHookPlanArtifact(mutated);
      assert.ok(
        issues.some((issue) => issue.includes(anchor)),
        `delaySeconds=${delaySeconds} 应触发锚点「${anchor}」，实际 issues：${JSON.stringify(issues)}`,
      );
    }
  }],
  ["onchain-instruction-op-closed-enum", async () => {
    const definition = await loadZhixuDefinition(FIXTURE_PATH);
    const artifact = compileZhixuOnchainHookPlan(definition);
    assert.deepEqual(validateOnchainHookPlanArtifact(artifact), []); // satisfy
    const mutated = structuredClone(artifact);
    const hooks = mutated.compiledHooks as unknown as Array<{ instructions: Array<Record<string, unknown>> }>;
    hooks[0]!.instructions = [{ ...hooks[0]!.instructions[0]!, op: "XOR" }];
    const issues = validateOnchainHookPlanArtifact(mutated);
    assert.ok(
      issues.some((issue) => issue.includes("op must be one of SIGNAL, NOT, AND, OR, DELAY")),
      `op=XOR 应触发闭集锚点，实际 issues：${JSON.stringify(issues)}`,
    );
  }],
  ["plan-dependencies-max-count", async () => {
    const definition = await loadZhixuDefinition(FIXTURE_PATH);
    const hookPlan = compileZhixuHookPlan(definition);
    compileOnchainHookPlan(hookPlan); // satisfy：fixture 计划依赖数远低于 1024
    const bloated = structuredClone(hookPlan);
    const hooks = bloated.compiledHooks as unknown as Array<{
      hookId: string;
      dependencies: Array<{ kind: string; source: string; signalName: string }>;
    }>;
    for (let i = 0; i < 1025; i += 1) {
      hooks[0]!.dependencies.push({ kind: "positive", source: "probe", signalName: `task.stage.s${i}` });
    }
    // 同步重建 dependencyIndex（key = `${source}::${signalName}` → hookIds），
    // 否则 artifact 形状校验会先于依赖数 preflight 报错。
    const recomputed: Record<string, string[]> = {};
    for (const hook of hooks) {
      for (const dependency of hook.dependencies) {
        const key = `${dependency.source}::${dependency.signalName}`;
        (recomputed[key] ??= []).push(hook.hookId);
      }
    }
    for (const hookIds of Object.values(recomputed)) hookIds.sort();
    (bloated as unknown as { dependencyIndex: Record<string, string[]> }).dependencyIndex =
      Object.fromEntries(Object.entries(recomputed).sort(([l], [r]) => (l < r ? -1 : 1)));
    // 变异后按载荷重签 planHash：承诺重算域先于 preflight 校验，未重签会以
    // planHash 不匹配报错而非 TooManyDependencies 镜像。
    const resigned = {
      ...bloated,
      planHash: hookPlanHashOf(bloated as unknown as HookPlanArtifact),
    };
    assert.throws(
      () => compileOnchainHookPlan(resigned),
      /exceed the contract limit 1024/,
      "1025 个去重依赖键必须被 preflight 拒绝（TooManyDependencies 镜像）",
    );
  }],
]);

test("constraints registry probes (ts line)", async (t) => {
  for (const [id, probe] of TS_PROBES) {
    await t.test(id, async () => {
      await probe();
    });
  }
});
