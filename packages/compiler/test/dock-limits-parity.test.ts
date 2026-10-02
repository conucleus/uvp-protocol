/**
 * MAX_DOCK 上限的双轨对拍（TS 线）：TS 常量（packages/compiler/src/dock.ts
 * 的 MAX_DOCK_INPUTS/MAX_DOCK_OUTPUTS）与 Rust 权威（uvp-core 仓
 * crates/uvp-compiler/src/dock.rs 的同名常量）此前没有任何对拍断言——任一侧
 * 单独调整上限，两轨对同一 Zhixu 定义的接受面即分叉（TS 编译放行 / Rust
 * 编译拒绝，或反之）。本测试按 closed-set-parity 同范式（相对路径直读
 * uvp-core 侧权威）+ 字面量钉死数值：Rust 侧动上限而不更新本测试时，
 * uvp-protocol 侧这道门报警，强制两轨同批落地（工作区 AGENTS 的同批规则）。
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { MAX_DOCK_INPUTS, MAX_DOCK_OUTPUTS } from "../src/dock.js";

const rustSourceUrl = new URL(
  "../../../../uvp-core/crates/uvp-compiler/src/dock.rs",
  import.meta.url,
);

/** Rust 权威字面量：uvp-core/crates/uvp-compiler/src/dock.rs:11-12。 */
const RUST_MAX_DOCK_INPUTS = 8;
const RUST_MAX_DOCK_OUTPUTS = 16;

function rustConst(name: string): number {
  let source: string;
  try {
    source = readFileSync(rustSourceUrl, "utf8");
  } catch (error) {
    throw new Error(
      `[dock-limits-parity] 读不到 Rust 权威源码（硬失败，不 skip）：${rustSourceUrl.pathname}\n` +
        `  - 权威是 uvp-core 仓 crates/uvp-compiler/src/dock.rs 的 MAX_DOCK_* 常量，` +
        ` TS 测试按相对路径消费（与 closed-set-parity 读 closed-sets.v1.json 同范式）；\n` +
        `  原始错误：${error instanceof Error ? error.message : String(error)}`,
    );
  }
  const match = source.match(
    new RegExp(`^pub const ${name}\\s*:\\s*\\w+\\s*=\\s*(\\d+)\\s*;`, "m"),
  );
  if (!match) {
    throw new Error(
      `[dock-limits-parity] 在 ${rustSourceUrl.pathname} 解析不到 pub const ${name}；` +
        ` 重命名或改形时请同步更新本对拍——MAX_DOCK_* 是两轨共享的接口面承诺，` +
        ` 变更必须两轨同批落地并更新本测试的字面量与出处注释。`,
    );
  }
  return Number(match[1]);
}

test("MAX_DOCK_INPUTS/MAX_DOCK_OUTPUTS match the Rust authority in uvp-core dock.rs", () => {
  // 第一层：字面量钉死（数值变化必须改这里，出处行号同步维护——
  // uvp-core/crates/uvp-compiler/src/dock.rs:11-12）。
  assert.equal(MAX_DOCK_INPUTS, RUST_MAX_DOCK_INPUTS);
  assert.equal(MAX_DOCK_OUTPUTS, RUST_MAX_DOCK_OUTPUTS);

  // 第二层：直读 Rust 源码对拍，防字面量与权威一起漂移——Rust 侧单独动
  // 上限时本门在 uvp-protocol 侧报警。
  assert.equal(rustConst("MAX_DOCK_INPUTS"), RUST_MAX_DOCK_INPUTS);
  assert.equal(rustConst("MAX_DOCK_OUTPUTS"), RUST_MAX_DOCK_OUTPUTS);

  // 形态自证：上限必须是正的安全整数，对拍才有意义。
  assert.equal(Number.isSafeInteger(MAX_DOCK_INPUTS) && MAX_DOCK_INPUTS > 0, true);
  assert.equal(Number.isSafeInteger(MAX_DOCK_OUTPUTS) && MAX_DOCK_OUTPUTS > 0, true);
});
