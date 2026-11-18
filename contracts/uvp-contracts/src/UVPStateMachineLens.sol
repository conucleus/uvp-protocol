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
            address supplierAccount,
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

interface IUVPStateMachineModuleDirectory {
    function stagePatchModule() external view returns (address);
    function planMetadataModule() external view returns (address);
}

contract UVPStateMachineLens {
    IUVPStateMachineCore public immutable stateMachine;
    IUVPStateMachineModuleDirectory private immutable _moduleDirectory;

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
        _moduleDirectory = IUVPStateMachineModuleDirectory(stateMachineAddress);
    }

    function effectiveStageSupplier(bytes32 planId, bytes32 orderId, bytes32 stageId)
        external
        view
        returns (bytes32)
    {
        return stateMachine.effectiveStageSupplier(planId, orderId, stageId);
    }

    function effectiveStageAccount(bytes32 planId, bytes32 orderId, bytes32 stageId) external view returns (address) {
        return stateMachine.effectiveStageAccount(planId, orderId, stageId);
    }

    function getActiveStageSupplierAssignment(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bool exists, bytes32 supplierId, address supplierAccount, uint256 patchNonce, bytes32 dockId)
    {
        (supplierId, patchNonce, dockId) = stateMachine.stageSupplierAssignment(planId, orderId, targetStageId);
        exists = supplierId != bytes32(0);
        if (exists) {
            supplierAccount = stateMachine.effectiveStageAccount(planId, orderId, targetStageId);
        }
    }

    function _dockFromPlanId(bytes32 dockId) private view returns (bytes32 fromPlanId) {
        (fromPlanId,,,,,,,) = IUVPDockRegistry(stateMachine.dockRegistry()).getDock(dockId);
    }

    function getActiveStageDockSupplierSelection(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bool exists, bytes32 dockId, bytes32 fromPlanId, bytes32 supplierId)
    {
        (supplierId,, dockId) = stateMachine.stageSupplierAssignment(planId, orderId, targetStageId);
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
            address supplierAccount,
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

    function planSupplierBindingsRoot(bytes32 planId) external view returns (bytes32) {
        return stateMachine.planSupplierBindingsRoot(planId);
    }

    function planStageHasDynamicSupplier(bytes32 planId, bytes32 stageId) external view returns (bool) {
        return stateMachine.planStageHasDynamicSupplier(planId, stageId);
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
}
