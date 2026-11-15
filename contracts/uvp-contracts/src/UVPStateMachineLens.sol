// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPDockRegistry} from "./interfaces/IUVPDockRegistry.sol";

interface IUVPStagePatchModuleLens {
    function getStageDockBinding(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId
    )
        external
        view
        returns (
            bool selected,
            bool current,
            bytes32 dockId,
            bytes32 supplierId,
            address executor,
            bytes32 fromPlanId,
            bytes32 bindingId
        );

    function dockOutputWindow(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId,
        uint256 outputIndex
    )
        external
        view
        returns (bool current, bool aSatisfied, uint64 aDueInSeconds, bool bSatisfied, bool emitted);
}

interface IUVPPlanMetadataModuleLens {
    function capabilitiesRoot(bytes32 planId) external view returns (bytes32);
    function hasCapabilityVocabulary(bytes32 planId) external view returns (bool);
    function verifySignalCapability(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation,
        bytes32[] calldata proof
    ) external view returns (bool);
    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
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

    function effectiveStageExecutor(bytes32 planId, bytes32 orderId, bytes32 stageId)
        external
        view
        returns (bytes32 supplierId, address executor)
    {
        return stateMachine.effectiveStageExecutor(planId, orderId, stageId);
    }

    function getActiveStageExecutorPatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bool exists, bytes32 supplierId, address executor, uint256 patchNonce, bytes32 dockId)
    {
        (supplierId, patchNonce, dockId) = stateMachine.activeStageExecutorPatch(planId, orderId, targetStageId);
        exists = supplierId != bytes32(0);
        if (exists) {
            (, executor) = stateMachine.effectiveStageExecutor(planId, orderId, targetStageId);
        }
    }

    function _dockFromPlanId(bytes32 dockId) private view returns (bytes32 fromPlanId) {
        (fromPlanId,,,,,,,) = IUVPDockRegistry(stateMachine.dockRegistry()).getDock(dockId);
    }

    function getActiveStageDockSelection(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bool exists, bytes32 dockId, bytes32 fromPlanId, bytes32 supplierId)
    {
        (supplierId,, dockId) = stateMachine.activeStageExecutorPatch(planId, orderId, targetStageId);
        exists = supplierId != bytes32(0) && dockId != bytes32(0);
        if (exists) {
            fromPlanId = _dockFromPlanId(dockId);
        }
    }

    function getStageDockBinding(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId
    )
        external
        view
        returns (
            bool selected,
            bool current,
            bytes32 dockId,
            bytes32 supplierId,
            address executor,
            bytes32 fromPlanId,
            bytes32 bindingId
        )
    {
        return IUVPStagePatchModuleLens(_moduleDirectory.stagePatchModule())
            .getStageDockBinding(planId, orderId, targetStageId, fromOrderId);
    }

    function dockOutputWindow(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId,
        uint256 outputIndex
    )
        external
        view
        returns (bool current, bool aSatisfied, uint64 aDueInSeconds, bool bSatisfied, bool emitted)
    {
        return IUVPStagePatchModuleLens(_moduleDirectory.stagePatchModule())
            .dockOutputWindow(planId, orderId, targetStageId, fromOrderId, outputIndex);
    }

    function planCapabilitiesRoot(bytes32 planId) external view returns (bytes32) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule()).capabilitiesRoot(planId);
    }

    function planExecutorBindingsRoot(bytes32 planId) external view returns (bytes32) {
        return stateMachine.planExecutorBindingsRoot(planId);
    }

    function planStageHasDynamicExecutor(bytes32 planId, bytes32 stageId) external view returns (bool) {
        return stateMachine.planStageHasDynamicExecutor(planId, stageId);
    }

    function planStageIsCandidate(bytes32 planId, bytes32 stageId) external view returns (bool) {
        return stateMachine.planStageIsCandidate(planId, stageId);
    }

    function planHasCapabilityVocabulary(bytes32 planId) external view returns (bool) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule()).hasCapabilityVocabulary(planId);
    }

    function verifySignalCapability(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation,
        bytes32[] calldata proof
    ) external view returns (bool) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule())
            .verifySignalCapability(planId, stageId, targetSourceId, signalId, relation, proof);
    }

    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool) {
        return IUVPPlanMetadataModuleLens(_moduleDirectory.planMetadataModule())
            .verifyStageSelectorBinding(planId, selectorStageId, targetStageId, proof);
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
