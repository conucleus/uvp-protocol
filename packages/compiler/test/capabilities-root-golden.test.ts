import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  capabilityLeaves,
  capabilitiesRootOf,
  factAttribution,
  selectorBindingLeaf,
  selectorBindingProof,
  signalCapabilityLeaf,
  signalCapabilityProof,
} from "../src/onchain/capabilities-root.js";
import type { HexString } from "../src/types/index.js";

/**
 * 能力树（capabilitiesRoot）跨语言 golden 消费（TS 侧）：
 * fixtures/capabilities-root/v1/vectors.json 由本包权威实现生成
 * （generate:capabilities-root-fixtures），Foundry 侧
 * CapabilitiesRootParity.t.sol 消费同一份 fixture——任何一侧改动叶公式
 * 或建树/证明规则，至少一侧测试响亮失配，不允许两侧各自漂移无报警。
 */
interface BindingInput {
  readonly selectorStageId: HexString;
  readonly targetStageId: HexString;
}

interface CapabilityInput {
  readonly stageId: HexString;
  readonly targetSourceId: HexString;
  readonly signalId: HexString;
  readonly targetOrderRelation: 0 | 1;
}

interface GoldenSample {
  readonly name: string;
  readonly counts: {
    readonly selectorBindings: number;
    readonly signalCapabilities: number;
    readonly sortedUniqueLeaves: number;
  };
  readonly inputs: {
    readonly selectorBindings: readonly BindingInput[];
    readonly signalCapabilities: readonly CapabilityInput[];
  };
  readonly expected: {
    readonly root: HexString;
    readonly sortedUniqueLeaves: readonly HexString[];
    readonly selectorBindingLeaves: readonly {
      readonly leaf: HexString;
      readonly proofLength: number;
      readonly proof: readonly HexString[];
    }[];
    readonly signalCapabilityLeaves: readonly {
      readonly leaf: HexString;
      readonly proofLength: number;
      readonly proof: readonly HexString[];
    }[];
  };
}

const fixturePath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../fixtures/capabilities-root/v1/vectors.json",
);
const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as {
  readonly schemaVersion: string;
  readonly samples: readonly GoldenSample[];
};

test("capabilities-root golden fixture keeps its schema version", () => {
  assert.equal(fixture.schemaVersion, "uvp.capabilities-root.golden.v1");
  assert.equal(fixture.samples.length, 2);
});

for (const sample of fixture.samples) {
  test(`capabilities-root golden: ${sample.name}`, () => {
    const { selectorBindings, signalCapabilities } = sample.inputs;
    const { expected } = sample;

    // 计数镜像（forge 侧 vm.parseJson 不支持 .length 路径）与实际数组
    // 长一致，防止 fixture 内部漂移。
    assert.equal(selectorBindings.length, sample.counts.selectorBindings);
    assert.equal(signalCapabilities.length, sample.counts.signalCapabilities);
    assert.equal(expected.sortedUniqueLeaves.length, sample.counts.sortedUniqueLeaves);

    // 树根与排序去重叶集：能力叶/绑定叶域分隔混编进同一棵排序配对树。
    assert.equal(capabilitiesRootOf(selectorBindings, signalCapabilities), expected.root);
    assert.deepEqual(
      [...new Set(capabilityLeaves(selectorBindings, signalCapabilities))].sort(),
      expected.sortedUniqueLeaves,
    );

    // 每条绑定输入：叶公式重算 + 成员资格证明逐字相等。
    assert.equal(selectorBindings.length, expected.selectorBindingLeaves.length);
    for (const [index, binding] of selectorBindings.entries()) {
      const leaf = selectorBindingLeaf(binding.selectorStageId, binding.targetStageId);
      assert.equal(leaf, expected.selectorBindingLeaves[index]!.leaf);
      assert.equal(expected.selectorBindingLeaves[index]!.proof.length, expected.selectorBindingLeaves[index]!.proofLength);
      assert.deepEqual(
        selectorBindingProof(
          selectorBindings,
          signalCapabilities,
          binding.selectorStageId,
          binding.targetStageId,
        ),
        expected.selectorBindingLeaves[index]!.proof,
      );
    }

    // 每条能力输入：叶公式重算 + 成员资格证明逐字相等。
    assert.equal(signalCapabilities.length, expected.signalCapabilityLeaves.length);
    for (const [index, capability] of signalCapabilities.entries()) {
      const leaf = signalCapabilityLeaf(
        capability.stageId,
        capability.targetSourceId,
        capability.signalId,
        capability.targetOrderRelation,
      );
      assert.equal(leaf, expected.signalCapabilityLeaves[index]!.leaf);
      assert.equal(expected.signalCapabilityLeaves[index]!.proof.length, expected.signalCapabilityLeaves[index]!.proofLength);
      assert.deepEqual(
        signalCapabilityProof(
          selectorBindings,
          signalCapabilities,
          capability.stageId,
          capability.targetSourceId,
          capability.signalId,
          capability.targetOrderRelation,
        ),
        expected.signalCapabilityLeaves[index]!.proof,
      );
    }

    // 事实属主自证（relation=0 唯一属主）：stageId + 证明与该键能力条目
    // 的 pinned 叶/证明一致——携证提交路径消费的同一材料。
    for (const [index, capability] of signalCapabilities.entries()) {
      if (capability.targetOrderRelation !== 0) {
        continue;
      }
      const attribution = factAttribution(
        selectorBindings,
        signalCapabilities,
        capability.targetSourceId,
        capability.signalId,
      );
      assert.ok(attribution, "relation=0 fact key must resolve to an owner");
      assert.equal(attribution.stageId, capability.stageId);
      assert.deepEqual(
        attribution.capabilityProof,
        expected.signalCapabilityLeaves[index]!.proof,
      );
    }
  });
}
