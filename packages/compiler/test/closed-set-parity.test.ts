/**
 * 链上承诺闭集词表的跨语言钉死（TS 线）：本测试与 uvp-core 仓
 * `crates/uvp-model/tests/closed_set_parity.rs` 对同一份
 * `uvp-core/fixtures/closed-sets/closed-sets.v1.json` 做逐元素相等比对
 * ——supplierTypes 经 executorRoutes 进 executorHash、fileTypes 经
 * fileResources/selectableResource 进 resourcesHash/executorHash，任一侧
 * 增删成员或改变比对口径（如引入 trim）都会让至少一侧的测试报警。
 * 语料文件由 uvp-core 仓持有（与 canonical.v1.json 同布局范式）。
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { FILE_TYPES, SUPPLIER_TYPES } from "../src/onchain/validate/capabilities.js";

const corpusUrl = new URL(
  "../../../../uvp-core/fixtures/closed-sets/closed-sets.v1.json",
  import.meta.url,
);

interface ClosedSetsCorpus {
  readonly schemaVersion: string;
  readonly supplierTypes: readonly string[];
  readonly fileTypes: readonly string[];
}

function loadCorpus(): ClosedSetsCorpus {
  try {
    return JSON.parse(readFileSync(corpusUrl, "utf8")) as ClosedSetsCorpus;
  } catch (error) {
    throw new Error(
      `[closed-set-parity] 读不到跨语言闭集语料（硬失败，不 skip）：${corpusUrl.pathname}\n` +
        `  - 语料由 uvp-core 仓持有，TS 测试按相对路径消费（与 canonical.v1.json 同范式）；\n` +
        `  原始错误：${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

test("closed-set constants match the shared uvp-core corpus", () => {
  const corpus = loadCorpus();
  assert.equal(corpus.schemaVersion, "uvp.closedSets.v1");

  // 逐元素相等（成员与序都钉）：闭集内容是承诺面，不是实现细节。
  assert.deepEqual(SUPPLIER_TYPES, corpus.supplierTypes);
  assert.deepEqual(FILE_TYPES, corpus.fileTypes);

  // 常量必须无重复：闭集是集合语义，重复成员会掩盖"集合同源"的比对。
  assert.equal(new Set(SUPPLIER_TYPES).size, SUPPLIER_TYPES.length);
  assert.equal(new Set(FILE_TYPES).size, FILE_TYPES.length);
});

test("closed-set membership helpers reject whitespace variants", () => {
  const corpus = loadCorpus();
  // 精确匹配口径的自证：语料成员全部命中，带空白变体全部落选。
  for (const word of corpus.supplierTypes) {
    assert.equal(SUPPLIER_TYPES.includes(word), true);
  }
  for (const word of corpus.fileTypes) {
    assert.equal(FILE_TYPES.includes(word), true);
  }
  for (const padded of [" individual", "organization ", "\tzhixu"]) {
    assert.equal(SUPPLIER_TYPES.includes(padded), false);
  }
  for (const padded of [" local", "http ", "plain_text\n"]) {
    assert.equal(FILE_TYPES.includes(padded), false);
  }
});
