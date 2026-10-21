/**
 * MAX_PLAN_DEPENDENCIES 的 TS↔Solidity 对拍（A-39）：TS 常量
 * （packages/compiler/src/onchain/validate/limits.ts）与合约常量
 * （uvp-protocol/contracts/uvp-contracts/src/UVPStateMachineConstants.sol 的
 * `_MAX_PLAN_DEPENDENCIES`）两处硬编码此前无对拍——任一侧单独调整上限，
 * 编译预检接受面与 commitPlan 注册面即分叉（TS 放行 / 链上 revert
 * TooManyDependencies，或反之收紧误拒）。本测试按 dock-limits-parity 同
 * 范式直读合约源码提取常量值 + 字面量钉死数值：合约侧动上限而不更新本
 * 测试时，这道门在 TS 侧报警，强制两侧同批落地。
 */
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

/** 合约权威字面量：UVPStateMachineConstants.sol 的 `_MAX_PLAN_DEPENDENCIES`。 */
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
  // 第一层：字面量钉死（数值变化必须改这里）。
  assert.equal(MAX_PLAN_DEPENDENCIES, SOLIDITY_MAX_PLAN_DEPENDENCIES);

  // 第二层：直读合约源码对拍，防字面量与权威一起漂移——合约侧单独动上限时
  // 本门在 TS 侧报警。
  assert.equal(
    solidityUintConstant("_MAX_PLAN_DEPENDENCIES"),
    SOLIDITY_MAX_PLAN_DEPENDENCIES,
  );

  // 形态自证：上限必须是正的安全整数，对拍才有意义。
  assert.equal(
    Number.isSafeInteger(MAX_PLAN_DEPENDENCIES) && MAX_PLAN_DEPENDENCIES > 0,
    true,
  );
});

test("per-dependency-key hook fan-out is capped (MAX_HOOKS_PER_DEPENDENCY_KEY)", () => {
  // A-09：单一依赖键挂 N 个 hook 让该事实每次提交 O(N)——per-key 扇出与
  // 总键数是两个独立爆炸面，上限与合约同名常量同值同批。
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
