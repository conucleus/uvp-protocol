// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
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
        bool isTrigger;
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
        bytes32 orderId;
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
        bytes32 triggerHookId;
        bytes32 triggerStageId;
        bytes32 originSourceId;
        bytes32 originSignalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        address submitter;
        uint256 deadline;
    }

    struct PlanCommit {
        address publisher;
        bytes32 hooksHash;
        bytes32 metadataHash;
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
        bool isTrigger;
        Instruction[] instructions;
        bytes32[] dependencyKeys;
        bool exists;
    }

    struct Plan {
        bytes32 planHash;
        bytes32 hooksHash;
        bytes32 metadataHash;
        address publisher;
        bytes32[] hookIds;
        mapping(bytes32 hookId => StoredHook hook) hooks;
        mapping(bytes32 signalKey => bytes32[] hookIds) dependencyIndex;
        mapping(bytes32 stageId => bool exists) stageExists;
        bool committed;
        bool finalized;
    }

    struct Order {
        bytes32 planId;
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
    error InvalidInstruction();
    error InvalidHook();
    error InvalidModuleAddress();
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
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error TimerNotDue();
    error TimerNotWaiting();
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

    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.8");
    bytes32 private constant _PLAN_RUNTIME_HASH_DOMAIN = keccak256("uvp.plan.runtime.v1");
    bytes32 private constant _PLAN_ID_HASH_DOMAIN = keccak256("uvp.plan.id.v1");
    uint64 public constant MAX_HOOK_DELAY_SECONDS = 30 days;
    uint256 public constant MAX_PLAN_DEPENDENCIES = 1024;
    bytes32 private constant _PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 metadataHash,uint256 deadline)"
    );
    bytes32 private constant _SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant _TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 orderId,bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );
    mapping(bytes32 planId => Plan plan) private _plans;
    mapping(bytes32 orderId => Order order) private _orders;
    mapping(bytes32 orderId => mapping(bytes32 signalKey => SignalRecord signal)) private _signals;
    mapping(
        bytes32 orderId
            => mapping(bytes32 signalKey => mapping(address submitter => StoredSignalAuthorization authorization))
    ) private _signalAuthorizations;
    mapping(bytes32 orderId => mapping(bytes32 signalKey => DelegatedStageSignalAuthorization authorization)) private
        _delegatedStageSignalAuthorizations;
    mapping(bytes32 orderId => mapping(bytes32 sourceId => uint256 count)) public sourceSignalCount;
    mapping(bytes32 orderId => mapping(bytes32 sourceId => address submitter)) public lastSignalSubmitter;
    mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch)) private
        _activeStageExecutorPatches;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StateMachineModuleSet(bytes32 indexed moduleId, address indexed previousModule, address indexed newModule);
    event StateMachineModulesFrozen(bytes32 indexed moduleSetHash);
    event PlanCommitted(
        bytes32 indexed planId,
        bytes32 indexed planHash,
        address indexed publisher,
        bytes32 hooksHash,
        bytes32 metadataHash,
        uint256 hookCount
    );
    event PlanFinalized(bytes32 indexed planId, bytes32 indexed planHash, bytes32 metadataHash);
    event PlanRegistered(bytes32 indexed planId, bytes32 planHash, uint256 hookCount);
    event PlanPublisherRecorded(bytes32 indexed planId, address indexed publisher);
    event OrderRegistered(bytes32 indexed orderId, bytes32 indexed planId);
    event OrderMaterialized(bytes32 indexed orderId, bytes32 indexed planId, bytes32 indexed stageId);
    event OrderRelayerRecorded(bytes32 indexed orderId, address indexed relayer, address indexed creator);
    event SignalSubmitterAuthorized(
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 indexed signalId,
        address submitter,
        bytes32 role,
        bytes32 metadataHash
    );
    event StageExecutorSignalDelegated(
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        address executor,
        bytes32 role,
        bytes32 metadataHash,
        uint256 patchNonce
    );
    event SignalSubmitted(
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 indexed signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    );
    event StageMaterialized(
        bytes32 indexed orderId,
        bytes32 indexed stageId,
        bytes32 indexed triggerHookId,
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
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        address indexed executor,
        bytes32 role,
        bytes32 metadataHash,
        uint256 patchNonce,
        string metadataURI
    );
    event HookStatusChanged(
        bytes32 indexed orderId, bytes32 indexed hookId, HookStatus previousStatus, HookStatus newStatus, uint64 dueAt
    );
    event HookReady(bytes32 indexed orderId, bytes32 indexed hookId, bytes32 indexed stageId, bytes32 hookName);
    event TimerPoked(bytes32 indexed orderId, bytes32 indexed hookId, uint64 dueAt);

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

        bytes32 runtimePlanHash = planRuntimeHash(commit.hooksHash, commit.metadataHash);
        planId = planIdFor(commit.publisher, runtimePlanHash);
        Plan storage plan = _plans[planId];
        if (plan.committed) {
            revert PlanAlreadyRegistered();
        }
        plan.planHash = runtimePlanHash;
        plan.hooksHash = commit.hooksHash;
        plan.metadataHash = commit.metadataHash;
        plan.publisher = commit.publisher;
        plan.committed = true;

        // Cross-stage dependency scan scratch: scoped so the large memory
        // arrays release their stack slots before the commit events fire.
        {
            bytes32[] memory seenKeys = new bytes32[](MAX_PLAN_DEPENDENCIES);
            bytes32[] memory seenStages = new bytes32[](MAX_PLAN_DEPENDENCIES);
            bool[] memory seenTriggerOnly = new bool[](MAX_PLAN_DEPENDENCIES);
            uint256 seenCount;
            for (uint256 i = 0; i < hooks.length; i++) {
                seenCount =
                _registerPlanHook(plan, hooks[i], seenKeys, seenStages, seenTriggerOnly, seenCount);
            }
        }

        emit PlanCommitted(
            planId, runtimePlanHash, commit.publisher, commit.hooksHash, commit.metadataHash, hooks.length
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

        IUVPPlanMetadataModule(planMetadataModule).finalizePlanMetadata(planId, selectorBindings, signalCapabilities);
        plan.finalized = true;

        emit PlanFinalized(planId, plan.planHash, plan.metadataHash);
        emit PlanRegistered(planId, plan.planHash, plan.hookIds.length);
    }

    function planRuntimeHash(bytes32 hooksHash, bytes32 metadataHash) public pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_RUNTIME_HASH_DOMAIN, hooksHash, metadataHash));
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

        bytes32 authorizationsHash = _signalAuthorizationsHash(authorizations);
        address recoveredSigner =
            _recoverSignalSubmitter(_triggerOrderFromOutsideDigest(trigger, authorizationsHash), signature);
        if (recoveredSigner != trigger.submitter) {
            revert InvalidTriggerOrderSignature(trigger.submitter, recoveredSigner);
        }

        _createOrder(trigger.orderId, trigger.planId, trigger.creator, msg.sender);
        _authorizeSignalSubmitters(trigger.orderId, authorizations);
        emit OrderTriggered(
            trigger.orderId,
            trigger.planId,
            trigger.triggerStageId,
            trigger.sourceId,
            trigger.signalId,
            trigger.submitter
        );
        _recordSignal(
            trigger.orderId,
            trigger.sourceId,
            trigger.signalId,
            trigger.payloadHash,
            trigger.idempotencyKey,
            trigger.submitter,
            false
        );
        _requireTriggerHookReady(trigger.orderId, trigger.planId, trigger.triggerHookId, trigger.triggerStageId);
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

        Order storage triggerOriginOrder = _orders[trigger.triggerOriginOrderId];
        if (!triggerOriginOrder.exists) {
            revert UnknownOrder();
        }
        if (!_hasSignal(trigger.triggerOriginOrderId, trigger.originSourceId, trigger.originSignalId)) {
            revert UnknownOrder();
        }
        _requireTriggerHookReadyForOrder(
            trigger.triggerOriginOrderId, trigger.planId, trigger.triggerHookId, trigger.triggerStageId
        );

        _createOrder(trigger.orderId, trigger.planId, trigger.creator, relayer);
        _authorizeSignalSubmitters(trigger.orderId, authorizations);
        emit OrderTriggered(
            trigger.orderId,
            trigger.planId,
            trigger.triggerStageId,
            trigger.originSourceId,
            trigger.originSignalId,
            trigger.submitter
        );
        _markTriggerHookReady(
            trigger.orderId,
            trigger.planId,
            trigger.triggerHookId,
            trigger.triggerStageId,
            trigger.originSourceId,
            trigger.originSignalId
        );
    }

    function _createOrder(bytes32 orderId, bytes32 planId, address creator, address relayer) private {
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
        Order storage order = _orders[orderId];
        if (order.exists) {
            revert OrderAlreadyRegistered();
        }
        order.planId = planId;
        order.relayer = relayer;
        order.creator = creator;
        order.exists = true;

        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (hook.isTrigger) {
                _initializeHookRuntime(order, hook.hookId);
            }
        }

        emit OrderRegistered(orderId, planId);
        emit OrderRelayerRecorded(orderId, relayer, creator);
    }

    function _authorizeSignalSubmitters(bytes32 orderId, SignalAuthorization[] calldata authorizations) private {
        for (uint256 i = 0; i < authorizations.length; i++) {
            _authorizeSignalSubmitter(orderId, authorizations[i]);
        }
    }

    function _authorizeSignalSubmitter(bytes32 orderId, SignalAuthorization calldata authorization) private {
        if (authorization.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        if (authorization.submitter == address(0)) {
            revert ZeroSubmitter();
        }

        bytes32 key = _signalKey(authorization.sourceId, authorization.signalId);
        StoredSignalAuthorization storage stored = _signalAuthorizations[orderId][key][authorization.submitter];
        if (stored.exists) {
            revert SignalSubmitterAlreadyAuthorized(
                orderId, authorization.sourceId, authorization.signalId, authorization.submitter
            );
        }

        stored.role = authorization.role;
        stored.metadataHash = authorization.metadataHash;
        stored.exists = true;

        emit SignalSubmitterAuthorized(
            orderId,
            authorization.sourceId,
            authorization.signalId,
            authorization.submitter,
            authorization.role,
            authorization.metadataHash
        );
    }

    function submitSignal(
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey
    ) external {
        _submitSignal(orderId, sourceId, signalId, payloadHash, idempotencyKey, msg.sender);
    }

    function submitSignalFor(
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
            _signalSubmissionDigest(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, deadline),
            signature
        );
        if (recoveredSigner != submitter) {
            revert InvalidSignalSignature(submitter, recoveredSigner);
        }

        _submitSignal(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter);
    }

    function activateStageExecutorFromModule(
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
        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (!_isPlanStage(order.planId, targetStageId)) {
            revert UnknownHook();
        }
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[orderId][targetStageId];
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
            orderId, targetStageId, executor, role, executorMetadataHash, patchNonce, metadataURI
        );
    }

    function delegateStageExecutorSignalFromModule(
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
        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (!_isPlanStage(order.planId, targetStageId)) {
            revert UnknownHook();
        }

        bytes32 key = _signalKey(sourceId, signalId);
        DelegatedStageSignalAuthorization storage delegated = _delegatedStageSignalAuthorizations[orderId][key];
        if (patchNonce <= delegated.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(orderId, targetStageId, delegated.patchNonce, patchNonce);
        }

        delegated.targetStageId = targetStageId;
        delegated.executor = executor;
        delegated.role = role;
        delegated.metadataHash = metadataHash;
        delegated.patchNonce = patchNonce;
        delegated.exists = true;

        emit SignalSubmitterAuthorized(orderId, sourceId, signalId, executor, role, metadataHash);
        emit StageExecutorSignalDelegated(
            orderId, targetStageId, sourceId, signalId, executor, role, metadataHash, patchNonce
        );
    }

    function submitSignalFromModule(
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
        _recordSignal(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, true);
    }

    function _submitSignal(
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
        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        if (!_isSignalSubmitterAuthorized(orderId, sourceId, signalId, submitter)) {
            revert UnauthorizedSignalSubmitter(orderId, sourceId, signalId, submitter);
        }
        _requireActiveStageExecutor(orderId, sourceId, submitter);

        _recordSignal(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, true);
    }

    function _recordSignal(
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        bool requireSourceStageMaterialized
    ) private {
        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (requireSourceStageMaterialized) {
            bool sourceIsPlanStage = _isPlanStage(order.planId, sourceId);
            if (sourceIsPlanStage && !order.materializedStages[sourceId]) {
                revert UnknownHook();
            }
            if (sourceIsPlanStage) {
                _requireStageExecutorAssigned(orderId, order.planId, sourceId);
            }
        }
        bytes32 key = _signalKey(sourceId, signalId);
        SignalRecord storage signal = _signals[orderId][key];
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
        sourceSignalCount[orderId][sourceId] += 1;
        lastSignalSubmitter[orderId][sourceId] = submitter;

        emit SignalSubmitted(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter);
        _evaluateAffectedHooks(orderId, order.planId, key, sourceId, signalId);
    }

    function pokeTimer(bytes32 orderId, bytes32 hookId) external {
        Order storage order = _orders[orderId];
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
        emit TimerPoked(orderId, hookId, dueAt);
        _evaluateHook(orderId, order.planId, hookId, bytes32(0), bytes32(0));
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

    function orderExists(bytes32 orderId) external view returns (bool) {
        return _orders[orderId].exists;
    }

    function orderPlanId(bytes32 orderId) external view returns (bytes32) {
        return _orders[orderId].planId;
    }

    function planPublisher(bytes32 planId) external view returns (address) {
        return _plans[planId].publisher;
    }

    function orderRelayer(bytes32 orderId) external view returns (address) {
        return _orders[orderId].relayer;
    }

    function orderCreator(bytes32 orderId) external view returns (address) {
        return _orders[orderId].creator;
    }

    function getHookStatus(bytes32 orderId, bytes32 hookId)
        external
        view
        returns (HookStatus status, uint64 dueAt, bool readyEmitted)
    {
        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            revert UnknownHook();
        }
        return (runtime.status, runtime.dueAt, runtime.readyEmitted);
    }

    function getSignal(bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter)
    {
        SignalRecord storage signal = _signals[orderId][_signalKey(sourceId, signalId)];
        return (signal.exists, signal.payloadHash, signal.idempotencyKey, signal.submittedAt, signal.submitter);
    }

    function hasSignal(bytes32 orderId, bytes32 sourceId, bytes32 signalId) external view returns (bool) {
        return _hasSignal(orderId, sourceId, signalId);
    }

    function hasSourceSignal(bytes32 orderId, bytes32 sourceId) external view returns (bool) {
        return sourceSignalCount[orderId][sourceId] != 0;
    }

    function isSignalSubmitterAuthorized(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        external
        view
        returns (bool)
    {
        Order storage order = _orders[orderId];
        if (!order.exists) {
            return false;
        }
        return _isSignalSubmitterAuthorized(orderId, sourceId, signalId, submitter);
    }

    function hasExplicitSignalAuthorization(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        external
        view
        returns (bool)
    {
        return _hasExplicitSignalAuthorization(orderId, sourceId, signalId, submitter);
    }

    function getSignalAuthorization(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        external
        view
        returns (bool exists, bytes32 role, bytes32 metadataHash)
    {
        DelegatedStageSignalAuthorization storage delegated =
            _delegatedStageSignalAuthorizations[orderId][_signalKey(sourceId, signalId)];
        if (delegated.exists) {
            return (delegated.executor == submitter, delegated.role, delegated.metadataHash);
        }
        StoredSignalAuthorization storage authorization =
            _signalAuthorizations[orderId][_signalKey(sourceId, signalId)][submitter];
        return (authorization.exists, authorization.role, authorization.metadataHash);
    }

    function activeStageExecutor(bytes32 orderId, bytes32 targetStageId) external view returns (address) {
        return _activeStageExecutorPatches[orderId][targetStageId].executor;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _signalSubmissionDigest(
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
        bytes memory encoded = new bytes(0x1a0);
        _writeWord(encoded, 0x00, _TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH);
        _writeWord(encoded, 0x20, trigger.orderId);
        _writeWord(encoded, 0x40, trigger.planId);
        _writeAddress(encoded, 0x60, trigger.creator);
        _writeWord(encoded, 0x80, trigger.triggerHookId);
        _writeWord(encoded, 0xa0, trigger.triggerStageId);
        _writeWord(encoded, 0xc0, trigger.sourceId);
        _writeWord(encoded, 0xe0, trigger.signalId);
        _writeWord(encoded, 0x100, trigger.payloadHash);
        _writeWord(encoded, 0x120, trigger.idempotencyKey);
        _writeWord(encoded, 0x140, authorizationsHash);
        _writeAddress(encoded, 0x160, trigger.submitter);
        _writeWord(encoded, 0x180, bytes32(trigger.deadline));
        bytes32 structHash = keccak256(encoded);
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function _isPlanStage(bytes32 planId, bytes32 stageId) private view returns (bool) {
        if (stageId == bytes32(0)) {
            return false;
        }
        return _plans[planId].stageExists[stageId];
    }

    function _requireStageExecutorAssigned(bytes32 orderId, bytes32 planId, bytes32 targetStageId) private view {
        if (_activeStageExecutorPatches[orderId][targetStageId].exists || planMetadataModule == address(0)) {
            return;
        }
        if (IUVPPlanMetadataModule(planMetadataModule).isSelectorTargetStage(planId, targetStageId)) {
            revert StageExecutorNotAssigned(orderId, targetStageId);
        }
    }

    function _planCommitDigest(PlanCommit calldata commit) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(_PLAN_COMMIT_TYPEHASH, commit.publisher, commit.hooksHash, commit.metadataHash, commit.deadline)
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
        if (plan.hooks[input.hookId].exists) {
            revert HookAlreadyRegistered();
        }

        StoredHook storage hook = plan.hooks[input.hookId];
        hook.hookId = input.hookId;
        hook.stageId = input.stageId;
        hook.hookName = input.hookName;
        hook.isTrigger = input.isTrigger;
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
                seenTriggerOnly[updatedCount] = input.isTrigger;
                updatedCount += 1;
            } else {
                bool triggerOnly = seenTriggerOnly[watcherIndex] && input.isTrigger;
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

    function _seenDependencyIndex(
        bytes32[] memory seenKeys,
        uint256 seenCount,
        bytes32 dependencyKey
    ) private pure returns (uint256) {
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
        bytes32 orderId,
        bytes32 planId,
        bytes32 dependencyKey,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Plan storage plan = _plans[planId];
        bytes32[] storage hookIds = plan.dependencyIndex[dependencyKey];
        for (uint256 i = 0; i < hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[hookIds[i]];
            if (hook.isTrigger) {
                _evaluateHook(orderId, planId, hookIds[i], triggerSourceId, triggerSignalId);
            }
        }
        for (uint256 i = 0; i < hookIds.length; i++) {
            StoredHook storage hook = plan.hooks[hookIds[i]];
            if (!hook.isTrigger) {
                _evaluateHook(orderId, planId, hookIds[i], triggerSourceId, triggerSignalId);
            }
        }
    }

    function _requireTriggerHookReady(bytes32 orderId, bytes32 planId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
    {
        _validatedTriggerHook(planId, triggerHookId, triggerStageId);

        HookRuntime storage runtime = _orders[orderId].hookRuntimes[triggerHookId];
        if (!runtime.exists || runtime.status != HookStatus.Ready || !runtime.readyEmitted) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _requireTriggerHookReadyForOrder(
        bytes32 orderId,
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId
    ) private view {
        StoredHook storage hook = _validatedTriggerHook(planId, triggerHookId, triggerStageId);
        EvalValue memory result = _evaluateInstructions(orderId, hook);
        if (!result.value || result.wait || result.cancel) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _markTriggerHookReady(
        bytes32 orderId,
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        StoredHook storage hook = _validatedTriggerHook(planId, triggerHookId, triggerStageId);
        Order storage order = _orders[orderId];
        HookRuntime storage runtime = order.hookRuntimes[triggerHookId];
        if (!runtime.exists) {
            _initializeHookRuntime(order, triggerHookId);
        }

        HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        runtime.status = HookStatus.Ready;
        runtime.dueAt = 0;

        if (previousStatus != HookStatus.Ready || previousDueAt != 0) {
            emit HookStatusChanged(orderId, triggerHookId, previousStatus, HookStatus.Ready, 0);
        }

        if (!runtime.readyEmitted) {
            runtime.readyEmitted = true;
            _materializeStage(orderId, planId, triggerStageId, triggerHookId, triggerSourceId, triggerSignalId);
            emit HookReady(orderId, triggerHookId, hook.stageId, hook.hookName);
        }
    }

    function _validatedTriggerHook(bytes32 planId, bytes32 triggerHookId, bytes32 triggerStageId)
        private
        view
        returns (StoredHook storage hook)
    {
        Plan storage plan = _plans[planId];
        if (!plan.finalized) {
            revert UnknownPlan();
        }

        hook = plan.hooks[triggerHookId];
        if (!hook.exists || !hook.isTrigger || hook.stageId != triggerStageId) {
            revert InvalidTriggerHook(triggerHookId);
        }
    }

    function _evaluateHook(
        bytes32 orderId,
        bytes32 planId,
        bytes32 hookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Plan storage plan = _plans[planId];
        StoredHook storage hook = plan.hooks[hookId];
        if (!hook.exists) {
            revert UnknownHook();
        }

        Order storage order = _orders[orderId];
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            if (!hook.isTrigger && !order.materializedStages[hook.stageId]) {
                revert UnknownHook();
            }
            _initializeHookRuntime(order, hookId);
        }
        if (runtime.status == HookStatus.Cancelled || runtime.status == HookStatus.Ready) {
            return;
        }

        HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        EvalValue memory result = _evaluateInstructions(orderId, hook);
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
            emit HookStatusChanged(orderId, hookId, previousStatus, nextStatus, nextDueAt);
        }

        if (nextStatus == HookStatus.Ready && hook.isTrigger && !runtime.readyEmitted) {
            runtime.readyEmitted = true;
            _materializeStage(orderId, planId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
            emit HookReady(orderId, hookId, hook.stageId, hook.hookName);
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
        bytes32 orderId,
        bytes32 planId,
        bytes32 stageId,
        bytes32 triggerHookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        Order storage order = _orders[orderId];
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

        emit StageMaterialized(orderId, stageId, triggerHookId, triggerSourceId, triggerSignalId);
    }

    function _evaluateInstructions(bytes32 orderId, StoredHook storage hook) private view returns (EvalValue memory) {
        EvalValue[] memory stack = new EvalValue[](hook.instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < hook.instructions.length; i++) {
            Instruction storage instruction = hook.instructions[i];
            if (instruction.op == InstructionOp.Signal) {
                stack[stackDepth++] = _signalValue(orderId, instruction.sourceId, instruction.signalId);
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

    function _signalValue(bytes32 orderId, bytes32 sourceId, bytes32 signalId) private view returns (EvalValue memory) {
        SignalRecord storage signal = _signals[orderId][_signalKey(sourceId, signalId)];
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

    function _orValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {        // Arrival-time causality (semantic 0.5): merge keeps the EARLIEST
        // received signal as the cause so trailing delays anchor on first
        // arrival, matching the core evaluator and replay oracle.
        if (left.value || right.value) {
            // Only READY branches compete for the anchor; a waiting branch's
            // stale anchor must not win (matches the core evaluator).
            uint64 anchor = left.value && right.value
                ? _minAnchor(left.anchorAt, right.anchorAt)
                : left.value
                    ? left.anchorAt
                    : right.anchorAt;
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

    function _hasSignal(bytes32 orderId, bytes32 sourceId, bytes32 signalId) private view returns (bool) {
        return _signals[orderId][_signalKey(sourceId, signalId)].exists;
    }

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _isSignalSubmitterAuthorized(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        private
        view
        returns (bool)
    {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        DelegatedStageSignalAuthorization storage delegated =
            _delegatedStageSignalAuthorizations[orderId][_signalKey(sourceId, signalId)];
        if (delegated.exists) {
            return delegated.executor == submitter;
        }
        return _hasExplicitSignalAuthorization(orderId, sourceId, signalId, submitter);
    }

    function _hasExplicitSignalAuthorization(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        private
        view
        returns (bool)
    {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        return _signalAuthorizations[orderId][_signalKey(sourceId, signalId)][submitter].exists;
    }

    function _requireActiveStageExecutor(bytes32 orderId, bytes32 sourceId, address submitter) private view {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[orderId][sourceId];
        if (activePatch.exists && submitter != activePatch.executor) {
            revert UnauthorizedStageExecutor(orderId, sourceId, submitter, activePatch.executor);
        }
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
