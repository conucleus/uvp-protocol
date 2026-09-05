// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";

contract UVPStateMachine {
    enum HookStatus {
        Init,
        Wait,
        Ready,
        Cancelled
    }

    enum InstructionOp {
        Signal,
        Not,
        And,
        Or,
        Delay,
        Merge
    }

    struct Instruction {
        InstructionOp op;
        bytes32 sourceId;
        bytes32 signalId;
        uint16 arity;
        uint64 delaySeconds;
    }

    struct CompactHook {
        bytes32 hookId;
        bytes32 stageId;
        bytes32 hookName;
        // PRD94 §3.4 / PRD95 §5.3：单一 isTrigger 拆为位标志。
        // 1 = ORDER_TRIGGER_MINT；2 = ORDER_TRIGGER_DOCK；4 = EMIT_READY。
        uint8 flags;
        Instruction[] instructions;
        bytes32[] dependencyKeys;
    }

    struct HookRuntime {
        HookStatus status;
        uint64 dueAt;
        bool readyEmitted;
        bool exists;
    }

    struct SignalRecord {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        uint64 submittedAt;
        address submitter;
        bool exists;
    }

    struct SignalAuthorization {
        bytes32 sourceId;
        bytes32 signalId;
        address submitter;
        bytes32 role;
        bytes32 metadataHash;
    }

    struct TriggerOrderFromOutsideRequest {
        // 审计批次(一事一单)：orderId 不再自报——合约内按
        // triggerOrderIdFor(planId, sourceId, signalId, payloadHash) 纯函数
        // 派生，同一事实恒定同 id，重放幂等（OrderAlreadyRegistered）。
        bytes32 planId;
        address creator;
        bytes32 triggerHookId;
        bytes32 triggerStageId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        uint256 deadline;
    }

    // 审计 #10 解冻批次：订单身份从全局 orderId 收紧为 (planId, orderId)。
    // 结构体新增 originPlanId 字段（新版本口径）：trigger-origin 订单按
    // (originPlanId, triggerOriginOrderId) 复合键寻址，派生单与 origin 单
    // 可以分属不同 plan，跨 plan 链接必须显式声明 origin 的 plan。
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

    // PRD95 §5.1：PlanCommitV2 显式提交 dock roots；runtime hash 覆盖全部
    // 五个域，executorRoutes 不再有"产物有、commitment 无"的悬空状态。
    struct PlanCommit {
        address publisher;
        bytes32 hooksHash;
        bytes32 metadataHash;
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
        uint256 deadline;
    }

    struct StoredSignalAuthorization {
        bytes32 role;
        bytes32 metadataHash;
        bool exists;
    }

    struct DelegatedStageSignalAuthorization {
        bytes32 targetStageId;
        address executor;
        bytes32 role;
        bytes32 metadataHash;
        uint256 patchNonce;
        bool exists;
    }

    struct StoredHook {
        bytes32 hookId;
        bytes32 stageId;
        bytes32 hookName;
        uint8 flags;
        Instruction[] instructions;
        bytes32[] dependencyKeys;
        bool exists;
    }

    struct Plan {
        bytes32 planHash;
        bytes32 hooksHash;
        bytes32 metadataHash;
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
        address publisher;
        bytes32[] hookIds;
        mapping(bytes32 hookId => StoredHook hook) hooks;
        mapping(bytes32 signalKey => bytes32[] hookIds) dependencyIndex;
        mapping(bytes32 stageId => bool exists) stageExists;
        bool committed;
        bool finalized;
    }

    struct Order {
        // 审计 #10：planId 移入存储键（(planId, orderId) 复合键），不再随
        // 结构体存储；订单的 plan 归属由寻址键本身保证，无法伪造。
        address relayer;
        address creator;
        mapping(bytes32 hookId => HookRuntime runtime) hookRuntimes;
        mapping(bytes32 stageId => bool materialized) materializedStages;
        bool materialized;
        bool exists;
    }

    struct ActiveStageExecutorPatch {
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
        bool exists;
    }

    struct EvalValue {
        bool value;
        bool wait;
        bool cancel;
        uint64 dueAt;
        uint64 anchorAt;
    }

    error EmptyPlan();
    error ExpiredSignalSignature(uint256 deadline);
    error ExpiredPlanSignature(uint256 deadline);
    error HookAlreadyRegistered();
    error HookDelayTooLong(uint256 delaySeconds);
    error CrossStageDependency(bytes32 signalKey);
    error TooManyDependencies();
    error InvalidSignalSignature(address expectedSigner, address recoveredSigner);
    error InvalidSignalSignatureLength(uint256 length);
    error InvalidSignalCapability(bytes32 planId, bytes32 sourceId, bytes32 signalId);
    error InvalidInstruction();
    error InvalidHook();
    error InvalidModuleAddress();
    /// Dock child order IDs use a reserved namespace. Public MINT and
    /// trigger-origin paths must not be able to front-run a deterministic
    /// linkedOrderId.
    error InvalidDockOrderNamespace(bytes32 orderId);
    error InvalidPlanSignature(address expectedSigner, address recoveredSigner);
    error IncompleteModuleConfiguration();
    error InvalidTriggerHook(bytes32 hookId);
    error InvalidTriggerOrderSignature(address expectedSigner, address recoveredSigner);
    error ModulesAlreadyFrozen();
    error ModulesFrozen();
    error ModulesNotFrozen();
    error NotOwner();
    error OrderAlreadyRegistered();
    error PlanAlreadyRegistered();
    error PlanMetadataHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error PlanNotCommitted();
    error PlanNotFinalized();
    error SignalAlreadyExists();
    error SignalSubmitterAlreadyAuthorized(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error StageExecutorNotAssigned(bytes32 orderId, bytes32 targetStageId);
    error StageNotMaterializable(bytes32 stageId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error TimerNotDue();
    error TimerNotWaiting();
    // 审计 #1 残余：trigger link 建立缺少 origin 侧同意。submitter 与
    // relayer 都不在 origin 订单的同意集合（创建者 / origin 源阶段执行器 /
    // origin 事实的授权提交者）内时拒绝。
    error UnauthorizedTriggerOrigin(bytes32 originPlanId, bytes32 originOrderId, address submitter);
    error UnauthorizedSignalSubmitter(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error UnauthorizedStateMachineModule(address caller);
    error UnauthorizedStageExecutor(bytes32 orderId, bytes32 targetStageId, address submitter, address executor);
    error UnknownHook();
    error UnknownOrder();
    error UnknownPlan();
    error ZeroOrderCreator();
    error ZeroOrderId();
    error ZeroPatchHash();
    error ZeroOwner();
    error ZeroPlanPublisher();
    error ZeroSignalId();
    error ZeroSourceId();
    error ZeroStageExecutor();
    error ZeroSubmitter();
    error ZeroTargetStageId();

    address public owner;
    address public stagePatchModule;
    address public derivedSignalModule;
    address public dockingModule;
    address public planMetadataModule;
    address public orderLinkModule;
    address public lens;
    bool public modulesFrozen;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStateMachine");
    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.10");
    bytes32 private constant _PLAN_RUNTIME_HASH_DOMAIN = keccak256("uvp.plan.runtime.v2");
    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_DOCK = 2;
    uint8 public constant HOOK_FLAG_EMIT_READY = 4;
    bytes32 private constant _PLAN_ID_HASH_DOMAIN = keccak256("uvp.plan.id.v1");
    bytes32 public constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    uint64 public constant MAX_HOOK_DELAY_SECONDS = 30 days;
    uint256 public constant MAX_PLAN_DEPENDENCIES = 1024;
    bytes32 private constant _PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 metadataHash,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
    );
    bytes32 private constant _SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        // 审计 #10：signal 提交摘要并入 planId（新版本口径），签名绑定
        // (planId, orderId) 而不再是全局 orderId。
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant _TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        // 一事一单批次：摘要去掉自报 orderId——订单 id 由合约从事实纯函数
        // 派生，签名不再背书调用方选择的订单号（防 mempool 抢注受害单号）。
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );
    mapping(bytes32 planId => Plan plan) private _plans;
    // 审计 #10：订单及全部 per-order 状态按 (planId, orderId) 复合键存储。
    // orderId 不再是全局唯一键——不同 plan 各自拥有同一 orderId 的订单时
    // 互不可见、互不干扰；同一 plan 内同一 orderId 仍保持创建幂等
    // （OrderAlreadyRegistered），"同 plan 同事实同单"的重放语义不变。
    // 订单 id 派生公式必须在链下并入 planId 域，使派生单号天然绑定 plan。
    mapping(bytes32 planId => mapping(bytes32 orderId => Order order)) private _orders;
    mapping(bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 signalKey => SignalRecord signal))) private
        _signals;
    mapping(
        bytes32 planId
            => mapping(
            bytes32 orderId
                => mapping(bytes32 signalKey => mapping(address submitter => StoredSignalAuthorization authorization))
        )
    ) private _signalAuthorizations;
    mapping(
        bytes32 planId
            => mapping(bytes32 orderId => mapping(bytes32 signalKey => DelegatedStageSignalAuthorization authorization))
    ) private _delegatedStageSignalAuthorizations;
    mapping(bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 sourceId => uint256 count))) public
        sourceSignalCount;
    mapping(bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 sourceId => address submitter))) public
        lastSignalSubmitter;
    mapping(
        bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch))
    ) private _activeStageExecutorPatches;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StateMachineModuleSet(bytes32 indexed moduleId, address indexed previousModule, address indexed newModule);
    event StateMachineModulesFrozen(bytes32 indexed moduleSetHash);
    event PlanCommitted(
        bytes32 indexed planId,
        bytes32 indexed planHash,
        address indexed publisher,
        bytes32 hooksHash,
        bytes32 metadataHash,
        uint256 hookCount,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot
    );
    event PlanFinalized(bytes32 indexed planId, bytes32 indexed planHash, bytes32 metadataHash);
    event PlanRegistered(bytes32 indexed planId, bytes32 planHash, uint256 hookCount);
    event PlanPublisherRecorded(bytes32 indexed planId, address indexed publisher);
    event OrderRegistered(bytes32 indexed orderId, bytes32 indexed planId);
    event OrderMaterialized(bytes32 indexed orderId, bytes32 indexed planId, bytes32 indexed stageId);
    event OrderRelayerRecorded(
        bytes32 indexed planId, bytes32 indexed orderId, address indexed relayer, address creator
    );
    event SignalSubmitterAuthorized(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        address submitter,
        bytes32 role,
        bytes32 metadataHash
    );
    event StageExecutorSignalDelegated(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 sourceId,
        bytes32 signalId,
        address executor,
        bytes32 role,
        bytes32 metadataHash,
        uint256 patchNonce
    );
    event SignalSubmitted(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    );
    event StageMaterialized(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed stageId,
        bytes32 triggerHookId,
        bytes32 sourceId,
        bytes32 signalId
    );
    event OrderTriggered(
        bytes32 indexed orderId,
        bytes32 indexed planId,
        bytes32 indexed triggerStageId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    );
    event StageExecutorActivated(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        address executor,
        bytes32 role,
        bytes32 metadataHash,
        uint256 patchNonce,
        string metadataURI
    );
    event HookStatusChanged(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed hookId,
        HookStatus previousStatus,
        HookStatus newStatus,
        uint64 dueAt
    );
    event HookReady(
        bytes32 indexed planId, bytes32 indexed orderId, bytes32 indexed hookId, bytes32 stageId, bytes32 hookName
    );
    event TimerPoked(bytes32 indexed planId, bytes32 indexed orderId, bytes32 indexed hookId, uint64 dueAt);

    bytes32 public constant STAGE_PATCH_MODULE_ID = keccak256("uvp.module.stage_patch.v1");
    bytes32 public constant DERIVED_SIGNAL_MODULE_ID = keccak256("uvp.module.derived_signal.v1");
    bytes32 public constant DOCKING_MODULE_ID = keccak256("uvp.module.docking.v1");
    bytes32 public constant PLAN_METADATA_MODULE_ID = keccak256("uvp.module.plan_metadata.v1");
    bytes32 public constant ORDER_LINK_MODULE_ID = keccak256("uvp.module.order_link.v1");
    bytes32 public constant LENS_MODULE_ID = keccak256("uvp.module.lens.v1");

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroOwner();
        }
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function setStagePatchModule(address moduleAddress) external onlyOwner {
        stagePatchModule = _setModule(STAGE_PATCH_MODULE_ID, stagePatchModule, moduleAddress);
    }

    function setDerivedSignalModule(address moduleAddress) external onlyOwner {
        derivedSignalModule = _setModule(DERIVED_SIGNAL_MODULE_ID, derivedSignalModule, moduleAddress);
    }

    function setDockingModule(address moduleAddress) external onlyOwner {
        dockingModule = _setModule(DOCKING_MODULE_ID, dockingModule, moduleAddress);
    }

    function setPlanMetadataModule(address moduleAddress) external onlyOwner {
        planMetadataModule = _setModule(PLAN_METADATA_MODULE_ID, planMetadataModule, moduleAddress);
    }

    function setOrderLinkModule(address moduleAddress) external onlyOwner {
        orderLinkModule = _setModule(ORDER_LINK_MODULE_ID, orderLinkModule, moduleAddress);
    }

    function setLens(address moduleAddress) external onlyOwner {
        lens = _setModule(LENS_MODULE_ID, lens, moduleAddress);
    }

    function freezeModules() external onlyOwner {
        if (modulesFrozen) {
            revert ModulesAlreadyFrozen();
        }
        if (
            stagePatchModule == address(0) || derivedSignalModule == address(0) || dockingModule == address(0)
                || planMetadataModule == address(0) || orderLinkModule == address(0) || lens == address(0)
        ) {
            revert IncompleteModuleConfiguration();
        }

        modulesFrozen = true;
        emit StateMachineModulesFrozen(moduleSetHash());
    }

    function moduleSetHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(stagePatchModule, derivedSignalModule, dockingModule, planMetadataModule, orderLinkModule, lens)
        );
    }

    function _setModule(bytes32 moduleId, address previousModule, address moduleAddress) private returns (address) {
        if (modulesFrozen) {
            revert ModulesFrozen();
        }
        if (moduleAddress == address(0) || moduleAddress == address(this)) {
            revert InvalidModuleAddress();
        }
        emit StateMachineModuleSet(moduleId, previousModule, moduleAddress);
        return moduleAddress;
    }

    function commitPlan(PlanCommit calldata commit, CompactHook[] calldata hooks, bytes calldata signature)
        external
        returns (bytes32 planId)
    {
        if (!modulesFrozen) {
            revert ModulesNotFrozen();
        }
        if (block.timestamp > commit.deadline) {
            revert ExpiredPlanSignature(commit.deadline);
        }
        if (commit.publisher == address(0)) {
            revert ZeroPlanPublisher();
        }
        if (hooks.length == 0) {
            revert EmptyPlan();
        }
        bytes32 actualHooksHash = keccak256(abi.encode(hooks));
        if (actualHooksHash != commit.hooksHash) {
            revert PlanMetadataHashMismatch(commit.hooksHash, actualHooksHash);
        }
        address recoveredSigner = _recoverSignalSubmitter(_planCommitDigest(commit), signature);
        if (recoveredSigner != commit.publisher) {
            revert InvalidPlanSignature(commit.publisher, recoveredSigner);
        }

        bytes32 dockRoutesRoot = commit.dockRoutesRoot == bytes32(0) ? DockMerkle.EMPTY_ROOT : commit.dockRoutesRoot;
        bytes32 dockInterfaceRoot =
            commit.dockInterfaceRoot == bytes32(0) ? DockMerkle.EMPTY_ROOT : commit.dockInterfaceRoot;
        bytes32 runtimePlanHash =
            planRuntimeHash(commit.hooksHash, commit.metadataHash, dockRoutesRoot, dockInterfaceRoot);
        planId = planIdFor(commit.publisher, runtimePlanHash);
        Plan storage plan = _plans[planId];
        if (plan.committed) {
            revert PlanAlreadyRegistered();
        }
        plan.planHash = runtimePlanHash;
        plan.hooksHash = commit.hooksHash;
        plan.metadataHash = commit.metadataHash;
        plan.dockRoutesRoot = dockRoutesRoot;
        plan.dockInterfaceRoot = dockInterfaceRoot;
        plan.publisher = commit.publisher;
        plan.committed = true;

        // Cross-stage dependency scan scratch: scoped so the large memory
        // arrays release their stack slots before the commit events fire.
        {
            bytes32[] memory seenKeys = new bytes32[](MAX_PLAN_DEPENDENCIES);
            bytes32[] memory seenStages = new bytes32[](MAX_PLAN_DEPENDENCIES);
            bool[] memory seenTriggerOnly = new bool[](MAX_PLAN_DEPENDENCIES);
            // 阶段物化防御纵深（簇 A2）：每个被注册 hook 的阶段必须至少有
            // 一个 order-trigger 或 EMIT_READY hook——纯 flags=0 watcher 阶段
            // 在链上永远无法物化（物化只由本阶段 hook Ready 触发，executor
            // patch 不物化），其 watcher 会让共享信号键的提交交易稳定回滚。
            // 编译器是第一道防线；这里是注册边界。
            bytes32[] memory stageScratch = new bytes32[](hooks.length);
            bool[] memory stageMaterializer = new bool[](hooks.length);
            uint256 seenCount;
            for (uint256 i = 0; i < hooks.length; i++) {
                seenCount = _registerPlanHook(plan, hooks[i], seenKeys, seenStages, seenTriggerOnly, seenCount);
                uint256 stageIndex = _seenDependencyIndex(stageScratch, i, hooks[i].stageId);
                if (stageIndex == type(uint256).max) {
                    stageScratch[i] = hooks[i].stageId;
                    stageMaterializer[i] = _hookCanMaterializeStage(hooks[i].flags);
                } else if (_hookCanMaterializeStage(hooks[i].flags)) {
                    stageMaterializer[stageIndex] = true;
                }
            }
            for (uint256 i = 0; i < hooks.length; i++) {
                if (stageScratch[i] == bytes32(0)) {
                    continue;
                }
                if (!stageMaterializer[i]) {
                    revert StageNotMaterializable(stageScratch[i]);
                }
            }
        }

        emit PlanCommitted(
            planId,
            runtimePlanHash,
            commit.publisher,
            commit.hooksHash,
            commit.metadataHash,
            hooks.length,
            dockRoutesRoot,
            dockInterfaceRoot
        );
        emit PlanPublisherRecorded(planId, commit.publisher);
    }

    function finalizePlan(
        bytes32 planId,
        IUVPPlanMetadataModule.StageSelectorBinding[] calldata selectorBindings,
        IUVPPlanMetadataModule.SignalCapability[] calldata signalCapabilities
    ) external {
        Plan storage plan = _plans[planId];
        if (!plan.committed) {
            revert PlanNotCommitted();
        }
        if (plan.finalized) {
            revert PlanAlreadyRegistered();
        }
        bytes32 actualMetadataHash = keccak256(abi.encode(selectorBindings, signalCapabilities));
        if (actualMetadataHash != plan.metadataHash) {
            revert PlanMetadataHashMismatch(plan.metadataHash, actualMetadataHash);
        }

        IUVPPlanMetadataModule(planMetadataModule)
            .finalizePlanMetadata(
                planId, selectorBindings, signalCapabilities, plan.dockRoutesRoot, plan.dockInterfaceRoot
            );
        plan.finalized = true;

        emit PlanFinalized(planId, plan.planHash, plan.metadataHash);
        emit PlanRegistered(planId, plan.planHash, plan.hookIds.length);
    }

    function planRuntimeHash(bytes32 hooksHash, bytes32 metadataHash, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot)
        public
        pure
        returns (bytes32)
    {
        return
            keccak256(abi.encode(_PLAN_RUNTIME_HASH_DOMAIN, hooksHash, metadataHash, dockRoutesRoot, dockInterfaceRoot));
    }

    function planIdFor(address publisher, bytes32 runtimePlanHash) public pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_ID_HASH_DOMAIN, publisher, runtimePlanHash));
    }

    function triggerOrderFromOutsideFor(
        TriggerOrderFromOutsideRequest calldata trigger,
        SignalAuthorization[] calldata authorizations,
        bytes calldata signature
    ) external {
        if (block.timestamp > trigger.deadline) {
            revert ExpiredSignalSignature(trigger.deadline);
        }
        if (trigger.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        // 白皮书 §11.3 语义校验承诺：出生事实 (sourceId, signalId) 必须在
        // 本 plan 的 capability 词表内（relation=0）。无任何 capability 声明
        // 的手工 plan 保持历史放行口径（与 _signalStageId 的 legacy 行为一致）。
        {
            bool factKnown = _signalStageId(trigger.planId, trigger.sourceId, trigger.signalId) != bytes32(0);
            if (!factKnown && _planSignalCapabilityCount(trigger.planId) != 0) {
                revert InvalidSignalCapability(trigger.planId, trigger.sourceId, trigger.signalId);
            }
        }

        {
            bytes32 authorizationsHash = _signalAuthorizationsHash(authorizations);
            address recoveredSigner =
                _recoverSignalSubmitter(_triggerOrderFromOutsideDigest(trigger, authorizationsHash), signature);
            if (recoveredSigner != trigger.submitter) {
                revert InvalidTriggerOrderSignature(trigger.submitter, recoveredSigner);
            }
        }
        _createOutsideTriggerOrder(trigger, authorizations);
    }

    /// 一事一单执行体：订单 id 由合约从事实纯函数派生，调用方不再自报。
    /// 同一 (planId, sourceId, signalId, payloadHash) 恒定派生同一 id——换
    /// orderId 无限重铸与 mempool 抢注受害单号在入口处关闭；重放同一事实
    /// 得到同 id，按 OrderAlreadyRegistered 幂等拒绝。
    function _createOutsideTriggerOrder(
        TriggerOrderFromOutsideRequest calldata trigger,
        SignalAuthorization[] calldata authorizations
    ) private {
        bytes32 orderId = triggerOrderIdFor(trigger.planId, trigger.sourceId, trigger.signalId, trigger.payloadHash);
        // The high-bit namespace is reserved for deterministic dock child
        // orders. A derived id colliding with it is a hash-collision-level
        // event; fail closed rather than let a dock child be front-run.
        if (_isDockOrderId(orderId)) {
            revert InvalidDockOrderNamespace(orderId);
        }

        _createOrder(trigger.planId, orderId, trigger.creator, msg.sender);
        _authorizeSignalSubmitters(trigger.planId, orderId, authorizations);
        emit OrderTriggered(
            orderId, trigger.planId, trigger.triggerStageId, trigger.sourceId, trigger.signalId, trigger.submitter
        );
        _recordSignal(
            trigger.planId,
            orderId,
            trigger.sourceId,
            trigger.signalId,
            trigger.payloadHash,
            trigger.idempotencyKey,
            trigger.submitter,
            false
        );
        _requireTriggerHookReady(trigger.planId, orderId, trigger.triggerHookId, trigger.triggerStageId);
    }

    /// @notice Outside 触发订单 id 的权威派生公式（一事一单）：
    ///         keccak256(abi.encode(planId, sourceId, signalId, payloadHash))。
    ///         消费方（BFF/indexer/bootstrap）必须镜像此公式预计算订单号。
    function triggerOrderIdFor(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 payloadHash)
        public
        pure
        returns (bytes32)
    {
        // dock 子单号恒置最高位（DOCK_ORDER_NAMESPACE_MASK），出生订单派生
        // id 恒清该位——两个命名空间结构性分离；确定性不受影响（同一事实
        // 恒定派生同一 id）。
        return bytes32(
            uint256(keccak256(abi.encode(planId, sourceId, signalId, payloadHash)))
                & ~uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function triggerOrderFromSignalFromModule(
        TriggerOrderFromSignalRequest calldata trigger,
        SignalAuthorization[] calldata authorizations,
        address relayer
    ) external {
        if (msg.sender != orderLinkModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (trigger.submitter == address(0)) {
            revert ZeroSubmitter();
        }

        // 审计 #10：trigger-origin 订单按 (originPlanId, triggerOriginOrderId)
        // 复合键寻址，跨 plan 链接必须显式声明 origin 的 plan。
        Order storage triggerOriginOrder = _orders[trigger.originPlanId][trigger.triggerOriginOrderId];
        if (!triggerOriginOrder.exists) {
            revert UnknownOrder();
        }
        if (!_hasSignal(
                trigger.originPlanId, trigger.triggerOriginOrderId, trigger.originSourceId, trigger.originSignalId
            )) {
            revert UnknownOrder();
        }
        // 审计 #1 残余：trigger link 建立需要 origin 侧同意。执行 relayer 或
        // EIP712 请求 submitter 必须在 origin 订单的同意集合内（创建者 /
        // origin 源阶段执行器 / origin 事实的授权提交者）。语义：能对 origin
        // 订单说出该事实的一方，才允许把它作为 trigger-origin 消费、在其上
        // 派生新订单。外部 plan 镜像公开 capability 声明不足以建立链接——
        // 这封死 capability 镜像攻击链（镜像 plan → 镜像 link → 回写注入）。
        if (
            !hasTriggerOriginConsent(
                    trigger.originPlanId,
                    trigger.triggerOriginOrderId,
                    trigger.originSourceId,
                    trigger.originSignalId,
                    trigger.submitter
                )
                && !hasTriggerOriginConsent(
                    trigger.originPlanId,
                    trigger.triggerOriginOrderId,
                    trigger.originSourceId,
                    trigger.originSignalId,
                    relayer
                )
        ) {
            revert UnauthorizedTriggerOrigin(trigger.originPlanId, trigger.triggerOriginOrderId, trigger.submitter);
        }
        _requireTriggerHookReadyForOrder(
            trigger.originPlanId,
            trigger.triggerOriginOrderId,
            trigger.planId,
            trigger.triggerHookId,
            trigger.triggerStageId
        );

        if (_isDockOrderId(trigger.orderId)) {
            revert InvalidDockOrderNamespace(trigger.orderId);
        }

        _createOrder(trigger.planId, trigger.orderId, trigger.creator, relayer);
        _authorizeSignalSubmitters(trigger.planId, trigger.orderId, authorizations);
        emit OrderTriggered(
            trigger.orderId,
            trigger.planId,
            trigger.triggerStageId,
            trigger.originSourceId,
            trigger.originSignalId,
            trigger.submitter
        );
        _markTriggerHookReady(
            trigger.planId,
            trigger.orderId,
            trigger.triggerHookId,
            trigger.triggerStageId,
            trigger.originSourceId,
            trigger.originSignalId
        );
    }

    function _createOrder(bytes32 planId, bytes32 orderId, address creator, address relayer) private {
        if (orderId == bytes32(0)) {
            revert ZeroOrderId();
        }
        if (creator == address(0)) {
            revert ZeroOrderCreator();
        }
        Plan storage plan = _plans[planId];
        if (!plan.finalized) {
            revert PlanNotFinalized();
        }
        Order storage order = _orders[planId][orderId];
        if (order.exists) {
            revert OrderAlreadyRegistered();
        }
        order.relayer = relayer;
        order.creator = creator;
        order.exists = true;

        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (_isOrderTrigger(hook.flags)) {
                _initializeHookRuntime(order, hook.hookId);
            }
        }

        emit OrderRegistered(orderId, planId);
        emit OrderRelayerRecorded(planId, orderId, relayer, creator);
    }

    function _authorizeSignalSubmitters(bytes32 planId, bytes32 orderId, SignalAuthorization[] calldata authorizations)
        private
    {
        for (uint256 i = 0; i < authorizations.length; i++) {
            _authorizeSignalSubmitter(planId, orderId, authorizations[i]);
        }
    }

    function _authorizeSignalSubmitter(bytes32 planId, bytes32 orderId, SignalAuthorization calldata authorization)
        private
    {
        if (authorization.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        if (authorization.submitter == address(0)) {
            revert ZeroSubmitter();
        }

        bytes32 key = _signalKey(authorization.sourceId, authorization.signalId);
        StoredSignalAuthorization storage stored = _signalAuthorizations[planId][orderId][key][authorization.submitter];
        if (stored.exists) {
            revert SignalSubmitterAlreadyAuthorized(
                orderId, authorization.sourceId, authorization.signalId, authorization.submitter
            );
        }

        stored.role = authorization.role;
        stored.metadataHash = authorization.metadataHash;
        stored.exists = true;

        emit SignalSubmitterAuthorized(
            planId,
            orderId,
            authorization.sourceId,
            authorization.signalId,
            authorization.submitter,
            authorization.role,
            authorization.metadataHash
        );
    }

    function submitSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey
    ) external {
        _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, msg.sender);
    }

    function submitSignalFor(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredSignalSignature(deadline);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }

        address recoveredSigner = _recoverSignalSubmitter(
            _signalSubmissionDigest(
                planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, deadline
            ),
            signature
        );
        if (recoveredSigner != submitter) {
            revert InvalidSignalSignature(submitter, recoveredSigner);
        }

        _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter);
    }

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
    ) external {
        if (msg.sender != stagePatchModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        Order storage order = _orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (!_isPlanStage(planId, targetStageId)) {
            revert UnknownHook();
        }
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][targetStageId];
        if (patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(orderId, targetStageId, activePatch.patchNonce, patchNonce);
        }

        activePatch.executor = executor;
        activePatch.role = role;
        activePatch.executorMetadataHash = executorMetadataHash;
        activePatch.patchHash = patchHash;
        activePatch.patchNonce = patchNonce;
        activePatch.metadataURI = metadataURI;
        activePatch.exists = true;

        emit StageExecutorActivated(
            planId, orderId, targetStageId, executor, role, executorMetadataHash, patchNonce, metadataURI
        );
    }

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
    ) external {
        if (msg.sender != stagePatchModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        Order storage order = _orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (!_isPlanStage(planId, targetStageId)) {
            revert UnknownHook();
        }

        bytes32 key = _signalKey(sourceId, signalId);
        DelegatedStageSignalAuthorization storage delegated = _delegatedStageSignalAuthorizations[planId][orderId][key];
        if (patchNonce <= delegated.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(orderId, targetStageId, delegated.patchNonce, patchNonce);
        }

        delegated.targetStageId = targetStageId;
        delegated.executor = executor;
        delegated.role = role;
        delegated.metadataHash = metadataHash;
        delegated.patchNonce = patchNonce;
        delegated.exists = true;

        emit SignalSubmitterAuthorized(planId, orderId, sourceId, signalId, executor, role, metadataHash);
        emit StageExecutorSignalDelegated(
            planId, orderId, targetStageId, sourceId, signalId, executor, role, metadataHash, patchNonce
        );
    }

    /// PRD95 §7.4：仅 docking module 可调用。创建独立 linkedOrderId 子订单、
    /// 授权子订单信号提交者、写入 entrance canonical fact（绕过源阶段
    /// materialization 检查——该事实正是出生事实），再把 entrance hook
    /// （ORDER_TRIGGER_DOCK）标记 Ready 并物化目标 stage。
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
    ) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (!_isDockOrderId(linkedOrderId)) {
            revert InvalidDockOrderNamespace(linkedOrderId);
        }
        _createOrder(targetPlanId, linkedOrderId, creator, relayer);
        _authorizeSignalSubmitters(targetPlanId, linkedOrderId, authorizations);
        _recordSignal(targetPlanId, linkedOrderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false);
        _markDockTriggerHookReady(targetPlanId, linkedOrderId, entranceHookId, entranceStageId, sourceId, signalId);
    }

    /// PRD95 §8：非 entrance 的 dock input 事实写入（kind: signal 端口）。
    /// 目标内部 hook 正常求值；模块不得直接把 hook 标为 Ready。
    function recordDockedInputFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false);
    }

    function planHookFlags(bytes32 planId, bytes32 hookId) external view returns (uint8) {
        StoredHook storage hook = _plans[planId].hooks[hookId];
        return hook.exists ? hook.flags : 0;
    }

    function planHookStageId(bytes32 planId, bytes32 hookId) external view returns (bytes32) {
        StoredHook storage hook = _plans[planId].hooks[hookId];
        return hook.stageId;
    }

    function planDockRoots(bytes32 planId) external view returns (bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot) {
        Plan storage plan = _plans[planId];
        return (plan.dockRoutesRoot, plan.dockInterfaceRoot);
    }

    function submitSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external {
        if (msg.sender != derivedSignalModule && msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, true);
    }

    /// Derived signals write a fact to a target/origin order while the
    /// capability's stage belongs to the originating path. Keep that stage
    /// explicit so an active executor patch on the target order cannot be
    /// bypassed by conflating the business source id with the stage id.
    function submitDerivedSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) external {
        if (msg.sender != derivedSignalModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }
        // 与普通 submitSignal 路径同口径（两维度独立）：显式 order 级授权
        // 豁免 active executor patch 检查——同一事实两条入口结论必须一致。
        if (!_hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter)) {
            _requireActiveStageExecutorByStage(planId, orderId, stageId, submitter);
        }
        // The target/origin order may not have materialized the source stage;
        // relation-1 capabilities intentionally write back to that order.
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false);
    }

    function _submitSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) private {
        if (signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        Order storage order = _orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        if (!_isSignalSubmitterAuthorized(planId, orderId, sourceId, signalId, submitter)) {
            revert UnauthorizedSignalSubmitter(orderId, sourceId, signalId, submitter);
        }
        _requireActiveStageExecutor(planId, orderId, sourceId, signalId, submitter);

        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, true);
    }

    function _recordSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        bool requireSourceStageMaterialized
    ) private {
        Order storage order = _orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (requireSourceStageMaterialized) {
            bytes32 sourceStageId = _signalStageId(planId, sourceId, signalId);
            // Preserve the legacy source==stage behavior for plans that do
            // not carry a metadata capability (e.g. trigger/manual plans).
            if (sourceStageId == bytes32(0) && _isPlanStage(planId, sourceId)) {
                sourceStageId = sourceId;
            }
            if (sourceStageId != bytes32(0) && !order.materializedStages[sourceStageId]) {
                revert UnknownHook();
            }
            if (sourceStageId != bytes32(0)) {
                _requireStageExecutorAssigned(planId, orderId, sourceStageId);
            }
        }
        bytes32 key = _signalKey(sourceId, signalId);
        SignalRecord storage signal = _signals[planId][orderId][key];
        if (signal.exists) {
            revert SignalAlreadyExists();
        }

        signal.sourceId = sourceId;
        signal.signalId = signalId;
        signal.payloadHash = payloadHash;
        signal.idempotencyKey = idempotencyKey;
        signal.submittedAt = uint64(block.timestamp);
        signal.submitter = submitter;
        signal.exists = true;
        sourceSignalCount[planId][orderId][sourceId] += 1;
        lastSignalSubmitter[planId][orderId][sourceId] = submitter;

        emit SignalSubmitted(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter);
        _evaluateAffectedHooks(planId, orderId, key, sourceId, signalId);
    }

    function pokeTimer(bytes32 planId, bytes32 orderId, bytes32 hookId) external {
        Order storage order = _orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            revert UnknownHook();
        }
        if (runtime.status != HookStatus.Wait) {
            revert TimerNotWaiting();
        }
        if (runtime.dueAt == 0 || block.timestamp < runtime.dueAt) {
            revert TimerNotDue();
        }

        uint64 dueAt = runtime.dueAt;
        emit TimerPoked(planId, orderId, hookId, dueAt);
        _evaluateHook(planId, orderId, hookId, bytes32(0), bytes32(0));
    }

    function planExists(bytes32 planId) external view returns (bool) {
        return _plans[planId].finalized;
    }

    function planCommitted(bytes32 planId) external view returns (bool) {
        return _plans[planId].committed;
    }

    function planFinalized(bytes32 planId) external view returns (bool) {
        return _plans[planId].finalized;
    }

    function planHash(bytes32 planId) external view returns (bytes32) {
        return _plans[planId].planHash;
    }

    function orderExists(bytes32 planId, bytes32 orderId) external view returns (bool) {
        return _orders[planId][orderId].exists;
    }

    function planPublisher(bytes32 planId) external view returns (address) {
        return _plans[planId].publisher;
    }

    function orderRelayer(bytes32 planId, bytes32 orderId) external view returns (address) {
        return _orders[planId][orderId].relayer;
    }

    function orderCreator(bytes32 planId, bytes32 orderId) external view returns (address) {
        return _orders[planId][orderId].creator;
    }

    function getHookStatus(bytes32 planId, bytes32 orderId, bytes32 hookId)
        external
        view
        returns (HookStatus status, uint64 dueAt, bool readyEmitted)
    {
        Order storage order = _orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            revert UnknownHook();
        }
        return (runtime.status, runtime.dueAt, runtime.readyEmitted);
    }

    function getSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter)
    {
        SignalRecord storage signal = _signals[planId][orderId][_signalKey(sourceId, signalId)];
        return (signal.exists, signal.payloadHash, signal.idempotencyKey, signal.submittedAt, signal.submitter);
    }

    function hasSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool)
    {
        return _hasSignal(planId, orderId, sourceId, signalId);
    }

    function hasSourceSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (bool) {
        return sourceSignalCount[planId][orderId][sourceId] != 0;
    }

    function isSignalSubmitterAuthorized(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool) {
        Order storage order = _orders[planId][orderId];
        if (!order.exists) {
            return false;
        }
        return _isSignalSubmitterAuthorized(planId, orderId, sourceId, signalId, submitter);
    }

    function hasExplicitSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool) {
        return _hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter);
    }

    function getSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool exists, bytes32 role, bytes32 metadataHash) {
        StoredSignalAuthorization storage authorization =
            _signalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)][submitter];
        if (authorization.exists) {
            return (true, authorization.role, authorization.metadataHash);
        }
        DelegatedStageSignalAuthorization storage delegated =
            _delegatedStageSignalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)];
        // 不存在即返回空值：委托授权的 executor 与查询 submitter 不匹配时，
        // 旧的 role/metadataHash 残留会让"用 role 判存在"的消费方误判。
        if (delegated.exists && delegated.executor == submitter) {
            return (true, delegated.role, delegated.metadataHash);
        }
        return (false, bytes32(0), bytes32(0));
    }

    function activeStageExecutor(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (address)
    {
        return _activeStageExecutorPatches[planId][orderId][targetStageId].executor;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _signalSubmissionDigest(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _SIGNAL_SUBMISSION_TYPEHASH,
                planId,
                orderId,
                sourceId,
                signalId,
                payloadHash,
                idempotencyKey,
                submitter,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _signalAuthorizationsHash(SignalAuthorization[] calldata authorizations) private pure returns (bytes32) {
        bytes32 rollingHash = keccak256(abi.encode(authorizations.length));
        for (uint256 i = 0; i < authorizations.length; i++) {
            SignalAuthorization calldata authorization = authorizations[i];
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    authorization.sourceId,
                    authorization.signalId,
                    authorization.submitter,
                    authorization.role,
                    authorization.metadataHash
                )
            );
        }
        return rollingHash;
    }

    function _triggerOrderFromOutsideDigest(TriggerOrderFromOutsideRequest calldata trigger, bytes32 authorizationsHash)
        private
        view
        returns (bytes32)
    {
        bytes memory encoded = new bytes(0x180);
        _writeWord(encoded, 0x00, _TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH);
        _writeWord(encoded, 0x20, trigger.planId);
        _writeAddress(encoded, 0x40, trigger.creator);
        _writeWord(encoded, 0x60, trigger.triggerHookId);
        _writeWord(encoded, 0x80, trigger.triggerStageId);
        _writeWord(encoded, 0xa0, trigger.sourceId);
        _writeWord(encoded, 0xc0, trigger.signalId);
        _writeWord(encoded, 0xe0, trigger.payloadHash);
        _writeWord(encoded, 0x100, trigger.idempotencyKey);
        _writeWord(encoded, 0x120, authorizationsHash);
        _writeAddress(encoded, 0x140, trigger.submitter);
        _writeWord(encoded, 0x160, bytes32(trigger.deadline));
        bytes32 structHash = keccak256(encoded);
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function _isOrderTrigger(uint8 flags) private pure returns (bool) {
        return flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK) != 0;
    }

    /// 阶段物化三线统一（簇 A）：order-trigger 与 EMIT_READY hook 都能物化
    /// 自身阶段；纯 flags=0 watcher 不能。
    function _hookCanMaterializeStage(uint8 flags) private pure returns (bool) {
        return _isOrderTrigger(flags) || flags & HOOK_FLAG_EMIT_READY != 0;
    }

    function _isDockOrderId(bytes32 orderId) private pure returns (bool) {
        return uint256(orderId) & uint256(DOCK_ORDER_NAMESPACE_MASK) != 0;
    }

    /// 审计 #1 残余：origin 侧同意判定。
    ///
    /// 同意集合（party 持有 origin 订单上的任一身份即算同意）：
    /// 1. origin 订单创建者——订单级权威；
    /// 2. origin 源阶段的 active stage executor——执行者 overlay 下唯一的
    ///    阶段发言方（覆盖 executor patch/handoff/replacement 流程）；
    /// 3. origin 事实 (originSourceId, originSignalId) 的授权提交者——
    ///    显式 signal authorization 或阶段执行者委托授权。
    ///
    /// 语义：能够对 origin 订单说出（或被 origin 订单授权说出）该事实的一
    /// 方，才允许把它作为 trigger-origin 消费、在任意 plan 上派生新订单。
    /// 外部 plan 镜像公开 capability 声明不构成同意，capability 镜像攻击链
    /// （镜像 plan → 镜像 link → 派生单回写注入）在 link 建立刻被拒绝。
    function hasTriggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party
    ) public view returns (bool) {
        if (party == address(0)) {
            return false;
        }
        Order storage originOrder = _orders[originPlanId][originOrderId];
        if (!originOrder.exists) {
            return false;
        }
        if (originOrder.creator == party) {
            return true;
        }
        // An active executor patch must not revoke an explicit order-level
        // authorization. Explicit grants are independent business
        // authorization and remain valid throughout executor handoffs.
        if (_hasExplicitSignalAuthorization(originPlanId, originOrderId, originSourceId, originSignalId, party)) {
            return true;
        }
        bytes32 originStageId = _signalStageId(originPlanId, originSourceId, originSignalId);
        if (originStageId == bytes32(0) && _isPlanStage(originPlanId, originSourceId)) {
            originStageId = originSourceId;
        }
        ActiveStageExecutorPatch storage activePatch =
            _activeStageExecutorPatches[originPlanId][originOrderId][originStageId];
        if (originStageId != bytes32(0) && activePatch.exists) {
            return activePatch.executor == party;
        }
        return _isSignalSubmitterAuthorized(originPlanId, originOrderId, originSourceId, originSignalId, party);
    }

    function _isPlanStage(bytes32 planId, bytes32 stageId) private view returns (bool) {
        if (stageId == bytes32(0)) {
            return false;
        }
        return _plans[planId].stageExists[stageId];
    }

    function _requireStageExecutorAssigned(bytes32 planId, bytes32 orderId, bytes32 targetStageId) private view {
        if (_activeStageExecutorPatches[planId][orderId][targetStageId].exists || planMetadataModule == address(0)) {
            return;
        }
        if (IUVPPlanMetadataModule(planMetadataModule).isSelectorTargetStage(planId, targetStageId)) {
            revert StageExecutorNotAssigned(orderId, targetStageId);
        }
    }

    function _planCommitDigest(PlanCommit calldata commit) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.metadataHash,
                commit.dockRoutesRoot,
                commit.dockInterfaceRoot,
                commit.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _registerPlanHook(
        Plan storage plan,
        CompactHook calldata input,
        bytes32[] memory seenKeys,
        bytes32[] memory seenStages,
        bool[] memory seenTriggerOnly,
        uint256 seenCount
    ) private returns (uint256) {
        _validateHook(input);
        // PRD94 §3.4：出生语义互斥——MINT 与 DOCK 不可同挂一个 hook。
        if (
            input.flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK)
                == (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK)
        ) {
            revert InvalidHook();
        }
        if (plan.hooks[input.hookId].exists) {
            revert HookAlreadyRegistered();
        }

        StoredHook storage hook = plan.hooks[input.hookId];
        hook.hookId = input.hookId;
        hook.stageId = input.stageId;
        hook.hookName = input.hookName;
        hook.flags = input.flags;
        hook.exists = true;

        for (uint256 j = 0; j < input.instructions.length; j++) {
            hook.instructions.push(input.instructions[j]);
        }

        uint256 updatedCount = seenCount;
        // 审计 #31：同一 hook 输入内的重复 dependencyKey 先去重。重复项会
        // 逐次推入 plan.dependencyIndex，此后该键每次信号提交都重复执行
        // _evaluateHook N 次，N 足够大即永久 OOG。
        uint256 inputKeyCount = 0;
        bytes32[] memory inputKeys = new bytes32[](input.dependencyKeys.length);
        for (uint256 j = 0; j < input.dependencyKeys.length; j++) {
            bytes32 dependencyKey = input.dependencyKeys[j];
            bool duplicatedInput = false;
            for (uint256 k = 0; k < inputKeyCount; k++) {
                if (inputKeys[k] == dependencyKey) {
                    duplicatedInput = true;
                    break;
                }
            }
            if (duplicatedInput) {
                continue;
            }
            inputKeys[inputKeyCount] = dependencyKey;
            inputKeyCount += 1;

            // Trigger watchers crossing stages are the normal selectedStages
            // flow: the evaluation guard skips triggers of unmaterialized
            // stages. The brick is a NON-trigger watcher in a stage that has
            // not materialized yet -- submitting the shared key would revert
            // that transaction forever.
            uint256 watcherIndex = _seenDependencyIndex(seenKeys, updatedCount, dependencyKey);
            if (watcherIndex == type(uint256).max) {
                if (updatedCount == seenKeys.length) {
                    revert TooManyDependencies();
                }
                seenKeys[updatedCount] = dependencyKey;
                seenStages[updatedCount] = input.stageId;
                seenTriggerOnly[updatedCount] = _isOrderTrigger(input.flags);
                updatedCount += 1;
            } else {
                bool triggerOnly = seenTriggerOnly[watcherIndex] && _isOrderTrigger(input.flags);
                if (seenStages[watcherIndex] != input.stageId && !triggerOnly) {
                    revert CrossStageDependency(dependencyKey);
                }
                seenTriggerOnly[watcherIndex] = triggerOnly;
            }

            hook.dependencyKeys.push(dependencyKey);
            plan.dependencyIndex[dependencyKey].push(input.hookId);
        }

        plan.hookIds.push(input.hookId);
        plan.stageExists[input.stageId] = true;
        return updatedCount;
    }

    function _seenDependencyIndex(bytes32[] memory seenKeys, uint256 seenCount, bytes32 dependencyKey)
        private
        pure
        returns (uint256)
    {
        for (uint256 k = 0; k < seenCount; k++) {
            if (seenKeys[k] == dependencyKey) {
                return k;
            }
        }
        return type(uint256).max;
    }

    function _validateHook(CompactHook calldata hook) private pure {
        if (
            hook.hookId == bytes32(0) || hook.stageId == bytes32(0) || hook.hookName == bytes32(0)
                || hook.instructions.length == 0 || hook.dependencyKeys.length == 0
        ) {
            revert InvalidHook();
        }

        uint256 stackDepth;
        for (uint256 i = 0; i < hook.instructions.length; i++) {
            Instruction calldata instruction = hook.instructions[i];
            if (instruction.op == InstructionOp.Signal) {
                if (instruction.signalId == bytes32(0)) {
                    revert InvalidInstruction();
                }
                stackDepth += 1;
            } else if (instruction.op == InstructionOp.Not || instruction.op == InstructionOp.Delay) {
                if (stackDepth == 0) {
                    revert InvalidInstruction();
                }
                if (instruction.op == InstructionOp.Delay && instruction.delaySeconds == 0) {
                    revert InvalidInstruction();
                }
                if (instruction.op == InstructionOp.Delay && instruction.delaySeconds > MAX_HOOK_DELAY_SECONDS) {
                    revert HookDelayTooLong(instruction.delaySeconds);
                }
            } else if (instruction.op == InstructionOp.And || instruction.op == InstructionOp.Or) {
                if (instruction.arity < 2 || stackDepth < instruction.arity) {
                    revert InvalidInstruction();
                }
                stackDepth = stackDepth - instruction.arity + 1;
            } else if (instruction.op == InstructionOp.Merge) {
                // 撮合扇入（semantic 0.6）：表达式形态下限 k≥2；k=1 的跨订单
                // 观察入口是 cloud 运行时投递形态，链上无对应物，编码层拒绝。
                if (instruction.arity < 2 || stackDepth < instruction.arity) {
                    revert InvalidInstruction();
                }
                stackDepth = stackDepth - instruction.arity + 1;
            } else {
                revert InvalidInstruction();
            }
        }
        if (stackDepth != 1) {
            revert InvalidInstruction();
        }
    }

    function _evaluateAffectedHooks(
        bytes32 planId,
        bytes32 orderId,
        bytes32 dependencyKey,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Plan storage plan = _plans[planId];
        Order storage order = _orders[planId][orderId];
        bytes32[] storage hookIds = plan.dependencyIndex[dependencyKey];
        for (uint256 i = 0; i < hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[hookIds[i]];
            if (_isOrderTrigger(hook.flags)) {
                _evaluateHook(planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
            }
        }
        for (uint256 i = 0; i < hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[hookIds[i]];
            if (!_isOrderTrigger(hook.flags)) {
                // 模块写事实路径不再 brick（簇 A3）：纯 flags=0 watcher 且其
                // 阶段未物化时跳过而不是 revert——与回放 oracle 的 skip 语义
                // 对齐。该形态正常不可达（编译器拒绝不可物化阶段挂
                // receive hook），本分支是防御纵深；EMIT_READY hook 仍照常
                // 求值（executor dispatch 边允许先于阶段物化初始化）。
                if (hook.flags & HOOK_FLAG_EMIT_READY == 0 && !order.materializedStages[hook.stageId]) {
                    continue;
                }
                _evaluateHook(planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
            }
        }
    }

    function _requireTriggerHookReady(bytes32 planId, bytes32 orderId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
    {
        _validatedTriggerHook(planId, triggerHookId, triggerStageId);

        HookRuntime storage runtime = _orders[planId][orderId].hookRuntimes[triggerHookId];
        if (!runtime.exists || runtime.status != HookStatus.Ready || !runtime.readyEmitted) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _requireTriggerHookReadyForOrder(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId
    ) private view {
        // 语义保持不变：用新单 plan 的 trigger hook 定义，评估 origin 订单的
        // 信号状态（origin 事实在 origin 订单的作用域内可见）。
        StoredHook storage hook = _validatedTriggerHook(planId, triggerHookId, triggerStageId);
        EvalValue memory result = _evaluateInstructions(originPlanId, originOrderId, hook);
        if (!result.value || result.wait || result.cancel) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _markTriggerHookReady(
        bytes32 planId,
        bytes32 orderId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        StoredHook storage hook = _validatedTriggerHook(planId, triggerHookId, triggerStageId);
        _markOrderTriggerHookReady(
            planId, orderId, hook, triggerHookId, triggerStageId, triggerSourceId, triggerSignalId
        );
    }

    function _markDockTriggerHookReady(
        bytes32 planId,
        bytes32 orderId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        StoredHook storage hook = _validatedDockTriggerHook(planId, triggerHookId, triggerStageId);
        _markOrderTriggerHookReady(
            planId, orderId, hook, triggerHookId, triggerStageId, triggerSourceId, triggerSignalId
        );
    }

    function _markOrderTriggerHookReady(
        bytes32 planId,
        bytes32 orderId,
        StoredHook storage hook,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Order storage order = _orders[planId][orderId];
        HookRuntime storage runtime = order.hookRuntimes[triggerHookId];
        if (!runtime.exists) {
            _initializeHookRuntime(order, triggerHookId);
        }

        HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        runtime.status = HookStatus.Ready;
        runtime.dueAt = 0;

        if (previousStatus != HookStatus.Ready || previousDueAt != 0) {
            emit HookStatusChanged(planId, orderId, triggerHookId, previousStatus, HookStatus.Ready, 0);
        }

        if (!runtime.readyEmitted) {
            runtime.readyEmitted = true;
            _materializeStage(planId, orderId, triggerStageId, triggerHookId, triggerSourceId, triggerSignalId);
            emit HookReady(planId, orderId, triggerHookId, hook.stageId, hook.hookName);
        }
    }

    function _validatedTriggerHook(bytes32 planId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
        returns (StoredHook storage hook)
    {
        // mint 出生路径（triggerOrderFromOutsideFor / order-link）只接受
        // MINT 触发器；DOCK 出生必须走 openDockedOrder 的 proof 链。
        hook = _validatedOrderTriggerHook(planId, triggerHookId, triggerStageId, HOOK_FLAG_ORDER_TRIGGER_MINT);
    }

    function _validatedDockTriggerHook(bytes32 planId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
        returns (StoredHook storage hook)
    {
        hook = _validatedOrderTriggerHook(planId, triggerHookId, triggerStageId, HOOK_FLAG_ORDER_TRIGGER_DOCK);
    }

    function _validatedOrderTriggerHook(
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        uint8 requiredFlag
    ) private view returns (StoredHook storage hook) {
        Plan storage plan = _plans[planId];
        if (!plan.finalized) {
            revert UnknownPlan();
        }

        hook = plan.hooks[triggerHookId];
        if (!hook.exists || hook.flags & requiredFlag == 0 || hook.stageId != triggerStageId) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _evaluateHook(
        bytes32 planId,
        bytes32 orderId,
        bytes32 hookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Plan storage plan = _plans[planId];
        StoredHook storage hook = plan.hooks[hookId];
        if (!hook.exists) {
            revert UnknownHook();
        }

        Order storage order = _orders[planId][orderId];
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            // 出生 hook（mint/dock）在任何时刻可初始化；EMIT_READY hook 是
            // executor dispatch 边（PRD94 §3.4），其 runtime 允许先于阶段
            // materialization 初始化——Ready 时会物化自身阶段。
            if (
                !_isOrderTrigger(hook.flags) && hook.flags & HOOK_FLAG_EMIT_READY == 0
                    && !order.materializedStages[hook.stageId]
            ) {
                revert UnknownHook();
            }
            _initializeHookRuntime(order, hookId);
        }
        if (runtime.status == HookStatus.Cancelled || runtime.status == HookStatus.Ready) {
            return;
        }

        HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        EvalValue memory result = _evaluateInstructions(planId, orderId, hook);
        HookStatus nextStatus = HookStatus.Init;
        uint64 nextDueAt;
        if (result.cancel) {
            nextStatus = HookStatus.Cancelled;
        } else if (result.wait) {
            nextStatus = HookStatus.Wait;
            nextDueAt = result.dueAt;
        } else if (result.value) {
            nextStatus = HookStatus.Ready;
        }

        runtime.status = nextStatus;
        runtime.dueAt = nextDueAt;

        if (previousStatus != nextStatus || previousDueAt != nextDueAt) {
            emit HookStatusChanged(planId, orderId, hookId, previousStatus, nextStatus, nextDueAt);
        }

        if (nextStatus == HookStatus.Ready && !runtime.readyEmitted) {
            if (_isOrderTrigger(hook.flags)) {
                runtime.readyEmitted = true;
                _materializeStage(planId, orderId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
                emit HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
            } else if (hook.flags & HOOK_FLAG_EMIT_READY != 0) {
                // EMIT_READY 只决定"发可消费事件"，不授予订单创建能力；
                // 阶段物化仍发生（executor 激活面），出生 API 依旧检查
                // order-trigger flag。
                runtime.readyEmitted = true;
                _materializeStage(planId, orderId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
                emit HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
            }
        }
    }

    function _initializeHookRuntime(Order storage order, bytes32 hookId) private {
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (runtime.exists) {
            return;
        }
        runtime.status = HookStatus.Init;
        runtime.dueAt = 0;
        runtime.readyEmitted = false;
        runtime.exists = true;
    }

    function _materializeStage(
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId,
        bytes32 triggerHookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Order storage order = _orders[planId][orderId];
        if (!order.materialized) {
            order.materialized = true;
            emit OrderMaterialized(orderId, planId, stageId);
        }
        if (order.materializedStages[stageId]) {
            return;
        }
        order.materializedStages[stageId] = true;

        Plan storage plan = _plans[planId];
        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (hook.stageId == stageId) {
                _initializeHookRuntime(order, hook.hookId);
            }
        }

        emit StageMaterialized(planId, orderId, stageId, triggerHookId, triggerSourceId, triggerSignalId);
    }

    function _evaluateInstructions(bytes32 planId, bytes32 orderId, StoredHook storage hook)
        private
        view
        returns (EvalValue memory)
    {
        EvalValue[] memory stack = new EvalValue[](hook.instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < hook.instructions.length; i++) {
            Instruction storage instruction = hook.instructions[i];
            if (instruction.op == InstructionOp.Signal) {
                stack[stackDepth++] = _signalValue(planId, orderId, instruction.sourceId, instruction.signalId);
            } else if (instruction.op == InstructionOp.Not) {
                stack[stackDepth - 1] = _notValue(stack[stackDepth - 1]);
            } else if (instruction.op == InstructionOp.Delay) {
                stack[stackDepth - 1] = _delayValue(stack[stackDepth - 1], instruction.delaySeconds);
            } else if (instruction.op == InstructionOp.And) {
                EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _andValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else if (instruction.op == InstructionOp.Or) {
                EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _orValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else if (instruction.op == InstructionOp.Merge) {
                EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _mergeValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            }
        }
        return stack[0];
    }

    function _signalValue(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (EvalValue memory)
    {
        SignalRecord storage signal = _signals[planId][orderId][_signalKey(sourceId, signalId)];
        if (!signal.exists) {
            return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: signal.submittedAt});
    }

    function _notValue(EvalValue memory value) private pure returns (EvalValue memory) {
        if (value.value || value.wait) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        if (value.cancel) {
            return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _delayValue(EvalValue memory value, uint64 delaySeconds) private view returns (EvalValue memory) {
        if (value.cancel || !value.value) {
            return value;
        }
        uint64 dueAt = value.anchorAt + delaySeconds;
        if (block.timestamp < dueAt) {
            return EvalValue({value: false, wait: true, cancel: false, dueAt: dueAt, anchorAt: value.anchorAt});
        }
        // Anchor advancement (semantic 0.5 chained-delay ruling): the maturity
        // moment becomes the new anchor so `(A + 1s) + 5s` counts the outer
        // delay from A+1s, matching the core evaluator and replay oracle.
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: dueAt});
    }

    function _andValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        if (left.cancel || right.cancel) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        if (left.value && right.value) {
            return EvalValue({
                value: true, wait: false, cancel: false, dueAt: 0, anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if ((left.wait && (right.value || right.wait)) || (right.wait && (left.value || left.wait))) {
            return EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: _maxDue(left.dueAt, right.dueAt),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    /// 撮合扇入（semantic 0.6，规格 I1/I2）：任一路贡献信号在场即就绪，锚点取
    /// 在场分支中最早到达（先到因果）。无等待/取消分支——编码层约束操作数必须是
    /// 裸 SIGNAL 引用，永不为 wait；逐事件投递语义下首个到达即交付。
    function _mergeValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        if (left.value && right.value) {
            return EvalValue({
                value: true, wait: false, cancel: false, dueAt: 0, anchorAt: _minAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if (left.value) {
            return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: left.anchorAt});
        }
        if (right.value) {
            return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: right.anchorAt});
        }
        return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _orValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        // Arrival-time causality (semantic 0.5): merge keeps the EARLIEST
        // received signal as the cause so trailing delays anchor on first
        // arrival, matching the core evaluator and replay oracle.
        if (left.value || right.value) {
            // Only READY branches compete for the anchor; a waiting branch's
            // stale anchor must not win (matches the core evaluator).
            uint64 anchor = left.value && right.value
                ? _minAnchor(left.anchorAt, right.anchorAt)
                : left.value ? left.anchorAt : right.anchorAt;
            return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: anchor});
        }
        if (left.wait || right.wait) {
            return EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: _minDue(left.dueAt, right.dueAt),
                anchorAt: _minAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if (left.cancel && right.cancel) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _hasSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (bool)
    {
        return _signals[planId][orderId][_signalKey(sourceId, signalId)].exists;
    }

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _isSignalSubmitterAuthorized(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) private view returns (bool) {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        if (_hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter)) {
            return true;
        }
        DelegatedStageSignalAuthorization storage delegated =
            _delegatedStageSignalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)];
        if (delegated.exists) {
            return delegated.executor == submitter;
        }
        return false;
    }

    function _hasExplicitSignalAuthorization(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) private view returns (bool) {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        return _signalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)][submitter].exists;
    }

    function _requireActiveStageExecutor(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) private view {
        // Explicit order-level authorization is deliberately independent from
        // executor delegation. An active patch only supersedes the implicit
        // stage-executor submitter path.
        if (_hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter)) {
            return;
        }
        bytes32 stageId = _signalStageId(planId, sourceId, signalId);
        if (stageId == bytes32(0) && _isPlanStage(planId, sourceId)) {
            stageId = sourceId;
        }
        if (stageId == bytes32(0)) {
            return;
        }
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][stageId];
        if (activePatch.exists && submitter != activePatch.executor) {
            revert UnauthorizedStageExecutor(orderId, stageId, submitter, activePatch.executor);
        }
    }

    function _requireActiveStageExecutorByStage(bytes32 planId, bytes32 orderId, bytes32 stageId, address submitter)
        private
        view
    {
        if (stageId == bytes32(0)) {
            return;
        }
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][stageId];
        if (activePatch.exists && submitter != activePatch.executor) {
            revert UnauthorizedStageExecutor(orderId, stageId, submitter, activePatch.executor);
        }
    }

    /// Resolve the stage that owns a production signal. Compiler artifacts use
    /// a stage identifier (hash of the stage path) separately from the source
    /// identifier (hash of the business source/class); treating sourceId as a
    /// stage key makes materialization and executor patches silently bypass
    /// their intended gate. Only a current-order capability (relation 0)
    /// owns a stage in the order being written. Trigger-origin capabilities
    /// (relation 1) are deliberately resolved by the derived-signal module and
    /// must not make the target origin order pass a stage-materialization gate.
    function _signalStageId(bytes32 planId, bytes32 sourceId, bytes32 signalId) private view returns (bytes32 stageId) {
        if (planMetadataModule == address(0) || sourceId == bytes32(0) || signalId == bytes32(0)) {
            return bytes32(0);
        }
        IUVPPlanMetadataModule metadata = IUVPPlanMetadataModule(planMetadataModule);
        uint256 capabilityCount = metadata.planSignalCapabilityCount(planId);
        for (uint256 i = 0; i < capabilityCount; i++) {
            (bytes32 candidateStageId, bytes32 candidateSourceId, bytes32 candidateSignalId, uint8 relation) =
                metadata.planSignalCapabilityAt(planId, i);
            if (candidateSourceId != sourceId || candidateSignalId != signalId) {
                continue;
            }
            if (relation == SIGNAL_TARGET_CURRENT_ORDER) {
                return candidateStageId;
            }
        }
        return bytes32(0);
    }

    /// Number of signal capabilities the plan declares. Zero means a manual /
    /// trigger-only plan without compiled metadata capabilities; such plans
    /// keep the legacy permissive vocabulary (no semantic gate).
    function _planSignalCapabilityCount(bytes32 planId) private view returns (uint256) {
        if (planMetadataModule == address(0)) {
            return 0;
        }
        return IUVPPlanMetadataModule(planMetadataModule).planSignalCapabilityCount(planId);
    }

    function _recoverSignalSubmitter(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidSignalSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }

    function _minDue(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }

    function _maxDue(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function _maxAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function _minAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }
}
