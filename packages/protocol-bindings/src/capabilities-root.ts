/**
 * 协议侧能力树表项与造证入口：叶公式、Merkle 建树与证明的单源在
 * @uvp-eth/compiler/browser（onchain/capabilities-root.ts），本模块只保留
 * 能力表项形状（relation，或 compiler/ABI 的 targetOrderRelation）、
 * Hex|string 归一与协议侧导出名。
 */

import {
  EMPTY_MERKLE_ROOT,
  SELECTOR_BINDING_LEAF_DOMAIN,
  SIGNAL_CAPABILITY_LEAF_DOMAIN,
  capabilitiesRootOf as sourceCapabilitiesRootOf,
  factAttribution as sourceFactAttribution,
  selectorBindingLeaf as sourceSelectorBindingLeaf,
  selectorBindingProof,
  signalCapabilityLeaf as sourceSignalCapabilityLeaf,
  signalCapabilityProof,
} from "@uvp-eth/compiler/browser";
import { isHex, type Hex } from "viem";

export const UVP_SIGNAL_CAPABILITY_V1 = SIGNAL_CAPABILITY_LEAF_DOMAIN;
export const UVP_SELECTOR_BINDING_V1 = SELECTOR_BINDING_LEAF_DOMAIN;
export const EMPTY_CAPABILITIES_ROOT: Hex = EMPTY_MERKLE_ROOT;

export const SIGNAL_CAPABILITY_RELATION_CURRENT_ORDER = 0;

export interface SignalCapabilityTableEntry {
  readonly stageId: Hex | string;
  readonly targetSourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly relation: 0;
}

/** Capability row exactly as emitted by `@uvp-eth/compiler`'s `capabilityTablesOf` (ABI field name). */
export interface CompilerSignalCapabilityTableEntry {
  readonly stageId: Hex | string;
  readonly targetSourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly targetOrderRelation: 0;
}

/** Capability row accepted at the public boundary: `relation` or the compiler/ABI `targetOrderRelation`. */
export type SignalCapabilityTableEntryInput =
  | SignalCapabilityTableEntry
  | CompilerSignalCapabilityTableEntry;

export interface StageSelectorBindingTableEntry {
  readonly selectorStageId: Hex | string;
  readonly targetStageId: Hex | string;
}

export function signalCapabilityLeaf(
  stageId: Hex | string,
  targetSourceId: Hex | string,
  signalId: Hex | string,
  relation: 0,
): Hex {
  return sourceSignalCapabilityLeaf(
    normalizeWord(stageId, "stageId"),
    normalizeWord(targetSourceId, "targetSourceId"),
    normalizeWord(signalId, "signalId"),
    relation,
  );
}

export function selectorBindingLeaf(
  selectorStageId: Hex | string,
  targetStageId: Hex | string,
): Hex {
  return sourceSelectorBindingLeaf(
    normalizeWord(selectorStageId, "selectorStageId"),
    normalizeWord(targetStageId, "targetStageId"),
  );
}

export function capabilitiesRootOf(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntryInput[],
): Hex {
  return sourceCapabilitiesRootOf(
    normalizeBindings(selectorBindings),
    normalizeCapabilities(signalCapabilities),
  );
}

export function factAttribution(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntryInput[],
  sourceId: Hex | string,
  signalId: Hex | string,
): { readonly stageId: Hex; readonly capabilityProof: readonly Hex[] }
| undefined {
  return sourceFactAttribution(
    normalizeBindings(selectorBindings),
    normalizeCapabilities(signalCapabilities),
    normalizeWord(sourceId, "sourceId"),
    normalizeWord(signalId, "signalId"),
  );
}

export function signalCapabilityProofFor(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntryInput[],
  stageId: Hex | string,
  targetSourceId: Hex | string,
  signalId: Hex | string,
  relation: 0 = SIGNAL_CAPABILITY_RELATION_CURRENT_ORDER,
): readonly Hex[] | undefined {
  return signalCapabilityProof(
    normalizeBindings(selectorBindings),
    normalizeCapabilities(signalCapabilities),
    normalizeWord(stageId, "stageId"),
    normalizeWord(targetSourceId, "targetSourceId"),
    normalizeWord(signalId, "signalId"),
    relation,
  );
}

export function selectorBindingProofFor(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntryInput[],
  targetStageId: Hex | string,
): { readonly selectorStageId: Hex; readonly proof: readonly Hex[] }
| undefined {
  const normalizedTargetStageId = normalizeWord(targetStageId, "targetStageId");
  const normalizedBindings = normalizeBindings(selectorBindings);
  const binding = normalizedBindings.find(
    (candidate) => candidate.targetStageId === normalizedTargetStageId,
  );
  if (binding === undefined) {
    return undefined;
  }
  const proof = selectorBindingProof(
    normalizedBindings,
    normalizeCapabilities(signalCapabilities),
    binding.selectorStageId,
    normalizedTargetStageId,
  );
  if (proof === undefined) {
    return undefined;
  }
  return { selectorStageId: binding.selectorStageId, proof };
}

function normalizeBindings(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
): readonly { readonly selectorStageId: Hex; readonly targetStageId: Hex }[] {
  return selectorBindings.map((binding) => ({
    selectorStageId: normalizeWord(
      binding.selectorStageId,
      "selectorBinding.selectorStageId",
    ),
    targetStageId: normalizeWord(binding.targetStageId, "selectorBinding.targetStageId"),
  }));
}

function normalizeCapabilities(
  signalCapabilities: readonly SignalCapabilityTableEntryInput[],
): readonly {
  readonly stageId: Hex;
  readonly targetSourceId: Hex;
  readonly signalId: Hex;
  readonly targetOrderRelation: 0;
}[] {
  return signalCapabilities.map((capability) => {
    const relation =
      "relation" in capability
        ? capability.relation
        : capability.targetOrderRelation;
    if (relation !== SIGNAL_CAPABILITY_RELATION_CURRENT_ORDER) {
      throw new Error("capability.relation must be current-order (0)");
    }
    return {
      stageId: normalizeWord(capability.stageId, "capability.stageId"),
      targetSourceId: normalizeWord(
        capability.targetSourceId,
        "capability.targetSourceId",
      ),
      signalId: normalizeWord(capability.signalId, "capability.signalId"),
      targetOrderRelation: relation,
    };
  });
}

const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;

function normalizeWord(value: Hex | string, fieldName: string): Hex {
  if (!isHex(value) || !BYTES32_RE.test(value)) {
    throw new Error(`${fieldName} must be a 32-byte hex value`);
  }
  return value.toLowerCase() as Hex;
}
