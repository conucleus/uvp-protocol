#!/usr/bin/env tsx
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

const stages = {
  init: word("init"),
  audit: word("audit"),
  settle: word("settle"),
} as const;
const sources = {
  payment: word("payment"),
  evidence: word("evidence"),
} as const;
const signals = {
  ready: word("ready"),
  confirmed: word("confirmed"),
  failed: word("failed"),
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

const deepLeaves = buildSample(
  "deep-tree-33-leaves",
  "16 绑定 + 17 能力 = 33 叶奇数集，证明路径深至 6 层（奇数尾叶逐层提升）",
  Array.from({ length: 16 }, (_, index) => ({
    selectorStageId: word(`deep.selector-${index}`),
    targetStageId: word(`deep.target-${index}`),
  })),
  Array.from({ length: 17 }, (_, index) => ({
    stageId: word(`deep.stage-${index}`),
    targetSourceId: word(`deep.source-${index % 5}`),
    signalId: word(`deep.signal-${index}`),
    targetOrderRelation: (index % 3 === 0 ? 1 : 0) as 0 | 1,
  })),
);

const largeTables = buildSample(
  "large-tables-128-leaves",
  "64 绑定 + 64 能力 = 128 叶大规模双满表，中部/首尾叶成员资格证明逐条钉住",
  Array.from({ length: 64 }, (_, index) => ({
    selectorStageId: word(`large.selector-${index}`),
    targetStageId: word(`large.target-${index}`),
  })),
  Array.from({ length: 64 }, (_, index) => ({
    stageId: word(`large.stage-${index}`),
    targetSourceId: word(`large.source-${index % 8}`),
    signalId: word(`large.signal-${index}`),
    targetOrderRelation: (index % 2 === 0 ? 0 : 1) as 0 | 1,
  })),
);

const duplicatePayloadHeavy = buildSample(
  "duplicate-payload-heavy-collapse",
  "重复 payload 重灾：4 绑定（1 唯一）+ 4 能力（1 唯一）→ 8 原始叶 → 2 唯一叶（单对树）",
  [
    { selectorStageId: stages.init, targetStageId: stages.audit },
    { selectorStageId: stages.init, targetStageId: stages.audit },
    { selectorStageId: stages.init, targetStageId: stages.audit },
    { selectorStageId: stages.init, targetStageId: stages.audit },
  ],
  [
    { stageId: stages.settle, targetSourceId: sources.evidence, signalId: signals.failed, targetOrderRelation: 1 },
    { stageId: stages.settle, targetSourceId: sources.evidence, signalId: signals.failed, targetOrderRelation: 1 },
    { stageId: stages.settle, targetSourceId: sources.evidence, signalId: signals.failed, targetOrderRelation: 1 },
  ],
);

const fixture = {
  schemaVersion: "uvp.capabilities-root.golden.v1",
  samples: [mixedTables, duplicateLeaves, deepLeaves, largeTables, duplicatePayloadHeavy],
};

const fixturePath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../fixtures/capabilities-root/v1/vectors.json",
);
await mkdir(dirname(fixturePath), { recursive: true });
await writeFile(fixturePath, `${JSON.stringify(fixture, null, 2)}\n`, "utf8");
console.log(`wrote ${fixturePath}`);
