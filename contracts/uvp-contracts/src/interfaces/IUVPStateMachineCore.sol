// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUVPStateMachineCore {
    struct TriggerOrderFromSignalRequest {
        bytes32 orderId;
        bytes32 planId;
        address creator;
        bytes32 triggerOriginOrderId;
        bytes32 originPlanId;
        bytes32 triggerHookId;
        bytes32 triggerStageId;
        bytes32 originSourceId;
        bytes32 originSignalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        uint256 deadline;
    }

    struct FactAttribution {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 stageId;
        bytes32[] capabilityProof;
    }

    struct SelectorBindingProof {
        bytes32 selectorStageId;
        bytes32[] proof;
    }

    struct WindowInstruction {
        uint8 op;
        bytes32 sourceId;
        bytes32 signalId;
        uint16 arity;
        uint64 delaySeconds;
    }

    function supplierRegistry() external view returns (address);

    function hasTriggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party,
        FactAttribution calldata originAttribution
    ) external view returns (bool);

    function effectiveStageSupplier(bytes32 planId, bytes32 orderId, bytes32 stageId) external view returns (bytes32);

    function effectiveStageAccount(bytes32 planId, bytes32 orderId, bytes32 stageId) external view returns (address);

    function isEffectiveStageAccount(bytes32 planId, bytes32 orderId, bytes32 stageId, address account)
        external
        view
        returns (bool);

    function stageSupplierAssignment(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bytes32 supplierId, uint256 patchNonce, bytes32 dockId);

    function activateStageSupplierFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        uint256 patchNonce
    ) external;

    function activateStageDockSupplierFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        bytes32 dockId,
        uint256 patchNonce
    ) external;

    function planSupplierBindingsRoot(bytes32 planId) external view returns (bytes32);

    function planStageDefaultSupplier(bytes32 planId, bytes32 stageId) external view returns (bytes32);

    function planStageHasDynamicSupplier(bytes32 planId, bytes32 stageId) external view returns (bool);

    function planStageIsCandidate(bytes32 planId, bytes32 stageId) external view returns (bool);

    function stageSignalState(bytes32 planId, bytes32 orderId, bytes32 stageId)
        external
        view
        returns (uint256 count, address lastSubmitter, uint64 lastAt, bool ambiguous);

    function hasSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool);

    function lastSignalSubmitter(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (address);

    function orderCreator(bytes32 planId, bytes32 orderId) external view returns (address);

    function orderExists(bytes32 planId, bytes32 orderId) external view returns (bool);

    function orderLinkModule() external view returns (address);

    function isPlanStage(bytes32 planId, bytes32 stageId) external view returns (bool);

    function planExists(bytes32 planId) external view returns (bool);

    function planMetadataModule() external view returns (address);

    function fileResourceModule() external view returns (address);

    function planPublisher(bytes32 planId) external view returns (address);

    function sourceSignalCount(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (uint256);

    function dockRegistry() external view returns (address);

    function stageHasDockExecutorHook(bytes32 planId, bytes32 stageId) external view returns (bool);

    function evaluateDockWindow(
        bytes32 planId,
        bytes32 orderId,
        WindowInstruction[] calldata instructions
    ) external view returns (bool satisfied, uint64 dueInSeconds);

    function isSignalAdmissionSatisfied(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool);

    function planHookFlags(bytes32 planId, bytes32 hookId) external view returns (uint8);

    function getHookStatus(bytes32 planId, bytes32 orderId, bytes32 hookId)
        external
        view
        returns (uint8 status, uint64 dueAt, bool readyEmitted);

    function planHookStageId(bytes32 planId, bytes32 hookId) external view returns (bytes32);

    function planHookDependsOn(bytes32 planId, bytes32 hookId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool);

    function stageHasOrderTriggerHook(bytes32 planId, bytes32 stageId) external view returns (bool);

    function submitDockOutputSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        FactAttribution calldata attribution
    ) external returns (bool submitted);

    function submitDerivedSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 fromPlanId,
        bytes32 fromOrderId,
        bytes32 stageId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external;

    function triggerOrderFromSignalFromModule(
        TriggerOrderFromSignalRequest calldata trigger,
        address relayer,
        FactAttribution[] calldata originFactAttributions
    ) external;

    function getSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter);
}
