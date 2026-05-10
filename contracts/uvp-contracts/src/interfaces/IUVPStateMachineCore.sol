// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUVPStateMachineCore {
    struct SignalAuthorization {
        bytes32 sourceId;
        bytes32 signalId;
        address submitter;
        bytes32 role;
        bytes32 metadataHash;
    }

    struct TriggerOrderFromSignalRequest {
        bytes32 orderId;
        bytes32 planId;
        address creator;
        bytes32 triggerOriginOrderId;
        bytes32 triggerHookId;
        bytes32 triggerStageId;
        bytes32 originSourceId;
        bytes32 originSignalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        uint256 deadline;
    }

    function activeStageExecutor(bytes32 orderId, bytes32 targetStageId) external view returns (address);
    function activateStageExecutorFromModule(
        bytes32 orderId,
        bytes32 targetStageId,
        address executor,
        bytes32 role,
        bytes32 executorMetadataHash,
        bytes32 patchHash,
        uint256 patchNonce
    ) external;
    function hasExplicitSignalAuthorization(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        external
        view
        returns (bool);
    function hasSignal(bytes32 orderId, bytes32 sourceId, bytes32 signalId) external view returns (bool);
    function lastSignalSubmitter(bytes32 orderId, bytes32 sourceId) external view returns (address);
    function orderExists(bytes32 orderId) external view returns (bool);
    function orderPlanId(bytes32 orderId) external view returns (bytes32);
    function orderLinkModule() external view returns (address);
    function orderRegistrars(address registrar) external view returns (bool);
    function planExists(bytes32 planId) external view returns (bool);
    function planMetadataModule() external view returns (address);
    function planPublisher(bytes32 planId) external view returns (address);
    function sourceSignalCount(bytes32 orderId, bytes32 sourceId) external view returns (uint256);
    function submitSignalFromModule(
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external;
    function triggerOrderFromSignalFromModule(
        TriggerOrderFromSignalRequest calldata trigger,
        SignalAuthorization[] calldata authorizations,
        address registrar
    ) external;
    function getSignal(bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter);
}
