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

    // 审计 #10 解冻批次：订单身份从全局 orderId 收紧为 (planId, orderId)。
    // 结构体新增 originPlanId 字段（新版本口径）：trigger-origin 订单按
    // (originPlanId, triggerOriginOrderId) 复合键寻址，跨 plan 链接必须
    // 显式声明 origin 的 plan。
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

    // 审计 #1 残余：trigger link 建立需要 origin 侧同意。
    function hasTriggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party
    ) external view returns (bool);
    function activeStageExecutor(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (address);
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
    function delegateStageExecutorSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 sourceId,
        bytes32 signalId,
        address executor,
        bytes32 role,
        bytes32 metadataHash,
        uint256 patchNonce
    ) external;
    function hasExplicitSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool);
    function hasSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool);
    function lastSignalSubmitter(bytes32 planId, bytes32 orderId, bytes32 sourceId)
        external
        view
        returns (address);
    function orderCreator(bytes32 planId, bytes32 orderId) external view returns (address);
    function orderExists(bytes32 planId, bytes32 orderId) external view returns (bool);
    function orderLinkModule() external view returns (address);
    function planExists(bytes32 planId) external view returns (bool);
    function planMetadataModule() external view returns (address);
    function planPublisher(bytes32 planId) external view returns (address);
    function sourceSignalCount(bytes32 planId, bytes32 orderId, bytes32 sourceId)
        external
        view
        returns (uint256);
    function createDockedOrderFromModule(
        bytes32 targetPlanId,
        bytes32 linkedOrderId,
        address creator,
        address relayer,
        bytes32 entranceHookId,
        bytes32 entranceStageId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        SignalAuthorization[] calldata authorizations
    ) external;

    function recordDockedInputFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external;

    function planHookFlags(bytes32 planId, bytes32 hookId) external view returns (uint8);

    function getHookStatus(bytes32 planId, bytes32 orderId, bytes32 hookId)
        external
        view
        returns (uint8 status, uint64 dueAt, bool readyEmitted);

    function planHookStageId(bytes32 planId, bytes32 hookId) external view returns (bytes32);

    function submitSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external;
    /// Derived signals carry the stage that authorizes the originating path
    /// separately from the target signal source. The target order receives the
    /// fact, while its active executor (if any) still gates the write.
    function submitDerivedSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
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
        address relayer
    ) external;
    function getSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter);
}
