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

    function hasTriggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party,
        FactAttribution calldata originAttribution
    ) external view returns (bool);
    function activeStageExecutor(bytes32 planId, bytes32 orderId, bytes32 targetStageId) external view returns (address);
    function activateStageExecutorFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        address executor,
        bytes32 role,
        bytes32 executorMetadataHash,
        bytes32 patchHash,
        uint256 patchNonce,
        string calldata metadataURI
    ) external;
    function authorizeSignalSubmittersFromModule(
        bytes32 planId,
        bytes32 orderId,
        SignalAuthorization[] calldata authorizations
    ) external;
    function authorizeDockedSignalsFromModule(
        bytes32 planId,
        bytes32 orderId,
        SignalAuthorization[] calldata authorizations
    ) external;
    function signalAuthorizationsHash(SignalAuthorization[] calldata authorizations) external pure returns (bytes32);
    function stageSignalState(bytes32 planId, bytes32 orderId, bytes32 stageId)
        external
        view
        returns (uint256 count, address lastSubmitter, uint64 lastAt, bool ambiguous);
    function planExecutorCandidatesRoot(bytes32 planId) external view returns (bytes32);
    function hasExplicitSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool);
    function hasSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId) external view returns (bool);
    function lastSignalSubmitter(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (address);
    function orderCreator(bytes32 planId, bytes32 orderId) external view returns (address);
    function orderExists(bytes32 planId, bytes32 orderId) external view returns (bool);
    function orderLinkModule() external view returns (address);
    function planExists(bytes32 planId) external view returns (bool);
    function planMetadataModule() external view returns (address);
    function planPublisher(bytes32 planId) external view returns (address);
    function sourceSignalCount(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (uint256);

    struct DockEntranceRequest {
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        address creator;
        address relayer;
        bytes32 entranceHookId;
        bytes32 entranceStageId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        SignalAuthorization[] authorizations;
        FactAttribution entranceAttribution;
    }

    struct DockInputFact {
        bytes32 planId;
        bytes32 orderId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        FactAttribution attribution;
    }

    function createDockedOrderFromModule(DockEntranceRequest calldata request) external;

    function recordDockedInputFromModule(DockInputFact calldata fact) external;

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

    function submitSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        FactAttribution calldata attribution
    ) external;
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
        SignalAuthorization[] calldata authorizations,
        address relayer,
        FactAttribution[] calldata originFactAttributions
    ) external;
    function getSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter);
}
