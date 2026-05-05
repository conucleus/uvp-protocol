// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";

interface IUVPStagePatchModuleLens {
    function getActiveStageExecutorPatch(bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        );
    function getActiveStageResourcePatch(bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (
            bool exists,
            bytes32 manifestHash,
            bytes32 policyHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory manifestURI
        );
}

interface IUVPDockingModuleLens {
    function getActiveDockedOrderLink(bytes32 localOrderId, bytes32 linkedOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 selectorStageId,
            bytes32 localSourceId,
            bytes32 linkedPlanId,
            address selector,
            bytes32 linkHash,
            uint256 linkNonce,
            string memory metadataURI
        );
    function getActiveDockedSignalBinding(
        bytes32 localOrderId,
        bytes32 linkedOrderId,
        bytes32 linkedSourceId,
        bytes32 linkedSignalId
    ) external view returns (bool exists, bytes32 localSourceId, bytes32 localSignalId);
}

interface IUVPPlanMetadataModuleLens {
    function planSelectorBindingCount(bytes32 planId) external view returns (uint256);
    function planSelectorBindingAt(bytes32 planId, uint256 index)
        external
        view
        returns (bytes32 selectorStageId, bytes32 targetStageId);
    function planSignalCapabilityCount(bytes32 planId) external view returns (uint256);
    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        external
        view
        returns (bool);
    function isSignalCapabilityRegistered(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) external view returns (bool);
}

interface IUVPOrderLinkModuleLens {
    function targetOrderRelation(bytes32 fromOrderId, bytes32 targetOrderId) external view returns (uint8);
    function getOrderTriggerLink(bytes32 childOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 parentOrderId,
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        );
}

interface IUVPStateMachineModuleDirectory {
    function stagePatchModule() external view returns (address);
    function dockingModule() external view returns (address);
    function planMetadataModule() external view returns (address);
    function orderLinkModule() external view returns (address);
}

contract UVPStateMachineLens {
    IUVPStateMachineCore public immutable stateMachine;
    IUVPStateMachineModuleDirectory private immutable _moduleDirectory;

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
        _moduleDirectory = IUVPStateMachineModuleDirectory(stateMachineAddress);
    }

    function getActiveStageExecutorPatch(bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        )
    {
        return IUVPStagePatchModuleLens(_moduleDirectory.stagePatchModule()).getActiveStageExecutorPatch(
            orderId, targetStageId
        );
    }

    function getActiveStageResourcePatch(bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (
            bool exists,
            bytes32 manifestHash,
            bytes32 policyHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory manifestURI
        )
    {
        return IUVPStagePatchModuleLens(_moduleDirectory.stagePatchModule()).getActiveStageResourcePatch(
            orderId, targetStageId, resourceKey
        );
    }

    function getActiveDockedOrderLink(bytes32 localOrderId, bytes32 linkedOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 selectorStageId,
            bytes32 localSourceId,
            bytes32 linkedPlanId,
            address selector,
            bytes32 linkHash,
            uint256 linkNonce,
            string memory metadataURI
        )
    {
        return IUVPDockingModuleLens(_moduleDirectory.dockingModule()).getActiveDockedOrderLink(
            localOrderId, linkedOrderId
        );
    }

    function getActiveDockedSignalBinding(
        bytes32 localOrderId,
        bytes32 linkedOrderId,
        bytes32 linkedSourceId,
        bytes32 linkedSignalId
    ) external view returns (bool exists, bytes32 localSourceId, bytes32 localSignalId) {
        return IUVPDockingModuleLens(_moduleDirectory.dockingModule()).getActiveDockedSignalBinding(
            localOrderId, linkedOrderId, linkedSourceId, linkedSignalId
        );
    }

    function planSelectorBindingCount(bytes32 planId) external view returns (uint256) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule()).planSelectorBindingCount(planId);
    }

    function planSelectorBindingAt(bytes32 planId, uint256 index)
        external
        view
        returns (bytes32 selectorStageId, bytes32 targetStageId)
    {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule()).planSelectorBindingAt(planId, index);
    }

    function planSignalCapabilityCount(bytes32 planId) external view returns (uint256) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule()).planSignalCapabilityCount(planId);
    }

    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        external
        view
        returns (bool)
    {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule()).isStageSelectorBound(
            planId, selectorStageId, targetStageId
        );
    }

    function isSignalCapabilityRegistered(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) external view returns (bool) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule()).isSignalCapabilityRegistered(
            planId, stageId, targetSourceId, signalId, relation
        );
    }

    function targetOrderRelation(bytes32 fromOrderId, bytes32 targetOrderId) external view returns (uint8) {
        return IUVPOrderLinkModuleLens(_moduleDirectory.orderLinkModule()).targetOrderRelation(
            fromOrderId, targetOrderId
        );
    }

    function getOrderTriggerLink(bytes32 childOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 parentOrderId,
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        )
    {
        return IUVPOrderLinkModuleLens(_moduleDirectory.orderLinkModule()).getOrderTriggerLink(childOrderId);
    }
}
