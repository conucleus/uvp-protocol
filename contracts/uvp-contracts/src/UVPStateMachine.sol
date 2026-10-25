// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {UVPPlanRegistration} from "./UVPPlanRegistration.sol";
import {
    _HOOK_FLAG_ORDER_TRIGGER_MINT,
    _HOOK_FLAG_ORDER_TRIGGER_DOCK,
    _HOOK_FLAG_EMIT_READY,
    _HOOK_FLAG_ADMISSION,
    _MAX_HOOK_DELAY_SECONDS,
    _MAX_PLAN_DEPENDENCIES,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN
} from "./UVPStateMachineConstants.sol";

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
        Delay
    }

    struct Instruction {
        uint8 op;
        bytes32 sourceId;
        bytes32 signalId;
        uint16 arity;
        uint64 delaySeconds;
    }

    struct CompactHook {
        bytes32 hookId;
        bytes32 stageId;
        bytes32 hookName;
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

    struct ForkBirthFact {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
    }

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

    struct StageSignalAccount {
        uint256 count;
        address lastSubmitter;
        uint64 lastAt;
        bool ambiguous;
    }

    struct PlanCommit {
        address publisher;
        bytes32 hooksHash;
        bytes32 capabilitiesRoot;
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
        bytes32 executorCandidatesRoot;
        address birthAuthorizer;
        uint256 deadline;
    }

    struct ExecutorCandidate {
        bytes32 stageId;
        address executor;
    }

    struct StoredSignalAuthorization {
        bytes32 role;
        bytes32 metadataHash;
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

    struct StoredAdmission {
        Instruction[] instructions;
        bool exists;
    }

    struct Plan {
        bytes32 planHash;
        bytes32 hooksHash;
        bytes32 capabilitiesRoot;
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
        bytes32 executorCandidatesRoot;
        address publisher;
        address birthAuthorizer;
        bytes32[] hookIds;
        mapping(bytes32 hookId => StoredHook hook) hooks;
        mapping(bytes32 signalKey => bytes32[] hookIds) dependencyIndex;
        mapping(bytes32 signalKey => StoredAdmission admission) admissions;
        mapping(bytes32 stageId => bool exists) stageExists;
        mapping(bytes32 stageId => bool covered) executorCandidateStages;
        bool committed;
        bool finalized;
        bool admissionsDeclared;
    }

    struct Order {
        address relayer;
        address creator;
        bytes32 parentOrderId;
        mapping(bytes32 hookId => HookRuntime runtime) hookRuntimes;
        mapping(bytes32 stageId => bool materialized) materializedStages;
        bool materialized;
        bool exists;
        bool admissionsDeclared;
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
    error DuplicateBirthChannelKey(bytes32 signalKey);
    error HookDependencyKeyMismatch(bytes32 hookId);
    error TooManyDependencies();
    error TooManyHooksPerDependencyKey(bytes32 signalKey);
    error InvalidSignalSignature(address expectedSigner, address recoveredSigner);
    error InvalidSignalSignatureLength(uint256 length);
    error InvalidSignalCapability(bytes32 planId, bytes32 sourceId, bytes32 signalId);
    error InvalidFactAttribution(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 claimedStageId);
    error InvalidInstruction();
    error InvalidHook();
    error InvalidModuleAddress();
    error InvalidDockOrderNamespace(bytes32 orderId);
    error InvalidPlanSignature(address expectedSigner, address recoveredSigner);
    error IncompleteModuleConfiguration();
    error InvalidTriggerHook(bytes32 hookId);
    error InvalidOrderLinkOrderId(bytes32 declared, bytes32 derived);
    error InvalidTriggerOrderSignature(address expectedSigner, address recoveredSigner);
    error ModulesAlreadyFrozen();
    error ModulesFrozen();
    error ModulesNotFrozen();
    error NotOwner();
    error OrderAlreadyRegistered();
    error PlanAlreadyRegistered();
    error PlanAlreadyFinalized();
    error HooksHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error ExecutorCandidatesRootMismatch(bytes32 expectedRoot, bytes32 actualRoot);
    error PlanNotCommitted();
    error PlanNotFinalized();
    error SignalAlreadyExists();
    error SignalAdmissionRejected(bytes32 orderId, bytes32 sourceId, bytes32 signalId);
    error AdmissionAlreadyRegistered(bytes32 signalKey);
    error SignalSubmitterAlreadyAuthorized(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error SilentOrderTriggerHook(bytes32 hookId);
    error StageExecutorNotAssigned(bytes32 orderId, bytes32 targetStageId);
    error StageNotMaterializable(bytes32 stageId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error TimerNotDue();
    error TimerNotWaiting();
    error UnauthorizedTriggerOrigin(bytes32 originPlanId, bytes32 originOrderId, address submitter);
    error UnauthorizedSignalSubmitter(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error UnauthorizedStateMachineModule(address caller);
    error UnauthorizedStageExecutor(bytes32 orderId, bytes32 targetStageId, address submitter, address executor);
    error UnknownHook();
    error UnknownOrder();
    error UnknownPlan();
    error ForkApprovalSignalUnknown(
        bytes32 planId, bytes32 parentOrderId, bytes32 approvalSourceId, bytes32 approvalSignalId
    );
    error UnauthorizedOrderFork(bytes32 planId, bytes32 parentOrderId, address initiator);
    error InvalidForkBirthFact(bytes32 parentOrderId, bytes32 sourceId, bytes32 signalId);
    error TooManyForkBirthFacts(uint256 count);
    error ZeroOrderCreator();
    error ZeroOrderId();
    error ZeroPatchHash();
    error ZeroOwner();
    error ZeroPlanPublisher();
    error ZeroSignalId();
    error ZeroSourceId();
    error UnauthorizedBirthSubmitter(address submitter);
    error ZeroStageExecutor();
    error ZeroSubmitter();
    error ZeroTargetStageId();

    address public owner;
    address public stagePatchModule;
    address public derivedSignalModule;
    address public dockingModule;

    function planMetadataModule() external view returns (address) {
        return _s.planMetadataModule;
    }

    address public orderLinkModule;
    address public lens;
    bool public modulesFrozen;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_MINT = _HOOK_FLAG_ORDER_TRIGGER_MINT;
    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_DOCK = _HOOK_FLAG_ORDER_TRIGGER_DOCK;
    uint8 public constant HOOK_FLAG_EMIT_READY = _HOOK_FLAG_EMIT_READY;
    uint8 public constant HOOK_FLAG_ADMISSION = _HOOK_FLAG_ADMISSION;
    uint64 public constant MAX_HOOK_DELAY_SECONDS = _MAX_HOOK_DELAY_SECONDS;
    uint256 public constant MAX_PLAN_DEPENDENCIES = _MAX_PLAN_DEPENDENCIES;
    uint256 public constant MAX_FORK_BIRTH_FACTS = 256;

    bytes32 private constant _FORK_ORDER_ID_DOMAIN = keccak256("uvp.fork.order_id.v1");

    bytes32 private constant _ORDER_LINK_ORDER_ID_DOMAIN = keccak256("uvp.order_link.order_id.v1");
    bytes32 public constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant _SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant _TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    struct SMState {
        mapping(bytes32 => Plan) plans;
        mapping(bytes32 => mapping(bytes32 => Order)) orders;
        mapping(bytes32 => mapping(bytes32 => mapping(bytes32 => SignalRecord))) signals;
        mapping(
            bytes32 planId
                => mapping(
                bytes32 orderId
                    => mapping(
                    bytes32 signalKey => mapping(address submitter => StoredSignalAuthorization authorization)
                )
            )
        ) signalAuthorizations;
        mapping(
            bytes32 planId
                => mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch))
        ) activeStageExecutorPatches;
        mapping(
            bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 sourceId => SourceSignalAccount account))
        ) sourceSignalAccounts;
        mapping(
            bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 stageId => StageSignalAccount account))
        ) stageSignalAccounts;
        address planMetadataModule;
    }

    SMState private _s;

    struct SourceSignalAccount {
        uint256 count;
        address lastSubmitter;
    }

    function sourceSignalCount(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (uint256) {
        return _s.sourceSignalAccounts[planId][orderId][sourceId].count;
    }

    function lastSignalSubmitter(bytes32 planId, bytes32 orderId, bytes32 sourceId) external view returns (address) {
        return _s.sourceSignalAccounts[planId][orderId][sourceId].lastSubmitter;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StateMachineModuleSet(bytes32 indexed moduleId, address indexed previousModule, address indexed newModule);
    event StateMachineModulesFrozen(bytes32 indexed moduleSetHash);
    event PlanCommitted(
        bytes32 indexed planId,
        bytes32 indexed planHash,
        address indexed publisher,
        bytes32 hooksHash,
        bytes32 capabilitiesRoot,
        uint256 hookCount,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot,
        bytes32 executorCandidatesRoot,
        address birthAuthorizer
    );
    event PlanFinalized(bytes32 indexed planId, bytes32 indexed planHash, bytes32 capabilitiesRoot);
    event PlanRegistered(bytes32 indexed planId, bytes32 planHash, uint256 hookCount);
    event PlanPublisherRecorded(bytes32 indexed planId, address indexed publisher);
    event OrderRegistered(bytes32 indexed orderId, bytes32 indexed planId);
    event OrderMaterialized(bytes32 indexed orderId, bytes32 indexed planId, bytes32 indexed stageId);
    event OrderRelayerRecorded(bytes32 indexed planId, bytes32 orderId, address indexed relayer, address creator);
    event SignalSubmitterAuthorized(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        address submitter,
        bytes32 role,
        bytes32 metadataHash
    );
    event SignalSubmitted(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        bytes32 factStageId
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
        bytes32 triggerHookId,
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
    event OrderForked(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed parentOrderId,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        address initiator,
        bytes32 forkPayloadHash,
        bytes32[] replayedFactKeys
    );

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
        _s.planMetadataModule = _setModule(PLAN_METADATA_MODULE_ID, _s.planMetadataModule, moduleAddress);
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
                || _s.planMetadataModule == address(0) || orderLinkModule == address(0) || lens == address(0)
        ) {
            revert IncompleteModuleConfiguration();
        }

        modulesFrozen = true;
        emit StateMachineModulesFrozen(moduleSetHash());
    }

    function moduleSetHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                stagePatchModule, derivedSignalModule, dockingModule, _s.planMetadataModule, orderLinkModule, lens
            )
        );
    }

    function _setModule(bytes32 moduleId, address previousModule, address moduleAddress) private returns (address) {
        if (modulesFrozen) {
            revert ModulesFrozen();
        }
        if (moduleAddress == address(0) || moduleAddress == address(this)) {
            revert InvalidModuleAddress();
        }
        if (moduleAddress.code.length == 0) {
            revert InvalidModuleAddress();
        }
        emit StateMachineModuleSet(moduleId, previousModule, moduleAddress);
        return moduleAddress;
    }

    function commitPlan(
        PlanCommit calldata commit,
        CompactHook[] calldata hooks,
        ExecutorCandidate[] calldata executorCandidates,
        bytes calldata signature
    ) external returns (bytes32 planId) {
        planId = UVPPlanRegistration.commitPlan(_s.plans, modulesFrozen, commit, hooks, executorCandidates, signature);
    }

    function finalizePlan(bytes32 planId) external {
        UVPPlanRegistration.finalizePlan(_s.plans, _s.planMetadataModule, planId);
    }

    function planRuntimeHash(
        bytes32 hooksHash,
        bytes32 capabilitiesRoot,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot,
        bytes32 executorCandidatesRoot
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _PLAN_RUNTIME_HASH_DOMAIN,
                hooksHash,
                capabilitiesRoot,
                dockRoutesRoot,
                dockInterfaceRoot,
                executorCandidatesRoot
            )
        );
    }

    function planIdFor(address publisher, bytes32 runtimePlanHash) public pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_ID_HASH_DOMAIN, publisher, runtimePlanHash));
    }

    function triggerOrderFromOutsideFor(
        TriggerOrderFromOutsideRequest calldata trigger,
        SignalAuthorization[] calldata authorizations,
        bytes calldata signature,
        FactAttribution calldata birthFactAttribution
    ) external {
        UVPPlanRegistration.triggerOrderFromOutside(_s, trigger, authorizations, signature, birthFactAttribution);
    }

    /// @notice Outside 触发订单 id 的权威派生公式（一事一单）：
    ///         keccak256(abi.encode(planId, sourceId, signalId, payloadHash))。
    ///         消费方（BFF/indexer/bootstrap）必须镜像此公式预计算订单号。
    function triggerOrderIdFor(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 payloadHash)
        public
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(keccak256(abi.encode(planId, sourceId, signalId, payloadHash)))
                & ~uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function orderLinkOrderIdFor(
        bytes32 planId,
        bytes32 originPlanId,
        bytes32 triggerOriginOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        bytes32 payloadHash
    ) public pure returns (bytes32) {
        return bytes32(
            uint256(
                keccak256(
                    abi.encode(
                        _ORDER_LINK_ORDER_ID_DOMAIN,
                        planId,
                        originPlanId,
                        triggerOriginOrderId,
                        originSourceId,
                        originSignalId,
                        payloadHash
                    )
                )
            ) & ~uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function forkOrderIdFor(bytes32 planId, bytes32 parentOrderId, bytes32 forkPayloadHash)
        public
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(keccak256(abi.encode(_FORK_ORDER_ID_DOMAIN, planId, parentOrderId, forkPayloadHash)))
                & ~uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function forkOrder(
        bytes32 planId,
        bytes32 parentOrderId,
        bytes32 forkPayloadHash,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        ForkBirthFact[] calldata birthFacts,
        SignalAuthorization[] calldata authorizations
    ) external returns (bytes32 forkedOrderId) {
        forkedOrderId = UVPPlanRegistration.forkOrderGate(
            _s, planId, parentOrderId, forkPayloadHash, approvalSourceId, approvalSignalId, birthFacts, authorizations
        );
        UVPPlanRegistration.forkOrderReplay(_s, planId, parentOrderId, forkedOrderId, birthFacts);
    }

    function triggerOrderFromSignalFromModule(
        TriggerOrderFromSignalRequest calldata trigger,
        SignalAuthorization[] calldata authorizations,
        address relayer,
        FactAttribution[] calldata originFactAttributions
    ) external {
        if (msg.sender != orderLinkModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        UVPPlanRegistration.triggerOrderFromSignal(_s, trigger, authorizations, relayer, originFactAttributions);
    }

    function _createOrder(bytes32 planId, bytes32 orderId, address creator, address relayer) private {
        if (orderId == bytes32(0)) {
            revert ZeroOrderId();
        }
        if (creator == address(0)) {
            revert ZeroOrderCreator();
        }
        Plan storage plan = _s.plans[planId];
        if (!plan.finalized) {
            revert PlanNotFinalized();
        }
        Order storage order = _s.orders[planId][orderId];
        if (order.exists) {
            revert OrderAlreadyRegistered();
        }
        order.relayer = relayer;
        order.creator = creator;
        order.exists = true;
        order.admissionsDeclared = plan.admissionsDeclared;

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
        if (authorization.sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (authorization.submitter == address(0)) {
            revert ZeroSubmitter();
        }

        bytes32 key = _signalKey(authorization.sourceId, authorization.signalId);
        StoredSignalAuthorization storage stored =
            _s.signalAuthorizations[planId][orderId][key][authorization.submitter];
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
        bytes32 idempotencyKey,
        FactAttribution calldata attribution
    ) external {
        _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, msg.sender, attribution);
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
        bytes calldata signature,
        FactAttribution calldata attribution
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

        _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, attribution);
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
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (!_isPlanStage(planId, targetStageId)) {
            revert UnknownHook();
        }
        ActiveStageExecutorPatch storage activePatch = _s.activeStageExecutorPatches[planId][orderId][targetStageId];
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

    function authorizeSignalSubmittersFromModule(
        bytes32 planId,
        bytes32 orderId,
        SignalAuthorization[] calldata authorizations
    ) external {
        if (msg.sender != stagePatchModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        for (uint256 i = 0; i < authorizations.length; i++) {
            SignalAuthorization calldata authorization = authorizations[i];
            if (_s.signalAuthorizations[planId][orderId][_signalKey(
                        authorization.sourceId, authorization.signalId
                    )][authorization.submitter].exists) {
                continue;
            }
            _authorizeSignalSubmitter(planId, orderId, authorization);
        }
    }

    function authorizeDockedSignalsFromModule(
        bytes32 planId,
        bytes32 orderId,
        SignalAuthorization[] calldata authorizations
    ) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        _authorizeSignalSubmitters(planId, orderId, authorizations);
    }

    function createDockedOrderFromModule(DockEntranceRequest calldata request) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (request.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        if (request.sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (request.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        if (!_isDockOrderId(request.linkedOrderId)) {
            revert InvalidDockOrderNamespace(request.linkedOrderId);
        }
        bytes32 entranceFactStageId =
            _resolveSourceStage(request.targetPlanId, request.sourceId, request.signalId, request.entranceAttribution);
        _createOrder(request.targetPlanId, request.linkedOrderId, request.creator, request.relayer);
        _authorizeSignalSubmitters(request.targetPlanId, request.linkedOrderId, request.authorizations);
        _recordSignal(
            request.targetPlanId,
            request.linkedOrderId,
            request.sourceId,
            request.signalId,
            request.payloadHash,
            request.idempotencyKey,
            request.submitter,
            true,
            entranceFactStageId
        );
        _requireDockTriggerHookReady(request.targetPlanId, request.linkedOrderId, request.entranceHookId, request.entranceStageId);
    }

    function recordDockedInputFromModule(DockInputFact calldata fact) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (fact.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        if (fact.sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (fact.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        bytes32 factStageId = _resolveSourceStage(fact.planId, fact.sourceId, fact.signalId, fact.attribution);
        _recordSignal(
            fact.planId,
            fact.orderId,
            fact.sourceId,
            fact.signalId,
            fact.payloadHash,
            fact.idempotencyKey,
            fact.submitter,
            false,
            factStageId
        );
    }

    function planHookFlags(bytes32 planId, bytes32 hookId) external view returns (uint8) {
        StoredHook storage hook = _s.plans[planId].hooks[hookId];
        return hook.exists ? hook.flags : 0;
    }

    function planHookStageId(bytes32 planId, bytes32 hookId) external view returns (bytes32) {
        StoredHook storage hook = _s.plans[planId].hooks[hookId];
        return hook.stageId;
    }

    function planBirthAuthorizer(bytes32 planId) external view returns (address) {
        return _s.plans[planId].birthAuthorizer;
    }

    /// @notice hook 是否声明依赖事实 (sourceId, signalId)——plan 的 receive
    ///         词表投影（compiledHooks 的 dependencyKeys）。docking 模块用它
    ///         把 dock 出生锚事实键钉在目标 mailbox hook 的 SIGNAL 原子上。
    function planHookDependsOn(bytes32 planId, bytes32 hookId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool)
    {
        bytes32[] storage dependents = _s.plans[planId].dependencyIndex[_signalKey(sourceId, signalId)];
        for (uint256 i = 0; i < dependents.length; i++) {
            if (dependents[i] == hookId) {
                return true;
            }
        }
        return false;
    }

    /// @notice 阶段是否挂有 order-trigger（mint/dock）hook。出生/订阅阶段
    ///         的执行者终生不可变（云侧已强制）——stage patch
    ///         模块读本视图拒绝出生阶段的逐单 executor patch；资源补丁
    ///         （fileResources-only）不受此门，资源可替换。
    function stageHasOrderTriggerHook(bytes32 planId, bytes32 stageId) external view returns (bool) {
        Plan storage plan = _s.plans[planId];
        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (hook.stageId == stageId && _isOrderTrigger(hook.flags)) {
                return true;
            }
        }
        return false;
    }

    function planDockRoots(bytes32 planId) external view returns (bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot) {
        Plan storage plan = _s.plans[planId];
        return (plan.dockRoutesRoot, plan.dockInterfaceRoot);
    }

    function submitSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        FactAttribution calldata attribution
    ) external {
        if (msg.sender != dockingModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }
        if (sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        bool factKnown = _verifiedFactOwner(planId, sourceId, signalId, attribution) != bytes32(0);
        if (!factKnown && _hasCapabilityVocabulary(planId)) {
            revert InvalidSignalCapability(planId, sourceId, signalId);
        }
        bytes32 sourceStageId = _resolveSourceStage(planId, sourceId, signalId, attribution);
        _requireSourceStageReady(planId, orderId, sourceStageId);
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
    }

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
    ) external {
        if (msg.sender != derivedSignalModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }
        if (!_hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter)) {
            _requireActiveStageExecutorByStage(fromPlanId, fromOrderId, stageId, submitter);
        }
        bool currentOrderFact = fromPlanId == planId && fromOrderId == orderId;
        bytes32 sourceStageId = currentOrderFact ? stageId : bytes32(0);
        _requireSourceStageReady(planId, orderId, sourceStageId);
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return;
        }
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
    }

    function _submitSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        FactAttribution calldata attribution
    ) private {
        if (sourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        if (!_isSignalSubmitterAuthorized(planId, orderId, sourceId, signalId, submitter)) {
            revert UnauthorizedSignalSubmitter(orderId, sourceId, signalId, submitter);
        }
        bytes32 sourceStageId = _resolveSourceStage(planId, sourceId, signalId, attribution);
        _requireSourceStageReady(planId, orderId, sourceStageId);
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return;
        }
        _requireSignalAdmission(planId, orderId, sourceId, signalId);
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
    }

    function _requireSignalAdmission(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId) private view {
        if (!_s.orders[planId][orderId].admissionsDeclared) {
            return;
        }
        StoredAdmission storage admission = _s.plans[planId].admissions[_signalKey(sourceId, signalId)];
        if (!admission.exists) {
            return;
        }
        EvalValue memory result = _evaluateInstructions(planId, orderId, admission.instructions);
        if (!result.value || result.wait || result.cancel) {
            revert SignalAdmissionRejected(orderId, sourceId, signalId);
        }
    }

    function _requireSourceStageReady(bytes32 planId, bytes32 orderId, bytes32 sourceStageId) private view {
        if (sourceStageId == bytes32(0)) {
            return;
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.materializedStages[sourceStageId]) {
            revert UnknownHook();
        }
        _requireStageExecutorAssigned(planId, orderId, sourceStageId);
    }

    function _recordSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        bool evaluateOrderTriggerHooks,
        bytes32 factStageId
    ) private {
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        bytes32 key = _signalKey(sourceId, signalId);
        SignalRecord storage signal = _s.signals[planId][orderId][key];
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
        _recordSourceSignal(planId, orderId, sourceId, submitter);
        if (factStageId != bytes32(0)) {
            _recordStageSignal(planId, orderId, factStageId, submitter);
        }

        emit SignalSubmitted(
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, factStageId
        );
        _evaluateAffectedHooks(planId, orderId, key, sourceId, signalId, evaluateOrderTriggerHooks);
    }

    function _recordSourceSignal(bytes32 planId, bytes32 orderId, bytes32 sourceId, address submitter) private {
        SourceSignalAccount storage sourceAccount = _s.sourceSignalAccounts[planId][orderId][sourceId];
        sourceAccount.count += 1;
        sourceAccount.lastSubmitter = submitter;
    }

    function _recordStageSignal(bytes32 planId, bytes32 orderId, bytes32 factStageId, address submitter) private {
        StageSignalAccount storage account = _s.stageSignalAccounts[planId][orderId][factStageId];
        account.count += 1;
        uint64 submittedAt = uint64(block.timestamp);
        if (submittedAt > account.lastAt) {
            account.lastAt = submittedAt;
            account.lastSubmitter = submitter;
            account.ambiguous = false;
        } else if (submittedAt == account.lastAt && submitter != account.lastSubmitter) {
            account.ambiguous = true;
        }
    }

    function pokeTimer(bytes32 planId, bytes32 orderId, bytes32 hookId) external {
        Order storage order = _s.orders[planId][orderId];
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
        return _s.plans[planId].finalized;
    }

    function planCommitted(bytes32 planId) external view returns (bool) {
        return _s.plans[planId].committed;
    }

    function planFinalized(bytes32 planId) external view returns (bool) {
        return _s.plans[planId].finalized;
    }

    function planHash(bytes32 planId) external view returns (bytes32) {
        return _s.plans[planId].planHash;
    }

    function orderExists(bytes32 planId, bytes32 orderId) external view returns (bool) {
        return _s.orders[planId][orderId].exists;
    }

    function planPublisher(bytes32 planId) external view returns (address) {
        return _s.plans[planId].publisher;
    }

    function orderRelayer(bytes32 planId, bytes32 orderId) external view returns (address) {
        return _s.orders[planId][orderId].relayer;
    }

    function orderCreator(bytes32 planId, bytes32 orderId) external view returns (address) {
        return _s.orders[planId][orderId].creator;
    }

    function getHookStatus(bytes32 planId, bytes32 orderId, bytes32 hookId)
        external
        view
        returns (HookStatus status, uint64 dueAt, bool readyEmitted)
    {
        Order storage order = _s.orders[planId][orderId];
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
        SignalRecord storage signal = _s.signals[planId][orderId][_signalKey(sourceId, signalId)];
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
        return _s.sourceSignalAccounts[planId][orderId][sourceId].count != 0;
    }

    function stageSignalState(bytes32 planId, bytes32 orderId, bytes32 stageId)
        external
        view
        returns (uint256 count, address lastSubmitter, uint64 lastAt, bool ambiguous)
    {
        StageSignalAccount storage account = _s.stageSignalAccounts[planId][orderId][stageId];
        return (account.count, account.lastSubmitter, account.lastAt, account.ambiguous);
    }

    function orderParent(bytes32 planId, bytes32 orderId) external view returns (bytes32) {
        return _s.orders[planId][orderId].parentOrderId;
    }

    function planExecutorCandidatesRoot(bytes32 planId) external view returns (bytes32) {
        return _s.plans[planId].executorCandidatesRoot;
    }

    function isSignalSubmitterAuthorized(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) external view returns (bool) {
        Order storage order = _s.orders[planId][orderId];
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
            _s.signalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)][submitter];
        if (authorization.exists) {
            return (true, authorization.role, authorization.metadataHash);
        }
        return (false, bytes32(0), bytes32(0));
    }

    function activeStageExecutor(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (address)
    {
        return _s.activeStageExecutorPatches[planId][orderId][targetStageId].executor;
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

    function signalAuthorizationsHash(SignalAuthorization[] calldata authorizations) public pure returns (bytes32) {
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

    function _signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function _isOrderTrigger(uint8 flags) private pure returns (bool) {
        return flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK) != 0;
    }

    function _isDockOrderId(bytes32 orderId) private pure returns (bool) {
        return uint256(orderId) & uint256(DOCK_ORDER_NAMESPACE_MASK) != 0;
    }

    function hasTriggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party,
        FactAttribution calldata originAttribution
    ) public view returns (bool) {
        if (party == address(0)) {
            return false;
        }
        bytes32 originStageId = _resolveSourceStage(originPlanId, originSourceId, originSignalId, originAttribution);
        return _triggerOriginConsent(originPlanId, originOrderId, originSourceId, originSignalId, party, originStageId);
    }

    function _triggerOriginConsent(
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party,
        bytes32 originStageId
    ) private view returns (bool) {
        if (party == address(0)) {
            return false;
        }
        Order storage originOrder = _s.orders[originPlanId][originOrderId];
        if (!originOrder.exists) {
            return false;
        }
        if (originOrder.creator == party) {
            return true;
        }
        if (_hasExplicitSignalAuthorization(originPlanId, originOrderId, originSourceId, originSignalId, party)) {
            return true;
        }
        ActiveStageExecutorPatch storage activePatch =
            _s.activeStageExecutorPatches[originPlanId][originOrderId][originStageId];
        if (originStageId != bytes32(0) && activePatch.exists) {
            return activePatch.executor == party;
        }
        return false;
    }

    function _isPlanStage(bytes32 planId, bytes32 stageId) private view returns (bool) {
        if (stageId == bytes32(0)) {
            return false;
        }
        return _s.plans[planId].stageExists[stageId];
    }

    function _requireStageExecutorAssigned(bytes32 planId, bytes32 orderId, bytes32 targetStageId) private view {
        if (_s.activeStageExecutorPatches[planId][orderId][targetStageId].exists) {
            return;
        }
        if (!_s.plans[planId].executorCandidateStages[targetStageId]) {
            return;
        }
        if (_s.stageSignalAccounts[planId][orderId][targetStageId].count != 0) {
            return;
        }
        revert StageExecutorNotAssigned(orderId, targetStageId);
    }

    function _evaluateAffectedHooks(
        bytes32 planId,
        bytes32 orderId,
        bytes32 dependencyKey,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId,
        bool evaluateOrderTriggerHooks
    ) private {
        Plan storage plan = _s.plans[planId];
        Order storage order = _s.orders[planId][orderId];
        bytes32[] storage hookIds = plan.dependencyIndex[dependencyKey];
        if (evaluateOrderTriggerHooks) {
            for (uint256 i = 0; i < hookIds.length; i++) {
                StoredHook storage hook = plan.hooks[hookIds[i]];
                if (_isOrderTrigger(hook.flags)) {
                    _evaluateHook(planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
                }
            }
        }
        for (uint256 i = 0; i < hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[hookIds[i]];
            if (!_isOrderTrigger(hook.flags)) {
                if (hook.flags & HOOK_FLAG_EMIT_READY == 0 && !order.materializedStages[hook.stageId]) {
                    continue;
                }
                _evaluateHook(planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
            }
        }
    }

    function _validatedOrderTriggerHook(
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        uint8 requiredFlag
    ) private view returns (StoredHook storage hook) {
        Plan storage plan = _s.plans[planId];
        if (!plan.finalized) {
            revert UnknownPlan();
        }

        hook = plan.hooks[triggerHookId];
        if (!hook.exists || hook.flags & requiredFlag == 0 || hook.stageId != triggerStageId) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _validatedDockTriggerHook(bytes32 planId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
        returns (StoredHook storage hook)
    {
        hook = _validatedOrderTriggerHook(planId, triggerHookId, triggerStageId, HOOK_FLAG_ORDER_TRIGGER_DOCK);
    }

    function _requireDockTriggerHookReady(bytes32 planId, bytes32 orderId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
    {
        _validatedDockTriggerHook(planId, triggerHookId, triggerStageId);
        HookRuntime storage runtime = _s.orders[planId][orderId].hookRuntimes[triggerHookId];
        if (!runtime.exists || runtime.status != HookStatus.Ready || !runtime.readyEmitted) {
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
        Plan storage plan = _s.plans[planId];
        StoredHook storage hook = plan.hooks[hookId];
        if (!hook.exists) {
            revert UnknownHook();
        }

        Order storage order = _s.orders[planId][orderId];
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
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
        EvalValue memory result = _evaluateInstructions(planId, orderId, hook.instructions);
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
        Order storage order = _s.orders[planId][orderId];
        if (!order.materialized) {
            order.materialized = true;
            emit OrderMaterialized(orderId, planId, stageId);
        }
        if (order.materializedStages[stageId]) {
            return;
        }
        order.materializedStages[stageId] = true;

        Plan storage plan = _s.plans[planId];
        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (hook.stageId == stageId) {
                _initializeHookRuntime(order, hook.hookId);
            }
        }

        emit StageMaterialized(planId, orderId, stageId, triggerHookId, triggerSourceId, triggerSignalId);
    }

    function _evaluateInstructions(bytes32 planId, bytes32 orderId, Instruction[] storage instructions)
        private
        view
        returns (EvalValue memory)
    {
        EvalValue[] memory stack = new EvalValue[](instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < instructions.length; i++) {
            Instruction storage instruction = instructions[i];
            if (instruction.op == uint8(InstructionOp.Signal)) {
                stack[stackDepth++] = _signalValue(planId, orderId, instruction.sourceId, instruction.signalId);
            } else if (instruction.op == uint8(InstructionOp.Not)) {
                stack[stackDepth - 1] = _notValue(stack[stackDepth - 1]);
            } else if (instruction.op == uint8(InstructionOp.Delay)) {
                stack[stackDepth - 1] = _delayValue(stack[stackDepth - 1], instruction.delaySeconds);
            } else if (instruction.op == uint8(InstructionOp.And)) {
                EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _andValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else if (instruction.op == uint8(InstructionOp.Or)) {
                EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _orValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else {
                revert InvalidInstruction();
            }
        }
        return stack[0];
    }

    function _signalValue(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (EvalValue memory)
    {
        SignalRecord storage signal = _s.signals[planId][orderId][_signalKey(sourceId, signalId)];
        if (!signal.exists) {
            return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: signal.submittedAt});
    }

    function _notValue(EvalValue memory value) private pure returns (EvalValue memory) {
        if (value.value) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        if (value.wait) {
            return EvalValue({value: true, wait: false, cancel: false, dueAt: value.dueAt, anchorAt: 0});
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
        if (value.anchorAt == 0) {
            return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        uint64 dueAt = value.anchorAt + delaySeconds;
        if (block.timestamp < dueAt) {
            return EvalValue({value: false, wait: true, cancel: false, dueAt: dueAt, anchorAt: value.anchorAt});
        }
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: dueAt});
    }

    function _andValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        if (left.cancel || right.cancel) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        if (left.value && right.value) {
            return EvalValue({
                value: true,
                wait: false,
                cancel: false,
                dueAt: _minDue(left.dueAt, right.dueAt),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if ((left.wait && (right.value || right.wait)) || (right.wait && (left.value || left.wait))) {
            return EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: _maxDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _orValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        if (left.value || right.value) {
            bool leftWins;
            if (left.value && !right.value) {
                leftWins = true;
            } else if (!left.value && right.value) {
                leftWins = false;
            } else {
                leftWins = !(right.anchorAt != 0 && (left.anchorAt == 0 || right.anchorAt < left.anchorAt));
            }
            return EvalValue({
                value: true,
                wait: false,
                cancel: false,
                dueAt: leftWins ? left.dueAt : right.dueAt,
                anchorAt: leftWins ? left.anchorAt : right.anchorAt
            });
        }
        if (left.wait || right.wait) {
            return EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: _minDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
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
        return _s.signals[planId][orderId][_signalKey(sourceId, signalId)].exists;
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
        return _hasExplicitSignalAuthorization(planId, orderId, sourceId, signalId, submitter);
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
        return _s.signalAuthorizations[planId][orderId][_signalKey(sourceId, signalId)][submitter].exists;
    }

    function _requireActiveStageExecutorByStage(bytes32 planId, bytes32 orderId, bytes32 stageId, address submitter)
        private
        view
    {
        if (stageId == bytes32(0)) {
            return;
        }
        ActiveStageExecutorPatch storage activePatch = _s.activeStageExecutorPatches[planId][orderId][stageId];
        if (activePatch.exists && submitter != activePatch.executor) {
            revert UnauthorizedStageExecutor(orderId, stageId, submitter, activePatch.executor);
        }
    }

    function _verifiedFactOwner(
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId,
        FactAttribution calldata attribution
    ) private view returns (bytes32 stageId) {
        if (attribution.stageId == bytes32(0)) {
            return bytes32(0);
        }
        if (attribution.sourceId != sourceId || attribution.signalId != signalId) {
            revert InvalidFactAttribution(planId, sourceId, signalId, attribution.stageId);
        }
        if (!IUVPPlanMetadataModule(_s.planMetadataModule)
                .verifySignalCapability(
                    planId,
                    attribution.stageId,
                    sourceId,
                    signalId,
                    SIGNAL_TARGET_CURRENT_ORDER,
                    attribution.capabilityProof
                )) {
            revert InvalidFactAttribution(planId, sourceId, signalId, attribution.stageId);
        }
        return attribution.stageId;
    }

    function _resolveSourceStage(
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId,
        FactAttribution calldata attribution
    ) private view returns (bytes32 stageId) {
        stageId = _verifiedFactOwner(planId, sourceId, signalId, attribution);
        if (stageId != bytes32(0)) {
            return stageId;
        }
        if (_hasCapabilityVocabulary(planId)) {
            revert InvalidSignalCapability(planId, sourceId, signalId);
        }
        if (_isPlanStage(planId, sourceId)) {
            stageId = sourceId;
        }
    }

    function _hasCapabilityVocabulary(bytes32 planId) private view returns (bool) {
        if (_s.planMetadataModule == address(0)) {
            return false;
        }
        return IUVPPlanMetadataModule(_s.planMetadataModule).hasCapabilityVocabulary(planId);
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
