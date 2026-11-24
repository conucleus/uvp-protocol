// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPIdentityRegistry} from "./interfaces/IUVPIdentityRegistry.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {StageFile} from "./interfaces/IUVPFileResourceModule.sol";
import {UVPPlanRegistration} from "./UVPPlanRegistration.sol";
import {UVPHookEvaluator} from "./libraries/UVPHookEvaluator.sol";
import {
    AdmissionVerdict,
    _HOOK_FLAG_ORDER_TRIGGER_MINT,
    _HOOK_FLAG_EMIT_READY,
    _HOOK_FLAG_ADMISSION,
    _HOOK_FLAG_DOCK_EXECUTOR,
    _HOOK_FLAG_DYNAMIC_EXECUTOR,
    _MAX_HOOK_DELAY_SECONDS,
    _MAX_PLAN_DEPENDENCIES,
    _MAX_SUPPLIER_BINDINGS,
    _MAX_FILE_WRITERS,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN
} from "./UVPStateMachineConstants.sol";

// Core state machine. Stage submission authority is resolved exclusively
// through the configured UVPIdentityRegistry module slot (effective SID ->
// account -> active status); no identity-binding registry is consulted, so
// subject/account bindings never authorize execution.
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

    struct FactAttribution {
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 stageId;
        bytes32[] capabilityProof;
    }

    struct SignalSubmission {
        bytes32 planId;
        bytes32 orderId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
        FactAttribution attribution;
        bytes32 targetStageId;
        StageFile[] files;
        address submitter;
        uint256 deadline;
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
        bytes32 fileWritersHash;
        uint256 deadline;
    }

    struct StageFileWriter {
        bytes32 targetStageId;
        bytes32 writerStageId;
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
        bytes32[] hookIds;
        mapping(bytes32 stageId => bytes32[] hookIds) stageHookIds;
        mapping(bytes32 hookId => StoredHook hook) hooks;
        mapping(bytes32 signalKey => bytes32[] hookIds) dependencyIndex;
        mapping(bytes32 signalKey => StoredAdmission admission) admissions;
        mapping(bytes32 stageId => bool exists) stageExists;
        mapping(bytes32 stageId => bytes32 supplierId) stageDefaultSuppliers;
        mapping(bytes32 targetStageId => bytes32[] writerStageIds) fileWriterStages;
        bytes32 fileWritersHash;
        mapping(bytes32 stageId => bool) stageCandidateStages;
        mapping(bytes32 stageId => bool) dynamicSupplierStages;
        bool committed;
        bool finalized;
        bool admissionsDeclared;
    }

    struct Order {
        address relayer;
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
    error NotTriggerSignal(bytes32 sourceId, bytes32 signalId);
    error AmbiguousTriggerSignal(bytes32 sourceId, bytes32 signalId);
    error DuplicateTriggerKey(address submitter, bytes32 idempotencyKey, bytes32 existingOrderId);
    error OrderIdCollision(bytes32 planId);
    error DuplicateFileWriter(bytes32 targetStageId, bytes32 writerStageId);
    error FileWritersHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error InvalidFileWriter(bytes32 targetStageId, bytes32 writerStageId);
    error TooManyFileWriters(uint256 count);
    error ZeroFileTargetStageId();
    error ZeroIdempotencyKey();
    error UnauthorizedDirectSubmitter(address submitter, address caller);
    error ModulesAlreadyFrozen();
    error ModulesFrozen();
    error ModulesNotFrozen();
    error NotOwner();
    error PlanAlreadyRegistered();
    error PlanAlreadyFinalized();
    error HooksHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error SupplierBindingsRootMismatch(bytes32 expectedRoot, bytes32 actualRoot);
    error PlanNotCommitted();
    error PlanNotFinalized();
    error SignalAlreadyExists();
    error SignalAdmissionRejected(bytes32 orderId, bytes32 sourceId, bytes32 signalId);
    error AdmissionAlreadyRegistered(bytes32 signalKey);
    error InvalidAdmissionHook(bytes32 hookId);
    error SilentOrderTriggerHook(bytes32 hookId);
    error StageSupplierNotAssigned(bytes32 orderId, bytes32 targetStageId);
    error StageNotMaterializable(bytes32 stageId);
    error StageSupplierPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error TimerNotDue();
    error TimerNotWaiting();
    error UnauthorizedStateMachineModule(address caller);
    error UnauthorizedStageSupplierAccount(
        bytes32 orderId, bytes32 targetStageId, address submitter, address expectedAccount
    );
    error UnknownHook();
    error UnknownOrder();
    error UnknownPlan();
    error ZeroOwner();
    error ZeroPlanPublisher();
    error ZeroSignalId();
    error ZeroSourceId();
    error ZeroSubmitter();
    error ZeroTargetStageId();
    error ZeroSupplierId();
    error ZeroDockId();
    error IdentityRegistryNotConfigured();
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

    function identityRegistry() external view returns (address) {
        return _s.identityRegistry;
    }

    address public lens;
    bool public modulesFrozen;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;

    uint8 public constant HOOK_FLAG_ORDER_TRIGGER_MINT = _HOOK_FLAG_ORDER_TRIGGER_MINT;
    uint8 public constant HOOK_FLAG_DOCK_EXECUTOR = _HOOK_FLAG_DOCK_EXECUTOR;
    uint8 public constant HOOK_FLAG_EMIT_READY = _HOOK_FLAG_EMIT_READY;
    uint8 public constant HOOK_FLAG_ADMISSION = _HOOK_FLAG_ADMISSION;
    uint8 public constant HOOK_FLAG_DYNAMIC_EXECUTOR = _HOOK_FLAG_DYNAMIC_EXECUTOR;
    uint64 public constant MAX_HOOK_DELAY_SECONDS = _MAX_HOOK_DELAY_SECONDS;
    uint256 public constant MAX_PLAN_DEPENDENCIES = _MAX_PLAN_DEPENDENCIES;
    uint256 public constant MAX_SUPPLIER_BINDINGS = _MAX_SUPPLIER_BINDINGS;
    uint256 public constant MAX_FILE_WRITERS = _MAX_FILE_WRITERS;

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
        mapping(address submitter => mapping(bytes32 idempotencyKey => bytes32 orderId)) usedTriggerKeys;
        uint256 orderNonce;
        address planMetadataModule;
        address identityRegistry;
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
        bytes32 supplierBindingsRoot
    );
    event PlanFinalized(bytes32 indexed planId, bytes32 indexed planHash, bytes32 capabilitiesRoot);
    event PlanRegistered(bytes32 indexed planId, bytes32 planHash, uint256 hookCount);
    event PlanPublisherRecorded(bytes32 indexed planId, address indexed publisher);
    event OrderRegistered(bytes32 indexed orderId, bytes32 indexed planId);
    event OrderMaterialized(bytes32 indexed orderId, bytes32 indexed planId, bytes32 indexed stageId);
    event OrderRelayerRecorded(bytes32 indexed planId, bytes32 orderId, address indexed relayer);
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

    bytes32 public constant STAGE_PATCH_MODULE_ID = keccak256("uvp.module.stage_patch.v1");
    bytes32 public constant DERIVED_SIGNAL_MODULE_ID = keccak256("uvp.module.derived_signal.v1");
    bytes32 public constant DOCK_REGISTRY_MODULE_ID = keccak256("uvp.module.dock_registry.v1");
    bytes32 public constant PLAN_METADATA_MODULE_ID = keccak256("uvp.module.plan_metadata.v1");
    bytes32 public constant LENS_MODULE_ID = keccak256("uvp.module.lens.v1");
    bytes32 public constant FILE_RESOURCE_MODULE_ID = keccak256("uvp.module.file_resource.v1");
    bytes32 public constant IDENTITY_REGISTRY_MODULE_ID = keccak256("uvp.module.supplier_registry.v1");

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

    function setLens(address moduleAddress) external onlyOwner {
        lens = _setModule(LENS_MODULE_ID, lens, moduleAddress);
    }

    function setFileResourceModule(address moduleAddress) external onlyOwner {
        fileResourceModule = _setModule(FILE_RESOURCE_MODULE_ID, fileResourceModule, moduleAddress);
    }

    function setIdentityRegistry(address moduleAddress) external onlyOwner {
        _s.identityRegistry = _setModule(IDENTITY_REGISTRY_MODULE_ID, _s.identityRegistry, moduleAddress);
    }

    function freezeModules() external onlyOwner {
        if (modulesFrozen) {
            revert ModulesAlreadyFrozen();
        }
        if (
            stagePatchModule == address(0) || derivedSignalModule == address(0) || dockRegistry == address(0)
                || _s.planMetadataModule == address(0) || lens == address(0) || fileResourceModule == address(0)
                || _s.identityRegistry == address(0)
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
                lens,
                fileResourceModule,
                _s.identityRegistry
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
        StageFileWriter[] calldata fileWriters,
        bytes calldata signature
    ) external returns (bytes32 planId) {
        planId = UVPPlanRegistration.commitPlan(
            _s.plans, modulesFrozen, _s.identityRegistry, commit, hooks, bindings, fileWriters, signature
        );
    }

    function finalizePlan(bytes32 planId) external {
        UVPPlanRegistration.finalizePlan(_s.plans, _s.planMetadataModule, planId);
    }

    function planRuntimeHash(
        bytes32 hooksHash,
        bytes32 capabilitiesRoot,
        bytes32 supplierBindingsRoot,
        bytes32 fileWritersHash
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(_PLAN_RUNTIME_HASH_DOMAIN, hooksHash, capabilitiesRoot, supplierBindingsRoot, fileWritersHash)
        );
    }

    function planIdFor(address publisher, bytes32 runtimePlanHash) public pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_ID_HASH_DOMAIN, publisher, runtimePlanHash));
    }

    function submitSignal(SignalSubmission calldata submission, bytes calldata signature)
        external
        returns (bytes32 orderId, bool inserted)
    {
        return UVPPlanRegistration.submitSignal(_s, submission, signature, fileResourceModule);
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
        (AdmissionVerdict verdict,) = _signalAdmissionVerdict(planId, orderId, sourceId, signalId);
        return verdict == AdmissionVerdict.Ready;
    }

    function signalAdmissionVerdict(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        external
        view
        returns (AdmissionVerdict verdict, uint64 dueAt)
    {
        if (!_s.orders[planId][orderId].exists) {
            return (AdmissionVerdict.Impossible, 0);
        }
        return _signalAdmissionVerdict(planId, orderId, sourceId, signalId);
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
        (AdmissionVerdict verdict,) = _signalAdmissionVerdict(planId, orderId, sourceId, signalId);
        if (verdict != AdmissionVerdict.Ready) {
            revert SignalAdmissionRejected(orderId, sourceId, signalId);
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
    ) external returns (bool inserted) {
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
        _requireSourceStageReady(planId, orderId, stageId);
        if (_hasSignal(planId, orderId, sourceId, signalId)) {
            return false;
        }
        _recordSignal(planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, false, stageId);
        return true;
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

    function _signalAdmissionVerdict(bytes32 planId, bytes32 orderId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (AdmissionVerdict verdict, uint64 dueAt)
    {
        if (!_s.orders[planId][orderId].admissionsDeclared) {
            return (AdmissionVerdict.Ready, 0);
        }
        StoredAdmission storage admission = _s.plans[planId].admissions[_signalKey(sourceId, signalId)];
        if (!admission.exists) {
            return (AdmissionVerdict.Ready, 0);
        }
        EvalValue memory result = _evaluateInstructions(planId, orderId, admission.instructions);
        return (UVPHookEvaluator.verdict(result), result.dueAt);
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
        address registry = _s.identityRegistry;
        if (registry == address(0)) {
            revert IdentityRegistryNotConfigured();
        }
        IUVPIdentityRegistry registryContract = IUVPIdentityRegistry(registry);
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

    function _isPlanFileWriter(bytes32 planId, bytes32 targetStageId, bytes32 writerStageId)
        private
        view
        returns (bool)
    {
        if (targetStageId == bytes32(0) || writerStageId == bytes32(0)) {
            return false;
        }
        bytes32[] storage writers = _s.plans[planId].fileWriterStages[targetStageId];
        for (uint256 i = 0; i < writers.length; i++) {
            if (writers[i] == writerStageId) {
                return true;
            }
        }
        return false;
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

    function isPlanFileWriter(bytes32 planId, bytes32 targetStageId, bytes32 writerStageId)
        external
        view
        returns (bool)
    {
        return _isPlanFileWriter(planId, targetStageId, writerStageId);
    }

    function isAuthorizedFileWriter(bytes32 planId, bytes32 orderId, bytes32 targetStageId, address account)
        external
        view
        returns (bool)
    {
        if (!_isEffectiveStageAccount(planId, orderId, targetStageId, account)) {
            bytes32[] storage writers = _s.plans[planId].fileWriterStages[targetStageId];
            for (uint256 i = 0; i < writers.length; i++) {
                if (_isEffectiveStageAccount(planId, orderId, writers[i], account)) {
                    return true;
                }
            }
            return false;
        }
        return true;
    }

    function planFileWritersHash(bytes32 planId) external view returns (bytes32) {
        return _s.plans[planId].fileWritersHash;
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

    function _signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function _isOrderTrigger(uint8 flags) private pure returns (bool) {
        return flags & HOOK_FLAG_ORDER_TRIGGER_MINT != 0;
    }

    function _hookCanMaterializeStage(uint8 flags) private pure returns (bool) {
        return _isOrderTrigger(flags) || flags & HOOK_FLAG_EMIT_READY != 0;
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
            nextDueAt = result.dueAt;
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
        return UVPHookEvaluator.evaluateStorage(_s.signals[planId][orderId], instructions);
    }

    function _evaluateMemoryInstructions(bytes32 planId, bytes32 orderId, Instruction[] memory instructions)
        private
        view
        returns (EvalValue memory)
    {
        return UVPHookEvaluator.evaluate(_s.signals[planId][orderId], instructions);
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
}
