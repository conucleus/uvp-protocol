#!/usr/bin/env tsx
/**
 * 生成能力树（capabilitiesRoot）跨语言 golden（链轨 TS 权威实现）：
 * `fixtures/capabilities-root/v1/vectors.json` 冻结两组能力表/绑定表样本
 * 的全部叶哈希、排序去重叶集、树根与成员资格证明。
 *
 * TS parity 测试（capabilities-root-golden.test.ts）与 Foundry
 * CapabilitiesRootParity.t.sol 从同一份 fixture 消费——两侧任何一方改动
 * 叶公式/建树规则都会在对侧测试响亮失配，不允许各自漂移无报警。
 *
 * 运行：`pnpm --filter @uvp-eth/compiler generate:capabilities-root-fixtures`
 * （幂等重生成；期望值由 `@uvp-eth/compiler` capabilities-root.ts 计算）。
 */
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, toHex } from "viem";
import {
  capabilityLeaves,
  capabilitiesRootOf,
  selectorBindingLeaf,
  selectorBindingProof,
  signalCapabilityLeaf,
  signalCapabilityProof,
} from "../src/onchain/capabilities-root.js";
import type { HexString } from "../src/types/index.js";

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

interface Sample {
  readonly name: string;
  readonly note: string;
  /** forge 侧 vm.parseJson 不支持 .length 路径，计数显式镜像（TS 测试
   * 断言与实际数组长一致，防止镜像漂移）。 */
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

function word(derivation: string): HexString {
  return keccak256(toHex(derivation)) as HexString;
}

function sortedUnique(leaves: readonly HexString[]): HexString[] {
  return [...new Set(leaves)].sort();
}

function buildSample(
  name: string,
  note: string,
  selectorBindings: readonly BindingInput[],
  signalCapabilities: readonly CapabilityInput[],
): Sample {
  const leaves = capabilityLeaves(selectorBindings, signalCapabilities);
  return {
    name,
    note,
    counts: {
      selectorBindings: selectorBindings.length,
      signalCapabilities: signalCapabilities.length,
      sortedUniqueLeaves: sortedUnique(leaves).length,
    },
    inputs: { selectorBindings, signalCapabilities },
    expected: {
      root: capabilitiesRootOf(selectorBindings, signalCapabilities),
      sortedUniqueLeaves: sortedUnique(leaves),
      selectorBindingLeaves: selectorBindings.map((binding) => {
        const proof = selectorBindingProof(
          selectorBindings,
          signalCapabilities,
          binding.selectorStageId,
          binding.targetStageId,
        ) as readonly HexString[];
        return {
          leaf: selectorBindingLeaf(binding.selectorStageId, binding.targetStageId),
          proofLength: proof.length,
          proof,
        };
      }),
      signalCapabilityLeaves: signalCapabilities.map((capability) => {
        const leaf = signalCapabilityLeaf(
          capability.stageId,
          capability.targetSourceId,
          capability.signalId,
          capability.targetOrderRelation,
        );
        const proof = signalCapabilityProof(
          selectorBindings,
          signalCapabilities,
          capability.stageId,
          capability.targetSourceId,
          capability.signalId,
          capability.targetOrderRelation,
        ) as readonly HexString[];
        return { leaf, proofLength: proof.length, proof };
      }),
    },
  };
}

// ---------------------------------------------------------------------
// 样本 1：双表混编、5 叶奇数集（钉奇数尾叶提升），含 relation=1 叶。
// ---------------------------------------------------------------------
const stages = {
  init: word("payment.init"),
  audit: word("payment.audit"),
  settle: word("payment.settle"),
} as const;
const sources = {
  payment: word("payment"),
  evidence: word("evidence"),
} as const;
const signals = {
  ready: word("payment.ready"),
  confirmed: word("payment.confirmed"),
  failed: word("payment.failed"),
} as const;

const mixedTables = buildSample(
  "mixed-tables-odd-leaves",
  "2 selector bindings + 3 signal capabilities（含 relation=1）= 5 叶奇数集，钉奇数尾叶提升",
  [
    { selectorStageId: stages.init, targetStageId: stages.audit },
    { selectorStageId: stages.init, targetStageId: stages.settle },
  ],
  [
    { stageId: stages.audit, targetSourceId: sources.payment, signalId: signals.ready, targetOrderRelation: 0 },
    { stageId: stages.init, targetSourceId: sources.payment, signalId: signals.confirmed, targetOrderRelation: 0 },
    { stageId: stages.settle, targetSourceId: sources.evidence, signalId: signals.failed, targetOrderRelation: 1 },
  ],
);

// ---------------------------------------------------------------------
// 样本 2：重复叶（同表内逐字段重复声明）钉排序去重语义：6 条原始输入
// （3 绑定含 1 重复 + 3 能力含 1 重复）→ 4 条唯一叶。
// ---------------------------------------------------------------------
const duplicateLeaves = buildSample(
  "duplicate-leaves-dedup",
  "重复叶排序去重：3 绑定（1 重复）+ 3 能力（1 重复）→ 6 原始叶 → 4 唯一叶",
  [
    { selectorStageId: stages.init, targetStageId: stages.audit },
    { selectorStageId: stages.audit, targetStageId: stages.settle },
    { selectorStageId: stages.init, targetStageId: stages.audit },
  ],
  [
    { stageId: stages.audit, targetSourceId: sources.payment, signalId: signals.ready, targetOrderRelation: 0 },
    { stageId: stages.settle, targetSourceId: sources.evidence, signalId: signals.failed, targetOrderRelation: 1 },
    { stageId: stages.audit, targetSourceId: sources.payment, signalId: signals.ready, targetOrderRelation: 0 },
  ],
);

const fixture = {
  schemaVersion: "uvp.capabilities-root.golden.v1",
  samples: [mixedTables, duplicateLeaves],
};

const fixturePath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../fixtures/capabilities-root/v1/vectors.json",
);
await mkdir(dirname(fixturePath), { recursive: true });
await writeFile(fixturePath, `${JSON.stringify(fixture, null, 2)}\n`, "utf8");
console.log(`wrote ${fixturePath}`);
