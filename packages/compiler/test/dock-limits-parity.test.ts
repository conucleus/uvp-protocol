import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { MAX_DOCK_INPUTS, MAX_DOCK_OUTPUTS } from "../src/dock.js";

const rustSourceUrl = new URL(
  "../../../../uvp-core/crates/uvp-compiler/src/dock.rs",
  import.meta.url,
);

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
  assert.equal(MAX_DOCK_INPUTS, RUST_MAX_DOCK_INPUTS);
  assert.equal(MAX_DOCK_OUTPUTS, RUST_MAX_DOCK_OUTPUTS);

  assert.equal(rustConst("MAX_DOCK_INPUTS"), RUST_MAX_DOCK_INPUTS);
  assert.equal(rustConst("MAX_DOCK_OUTPUTS"), RUST_MAX_DOCK_OUTPUTS);

  assert.equal(Number.isSafeInteger(MAX_DOCK_INPUTS) && MAX_DOCK_INPUTS > 0, true);
  assert.equal(Number.isSafeInteger(MAX_DOCK_OUTPUTS) && MAX_DOCK_OUTPUTS > 0, true);
});
