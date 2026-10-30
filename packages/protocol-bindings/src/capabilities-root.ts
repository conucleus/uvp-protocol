/**
 * 协议侧能力树表项与造证入口：叶公式、Merkle 建树与证明的单源在
 * @uvp-eth/compiler/browser（onchain/capabilities-root.ts），本模块只保留
 * relation 字段的表项形状、Hex|string 归一与协议侧导出名。
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
} from "@uvp-eth/compiler/browser";
import { isHex, type Hex } from "viem";

export const UVP_SIGNAL_CAPABILITY_V1 = SIGNAL_CAPABILITY_LEAF_DOMAIN;
export const UVP_SELECTOR_BINDING_V1 = SELECTOR_BINDING_LEAF_DOMAIN;
export const EMPTY_CAPABILITIES_ROOT: Hex = EMPTY_MERKLE_ROOT;

export const SIGNAL_CAPABILITY_RELATION_CURRENT_ORDER = 0;
export const SIGNAL_CAPABILITY_RELATION_TRIGGER_ORIGIN = 1;

export interface SignalCapabilityTableEntry {
  readonly stageId: Hex | string;
  readonly targetSourceId: Hex | string;
  readonly signalId: Hex | string;
  readonly relation: 0 | 1;
}

export interface StageSelectorBindingTableEntry {
  readonly selectorStageId: Hex | string;
  readonly targetStageId: Hex | string;
}

export function signalCapabilityLeaf(
  stageId: Hex | string,
  targetSourceId: Hex | string,
  signalId: Hex | string,
  relation: 0 | 1,
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
  signalCapabilities: readonly SignalCapabilityTableEntry[],
): Hex {
  return sourceCapabilitiesRootOf(
    normalizeBindings(selectorBindings),
    normalizeCapabilities(signalCapabilities),
  );
}

export function factAttribution(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
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

export function selectorBindingProofFor(
  selectorBindings: readonly StageSelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
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
  signalCapabilities: readonly SignalCapabilityTableEntry[],
): readonly {
  readonly stageId: Hex;
  readonly targetSourceId: Hex;
  readonly signalId: Hex;
  readonly targetOrderRelation: 0 | 1;
}[] {
  return signalCapabilities.map((capability) => ({
    stageId: normalizeWord(capability.stageId, "capability.stageId"),
    targetSourceId: normalizeWord(
      capability.targetSourceId,
      "capability.targetSourceId",
    ),
    signalId: normalizeWord(capability.signalId, "capability.signalId"),
    targetOrderRelation: capability.relation,
  }));
}

const BYTES32_RE = /^0x[a-fA-F0-9]{64}$/;

function normalizeWord(value: Hex | string, fieldName: string): Hex {
  if (!isHex(value) || !BYTES32_RE.test(value)) {
    throw new Error(`${fieldName} must be a 32-byte hex value`);
  }
  return value.toLowerCase() as Hex;
}
