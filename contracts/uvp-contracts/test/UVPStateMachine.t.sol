// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPDockRegistry} from "../src/UVPDockRegistry.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {UVPSupplierRegistry} from "../src/UVPSupplierRegistry.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
import {FileOp, FilePatch} from "../src/interfaces/IUVPFileResourceModule.sol";
import {MerkleCommitment} from "../src/libraries/MerkleCommitment.sol";
import {BirthAuthorizerForwarder} from "./BirthAuthorizerForwarder.sol";
import {emptyFilePatch} from "./FilePatchTestHelpers.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function addr(uint256 privateKey) external returns (address keyAddr);
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address msgSender) external;
    function recordLogs() external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

contract Eip1271Executor {
    bytes4 private constant _MAGIC = 0x1626ba7e;

    bool public valid = true;

    function setValid(bool nextValid) external {
        valid = nextValid;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return valid ? _MAGIC : bytes4(0xffffffff);
    }
}

contract StagePatchActivationMock {
    address private immutable _machine;

    constructor(address machineAddress) {
        _machine = machineAddress;
    }

    function activateExecutor(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        uint256 patchNonce
    ) external {
        IUVPStateMachineCore(_machine).activateStageExecutorFromModule(
            planId, orderId, targetStageId, supplierId, patchNonce
        );
    }

    function activateDockExecutor(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        bytes32 dockId,
        uint256 patchNonce
    ) external {
        IUVPStateMachineCore(_machine).activateStageDockExecutorFromModule(
            planId, orderId, targetStageId, supplierId, dockId, patchNonce
        );
    }
}

contract UVPStateMachineTest {
    struct StageSelectorBinding {
        bytes32 selectorStageId;
        bytes32 targetStageId;
    }

    struct SignalCapability {
        bytes32 stageId;
        bytes32 targetSourceId;
        bytes32 signalId;
        uint8 targetOrderRelation;
    }

    struct CapabilityTables {
        StageSelectorBinding[] bindings;
        SignalCapability[] capabilities;
        bytes32[] sortedLeaves;
    }

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant SOURCE_BOOTSTRAP = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_AUDIT = bytes32(uint256(0x5002));
    bytes32 private constant STAGE_DYN = bytes32(uint256(0x5003));
    bytes32 private constant STAGE_DOCK = bytes32(uint256(0x5004));
    bytes32 private constant EXTERNAL_SOURCE = bytes32(uint256(0x3ff1));

    bytes32 private constant SIGNAL_BIRTH = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_OPEN = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_DONE = bytes32(uint256(0x4002));
    bytes32 private constant SIGNAL_TIMER = bytes32(uint256(0x4003));
    bytes32 private constant SIGNAL_VETO = bytes32(uint256(0x4004));
    bytes32 private constant SIGNAL_DERIVED = bytes32(uint256(0x4005));

    bytes32 private constant HOOK_BIRTH = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_OPEN = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_DONE = bytes32(uint256(0x6002));
    bytes32 private constant HOOK_DYN_OPEN = bytes32(uint256(0x6003));
    bytes32 private constant HOOK_DOCK_OPEN = bytes32(uint256(0x6004));
    bytes32 private constant HOOK_DOCK_DONE = bytes32(uint256(0x6007));
    bytes32 private constant HOOK_TIMER = bytes32(uint256(0x6005));
    bytes32 private constant HOOK_VETO = bytes32(uint256(0x6006));

    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant DOCK_ID = bytes32(uint256(0xd0c1));

    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_ADMISSION = 8;
    uint8 private constant FLAG_DOCK_EXECUTOR = 16;
    uint8 private constant FLAG_DYNAMIC_EXECUTOR = 32;

    address private constant ORDER_CREATOR = address(uint160(0xc0de));
    address private constant EXECUTOR_A = address(uint160(0xa11ce));
    address private constant EXECUTOR_B = address(uint160(0xb0b));
    address private constant OUTSIDER = address(uint160(0xbad));
    address private constant NON_OWNER = address(uint160(0xf01));

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant BIRTH_PRIVATE_KEY = 0xbeef;
    uint256 private constant SIGNAL_PRIVATE_KEY = 0xb51;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.18");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 executorBindingsRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignalSubmission(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 filesDigest,bytes32 attributionHash,address submitter,uint256 deadline)"
    );
    bytes32 private constant FACT_ATTRIBUTION_TYPEHASH =
        keccak256("FactAttribution(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)");
    bytes32 private constant EXECUTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_BINDING_V2");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");

    mapping(address machine => UVPSupplierRegistry) private _registries;
    mapping(address machine => UVPFileResourceModule) private _fileModules;
    mapping(address machine => UVPDerivedSignalModule) private _derivedModules;
    mapping(address machine => StagePatchActivationMock) private _patchModules;
    mapping(address machine => mapping(address executor => bytes32 supplierId)) private _suppliers;
    mapping(address machine => mapping(bytes32 stageId => address executor)) private _stageExecutors;
    mapping(address machine => mapping(bytes32 planId => CapabilityTables)) private _tables;

    bytes32 private PLAN_ID;
    bytes32 private ORDER_ID;

    function testConstructorSetsOwner() public {
        UVPStateMachine machine = new UVPStateMachine();
        require(machine.owner() == address(this), "owner mismatch");
        require(!machine.modulesFrozen(), "frozen too early");
    }

    function testTransferOwnershipRequiresOwnerAndNonZero() public {
        UVPStateMachine machine = new UVPStateMachine();
        vm.prank(NON_OWNER);
        vm.expectRevert(UVPStateMachine.NotOwner.selector);
        machine.transferOwnership(NON_OWNER);

        vm.expectRevert(UVPStateMachine.ZeroOwner.selector);
        machine.transferOwnership(address(0));

        machine.transferOwnership(NON_OWNER);
        require(machine.owner() == NON_OWNER, "owner transfer missing");
    }

    function testFreezeRequiresSupplierRegistryModule() public {
        UVPStateMachine machine = _deployModulesWithoutSupplierRegistry();
        vm.expectRevert(UVPStateMachine.IncompleteModuleConfiguration.selector);
        machine.freezeModules();

        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        machine.setSupplierRegistry(address(registry));
        machine.freezeModules();
        require(machine.modulesFrozen(), "modules not frozen");
        require(machine.supplierRegistry() == address(registry), "registry slot missing");
    }

    function testFrozenModulesCannotBeReconfigured() public {
        UVPStateMachine machine = _newMachine();
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        address replacementPatch = address(new StagePatchActivationMock(address(machine)));
        vm.expectRevert(UVPStateMachine.ModulesFrozen.selector);
        machine.setSupplierRegistry(address(registry));
        vm.expectRevert(UVPStateMachine.ModulesFrozen.selector);
        machine.setStagePatchModule(replacementPatch);
    }

    function testCommitPlanRequiresFrozenModules() public {
        UVPStateMachine machine = _deployModulesWithoutSupplierRegistry();
        UVPStateMachine.CompactHook[] memory hooks = _birthPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = new UVPStateMachine.ExecutorBinding[](0);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(UVPStateMachine.ModulesNotFrozen.selector);
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testPlanExistsOnlyAfterFinalize() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _commitPlan(machine, _birthPlan(), new StageSelectorBinding[](0), new SignalCapability[](0), _autoBindings(machine, _birthPlan()), PUBLISHER_PRIVATE_KEY);
        require(machine.planCommitted(planId), "plan not committed");
        require(!machine.planExists(planId), "pending plan must not exist");
        machine.finalizePlan(planId);
        require(machine.planExists(planId), "plan not finalized");
        vm.expectRevert(UVPStateMachine.PlanAlreadyFinalized.selector);
        machine.finalizePlan(planId);
    }

    function testCommitPlanStoresExecutorBindingsState() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        bytes32 supplierThis = _supplierFor(machine, address(this));
        bytes32 supplierA = _supplierFor(machine, EXECUTOR_A);
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory withCandidate =
            new UVPStateMachine.ExecutorBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withCandidate[i] = bindings[i];
        }
        withCandidate[bindings.length] = UVPStateMachine.ExecutorBinding({
            stageId: STAGE_AUDIT,
            supplierId: supplierA,
            kind: 1
        });

        bytes32 planId = _commitPlan(
            machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withCandidate, PUBLISHER_PRIVATE_KEY
        );
        require(
            machine.planExecutorBindingsRoot(planId) == _bindingsRoot(withCandidate), "bindings root mismatch"
        );
        require(machine.planStageDefaultSupplier(planId, STAGE_INIT) == supplierThis, "init supplier mismatch");
        require(machine.planStageDefaultSupplier(planId, STAGE_AUDIT) == supplierThis, "audit supplier mismatch");
        require(machine.planStageIsCandidate(planId, STAGE_AUDIT), "candidate stage flag missing");
        require(!machine.planStageIsCandidate(planId, STAGE_INIT), "init must not be candidate");
        require(!machine.planStageHasDynamicExecutor(planId, STAGE_AUDIT), "unexpected dynamic flag");
    }

    function testDynamicPlanMarksDynamicStageWithoutBinding() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _dynamicPlan());
        require(machine.planStageHasDynamicExecutor(planId, STAGE_DYN), "dynamic stage flag missing");
        require(machine.planStageDefaultSupplier(planId, STAGE_DYN) == bytes32(0), "dynamic stage must be unbound");
        _submitTriggerBirth(machine, planId);
        require(machine.effectiveStageSupplier(planId, ORDER_ID, STAGE_DYN) == bytes32(0), "dynamic supplier must be zero");
    }

    function testCommitPlanRejectsBindingsRootMismatch() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        commit.executorBindingsRoot = bytes32(uint256(0x1234));
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.ExecutorBindingsRootMismatch.selector, bytes32(uint256(0x1234)), _bindingsRoot(bindings)
            )
        );
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testCommitPlanRejectsTooManyExecutorBindings() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _birthPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = new UVPStateMachine.ExecutorBinding[](257);
        bytes32 supplierId = _supplierFor(machine, address(this));
        for (uint256 i = 0; i < bindings.length; i++) {
            bindings[i] = UVPStateMachine.ExecutorBinding({stageId: STAGE_INIT, supplierId: supplierId, kind: 0});
        }
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.TooManyExecutorBindings.selector, 257));
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testCommitPlanRejectsDuplicateExecutorBinding() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory duplicated =
            new UVPStateMachine.ExecutorBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            duplicated[i] = bindings[i];
        }
        duplicated[bindings.length] = bindings[0];
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), duplicated, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.DuplicateExecutorBinding.selector, bindings[0].stageId, bindings[0].supplierId, bindings[0].kind
            )
        );
        machine.commitPlan(commit, hooks, duplicated, signature);
    }

    function testCommitPlanRejectsUnregisteredSupplier() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        bytes32 unknownSupplier = keccak256("unknown-supplier");
        bindings[0].supplierId = unknownSupplier;
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SupplierNotRegistered.selector, unknownSupplier));
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testCommitPlanRejectsBindingForUnknownStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory withUnknown =
            new UVPStateMachine.ExecutorBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withUnknown[i] = bindings[i];
        }
        withUnknown[bindings.length] = UVPStateMachine.ExecutorBinding({
            stageId: bytes32(uint256(0x7777)),
            supplierId: _supplierFor(machine, EXECUTOR_A),
            kind: 0
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withUnknown, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnknownPlanStage.selector, bytes32(uint256(0x7777)))
        );
        machine.commitPlan(commit, hooks, withUnknown, signature);
    }

    function testCommitPlanRejectsBindingOnDynamicStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _dynamicPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory withDynamic =
            new UVPStateMachine.ExecutorBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withDynamic[i] = bindings[i];
        }
        withDynamic[bindings.length] = UVPStateMachine.ExecutorBinding({
            stageId: STAGE_DYN,
            supplierId: _supplierFor(machine, EXECUTOR_A),
            kind: 0
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withDynamic, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.ExecutorBindingForbiddenForStage.selector, STAGE_DYN)
        );
        machine.commitPlan(commit, hooks, withDynamic, signature);
    }

    function testCommitPlanRejectsBindingOnDockStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _dockPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory withDock = new UVPStateMachine.ExecutorBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withDock[i] = bindings[i];
        }
        withDock[bindings.length] = UVPStateMachine.ExecutorBinding({
            stageId: STAGE_DOCK,
            supplierId: _supplierFor(machine, EXECUTOR_A),
            kind: 0
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withDock, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.ExecutorBindingForbiddenForStage.selector, STAGE_DOCK)
        );
        machine.commitPlan(commit, hooks, withDock, signature);
    }

    function testCommitPlanRejectsCandidateOnBirthStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory withCandidate =
            new UVPStateMachine.ExecutorBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withCandidate[i] = bindings[i];
        }
        withCandidate[bindings.length] = UVPStateMachine.ExecutorBinding({
            stageId: STAGE_INIT,
            supplierId: _supplierFor(machine, EXECUTOR_A),
            kind: 1
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withCandidate, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.CandidateExecutorBindingForbiddenForStage.selector, STAGE_INIT)
        );
        machine.commitPlan(commit, hooks, withCandidate, signature);
    }

    function testCommitPlanRejectsCandidateWithoutDefault() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory candidatesOnly =
            new UVPStateMachine.ExecutorBinding[](bindings.length);
        uint256 count;
        for (uint256 i = 0; i < bindings.length; i++) {
            if (bindings[i].stageId == STAGE_AUDIT) {
                continue;
            }
            candidatesOnly[count++] = bindings[i];
        }
        candidatesOnly[count] = UVPStateMachine.ExecutorBinding({
            stageId: STAGE_AUDIT,
            supplierId: _supplierFor(machine, EXECUTOR_A),
            kind: 1
        });
        UVPStateMachine.ExecutorBinding[] memory trimmed = new UVPStateMachine.ExecutorBinding[](count + 1);
        for (uint256 i = 0; i < count + 1; i++) {
            trimmed[i] = candidatesOnly[i];
        }
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), trimmed, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.CandidateExecutorBindingRequiresDefault.selector, STAGE_AUDIT)
        );
        machine.commitPlan(commit, hooks, trimmed, signature);
    }

    function testCommitPlanRejectsInvalidBindingKind() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.ExecutorBinding[] memory withInvalid =
            new UVPStateMachine.ExecutorBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withInvalid[i] = bindings[i];
        }
        withInvalid[bindings.length] = UVPStateMachine.ExecutorBinding({
            stageId: STAGE_AUDIT,
            supplierId: _supplierFor(machine, EXECUTOR_A),
            kind: 2
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withInvalid, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidExecutorBindingKind.selector, 2));
        machine.commitPlan(commit, hooks, withInvalid, signature);
    }

    function testCommitPlanRejectsInconsistentDynamicExecutorFlag() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP);
        hooks[1] = _signalHook(
            HOOK_DYN_OPEN,
            STAGE_DYN,
            SIGNAL_OPEN,
            FLAG_EMIT_READY | FLAG_ORDER_TRIGGER_MINT | FLAG_DYNAMIC_EXECUTOR,
            SOURCE_BOOTSTRAP
        );
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.InconsistentDynamicExecutorFlag.selector, STAGE_DYN)
        );
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testCommitPlanRejectsWrongPublisherSignature() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        bytes memory signature = _signPlanCommit(machine, commit, BIRTH_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidPlanSignature.selector, vm.addr(PUBLISHER_PRIVATE_KEY), vm.addr(BIRTH_PRIVATE_KEY)
            )
        );
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testCommitPlanRejectsExpiredSignature() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        vm.warp(block.timestamp + 2 hours);
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredPlanSignature.selector, commit.deadline));
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testCommitPlanRejectsHooksHashMismatch() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, vm.addr(BIRTH_PRIVATE_KEY)
        );
        commit.hooksHash = bytes32(uint256(0x1234));
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.HooksHashMismatch.selector, bytes32(uint256(0x1234)), keccak256(abi.encode(hooks))
            )
        );
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function testPlanCommittedEventCarriesExecutorBindingsRoot() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _executorPlan();
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        vm.recordLogs();
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, PUBLISHER_PRIVATE_KEY);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("PlanCommitted(bytes32,bytes32,address,bytes32,bytes32,uint256,bytes32,address)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                (bytes32 hooksHash, bytes32 capabilitiesRoot, uint256 hookCount, bytes32 bindingsRoot, address birthAuthorizer) =
                    abi.decode(logs[i].data, (bytes32, bytes32, uint256, bytes32, address));
                require(hooksHash == keccak256(abi.encode(hooks)), "event hooks hash");
                require(capabilitiesRoot == EMPTY_ROOT, "event capabilities root");
                require(hookCount == hooks.length, "event hook count");
                require(bindingsRoot == _bindingsRoot(bindings), "event bindings root");
                require(birthAuthorizer == vm.addr(BIRTH_PRIVATE_KEY), "event birth authorizer");
                found = true;
            }
        }
        require(found, "PlanCommitted not emitted");
    }

    function testBirthTriggerCreatesOrderAndMaterializesStage() public {
        UVPStateMachine machine = _registerBirthMachine();
        require(machine.orderExists(PLAN_ID, ORDER_ID), "order missing");
        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_BIRTH), "birth fact missing");
        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_BIRTH);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");
        require(machine.orderCreator(PLAN_ID, ORDER_ID) == ORDER_CREATOR, "creator mismatch");
        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_BIRTH);
        require(submitter == vm.addr(BIRTH_PRIVATE_KEY), "birth submitter mismatch");
    }

    function testBirthRelayerIsRecordedInSignalEvent() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _birthPlan());
        vm.recordLogs();
        _submitTriggerBirth(machine, planId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,address,bytes32)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic) {
                continue;
            }
            address submitter;
            address relayer;
            (,,, submitter, relayer,) =
                abi.decode(logs[i].data, (bytes32, bytes32, bytes32, address, address, bytes32));
            require(submitter == vm.addr(BIRTH_PRIVATE_KEY), "event submitter");
            require(relayer == address(this), "event relayer");
            found = true;
        }
        require(found, "SignalSubmitted not emitted");
    }

    function testBirthRejectsWrongSigner() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _birthPlan());
        address signer = vm.addr(BIRTH_PRIVATE_KEY);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _birthTrigger(planId, signer);
        bytes32 digest = _triggerDigest(machine, trigger);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidTriggerOrderSignature.selector, signer, vm.addr(PUBLISHER_PRIVATE_KEY)
            )
        );
        machine.triggerOrderFromOutsideFor(trigger, _packedSignature(v, r, s), _noAttribution());
    }

    function testBirthRejectsUnauthorizedBirthSubmitter() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlanWithBirthAuthorizer(machine, _birthPlan(), new SignalCapability[](0), EXECUTOR_A);
        address signer = vm.addr(BIRTH_PRIVATE_KEY);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _birthTrigger(planId, signer);
        bytes32 digest = _triggerDigest(machine, trigger);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BIRTH_PRIVATE_KEY, digest);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.UnauthorizedBirthSubmitter.selector, signer));
        machine.triggerOrderFromOutsideFor(trigger, _packedSignature(v, r, s), _noAttribution());
    }

    function testBirthByAuthorizerContract() public {
        UVPStateMachine machine = _newMachine();
        address authorizer = address(new BirthAuthorizerForwarder(address(machine)));
        bytes32 planId = _registerPlanWithBirthAuthorizer(machine, _birthPlan(), new SignalCapability[](0), authorizer);
        UVPStateMachine.TriggerOrderFromOutsideByAuthorizerRequest memory trigger =
            UVPStateMachine.TriggerOrderFromOutsideByAuthorizerRequest({
                planId: planId,
                creator: ORDER_CREATOR,
                triggerHookId: HOOK_BIRTH,
                triggerStageId: STAGE_INIT,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_BIRTH,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                deadline: block.timestamp + 1 hours
            });
        vm.prank(authorizer);
        machine.triggerOrderFromOutsideByAuthorizer(trigger, _noAttribution());
        bytes32 orderId = machine.triggerOrderIdFor(planId, SOURCE_BOOTSTRAP, SIGNAL_BIRTH, PAYLOAD_HASH);
        require(machine.orderExists(planId, orderId), "authorizer order missing");
        require(machine.orderRelayer(planId, orderId) == authorizer, "authorizer relayer mismatch");
    }

    function testDefaultExecutorBoundSubmitRecordsSignal() public {
        UVPStateMachine machine = _executorMachine();
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);
        require(machine.hasSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE), "signal missing");
        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE);
        require(submitter == address(this), "submitter mismatch");
        (UVPStateMachine.HookStatus status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_DONE);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
    }

    function testSubmitSignalRejectsNonExecutor() public {
        UVPStateMachine machine = _executorMachine();
        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_INIT, OUTSIDER, address(this)
            )
        );
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_DONE);
    }

    function testSubmitSignalRejectsUnknownSourceStage() public {
        UVPStateMachine machine = _executorMachine();
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SignalStageUnknown.selector, PLAN_ID, EXTERNAL_SOURCE, SIGNAL_DONE)
        );
        _submit(machine, EXTERNAL_SOURCE, SIGNAL_DONE);
    }

    function testEffectiveExecutorViews() public {
        UVPStateMachine machine = _executorMachine();
        bytes32 supplierId = _supplierFor(machine, address(this));
        require(machine.effectiveStageSupplier(PLAN_ID, ORDER_ID, STAGE_INIT) == supplierId, "supplier mismatch");
        (bytes32 resolvedSupplier, address executor) = machine.effectiveStageExecutor(PLAN_ID, ORDER_ID, STAGE_INIT);
        require(resolvedSupplier == supplierId, "executor supplier mismatch");
        require(executor == address(this), "executor mismatch");
        require(machine.isEffectiveStageExecutor(PLAN_ID, ORDER_ID, STAGE_INIT, address(this)), "executor not effective");
        require(!machine.isEffectiveStageExecutor(PLAN_ID, ORDER_ID, STAGE_INIT, OUTSIDER), "outsider effective");
    }

    function testActivateStageExecutorFromModuleSwitchesEffectiveExecutor() public {
        UVPStateMachine machine = _executorMachine();
        bytes32 supplierA = _supplierFor(machine, EXECUTOR_A);
        vm.recordLogs();
        _patchModules[address(machine)].activateExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bytes32 patchedSupplier, uint256 patchNonce, bytes32 dockId) =
            machine.activeStageExecutorPatch(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(patchedSupplier == supplierA, "patch supplier mismatch");
        require(patchNonce == 1, "patch nonce mismatch");
        require(dockId == bytes32(0), "unexpected dock id");
        require(machine.effectiveStageSupplier(PLAN_ID, ORDER_ID, STAGE_AUDIT) == supplierA, "effective supplier mismatch");

        bytes32 topic = keccak256("StageExecutorActivated(bytes32,bytes32,bytes32,bytes32,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic) {
                continue;
            }
            (bytes32 eventSupplierId, uint256 eventNonce) = abi.decode(logs[i].data, (bytes32, uint256));
            require(eventSupplierId == supplierA, "event supplier mismatch");
            require(eventNonce == 1, "event nonce mismatch");
            found = true;
        }
        require(found, "StageExecutorActivated not emitted");

        vm.prank(EXECUTOR_A);
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);
        require(machine.hasSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE), "patched executor signal missing");

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_AUDIT, address(this), EXECUTOR_A
            )
        );
        _submit(machine, STAGE_AUDIT, SIGNAL_TIMER);
    }

    function testActivateDockExecutorRecordsDockId() public {
        UVPStateMachine machine = _executorMachine();
        bytes32 supplierA = _supplierFor(machine, EXECUTOR_A);
        _patchModules[address(machine)].activateDockExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, DOCK_ID, 1);
        (bytes32 supplierId, uint256 patchNonce, bytes32 dockId) =
            machine.activeStageExecutorPatch(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(supplierId == supplierA, "dock supplier mismatch");
        require(patchNonce == 1, "dock nonce mismatch");
        require(dockId == DOCK_ID, "dock id mismatch");
    }

    function testActivateStageExecutorRejectsNonIncreasingNonce() public {
        UVPStateMachine machine = _executorMachine();
        bytes32 supplierA = _supplierFor(machine, EXECUTOR_A);
        _patchModules[address(machine)].activateExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.StageExecutorPatchNonceNotIncreasing.selector, ORDER_ID, STAGE_AUDIT, 2, 2
            )
        );
        _patchModules[address(machine)].activateExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 2);
    }

    function testActivateStageExecutorRejectsUnauthorizedCaller() public {
        UVPStateMachine machine = _executorMachine();
        bytes32 supplierA = _supplierFor(machine, EXECUTOR_A);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.UnauthorizedStateMachineModule.selector, OUTSIDER));
        machine.activateStageExecutorFromModule(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 1);
    }

    function testDynamicStageRequiresAssignmentBeforeSignal() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _dynamicPlan());
        _submitTriggerBirth(machine, planId);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        require(machine.orderExists(planId, ORDER_ID), "dynamic order missing");

        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_DYN)
        );
        _submit(machine, STAGE_DYN, SIGNAL_DONE);

        bytes32 supplierA = _supplierFor(machine, EXECUTOR_A);
        _patchModules[address(machine)].activateExecutor(planId, ORDER_ID, STAGE_DYN, supplierA, 1);
        vm.prank(EXECUTOR_A);
        _submit(machine, STAGE_DYN, SIGNAL_DONE);
        require(machine.hasSignal(planId, ORDER_ID, STAGE_DYN, SIGNAL_DONE), "dynamic signal missing");
    }

    function testSupplierRevocationBlocksSubmit() public {
        UVPStateMachine machine = _executorMachine();
        bytes32 supplierId = _supplierFor(machine, address(this));
        _registries[address(machine)].revokeSupplier(supplierId);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SupplierNotRegistered.selector, supplierId));
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);
    }

    function testSupplierRotationSwitchesEffectiveExecutor() public {
        UVPStateMachine machine = _executorMachine();
        bytes32 supplierId = _supplierFor(machine, address(this));
        _registries[address(machine)].rotateSupplierExecutor(supplierId, EXECUTOR_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_AUDIT, address(this), EXECUTOR_A
            )
        );
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);

        vm.prank(EXECUTOR_A);
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);
        require(machine.hasSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE), "rotated executor signal missing");
    }

    function testSubmitSignalForEcdsaByExecutor() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        _stageExecutors[address(machine)][STAGE_INIT] = signer;
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine, planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, PAYLOAD_HASH, bytes32(uint256(42)), bytes32(0), _noAttribution(), signer, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNAL_PRIVATE_KEY, digest);
        address relayer = address(uint160(0x1234));
        vm.prank(relayer);
        machine.submitSignalFor(
            planId,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            PAYLOAD_HASH,
            bytes32(uint256(42)),
            _noAttribution(),
            bytes32(0),
            emptyFilePatch(),
            signer,
            deadline,
            _packedSignature(v, r, s)
        );
        (,,,, address submitter) = machine.getSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        require(submitter == signer, "signed submitter mismatch");
        require(machine.orderRelayer(planId, ORDER_ID) == address(this), "order relayer drifted");
    }

    function testSubmitSignalForRejectsWrongSigner() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        _stageExecutors[address(machine)][STAGE_INIT] = signer;
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine, planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, PAYLOAD_HASH, bytes32(uint256(43)), bytes32(0), _noAttribution(), signer, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BIRTH_PRIVATE_KEY, digest);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalSubmitterSignature.selector, signer, vm.addr(BIRTH_PRIVATE_KEY)
            )
        );
        machine.submitSignalFor(
            planId,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            PAYLOAD_HASH,
            bytes32(uint256(43)),
            _noAttribution(),
            bytes32(0),
            emptyFilePatch(),
            signer,
            deadline,
            _packedSignature(v, r, s)
        );
    }

    function testSubmitSignalForRejectsExpiredDeadline() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        _stageExecutors[address(machine)][STAGE_INIT] = signer;
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);
        vm.warp(block.timestamp + 2 hours);
        uint256 deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredSignalSignature.selector, deadline));
        machine.submitSignalFor(
            planId,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            PAYLOAD_HASH,
            bytes32(uint256(44)),
            _noAttribution(),
            bytes32(0),
            emptyFilePatch(),
            signer,
            deadline,
            hex""
        );
    }

    function testSubmitSignalForRejectsSignerThatIsNotExecutor() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine, planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, PAYLOAD_HASH, bytes32(uint256(45)), bytes32(0), _noAttribution(), signer, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNAL_PRIVATE_KEY, digest);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_INIT, signer, address(this)
            )
        );
        machine.submitSignalFor(
            planId,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            PAYLOAD_HASH,
            bytes32(uint256(45)),
            _noAttribution(),
            bytes32(0),
            emptyFilePatch(),
            signer,
            deadline,
            _packedSignature(v, r, s)
        );
    }

    function testSubmitSignalForEip1271ExecutorAccepted() public {
        UVPStateMachine machine = _newMachine();
        Eip1271Executor wallet = new Eip1271Executor();
        _stageExecutors[address(machine)][STAGE_INIT] = address(wallet);
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);

        uint256 deadline = block.timestamp + 1 hours;
        machine.submitSignalFor(
            planId,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            PAYLOAD_HASH,
            bytes32(uint256(46)),
            _noAttribution(),
            bytes32(0),
            emptyFilePatch(),
            address(wallet),
            deadline,
            hex"deadbeef"
        );
        (,,,, address submitter) = machine.getSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        require(submitter == address(wallet), "1271 submitter mismatch");
    }

    function testSubmitSignalForEip1271InvalidSignatureRejected() public {
        UVPStateMachine machine = _newMachine();
        Eip1271Executor wallet = new Eip1271Executor();
        wallet.setValid(false);
        _stageExecutors[address(machine)][STAGE_INIT] = address(wallet);
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidEIP1271Signature.selector, address(wallet)));
        machine.submitSignalFor(
            planId,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            PAYLOAD_HASH,
            bytes32(uint256(47)),
            _noAttribution(),
            bytes32(0),
            emptyFilePatch(),
            address(wallet),
            deadline,
            hex"deadbeef"
        );
    }

    function testPureFilePatchUsesEffectiveExecutor() public {
        UVPStateMachine machine = _executorMachine();
        FilePatch memory patch = _addFilePatch(0, keccak256("k1"), keccak256("content"));
        bytes32 digest = _fileModules[address(machine)].filePatchDigest(PLAN_ID, ORDER_ID, patch);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, bytes32(0), bytes32(0), bytes32(0), bytes32(0), _noAttribution(), digest, patch
        );
        (bool exists,,,) = _fileModules[address(machine)].getStageFile(PLAN_ID, ORDER_ID, STAGE_INIT, keccak256("k1"));
        require(exists, "file record missing");
    }

    function testPureFilePatchRejectsNonExecutor() public {
        UVPStateMachine machine = _executorMachine();
        FilePatch memory patch = _addFilePatch(0, keccak256("k2"), keccak256("content"));
        bytes32 digest = _fileModules[address(machine)].filePatchDigest(PLAN_ID, ORDER_ID, patch);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector, ORDER_ID, STAGE_INIT, bytes32(0), OUTSIDER
            )
        );
        vm.prank(OUTSIDER);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, bytes32(0), bytes32(0), bytes32(0), bytes32(0), _noAttribution(), digest, patch
        );
    }

    function testBusinessSignalWithFilePatchUsesEffectiveExecutor() public {
        UVPStateMachine machine = _executorMachine();
        FilePatch memory patch = _addFilePatch(0, keccak256("k3"), keccak256("content"));
        bytes32 digest = _fileModules[address(machine)].filePatchDigest(PLAN_ID, ORDER_ID, patch);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(48)),
            _noAttribution(),
            digest,
            patch
        );
        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_DONE), "business signal missing");
        (bool exists,,,) = _fileModules[address(machine)].getStageFile(PLAN_ID, ORDER_ID, STAGE_INIT, keccak256("k3"));
        require(exists, "file record missing");
    }

    function testDerivedSignalUsesEffectiveExecutor() public {
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_OPEN,
            targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: STAGE_AUDIT,
            targetSourceId: STAGE_AUDIT,
            signalId: SIGNAL_DERIVED,
            targetOrderRelation: 0
        });
        bytes32 planId = _registerPlan(machine, _executorPlan(), new StageSelectorBinding[](0), capabilities);
        _submitTriggerBirthWithAttribution(
            machine, planId, _capabilityAttribution(machine, planId, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BIRTH)
        );
        _submitWithAttribution(
            machine,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            _capabilityAttribution(machine, planId, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_OPEN)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory request = UVPDerivedSignalModule.DerivedSignalRequest({
            fromPlanId: planId,
            fromOrderId: ORDER_ID,
            fromStageId: STAGE_AUDIT,
            targetPlanId: planId,
            targetOrderId: ORDER_ID,
            targetSourceId: STAGE_AUDIT,
            signalId: SIGNAL_DERIVED,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(49))
        });
        UVPDerivedSignalModule.DerivedSignalProofs memory proofs = _derivedProofs(machine, planId, request);
        _derivedModules[address(machine)].submitDerivedSignal(request, address(this), proofs);
        require(machine.hasSignal(planId, ORDER_ID, STAGE_AUDIT, SIGNAL_DERIVED), "derived signal missing");
    }

    function testDerivedSignalRejectsNonExecutor() public {
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_OPEN,
            targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: STAGE_AUDIT,
            targetSourceId: STAGE_AUDIT,
            signalId: SIGNAL_DERIVED,
            targetOrderRelation: 0
        });
        bytes32 planId = _registerPlan(machine, _executorPlan(), new StageSelectorBinding[](0), capabilities);
        _submitTriggerBirthWithAttribution(
            machine, planId, _capabilityAttribution(machine, planId, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BIRTH)
        );
        _submitWithAttribution(
            machine,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            _capabilityAttribution(machine, planId, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_OPEN)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory request = UVPDerivedSignalModule.DerivedSignalRequest({
            fromPlanId: planId,
            fromOrderId: ORDER_ID,
            fromStageId: STAGE_AUDIT,
            targetPlanId: planId,
            targetOrderId: ORDER_ID,
            targetSourceId: STAGE_AUDIT,
            signalId: SIGNAL_DERIVED,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(50))
        });
        UVPDerivedSignalModule.DerivedSignalProofs memory proofs = _derivedProofs(machine, planId, request);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPDerivedSignalModule.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SIGNAL_DERIVED,
                OUTSIDER
            )
        );
        vm.prank(OUTSIDER);
        _derivedModules[address(machine)].submitDerivedSignal(request, OUTSIDER, proofs);
    }

    function testOrderLinkTriggerFromSignalRequiresNoAuthorizations() public {
        UVPStateMachine machine = _executorMachine();
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);

        address signer = vm.addr(BIRTH_PRIVATE_KEY);
        bytes32 payload = keccak256("linked");
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger =
            IUVPStateMachineCore.TriggerOrderFromSignalRequest({
            orderId: machine.orderLinkOrderIdFor(
                PLAN_ID, PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE, payload
            ),
            planId: PLAN_ID,
            creator: ORDER_CREATOR,
            triggerOriginOrderId: ORDER_ID,
            originPlanId: PLAN_ID,
            triggerHookId: HOOK_BIRTH,
            triggerStageId: STAGE_INIT,
            originSourceId: STAGE_AUDIT,
            originSignalId: SIGNAL_DONE,
            payloadHash: payload,
            idempotencyKey: bytes32(uint256(51)),
            submitter: signer,
            deadline: block.timestamp + 1 hours
        });
        UVPOrderLinkModule orderLink = UVPOrderLinkModule(machine.orderLinkModule());
        bytes32 digest = orderLink.triggerOrderFromSignalDigest(trigger);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BIRTH_PRIVATE_KEY, digest);
        orderLink.triggerOrderFromSignalFor(
            trigger, _packedSignature(v, r, s), new IUVPStateMachineCore.FactAttribution[](0)
        );
        require(machine.orderExists(PLAN_ID, trigger.orderId), "linked order missing");
        (bool exists,,,,,) = orderLink.getTriggerOriginLink(PLAN_ID, trigger.orderId);
        require(exists, "trigger origin link missing");
    }

    function testOrderLinkTriggerRejectsOutsiderRelayerWithoutConsent() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);

        address signer = vm.addr(BIRTH_PRIVATE_KEY);
        bytes32 payload = keccak256("linked-rejected");
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger =
            IUVPStateMachineCore.TriggerOrderFromSignalRequest({
            orderId: machine.orderLinkOrderIdFor(planId, planId, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE, payload),
            planId: planId,
            creator: ORDER_CREATOR,
            triggerOriginOrderId: ORDER_ID,
            originPlanId: planId,
            triggerHookId: HOOK_BIRTH,
            triggerStageId: STAGE_INIT,
            originSourceId: STAGE_AUDIT,
            originSignalId: SIGNAL_DONE,
            payloadHash: payload,
            idempotencyKey: bytes32(uint256(52)),
            submitter: signer,
            deadline: block.timestamp + 1 hours
        });
        UVPOrderLinkModule orderLink = UVPOrderLinkModule(machine.orderLinkModule());
        bytes32 digest = orderLink.triggerOrderFromSignalDigest(trigger);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BIRTH_PRIVATE_KEY, digest);
        vm.prank(address(uint160(0x9999)));
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedTriggerOrigin.selector, planId, ORDER_ID, signer
            )
        );
        orderLink.triggerOrderFromSignalFor(
            trigger, _packedSignature(v, r, s), new IUVPStateMachineCore.FactAttribution[](0)
        );
    }

    function testForkOrderWithoutAuthorizationsReplaysFacts() public {
        UVPStateMachine machine = _executorMachine();
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_DONE);

        bytes32 forkPayload = keccak256("fork");
        UVPStateMachine.ForkBirthFact[] memory facts = new UVPStateMachine.ForkBirthFact[](1);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY
        });
        bytes32 forkedOrderId =
            machine.forkOrder(PLAN_ID, ORDER_ID, forkPayload, SOURCE_BOOTSTRAP, SIGNAL_DONE, facts);
        require(machine.orderExists(PLAN_ID, forkedOrderId), "forked order missing");
        require(machine.orderParent(PLAN_ID, forkedOrderId) == ORDER_ID, "fork parent mismatch");
        require(
            machine.hasSignal(PLAN_ID, forkedOrderId, SOURCE_BOOTSTRAP, SIGNAL_BIRTH), "forked birth fact missing"
        );
    }

    function testTimerHookWaitsThenPokesReady() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _timerPlan());
        _submitTriggerBirth(machine, planId);
        vm.warp(block.timestamp + 5);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_TIMER);
        (UVPStateMachine.HookStatus status, uint64 dueAt,) = machine.getHookStatus(planId, ORDER_ID, HOOK_TIMER);
        require(status == UVPStateMachine.HookStatus.Wait, "timer not waiting");
        require(dueAt == block.timestamp + 7, "timer due mismatch");

        vm.expectRevert(UVPStateMachine.TimerNotDue.selector);
        machine.pokeTimer(planId, ORDER_ID, HOOK_TIMER);
        vm.warp(block.timestamp + 7);
        machine.pokeTimer(planId, ORDER_ID, HOOK_TIMER);
        bool readyEmitted;
        (status,, readyEmitted) = machine.getHookStatus(planId, ORDER_ID, HOOK_TIMER);
        require(status == UVPStateMachine.HookStatus.Ready, "timer hook not ready");
        require(readyEmitted, "timer ready marker missing");
    }

    function testNegativeSignalCancelsHook() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _vetoPlan());
        _submitTriggerBirth(machine, planId);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_VETO);
        (UVPStateMachine.HookStatus status,,) = machine.getHookStatus(planId, ORDER_ID, HOOK_VETO);
        require(status == UVPStateMachine.HookStatus.Cancelled, "hook not cancelled");
    }

    function testDuplicateSignalIsAbsorbedFirstWin() public {
        UVPStateMachine machine = _executorMachine();
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_DONE);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_DONE);
        address submitter;
        (,,,, submitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_DONE);
        require(submitter == address(this), "first writer overwritten");
        (uint256 count,,,) = machine.stageSignalState(PLAN_ID, ORDER_ID, STAGE_INIT);
        require(count >= 1, "stage count missing");
    }

    function testSetModuleRejectsEOATarget() public {
        UVPStateMachine machine = new UVPStateMachine();
        vm.expectRevert(UVPStateMachine.InvalidModuleAddress.selector);
        machine.setSupplierRegistry(NON_OWNER);
    }

    bytes32 private constant EMPTY_ROOT = keccak256("");

    function _newMachine() private returns (UVPStateMachine machine) {
        machine = _deployModules();
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        machine.setSupplierRegistry(address(registry));
        _registries[address(machine)] = registry;
        machine.freezeModules();
    }

    function _deployModules() private returns (UVPStateMachine machine) {
        machine = new UVPStateMachine();
        _patchModules[address(machine)] = new StagePatchActivationMock(address(machine));
        machine.setStagePatchModule(address(_patchModules[address(machine)]));
        UVPDerivedSignalModule derivedModule = new UVPDerivedSignalModule(address(machine));
        _derivedModules[address(machine)] = derivedModule;
        machine.setDerivedSignalModule(address(derivedModule));
        machine.setDockRegistry(address(new UVPDockRegistry(address(machine))));
        machine.setPlanMetadataModule(address(new UVPPlanMetadataModule(address(machine))));
        machine.setOrderLinkModule(address(new UVPOrderLinkModule(address(machine))));
        UVPFileResourceModule fileModule = new UVPFileResourceModule(address(machine));
        _fileModules[address(machine)] = fileModule;
        machine.setFileResourceModule(address(fileModule));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
    }

    function _deployModulesWithoutSupplierRegistry() private returns (UVPStateMachine machine) {
        machine = _deployModules();
    }

    function _supplierFor(UVPStateMachine machine, address executor) private returns (bytes32 supplierId) {
        supplierId = _suppliers[address(machine)][executor];
        if (supplierId != bytes32(0)) {
            return supplierId;
        }
        supplierId = keccak256(abi.encode("test.supplier", executor));
        _registries[address(machine)].registerSupplier(supplierId, executor);
        _suppliers[address(machine)][executor] = supplierId;
    }

    function _executorMachine() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _executorPlan());
        _submitTriggerBirth(machine, planId);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        require(machine.hasSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN), "audit stage not opened");
    }

    function _registerBirthMachine() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _birthPlan());
        _submitTriggerBirth(machine, planId);
    }

    function _submitTriggerBirth(UVPStateMachine machine, bytes32 planId) private {
        address signer = vm.addr(BIRTH_PRIVATE_KEY);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _birthTrigger(planId, signer);
        bytes32 digest = _triggerDigest(machine, trigger);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BIRTH_PRIVATE_KEY, digest);
        machine.triggerOrderFromOutsideFor(trigger, _packedSignature(v, r, s), _noAttribution());
        ORDER_ID = machine.triggerOrderIdFor(planId, SOURCE_BOOTSTRAP, SIGNAL_BIRTH, PAYLOAD_HASH);
        PLAN_ID = planId;
    }

    function _birthTrigger(bytes32 planId, address signer)
        private
        view
        returns (UVPStateMachine.TriggerOrderFromOutsideRequest memory)
    {
        return UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: planId,
            creator: ORDER_CREATOR,
            triggerHookId: HOOK_BIRTH,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: signer,
            deadline: block.timestamp + 1 hours
        });
    }

    function _triggerDigest(UVPStateMachine machine, UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger)
        private
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH,
                trigger.planId,
                trigger.creator,
                trigger.triggerHookId,
                trigger.triggerStageId,
                trigger.sourceId,
                trigger.signalId,
                trigger.payloadHash,
                trigger.idempotencyKey,
                trigger.submitter,
                trigger.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(machine), structHash));
    }

    function _submitTriggerBirthWithAttribution(
        UVPStateMachine machine,
        bytes32 planId,
        UVPStateMachine.FactAttribution memory attribution
    ) private {
        address signer = vm.addr(BIRTH_PRIVATE_KEY);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _birthTrigger(planId, signer);
        bytes32 digest = _triggerDigest(machine, trigger);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BIRTH_PRIVATE_KEY, digest);
        machine.triggerOrderFromOutsideFor(trigger, _packedSignature(v, r, s), attribution);
        ORDER_ID = machine.triggerOrderIdFor(planId, SOURCE_BOOTSTRAP, SIGNAL_BIRTH, PAYLOAD_HASH);
        PLAN_ID = planId;
    }

    function _submitWithAttribution(
        UVPStateMachine machine,
        bytes32 sourceId,
        bytes32 signalId,
        UVPStateMachine.FactAttribution memory attribution
    ) private {
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            sourceId,
            signalId,
            PAYLOAD_HASH,
            keccak256(abi.encode(sourceId, signalId)),
            attribution,
            bytes32(0),
            emptyFilePatch()
        );
    }

    function _capabilityAttribution(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 stageId,
        bytes32 sourceId,
        bytes32 signalId
    ) private view returns (UVPStateMachine.FactAttribution memory attribution) {
        bytes32 leaf = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, stageId, sourceId, signalId, uint256(0))
        );
        attribution = UVPStateMachine.FactAttribution({
            sourceId: sourceId,
            signalId: signalId,
            stageId: stageId,
            capabilityProof: _merkleProofFor(_tables[address(machine)][planId].sortedLeaves, leaf)
        });
    }

    function _submit(UVPStateMachine machine, bytes32 sourceId, bytes32 signalId) private {
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            sourceId,
            signalId,
            PAYLOAD_HASH,
            keccak256(abi.encode(sourceId, signalId)),
            _noAttribution(),
            bytes32(0),
            emptyFilePatch()
        );
    }

    function _registerPlan(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (bytes32 planId)
    {
        return _registerPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function _registerPlan(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities
    ) private returns (bytes32 planId) {
        planId = _commitPlan(
            machine,
            hooks,
            selectorBindings,
            signalCapabilities,
            _autoBindings(machine, hooks),
            PUBLISHER_PRIVATE_KEY
        );
        machine.finalizePlan(planId);
    }

    function _registerPlanWithBindings(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        SignalCapability[] memory signalCapabilities,
        UVPStateMachine.ExecutorBinding[] memory bindings
    ) private returns (bytes32 planId) {
        planId = _commitPlan(
            machine, hooks, new StageSelectorBinding[](0), signalCapabilities, bindings, PUBLISHER_PRIVATE_KEY
        );
        machine.finalizePlan(planId);
    }

    function _registerPlanWithBirthAuthorizer(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        SignalCapability[] memory signalCapabilities,
        address birthAuthorizer
    ) private returns (bytes32 planId) {
        UVPStateMachine.ExecutorBinding[] memory bindings = _autoBindings(machine, hooks);
        planId = _commitPlanWithAuthorizer(
            machine, hooks, new StageSelectorBinding[](0), signalCapabilities, bindings, PUBLISHER_PRIVATE_KEY, birthAuthorizer
        );
        machine.finalizePlan(planId);
    }

    function _commitPlan(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        UVPStateMachine.ExecutorBinding[] memory bindings,
        uint256 publisherPrivateKey
    ) private returns (bytes32 planId) {
        return _commitPlanWithAuthorizer(
            machine,
            hooks,
            selectorBindings,
            signalCapabilities,
            bindings,
            publisherPrivateKey,
            vm.addr(BIRTH_PRIVATE_KEY)
        );
    }

    function _commitPlanWithAuthorizer(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        UVPStateMachine.ExecutorBinding[] memory bindings,
        uint256 publisherPrivateKey,
        address birthAuthorizer
    ) private returns (bytes32 planId) {
        bytes32[] memory leaves = _capabilityLeaves(selectorBindings, signalCapabilities);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(publisherPrivateKey),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: MerkleCommitment.root(leaves),
            executorBindingsRoot: _bindingsRoot(bindings),
            birthAuthorizer: birthAuthorizer,
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherPrivateKey, _planCommitDigest(machine, commit));
        planId = machine.commitPlan(commit, hooks, bindings, _packedSignature(v, r, s));

        PLAN_ID = planId;
        CapabilityTables storage tables = _tables[address(machine)][planId];
        tables.sortedLeaves = _sortedUnique(leaves);
    }

    function _planCommit(
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        UVPStateMachine.ExecutorBinding[] memory bindings,
        address birthAuthorizer
    ) private returns (UVPStateMachine.PlanCommit memory commit) {
        commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: MerkleCommitment.root(_capabilityLeaves(selectorBindings, signalCapabilities)),
            executorBindingsRoot: _bindingsRoot(bindings),
            birthAuthorizer: birthAuthorizer,
            deadline: block.timestamp + 1 hours
        });
    }

    function _planCommitDigest(UVPStateMachine machine, UVPStateMachine.PlanCommit memory commit)
        private
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.capabilitiesRoot,
                commit.executorBindingsRoot,
                commit.birthAuthorizer,
                commit.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(machine), structHash));
    }

    function _signPlanCommit(UVPStateMachine machine, UVPStateMachine.PlanCommit memory commit, uint256 privateKey)
        private
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _planCommitDigest(machine, commit));
        return _packedSignature(v, r, s);
    }

    function _domainSeparator(UVPStateMachine machine) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                STATE_MACHINE_NAME_HASH,
                STATE_MACHINE_VERSION_HASH,
                block.chainid,
                address(machine)
            )
        );
    }

    function _signalSubmissionDigest(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        bytes32 filesDigest,
        UVPStateMachine.FactAttribution memory attribution,
        address submitter,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNAL_SUBMISSION_TYPEHASH,
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
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(machine), structHash));
    }

    function _attributionHash(UVPStateMachine.FactAttribution memory attribution) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FACT_ATTRIBUTION_TYPEHASH,
                attribution.sourceId,
                attribution.signalId,
                attribution.stageId,
                keccak256(abi.encode(attribution.capabilityProof))
            )
        );
    }

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0),
            signalId: bytes32(0),
            stageId: bytes32(0),
            capabilityProof: new bytes32[](0)
        });
    }

    function _packedSignature(uint8 v, bytes32 r, bytes32 s) private pure returns (bytes memory) {
        return abi.encodePacked(r, s, v);
    }

    function _autoBindings(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (UVPStateMachine.ExecutorBinding[] memory bindings)
    {
        bytes32[] memory stages = new bytes32[](hooks.length);
        uint8[] memory kinds = new uint8[](hooks.length);
        uint256 stageCount;
        for (uint256 i = 0; i < hooks.length; i++) {
            if (hooks[i].flags == FLAG_ADMISSION) {
                continue;
            }
            uint256 stageIndex = _stageIndex(stages, stageCount, hooks[i].stageId);
            if (stageIndex == type(uint256).max) {
                stageIndex = stageCount;
                stages[stageIndex] = hooks[i].stageId;
                stageCount += 1;
            }
            if (hooks[i].flags & FLAG_ORDER_TRIGGER_MINT != 0) {
                kinds[stageIndex] |= 1;
            }
            if (hooks[i].flags & FLAG_DOCK_EXECUTOR != 0) {
                kinds[stageIndex] |= 2;
            }
            if (hooks[i].flags & FLAG_DYNAMIC_EXECUTOR != 0) {
                kinds[stageIndex] |= 4;
            }
        }
        uint256 boundCount;
        for (uint256 i = 0; i < stageCount; i++) {
            if (kinds[i] & (2 | 4) == 0) {
                boundCount += 1;
            }
        }
        bindings = new UVPStateMachine.ExecutorBinding[](boundCount);
        uint256 cursor;
        for (uint256 i = 0; i < stageCount; i++) {
            if (kinds[i] & (2 | 4) != 0) {
                continue;
            }
            address executor = _stageExecutors[address(machine)][stages[i]];
            if (executor == address(0)) {
                executor = address(this);
            }
            bindings[cursor++] = UVPStateMachine.ExecutorBinding({
                stageId: stages[i],
                supplierId: _supplierFor(machine, executor),
                kind: 0
            });
        }
    }

    function _stageIndex(bytes32[] memory stages, uint256 stageCount, bytes32 stageId)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < stageCount; i++) {
            if (stages[i] == stageId) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _bindingsRoot(UVPStateMachine.ExecutorBinding[] memory bindings) private pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](bindings.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    EXECUTOR_BINDING_LEAF_DOMAIN, bindings[i].stageId, bindings[i].supplierId, bindings[i].kind
                )
            );
        }
        return MerkleCommitment.root(leaves);
    }

    function _capabilityLeaves(StageSelectorBinding[] memory selectorBindings, SignalCapability[] memory signalCapabilities)
        private
        pure
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](selectorBindings.length + signalCapabilities.length);
        for (uint256 i = 0; i < selectorBindings.length; i++) {
            leaves[i] = keccak256(
                abi.encode(
                    SELECTOR_BINDING_LEAF_DOMAIN, selectorBindings[i].selectorStageId, selectorBindings[i].targetStageId
                )
            );
        }
        for (uint256 i = 0; i < signalCapabilities.length; i++) {
            leaves[selectorBindings.length + i] = keccak256(
                abi.encode(
                    SIGNAL_CAPABILITY_LEAF_DOMAIN,
                    signalCapabilities[i].stageId,
                    signalCapabilities[i].targetSourceId,
                    signalCapabilities[i].signalId,
                    uint256(signalCapabilities[i].targetOrderRelation)
                )
            );
        }
    }

    function _derivedProofs(
        UVPStateMachine machine,
        bytes32 planId,
        UVPDerivedSignalModule.DerivedSignalRequest memory request
    ) private view returns (UVPDerivedSignalModule.DerivedSignalProofs memory proofs) {
        bytes32 leaf = keccak256(
            abi.encode(
                SIGNAL_CAPABILITY_LEAF_DOMAIN,
                request.fromStageId,
                request.targetSourceId,
                request.signalId,
                uint256(0)
            )
        );
        proofs.fromCapabilityProof = _merkleProofFor(_tables[address(machine)][planId].sortedLeaves, leaf);
        proofs.targetCapabilityProof = new bytes32[](0);
    }

    function _sortedUnique(bytes32[] memory raw) private pure returns (bytes32[] memory) {
        bytes32[] memory sorted = new bytes32[](raw.length);
        uint256 count;
        for (uint256 i = 0; i < raw.length; i++) {
            bool duplicate;
            for (uint256 j = 0; j < count; j++) {
                if (sorted[j] == raw[i]) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                sorted[count++] = raw[i];
            }
        }
        for (uint256 i = 1; i < count; i++) {
            bytes32 key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key;
        }
        bytes32[] memory exact = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            exact[i] = sorted[i];
        }
        return exact;
    }

    function _pairOf(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return left <= right ? keccak256(abi.encodePacked(left, right)) : keccak256(abi.encodePacked(right, left));
    }

    function _merkleProofFor(bytes32[] memory sorted, bytes32 leaf) private pure returns (bytes32[] memory proof) {
        uint256 index = type(uint256).max;
        for (uint256 i = 0; i < sorted.length; i++) {
            if (sorted[i] == leaf) {
                index = i;
                break;
            }
        }
        require(index != type(uint256).max, "test: leaf not in tree");
        bytes32[] memory buffer = new bytes32[](64);
        uint256 count;
        bytes32[] memory level = sorted;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) {
                buffer[count++] = level[sibling];
            }
            uint256 nextLength = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLength);
            uint256 cursor;
            for (uint256 i = 0; i + 1 < level.length; i += 2) {
                next[cursor++] = _pairOf(level[i], level[i + 1]);
            }
            if (level.length % 2 == 1) {
                next[cursor] = level[level.length - 1];
            }
            level = next;
            index /= 2;
        }
        proof = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            proof[i] = buffer[i];
        }
    }

    function _addFilePatch(bytes32 baseHash, bytes32 key, bytes32 contentHash)
        private
        pure
        returns (FilePatch memory patch)
    {
        FileOp[] memory ops = new FileOp[](1);
        ops[0] = FileOp({kind: 0, key: key, contentHash: contentHash, handle: "uvp://file/test"});
        patch = FilePatch({
            targetStageId: STAGE_INIT,
            baseHash: baseHash,
            writerStageId: bytes32(0),
            writerProof: new bytes32[](0),
            ops: ops
        });
    }

    function _birthPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
    }

    function _executorPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        hooks[1] = _signalHook(HOOK_OPEN, STAGE_AUDIT, SIGNAL_OPEN, FLAG_EMIT_READY, SOURCE_BOOTSTRAP);
        hooks[2] = _signalHook(HOOK_DONE, STAGE_AUDIT, SIGNAL_DONE, FLAG_EMIT_READY, STAGE_AUDIT);
    }

    function _dynamicPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        hooks[1] = _signalHook(
            HOOK_DYN_OPEN, STAGE_DYN, SIGNAL_OPEN, FLAG_EMIT_READY | FLAG_DYNAMIC_EXECUTOR, SOURCE_BOOTSTRAP
        );
    }

    function _dockPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        hooks[1] = _signalHook(HOOK_DOCK_OPEN, STAGE_DOCK, SIGNAL_OPEN, FLAG_EMIT_READY | FLAG_DOCK_EXECUTOR, SOURCE_BOOTSTRAP);
        hooks[2] = _signalHook(HOOK_DOCK_DONE, STAGE_DOCK, SIGNAL_DONE, FLAG_DOCK_EXECUTOR, SOURCE_BOOTSTRAP);
    }

    function _timerPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_TIMER,
            arity: 0,
            delaySeconds: 0
        });
        instructions[1] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 7
        });
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_TIMER,
            stageId: STAGE_INIT,
            hookName: keccak256("timer.hook"),
            flags: FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: _depsOf(instructions)
        });
    }

    function _vetoPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_VETO,
            arity: 0,
            delaySeconds: 0
        });
        instructions[1] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
        instructions[2] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_TIMER,
            arity: 0,
            delaySeconds: 0
        });
        instructions[3] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.And),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 2,
            delaySeconds: 0
        });
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_VETO,
            stageId: STAGE_INIT,
            hookName: keccak256("veto.hook"),
            flags: FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: _depsOf(instructions)
        });
    }

    function _signalHook(bytes32 hookId, bytes32 stageId, bytes32 signalId, uint8 flags, bytes32 sourceId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: sourceId,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: keccak256(abi.encode(hookId)),
            flags: flags,
            instructions: instructions,
            dependencyKeys: _depsOf(instructions)
        });
    }

    function _depsOf(UVPStateMachine.Instruction[] memory instructions) private pure returns (bytes32[] memory deps) {
        bytes32[] memory buffer = new bytes32[](instructions.length);
        uint256 count;
        for (uint256 i = 0; i < instructions.length; i++) {
            if (instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            bytes32 key = keccak256(abi.encode(instructions[i].sourceId, instructions[i].signalId));
            bool seen;
            for (uint256 j = 0; j < count; j++) {
                if (buffer[j] == key) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                buffer[count++] = key;
            }
        }
        deps = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            deps[i] = buffer[i];
        }
    }
}
