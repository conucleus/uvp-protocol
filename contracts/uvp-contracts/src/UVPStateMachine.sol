// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

interface IStateMachineTrustRegistry {
    function isPlanActive(bytes32 domainId, bytes32 planId, bytes32 planHash) external view returns (bool);
    function isPlanRevoked(bytes32 domainId, bytes32 planId) external view returns (bool);
}

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
        bool trigger;
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

    struct StageSelectorBinding {
        bytes32 selectorStageId;
        bytes32 targetStageId;
    }

    struct StageExecutorPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 mode;
        address previousExecutor;
        bytes32 approvalSourceId;
        bytes32 approvalSignalId;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
    }

    struct StageResourcePatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 resourceKey;
        bytes32 manifestHash;
        bytes32 policyHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string manifestURI;
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
        bool trigger;
        Instruction[] instructions;
        bytes32[] dependencyKeys;
        bool exists;
    }

    struct Plan {
        bytes32 planHash;
        address publisher;
        bytes32[] hookIds;
        bytes32[] selectorBindingKeys;
        mapping(bytes32 hookId => StoredHook hook) hooks;
        mapping(bytes32 signalKey => bytes32[] hookIds) dependencyIndex;
        mapping(bytes32 bindingKey => StageSelectorBinding binding) selectorBindings;
        bool exists;
    }

    struct Order {
        bytes32 planId;
        address registrar;
        address creator;
        mapping(bytes32 hookId => HookRuntime runtime) hookRuntimes;
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

    struct ActiveStageResourcePatch {
        bytes32 manifestHash;
        bytes32 policyHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string manifestURI;
        bool exists;
    }

    struct DockedSignalBinding {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bytes32 linkedSourceId;
        bytes32 linkedSignalId;
    }

    struct DockedOrderLink {
        bytes32 selectorStageId;
        bytes32 localSourceId;
        bytes32 linkedOrderId;
        bytes32 linkedPlanId;
        bytes32 linkHash;
        uint256 linkNonce;
        string metadataURI;
        DockedSignalBinding[] signalBindings;
    }

    struct ActiveDockedOrderLink {
        bytes32 selectorStageId;
        bytes32 localSourceId;
        bytes32 linkedPlanId;
        address selector;
        bytes32 linkHash;
        uint256 linkNonce;
        string metadataURI;
        bool exists;
    }

    struct ActiveDockedSignalBinding {
        bytes32 localSourceId;
        bytes32 localSignalId;
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
    error EmptySignalAuthorizations();
    error ExpiredSignalSignature(uint256 deadline);
    error HookAlreadyRegistered();
    error InvalidSignalSignature(address expectedSigner, address recoveredSigner);
    error InvalidSignalSignatureLength(uint256 length);
    error InvalidStageExecutorPatchMode(bytes32 mode);
    error InvalidStageExecutorPatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageExecutorPatchSignatureLength(uint256 length);
    error InvalidStageResourcePatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageResourcePatchSignatureLength(uint256 length);
    error InvalidDockedOrderLinkSignature(address expectedSigner, address recoveredSigner);
    error InvalidDockedOrderLinkSignatureLength(uint256 length);
    error InvalidInstruction();
    error InvalidHook();
    error NotOwner();
    error OrderAlreadyRegistered();
    error PlanAlreadyRegistered();
    error SignalAlreadyExists();
    error SignalSubmitterAlreadyAuthorized(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error DockedOrderLinkNonceNotIncreasing(
        bytes32 localOrderId, bytes32 linkedOrderId, uint256 previousNonce, uint256 linkNonce
    );
    error DockedSignalBindingAlreadyRegistered(
        bytes32 localOrderId, bytes32 linkedOrderId, bytes32 linkedSourceId, bytes32 linkedSignalId
    );
    error DockedSignalBindingNotFound(
        bytes32 localOrderId, bytes32 linkedOrderId, bytes32 linkedSourceId, bytes32 linkedSignalId
    );
    error ExpiredDockedOrderLinkSignature(uint256 deadline);
    error ExpiredStageExecutorPatchSignature(uint256 deadline);
    error ExpiredStageResourcePatchSignature(uint256 deadline);
    error StageAlreadyHasSignal(bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchApprovalSignalMissing(bytes32 orderId, bytes32 approvalSourceId, bytes32 approvalSignalId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error StageExecutorPatchPreviousExecutorMismatch(
        bytes32 orderId, bytes32 targetStageId, address expectedExecutor, address previousExecutor
    );
    error StageResourcePatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey, uint256 previousNonce, uint256 patchNonce
    );
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    error StageSelectorBindingAlreadyRegistered(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error TimerNotDue();
    error TimerNotWaiting();
    error OfficialPlanNotActive();
    error OfficialPlanRevoked();
    error UnauthorizedOrderRegistrar();
    error UnauthorizedPlanPublisher();
    error UnauthorizedSignalSubmitter(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error UnauthorizedDockedOrderLinkSelector(bytes32 localOrderId, bytes32 selectorStageId, address selector);
    error UnauthorizedStageExecutor(bytes32 orderId, bytes32 targetStageId, address submitter, address executor);
    error UnauthorizedStageExecutorPatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnauthorizedStageResourcePatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnknownLinkedOrder(bytes32 linkedOrderId);
    error UnknownDockedOrderLink(bytes32 localOrderId, bytes32 linkedOrderId);
    error UnknownHook();
    error UnknownOrder();
    error UnknownPlan();
    error ZeroLinkedOrderId();
    error ZeroLinkedPlanId();
    error ZeroLinkHash();
    error ZeroManifestHash();
    error ZeroOfficialDomainId();
    error ZeroOrderCreator();
    error ZeroOrderId();
    error ZeroOrderRegistrar();
    error ZeroPatchHash();
    error ZeroPolicyHash();
    error ZeroOwner();
    error ZeroPlanId();
    error ZeroPlanPublisher();
    error ZeroResourceKey();
    error ZeroSelector();
    error ZeroSelectorStageId();
    error ZeroSignalId();
    error ZeroSourceId();
    error ZeroStageExecutor();
    error ZeroSubmitter();
    error ZeroTargetStageId();
    error ZeroTrustRegistry();

    address public owner;
    IStateMachineTrustRegistry public immutable trustRegistry;
    bytes32 public immutable officialDomainId;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 public constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;
    bytes32 public constant RESOURCE_PATCH_SIGNAL_ID =
        0x6dff331f2bb7b785cbcd99a911e6d30dc8714f43b3b9ba80c658215445ddd0ba;
    bytes32 public constant DOCKED_ORDER_LINK_SIGNAL_ID = keccak256("uvp.docked_order_link.v1");
    bytes32 public constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");
    bytes32 public constant EXECUTOR_PATCH_MODE_HANDOFF = bytes32("handoff");
    bytes32 public constant EXECUTOR_PATCH_MODE_REPLACEMENT = bytes32("replacement");

    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.2");
    bytes32 private constant _SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC = keccak256(
        "StageExecutorPatchApplied(bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,bytes32,uint256,string)"
    );
    bytes32 private constant _STAGE_EXECUTOR_PATCH_TYPEHASH = keccak256(
        "UVPStateMachineStageExecutorPatch(bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_RESOURCE_PATCH_TYPEHASH = keccak256(
        "UVPStateMachineStageResourcePatch(bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _DOCKED_ORDER_LINK_TYPEHASH = keccak256(
        "UVPStateMachineDockedOrderLink(bytes32 localOrderId,bytes32 selectorStageId,bytes32 localSourceId,bytes32 linkedOrderId,bytes32 linkedPlanId,bytes32 linkHash,uint256 linkNonce,bytes32 signalBindingsHash,string metadataURI,address selector,uint256 deadline)"
    );

    mapping(address publisher => bool allowed) public planPublishers;
    mapping(address registrar => bool allowed) public orderRegistrars;
    mapping(bytes32 planId => Plan plan) private _plans;
    mapping(bytes32 orderId => Order order) private _orders;
    mapping(bytes32 orderId => mapping(bytes32 signalKey => SignalRecord signal)) private _signals;
    mapping(
        bytes32 orderId
            => mapping(bytes32 signalKey => mapping(address submitter => StoredSignalAuthorization authorization))
    ) private _signalAuthorizations;
    mapping(bytes32 orderId => mapping(bytes32 sourceId => uint256 count)) public sourceSignalCount;
    mapping(bytes32 orderId => mapping(bytes32 sourceId => address submitter)) public lastSignalSubmitter;
    mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch)) private
        _activeStageExecutorPatches;
    mapping(
        bytes32 orderId
            => mapping(bytes32 targetStageId => mapping(bytes32 resourceKey => ActiveStageResourcePatch patch))
    ) private _activeStageResourcePatches;
    mapping(bytes32 localOrderId => mapping(bytes32 linkedOrderId => ActiveDockedOrderLink link)) private
        _activeDockedOrderLinks;
    mapping(
        bytes32 localOrderId
            => mapping(bytes32 linkedOrderId => mapping(bytes32 linkedSignalKey => ActiveDockedSignalBinding binding))
    ) private _activeDockedSignalBindings;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PlanPublisherSet(address indexed publisher, bool allowed);
    event OrderRegistrarSet(address indexed registrar, bool allowed);
    event PlanRegistered(bytes32 indexed planId, bytes32 planHash, uint256 hookCount);
    event PlanPublisherRecorded(bytes32 indexed planId, address indexed publisher);
    event OrderRegistered(bytes32 indexed orderId, bytes32 indexed planId);
    event OrderRegistrarRecorded(bytes32 indexed orderId, address indexed registrar, address indexed creator);
    event SignalSubmitterAuthorized(
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 indexed signalId,
        address submitter,
        bytes32 role,
        bytes32 metadataHash
    );
    event SignalSubmitted(
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 indexed signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    );
    event StageSelectorBindingRegistered(
        bytes32 indexed planId, bytes32 indexed selectorStageId, bytes32 indexed targetStageId
    );
    event StageExecutorPatchApplied(
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 indexed targetStageId,
        address selector,
        address executor,
        bytes32 role,
        bytes32 executorMetadataHash,
        bytes32 mode,
        address previousExecutor,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        bytes32 patchHash,
        uint256 patchNonce,
        string metadataURI
    );
    event StageResourcePatchApplied(
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 indexed targetStageId,
        address selector,
        bytes32 resourceKey,
        bytes32 manifestHash,
        bytes32 policyHash,
        bytes32 patchHash,
        uint256 patchNonce,
        string manifestURI
    );
    event StageExecutorActivated(
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        address indexed executor,
        bytes32 role,
        bytes32 metadataHash,
        uint256 patchNonce
    );
    event DockedOrderLinked(
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed localSourceId,
        bytes32 selectorStageId,
        bytes32 linkedPlanId,
        address selector,
        bytes32 linkHash,
        uint256 linkNonce,
        string metadataURI
    );
    event DockedSignalMapped(
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed linkedSourceId,
        bytes32 linkedSignalId,
        bytes32 localSourceId,
        bytes32 localSignalId
    );
    event DockedSignalSubmitted(
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed linkedSourceId,
        bytes32 linkedSignalId,
        bytes32 localSourceId,
        bytes32 localSignalId,
        bytes32 payloadHash,
        address submitter
    );
    event HookStatusChanged(
        bytes32 indexed orderId, bytes32 indexed hookId, HookStatus previousStatus, HookStatus newStatus, uint64 dueAt
    );
    event HookReady(bytes32 indexed orderId, bytes32 indexed hookId, bytes32 indexed stageId, bytes32 hookName);
    event TimerPoked(bytes32 indexed orderId, bytes32 indexed hookId, uint64 dueAt);

    constructor(address trustRegistry_, bytes32 officialDomainId_) {
        if (trustRegistry_ == address(0)) {
            revert ZeroTrustRegistry();
        }
        if (officialDomainId_ == bytes32(0)) {
            revert ZeroOfficialDomainId();
        }

        owner = msg.sender;
        trustRegistry = IStateMachineTrustRegistry(trustRegistry_);
        officialDomainId = officialDomainId_;
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

    function setPlanPublisher(address publisher, bool allowed) external onlyOwner {
        if (publisher == address(0)) {
            revert ZeroPlanPublisher();
        }
        planPublishers[publisher] = allowed;
        emit PlanPublisherSet(publisher, allowed);
    }

    function setOrderRegistrar(address registrar, bool allowed) external onlyOwner {
        if (registrar == address(0)) {
            revert ZeroOrderRegistrar();
        }
        orderRegistrars[registrar] = allowed;
        emit OrderRegistrarSet(registrar, allowed);
    }

    function registerPlan(bytes32 planId, bytes32 planHash, CompactHook[] calldata hooks) external {
        _registerPlan(planId, planHash, hooks);
    }

    function registerPlan(
        bytes32 planId,
        bytes32 planHash,
        CompactHook[] calldata hooks,
        StageSelectorBinding[] calldata selectorBindings
    ) external {
        _registerPlan(planId, planHash, hooks);
        _registerStageSelectorBindings(planId, selectorBindings);
    }

    function _registerPlan(bytes32 planId, bytes32 planHash, CompactHook[] calldata hooks) private {
        if (!planPublishers[msg.sender]) {
            revert UnauthorizedPlanPublisher();
        }
        if (planId == bytes32(0)) {
            revert ZeroPlanId();
        }
        if (hooks.length == 0) {
            revert EmptyPlan();
        }
        Plan storage plan = _plans[planId];
        if (plan.exists) {
            revert PlanAlreadyRegistered();
        }
        _requireOfficialPlanActive(planId, planHash);

        plan.planHash = planHash;
        plan.publisher = msg.sender;
        plan.exists = true;

        for (uint256 i = 0; i < hooks.length; i++) {
            CompactHook calldata input = hooks[i];
            _validateHook(input);
            if (plan.hooks[input.hookId].exists) {
                revert HookAlreadyRegistered();
            }

            StoredHook storage hook = plan.hooks[input.hookId];
            hook.hookId = input.hookId;
            hook.stageId = input.stageId;
            hook.hookName = input.hookName;
            hook.trigger = input.trigger;
            hook.exists = true;

            for (uint256 j = 0; j < input.instructions.length; j++) {
                hook.instructions.push(input.instructions[j]);
            }
            for (uint256 j = 0; j < input.dependencyKeys.length; j++) {
                bytes32 dependencyKey = input.dependencyKeys[j];
                hook.dependencyKeys.push(dependencyKey);
                plan.dependencyIndex[dependencyKey].push(input.hookId);
            }

            plan.hookIds.push(input.hookId);
        }

        emit PlanRegistered(planId, planHash, hooks.length);
        emit PlanPublisherRecorded(planId, msg.sender);
    }

    function _registerStageSelectorBindings(bytes32 planId, StageSelectorBinding[] calldata selectorBindings) private {
        Plan storage plan = _plans[planId];
        for (uint256 i = 0; i < selectorBindings.length; i++) {
            StageSelectorBinding calldata binding = selectorBindings[i];
            if (binding.selectorStageId == bytes32(0)) {
                revert ZeroSelectorStageId();
            }
            if (binding.targetStageId == bytes32(0)) {
                revert ZeroTargetStageId();
            }

            bytes32 key = stageSelectorBindingKey(binding.selectorStageId, binding.targetStageId);
            if (plan.selectorBindings[key].selectorStageId != bytes32(0)) {
                revert StageSelectorBindingAlreadyRegistered(planId, binding.selectorStageId, binding.targetStageId);
            }

            plan.selectorBindings[key] =
                StageSelectorBinding({selectorStageId: binding.selectorStageId, targetStageId: binding.targetStageId});
            plan.selectorBindingKeys.push(key);
            emit StageSelectorBindingRegistered(planId, binding.selectorStageId, binding.targetStageId);
        }
    }

    function registerOrder(bytes32 orderId, bytes32 planId) external {
        _registerOrder(orderId, planId, msg.sender);
    }

    function registerOrder(bytes32 orderId, bytes32 planId, address creator) external {
        _registerOrder(orderId, planId, creator);
    }

    function registerOrder(bytes32 orderId, bytes32 planId, SignalAuthorization[] calldata authorizations) external {
        if (authorizations.length == 0) {
            revert EmptySignalAuthorizations();
        }
        _registerOrder(orderId, planId, msg.sender);

        for (uint256 i = 0; i < authorizations.length; i++) {
            _authorizeSignalSubmitter(orderId, authorizations[i]);
        }
    }

    function registerOrder(
        bytes32 orderId,
        bytes32 planId,
        address creator,
        SignalAuthorization[] calldata authorizations
    ) external {
        if (authorizations.length == 0) {
            revert EmptySignalAuthorizations();
        }
        _registerOrder(orderId, planId, creator);

        for (uint256 i = 0; i < authorizations.length; i++) {
            _authorizeSignalSubmitter(orderId, authorizations[i]);
        }
    }

    function _registerOrder(bytes32 orderId, bytes32 planId, address creator) private {
        if (!orderRegistrars[msg.sender]) {
            revert UnauthorizedOrderRegistrar();
        }
        if (orderId == bytes32(0)) {
            revert ZeroOrderId();
        }
        if (creator == address(0)) {
            revert ZeroOrderCreator();
        }
        Plan storage plan = _plans[planId];
        if (!plan.exists) {
            revert UnknownPlan();
        }
        Order storage order = _orders[orderId];
        if (order.exists) {
            revert OrderAlreadyRegistered();
        }
        _requireOfficialPlanActive(planId, plan.planHash);

        order.planId = planId;
        order.registrar = msg.sender;
        order.creator = creator;
        order.exists = true;

        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            order.hookRuntimes[plan.hookIds[i]] =
                HookRuntime({status: HookStatus.Init, dueAt: 0, readyEmitted: false, exists: true});
        }

        emit OrderRegistered(orderId, planId);
        emit OrderRegistrarRecorded(orderId, msg.sender, creator);
    }

    function _authorizeSignalSubmitter(bytes32 orderId, SignalAuthorization calldata authorization) private {
        if (authorization.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        if (authorization.submitter == address(0)) {
            revert ZeroSubmitter();
        }

        bytes32 key = signalKey(authorization.sourceId, authorization.signalId);
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
            signalSubmissionDigest(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, deadline),
            signature
        );
        if (recoveredSigner != submitter) {
            revert InvalidSignalSignature(submitter, recoveredSigner);
        }

        _submitSignal(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter);
    }

    function applyStageExecutorPatch(bytes32 orderId, StageExecutorPatch calldata patch) external {
        _applyStageExecutorPatch(orderId, patch, msg.sender);
    }

    function applyStageExecutorPatchFor(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        bytes calldata previousExecutorSignature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageExecutorPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        bytes32 digest = stageExecutorPatchDigest(orderId, patch, selector, deadline);
        address recoveredSigner = _recoverStageExecutorPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageExecutorPatchSignature(selector, recoveredSigner);
        }

        address recoveredPreviousExecutor;
        if (previousExecutorSignature.length != 0) {
            recoveredPreviousExecutor = _recoverStageExecutorPatchSigner(digest, previousExecutorSignature);
        }

        _applyStageExecutorPatch(orderId, patch, selector, recoveredPreviousExecutor);
    }

    function applyStageResourcePatch(bytes32 orderId, StageResourcePatch calldata patch) external {
        _applyStageResourcePatch(orderId, patch, msg.sender);
    }

    function applyStageResourcePatchFor(
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageResourcePatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        address recoveredSigner =
            _recoverStageResourcePatchSelector(stageResourcePatchDigest(orderId, patch, selector, deadline), signature);
        if (recoveredSigner != selector) {
            revert InvalidStageResourcePatchSignature(selector, recoveredSigner);
        }

        _applyStageResourcePatch(orderId, patch, selector);
    }

    function linkDockedOrder(bytes32 localOrderId, DockedOrderLink calldata link) external {
        _linkDockedOrder(localOrderId, link, msg.sender);
    }

    function linkDockedOrderFor(
        bytes32 localOrderId,
        DockedOrderLink calldata link,
        address selector,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredDockedOrderLinkSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        address recoveredSigner =
            _recoverDockedOrderLinkSelector(dockedOrderLinkDigest(localOrderId, link, selector, deadline), signature);
        if (recoveredSigner != selector) {
            revert InvalidDockedOrderLinkSignature(selector, recoveredSigner);
        }

        _linkDockedOrder(localOrderId, link, selector);
    }

    function submitDockedSignal(
        bytes32 localOrderId,
        bytes32 linkedOrderId,
        bytes32 linkedSourceId,
        bytes32 linkedSignalId,
        bytes32 idempotencyKey
    ) external {
        ActiveDockedOrderLink storage dockedLink = _activeDockedOrderLinks[localOrderId][linkedOrderId];
        if (!dockedLink.exists) {
            revert UnknownDockedOrderLink(localOrderId, linkedOrderId);
        }

        SignalRecord storage linkedSignal = _signals[linkedOrderId][signalKey(linkedSourceId, linkedSignalId)];
        if (!linkedSignal.exists) {
            revert DockedSignalBindingNotFound(localOrderId, linkedOrderId, linkedSourceId, linkedSignalId);
        }

        ActiveDockedSignalBinding storage binding =
            _activeDockedSignalBindings[localOrderId][linkedOrderId][signalKey(linkedSourceId, linkedSignalId)];
        if (!binding.exists) {
            revert DockedSignalBindingNotFound(localOrderId, linkedOrderId, linkedSourceId, linkedSignalId);
        }

        _recordSignal(
            localOrderId,
            binding.localSourceId,
            binding.localSignalId,
            linkedSignal.payloadHash,
            idempotencyKey,
            linkedSignal.submitter
        );
        emit DockedSignalSubmitted(
            localOrderId,
            linkedOrderId,
            linkedSourceId,
            linkedSignalId,
            binding.localSourceId,
            binding.localSignalId,
            linkedSignal.payloadHash,
            linkedSignal.submitter
        );
    }

    function _applyStageExecutorPatch(bytes32 orderId, StageExecutorPatch calldata patch, address selector) private {
        _applyStageExecutorPatch(orderId, patch, selector, address(0));
    }

    function _applyStageExecutorPatch(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        address previousExecutorSigner
    ) private {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (patch.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        if (!_isStageExecutorPatchMode(patch.mode)) {
            revert InvalidStageExecutorPatchMode(patch.mode);
        }

        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        Plan storage plan = _plans[order.planId];
        _requireOfficialPlanActive(order.planId, plan.planHash);

        if (!isStageSelectorBound(order.planId, patch.selectorStageId, patch.targetStageId)) {
            revert StageSelectorBindingNotFound(order.planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!_hasExplicitSignalAuthorization(orderId, patch.selectorStageId, EXECUTOR_PATCH_SIGNAL_ID, selector)) {
            revert UnauthorizedStageExecutorPatchSelector(orderId, patch.selectorStageId, selector);
        }

        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[orderId][patch.targetStageId];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, patch.targetStageId, activePatch.patchNonce, patch.patchNonce
            );
        }
        _validateStageExecutorPatchMode(orderId, patch, activePatch, previousExecutorSigner);

        _activateStageExecutorPatch(orderId, patch, selector, activePatch);
    }

    function _activateStageExecutorPatch(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        ActiveStageExecutorPatch storage activePatch
    ) private {
        activePatch.executor = patch.executor;
        activePatch.role = patch.role;
        activePatch.executorMetadataHash = patch.executorMetadataHash;
        activePatch.patchHash = patch.patchHash;
        activePatch.patchNonce = patch.patchNonce;
        activePatch.metadataURI = patch.metadataURI;
        activePatch.exists = true;

        _emitStageExecutorPatchApplied(orderId, patch, selector);
        emit StageExecutorActivated(
            orderId, patch.targetStageId, patch.executor, patch.role, patch.executorMetadataHash, patch.patchNonce
        );
    }

    function _linkDockedOrder(bytes32 localOrderId, DockedOrderLink calldata link, address selector) private {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (link.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (link.localSourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (link.linkedOrderId == bytes32(0)) {
            revert ZeroLinkedOrderId();
        }
        if (link.linkedPlanId == bytes32(0)) {
            revert ZeroLinkedPlanId();
        }
        if (link.linkHash == bytes32(0)) {
            revert ZeroLinkHash();
        }

        Order storage localOrder = _orders[localOrderId];
        if (!localOrder.exists) {
            revert UnknownOrder();
        }
        Order storage linkedOrder = _orders[link.linkedOrderId];
        if (!linkedOrder.exists) {
            revert UnknownLinkedOrder(link.linkedOrderId);
        }
        if (linkedOrder.planId != link.linkedPlanId) {
            revert UnknownLinkedOrder(link.linkedOrderId);
        }

        Plan storage localPlan = _plans[localOrder.planId];
        _requireOfficialPlanActive(localOrder.planId, localPlan.planHash);
        Plan storage linkedPlan = _plans[linkedOrder.planId];
        _requireOfficialPlanActive(linkedOrder.planId, linkedPlan.planHash);

        if (!isStageSelectorBound(localOrder.planId, link.selectorStageId, link.localSourceId)) {
            revert StageSelectorBindingNotFound(localOrder.planId, link.selectorStageId, link.localSourceId);
        }
        if (!_hasExplicitSignalAuthorization(localOrderId, link.selectorStageId, DOCKED_ORDER_LINK_SIGNAL_ID, selector))
        {
            revert UnauthorizedDockedOrderLinkSelector(localOrderId, link.selectorStageId, selector);
        }

        ActiveDockedOrderLink storage activeLink = _activeDockedOrderLinks[localOrderId][link.linkedOrderId];
        if (link.linkNonce <= activeLink.linkNonce) {
            revert DockedOrderLinkNonceNotIncreasing(
                localOrderId, link.linkedOrderId, activeLink.linkNonce, link.linkNonce
            );
        }

        activeLink.selectorStageId = link.selectorStageId;
        activeLink.localSourceId = link.localSourceId;
        activeLink.linkedPlanId = link.linkedPlanId;
        activeLink.selector = selector;
        activeLink.linkHash = link.linkHash;
        activeLink.linkNonce = link.linkNonce;
        activeLink.metadataURI = link.metadataURI;
        activeLink.exists = true;

        emit DockedOrderLinked(
            localOrderId,
            link.linkedOrderId,
            link.localSourceId,
            link.selectorStageId,
            link.linkedPlanId,
            selector,
            link.linkHash,
            link.linkNonce,
            link.metadataURI
        );

        for (uint256 i = 0; i < link.signalBindings.length; i++) {
            DockedSignalBinding calldata binding = link.signalBindings[i];
            _activateDockedSignalBinding(localOrderId, link.linkedOrderId, binding);
        }
    }

    function _activateDockedSignalBinding(
        bytes32 localOrderId,
        bytes32 linkedOrderId,
        DockedSignalBinding calldata binding
    ) private {
        if (binding.localSourceId == bytes32(0) || binding.linkedSourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (binding.localSignalId == bytes32(0) || binding.linkedSignalId == bytes32(0)) {
            revert ZeroSignalId();
        }

        bytes32 linkedSignalKey = signalKey(binding.linkedSourceId, binding.linkedSignalId);
        ActiveDockedSignalBinding storage activeBinding =
            _activeDockedSignalBindings[localOrderId][linkedOrderId][linkedSignalKey];

        activeBinding.localSourceId = binding.localSourceId;
        activeBinding.localSignalId = binding.localSignalId;
        activeBinding.exists = true;

        emit DockedSignalMapped(
            localOrderId,
            linkedOrderId,
            binding.linkedSourceId,
            binding.linkedSignalId,
            binding.localSourceId,
            binding.localSignalId
        );
    }

    function _applyStageResourcePatch(bytes32 orderId, StageResourcePatch calldata patch, address selector) private {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.resourceKey == bytes32(0)) {
            revert ZeroResourceKey();
        }
        if (patch.manifestHash == bytes32(0)) {
            revert ZeroManifestHash();
        }
        if (patch.policyHash == bytes32(0)) {
            revert ZeroPolicyHash();
        }
        if (patch.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }

        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }

        Plan storage plan = _plans[order.planId];
        _requireOfficialPlanActive(order.planId, plan.planHash);

        if (!isStageSelectorBound(order.planId, patch.selectorStageId, patch.targetStageId)) {
            revert StageSelectorBindingNotFound(order.planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!_hasExplicitSignalAuthorization(orderId, patch.selectorStageId, RESOURCE_PATCH_SIGNAL_ID, selector)) {
            revert UnauthorizedStageResourcePatchSelector(orderId, patch.selectorStageId, selector);
        }
        if (sourceSignalCount[orderId][patch.targetStageId] != 0) {
            revert StageAlreadyHasSignal(orderId, patch.targetStageId);
        }

        ActiveStageResourcePatch storage activePatch =
            _activeStageResourcePatches[orderId][patch.targetStageId][patch.resourceKey];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageResourcePatchNonceNotIncreasing(
                orderId, patch.targetStageId, patch.resourceKey, activePatch.patchNonce, patch.patchNonce
            );
        }

        activePatch.manifestHash = patch.manifestHash;
        activePatch.policyHash = patch.policyHash;
        activePatch.patchHash = patch.patchHash;
        activePatch.patchNonce = patch.patchNonce;
        activePatch.manifestURI = patch.manifestURI;
        activePatch.exists = true;

        emit StageResourcePatchApplied(
            orderId,
            patch.selectorStageId,
            patch.targetStageId,
            selector,
            patch.resourceKey,
            patch.manifestHash,
            patch.policyHash,
            patch.patchHash,
            patch.patchNonce,
            patch.manifestURI
        );
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

        _requireActiveStageExecutor(orderId, sourceId, submitter);
        if (!_isSignalSubmitterAuthorized(orderId, sourceId, signalId, submitter)) {
            revert UnauthorizedSignalSubmitter(orderId, sourceId, signalId, submitter);
        }

        _recordSignal(orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter);
    }

    function _recordSignal(
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) private {
        Order storage order = _orders[orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        bytes32 key = signalKey(sourceId, signalId);
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
        _evaluateAffectedHooks(orderId, order.planId, key);
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
        _evaluateHook(orderId, order.planId, hookId);
    }

    function planExists(bytes32 planId) external view returns (bool) {
        return _plans[planId].exists;
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

    function orderRegistrar(bytes32 orderId) external view returns (address) {
        return _orders[orderId].registrar;
    }

    function orderCreator(bytes32 orderId) external view returns (address) {
        return _orders[orderId].creator;
    }

    function planHookCount(bytes32 planId) external view returns (uint256) {
        Plan storage plan = _plans[planId];
        if (!plan.exists) {
            revert UnknownPlan();
        }
        return plan.hookIds.length;
    }

    function planHookIdAt(bytes32 planId, uint256 index) external view returns (bytes32) {
        Plan storage plan = _plans[planId];
        if (!plan.exists) {
            revert UnknownPlan();
        }
        return plan.hookIds[index];
    }

    function planDependencyHookCount(bytes32 planId, bytes32 dependencyKey) external view returns (uint256) {
        Plan storage plan = _plans[planId];
        if (!plan.exists) {
            revert UnknownPlan();
        }
        return plan.dependencyIndex[dependencyKey].length;
    }

    function planSelectorBindingCount(bytes32 planId) external view returns (uint256) {
        Plan storage plan = _plans[planId];
        if (!plan.exists) {
            revert UnknownPlan();
        }
        return plan.selectorBindingKeys.length;
    }

    function planSelectorBindingAt(bytes32 planId, uint256 index)
        external
        view
        returns (bytes32 selectorStageId, bytes32 targetStageId)
    {
        Plan storage plan = _plans[planId];
        if (!plan.exists) {
            revert UnknownPlan();
        }
        StageSelectorBinding storage binding = plan.selectorBindings[plan.selectorBindingKeys[index]];
        return (binding.selectorStageId, binding.targetStageId);
    }

    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        public
        view
        returns (bool)
    {
        Plan storage plan = _plans[planId];
        if (!plan.exists) {
            revert UnknownPlan();
        }
        return
            plan.selectorBindings[stageSelectorBindingKey(selectorStageId, targetStageId)].selectorStageId != bytes32(0);
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
        SignalRecord storage signal = _signals[orderId][signalKey(sourceId, signalId)];
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

    function getSignalAuthorization(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        external
        view
        returns (bool exists, bytes32 role, bytes32 metadataHash)
    {
        StoredSignalAuthorization storage authorization =
            _signalAuthorizations[orderId][signalKey(sourceId, signalId)][submitter];
        return (authorization.exists, authorization.role, authorization.metadataHash);
    }

    function activeStageExecutor(bytes32 orderId, bytes32 targetStageId) external view returns (address) {
        return _activeStageExecutorPatches[orderId][targetStageId].executor;
    }

    function orderStageExecutorPatchNonce(bytes32 orderId, bytes32 targetStageId) external view returns (uint256) {
        return _activeStageExecutorPatches[orderId][targetStageId].patchNonce;
    }

    function getActiveStageExecutorPatch(bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        )
    {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[orderId][targetStageId];
        return (
            activePatch.exists,
            activePatch.executor,
            activePatch.role,
            activePatch.executorMetadataHash,
            activePatch.patchHash,
            activePatch.patchNonce,
            activePatch.metadataURI
        );
    }

    function orderStageResourcePatchNonce(bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (uint256)
    {
        return _activeStageResourcePatches[orderId][targetStageId][resourceKey].patchNonce;
    }

    function getActiveStageResourcePatch(bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (
            bool exists,
            bytes32 manifestHash,
            bytes32 policyHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory manifestURI
        )
    {
        ActiveStageResourcePatch storage activePatch = _activeStageResourcePatches[orderId][targetStageId][resourceKey];
        return (
            activePatch.exists,
            activePatch.manifestHash,
            activePatch.policyHash,
            activePatch.patchHash,
            activePatch.patchNonce,
            activePatch.manifestURI
        );
    }

    function orderDockedOrderLinkNonce(bytes32 localOrderId, bytes32 linkedOrderId) external view returns (uint256) {
        return _activeDockedOrderLinks[localOrderId][linkedOrderId].linkNonce;
    }

    function getActiveDockedOrderLink(bytes32 localOrderId, bytes32 linkedOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 selectorStageId,
            bytes32 localSourceId,
            bytes32 linkedPlanId,
            address selector,
            bytes32 linkHash,
            uint256 linkNonce,
            string memory metadataURI
        )
    {
        ActiveDockedOrderLink storage activeLink = _activeDockedOrderLinks[localOrderId][linkedOrderId];
        return (
            activeLink.exists,
            activeLink.selectorStageId,
            activeLink.localSourceId,
            activeLink.linkedPlanId,
            activeLink.selector,
            activeLink.linkHash,
            activeLink.linkNonce,
            activeLink.metadataURI
        );
    }

    function getActiveDockedSignalBinding(
        bytes32 localOrderId,
        bytes32 linkedOrderId,
        bytes32 linkedSourceId,
        bytes32 linkedSignalId
    ) external view returns (bool exists, bytes32 localSourceId, bytes32 localSignalId) {
        ActiveDockedSignalBinding storage binding =
            _activeDockedSignalBindings[localOrderId][linkedOrderId][signalKey(linkedSourceId, linkedSignalId)];
        return (binding.exists, binding.localSourceId, binding.localSignalId);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function signalSubmissionDigest(
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline
    ) public view returns (bytes32) {
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

    function stageExecutorPatchDigest(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01", DOMAIN_SEPARATOR(), _stageExecutorPatchStructHash(orderId, patch, selector, deadline)
            )
        );
    }

    function stageResourcePatchDigest(
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _STAGE_RESOURCE_PATCH_TYPEHASH,
                orderId,
                patch.selectorStageId,
                patch.targetStageId,
                patch.resourceKey,
                patch.manifestHash,
                patch.policyHash,
                patch.patchHash,
                patch.patchNonce,
                keccak256(bytes(patch.manifestURI)),
                selector,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function dockedOrderLinkDigest(
        bytes32 localOrderId,
        DockedOrderLink calldata link,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _DOCKED_ORDER_LINK_TYPEHASH,
                localOrderId,
                link.selectorStageId,
                link.localSourceId,
                link.linkedOrderId,
                link.linkedPlanId,
                link.linkHash,
                link.linkNonce,
                _dockedSignalBindingsHash(link.signalBindings),
                keccak256(bytes(link.metadataURI)),
                selector,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function signalKey(bytes32 sourceId, bytes32 signalId) public pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function stageSelectorBindingKey(bytes32 selectorStageId, bytes32 targetStageId) public pure returns (bytes32) {
        return keccak256(abi.encode(selectorStageId, targetStageId));
    }

    function _requireOfficialPlanActive(bytes32 planId, bytes32 planHash) private view {
        if (trustRegistry.isPlanRevoked(officialDomainId, planId)) {
            revert OfficialPlanRevoked();
        }
        if (!trustRegistry.isPlanActive(officialDomainId, planId, planHash)) {
            revert OfficialPlanNotActive();
        }
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
            } else if (instruction.op == InstructionOp.And || instruction.op == InstructionOp.Or) {
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

    function _evaluateAffectedHooks(bytes32 orderId, bytes32 planId, bytes32 dependencyKey) private {
        Plan storage plan = _plans[planId];
        bytes32[] storage hookIds = plan.dependencyIndex[dependencyKey];
        for (uint256 i = 0; i < hookIds.length; i++) {
            _evaluateHook(orderId, planId, hookIds[i]);
        }
    }

    function _evaluateHook(bytes32 orderId, bytes32 planId, bytes32 hookId) private {
        Plan storage plan = _plans[planId];
        StoredHook storage hook = plan.hooks[hookId];
        if (!hook.exists) {
            revert UnknownHook();
        }

        Order storage order = _orders[orderId];
        HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            revert UnknownHook();
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

        if (nextStatus == HookStatus.Ready && hook.trigger && !runtime.readyEmitted) {
            runtime.readyEmitted = true;
            emit HookReady(orderId, hookId, hook.stageId, hook.hookName);
        }
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
            }
        }
        return stack[0];
    }

    function _signalValue(bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (EvalValue memory)
    {
        SignalRecord storage signal = _signals[orderId][signalKey(sourceId, signalId)];
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
        return EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: value.anchorAt});
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
                dueAt: 0,
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
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

    function _orValue(EvalValue memory left, EvalValue memory right) private pure returns (EvalValue memory) {
        if (left.value || right.value) {
            return EvalValue({
                value: true,
                wait: false,
                cancel: false,
                dueAt: 0,
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if (left.wait || right.wait) {
            return EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: _minDue(left.dueAt, right.dueAt),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if (left.cancel && right.cancel) {
            return EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        return EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _hasSignal(bytes32 orderId, bytes32 sourceId, bytes32 signalId) private view returns (bool) {
        return _signals[orderId][signalKey(sourceId, signalId)].exists;
    }

    function _dockedSignalBindingsHash(DockedSignalBinding[] calldata bindings) private pure returns (bytes32) {
        bytes32 rollingHash = keccak256(abi.encode(bindings.length));
        for (uint256 i = 0; i < bindings.length; i++) {
            DockedSignalBinding calldata binding = bindings[i];
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    binding.localSourceId,
                    binding.localSignalId,
                    binding.linkedSourceId,
                    binding.linkedSignalId
                )
            );
        }
        return rollingHash;
    }

    function _stageExecutorPatchStructHash(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) private pure returns (bytes32) {
        bytes memory encoded = new bytes(0x200);
        _writeWord(encoded, 0x00, _STAGE_EXECUTOR_PATCH_TYPEHASH);
        _writeWord(encoded, 0x20, orderId);
        _writeWord(encoded, 0x40, patch.selectorStageId);
        _writeWord(encoded, 0x60, patch.targetStageId);
        _writeAddress(encoded, 0x80, patch.executor);
        _writeWord(encoded, 0xa0, patch.role);
        _writeWord(encoded, 0xc0, patch.executorMetadataHash);
        _writeWord(encoded, 0xe0, patch.mode);
        _writeAddress(encoded, 0x100, patch.previousExecutor);
        _writeWord(encoded, 0x120, patch.approvalSourceId);
        _writeWord(encoded, 0x140, patch.approvalSignalId);
        _writeWord(encoded, 0x160, patch.patchHash);
        _writeWord(encoded, 0x180, bytes32(patch.patchNonce));
        _writeWord(encoded, 0x1a0, keccak256(bytes(patch.metadataURI)));
        _writeAddress(encoded, 0x1c0, selector);
        _writeWord(encoded, 0x1e0, bytes32(deadline));
        return keccak256(encoded);
    }

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _emitStageExecutorPatchApplied(bytes32 orderId, StageExecutorPatch calldata patch, address selector)
        private
    {
        bytes memory metadataURI = bytes(patch.metadataURI);
        bytes memory eventData = new bytes(0x180 + _paddedLength(metadataURI.length));
        _writeAddress(eventData, 0x00, selector);
        _writeAddress(eventData, 0x20, patch.executor);
        _writeWord(eventData, 0x40, patch.role);
        _writeWord(eventData, 0x60, patch.executorMetadataHash);
        _writeWord(eventData, 0x80, patch.mode);
        _writeAddress(eventData, 0xa0, patch.previousExecutor);
        _writeWord(eventData, 0xc0, patch.approvalSourceId);
        _writeWord(eventData, 0xe0, patch.approvalSignalId);
        _writeWord(eventData, 0x100, patch.patchHash);
        _writeWord(eventData, 0x120, bytes32(patch.patchNonce));
        _writeWord(eventData, 0x140, bytes32(uint256(0x160)));
        _writeWord(eventData, 0x160, bytes32(metadataURI.length));
        _copyBytes(eventData, 0x180, metadataURI);

        bytes32 selectorStageId = patch.selectorStageId;
        bytes32 targetStageId = patch.targetStageId;
        bytes32 topic = _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC;
        assembly {
            log4(add(eventData, 0x20), mload(eventData), topic, orderId, selectorStageId, targetStageId)
        }
    }

    function _copyBytes(bytes memory target, uint256 offset, bytes memory source) private pure {
        for (uint256 i = 0; i < source.length; i++) {
            target[offset + i] = source[i];
        }
    }

    function _paddedLength(uint256 length) private pure returns (uint256) {
        return (length + 31) & ~uint256(31);
    }

    function _validateStageExecutorPatchMode(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        ActiveStageExecutorPatch storage activePatch,
        address previousExecutorSigner
    ) private view {
        uint256 signalCount = sourceSignalCount[orderId][patch.targetStageId];
        if (patch.mode == EXECUTOR_PATCH_MODE_ASSIGN) {
            if (patch.previousExecutor != address(0)) {
                revert StageExecutorPatchPreviousExecutorMismatch(
                    orderId, patch.targetStageId, address(0), patch.previousExecutor
                );
            }
            if (patch.approvalSourceId != bytes32(0) || patch.approvalSignalId != bytes32(0)) {
                revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
            }
            if (signalCount != 0) {
                revert StageAlreadyHasSignal(orderId, patch.targetStageId);
            }
            return;
        }

        if (signalCount == 0) {
            revert StageHasNoSignal(orderId, patch.targetStageId);
        }

        address expectedPreviousExecutor =
            activePatch.exists ? activePatch.executor : lastSignalSubmitter[orderId][patch.targetStageId];
        if (patch.previousExecutor != expectedPreviousExecutor) {
            revert StageExecutorPatchPreviousExecutorMismatch(
                orderId, patch.targetStageId, expectedPreviousExecutor, patch.previousExecutor
            );
        }

        if (patch.mode == EXECUTOR_PATCH_MODE_HANDOFF) {
            if (patch.approvalSourceId != bytes32(0) || patch.approvalSignalId != bytes32(0)) {
                revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
            }
            if (previousExecutorSigner != patch.previousExecutor) {
                revert InvalidStageExecutorPatchSignature(patch.previousExecutor, previousExecutorSigner);
            }
            return;
        }

        if (!_hasSignal(orderId, patch.approvalSourceId, patch.approvalSignalId)) {
            revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
        }
    }

    function _isStageExecutorPatchMode(bytes32 mode) private pure returns (bool) {
        return mode == EXECUTOR_PATCH_MODE_ASSIGN || mode == EXECUTOR_PATCH_MODE_HANDOFF
            || mode == EXECUTOR_PATCH_MODE_REPLACEMENT;
    }

    function _isSignalSubmitterAuthorized(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter)
        private
        view
        returns (bool)
    {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[orderId][sourceId];
        if (activePatch.exists) {
            return submitter == activePatch.executor;
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
        return _signalAuthorizations[orderId][signalKey(sourceId, signalId)][submitter].exists;
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

    function _recoverStageExecutorPatchSigner(bytes32 digest, bytes calldata signature)
        private
        pure
        returns (address)
    {
        if (signature.length != 65) {
            revert InvalidStageExecutorPatchSignatureLength(signature.length);
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

    function _recoverStageResourcePatchSelector(bytes32 digest, bytes calldata signature)
        private
        pure
        returns (address)
    {
        if (signature.length != 65) {
            revert InvalidStageResourcePatchSignatureLength(signature.length);
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

    function _recoverDockedOrderLinkSelector(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidDockedOrderLinkSignatureLength(signature.length);
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
}
