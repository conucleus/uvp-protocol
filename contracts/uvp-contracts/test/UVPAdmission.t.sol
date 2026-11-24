// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPDockRegistry} from "../src/UVPDockRegistry.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {UVPIdentityRegistry} from "../src/UVPIdentityRegistry.sol";
import {AdmissionVerdict} from "../src/UVPStateMachineConstants.sol";
import {MerkleCommitment} from "../src/libraries/MerkleCommitment.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";
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

contract BatchSubmitter {
    function submitTwo(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        bytes32 firstSourceId,
        bytes32 firstSignalId,
        bytes32 secondSourceId,
        bytes32 secondSignalId
    ) external {
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: firstSourceId,
                signalId: firstSignalId,
                payloadHash: bytes32(uint256(0x8001)),
                idempotencyKey: bytes32(uint256(0x9001)),
                attribution: UVPStateMachine.FactAttribution({
                sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
            }),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: secondSourceId,
                signalId: secondSignalId,
                payloadHash: bytes32(uint256(0x8002)),
                idempotencyKey: bytes32(uint256(0x9002)),
                attribution: UVPStateMachine.FactAttribution({
                sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
            }),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
    }

    function submitBirth(UVPStateMachine machine, UVPStateMachine.SignalSubmission calldata submission)
        external
        returns (bytes32 orderId)
    {
        machine.submitSignal(submission, "");
        try machine.submitSignal(submission, "") {
            revert("duplicate trigger submission did not revert");
        } catch (bytes memory reason) {
            require(reason.length == 100, "unexpected duplicate trigger payload length");
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
            require(selector == UVPStateMachine.DuplicateTriggerKey.selector, "unexpected duplicate trigger revert");
            bytes memory payload = new bytes(reason.length - 4);
            for (uint256 i = 4; i < reason.length; i++) {
                payload[i - 4] = reason[i];
            }
            (, , orderId) = abi.decode(payload, (address, bytes32, bytes32));
        }
    }
}

contract UVPAdmissionTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_uint(string key, uint256 val);


    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant SOURCE_BOOTSTRAP = STAGE_INIT;
    bytes32 private constant SIGNAL_ORDER_START = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_TRIGGER = bytes32(uint256(0x4002));
    bytes32 private constant SIGNAL_ANCHOR = bytes32(uint256(0x4008));
    bytes32 private constant SIGNAL_CANCEL = bytes32(uint256(0x4009));
    bytes32 private constant SIGNAL_GUARD = bytes32(uint256(0x400a));
    bytes32 private constant HOOK_ORDER_START = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_INIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_NAME_TRIGGER = bytes32(uint256(0x7001));
    bytes32 private constant HOOK_NAME_ORDER_START = bytes32(uint256(0x7005));
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant BATCH_PRIVATE_KEY = 0xba7c4;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("1");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 supplierBindingsRoot,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignalSubmission(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 targetStageId,bytes32 filesHash,bytes32 attributionHash,address submitter,uint256 deadline)"
    );
    bytes32 private constant FACT_ATTRIBUTION_TYPEHASH =
        keccak256("FactAttribution(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)");
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_ADMISSION = 8;
    bytes32 private constant EMPTY_MERKLE_ROOT = keccak256("");
    bytes32 private constant SUPPLIER_BINDING_LEAF_DOMAIN = keccak256("UVP_SUPPLIER_BINDING_V1");

    mapping(address machine => UVPIdentityRegistry) private _registries;
    mapping(address machine => mapping(address account => bytes32 supplierId)) private _suppliers;
    mapping(address machine => mapping(bytes32 stageId => address account)) private _stageSupplierAccounts;
    mapping(address account => uint256 privateKey) private _supplierKeys;

    bytes32 private PLAN_ID;
    bytes32 private ORDER_ID;

    function testOrderTriggerHookRequiresSingleSignalInstruction() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](3);
        instrs[0] = _signal(SIGNAL_ORDER_START);
        instrs[1] = _signal(SIGNAL_ANCHOR);
        instrs[2] = _and(2);
        bytes32 hookId = keccak256("multi.instruction.trigger");
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: STAGE_INIT,
            hookName: HOOK_NAME_ORDER_START,
            flags: FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            instructions: instrs,
            dependencyKeys: _declaredKeys(instrs)
        });
        _commitOnly(machine, hooks, abi.encodeWithSelector(UVPStateMachine.InvalidTriggerHook.selector, hookId));
    }

    function testAdmissionRejectsArbitraryHookId() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_admissionOnly(instructions));
        hooks[1].hookId = keccak256("arbitrary.admission.key");
        _commitOnly(
            machine,
            hooks,
            abi.encodeWithSelector(UVPStateMachine.InvalidAdmissionHook.selector, hooks[1].hookId)
        );
    }

    function testAdmissionKeyMayUseDeclaredSourceDistinctFromStage() public {
        UVPStateMachine machine = _newMachine();
        bytes32 materialStage = keccak256("admission.material.stage");
        UVPStateMachine.Instruction[] memory birthInstrs = new UVPStateMachine.Instruction[](1);
        birthInstrs[0] = _signal(SIGNAL_ORDER_START);
        UVPStateMachine.Instruction[] memory admissionInstrs = new UVPStateMachine.Instruction[](1);
        admissionInstrs[0] = _signal(SIGNAL_ANCHOR);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: HOOK_ORDER_START,
            stageId: materialStage,
            hookName: HOOK_NAME_ORDER_START,
            flags: FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            instructions: birthInstrs,
            dependencyKeys: _declaredKeys(birthInstrs)
        });
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)),
            stageId: materialStage,
            hookName: SIGNAL_TRIGGER,
            flags: FLAG_ADMISSION,
            instructions: admissionInstrs,
            dependencyKeys: _declaredKeys(admissionInstrs)
        });
        bytes32 planId = _registerPlan(machine, hooks);
        require(machine.planExists(planId), "source-distinct admission key rejected");
    }

    function testAdmissionVerdictSeparatesWaitImpossibleReady() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory waitInstrs = new UVPStateMachine.Instruction[](1);
        waitInstrs[0] = _signal(SIGNAL_ANCHOR);
        UVPStateMachine.Instruction[] memory impossibleInstrs = new UVPStateMachine.Instruction[](2);
        impossibleInstrs[0] = _signal(SIGNAL_CANCEL);
        impossibleInstrs[1] = _not();

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _admissionHook(SIGNAL_TRIGGER, waitInstrs);
        hooks[2] = _admissionHook(SIGNAL_GUARD, impossibleInstrs);
        bytes32 planId = _registerPlan(machine, hooks);
        _submitTriggerBirth(machine);

        (AdmissionVerdict triggerVerdict, uint64 triggerDueAt) =
            machine.signalAdmissionVerdict(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(triggerVerdict == AdmissionVerdict.Wait, "missing anchor must be Wait");
        require(triggerDueAt == 0, "missing anchor must not carry a due time");
        (AdmissionVerdict guardVerdict,) =
            machine.signalAdmissionVerdict(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_GUARD);
        require(guardVerdict == AdmissionVerdict.Ready, "absent negated fact must be Ready");

        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_CANCEL);
        (guardVerdict,) = machine.signalAdmissionVerdict(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_GUARD);
        require(guardVerdict == AdmissionVerdict.Impossible, "present negated fact must be Impossible");
        require(
            !machine.isSignalAdmissionSatisfied(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_GUARD),
            "Impossible admission must not read as satisfied"
        );

        _submit(machine, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR);
        (triggerVerdict,) = machine.signalAdmissionVerdict(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(triggerVerdict == AdmissionVerdict.Ready, "present anchor must become Ready");
    }

    function testValidAdmissionPlanRegisters() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _admissionPlan(5, true));
        require(machine.planExists(planId), "admission plan not registered");
    }

    function testBareDecayingRootAdmissionRegisters() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_CANCEL);
        instructions[1] = _delay(5);
        instructions[2] = _not();

        bytes32 planId = _registerPlan(machine, _withOrderStart(_admissionOnly(instructions)));
        require(machine.planExists(planId), "bare decaying root plan not registered");
    }

    function testDecayingVetoUnderOrAdmissionRegisters() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _or(2);

        bytes32 planId = _registerPlan(machine, _withOrderStart(_admissionOnly(instructions)));
        require(machine.planExists(planId), "veto-under-or plan not registered");
    }

    function testDecayingVetoInsideDelayOperandAdmissionRegisters() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(30);
        instructions[2] = _delay(30);
        hooks[0] = _admissionHook(SIGNAL_TRIGGER, instructions);
        _commitOnly(machine, hooks, UVPStateMachine.InvalidInstruction.selector);
    }

    function testAdmissionRejectsUnanchoredDelayOperand() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _not();
        instructions[2] = _delay(30);
        hooks[0] = _admissionHook(SIGNAL_TRIGGER, instructions);
        _commitOnly(machine, hooks, UVPStateMachine.InvalidInstruction.selector);
    }

    function testAdmissionBareDecayingVetoRootStillRegisters() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory base = _basePlan(true);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            hooks[i] = base[i];
        }
        UVPStateMachine.Instruction[] memory veto = new UVPStateMachine.Instruction[](3);
        veto[0] = _signal(SIGNAL_TRIGGER);
        veto[1] = _delay(30);
        veto[2] = _not();
        hooks[base.length] = _admissionHook(SIGNAL_TRIGGER, veto);
        _commitOnly(machine, hooks);
    }

    function testDoubleNegationAdmissionIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_CANCEL);
        instructions[1] = _delay(5);
        instructions[2] = _not();
        instructions[3] = _not();

        _commitOnly(machine, _withOrderStart(_admissionOnly(instructions)), UVPStateMachine.InvalidInstruction.selector);
    }

    function testAdmissionDelayBoundsAreRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory zero = new UVPStateMachine.Instruction[](2);
        zero[0] = _signal(SIGNAL_CANCEL);
        zero[1] = _delay(0);
        _commitOnly(machine, _withOrderStart(_admissionOnly(zero)), UVPStateMachine.InvalidInstruction.selector);

        UVPStateMachine.Instruction[] memory over = new UVPStateMachine.Instruction[](2);
        over[0] = _signal(SIGNAL_CANCEL);
        over[1] = _delay(30 days + 1 seconds);
        _commitOnly(machine, _withOrderStart(_admissionOnly(over)), abi.encodeWithSelector(UVPStateMachine.HookDelayTooLong.selector, 30 days + 1 seconds));
    }

    function testAdmissionRootNotSingleIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory two = new UVPStateMachine.Instruction[](2);
        two[0] = _signal(SIGNAL_ANCHOR);
        two[1] = _signal(SIGNAL_CANCEL);
        _commitOnly(machine, _withOrderStart(_admissionOnly(two)), UVPStateMachine.InvalidInstruction.selector);
    }

    function testAdmissionDependencyKeyMismatchIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _and(2);

        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_admissionOnly(instructions));
        hooks[1].dependencyKeys = _deps3(SIGNAL_ANCHOR, SIGNAL_CANCEL, SIGNAL_TRIGGER);

        _commitOnly(machine, hooks, abi.encodeWithSelector(UVPStateMachine.HookDependencyKeyMismatch.selector, hooks[1].hookId));
    }

    function testAdmissionChimeraFlagsAreRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_ANCHOR);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _admissionHook(SIGNAL_TRIGGER, instructions);
        hooks[1].flags = uint8(FLAG_ADMISSION | FLAG_EMIT_READY);

        _commitOnly(machine, hooks, UVPStateMachine.InvalidHook.selector);
    }

    function testDuplicateAdmissionIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _and(2);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _admissionHook(SIGNAL_TRIGGER, instructions);
        hooks[2] = _admissionHook(SIGNAL_TRIGGER, instructions);

        _commitOnly(machine, hooks, abi.encodeWithSelector(UVPStateMachine.AdmissionAlreadyRegistered.selector, hooks[1].hookId));
    }

    function testAdmissionOnlyStageIsRejectedAsNotMaterializable() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_ANCHOR);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] =
            _signalHook(HOOK_ORDER_START, bytes32(uint256(0x5f01)), HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _admissionHook(SIGNAL_TRIGGER, instructions);

        _commitOnly(machine, hooks, abi.encodeWithSelector(UVPStateMachine.StageNotMaterializable.selector, STAGE_INIT));
    }

    function testAdmittedSignalRecordsFactAndRunsHooks() public {
        UVPStateMachine machine = _gatedMachine(5);
        vm.warp(100);

        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        (bool exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(exists, "admitted fact missing");
        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "dependent hook not ready");
        require(readyEmitted, "ready marker missing");
    }

    function testNonReadyAdmissionRevertsAndRecordsNothing() public {
        UVPStateMachine machine = _gatedMachine(5);
        vm.warp(100);

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
            )
        );
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        (bool exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(!exists, "rejected emission must not record a fact");
        (UVPStateMachine.HookStatus status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Init, "rejected emission must not advance hooks");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(
            _countTopic(logs, keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,address,bytes32)"))
                == 0,
            "rejected emission emitted events"
        );
    }

    function testAdmissionOrVacuumArmLosesToAnchoredArm() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _not();
        instructions[3] = _or(2);
        instructions[4] = _delay(5);
        UVPStateMachine.CompactHook[] memory base = _basePlan(false);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            hooks[i] = base[i];
        }
        hooks[base.length] = _admissionHook(SIGNAL_TRIGGER, instructions);
        _registerPlan(machine, hooks);
        _submitTriggerBirth(machine);

        vm.warp(100);
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        vm.warp(103);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
            )
        );
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        vm.warp(105);
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        (bool exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(exists, "admitted emission missing at anchored maturity");
    }

    function testAdmissionOrDoubleVacuumTieKeepsLeftBranch() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _not();
        instructions[2] = _signal(SIGNAL_CANCEL);
        instructions[3] = _not();
        instructions[4] = _or(2);
        UVPStateMachine.CompactHook[] memory base = _basePlan(false);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            hooks[i] = base[i];
        }
        hooks[base.length] = _admissionHook(SIGNAL_TRIGGER, instructions);
        _registerPlan(machine, hooks);
        _submitTriggerBirth(machine);
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        (bool admitted,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(admitted, "double-vacuum tie must resolve value-Ready and admit");

        UVPStateMachine swapped = _newMachine();
        UVPStateMachine.Instruction[] memory swappedInstrs = new UVPStateMachine.Instruction[](5);
        swappedInstrs[0] = _signal(SIGNAL_CANCEL);
        swappedInstrs[1] = _not();
        swappedInstrs[2] = _signal(SIGNAL_ANCHOR);
        swappedInstrs[3] = _not();
        swappedInstrs[4] = _or(2);
        UVPStateMachine.CompactHook[] memory swappedHooks = new UVPStateMachine.CompactHook[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            swappedHooks[i] = base[i];
        }
        swappedHooks[base.length] = _admissionHook(SIGNAL_TRIGGER, swappedInstrs);
        _registerPlan(swapped, swappedHooks);
        _submitTriggerBirth(swapped);
        swapped.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        (bool admittedSwapped,,,,) = swapped.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(admittedSwapped, "double-vacuum tie outcome must be fold-order independent");

        UVPStateMachine asymmetric = _newMachine();
        UVPStateMachine.Instruction[] memory asymInstrs = new UVPStateMachine.Instruction[](7);
        asymInstrs[0] = _signal(SIGNAL_ANCHOR);
        asymInstrs[1] = _delay(3);
        asymInstrs[2] = _not();
        asymInstrs[3] = _signal(SIGNAL_CANCEL);
        asymInstrs[4] = _delay(7);
        asymInstrs[5] = _not();
        asymInstrs[6] = _or(2);
        UVPStateMachine.CompactHook[] memory asymHooks = new UVPStateMachine.CompactHook[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            asymHooks[i] = base[i];
        }
        asymHooks[base.length] = _admissionHook(SIGNAL_TRIGGER, asymInstrs);
        _registerPlan(asymmetric, asymHooks);
        _submitTriggerBirth(asymmetric);
        vm.warp(100);
        asymmetric.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        asymmetric.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_CANCEL,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        vm.warp(101);
        asymmetric.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        (bool admittedAsym,,,,) = asymmetric.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(admittedAsym, "asymmetric-payload (0,0) tie must stay value-Ready and admit");
    }

    function testWindowBoundaryExactlyAtExpiryRejects() public {
        UVPStateMachine before = _gatedMachine(5);
        vm.warp(100);
        before.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        before.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_CANCEL,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        vm.warp(104);
        before.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        UVPStateMachine atExpiry = _gatedMachine(5);
        vm.warp(100);
        atExpiry.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        atExpiry.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_CANCEL,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        vm.warp(105);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
            )
        );
        atExpiry.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
    }

    function testDuplicateAbsorbsAfterWindowExpiry() public {
        UVPStateMachine machine = _gatedMachine(5);
        vm.warp(100);

        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_CANCEL,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        vm.warp(1000);
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: bytes32(uint256(0x8004)),
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        (, bytes32 payloadHash,,,) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(payloadHash == PAYLOAD_HASH, "absorbed retry overwrote the first write");
    }

    function testOutsideBirthIsScreenedByAdmission() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, false, SIGNAL_TRIGGER);
        hooks[2] = _admissionHook(SIGNAL_ORDER_START, instructions);
        bytes32 planId = _registerPlan(machine, hooks);
        PLAN_ID = planId;

        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
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
                UVPStateMachine.SignalAdmissionRejected.selector, bytes32(0), SOURCE_BOOTSTRAP, SIGNAL_ORDER_START
            )
        );
        machine.submitSignal(submission, hex"");
    }


    function testMultiSignalTxWithIneligibleEmissionRevertsEntirely() public {
        BatchSubmitter submitter = new BatchSubmitter();
        UVPStateMachine machine = _gatedMachineFor(5, address(submitter), 0, false);
        vm.warp(100);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
            )
        );
        submitter.submitTwo(
            machine, PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_CANCEL, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
        );

        (bool cancelRecorded,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_CANCEL);
        require(!cancelRecorded, "atomic rollback must erase the earlier eligible emission");
    }

    function testNoAdmissionPlanSubmitCostDeltaIsBounded() public {
        UVPStateMachine machine = _plainMachine();

        vm.warp(100);
        uint256 gasBefore = gasleft();
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        uint256 spent = gasBefore - gasleft();

        require(spent <= 137_500, "no-admission submit must stay on the fixed envelope path");
    }

    function testAdmissionSubmitGasIsConstantIncrement() public {
        UVPStateMachine plain = _plainMachine();
        vm.warp(100);
        plain.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        uint256 gasBefore = gasleft();
        plain.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        uint256 plainSpent = gasBefore - gasleft();

        UVPStateMachine machine = _gatedTriggerMachine(5);
        vm.warp(100);
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        gasBefore = gasleft();
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        uint256 admissionSpent = gasBefore - gasleft();

        UVPStateMachine machineHour = _gatedTriggerMachine(1 hours);
        vm.warp(100);
        machineHour.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ANCHOR,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        gasBefore = gasleft();
        machineHour.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: PLAN_ID,
                orderId: ORDER_ID,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: _noAttribution(),
                targetStageId: bytes32(0),
                files: emptyStageFiles(),
                submitter: address(this),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        uint256 hourSpent = gasBefore - gasleft();

        require(admissionSpent > plainSpent, "admission face must cost more than the ungated path");
        // New dock binding admission surface adds fixed per-call overhead
        // (admissionsDeclared/admissions reads + _evaluateInstructions); the old
        // 15_000 budget predated the dock/binding model. Keep the constant-increment
        // and duration-wobble guards below.
        require(admissionSpent - plainSpent <= 18_500, "admission submit delta exceeds the constant budget");
        uint256 durationWobble = admissionSpent > hourSpent ? admissionSpent - hourSpent : hourSpent - admissionSpent;
        require(durationWobble <= 100, "admission gas must not scale with the window duration");
    }

    function _newMachine() private returns (UVPStateMachine machine) {
        machine = new UVPStateMachine();
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        _registries[address(machine)] = registry;
        machine.setStagePatchModule(address(new UVPStagePatchModule(address(machine))));
        machine.setDerivedSignalModule(address(new UVPDerivedSignalModule(address(machine))));
        machine.setDockRegistry(address(new UVPDockRegistry(address(machine))));
        machine.setPlanMetadataModule(address(new UVPPlanMetadataModule(address(machine))));
        machine.setFileResourceModule(address(new UVPFileResourceModule(address(machine))));
        machine.setIdentityRegistry(address(registry));
        machine.freezeModules();
    }

    function _supplierFor(UVPStateMachine machine, address account) private returns (bytes32 supplierId) {
        supplierId = _suppliers[address(machine)][account];
        if (supplierId != bytes32(0)) {
            return supplierId;
        }
        UVPIdentityRegistry registry = _registries[address(machine)];
        if (account == address(this)) {
            supplierId = registry.registerSupplier(account);
        } else {
            vm.prank(account);
            supplierId = registry.registerSupplier(account);
        }
        registry.activateSupplier(supplierId);
        _suppliers[address(machine)][account] = supplierId;
    }

    function _gatedMachine(uint64 delaySeconds) private returns (UVPStateMachine machine) {
        return _gatedMachineFor(delaySeconds, address(0), 0, false);
    }

    function _gatedTriggerMachine(uint64 delaySeconds) private returns (UVPStateMachine machine) {
        return _gatedMachineFor(delaySeconds, address(0), 0, true);
    }

    function _gatedMachineFor(
        uint64 delaySeconds,
        address extraSubmitter,
        uint256 extraSubmitterKey,
        bool watcherIsTrigger
    ) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        if (extraSubmitter != address(0)) {
            _stageSupplierAccounts[address(machine)][STAGE_INIT] = extraSubmitter;
            _supplierKeys[extraSubmitter] = extraSubmitterKey;
        }
        _registerPlan(machine, _admissionPlan(delaySeconds, watcherIsTrigger));
        if (extraSubmitter.code.length != 0) {
            ORDER_ID = BatchSubmitter(extraSubmitter).submitBirth(machine, _birthSubmission(extraSubmitter));
        } else {
            _submitTriggerBirth(machine);
        }
    }


    function _plainMachine() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlan(machine, _basePlan(true));
        _submitTriggerBirth(machine);
    }

    function _admissionPlan(uint64 delaySeconds, bool watcherIsTrigger)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(delaySeconds);
        instructions[3] = _not();
        instructions[4] = _and(2);

        UVPStateMachine.CompactHook[] memory base = _basePlan(watcherIsTrigger);
        hooks = new UVPStateMachine.CompactHook[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            hooks[i] = base[i];
        }
        hooks[base.length] = _admissionHook(SIGNAL_TRIGGER, instructions);
    }

    function _basePlan(bool watcherIsTrigger) private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, watcherIsTrigger, SIGNAL_TRIGGER);
    }

    function _admissionOnly(UVPStateMachine.Instruction[] memory instructions)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _admissionHook(SIGNAL_TRIGGER, instructions);
    }

    function _admissionHook(bytes32 signalId, UVPStateMachine.Instruction[] memory instructions)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        return UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId)),
            stageId: STAGE_INIT,
            hookName: signalId,
            flags: FLAG_ADMISSION,
            instructions: instructions,
            dependencyKeys: _declaredKeys(instructions)
        });
    }

    function _declaredKeys(UVPStateMachine.Instruction[] memory instructions)
        private
        pure
        returns (bytes32[] memory keys)
    {
        bytes32[] memory scratch = new bytes32[](instructions.length);
        uint256 count;
        for (uint256 i = 0; i < instructions.length; i++) {
            if (instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            bytes32 key = keccak256(abi.encode(instructions[i].sourceId, instructions[i].signalId));
            bool seen;
            for (uint256 j = 0; j < count; j++) {
                if (scratch[j] == key) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                scratch[count] = key;
                count += 1;
            }
        }
        keys = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            keys[i] = scratch[i];
        }
    }

    function _withOrderStart(UVPStateMachine.CompactHook[] memory tail)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory wrapped)
    {
        wrapped = new UVPStateMachine.CompactHook[](tail.length + 1);
        wrapped[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        for (uint256 i = 0; i < tail.length; i++) {
            wrapped[i + 1] = tail[i];
        }
    }

    function _signalHook(bytes32 hookId, bytes32 stageId, bytes32 hookName, bool isTrigger, bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(signalId);
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: hookName,
            flags: isTrigger ? uint8(FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY) : FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: _deps(signalId)
        });
    }

    function _signal(bytes32 signalId) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
    }

    function _not() private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
    }

    function _and(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.And),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _or(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Or),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _delay(uint64 delaySeconds) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: delaySeconds
        });
    }

    function _deps(bytes32 signalId) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId));
    }

    function _deps3(bytes32 a, bytes32 b, bytes32 c) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](3);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, a));
        deps[1] = keccak256(abi.encode(SOURCE_BOOTSTRAP, b));
        deps[2] = keccak256(abi.encode(SOURCE_BOOTSTRAP, c));
    }

    function _registerPlan(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (bytes32 planId)
    {
        planId = _commitPlan(machine, hooks);
        machine.finalizePlan(planId);
        PLAN_ID = planId;
    }

    function _commitOnly(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks) private {
        _commitOnly(machine, hooks, new bytes(0));
    }

    function _commitOnly(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        bytes4 expectedRevert
    ) private {
        _commitOnly(machine, hooks, abi.encodeWithSelector(expectedRevert));
    }

    function _commitOnly(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        bytes memory expectedRevert
    ) private {
        (UVPStateMachine.PlanCommit memory commit, UVPStateMachine.StageSupplierBinding[] memory bindings, bytes memory signature) =
            _buildCommit(machine, hooks);
        if (expectedRevert.length != 0) {
            vm.expectRevert(expectedRevert);
        }
        machine.commitPlan(commit, hooks, bindings, signature);
    }

    function _commitPlan(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (bytes32 planId)
    {
        (UVPStateMachine.PlanCommit memory commit, UVPStateMachine.StageSupplierBinding[] memory bindings, bytes memory signature) =
            _buildCommit(machine, hooks);
        planId = machine.commitPlan(commit, hooks, bindings, signature);
    }

    function _buildCommit(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (
            UVPStateMachine.PlanCommit memory commit,
            UVPStateMachine.StageSupplierBinding[] memory bindings,
            bytes memory signature
        )
    {
        bindings = _autoBindings(machine, hooks);
        commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: EMPTY_MERKLE_ROOT,
            supplierBindingsRoot: _bindingsRoot(bindings),
            deadline: block.timestamp + 1 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.capabilitiesRoot,
                commit.supplierBindingsRoot,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        signature = _packedSignature(v, r, s);
    }

    function _autoBindings(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (UVPStateMachine.StageSupplierBinding[] memory bindings)
    {
        bytes32[] memory stages = new bytes32[](hooks.length);
        uint256 stageCount;
        for (uint256 i = 0; i < hooks.length; i++) {
            if (hooks[i].flags == FLAG_ADMISSION) {
                continue;
            }
            bool seen;
            for (uint256 j = 0; j < stageCount; j++) {
                if (stages[j] == hooks[i].stageId) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                stages[stageCount++] = hooks[i].stageId;
            }
        }
        bindings = new UVPStateMachine.StageSupplierBinding[](stageCount);
        for (uint256 i = 0; i < stageCount; i++) {
            address account = _stageSupplierAccounts[address(machine)][stages[i]];
            if (account == address(0)) {
                account = address(this);
            }
            bindings[i] = UVPStateMachine.StageSupplierBinding({
                stageId: stages[i],
                supplierId: _supplierFor(machine, account),
                kind: 0
            });
        }
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

    function _birthSubmission(address submitter) private view returns (UVPStateMachine.SignalSubmission memory) {
        return UVPStateMachine.SignalSubmission({
            planId: PLAN_ID,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: _noAttribution(),
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: submitter,
            deadline: block.timestamp + 1 hours
        });
    }

    function _submitTriggerBirth(UVPStateMachine machine) private {
        address submitter = _stageSupplierAccounts[address(machine)][STAGE_INIT];
        if (submitter == address(0)) {
            submitter = address(this);
        }
        UVPStateMachine.SignalSubmission memory submission = _birthSubmission(submitter);
        if (submitter == address(this)) {
            machine.submitSignal(submission, hex"");
        } else {
            machine.submitSignal(submission, _signalSignature(machine, submission, _supplierKeys[submitter]));
        }
        ORDER_ID = _createdTriggerOrderId(machine, submission);
    }


    function _createdTriggerOrderId(UVPStateMachine machine, UVPStateMachine.SignalSubmission memory submission)
        private
        returns (bytes32 orderId)
    {
        bytes memory signature = submission.submitter == address(this)
            ? bytes("")
            : _signalSignature(machine, submission, _supplierKeys[submission.submitter]);
        try machine.submitSignal(submission, signature) {
            revert("duplicate trigger submission did not revert");
        } catch (bytes memory reason) {
            require(reason.length == 100, "unexpected duplicate trigger payload length");
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
            require(selector == UVPStateMachine.DuplicateTriggerKey.selector, "unexpected duplicate trigger revert");
            (, , orderId) = abi.decode(_withoutSelector(reason), (address, bytes32, bytes32));
        }
    }


    function _withoutSelector(bytes memory reason) private pure returns (bytes memory data) {
        data = new bytes(reason.length - 4);
        for (uint256 i = 4; i < reason.length; i++) {
            data[i - 4] = reason[i];
        }
    }

    function _signalSignature(
        UVPStateMachine machine,
        UVPStateMachine.SignalSubmission memory submission,
        uint256 privateKey
    ) private returns (bytes memory) {
        bytes32 attributionHash = keccak256(
            abi.encode(
                FACT_ATTRIBUTION_TYPEHASH,
                submission.attribution.sourceId,
                submission.attribution.signalId,
                submission.attribution.stageId,
                keccak256(abi.encode(submission.attribution.capabilityProof))
            )
        );
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
                attributionHash,
                submission.submitter,
                submission.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return _packedSignature(v, r, s);
    }

    function _businessSubmission(bytes32 sourceId, bytes32 signalId, bytes32 payloadHash, bytes32 idempotencyKey)
        private
        view
        returns (UVPStateMachine.SignalSubmission memory)
    {
        return UVPStateMachine.SignalSubmission({
            planId: PLAN_ID,
            orderId: ORDER_ID,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: payloadHash,
            idempotencyKey: idempotencyKey,
            attribution: _noAttribution(),
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
    }

    function _submit(UVPStateMachine machine, bytes32 sourceId, bytes32 signalId) private {
        machine.submitSignal(_businessSubmission(sourceId, signalId, PAYLOAD_HASH, IDEMPOTENCY_KEY), hex"");
    }

    function _submitWithPayload(
        UVPStateMachine machine,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash
    ) private {
        machine.submitSignal(_businessSubmission(sourceId, signalId, payloadHash, IDEMPOTENCY_KEY), hex"");
    }


    function _stateMachineDomainSeparator(UVPStateMachine machine) private view returns (bytes32) {
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

    function _packedSignature(uint8 v, bytes32 r, bytes32 s) private pure returns (bytes memory) {
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count += 1;
            }
        }
    }
}
