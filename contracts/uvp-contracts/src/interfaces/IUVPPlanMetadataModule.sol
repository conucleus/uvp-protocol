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
        SignalCapability[] calldata signalCapabilities,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot
    ) external;

    function dockRoutesRoot(bytes32 planId) external view returns (bytes32);

    function dockInterfaceRoot(bytes32 planId) external view returns (bytes32);

    function verifyDockRoute(bytes32 planId, bytes32 leaf, bytes32[] calldata proof) external view returns (bool);

    function verifyDockInterfacePort(bytes32 planId, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool);

    function isSelectorTargetStage(bytes32 planId, bytes32 targetStageId) external view returns (bool);

    function planSignalCapabilityCount(bytes32 planId) external view returns (uint256);

    function planSignalCapabilityAt(bytes32 planId, uint256 index)
        external
        view
        returns (bytes32 stageId, bytes32 targetSourceId, bytes32 signalId, uint8 targetOrderRelation);

    function stageSignalCapabilityCount(bytes32 planId, bytes32 stageId) external view returns (uint256);

    function stageSignalCapabilityAt(bytes32 planId, bytes32 stageId, uint256 index)
        external
        view
        returns (bytes32 targetSourceId, bytes32 signalId, uint8 targetOrderRelation);
}
