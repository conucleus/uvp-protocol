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

    // trigger-origin 订单按 (originPlanId, triggerOriginOrderId) 复合键
    // 寻址：派生单与 origin 单可以分属不同 plan，跨 plan 链接必须
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

    /// 事实属主自证：声明非零 stageId 即声明"该 (sourceId, signalId) 事实
    /// 键的属主是 stageId"，必须携有效 membership proof（能力叶
    /// (stageId, sourceId, signalId, relation=0)）。stageId==0 表示不声明
    /// （词表外事实口径）。
    struct FactAttribution {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 stageId;
        bytes32[] capabilityProof;
    }

    /// selector 绑定目标的成员资格证明（(selectorStageId, targetStageId)
    /// 绑定叶）——executor/resource patch 面的判定材料（换人面必须证明
    /// selector 对目标的绑定在能力树内）。
    struct SelectorBindingProof {
        bytes32 selectorStageId;
        bytes32[] proof;
    }

    // trigger link 建立需要 origin 侧同意；origin 事实的属主阶段由
    // originAttribution 携 proof 自证。
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
    /// UB-36①：executor patch 生效时对新城执行者写入显式订单级授权集
    ///（仅 stage patch 模块可调用）。
    function authorizeSignalSubmittersFromModule(
        bytes32 planId,
        bytes32 orderId,
        SignalAuthorization[] calldata authorizations
    ) external;
    /// 授权集哈希公式（trigger 出生与 executor patch 摘要的公共折叠公式）。
    function signalAuthorizationsHash(SignalAuthorization[] calldata authorizations) external pure returns (bytes32);
    /// 合约原生 per-stage 信号计数真源（UB-2）：ASSIGN/HANDOFF 时序闸的
    /// 判定材料（count/末位提交者/末位时刻/同秒歧义标记）。
    function stageSignalState(bytes32 planId, bytes32 orderId, bytes32 stageId)
        external
        view
        returns (uint256 count, address lastSubmitter, uint64 lastAt, bool ambiguous);
    /// plan 承诺的执行者候选集树根（UB-36②③）：EMPTY_ROOT = 无候选集，
    /// 逐单 executor patch 恒拒。
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

    /// dock 出生入口请求（UB-2 批随 UB-36 破坏窗口收束为单结构体入参：
    /// 模块↔主合约 ABI，跨栈参数收拢）。
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

    /// dock input 事实写入请求（同上收拢）。
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

    /// hook 是否声明依赖事实 (sourceId, signalId)（receive 词表投影）。
    function planHookDependsOn(bytes32 planId, bytes32 hookId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool);

    /// 挂有 order-trigger（mint/dock）hook 的阶段对逐单 executor patch
    /// 关闭——出生阶段执行者终生不可变，stage patch 模块以
    /// 此守门。本 flag 判定只覆盖 mint/dock 出生形态；其它订阅阶段（无
    /// order-trigger hook）的执行者不可变约束由编译器在产物层权威强制，
    /// 链上该视图无法判定。
    function stageHasOrderTriggerHook(bytes32 planId, bytes32 stageId) external view returns (bool);

    /// dock output 镜像回写：本地事实键的词表成员资格与属主阶段由
    /// attribution 携 proof 自证。
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
    /// Derived signals write a fact to a target order while the capability's
    /// stage belongs to the producing (from) path. The from identities ride
    /// the call so the executor leg binds to the producing order's stage；
    /// relation=0（from==target 复合键）生产事实过属主就绪门，relation=1
    /// trigger-origin 回写不经门。
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
