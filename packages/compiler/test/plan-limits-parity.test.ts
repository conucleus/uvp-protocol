import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  MAX_HOOKS_PER_DEPENDENCY_KEY,
  MAX_PLAN_DEPENDENCIES,
  planDependencyCountIssues,
} from "../src/onchain/validate/limits.js";
import type { OnchainCompiledHook } from "../src/types/index.js";

const constantsUrl = new URL(
  "../../../contracts/uvp-contracts/src/UVPStateMachineConstants.sol",
  import.meta.url,
);

const SOLIDITY_MAX_PLAN_DEPENDENCIES = 1024;

function solidityUintConstant(name: string): number {
  let source: string;
  try {
    source = readFileSync(constantsUrl, "utf8");
  } catch (error) {
    throw new Error(
      `[plan-limits-parity] 读不到合约常量源码（硬失败，不 skip）：${constantsUrl.pathname}\n` +
        `  原始错误：${error instanceof Error ? error.message : String(error)}`,
    );
  }
  const match = source.match(
    new RegExp(`\\b${name}\\s*=\\s*(\\d+)\\s*;`),
  );
  if (!match) {
    throw new Error(
      `[plan-limits-parity] 在 ${constantsUrl.pathname} 解析不到 ${name}；` +
        ` 重命名或改形时请同步更新本对拍——该上限是编译预检与 commitPlan 共享的接口面承诺，` +
        ` 变更必须两侧同批落地并更新本测试的字面量与出处注释。`,
    );
  }
  return Number(match[1]);
}

test("MAX_PLAN_DEPENDENCIES matches the Solidity authority in UVPStateMachineConstants.sol", () => {
  assert.equal(MAX_PLAN_DEPENDENCIES, SOLIDITY_MAX_PLAN_DEPENDENCIES);

  assert.equal(
    solidityUintConstant("_MAX_PLAN_DEPENDENCIES"),
    SOLIDITY_MAX_PLAN_DEPENDENCIES,
  );

  assert.equal(
    Number.isSafeInteger(MAX_PLAN_DEPENDENCIES) && MAX_PLAN_DEPENDENCIES > 0,
    true,
  );
});

test("per-dependency-key hook fan-out is capped (MAX_HOOKS_PER_DEPENDENCY_KEY)", () => {
  const sharedKey = `0x${"ab".repeat(32)}`;
  const hooksOf = (count: number): readonly OnchainCompiledHook[] =>
    Array.from({ length: count }, (_, index) => ({
      hookId: `0x${(index + 1).toString(16).padStart(64, "0")}`,
      dependencies: [{ signalKey: sharedKey }],
    })) as unknown as readonly OnchainCompiledHook[];
  assert.deepEqual(
    planDependencyCountIssues(hooksOf(MAX_HOOKS_PER_DEPENDENCY_KEY)),
    [],
    `${MAX_HOOKS_PER_DEPENDENCY_KEY} hooks on one key is the boundary and must pass`,
  );
  assert.ok(
    planDependencyCountIssues(hooksOf(MAX_HOOKS_PER_DEPENDENCY_KEY + 1)).some(
      (issue) =>
        issue.includes(`fans out to ${MAX_HOOKS_PER_DEPENDENCY_KEY + 1} hooks`),
    ),
    "one hook past the per-key cap must be rejected",
  );
});
