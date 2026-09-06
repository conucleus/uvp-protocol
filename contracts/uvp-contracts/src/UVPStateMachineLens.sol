// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";

interface IUVPStagePatchModuleLens {
    function getActiveStageExecutorPatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
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
    function getActiveStageResourcePatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
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
    function getActiveDock(bytes32 dockInstanceId)
        external
        view
        returns (
            bytes32 localPlanId,
            bytes32 localOrderId,
            bytes32 localStageId,
            bytes32 routeId,
            bytes32 routeHash,
            bytes32 targetPlanId,
            bytes32 linkedOrderId,
            uint8 depth,
            uint8 status,
            bool exists
        );

    function getDockInputBinding(bytes32 dockInstanceId, bytes32 inputBindingHash)
        external
        view
        returns (
            bytes32 localHookId,
            bytes32 portKey,
            bytes32 targetSourceId,
            bytes32 targetSignalId,
            uint8 kind,
            bool exists
        );

    function getDockOutputBinding(bytes32 dockInstanceId, bytes32 outputBindingHash)
        external
        view
        returns (
            bytes32 localSourceId,
            bytes32 localSignalId,
            bytes32 portKey,
            bytes32 targetSourceId,
            bytes32 targetSignalId,
            uint8 terminal,
            bool exists
        );

    function dockInputDelivered(bytes32 dockInstanceId, bytes32 inputBindingHash) external view returns (bool);
    function dockOutputDelivered(bytes32 dockInstanceId, bytes32 outputBindingHash) external view returns (bool);
    function dockByLocalRoute(bytes32 localRouteInstanceKey) external view returns (bytes32);
    function dockByTargetOrder(bytes32 targetEndpointKey) external view returns (bytes32);
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
    function isSelectorTargetStage(bytes32 planId, bytes32 targetStageId) external view returns (bool);
    function isSignalCapabilityRegistered(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) external view returns (bool);
}

interface IUVPOrderLinkModuleLens {
    function targetOrderRelation(bytes32 fromPlanId, bytes32 fromOrderId, bytes32 targetPlanId, bytes32 targetOrderId)
        external
        view
        returns (uint8);
    function getTriggerOriginLink(bytes32 planId, bytes32 triggeredOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 triggerOriginOrderId,
            bytes32 triggerOriginPlanId,
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

    function getActiveStageExecutorPatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
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
        return IUVPStagePatchModuleLens(_moduleDirectory.stagePatchModule())
            .getActiveStageExecutorPatch(planId, orderId, targetStageId);
    }

    function getActiveStageResourcePatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
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
        return IUVPStagePatchModuleLens(_moduleDirectory.stagePatchModule())
            .getActiveStageResourcePatch(planId, orderId, targetStageId, resourceKey);
    }

    function getActiveDock(bytes32 dockInstanceId)
        external
        view
        returns (
            bytes32 localPlanId,
            bytes32 localOrderId,
            bytes32 localStageId,
            bytes32 routeId,
            bytes32 routeHash,
            bytes32 targetPlanId,
            bytes32 linkedOrderId,
            uint8 depth,
            uint8 status,
            bool exists
        )
    {
        return IUVPDockingModuleLens(_moduleDirectory.dockingModule()).getActiveDock(dockInstanceId);
    }

    function getDockInputBinding(bytes32 dockInstanceId, bytes32 inputBindingHash)
        external
        view
        returns (
            bytes32 localHookId,
            bytes32 portKey,
            bytes32 targetSourceId,
            bytes32 targetSignalId,
            uint8 kind,
            bool exists
        )
    {
        return IUVPDockingModuleLens(_moduleDirectory.dockingModule())
            .getDockInputBinding(dockInstanceId, inputBindingHash);
    }

    function getDockOutputBinding(bytes32 dockInstanceId, bytes32 outputBindingHash)
        external
        view
        returns (
            bytes32 localSourceId,
            bytes32 localSignalId,
            bytes32 portKey,
            bytes32 targetSourceId,
            bytes32 targetSignalId,
            uint8 terminal,
            bool exists
        )
    {
        return IUVPDockingModuleLens(_moduleDirectory.dockingModule())
            .getDockOutputBinding(dockInstanceId, outputBindingHash);
    }

    function dockInputDelivered(bytes32 dockInstanceId, bytes32 inputBindingHash) external view returns (bool) {
        return
            IUVPDockingModuleLens(_moduleDirectory.dockingModule()).dockInputDelivered(dockInstanceId, inputBindingHash);
    }

    function dockOutputDelivered(bytes32 dockInstanceId, bytes32 outputBindingHash) external view returns (bool) {
        return
            IUVPDockingModuleLens(_moduleDirectory.dockingModule())
                .dockOutputDelivered(dockInstanceId, outputBindingHash);
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
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule())
            .isStageSelectorBound(planId, selectorStageId, targetStageId);
    }

    function isSelectorTargetStage(bytes32 planId, bytes32 targetStageId) external view returns (bool) {
        return
            IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule())
                .isSelectorTargetStage(planId, targetStageId);
    }

    function isSignalCapabilityRegistered(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) external view returns (bool) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule())
            .isSignalCapabilityRegistered(planId, stageId, targetSourceId, signalId, relation);
    }

    function targetOrderRelation(bytes32 fromPlanId, bytes32 fromOrderId, bytes32 targetPlanId, bytes32 targetOrderId)
        external
        view
        returns (uint8)
    {
        return IUVPOrderLinkModuleLens(_moduleDirectory.orderLinkModule())
            .targetOrderRelation(fromPlanId, fromOrderId, targetPlanId, targetOrderId);
    }

    function getTriggerOriginLink(bytes32 planId, bytes32 triggeredOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 triggerOriginOrderId,
            bytes32 triggerOriginPlanId,
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        )
    {
        return IUVPOrderLinkModuleLens(_moduleDirectory.orderLinkModule())
            .getTriggerOriginLink(planId, triggeredOrderId);
    }
}
