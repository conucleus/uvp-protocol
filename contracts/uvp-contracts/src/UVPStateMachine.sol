// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {IUVPSupplierRegistry} from "./interfaces/IUVPSupplierRegistry.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPFileResourceModule, FilePatch, FilePatchEmpty} from "./interfaces/IUVPFileResourceModule.sol";
import {UVPPlanRegistration} from "./UVPPlanRegistration.sol";
import {
    _HOOK_FLAG_ORDER_TRIGGER_MINT,
    _HOOK_FLAG_EMIT_READY,
    _HOOK_FLAG_ADMISSION,
    _HOOK_FLAG_DOCK_EXECUTOR,
    _HOOK_FLAG_DYNAMIC_EXECUTOR,
    _MAX_HOOK_DELAY_SECONDS,
    _MAX_PLAN_DEPENDENCIES,
    _MAX_SUPPLIER_BINDINGS,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN,
    _FACT_ATTRIBUTION_TYPEHASH,
    _SIGNAL_SUBMISSION_TYPEHASH,
    _FORK_ORDER_ID_DOMAIN,
    _ORDER_LINK_ORDER_ID_DOMAIN
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

    struct TriggerOrderFromOutsideByAuthorizerRequest {
        bytes32 planId;
        address creator;
        bytes32 triggerHookId;
        bytes32 triggerStageId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
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
        bytes32 supplierBindingsRoot;
        address birthAuthorizer;
        uint256 deadline;
    }

    struct StageSupplierBinding {
        bytes32 stageId;
        bytes32 supplierId;
        uint8 kind;
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
        bytes32 supplierBindingsRoot;
        address publisher;
        address birthAuthorizer;
        bytes32[] hookIds;
        mapping(bytes32 stageId => bytes32[] hookIds) stageHookIds;
        mapping(bytes32 hookId => StoredHook hook) hooks;
        mapping(bytes32 signalKey => bytes32[] hookIds) dependencyIndex;
        mapping(bytes32 signalKey => StoredAdmission admission) admissions;
        mapping(bytes32 stageId => bool exists) stageExists;
        mapping(bytes32 stageId => bytes32 supplierId) stageDefaultSuppliers;
        mapping(bytes32 stageId => bool) stageCandidateStages;
        mapping(bytes32 stageId => bool) dynamicSupplierStages;
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

    struct StageSupplierAssignment {
        bytes32 supplierId;
        uint256 patchNonce;
        bytes32 dockId;
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
    error HookDependencyKeyMismatch(bytes32 hookId);
    error TooManyDependencies();
    error TooManyHooksPerDependencyKey(bytes32 signalKey);
    error InvalidSignalSignatureLength(uint256 length);
    error InvalidSignalCapability(bytes32 planId, bytes32 sourceId, bytes32 signalId);
    error InvalidFactAttribution(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 claimedStageId);
    error InvalidInstruction();
    error InvalidHook();
    error InvalidModuleAddress();
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
    error SupplierBindingsRootMismatch(bytes32 expectedRoot, bytes32 actualRoot);
    error PlanNotCommitted();
    error PlanNotFinalized();
    error SignalAlreadyExists();
    error SignalAdmissionRejected(bytes32 orderId, bytes32 sourceId, bytes32 signalId);
    error AdmissionAlreadyRegistered(bytes32 signalKey);
    error SilentOrderTriggerHook(bytes32 hookId);
    error StageSupplierNotAssigned(bytes32 orderId, bytes32 targetStageId);
    error StageNotMaterializable(bytes32 stageId);
    error StageSupplierPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error TimerNotDue();
    error TimerNotWaiting();
    error UnauthorizedTriggerOrigin(bytes32 originPlanId, bytes32 originOrderId, address submitter);
    error UnauthorizedStateMachineModule(address caller);
    error UnauthorizedStageSupplierAccount(
        bytes32 orderId, bytes32 targetStageId, address submitter, address expectedAccount
    );
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
    error ZeroOwner();
    error ZeroPlanPublisher();
    error ZeroSignalId();
    error ZeroSourceId();
    error BirthAuthorizerNotContract(address authorizer);
    error UnauthorizedBirthSubmitter(address submitter);
    error ZeroSubmitter();
    error ZeroTargetStageId();
    error ZeroSupplierId();
    error ZeroDockId();
    error SupplierRegistryNotConfigured();
    error SupplierNotActive(bytes32 supplierId);
    error SignalStageUnknown(bytes32 planId, bytes32 sourceId, bytes32 signalId);
    error InvalidSignalSubmitterSignature(address expectedSigner, address recoveredSigner);
    error InvalidEIP1271Signature(address submitter);
    error TooManySupplierBindings(uint256 count);
    error DuplicateSupplierBinding(bytes32 stageId, bytes32 supplierId, uint8 kind);
    error UnknownPlanStage(bytes32 stageId);
    error InvalidSupplierBindingKind(uint8 kind);
    error SupplierBindingForbiddenForStage(bytes32 stageId);
    error CandidateSupplierBindingForbiddenForStage(bytes32 stageId);
    error CandidateSupplierBindingRequiresDefault(bytes32 stageId);
    error InconsistentDynamicSupplierFlag(bytes32 stageId);

    address public owner;
    address public stagePatchModule;
    address public derivedSignalModule;
    address public dockRegistry;
    address public fileResourceModule;

    function planMetadataModule() external view returns (address) {
        return _s.planMetadataModule;
    }

    function supplierRegistry() external view returns (address) {
        return _s.supplierRegistry;
    }

    address public orderLinkModule;
    address public lens;
    bool public modulesFrozen;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_MINT = _HOOK_FLAG_ORDER_TRIGGER_MINT;
    uint8 public constant HOOK_FLAG_DOCK_EXECUTOR = _HOOK_FLAG_DOCK_EXECUTOR;
    uint8 public constant HOOK_FLAG_EMIT_READY = _HOOK_FLAG_EMIT_READY;
    uint8 public constant HOOK_FLAG_ADMISSION = _HOOK_FLAG_ADMISSION;
    uint8 public constant HOOK_FLAG_DYNAMIC_EXECUTOR = _HOOK_FLAG_DYNAMIC_EXECUTOR;
    uint64 public constant MAX_HOOK_DELAY_SECONDS = _MAX_HOOK_DELAY_SECONDS;
    uint256 public constant MAX_PLAN_DEPENDENCIES = _MAX_PLAN_DEPENDENCIES;
    uint256 public constant MAX_SUPPLIER_BINDINGS = _MAX_SUPPLIER_BINDINGS;
    uint256 public constant MAX_FORK_BIRTH_FACTS = 256;

    bytes32 private constant _ORDER_ID_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes4 private constant _EIP1271_MAGIC_VALUE = 0x1626ba7e;

    struct SMState {
        mapping(bytes32 => Plan) plans;
        mapping(bytes32 => mapping(bytes32 => Order)) orders;
        mapping(bytes32 => mapping(bytes32 => mapping(bytes32 => SignalRecord))) signals;
        mapping(
            bytes32 planId
                => mapping(bytes32 orderId => mapping(bytes32 targetStageId => StageSupplierAssignment patch))
        ) stageSupplierAssignments;
        mapping(
            bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 sourceId => SourceSignalAccount account))
        ) sourceSignalAccounts;
        mapping(
            bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 stageId => StageSignalAccount account))
        ) stageSignalAccounts;
        address planMetadataModule;
        address supplierRegistry;
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
        bytes32 supplierBindingsRoot,
        address birthAuthorizer
    );
    event PlanFinalized(bytes32 indexed planId, bytes32 indexed planHash, bytes32 capabilitiesRoot);
    event PlanRegistered(bytes32 indexed planId, bytes32 planHash, uint256 hookCount);
    event PlanPublisherRecorded(bytes32 indexed planId, address indexed publisher);
    event OrderRegistered(bytes32 indexed orderId, bytes32 indexed planId);
    event OrderMaterialized(bytes32 indexed orderId, bytes32 indexed planId, bytes32 indexed stageId);
    event OrderRelayerRecorded(bytes32 indexed planId, bytes32 orderId, address indexed relayer, address creator);
    event SignalSubmitted(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        address relayer,
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
    event StageSupplierAssigned(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 supplierId,
        uint256 patchNonce
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
    bytes32 public constant DOCK_REGISTRY_MODULE_ID = keccak256("uvp.module.dock_registry.v1");
    bytes32 public constant PLAN_METADATA_MODULE_ID = keccak256("uvp.module.plan_metadata.v1");
    bytes32 public constant ORDER_LINK_MODULE_ID = keccak256("uvp.module.order_link.v1");
    bytes32 public constant LENS_MODULE_ID = keccak256("uvp.module.lens.v1");
    bytes32 public constant FILE_RESOURCE_MODULE_ID = keccak256("uvp.module.file_resource.v1");
    bytes32 public constant SUPPLIER_REGISTRY_MODULE_ID = keccak256("uvp.module.supplier_registry.v1");

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

    function setDockRegistry(address moduleAddress) external onlyOwner {
        dockRegistry = _setModule(DOCK_REGISTRY_MODULE_ID, dockRegistry, moduleAddress);
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

    function setFileResourceModule(address moduleAddress) external onlyOwner {
        fileResourceModule = _setModule(FILE_RESOURCE_MODULE_ID, fileResourceModule, moduleAddress);
    }

    function setSupplierRegistry(address moduleAddress) external onlyOwner {
        _s.supplierRegistry = _setModule(SUPPLIER_REGISTRY_MODULE_ID, _s.supplierRegistry, moduleAddress);
    }

    function freezeModules() external onlyOwner {
        if (modulesFrozen) {
            revert ModulesAlreadyFrozen();
        }
        if (
            stagePatchModule == address(0) || derivedSignalModule == address(0) || dockRegistry == address(0)
                || _s.planMetadataModule == address(0) || orderLinkModule == address(0) || lens == address(0)
                || fileResourceModule == address(0) || _s.supplierRegistry == address(0)
        ) {
            revert IncompleteModuleConfiguration();
        }

        modulesFrozen = true;
        emit StateMachineModulesFrozen(moduleSetHash());
    }

    function moduleSetHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                stagePatchModule,
                derivedSignalModule,
                dockRegistry,
                _s.planMetadataModule,
                orderLinkModule,
                lens,
                fileResourceModule,
                _s.supplierRegistry
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
        StageSupplierBinding[] calldata bindings,
        bytes calldata signature
    ) external returns (bytes32 planId) {
        planId = UVPPlanRegistration.commitPlan(
            _s.plans, modulesFrozen, _s.supplierRegistry, commit, hooks, bindings, signature
        );
    }

    function finalizePlan(bytes32 planId) external {
        UVPPlanRegistration.finalizePlan(_s.plans, _s.planMetadataModule, planId);
    }

    function planRuntimeHash(bytes32 hooksHash, bytes32 capabilitiesRoot, bytes32 supplierBindingsRoot)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_PLAN_RUNTIME_HASH_DOMAIN, hooksHash, capabilitiesRoot, supplierBindingsRoot));
    }

    function planIdFor(address publisher, bytes32 runtimePlanHash) public pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_ID_HASH_DOMAIN, publisher, runtimePlanHash));
    }

    function triggerOrderFromOutsideFor(
        TriggerOrderFromOutsideRequest calldata trigger,
        bytes calldata signature,
        FactAttribution calldata birthFactAttribution
    ) external {
        UVPPlanRegistration.triggerOrderFromOutside(_s, trigger, signature, birthFactAttribution);
    }

    function triggerOrderFromOutsideByAuthorizer(
        TriggerOrderFromOutsideByAuthorizerRequest calldata trigger,
        FactAttribution calldata birthFactAttribution
    ) external {
        UVPPlanRegistration.triggerOrderFromOutsideByAuthorizer(_s, trigger, birthFactAttribution);
    }

    function triggerOrderIdFor(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 payloadHash)
        public
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(keccak256(abi.encode(planId, sourceId, signalId, payloadHash)))
                & ~uint256(_ORDER_ID_NAMESPACE_MASK)
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
            ) & ~uint256(_ORDER_ID_NAMESPACE_MASK)
        );
    }

    function forkOrderIdFor(bytes32 planId, bytes32 parentOrderId, bytes32 forkPayloadHash)
        public
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(keccak256(abi.encode(_FORK_ORDER_ID_DOMAIN, planId, parentOrderId, forkPayloadHash)))
                & ~uint256(_ORDER_ID_NAMESPACE_MASK)
        );
    }

    function forkOrder(
        bytes32 planId,
        bytes32 parentOrderId,
        bytes32 forkPayloadHash,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        ForkBirthFact[] calldata birthFacts
    ) external returns (bytes32 forkedOrderId) {
        forkedOrderId = UVPPlanRegistration.forkOrderGate(
            _s, planId, parentOrderId, forkPayloadHash, approvalSourceId, approvalSignalId, birthFacts
        );
        UVPPlanRegistration.forkOrderReplay(_s, planId, parentOrderId, forkedOrderId, birthFacts);
    }

    function triggerOrderFromSignalFromModule(
        TriggerOrderFromSignalRequest calldata trigger,
        address relayer,
        FactAttribution[] calldata originFactAttributions
    ) external {
        if (msg.sender != orderLinkModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        UVPPlanRegistration.triggerOrderFromSignal(_s, trigger, relayer, originFactAttributions);
    }

    function submitSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        FactAttribution calldata attribution,
        bytes32 filesDigest,
        FilePatch calldata filePatch
    ) external {
        if (signalId == bytes32(0)) {
            if (filePatch.ops.length == 0) {
                revert FilePatchEmpty();
            }
            _applyFilePatch(planId, orderId, filesDigest, filePatch, msg.sender, bytes32(0));
            return;
        }
        (bool inserted, bytes32 signalStageId) =
            _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, msg.sender, attribution);
        if (!inserted) {
            return;
        }
        if (filePatch.ops.length == 0 && filesDigest == bytes32(0)) {
            return;
        }
        _applyFilePatch(planId, orderId, filesDigest, filePatch, msg.sender, signalStageId);
    }

    function submitSignalFor(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        FactAttribution calldata attribution,
        bytes32 filesDigest,
        FilePatch calldata filePatch,
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
        bytes32 digest = _signalSubmissionDigest(
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, filesDigest, attribution, submitter, deadline
        );
        _verifySubmitterSignature(submitter, digest, signature);

        if (signalId == bytes32(0)) {
            if (filePatch.ops.length == 0) {
                revert FilePatchEmpty();
            }
            _applyFilePatch(planId, orderId, filesDigest, filePatch, submitter, bytes32(0));
            return;
        }
        (bool inserted, bytes32 signalStageId) =
            _submitSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, attribution);
        if (!inserted) {
            return;
        }
        if (filePatch.ops.length == 0 && filesDigest == bytes32(0)) {
            return;
        }
        _applyFilePatch(planId, orderId, filesDigest, filePatch, submitter, signalStageId);
    }

    function activateStageSupplierFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        uint256 patchNonce
    ) external {
        if (msg.sender != stagePatchModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        _activateStageSupplierAssignment(planId, orderId, targetStageId, supplierId, patchNonce, bytes32(0));
    }

    function activateStageDockSupplierFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        bytes32 dockId,
        uint256 patchNonce
    ) external {
        if (msg.sender != stagePatchModule) {
            revert UnauthorizedStateMachineModule(msg.sender);
        }
        if (dockId == bytes32(0)) {
            revert ZeroDockId();
        }
        _activateStageSupplierAssignment(planId, orderId, targetStageId, supplierId, patchNonce, dockId);
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

    function stageHasOrderTriggerHook(bytes32 planId, bytes32 stageId) external view returns (bool) {
        Plan storage plan = _s.plans[planId];
        bytes32[] storage stageHooks = plan.stageHookIds[stageId];
        for (uint256 i = 0; i < stageHooks.length; i++) {
            if (_isOrderTrigger(plan.hooks[stageHooks[i]].flags)) {
                return true;
            }
        }
        return false;
    }

    function stageHasDockExecutorHook(bytes32 planId, bytes32 stageId) external view returns (bool) {
        Plan storage plan = _s.plans[planId];
        bytes32[] storage stageHooks = plan.stageHookIds[stageId];
        for (uint256 i = 0; i < stageHooks.length; i++) {
            if (plan.hooks[stageHooks[i]].flags & HOOK_FLAG_DOCK_EXECUTOR != 0) {
                return true;
            }
        }
        return false;
    }

    function evaluateDockWindow(
        bytes32 planId,
        bytes32 orderId,
        IUVPStateMachineCore.WindowInstruction[] calldata instructions
    ) external view returns (bool satisfied, uint64 dueInSeconds) {
        if (!_s.orders[planId][orderId].exists) {
            return (false, 0);
        }
        Instruction[] memory converted = new Instruction[](instructions.length);
        for (uint256 i = 0; i < instructions.length; i++) {
            IUVPStateMachineCore.WindowInstruction calldata instruction = instructions[i];
            converted[i] = Instruction({
                op: instruction.op,
                sourceId: instruction.sourceId,
                signalId: instruction.signalId,
                arity: instruction.arity,
                delaySeconds: instruction.delaySeconds
            });
        }
        EvalValue memory result = _evaluateMemoryInstructions(planId, orderId, converted);
        satisfied = result.value && !result.wait && !result.cancel;
        if (!satisfied && result.wait && result.dueAt > block.timestamp) {
            dueInSeconds = result.dueAt - uint64(block.timestamp);
        }
    }

    function isSignalAdmissionSatisfied(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (bool)
    {
        if (!_s.orders[planId][orderId].exists) {
            return false;
        }
        return _signalAdmissionSatisfied(planId, orderId, sourceId, signalId);
    }

    function submitDockOutputSignalFromModule(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        FactAttribution calldata attribution
    ) external returns (bool submitted) {
        if (msg.sender != stagePatchModule) {
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
        bytes32 sourceStageId = _resolveSourceStage(planId, sourceId, signalId, attribution);
        if (sourceStageId == bytes32(0)) {
            revert SignalStageUnknown(planId, sourceId, signalId);
        }
        _requireSourceStageReady(planId, orderId, sourceStageId);
        _requireEffectiveSupplier(planId, orderId, sourceStageId, submitter);
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return false;
        }
        if (!_signalAdmissionSatisfied(planId, orderId, sourceId, signalId)) {
            return false;
        }
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
        return true;
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
        if (stageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        _requireEffectiveSupplier(fromPlanId, fromOrderId, stageId, submitter);
        bool currentOrderFact = fromPlanId == planId && fromOrderId == orderId;
        bytes32 sourceStageId = currentOrderFact ? stageId : bytes32(0);
        _requireSourceStageReady(planId, orderId, sourceStageId);
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return;
        }
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
    }

    function _activateStageSupplierAssignment(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        uint256 patchNonce,
        bytes32 dockId
    ) private {
        if (supplierId == bytes32(0)) {
            revert ZeroSupplierId();
        }
        if (targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UnknownOrder();
        }
        if (!_isPlanStage(planId, targetStageId)) {
            revert UnknownPlanStage(targetStageId);
        }
        StageSupplierAssignment storage assignment = _s.stageSupplierAssignments[planId][orderId][targetStageId];
        if (patchNonce <= assignment.patchNonce) {
            revert StageSupplierPatchNonceNotIncreasing(orderId, targetStageId, assignment.patchNonce, patchNonce);
        }
        assignment.supplierId = supplierId;
        assignment.patchNonce = patchNonce;
        assignment.dockId = dockId;
        emit StageSupplierAssigned(planId, orderId, targetStageId, supplierId, patchNonce);
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
    ) private returns (bool inserted, bytes32 sourceStageId) {
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
        sourceStageId = _resolveSourceStage(planId, sourceId, signalId, attribution);
        if (sourceStageId == bytes32(0)) {
            revert SignalStageUnknown(planId, sourceId, signalId);
        }
        _requireSourceStageReady(planId, orderId, sourceStageId);
        _requireEffectiveSupplier(planId, orderId, sourceStageId, submitter);
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return (false, sourceStageId);
        }
        _requireSignalAdmission(planId, orderId, sourceId, signalId);
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, sourceStageId);
        return (true, sourceStageId);
    }

    function _applyFilePatch(
        bytes32 planId,
        bytes32 orderId,
        bytes32 filesDigest,
        FilePatch calldata filePatch,
        address submitter,
        bytes32 signalStageId
    ) private {
        address module = fileResourceModule;
        if (module == address(0)) {
            revert InvalidModuleAddress();
        }
        uint256 selectorWord = uint256(uint32(IUVPFileResourceModule.applyStageFilePatch.selector)) << 224;
        assembly ("memory-safe") {
            let start := filePatch
            let size := calldatasize()
            if iszero(gt(size, start)) { revert(0, 0) }
            let patchSize := sub(size, start)
            let ptr := mload(0x40)
            mstore(ptr, selectorWord)
            mstore(add(ptr, 0x04), planId)
            mstore(add(ptr, 0x24), orderId)
            mstore(add(ptr, 0x44), filesDigest)
            mstore(add(ptr, 0x64), 0xc0)
            mstore(add(ptr, 0x84), submitter)
            mstore(add(ptr, 0xa4), signalStageId)
            calldatacopy(add(ptr, 0xc4), start, patchSize)
            mstore(0x40, add(ptr, add(0xc4, patchSize)))
            if iszero(call(gas(), module, 0, ptr, add(0xc4, patchSize), 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _requireSignalAdmission(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId) private view {
        if (!_signalAdmissionSatisfied(planId, orderId, sourceId, signalId)) {
            revert SignalAdmissionRejected(orderId, sourceId, signalId);
        }
    }

    function _signalAdmissionSatisfied(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (bool)
    {
        if (!_s.orders[planId][orderId].admissionsDeclared) {
            return true;
        }
        StoredAdmission storage admission = _s.plans[planId].admissions[_signalKey(sourceId, signalId)];
        if (!admission.exists) {
            return true;
        }
        EvalValue memory result = _evaluateInstructions(planId, orderId, admission.instructions);
        return result.value && !result.wait && !result.cancel;
    }

    function _requireSourceStageReady(bytes32 planId, bytes32 orderId, bytes32 sourceStageId) private view {
        if (sourceStageId == bytes32(0)) {
            return;
        }
        if (!_s.orders[planId][orderId].materializedStages[sourceStageId]) {
            revert UnknownHook();
        }
    }

    function _requireEffectiveSupplier(bytes32 planId, bytes32 orderId, bytes32 stageId, address submitter)
        private
        view
    {
        bytes32 supplierId = _effectiveStageSupplier(planId, orderId, stageId);
        if (supplierId == bytes32(0)) {
            revert StageSupplierNotAssigned(orderId, stageId);
        }
        address account = _activeSupplierAccount(supplierId);
        if (account == address(0)) {
            revert SupplierNotActive(supplierId);
        }
        if (account != submitter) {
            revert UnauthorizedStageSupplierAccount(orderId, stageId, submitter, account);
        }
    }

    function _effectiveStageAccount(bytes32 planId, bytes32 orderId, bytes32 stageId) private view returns (address) {
        return _activeSupplierAccount(_effectiveStageSupplier(planId, orderId, stageId));
    }

    function _effectiveStageSupplier(bytes32 planId, bytes32 orderId, bytes32 stageId)
        private
        view
        returns (bytes32)
    {
        if (stageId == bytes32(0)) {
            return bytes32(0);
        }
        bytes32 assignedSupplierId = _s.stageSupplierAssignments[planId][orderId][stageId].supplierId;
        if (assignedSupplierId != bytes32(0)) {
            return assignedSupplierId;
        }
        return _s.plans[planId].stageDefaultSuppliers[stageId];
    }

    function _activeSupplierAccount(bytes32 supplierId) private view returns (address) {
        if (supplierId == bytes32(0)) {
            return address(0);
        }
        address registry = _s.supplierRegistry;
        if (registry == address(0)) {
            revert SupplierRegistryNotConfigured();
        }
        IUVPSupplierRegistry registryContract = IUVPSupplierRegistry(registry);
        if (!registryContract.isActiveSupplier(supplierId)) {
            return address(0);
        }
        return registryContract.accountOf(supplierId);
    }

    function _isEffectiveStageAccount(bytes32 planId, bytes32 orderId, bytes32 stageId, address account)
        private
        view
        returns (bool)
    {
        if (stageId == bytes32(0) || account == address(0)) {
            return false;
        }
        return _effectiveStageAccount(planId, orderId, stageId) == account;
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
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, msg.sender, factStageId
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

    function isPlanStage(bytes32 planId, bytes32 stageId) external view returns (bool) {
        return _isPlanStage(planId, stageId);
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

    function planSupplierBindingsRoot(bytes32 planId) external view returns (bytes32) {
        return _s.plans[planId].supplierBindingsRoot;
    }

    function planStageDefaultSupplier(bytes32 planId, bytes32 stageId) external view returns (bytes32) {
        return _s.plans[planId].stageDefaultSuppliers[stageId];
    }

    function planStageHasDynamicSupplier(bytes32 planId, bytes32 stageId) external view returns (bool) {
        return _s.plans[planId].dynamicSupplierStages[stageId];
    }

    function planStageIsCandidate(bytes32 planId, bytes32 stageId) external view returns (bool) {
        return _s.plans[planId].stageCandidateStages[stageId];
    }

    function effectiveStageSupplier(bytes32 planId, bytes32 orderId, bytes32 stageId) external view returns (bytes32) {
        return _effectiveStageSupplier(planId, orderId, stageId);
    }

    function effectiveStageAccount(bytes32 planId, bytes32 orderId, bytes32 stageId) external view returns (address) {
        return _effectiveStageAccount(planId, orderId, stageId);
    }

    function isEffectiveStageAccount(bytes32 planId, bytes32 orderId, bytes32 stageId, address account)
        external
        view
        returns (bool)
    {
        return _isEffectiveStageAccount(planId, orderId, stageId, account);
    }

    function stageSupplierAssignment(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bytes32 supplierId, uint256 patchNonce, bytes32 dockId)
    {
        StageSupplierAssignment storage assignment = _s.stageSupplierAssignments[planId][orderId][targetStageId];
        return (assignment.supplierId, assignment.patchNonce, assignment.dockId);
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
        bytes32 filesDigest,
        FactAttribution calldata attribution,
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
                filesDigest,
                _attributionHash(attribution),
                submitter,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _attributionHash(FactAttribution calldata attribution) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _FACT_ATTRIBUTION_TYPEHASH,
                attribution.sourceId,
                attribution.signalId,
                attribution.stageId,
                keccak256(abi.encode(attribution.capabilityProof))
            )
        );
    }

    function _verifySubmitterSignature(address submitter, bytes32 digest, bytes calldata signature) private view {
        if (submitter.code.length != 0) {
            (bool ok, bytes memory result) =
                submitter.staticcall(abi.encodeWithSelector(_EIP1271_MAGIC_VALUE, digest, signature));
            if (!ok || result.length < 32 || abi.decode(result, (bytes4)) != _EIP1271_MAGIC_VALUE) {
                revert InvalidEIP1271Signature(submitter);
            }
            return;
        }
        address recoveredSigner = _recoverSignalSubmitter(digest, signature);
        if (recoveredSigner != submitter) {
            revert InvalidSignalSubmitterSignature(submitter, recoveredSigner);
        }
    }

    function _signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function _isOrderTrigger(uint8 flags) private pure returns (bool) {
        return flags & HOOK_FLAG_ORDER_TRIGGER_MINT != 0;
    }

    function _hookCanMaterializeStage(uint8 flags) private pure returns (bool) {
        return _isOrderTrigger(flags) || flags & HOOK_FLAG_EMIT_READY != 0;
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
        return _isEffectiveStageAccount(originPlanId, originOrderId, originStageId, party);
    }

    function _isPlanStage(bytes32 planId, bytes32 stageId) private view returns (bool) {
        if (stageId == bytes32(0)) {
            return false;
        }
        return _s.plans[planId].stageExists[stageId];
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
                _evaluateHook(planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
            }
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
        _initializeHookRuntime(runtime);
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

        if (nextStatus == HookStatus.Ready) {
            _announceHookReady(planId, orderId, hookId, triggerSourceId, triggerSignalId);
        }
    }

    function _announceHookReady(
        bytes32 planId,
        bytes32 orderId,
        bytes32 hookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        StoredHook storage hook = _s.plans[planId].hooks[hookId];
        HookRuntime storage runtime = _s.orders[planId][orderId].hookRuntimes[hookId];
        if (runtime.readyEmitted) {
            return;
        }
        if (_s.orders[planId][orderId].materializedStages[hook.stageId]) {
            runtime.readyEmitted = true;
            emit HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
        } else if (_hookCanMaterializeStage(hook.flags)) {
            _materializeStage(planId, orderId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
        }
    }

    function _initializeHookRuntime(HookRuntime storage runtime) private {
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

        emit StageMaterialized(planId, orderId, stageId, triggerHookId, triggerSourceId, triggerSignalId);

        bytes32[] storage stageHooks = _s.plans[planId].stageHookIds[stageId];
        for (uint256 i = 0; i < stageHooks.length; i++) {
            _settleStageHook(planId, orderId, stageHooks[i]);
        }
    }

    function _settleStageHook(bytes32 planId, bytes32 orderId, bytes32 hookId) private {
        HookRuntime storage runtime = _s.orders[planId][orderId].hookRuntimes[hookId];
        _initializeHookRuntime(runtime);
        if (runtime.status != HookStatus.Ready) {
            return;
        }
        if (runtime.readyEmitted) {
            return;
        }
        runtime.readyEmitted = true;
        StoredHook storage hook = _s.plans[planId].hooks[hookId];
        emit HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
    }

    function _evaluateInstructions(bytes32 planId, bytes32 orderId, Instruction[] storage instructions)
        private
        view
        returns (EvalValue memory)
    {
        Instruction[] memory loaded = new Instruction[](instructions.length);
        for (uint256 i = 0; i < instructions.length; i++) {
            loaded[i] = instructions[i];
        }
        return _evaluateMemoryInstructions(planId, orderId, loaded);
    }

    function _evaluateMemoryInstructions(bytes32 planId, bytes32 orderId, Instruction[] memory instructions)
        private
        view
        returns (EvalValue memory)
    {
        EvalValue[] memory stack = new EvalValue[](instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < instructions.length; i++) {
            Instruction memory instruction = instructions[i];
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
        assembly ("memory-safe") {
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
