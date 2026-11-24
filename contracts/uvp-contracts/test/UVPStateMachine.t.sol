// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {AdmissionVerdict} from "../src/UVPStateMachineConstants.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPDockRegistry} from "../src/UVPDockRegistry.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {IUVPDockRegistry} from "../src/interfaces/IUVPDockRegistry.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {UVPIdentityRegistry} from "../src/UVPIdentityRegistry.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
import {StageFile} from "../src/interfaces/IUVPFileResourceModule.sol";
import {MerkleCommitment} from "../src/libraries/MerkleCommitment.sol";
import {emptyStageFiles} from "./StageFileTestHelpers.sol";

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

contract Eip1271SupplierAccount {
    bytes4 private constant _MAGIC = 0x1626ba7e;

    bool public valid = true;

    function setValid(bool nextValid) external {
        valid = nextValid;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return valid ? _MAGIC : bytes4(0xffffffff);
    }

    function registerSupplier(UVPIdentityRegistry registry) external returns (bytes32 supplierId) {
        supplierId = registry.registerSupplier(address(this));
    }
}

contract StagePatchActivationMock {
    address private immutable _machine;

    constructor(address machineAddress) {
        _machine = machineAddress;
    }

    function activateSupplier(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        uint256 patchNonce
    ) external {
        IUVPStateMachineCore(_machine).activateStageSupplierFromModule(
            planId, orderId, targetStageId, supplierId, patchNonce
        );
    }

    function activateDockSupplier(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 supplierId,
        bytes32 dockId,
        uint256 patchNonce
    ) external {
        IUVPStateMachineCore(_machine).activateStageDockSupplierFromModule(
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
    bytes32 private constant STAGE_OBSERVER_A = bytes32(uint256(0x5005));
    bytes32 private constant STAGE_OBSERVER_B = bytes32(uint256(0x5006));
    bytes32 private constant STAGE_WATCH = bytes32(uint256(0x5007));
    bytes32 private constant EXTERNAL_SOURCE = bytes32(uint256(0x3ff1));

    bytes32 private constant SIGNAL_BIRTH = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_OPEN = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_DONE = bytes32(uint256(0x4002));
    bytes32 private constant SIGNAL_TIMER = bytes32(uint256(0x4003));
    bytes32 private constant SIGNAL_BLOCKED = bytes32(uint256(0x400a));
    bytes32 private constant SIGNAL_CANCEL = bytes32(uint256(0x4009));
    bytes32 private constant SIGNAL_VETO = bytes32(uint256(0x4004));
    bytes32 private constant SIGNAL_DERIVED = bytes32(uint256(0x4005));
    bytes32 private constant SIGNAL_SHARED = bytes32(uint256(0x4006));
    bytes32 private constant SIGNAL_WATCH_PRE = bytes32(uint256(0x4007));
    bytes32 private constant SIGNAL_WATCH_OPEN = bytes32(uint256(0x4008));

    bytes32 private constant HOOK_BIRTH = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_OPEN = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_DONE = bytes32(uint256(0x6002));
    bytes32 private constant HOOK_DYN_OPEN = bytes32(uint256(0x6003));
    bytes32 private constant HOOK_DOCK_OPEN = bytes32(uint256(0x6004));
    bytes32 private constant HOOK_DOCK_DONE = bytes32(uint256(0x6007));
    bytes32 private constant HOOK_TIMER = bytes32(uint256(0x6005));
    bytes32 private constant HOOK_VETO = bytes32(uint256(0x6006));
    bytes32 private constant HOOK_DECAY_REGISTRATION = bytes32(uint256(0x6008));
    bytes32 private constant HOOK_DECAY_POKE = bytes32(uint256(0x6009));
    bytes32 private constant HOOK_OBSERVER_A = bytes32(uint256(0x6010));
    bytes32 private constant HOOK_OBSERVER_B = bytes32(uint256(0x6011));
    bytes32 private constant HOOK_WATCH_PRE = bytes32(uint256(0x6012));
    bytes32 private constant HOOK_WATCH_OPEN = bytes32(uint256(0x6013));

    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant DOCK_ID = bytes32(uint256(0xd0c1));

    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_ADMISSION = 8;
    uint8 private constant FLAG_DOCK_EXECUTOR = 16;
    uint8 private constant FLAG_DYNAMIC_EXECUTOR = 32;

    address private constant SUPPLIER_ACCOUNT_A = address(uint160(0xa11ce));
    address private constant OUTSIDER = address(uint160(0xbad));
    address private constant NON_OWNER = address(uint160(0xf01));

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant BIRTH_PRIVATE_KEY = 0xbeef;
    uint256 private constant SIGNAL_PRIVATE_KEY = 0xb51;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("1");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 supplierBindingsRoot,bytes32 fileWritersHash,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignalSubmission(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 targetStageId,bytes32 filesHash,bytes32 attributionHash,address submitter,uint256 deadline)"
    );
    bytes32 private constant ORDER_TRIGGERED_TOPIC =
        keccak256("OrderTriggered(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)");
    bytes32 private constant FACT_ATTRIBUTION_TYPEHASH =
        keccak256("FactAttribution(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)");
    bytes32 private constant SUPPLIER_BINDING_LEAF_DOMAIN = keccak256("UVP_SUPPLIER_BINDING_V1");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant STAGE_MATERIALIZED_TOPIC =
        keccak256("StageMaterialized(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)");
    bytes32 private constant HOOK_READY_TOPIC = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)");

    mapping(address machine => UVPIdentityRegistry) private _registries;
    mapping(address machine => UVPFileResourceModule) private _fileModules;
    mapping(address machine => UVPDerivedSignalModule) private _derivedModules;
    mapping(address machine => StagePatchActivationMock) private _patchModules;
    mapping(address machine => mapping(address account => bytes32 supplierId)) private _suppliers;
    mapping(address machine => mapping(bytes32 stageId => address account)) private _stageSupplierAccounts;
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

    function testFreezeRequiresIdentityRegistryModule() public {
        UVPStateMachine machine = _deployModulesWithoutIdentityRegistry();
        vm.expectRevert(UVPStateMachine.IncompleteModuleConfiguration.selector);
        machine.freezeModules();

        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        machine.setIdentityRegistry(address(registry));
        machine.freezeModules();
        require(machine.modulesFrozen(), "modules not frozen");
        require(machine.identityRegistry() == address(registry), "registry slot missing");
    }

    function testFrozenModulesCannotBeReconfigured() public {
        UVPStateMachine machine = _newMachine();
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        address replacementPatch = address(new StagePatchActivationMock(address(machine)));
        vm.expectRevert(UVPStateMachine.ModulesFrozen.selector);
        machine.setIdentityRegistry(address(registry));
        vm.expectRevert(UVPStateMachine.ModulesFrozen.selector);
        machine.setStagePatchModule(replacementPatch);
    }

    function testCommitPlanRequiresFrozenModules() public {
        UVPStateMachine machine = _deployModulesWithoutIdentityRegistry();
        UVPStateMachine.CompactHook[] memory hooks = _birthPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](0);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(UVPStateMachine.ModulesNotFrozen.selector);
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
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

    function testCommitPlanStoresSupplierBindingsState() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        bytes32 supplierThis = _supplierFor(machine, address(this));
        bytes32 supplierA = _supplierFor(machine, SUPPLIER_ACCOUNT_A);
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory withCandidate =
            new UVPStateMachine.StageSupplierBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withCandidate[i] = bindings[i];
        }
        withCandidate[bindings.length] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_AUDIT,
            supplierId: supplierA,
            kind: 1
        });

        bytes32 planId = _commitPlan(
            machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withCandidate, PUBLISHER_PRIVATE_KEY
        );
        require(
            machine.planSupplierBindingsRoot(planId) == _bindingsRoot(withCandidate), "bindings root mismatch"
        );
        require(machine.planStageDefaultSupplier(planId, STAGE_INIT) == supplierThis, "init supplier mismatch");
        require(machine.planStageDefaultSupplier(planId, STAGE_AUDIT) == supplierThis, "audit supplier mismatch");
        require(machine.planStageIsCandidate(planId, STAGE_AUDIT), "candidate stage flag missing");
        require(!machine.planStageIsCandidate(planId, STAGE_INIT), "init must not be candidate");
        require(!machine.planStageHasDynamicSupplier(planId, STAGE_AUDIT), "unexpected dynamic flag");
    }

    function testDynamicPlanMarksDynamicStageWithoutBinding() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _dynamicPlan());
        require(machine.planStageHasDynamicSupplier(planId, STAGE_DYN), "dynamic stage flag missing");
        require(machine.planStageDefaultSupplier(planId, STAGE_DYN) == bytes32(0), "dynamic stage must be unbound");
        _submitTriggerBirth(machine, planId);
        require(machine.effectiveStageSupplier(planId, ORDER_ID, STAGE_DYN) == bytes32(0), "dynamic supplier must be zero");
    }

    function testCommitPlanRejectsBindingsRootMismatch() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        commit.supplierBindingsRoot = bytes32(uint256(0x1234));
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.SupplierBindingsRootMismatch.selector, bytes32(uint256(0x1234)), _bindingsRoot(bindings)
            )
        );
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsTooManySupplierBindings() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _birthPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](257);
        bytes32 supplierId = _supplierFor(machine, address(this));
        for (uint256 i = 0; i < bindings.length; i++) {
            bindings[i] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_INIT, supplierId: supplierId, kind: 0});
        }
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.TooManySupplierBindings.selector, 257));
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsDuplicateSupplierBinding() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory duplicated =
            new UVPStateMachine.StageSupplierBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            duplicated[i] = bindings[i];
        }
        duplicated[bindings.length] = bindings[0];
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), duplicated
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.DuplicateSupplierBinding.selector, bindings[0].stageId, bindings[0].supplierId, bindings[0].kind
            )
        );
        machine.commitPlan(commit, hooks, duplicated, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsInactiveSupplier() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        bytes32 unknownSupplier = keccak256("unknown-supplier");
        bindings[0].supplierId = unknownSupplier;
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SupplierNotActive.selector, unknownSupplier));
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsBindingForUnknownStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory withUnknown =
            new UVPStateMachine.StageSupplierBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withUnknown[i] = bindings[i];
        }
        withUnknown[bindings.length] = UVPStateMachine.StageSupplierBinding({
            stageId: bytes32(uint256(0x7777)),
            supplierId: _supplierFor(machine, SUPPLIER_ACCOUNT_A),
            kind: 0
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withUnknown
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnknownPlanStage.selector, bytes32(uint256(0x7777)))
        );
        machine.commitPlan(commit, hooks, withUnknown, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsBindingOnDynamicStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _dynamicPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory withDynamic =
            new UVPStateMachine.StageSupplierBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withDynamic[i] = bindings[i];
        }
        withDynamic[bindings.length] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_DYN,
            supplierId: _supplierFor(machine, SUPPLIER_ACCOUNT_A),
            kind: 0
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withDynamic
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SupplierBindingForbiddenForStage.selector, STAGE_DYN)
        );
        machine.commitPlan(commit, hooks, withDynamic, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsBindingOnDockStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _dockPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory withDock = new UVPStateMachine.StageSupplierBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withDock[i] = bindings[i];
        }
        withDock[bindings.length] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_DOCK,
            supplierId: _supplierFor(machine, SUPPLIER_ACCOUNT_A),
            kind: 0
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withDock
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SupplierBindingForbiddenForStage.selector, STAGE_DOCK)
        );
        machine.commitPlan(commit, hooks, withDock, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsCandidateOnBirthStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory withCandidate =
            new UVPStateMachine.StageSupplierBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withCandidate[i] = bindings[i];
        }
        withCandidate[bindings.length] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_INIT,
            supplierId: _supplierFor(machine, SUPPLIER_ACCOUNT_A),
            kind: 1
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withCandidate
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.CandidateSupplierBindingForbiddenForStage.selector, STAGE_INIT)
        );
        machine.commitPlan(commit, hooks, withCandidate, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsCandidateWithoutDefault() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory candidatesOnly =
            new UVPStateMachine.StageSupplierBinding[](bindings.length);
        uint256 count;
        for (uint256 i = 0; i < bindings.length; i++) {
            if (bindings[i].stageId == STAGE_AUDIT) {
                continue;
            }
            candidatesOnly[count++] = bindings[i];
        }
        candidatesOnly[count] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_AUDIT,
            supplierId: _supplierFor(machine, SUPPLIER_ACCOUNT_A),
            kind: 1
        });
        UVPStateMachine.StageSupplierBinding[] memory trimmed = new UVPStateMachine.StageSupplierBinding[](count + 1);
        for (uint256 i = 0; i < count + 1; i++) {
            trimmed[i] = candidatesOnly[i];
        }
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), trimmed
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.CandidateSupplierBindingRequiresDefault.selector, STAGE_AUDIT)
        );
        machine.commitPlan(commit, hooks, trimmed, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsInvalidBindingKind() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.StageSupplierBinding[] memory withInvalid =
            new UVPStateMachine.StageSupplierBinding[](bindings.length + 1);
        for (uint256 i = 0; i < bindings.length; i++) {
            withInvalid[i] = bindings[i];
        }
        withInvalid[bindings.length] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_AUDIT,
            supplierId: _supplierFor(machine, SUPPLIER_ACCOUNT_A),
            kind: 2
        });
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), withInvalid
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidSupplierBindingKind.selector, 2));
        machine.commitPlan(commit, hooks, withInvalid, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsInconsistentDynamicSupplierFlag() public {
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
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.InconsistentDynamicSupplierFlag.selector, STAGE_DYN)
        );
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsWrongPublisherSignature() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        bytes memory signature = _signPlanCommit(machine, commit, BIRTH_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidPlanSignature.selector, vm.addr(PUBLISHER_PRIVATE_KEY), vm.addr(BIRTH_PRIVATE_KEY)
            )
        );
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsExpiredSignature() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        vm.warp(block.timestamp + 2 hours);
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredPlanSignature.selector, commit.deadline));
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testCommitPlanRejectsHooksHashMismatch() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        UVPStateMachine.PlanCommit memory commit = _planCommit(
            hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings
        );
        commit.hooksHash = bytes32(uint256(0x1234));
        bytes memory signature = _signPlanCommit(machine, commit, PUBLISHER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.HooksHashMismatch.selector, bytes32(uint256(0x1234)), keccak256(abi.encode(hooks))
            )
        );
        machine.commitPlan(commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), signature);
    }

    function testPlanCommittedEventCarriesSupplierBindingsRoot() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _supplierPlan();
        UVPStateMachine.StageSupplierBinding[] memory bindings = _autoBindings(machine, hooks);
        vm.recordLogs();
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0), bindings, PUBLISHER_PRIVATE_KEY);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("PlanCommitted(bytes32,bytes32,address,bytes32,bytes32,uint256,bytes32)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                (bytes32 hooksHash, bytes32 capabilitiesRoot, uint256 hookCount, bytes32 bindingsRoot) =
                    abi.decode(logs[i].data, (bytes32, bytes32, uint256, bytes32));
                require(hooksHash == keccak256(abi.encode(hooks)), "event hooks hash");
                require(capabilitiesRoot == EMPTY_ROOT, "event capabilities root");
                require(hookCount == hooks.length, "event hook count");
                require(bindingsRoot == _bindingsRoot(bindings), "event bindings root");
                found = true;
            }
        }
        require(found, "PlanCommitted not emitted");
    }


    function testBirthTriggerCreatesOrderAndMaterializesStage() public {
        UVPStateMachine machine = _registerBirthMachine();
        require(ORDER_ID != bytes32(0), "generated order id missing");
        require(machine.orderExists(PLAN_ID, ORDER_ID), "order missing");
        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_BIRTH), "birth fact missing");
        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_BIRTH);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");
    }

    function testDuplicateTriggerKeyRejectsReplayAndKeepsExistingOrder() public {
        UVPStateMachine machine = _registerBirthMachine();
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: PLAN_ID,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: _noAttribution(),
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.DuplicateTriggerKey.selector, address(this), IDEMPOTENCY_KEY, ORDER_ID
            )
        );
        machine.submitSignal(submission, hex"");
        require(machine.orderExists(PLAN_ID, ORDER_ID), "existing order disappeared");
    }

    function testDifferentTriggerKeyCreatesDifferentOrder() public {
        UVPStateMachine machine = _registerBirthMachine();
        bytes32 firstOrderId = ORDER_ID;
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: PLAN_ID,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: keccak256("second-key"),
            attribution: _noAttribution(),
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
        (bytes32 secondOrderId, bool secondInserted) = machine.submitSignal(submission, hex"");
        require(secondInserted, "second trigger birth must report inserted");
        require(secondOrderId != firstOrderId, "second order id collided");
        require(machine.orderExists(PLAN_ID, secondOrderId), "second order missing");
    }

    function testNonTriggerSignalWithoutOrderRevertsNotTriggerSignal() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _supplierPlan());
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: STAGE_AUDIT,
            signalId: SIGNAL_DONE,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: _noAttribution(),
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.NotTriggerSignal.selector, STAGE_AUDIT, SIGNAL_DONE)
        );
        machine.submitSignal(submission, hex"");
    }


    function testTriggerSignalOnExistingOrderHasNoTriggerPrivilege() public {
        UVPStateMachine machine = _registerBirthMachine();
        vm.recordLogs();
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_BIRTH);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 triggeredOrders;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 3 && logs[i].topics[0] == ORDER_TRIGGERED_TOPIC
                    && logs[i].topics[1] == ORDER_ID && logs[i].topics[2] == PLAN_ID
            ) {
                triggeredOrders += 1;
            }
        }
        require(triggeredOrders == 0, "trigger signal minted an order");
        require(_countLogs(logs, HOOK_READY_TOPIC, PLAN_ID, ORDER_ID) == 0, "trigger hook re-announced on duplicate");

        UVPStateMachine.SignalSubmission memory replay = _businessSubmission(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_BIRTH, _noAttribution(), address(this)
        );
        replay.payloadHash = bytes32(uint256(0xdead));
        replay.idempotencyKey = bytes32(uint256(0xbeef));
        machine.submitSignal(replay, hex"");
        (bool exists, bytes32 payloadHash,,,) =
            machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_BIRTH);
        require(exists, "birth fact missing after duplicate submit");
        require(payloadHash == PAYLOAD_HASH, "duplicate trigger signal rewrote the first write");
    }

    function testTriggerBirthReturnsGeneratedOrderIdAndInsertedTrue() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _birthPlan());
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: _noAttribution(),
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
        (bytes32 createdOrderId, bool inserted) = machine.submitSignal(submission, hex"");
        require(inserted, "trigger birth must report inserted");
        require(createdOrderId != bytes32(0), "trigger birth must return a generated order id");
        require(machine.orderExists(planId, createdOrderId), "returned order id does not exist");
    }

    function testBusinessSignalReturnsOrderIdAndInsertedFlag() public {
        UVPStateMachine machine = _supplierMachine();
        UVPStateMachine.SignalSubmission memory submission =
            _businessSubmission(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE, _noAttribution(), address(this));
        (bytes32 insertedOrderId, bool inserted) = machine.submitSignal(submission, hex"");
        require(insertedOrderId == ORDER_ID, "new signal must return the input order id");
        require(inserted, "new signal must report inserted");
        (bytes32 duplicateOrderId, bool duplicateInserted) = machine.submitSignal(submission, hex"");
        require(duplicateOrderId == ORDER_ID, "duplicate signal must return the input order id");
        require(!duplicateInserted, "duplicate signal must report not inserted");
    }

    function testTriggerWithFilesCreatesOrderAndWritesFiles() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _birthPlan());
        StageFile[] memory files = _oneFile("birth-file", bytes("birth-content"));
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: _noAttribution(),
            targetStageId: STAGE_INIT,
            files: files,
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
        (bytes32 orderId, bool inserted) = machine.submitSignal(submission, hex"");
        require(inserted, "trigger with file must report inserted");
        require(machine.orderExists(planId, orderId), "trigger order missing");
        (bool exists, bytes memory payload) =
            _fileModules[address(machine)].getStageFile(planId, orderId, STAGE_INIT, "birth-file");
        require(exists, "birth file patch missing");
        require(keccak256(payload) == keccak256(bytes("birth-content")), "birth file content mismatch");
    }

    function testTriggerWithFailedFilesRevertsWholeOrderCreation() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _birthPlan());
        bytes32 unknownStageId = keccak256("unknown-target-stage");
        StageFile[] memory files = _oneFile("failed-file", bytes("content"));
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: _noAttribution(),
            targetStageId: unknownStageId,
            files: files,
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.FileTargetStageUnknown.selector, planId, unknownStageId)
        );
        machine.submitSignal(submission, hex"");

        submission.targetStageId = STAGE_INIT;
        submission.files = emptyStageFiles();
        (bytes32 orderId, bool inserted) = machine.submitSignal(submission, hex"");
        require(inserted, "retried trigger birth must report inserted");
        require(machine.orderExists(planId, orderId), "retry after reverted birth did not create the order");
        (bool exists,) = _fileModules[address(machine)].getStageFile(planId, orderId, STAGE_INIT, "failed-file");
        require(!exists, "reverted birth file patch leaked into the order");
    }

    function testDirectSubmitSignalRejectsSubmitterThatIsNotCaller() public {
        UVPStateMachine machine = _supplierMachine();
        UVPStateMachine.SignalSubmission memory submission =
            _businessSubmission(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_DONE, _noAttribution(), OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnauthorizedDirectSubmitter.selector, OUTSIDER, address(this))
        );
        machine.submitSignal(submission, hex"");
    }

    function testCrossStageObservationMaterializesBothStages() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _crossStageObservationPlan());
        _submitTriggerBirth(machine, planId);

        vm.recordLogs();
        _submit(machine, STAGE_INIT, SIGNAL_SHARED);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 materializedA = _logIndexOf(logs, STAGE_MATERIALIZED_TOPIC, planId, ORDER_ID, STAGE_OBSERVER_A);
        uint256 materializedB = _logIndexOf(logs, STAGE_MATERIALIZED_TOPIC, planId, ORDER_ID, STAGE_OBSERVER_B);
        uint256 readyA = _logIndexOf(logs, HOOK_READY_TOPIC, planId, ORDER_ID, HOOK_OBSERVER_A);
        uint256 readyB = _logIndexOf(logs, HOOK_READY_TOPIC, planId, ORDER_ID, HOOK_OBSERVER_B);
        require(materializedA != type(uint256).max, "observer A stage not materialized");
        require(materializedB != type(uint256).max, "observer B stage not materialized");
        require(readyA != type(uint256).max, "observer A hook ready missing");
        require(readyB != type(uint256).max, "observer B hook ready missing");
        require(_countLogs(logs, HOOK_READY_TOPIC, planId, ORDER_ID) == 2, "expected exactly two HookReady");
        require(materializedA < readyA && materializedB < readyB, "HookReady must follow its stage materialization");
        require(readyA < readyB, "HookReady order must follow stage hook registration order");

        (UVPStateMachine.HookStatus statusA,, bool emittedA) = machine.getHookStatus(planId, ORDER_ID, HOOK_OBSERVER_A);
        (UVPStateMachine.HookStatus statusB,, bool emittedB) = machine.getHookStatus(planId, ORDER_ID, HOOK_OBSERVER_B);
        require(statusA == UVPStateMachine.HookStatus.Ready && emittedA, "observer A not ready");
        require(statusB == UVPStateMachine.HookStatus.Ready && emittedB, "observer B not ready");
    }

    function testWatcherReadyBeforeMaterializationFlushesHookReady() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _watcherFlushPlan());
        _submitTriggerBirth(machine, planId);

        vm.recordLogs();
        _submit(machine, STAGE_INIT, SIGNAL_WATCH_PRE);
        Vm.Log[] memory preLogs = vm.getRecordedLogs();

        (UVPStateMachine.HookStatus preStatus,, bool preEmitted) =
            machine.getHookStatus(planId, ORDER_ID, HOOK_WATCH_PRE);
        require(preStatus == UVPStateMachine.HookStatus.Ready, "watcher not ready before materialization");
        require(!preEmitted, "watcher announced before materialization");
        require(
            _logIndexOf(preLogs, STAGE_MATERIALIZED_TOPIC, planId, ORDER_ID, STAGE_WATCH) == type(uint256).max,
            "watch stage materialized too early"
        );
        require(
            _logIndexOf(preLogs, HOOK_READY_TOPIC, planId, ORDER_ID, HOOK_WATCH_PRE) == type(uint256).max,
            "watcher announced too early"
        );

        vm.recordLogs();
        _submit(machine, STAGE_INIT, SIGNAL_WATCH_OPEN);
        Vm.Log[] memory openLogs = vm.getRecordedLogs();

        uint256 materialized = _logIndexOf(openLogs, STAGE_MATERIALIZED_TOPIC, planId, ORDER_ID, STAGE_WATCH);
        uint256 readyPre = _logIndexOf(openLogs, HOOK_READY_TOPIC, planId, ORDER_ID, HOOK_WATCH_PRE);
        uint256 readyOpen = _logIndexOf(openLogs, HOOK_READY_TOPIC, planId, ORDER_ID, HOOK_WATCH_OPEN);
        require(materialized != type(uint256).max, "watch stage not materialized");
        require(readyPre != type(uint256).max, "pre-ready watcher HookReady was dropped");
        require(readyOpen != type(uint256).max, "materializer HookReady missing");
        require(_countLogs(openLogs, HOOK_READY_TOPIC, planId, ORDER_ID) == 2, "expected exactly two HookReady");
        require(materialized < readyPre, "watcher HookReady must follow materialization");
        require(readyPre < readyOpen, "flush order must follow stage hook registration order");

        (UVPStateMachine.HookStatus statusPre,, bool emittedPre) =
            machine.getHookStatus(planId, ORDER_ID, HOOK_WATCH_PRE);
        (UVPStateMachine.HookStatus statusOpen,, bool emittedOpen) =
            machine.getHookStatus(planId, ORDER_ID, HOOK_WATCH_OPEN);
        require(statusPre == UVPStateMachine.HookStatus.Ready && emittedPre, "watcher not flushed");
        require(statusOpen == UVPStateMachine.HookStatus.Ready && emittedOpen, "materializer not ready");
    }

    function testDefaultSupplierBoundSubmitRecordsSignal() public {
        UVPStateMachine machine = _supplierMachine();
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);
        require(machine.hasSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE), "signal missing");
        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE);
        require(submitter == address(this), "submitter mismatch");
        (UVPStateMachine.HookStatus status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_DONE);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
    }

    function testSubmitSignalRejectsUnauthorizedSupplierAccount() public {
        UVPStateMachine machine = _supplierMachine();
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageSupplierAccount.selector, ORDER_ID, STAGE_INIT, OUTSIDER, address(this)
            )
        );
        _submitAs(machine, SOURCE_BOOTSTRAP, SIGNAL_DONE, OUTSIDER);
    }

    function testSubmitSignalRejectsUnknownSourceStage() public {
        UVPStateMachine machine = _supplierMachine();
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SignalStageUnknown.selector, PLAN_ID, EXTERNAL_SOURCE, SIGNAL_DONE)
        );
        _submit(machine, EXTERNAL_SOURCE, SIGNAL_DONE);
    }

    function testEffectiveStageSupplierViews() public {
        UVPStateMachine machine = _supplierMachine();
        bytes32 supplierId = _supplierFor(machine, address(this));
        require(machine.effectiveStageSupplier(PLAN_ID, ORDER_ID, STAGE_INIT) == supplierId, "supplier mismatch");
        require(machine.effectiveStageAccount(PLAN_ID, ORDER_ID, STAGE_INIT) == address(this), "account mismatch");
        require(machine.isEffectiveStageAccount(PLAN_ID, ORDER_ID, STAGE_INIT, address(this)), "account not effective");
        require(!machine.isEffectiveStageAccount(PLAN_ID, ORDER_ID, STAGE_INIT, OUTSIDER), "outsider effective");
    }

    function testActivateStageSupplierFromModuleSwitchesEffectiveSupplier() public {
        UVPStateMachine machine = _supplierMachine();
        bytes32 supplierA = _supplierFor(machine, SUPPLIER_ACCOUNT_A);
        vm.recordLogs();
        _patchModules[address(machine)].activateSupplier(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bytes32 patchedSupplier, uint256 patchNonce, bytes32 dockId) =
            machine.stageSupplierAssignment(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(patchedSupplier == supplierA, "patch supplier mismatch");
        require(patchNonce == 1, "patch nonce mismatch");
        require(dockId == bytes32(0), "unexpected dock id");
        require(machine.effectiveStageSupplier(PLAN_ID, ORDER_ID, STAGE_AUDIT) == supplierA, "effective supplier mismatch");

        bytes32 topic = keccak256("StageSupplierAssigned(bytes32,bytes32,bytes32,bytes32,uint256)");
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
        require(found, "StageSupplierAssigned not emitted");

        _submitAs(machine, STAGE_AUDIT, SIGNAL_DONE, SUPPLIER_ACCOUNT_A);
        require(machine.hasSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE), "patched supplier signal missing");

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageSupplierAccount.selector, ORDER_ID, STAGE_AUDIT, address(this), SUPPLIER_ACCOUNT_A
            )
        );
        _submit(machine, STAGE_AUDIT, SIGNAL_TIMER);
    }

    function testActivateDockSupplierRecordsDockId() public {
        UVPStateMachine machine = _supplierMachine();
        bytes32 supplierA = _supplierFor(machine, SUPPLIER_ACCOUNT_A);
        _patchModules[address(machine)].activateDockSupplier(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, DOCK_ID, 1);
        (bytes32 supplierId, uint256 patchNonce, bytes32 dockId) =
            machine.stageSupplierAssignment(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(supplierId == supplierA, "dock supplier mismatch");
        require(patchNonce == 1, "dock nonce mismatch");
        require(dockId == DOCK_ID, "dock id mismatch");
    }

    function testActivateStageSupplierRejectsNonIncreasingNonce() public {
        UVPStateMachine machine = _supplierMachine();
        bytes32 supplierA = _supplierFor(machine, SUPPLIER_ACCOUNT_A);
        _patchModules[address(machine)].activateSupplier(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.StageSupplierPatchNonceNotIncreasing.selector, ORDER_ID, STAGE_AUDIT, 2, 2
            )
        );
        _patchModules[address(machine)].activateSupplier(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 2);
    }

    function testActivateStageSupplierRejectsUnauthorizedCaller() public {
        UVPStateMachine machine = _supplierMachine();
        bytes32 supplierA = _supplierFor(machine, SUPPLIER_ACCOUNT_A);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.UnauthorizedStateMachineModule.selector, OUTSIDER));
        machine.activateStageSupplierFromModule(PLAN_ID, ORDER_ID, STAGE_AUDIT, supplierA, 1);
    }

    function testDynamicStageRequiresAssignmentBeforeSignal() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _dynamicPlan());
        _submitTriggerBirth(machine, planId);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        require(machine.orderExists(planId, ORDER_ID), "dynamic order missing");

        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageSupplierNotAssigned.selector, ORDER_ID, STAGE_DYN)
        );
        _submit(machine, STAGE_DYN, SIGNAL_DONE);

        bytes32 supplierA = _supplierFor(machine, SUPPLIER_ACCOUNT_A);
        _patchModules[address(machine)].activateSupplier(planId, ORDER_ID, STAGE_DYN, supplierA, 1);
        _submitAs(machine, STAGE_DYN, SIGNAL_DONE, SUPPLIER_ACCOUNT_A);
        require(machine.hasSignal(planId, ORDER_ID, STAGE_DYN, SIGNAL_DONE), "dynamic signal missing");
    }

    function testSubmitSignalRejectsSuspendedSupplier() public {
        UVPStateMachine machine = _supplierMachine();
        bytes32 supplierId = _supplierFor(machine, address(this));
        _registries[address(machine)].suspendSupplier(supplierId);
        require(machine.effectiveStageAccount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == address(0), "suspended account");
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SupplierNotActive.selector, supplierId));
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);
    }

    function testSubmitSignalRejectsRevokedSupplier() public {
        UVPStateMachine machine = _supplierMachine();
        bytes32 supplierId = _supplierFor(machine, address(this));
        _registries[address(machine)].revokeSupplier(supplierId);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SupplierNotActive.selector, supplierId));
        _submit(machine, STAGE_AUDIT, SIGNAL_DONE);
    }

    function testSubmitSignalRejectsPendingSupplierAssignment() public {
        UVPStateMachine machine = _supplierMachine();
        address pendingAccount = address(uint160(0x9e9));
        vm.prank(pendingAccount);
        bytes32 pendingSupplierId = _registries[address(machine)].registerSupplier(pendingAccount);
        _patchModules[address(machine)].activateSupplier(PLAN_ID, ORDER_ID, STAGE_AUDIT, pendingSupplierId, 1);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SupplierNotActive.selector, pendingSupplierId));
        _submitAs(machine, STAGE_AUDIT, SIGNAL_DONE, pendingAccount);
    }

    function testRelayedSubmitSignalRecoversSubmitter() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        _stageSupplierAccounts[address(machine)][STAGE_INIT] = signer;
        bytes32 planId = _registerPlan(machine, _supplierPlan());
        _submitTriggerBirth(machine, planId);

        UVPStateMachine.SignalSubmission memory submission = _businessSubmission(
            planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, _noAttribution(), signer
        );
        submission.idempotencyKey = bytes32(uint256(42));
        vm.prank(address(uint160(0x1234)));
        machine.submitSignal(submission, _signSignalSubmission(machine, submission, SIGNAL_PRIVATE_KEY));
        (,,,, address submitter) = machine.getSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        require(submitter == signer, "signed submitter mismatch");
    }


    function testRelayedSubmitSignalRejectsWrongSigner() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        _stageSupplierAccounts[address(machine)][STAGE_INIT] = signer;
        bytes32 planId = _registerPlan(machine, _supplierPlan());
        _submitTriggerBirth(machine, planId);

        UVPStateMachine.SignalSubmission memory submission = _businessSubmission(
            planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, _noAttribution(), signer
        );
        submission.idempotencyKey = bytes32(uint256(43));
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalSubmitterSignature.selector, signer, vm.addr(BIRTH_PRIVATE_KEY)
            )
        );
        machine.submitSignal(submission, _signSignalSubmission(machine, submission, BIRTH_PRIVATE_KEY));
    }


    function testRelayedSubmitSignalRejectsExpiredDeadline() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        _stageSupplierAccounts[address(machine)][STAGE_INIT] = signer;
        bytes32 planId = _registerPlan(machine, _supplierPlan());
        _submitTriggerBirth(machine, planId);
        vm.warp(block.timestamp + 2 hours);
        uint256 deadline = block.timestamp - 1;
        UVPStateMachine.SignalSubmission memory submission = _businessSubmission(
            planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, _noAttribution(), signer
        );
        submission.idempotencyKey = bytes32(uint256(44));
        submission.deadline = deadline;
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredSignalSignature.selector, deadline));
        machine.submitSignal(submission, hex"");
    }


    function testRelayedSubmitSignalRejectsSignerThatIsNotSupplierAccount() public {
        UVPStateMachine machine = _newMachine();
        address signer = vm.addr(SIGNAL_PRIVATE_KEY);
        bytes32 planId = _registerPlan(machine, _supplierPlan());
        _submitTriggerBirth(machine, planId);

        UVPStateMachine.SignalSubmission memory submission = _businessSubmission(
            planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, _noAttribution(), signer
        );
        submission.idempotencyKey = bytes32(uint256(45));
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageSupplierAccount.selector, ORDER_ID, STAGE_INIT, signer, address(this)
            )
        );
        machine.submitSignal(submission, _signSignalSubmission(machine, submission, SIGNAL_PRIVATE_KEY));
    }


    function testEip1271SupplierAccountRelayedSubmitAccepted() public {
        UVPStateMachine machine = _newMachine();
        Eip1271SupplierAccount wallet = new Eip1271SupplierAccount();
        _stageSupplierAccounts[address(machine)][STAGE_INIT] = address(wallet);
        bytes32 planId = _registerPlan(machine, _supplierPlan());
        _submitTriggerBirth(machine, planId);

        UVPStateMachine.SignalSubmission memory submission = _businessSubmission(
            planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, _noAttribution(), address(wallet)
        );
        submission.idempotencyKey = bytes32(uint256(46));
        machine.submitSignal(submission, hex"deadbeef");
        (,,,, address submitter) = machine.getSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        require(submitter == address(wallet), "1271 submitter mismatch");
    }


    function testEip1271SupplierAccountRelayedSubmitRejected() public {
        UVPStateMachine machine = _newMachine();
        Eip1271SupplierAccount wallet = new Eip1271SupplierAccount();
        _stageSupplierAccounts[address(machine)][STAGE_INIT] = address(wallet);
        bytes32 planId = _registerPlan(machine, _supplierPlan());
        _submitTriggerBirth(machine, planId);
        wallet.setValid(false);
        UVPStateMachine.SignalSubmission memory submission = _businessSubmission(
            planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN, _noAttribution(), address(wallet)
        );
        submission.idempotencyKey = bytes32(uint256(47));
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidEIP1271Signature.selector, address(wallet)));
        machine.submitSignal(submission, hex"deadbeef");
    }


    function testPureFilesUseEffectiveSupplierAccount() public {
        UVPStateMachine machine = _supplierMachine();
        _submitFilesAs(machine, STAGE_INIT, _oneFile("k1", bytes("content")), address(this));
        (bool exists, bytes memory payload) =
            _fileModules[address(machine)].getStageFile(PLAN_ID, ORDER_ID, STAGE_INIT, "k1");
        require(exists, "file record missing");
        require(keccak256(payload) == keccak256(bytes("content")), "file payload mismatch");
    }


    function testPureFilesRejectNonSupplierAccount() public {
        UVPStateMachine machine = _supplierMachine();
        UVPStateMachine.SignalSubmission memory submission =
            _fileSubmission(PLAN_ID, ORDER_ID, STAGE_INIT, _oneFile("k2", bytes("content")), OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.FileWriterUnauthorized.selector, ORDER_ID, STAGE_INIT, OUTSIDER)
        );
        vm.prank(OUTSIDER);
        machine.submitSignal(submission, hex"");
    }



    function testBusinessSignalWithFilesUsesEffectiveSupplierAccount() public {
        UVPStateMachine machine = _supplierMachine();
        _submitBusinessWithFiles(machine, SOURCE_BOOTSTRAP, SIGNAL_DONE, _oneFile("k3", bytes("content")));
        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_DONE), "business signal missing");
        (bool exists,) = _fileModules[address(machine)].getStageFile(PLAN_ID, ORDER_ID, STAGE_INIT, "k3");
        require(exists, "file record missing");
    }


    function testDerivedSignalUsesEffectiveSupplierAccount() public {
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
        bytes32 planId = _registerPlan(machine, _supplierPlan(), new StageSelectorBinding[](0), capabilities);
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

    function testDockOutputWaitsForBWindowThenEmits() public {
        (UVPStateMachine machine, UVPStagePatchModule stagePatch) = _newDockMachine();

        SignalCapability[] memory aCapabilities = new SignalCapability[](3);
        aCapabilities[0] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            targetOrderRelation: 0
        });
        aCapabilities[1] = SignalCapability({
            stageId: STAGE_AUDIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_OPEN,
            targetOrderRelation: 0
        });
        aCapabilities[2] = SignalCapability({
            stageId: STAGE_AUDIT,
            targetSourceId: STAGE_AUDIT,
            signalId: SIGNAL_DONE,
            targetOrderRelation: 0
        });
        bytes32 planA = _registerPlan(machine, _supplierPlan(), new StageSelectorBinding[](0), aCapabilities);
        _submitTriggerBirthWithAttribution(
            machine, planA, _capabilityAttribution(machine, planA, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BIRTH)
        );
        bytes32 orderA = ORDER_ID;

        SignalCapability[] memory bCapabilities = new SignalCapability[](6);
        bCapabilities[0] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            targetOrderRelation: 0
        });
        bCapabilities[1] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_OPEN,
            targetOrderRelation: 0
        });
        bCapabilities[2] = SignalCapability({
            stageId: STAGE_DOCK,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_DONE,
            targetOrderRelation: 0
        });
        bCapabilities[3] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_TIMER,
            targetOrderRelation: 0
        });
        bCapabilities[4] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_CANCEL,
            targetOrderRelation: 0
        });
        bCapabilities[5] = SignalCapability({
            stageId: STAGE_DOCK,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BLOCKED,
            targetOrderRelation: 0
        });

        UVPStateMachine.Instruction[] memory admissionInstrs = new UVPStateMachine.Instruction[](1);
        admissionInstrs[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_TIMER,
            arity: 0,
            delaySeconds: 0
        });
        UVPStateMachine.CompactHook[] memory baseHooks = _dockPlan();
        UVPStateMachine.Instruction[] memory blockedInstrs = new UVPStateMachine.Instruction[](2);
        blockedInstrs[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_CANCEL,
            arity: 0,
            delaySeconds: 0
        });
        blockedInstrs[1] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
        UVPStateMachine.CompactHook[] memory bHooks = new UVPStateMachine.CompactHook[](baseHooks.length + 2);
        for (uint256 i = 0; i < baseHooks.length; i++) {
            bHooks[i] = baseHooks[i];
        }
        bHooks[baseHooks.length] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_DONE)),
            stageId: STAGE_DOCK,
            hookName: SIGNAL_DONE,
            flags: 8,
            instructions: admissionInstrs,
            dependencyKeys: _depsOf(admissionInstrs)
        });
        bHooks[baseHooks.length + 1] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_BLOCKED)),
            stageId: STAGE_DOCK,
            hookName: SIGNAL_BLOCKED,
            flags: 8,
            instructions: blockedInstrs,
            dependencyKeys: _depsOf(blockedInstrs)
        });
        bytes32 planB = _registerPlan(machine, bHooks, new StageSelectorBinding[](0), bCapabilities);
        UVPStateMachine.SignalSubmission memory birthB = UVPStateMachine.SignalSubmission({
            planId: planB,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: keccak256("dock.b.birth.payload"),
            idempotencyKey: keccak256("dock.b.birth.idempotency"),
            attribution: _capabilityAttribution(machine, planB, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BIRTH),
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: _triggerSubmitter(machine),
            deadline: block.timestamp + 1 hours
        });
        (bytes32 orderB, bool insertedB) = _submitEnvelope(machine, birthB);
        require(insertedB, "dock B birth must report inserted");
        ORDER_ID = orderB;
        _submitWithAttribution(
            machine,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            _capabilityAttribution(machine, planB, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_OPEN)
        );

        bytes32[] memory aProof =
            _capabilityAttribution(machine, planA, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BIRTH).capabilityProof;
        _submitWithAttribution(
            machine,
            SOURCE_BOOTSTRAP,
            SIGNAL_CANCEL,
            _capabilityAttribution(machine, planB, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_CANCEL)
        );
        bytes32[] memory bProof =
            _capabilityAttribution(machine, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, SIGNAL_DONE).capabilityProof;
        bytes32[] memory blockedProof =
            _capabilityAttribution(machine, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, SIGNAL_BLOCKED).capabilityProof;

        IUVPDockRegistry.DockAtomInput[] memory atoms = new IUVPDockRegistry.DockAtomInput[](1);
        atoms[0] = IUVPDockRegistry.DockAtomInput({
            stageId: STAGE_INIT,
            signalId: SIGNAL_BIRTH,
            relation: 0,
            capabilityProof: aProof
        });
        IUVPStateMachineCore.WindowInstruction[] memory window = new IUVPStateMachineCore.WindowInstruction[](1);
        window[0] = IUVPStateMachineCore.WindowInstruction({
            op: 0,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            arity: 0,
            delaySeconds: 0
        });
        IUVPDockRegistry.DockOutputInput[] memory outputs = new IUVPDockRegistry.DockOutputInput[](2);
        outputs[0] = IUVPDockRegistry.DockOutputInput({
            signalId: SIGNAL_DONE,
            relation: 0,
            atoms: atoms,
            window: window,
            capabilityProof: bProof
        });
        outputs[1] = IUVPDockRegistry.DockOutputInput({
            signalId: SIGNAL_BLOCKED,
            relation: 0,
            atoms: atoms,
            window: window,
            capabilityProof: blockedProof
        });
        bytes32 docHash = keccak256("dock.test.doc");
        IUVPDockRegistry dockRegistry = IUVPDockRegistry(machine.dockRegistry());
        bytes32 dkid =
            dockRegistry.registerDock(planA, SOURCE_BOOTSTRAP, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, docHash, outputs);
        require(dkid == keccak256(abi.encode(docHash, planA, planB, keccak256(abi.encode(outputs)))), "dock id mismatch");

        bytes32 supplierId = _supplierFor(machine, address(this));
        vm.prank(address(stagePatch));
        machine.activateStageDockSupplierFromModule(planB, orderB, STAGE_DOCK, supplierId, dkid, 1);

        bytes memory payload = _dockPayload(orderA);
        StageFile[] memory files = _oneFile("dock_link", payload);
        UVPFileResourceModule fileModule = UVPFileResourceModule(machine.fileResourceModule());
        vm.prank(address(machine));
        fileModule.applyStageFiles(planB, orderB, STAGE_DOCK, files, address(this));

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = bProof;
        proofs[1] = blockedProof;
        vm.recordLogs();
        uint256 emitted = stagePatch.pokeDockBinding(planB, orderB, STAGE_DOCK, payload, orderA, proofs);
        require(emitted == 0, "waiting B window must not emit");
        require(!machine.hasSignal(planB, orderB, SOURCE_BOOTSTRAP, SIGNAL_DONE), "waiting B output was recorded");
        require(!machine.hasSignal(planB, orderB, SOURCE_BOOTSTRAP, SIGNAL_BLOCKED), "blocked B output was recorded");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 deferredTopic =
            keccak256("DockOutputDeferred(bytes32,bytes32,bytes32,uint256,bytes32,uint8,uint64)");
        bool deferred;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == deferredTopic) {
                deferred = true;
            }
        }
        require(deferred, "waiting B window must be reported as deferred");
        (AdmissionVerdict verdict,) = stagePatch.dockOutputAdmissionVerdict(planB, orderB, STAGE_DOCK, 0);
        require(verdict == AdmissionVerdict.Wait, "B window must read Wait");

        _submitWithAttribution(
            machine,
            SOURCE_BOOTSTRAP,
            SIGNAL_TIMER,
            _capabilityAttribution(machine, planB, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_TIMER)
        );
        (verdict,) = stagePatch.dockOutputAdmissionVerdict(planB, orderB, STAGE_DOCK, 0);
        require(verdict == AdmissionVerdict.Ready, "B window must become Ready");
        (verdict,) = stagePatch.dockOutputAdmissionVerdict(planB, orderB, STAGE_DOCK, 1);
        require(verdict == AdmissionVerdict.Impossible, "cancelled B window must read Impossible");
        emitted = stagePatch.pokeDockBinding(planB, orderB, STAGE_DOCK, payload, orderA, proofs);
        require(emitted == 1, "ready B window must emit exactly once");
        require(machine.hasSignal(planB, orderB, SOURCE_BOOTSTRAP, SIGNAL_DONE), "dock output fact missing");
        require(!machine.hasSignal(planB, orderB, SOURCE_BOOTSTRAP, SIGNAL_BLOCKED), "impossible output was recorded");

        (bool current, bool aSatisfied,, bool bSatisfied, bool outputEmitted) =
            stagePatch.dockOutputWindow(planB, orderB, STAGE_DOCK, orderA, 0);
        require(current && aSatisfied && bSatisfied && outputEmitted, "dock window readback mismatch");
        (current, aSatisfied,, bSatisfied, outputEmitted) =
            stagePatch.dockOutputWindow(planB, orderB, STAGE_DOCK, orderA, 1);
        require(current && aSatisfied && !bSatisfied && !outputEmitted, "impossible window readback mismatch");
    }

    function testDockIdScopingAllowsDistinctPlanPairsAndDistinctOutputs() public {
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory aCapabilities = new SignalCapability[](1);
        aCapabilities[0] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            targetOrderRelation: 0
        });
        bytes32 planA = _registerPlan(machine, _dockPlan(), new StageSelectorBinding[](0), aCapabilities);

        SignalCapability[] memory bCapabilities = new SignalCapability[](2);
        bCapabilities[0] = SignalCapability({
            stageId: STAGE_DOCK,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_DONE,
            targetOrderRelation: 0
        });
        bCapabilities[1] = SignalCapability({
            stageId: STAGE_DOCK,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BLOCKED,
            targetOrderRelation: 0
        });
        UVPStateMachine.CompactHook[] memory baseHooks = _dockPlan();
        UVPStateMachine.CompactHook[] memory bHooks = new UVPStateMachine.CompactHook[](baseHooks.length + 2);
        for (uint256 i = 0; i < baseHooks.length; i++) {
            bHooks[i] = baseHooks[i];
        }
        UVPStateMachine.Instruction[] memory doneInstrs = new UVPStateMachine.Instruction[](1);
        doneInstrs[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_DONE,
            arity: 0,
            delaySeconds: 0
        });
        bHooks[baseHooks.length] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_DONE)),
            stageId: STAGE_DOCK,
            hookName: SIGNAL_DONE,
            flags: 8,
            instructions: doneInstrs,
            dependencyKeys: _depsOf(doneInstrs)
        });
        UVPStateMachine.Instruction[] memory blockedInstrs = new UVPStateMachine.Instruction[](1);
        blockedInstrs[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BLOCKED,
            arity: 0,
            delaySeconds: 0
        });
        bHooks[baseHooks.length + 1] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_BLOCKED)),
            stageId: STAGE_DOCK,
            hookName: SIGNAL_BLOCKED,
            flags: 8,
            instructions: blockedInstrs,
            dependencyKeys: _depsOf(blockedInstrs)
        });
        bytes32 planB = _registerPlan(machine, bHooks, new StageSelectorBinding[](0), bCapabilities);

        UVPStateMachine.CompactHook[] memory cHooks = new UVPStateMachine.CompactHook[](baseHooks.length + 2);
        for (uint256 i = 0; i < baseHooks.length; i++) {
            cHooks[i] = baseHooks[i];
        }
        cHooks[baseHooks.length] = bHooks[baseHooks.length];
        cHooks[baseHooks.length + 1] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TIMER)),
            stageId: STAGE_DOCK,
            hookName: SIGNAL_TIMER,
            flags: 8,
            instructions: blockedInstrs,
            dependencyKeys: _depsOf(blockedInstrs)
        });
        bytes32 planC = _registerPlan(machine, cHooks, new StageSelectorBinding[](0), bCapabilities);

        bytes32[] memory aProof =
            _capabilityAttribution(machine, planA, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BIRTH).capabilityProof;
        bytes32[] memory bProofDone =
            _capabilityAttribution(machine, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, SIGNAL_DONE).capabilityProof;
        bytes32[] memory bProofBlocked =
            _capabilityAttribution(machine, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, SIGNAL_BLOCKED).capabilityProof;
        bytes32[] memory cProofDone =
            _capabilityAttribution(machine, planC, STAGE_DOCK, SOURCE_BOOTSTRAP, SIGNAL_DONE).capabilityProof;

        IUVPDockRegistry.DockAtomInput[] memory atoms = new IUVPDockRegistry.DockAtomInput[](1);
        atoms[0] = IUVPDockRegistry.DockAtomInput({
            stageId: STAGE_INIT,
            signalId: SIGNAL_BIRTH,
            relation: 0,
            capabilityProof: aProof
        });
        IUVPStateMachineCore.WindowInstruction[] memory window = new IUVPStateMachineCore.WindowInstruction[](1);
        window[0] = IUVPStateMachineCore.WindowInstruction({
            op: 0,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            arity: 0,
            delaySeconds: 0
        });

        IUVPDockRegistry.DockOutputInput[] memory outputsReal = new IUVPDockRegistry.DockOutputInput[](1);
        outputsReal[0] = IUVPDockRegistry.DockOutputInput({
            signalId: SIGNAL_DONE,
            relation: 0,
            atoms: atoms,
            window: window,
            capabilityProof: bProofDone
        });

        IUVPDockRegistry.DockOutputInput[] memory outputsSquatter = new IUVPDockRegistry.DockOutputInput[](1);
        outputsSquatter[0] = IUVPDockRegistry.DockOutputInput({
            signalId: SIGNAL_BLOCKED,
            relation: 0,
            atoms: atoms,
            window: window,
            capabilityProof: bProofBlocked
        });

        IUVPDockRegistry.DockOutputInput[] memory outputsPlanC = new IUVPDockRegistry.DockOutputInput[](1);
        outputsPlanC[0] = IUVPDockRegistry.DockOutputInput({
            signalId: SIGNAL_DONE,
            relation: 0,
            atoms: atoms,
            window: window,
            capabilityProof: cProofDone
        });

        bytes32 docHash = keccak256("dock.shared.doc");
        IUVPDockRegistry dockRegistry = IUVPDockRegistry(machine.dockRegistry());

        bytes32 dkidSquatter = dockRegistry.registerDock(
            planA, SOURCE_BOOTSTRAP, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, docHash, outputsSquatter
        );
        bytes32 dkidReal = dockRegistry.registerDock(
            planA, SOURCE_BOOTSTRAP, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, docHash, outputsReal
        );
        bytes32 dkidPlanC = dockRegistry.registerDock(
            planA, SOURCE_BOOTSTRAP, planC, STAGE_DOCK, SOURCE_BOOTSTRAP, docHash, outputsPlanC
        );

        require(dkidSquatter != dkidReal, "different outputs must produce distinct dkid");
        require(dkidReal != dkidPlanC, "different plan pair must produce distinct dkid");
        require(dockRegistry.dockExists(dkidSquatter), "squatter dock missing");
        require(dockRegistry.dockExists(dkidReal), "real dock missing");
        require(dockRegistry.dockExists(dkidPlanC), "second plan pair dock missing");

        vm.expectRevert(abi.encodeWithSelector(UVPDockRegistry.DockAlreadyRegistered.selector, dkidReal));
        dockRegistry.registerDock(
            planA, SOURCE_BOOTSTRAP, planB, STAGE_DOCK, SOURCE_BOOTSTRAP, docHash, outputsReal
        );
    }

    function testDockOutputWriteRevertsWhenAdmissionNotReady() public {
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory capabilities = new SignalCapability[](4);
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
            signalId: SIGNAL_DONE,
            targetOrderRelation: 0
        });
        capabilities[3] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_TIMER,
            targetOrderRelation: 0
        });

        UVPStateMachine.Instruction[] memory admissionInstrs = new UVPStateMachine.Instruction[](1);
        admissionInstrs[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_TIMER,
            arity: 0,
            delaySeconds: 0
        });
        UVPStateMachine.CompactHook[] memory baseHooks = _supplierPlan();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](baseHooks.length + 1);
        for (uint256 i = 0; i < baseHooks.length; i++) {
            hooks[i] = baseHooks[i];
        }
        hooks[baseHooks.length] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(STAGE_AUDIT, SIGNAL_DONE)),
            stageId: STAGE_AUDIT,
            hookName: SIGNAL_DONE,
            flags: 8,
            instructions: admissionInstrs,
            dependencyKeys: _depsOf(admissionInstrs)
        });
        bytes32 planId = _registerPlan(machine, hooks, new StageSelectorBinding[](0), capabilities);
        _submitTriggerBirthWithAttribution(
            machine, planId, _capabilityAttribution(machine, planId, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BIRTH)
        );
        _submitWithAttribution(
            machine,
            SOURCE_BOOTSTRAP,
            SIGNAL_OPEN,
            _capabilityAttribution(machine, planId, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_OPEN)
        );

        UVPStateMachine.FactAttribution memory attribution =
            _capabilityAttribution(machine, planId, STAGE_AUDIT, STAGE_AUDIT, SIGNAL_DONE);
        address stagePatch = address(_patchModules[address(machine)]);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE
            )
        );
        vm.prank(stagePatch);
        machine.submitDockOutputSignalFromModule(
            planId, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this), attribution
        );

        _submitWithAttribution(
            machine,
            SOURCE_BOOTSTRAP,
            SIGNAL_TIMER,
            _capabilityAttribution(machine, planId, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_TIMER)
        );
        vm.prank(stagePatch);
        bool submitted = machine.submitDockOutputSignalFromModule(
            planId, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this), attribution
        );
        require(submitted, "dock output not submitted after admission became ready");
        require(machine.hasSignal(planId, ORDER_ID, STAGE_AUDIT, SIGNAL_DONE), "dock output fact missing");
    }

    function testDerivedSignalDuplicateDoesNotEmitSubmitted() public {
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
        bytes32 planId = _registerPlan(machine, _supplierPlan(), new StageSelectorBinding[](0), capabilities);
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
            idempotencyKey: bytes32(uint256(51))
        });
        UVPDerivedSignalModule.DerivedSignalProofs memory proofs = _derivedProofs(machine, planId, request);
        _derivedModules[address(machine)].submitDerivedSignal(request, address(this), proofs);

        vm.recordLogs();
        _derivedModules[address(machine)].submitDerivedSignal(request, address(this), proofs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 derivedSignalSubmittedTopic = keccak256(
            "DerivedSignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,uint8)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            require(logs[i].topics[0] != derivedSignalSubmittedTopic, "duplicate derived signal emitted an event");
        }
        require(machine.hasSignal(planId, ORDER_ID, STAGE_AUDIT, SIGNAL_DERIVED), "derived signal missing");
    }

    function testDerivedSignalRejectsNonSupplierAccount() public {
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
        bytes32 planId = _registerPlan(machine, _supplierPlan(), new StageSelectorBinding[](0), capabilities);
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

    function testReadyDecayingVetoDueAtSurvivesRegistrationEvaluation() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _decayingVetoRegistrationPlan());
        _submitTriggerBirth(machine, planId);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_VETO);
        (,,, uint64 vetoSubmittedAt,) = machine.getSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VETO);
        vm.warp(vetoSubmittedAt + 1);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        (UVPStateMachine.HookStatus status, uint64 dueAt,) =
            machine.getHookStatus(planId, ORDER_ID, HOOK_DECAY_REGISTRATION);
        require(status == UVPStateMachine.HookStatus.Ready, "decaying veto not ready");
        require(dueAt == vetoSubmittedAt + 5, "ready dueAt dropped on registration path");
    }

    function testReadyDecayingVetoDueAtSurvivesPokeTimerEvaluation() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _decayingVetoPokePlan());
        _submitTriggerBirth(machine, planId);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        (,,, uint64 openSubmittedAt,) = machine.getSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_OPEN);
        vm.warp(openSubmittedAt + 8);
        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_VETO);
        (,,, uint64 vetoSubmittedAt,) = machine.getSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VETO);
        (UVPStateMachine.HookStatus status, uint64 dueAt,) =
            machine.getHookStatus(planId, ORDER_ID, HOOK_DECAY_POKE);
        require(status == UVPStateMachine.HookStatus.Wait, "timer leg not waiting");
        require(dueAt == openSubmittedAt + 10, "wait dueAt must follow the timer leg");
        vm.warp(openSubmittedAt + 10);
        machine.pokeTimer(planId, ORDER_ID, HOOK_DECAY_POKE);
        (status, dueAt,) = machine.getHookStatus(planId, ORDER_ID, HOOK_DECAY_POKE);
        require(status == UVPStateMachine.HookStatus.Ready, "decaying veto not ready after poke");
        require(dueAt == vetoSubmittedAt + 5, "ready dueAt dropped on poke path");
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
        UVPStateMachine machine = _supplierMachine();
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
        machine.setIdentityRegistry(NON_OWNER);
    }

    bytes32 private constant EMPTY_ROOT = keccak256("");

    function _logIndexOf(Vm.Log[] memory logs, bytes32 topic, bytes32 planId, bytes32 orderId, bytes32 subjectId)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 4 && logs[i].topics[0] == topic && logs[i].topics[1] == planId
                    && logs[i].topics[2] == orderId && logs[i].topics[3] == subjectId
            ) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 topic, bytes32 planId, bytes32 orderId)
        private
        pure
        returns (uint256 count)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length >= 3 && logs[i].topics[0] == topic && logs[i].topics[1] == planId
                    && logs[i].topics[2] == orderId
            ) {
                count += 1;
            }
        }
    }

    function _newDockMachine() private returns (UVPStateMachine machine, UVPStagePatchModule stagePatch) {
        machine = new UVPStateMachine();
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        _registries[address(machine)] = registry;
        stagePatch = new UVPStagePatchModule(address(machine));
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(new UVPDerivedSignalModule(address(machine))));
        machine.setDockRegistry(address(new UVPDockRegistry(address(machine))));
        machine.setPlanMetadataModule(address(new UVPPlanMetadataModule(address(machine))));
        machine.setFileResourceModule(address(new UVPFileResourceModule(address(machine))));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
        machine.setIdentityRegistry(address(registry));
        machine.freezeModules();
    }

    function _dockPayload(bytes32 orderId) private pure returns (bytes memory payload) {
        bytes memory digits = bytes("0123456789abcdef");
        bytes memory encoded = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 value = uint8(orderId[i]);
            encoded[i * 2] = digits[value >> 4];
            encoded[i * 2 + 1] = digits[value & 0x0f];
        }
        payload = abi.encodePacked("0x", encoded);
    }

    function _newMachine() private returns (UVPStateMachine machine) {
        machine = _deployModules();
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        machine.setIdentityRegistry(address(registry));
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
        UVPFileResourceModule fileModule = new UVPFileResourceModule(address(machine));
        _fileModules[address(machine)] = fileModule;
        machine.setFileResourceModule(address(fileModule));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
    }

    function _deployModulesWithoutIdentityRegistry() private returns (UVPStateMachine machine) {
        machine = _deployModules();
    }

    function _supplierFor(UVPStateMachine machine, address account) private returns (bytes32 supplierId) {
        supplierId = _suppliers[address(machine)][account];
        if (supplierId != bytes32(0)) {
            return supplierId;
        }
        UVPIdentityRegistry registry = _registries[address(machine)];
        if (account == address(this)) {
            supplierId = registry.registerSupplier(account);
        } else if (account.code.length != 0) {
            supplierId = Eip1271SupplierAccount(account).registerSupplier(registry);
        } else {
            vm.prank(account);
            supplierId = registry.registerSupplier(account);
        }
        registry.activateSupplier(supplierId);
        _suppliers[address(machine)][account] = supplierId;
    }

    function _supplierMachine() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _supplierPlan());
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
        _submitTriggerBirthWithAttribution(machine, planId, _noAttribution());
    }


    function _submitTriggerBirthWithAttribution(
        UVPStateMachine machine,
        bytes32 planId,
        UVPStateMachine.FactAttribution memory attribution
    ) private {
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: attribution,
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: _triggerSubmitter(machine),
            deadline: block.timestamp + 1 hours
        });
        (bytes32 createdOrderId, bool inserted) = _submitEnvelope(machine, submission);
        require(inserted, "trigger birth must report inserted");
        ORDER_ID = createdOrderId;
        PLAN_ID = planId;
    }

    function _triggerSubmitter(UVPStateMachine machine) private view returns (address) {
        address submitter = _stageSupplierAccounts[address(machine)][STAGE_INIT];
        return submitter == address(0) ? address(this) : submitter;
    }

    function _submitEnvelope(UVPStateMachine machine, UVPStateMachine.SignalSubmission memory submission)
        private
        returns (bytes32 orderId, bool inserted)
    {
        if (submission.submitter == address(this)) {
            return machine.submitSignal(submission, hex"");
        }
        bytes memory signature = submission.submitter.code.length == 0
            ? _signSignalSubmission(machine, submission, _privateKeyFor(submission.submitter))
            : bytes(hex"01");
        return machine.submitSignal(submission, signature);
    }



    function _privateKeyFor(address account) private returns (uint256) {
        if (account == vm.addr(BIRTH_PRIVATE_KEY)) {
            return BIRTH_PRIVATE_KEY;
        }
        if (account == vm.addr(SIGNAL_PRIVATE_KEY)) {
            return SIGNAL_PRIVATE_KEY;
        }
        revert("no key for submitter");
    }

    function _signSignalSubmission(
        UVPStateMachine machine,
        UVPStateMachine.SignalSubmission memory submission,
        uint256 privateKey
    ) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _signalSubmissionDigest(machine, submission));
        return _packedSignature(v, r, s);
    }

    function _businessSubmission(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        UVPStateMachine.FactAttribution memory attribution,
        address submitter
    ) private view returns (UVPStateMachine.SignalSubmission memory) {
        return UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: orderId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: keccak256(abi.encode(sourceId, signalId, submitter)),
            attribution: attribution,
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: submitter,
            deadline: block.timestamp + 1 hours
        });
    }

    function _submitFilesAs(
        UVPStateMachine machine,
        bytes32 targetStageId,
        StageFile[] memory files,
        address submitter
    ) private {
        vm.prank(submitter);
        machine.submitSignal(_fileSubmission(PLAN_ID, ORDER_ID, targetStageId, files, submitter), hex"");
    }

    function _submitBusinessWithFiles(
        UVPStateMachine machine,
        bytes32 sourceId,
        bytes32 signalId,
        StageFile[] memory files
    ) private {
        UVPStateMachine.SignalSubmission memory submission =
            _businessSubmission(PLAN_ID, ORDER_ID, sourceId, signalId, _noAttribution(), address(this));
        submission.targetStageId = STAGE_INIT;
        submission.files = files;
        machine.submitSignal(submission, hex"");
    }

    function _fileSubmission(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        StageFile[] memory files,
        address submitter
    ) private view returns (UVPStateMachine.SignalSubmission memory) {
        return UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: orderId,
            sourceId: bytes32(0),
            signalId: bytes32(0),
            payloadHash: bytes32(0),
            idempotencyKey: keccak256(abi.encode("files", targetStageId, files.length)),
            attribution: _noAttribution(),
            targetStageId: targetStageId,
            files: files,
            submitter: submitter,
            deadline: block.timestamp + 1 hours
        });
    }

    function _oneFile(string memory key, bytes memory payload) private pure returns (StageFile[] memory files) {
        files = new StageFile[](1);
        files[0] = StageFile({key: key, payload: payload});
    }


    function _submitWithAttribution(
        UVPStateMachine machine,
        bytes32 sourceId,
        bytes32 signalId,
        UVPStateMachine.FactAttribution memory attribution
    ) private {
        _submitDirect(
            machine, _businessSubmission(PLAN_ID, ORDER_ID, sourceId, signalId, attribution, address(this))
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
        _submitDirect(machine, _businessSubmission(PLAN_ID, ORDER_ID, sourceId, signalId, _noAttribution(), address(this)));
    }

    function _submitAs(UVPStateMachine machine, bytes32 sourceId, bytes32 signalId, address submitter) private {
        vm.prank(submitter);
        _submitDirect(machine, _businessSubmission(PLAN_ID, ORDER_ID, sourceId, signalId, _noAttribution(), submitter));
    }

    function _submitDirect(UVPStateMachine machine, UVPStateMachine.SignalSubmission memory submission) private {
        machine.submitSignal(submission, hex"");
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
        UVPStateMachine.StageSupplierBinding[] memory bindings
    ) private returns (bytes32 planId) {
        planId = _commitPlan(
            machine, hooks, new StageSelectorBinding[](0), signalCapabilities, bindings, PUBLISHER_PRIVATE_KEY
        );
        machine.finalizePlan(planId);
    }

    function _commitPlan(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        UVPStateMachine.StageSupplierBinding[] memory bindings,
        uint256 publisherPrivateKey
    ) private returns (bytes32 planId) {
        bytes32[] memory leaves = _capabilityLeaves(selectorBindings, signalCapabilities);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(publisherPrivateKey),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: MerkleCommitment.root(leaves),
            supplierBindingsRoot: _bindingsRoot(bindings),
            fileWritersHash: keccak256(abi.encode(new UVPStateMachine.StageFileWriter[](0))),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherPrivateKey, _planCommitDigest(machine, commit));
        planId = machine.commitPlan(
            commit, hooks, bindings, new UVPStateMachine.StageFileWriter[](0), _packedSignature(v, r, s)
        );

        PLAN_ID = planId;
        CapabilityTables storage tables = _tables[address(machine)][planId];
        tables.sortedLeaves = _sortedUnique(leaves);
    }


    function _planCommit(
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        UVPStateMachine.StageSupplierBinding[] memory bindings
    ) private returns (UVPStateMachine.PlanCommit memory commit) {
        commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: MerkleCommitment.root(_capabilityLeaves(selectorBindings, signalCapabilities)),
            supplierBindingsRoot: _bindingsRoot(bindings),
            fileWritersHash: keccak256(abi.encode(new UVPStateMachine.StageFileWriter[](0))),
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
                commit.supplierBindingsRoot,
                commit.fileWritersHash,
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

    function _signalSubmissionDigest(UVPStateMachine machine, UVPStateMachine.SignalSubmission memory submission)
        private
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNAL_SUBMISSION_TYPEHASH,
                submission.planId,
                submission.orderId,
                submission.sourceId,
                submission.signalId,
                submission.payloadHash,
                submission.idempotencyKey,
                submission.targetStageId,
                keccak256(abi.encode(submission.files)),
                _attributionHash(submission.attribution),
                submission.submitter,
                submission.deadline
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
        returns (UVPStateMachine.StageSupplierBinding[] memory bindings)
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
        bindings = new UVPStateMachine.StageSupplierBinding[](boundCount);
        uint256 cursor;
        for (uint256 i = 0; i < stageCount; i++) {
            if (kinds[i] & (2 | 4) != 0) {
                continue;
            }
            address account = _stageSupplierAccounts[address(machine)][stages[i]];
            if (account == address(0)) {
                account = address(this);
            }
            bindings[cursor++] = UVPStateMachine.StageSupplierBinding({
                stageId: stages[i],
                supplierId: _supplierFor(machine, account),
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

    function _bindingsRoot(UVPStateMachine.StageSupplierBinding[] memory bindings) private pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](bindings.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    SUPPLIER_BINDING_LEAF_DOMAIN, bindings[i].stageId, bindings[i].supplierId, bindings[i].kind
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

    function _birthPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
    }

    function _crossStageObservationPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        hooks[1] = _signalHook(HOOK_OBSERVER_A, STAGE_OBSERVER_A, SIGNAL_SHARED, FLAG_EMIT_READY, STAGE_INIT);
        hooks[2] = _signalHook(HOOK_OBSERVER_B, STAGE_OBSERVER_B, SIGNAL_SHARED, FLAG_EMIT_READY, STAGE_INIT);
    }

    function _watcherFlushPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        hooks[1] = _signalHook(HOOK_WATCH_PRE, STAGE_WATCH, SIGNAL_WATCH_PRE, 0, STAGE_INIT);
        hooks[2] = _signalHook(HOOK_WATCH_OPEN, STAGE_WATCH, SIGNAL_WATCH_OPEN, FLAG_EMIT_READY, STAGE_INIT);
    }

    function _supplierPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
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

    function _decayingVetoRegistrationPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_VETO,
            arity: 0,
            delaySeconds: 0
        });
        instructions[1] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 5
        });
        instructions[2] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
        instructions[3] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_OPEN,
            arity: 0,
            delaySeconds: 0
        });
        instructions[4] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.And),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 2,
            delaySeconds: 0
        });
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_DECAY_REGISTRATION,
            stageId: STAGE_INIT,
            hookName: keccak256("decay.registration"),
            flags: FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: _depsOf(instructions)
        });
    }

    function _decayingVetoPokePlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            HOOK_BIRTH, STAGE_INIT, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SOURCE_BOOTSTRAP
        );
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](6);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_OPEN,
            arity: 0,
            delaySeconds: 0
        });
        instructions[1] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 10
        });
        instructions[2] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_VETO,
            arity: 0,
            delaySeconds: 0
        });
        instructions[3] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 5
        });
        instructions[4] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
        instructions[5] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.And),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 2,
            delaySeconds: 0
        });
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_DECAY_POKE,
            stageId: STAGE_INIT,
            hookName: keccak256("decay.poke"),
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
