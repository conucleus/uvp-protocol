// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUVPPlanMetadataModule {
    struct StageSelectorBinding {
        bytes32 selectorStageId;
        bytes32 targetStageId;
    }

    struct SignalCapability {
        bytes32 stageId;
        bytes32 targetSourceId;
        bytes32 signalId;
        uint8 targetOrderRelation;
    }

    function finalizePlanMetadata(
        bytes32 planId,
        StageSelectorBinding[] calldata selectorBindings,
        SignalCapability[] calldata signalCapabilities
    ) external;

    function isSelectorTargetStage(bytes32 planId, bytes32 targetStageId) external view returns (bool);
}
