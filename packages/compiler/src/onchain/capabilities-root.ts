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

export function capabilityLeaves(
  selectorBindings: readonly { selectorStageId: HexString; targetStageId: HexString }[],
  signalCapabilities: readonly {
    stageId: HexString;
    targetSourceId: HexString;
    signalId: HexString;
    targetOrderRelation: 0 | 1;
  }[],
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
  ];
}

export function capabilitiesRootOf(
  selectorBindings: readonly { selectorStageId: HexString; targetStageId: HexString }[],
  signalCapabilities: readonly {
    stageId: HexString;
    targetSourceId: HexString;
    signalId: HexString;
    targetOrderRelation: 0 | 1;
  }[],
): HexString {
  return merkleRoot(capabilityLeaves(selectorBindings, signalCapabilities));
}

export function signalCapabilityProof(
  selectorBindings: readonly { selectorStageId: HexString; targetStageId: HexString }[],
  signalCapabilities: readonly {
    stageId: HexString;
    targetSourceId: HexString;
    signalId: HexString;
    targetOrderRelation: 0 | 1;
  }[],
  stageId: HexString,
  targetSourceId: HexString,
  signalId: HexString,
  relation: 0 | 1,
): HexString[] | undefined {
  return merkleProof(
    capabilityLeaves(selectorBindings, signalCapabilities),
    signalCapabilityLeaf(stageId, targetSourceId, signalId, relation),
  );
}

export function selectorBindingProof(
  selectorBindings: readonly { selectorStageId: HexString; targetStageId: HexString }[],
  signalCapabilities: readonly {
    stageId: HexString;
    targetSourceId: HexString;
    signalId: HexString;
    targetOrderRelation: 0 | 1;
  }[],
  selectorStageId: HexString,
  targetStageId: HexString,
): HexString[] | undefined {
  return merkleProof(
    capabilityLeaves(selectorBindings, signalCapabilities),
    selectorBindingLeaf(selectorStageId, targetStageId),
  );
}

export function factAttribution(
  selectorBindings: readonly { selectorStageId: HexString; targetStageId: HexString }[],
  signalCapabilities: readonly {
    stageId: HexString;
    targetSourceId: HexString;
    signalId: HexString;
    targetOrderRelation: 0 | 1;
  }[],
  sourceId: HexString,
  signalId: HexString,
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
  };
}

export function artifactCapabilitiesRoot(artifact: OnchainHookPlanArtifact): HexString {
  const tables = capabilityTablesOf(artifact);
  return capabilitiesRootOf(tables.selectorBindings, tables.signalCapabilities);
}
