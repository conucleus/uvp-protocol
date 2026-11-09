import { keccakWords, merkleProof, merkleRoot } from "../dock.js";
import type {
  HexString,
  OnchainHookPlanArtifact,
  OnchainSignalCapability,
  OnchainStageSelectorBinding,
  SolidityRegisterPlanArgs,
} from "../types/index.js";

/**
 * 计划能力树（capabilitiesRoot）权威实现：叶子公式与 UVPPlanMetadataModule
 * 逐字节一致；链上只存 root，成员资格按"重算叶 + 携 proof"验证。
 */

export const SIGNAL_CAPABILITY_LEAF_DOMAIN = "UVP_SIGNAL_CAPABILITY_V1";
export const SELECTOR_BINDING_LEAF_DOMAIN = "UVP_SELECTOR_BINDING_V1";
export const FILE_WRITER_LEAF_DOMAIN = "UVP_FILE_WRITER_V1";

export function signalCapabilityLeaf(
  stageId: HexString,
  targetSourceId: HexString,
  signalId: HexString,
  relation: 0 | 1,
): HexString {
  return keccakWords(SIGNAL_CAPABILITY_LEAF_DOMAIN, [
    stageId,
    targetSourceId,
    signalId,
    `0x${relation.toString(16).padStart(64, "0")}` as HexString,
  ]);
}

export function selectorBindingLeaf(
  selectorStageId: HexString,
  targetStageId: HexString,
): HexString {
  return keccakWords(SELECTOR_BINDING_LEAF_DOMAIN, [selectorStageId, targetStageId]);
}

export function fileWriterLeaf(
  targetStageId: HexString,
  writerStageId: HexString,
): HexString {
  return keccakWords(FILE_WRITER_LEAF_DOMAIN, [targetStageId, writerStageId]);
}

interface SelectorBindingTableEntry {
  readonly selectorStageId: HexString;
  readonly targetStageId: HexString;
}

interface SignalCapabilityTableEntry {
  readonly stageId: HexString;
  readonly targetSourceId: HexString;
  readonly signalId: HexString;
  readonly targetOrderRelation: 0 | 1;
}

interface FileWriterTableEntry {
  readonly targetStageId: HexString;
  readonly writerStageId: HexString;
}

export function capabilityLeaves(
  selectorBindings: readonly SelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  fileWriterBindings: readonly FileWriterTableEntry[] = [],
): HexString[] {
  return [
    ...selectorBindings.map((binding) =>
      selectorBindingLeaf(binding.selectorStageId, binding.targetStageId),
    ),
    ...signalCapabilities.map((capability) =>
      signalCapabilityLeaf(
        capability.stageId,
        capability.targetSourceId,
        capability.signalId,
        capability.targetOrderRelation,
      ),
    ),
    ...fileWriterBindings.map((binding) =>
      fileWriterLeaf(binding.targetStageId, binding.writerStageId),
    ),
  ];
}

export function capabilitiesRootOf(
  selectorBindings: readonly SelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  fileWriterBindings: readonly FileWriterTableEntry[] = [],
): HexString {
  return merkleRoot(
    capabilityLeaves(selectorBindings, signalCapabilities, fileWriterBindings),
  );
}

export function signalCapabilityProof(
  selectorBindings: readonly SelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  stageId: HexString,
  targetSourceId: HexString,
  signalId: HexString,
  relation: 0 | 1,
  fileWriterBindings: readonly FileWriterTableEntry[] = [],
): HexString[] | undefined {
  return merkleProof(
    capabilityLeaves(selectorBindings, signalCapabilities, fileWriterBindings),
    signalCapabilityLeaf(stageId, targetSourceId, signalId, relation),
  );
}

export function selectorBindingProof(
  selectorBindings: readonly SelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  selectorStageId: HexString,
  targetStageId: HexString,
  fileWriterBindings: readonly FileWriterTableEntry[] = [],
): HexString[] | undefined {
  return merkleProof(
    capabilityLeaves(selectorBindings, signalCapabilities, fileWriterBindings),
    selectorBindingLeaf(selectorStageId, targetStageId),
  );
}

export function fileWriterProof(
  selectorBindings: readonly SelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  fileWriterBindings: readonly FileWriterTableEntry[],
  targetStageId: HexString,
  writerStageId: HexString,
): HexString[] | undefined {
  return merkleProof(
    capabilityLeaves(selectorBindings, signalCapabilities, fileWriterBindings),
    fileWriterLeaf(targetStageId, writerStageId),
  );
}


export function factAttribution(
  selectorBindings: readonly SelectorBindingTableEntry[],
  signalCapabilities: readonly SignalCapabilityTableEntry[],
  sourceId: HexString,
  signalId: HexString,
  fileWriterBindings: readonly FileWriterTableEntry[] = [],
): { stageId: HexString; capabilityProof: readonly HexString[] } | undefined {
  for (const capability of signalCapabilities) {
    if (
      capability.targetOrderRelation === 0 &&
      capability.targetSourceId === sourceId &&
      capability.signalId === signalId
    ) {
      const proof = signalCapabilityProof(
        selectorBindings,
        signalCapabilities,
        capability.stageId,
        sourceId,
        signalId,
        0,
        fileWriterBindings,
      );
      if (!proof) {
        return undefined;
      }
      return { stageId: capability.stageId, capabilityProof: proof };
    }
  }
  return undefined;
}

export function capabilityTablesOf(artifact: OnchainHookPlanArtifact): {
  selectorBindings: SolidityRegisterPlanArgs["selectorBindings"];
  signalCapabilities: SolidityRegisterPlanArgs["signalCapabilities"];
  fileWriterBindings: SolidityRegisterPlanArgs["fileWriterBindings"];
} {
  return {
    selectorBindings: artifact.selectorBindings.map((binding: OnchainStageSelectorBinding) => ({
      selectorStageId: binding.selectorStageId,
      targetStageId: binding.targetStageId,
    })),
    signalCapabilities: artifact.signalCapabilities.map(
      (capability: OnchainSignalCapability) => ({
        stageId: capability.stageId,
        targetSourceId: capability.targetSourceId,
        signalId: capability.signalId,
        targetOrderRelation: 0 as const,
      }),
    ),
    fileWriterBindings: artifact.stageFileWriters.map((binding) => ({
      targetStageId: binding.targetStageId,
      writerStageId: binding.writerStageId,
    })),
  };
}

export function artifactCapabilitiesRoot(artifact: OnchainHookPlanArtifact): HexString {
  const tables = capabilityTablesOf(artifact);
  return capabilitiesRootOf(
    tables.selectorBindings,
    tables.signalCapabilities,
    tables.fileWriterBindings,
  );
}
