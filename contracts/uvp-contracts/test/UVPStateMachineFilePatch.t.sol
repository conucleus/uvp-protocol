// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPDockRegistry} from "../src/UVPDockRegistry.sol";
import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {UVPIdentityRegistry} from "../src/UVPIdentityRegistry.sol";
import {StageFile, StageFilesEmpty} from "../src/interfaces/IUVPFileResourceModule.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";
import {MerkleCommitment} from "../src/libraries/MerkleCommitment.sol";
import {emptyStageFiles} from "./StageFileTestHelpers.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function addr(uint256 privateKey) external pure returns (address);
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract UVPStateMachineFileWriteTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant BIRTH_PRIVATE_KEY = 0xa11ce;
    uint256 private constant AUDIT_PRIVATE_KEY = 0xb0b;

    bytes32 private constant SIGNAL_BIRTH = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_A = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_MATERIALIZE = bytes32(uint256(0x4002));
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_AUDIT = bytes32(uint256(0x5002));
    bytes32 private constant HOOK_BIRTH = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_AUDIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_NAME_BIRTH = bytes32(uint256(0x7000));
    bytes32 private constant HOOK_NAME_AUDIT = bytes32(uint256(0x7001));
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));

    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;

    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 supplierBindingsRoot,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_SUBMITTED_TOPIC =
        keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,address,bytes32)");
    bytes32 private constant STAGE_FILE_WRITTEN_TOPIC =
        keccak256("StageFileWritten(bytes32,bytes32,bytes32,string,bytes,address)");

    UVPStateMachine private machine;
    UVPFileResourceModule private fileModule;
    UVPIdentityRegistry private suppliers;
    bytes32 private planId;
    bytes32 private orderId;
    address private birthAccount;
    address private auditAccount;
    bytes32[] private signalAProof;
    bytes32[] private writerProof;

    function setUp() public {
        machine = new UVPStateMachine();
        suppliers = new UVPIdentityRegistry();
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(machine));
        fileModule = new UVPFileResourceModule(address(machine));
        UVPStagePatchModule stagePatch = new UVPStagePatchModule(address(machine));
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(new UVPDerivedSignalModule(address(machine))));
        machine.setDockRegistry(address(new UVPDockRegistry(address(machine))));
        machine.setPlanMetadataModule(address(planMetadata));
        machine.setFileResourceModule(address(fileModule));
        machine.setIdentityRegistry(address(suppliers));
        machine.freezeModules();

        birthAccount = vm.addr(BIRTH_PRIVATE_KEY);
        auditAccount = vm.addr(AUDIT_PRIVATE_KEY);
        bytes32 birthSupplierId = _registerSupplier(birthAccount);
        bytes32 auditSupplierId = _registerSupplier(auditAccount);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _hook(
            HOOK_BIRTH, STAGE_INIT, HOOK_NAME_BIRTH, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY
        );
        hooks[1] = _hook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_AUDIT, SIGNAL_MATERIALIZE, FLAG_EMIT_READY);

        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](2);
        bindings[0] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_INIT, supplierId: birthSupplierId, kind: 0});
        bindings[1] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_AUDIT, supplierId: auditSupplierId, kind: 0});

        bytes32 birthLeaf = planMetadata.signalCapabilityLeaf(STAGE_INIT, STAGE_INIT, SIGNAL_BIRTH, 0);
        bytes32 signalALeaf = planMetadata.signalCapabilityLeaf(STAGE_INIT, STAGE_INIT, SIGNAL_A, 0);
        bytes32 writerLeaf = planMetadata.fileWriterBindingLeaf(STAGE_AUDIT, STAGE_INIT);
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = birthLeaf;
        leaves[1] = signalALeaf;
        leaves[2] = writerLeaf;
        bytes32 capRoot = MerkleCommitment.root(leaves);
        bytes32[] memory sorted = new bytes32[](3);
        sorted[0] = leaves[0];
        sorted[1] = leaves[1];
        sorted[2] = leaves[2];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (sorted[j] < sorted[i]) {
                    bytes32 tmp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                }
            }
        }
        bytes32 pair01 = MerkleCommitment.pair(sorted[0], sorted[1]);
        bytes32[] memory birthProof = new bytes32[](2);
        birthProof[0] = sorted[0] == birthLeaf ? sorted[1] : sorted[0];
        birthProof[1] = sorted[2];
        if (sorted[2] == birthLeaf) {
            birthProof = new bytes32[](1);
            birthProof[0] = pair01;
        }
        signalAProof = new bytes32[](2);
        signalAProof[0] = sorted[0] == signalALeaf ? sorted[1] : sorted[0];
        signalAProof[1] = sorted[2];
        if (sorted[2] == signalALeaf) {
            signalAProof = new bytes32[](1);
            signalAProof[0] = pair01;
        }
        writerProof = new bytes32[](2);
        writerProof[0] = sorted[0] == writerLeaf ? sorted[1] : sorted[0];
        writerProof[1] = sorted[2];
        if (sorted[2] == writerLeaf) {
            writerProof = new bytes32[](1);
            writerProof[0] = pair01;
        }

        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: capRoot,
            supplierBindingsRoot: _bindingsRoot(bindings),
            deadline: block.timestamp + 1 hours
        });
        planId = machine.commitPlan(
            commit, hooks, bindings, _sign(PUBLISHER_PRIVATE_KEY, _planCommitDigest(commit))
        );
        machine.finalizePlan(planId);

        UVPStateMachine.FactAttribution memory birthAttr = _emptyAttribution();
        birthAttr.stageId = STAGE_INIT;
        birthAttr.sourceId = STAGE_INIT;
        birthAttr.signalId = SIGNAL_BIRTH;
        birthAttr.capabilityProof = birthProof;
        UVPStateMachine.SignalSubmission memory birth = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: STAGE_INIT,
            signalId: SIGNAL_BIRTH,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: birthAttr,
            targetStageId: bytes32(0),
            files: emptyStageFiles(),
            submitter: birthAccount,
            deadline: block.timestamp + 1 hours
        });
        vm.prank(birthAccount);
        (orderId,) = machine.submitSignal(birth, hex"");
    }

    function testBareSignalWithoutFilesDoesNotWriteStageFiles() public {
        vm.recordLogs();
        _submitSignalAs(birthAccount, STAGE_INIT, SIGNAL_A, bytes32(0), emptyStageFiles());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.hasSignal(planId, orderId, STAGE_INIT, SIGNAL_A), "bare signal missing");
        require(_countTopic(logs, SIGNAL_SUBMITTED_TOPIC) == 1, "bare signal event missing");
        require(_countTopic(logs, STAGE_FILE_WRITTEN_TOPIC) == 0, "bare signal wrote a file");
    }

    function testBareFilesWithoutSignalWriteMapWithoutBusinessEffects() public {
        StageFile[] memory files = _files("uvp://file/a", bytes("payload-a"));
        vm.recordLogs();
        _submitFilesAs(auditAccount, STAGE_INIT, files);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool exists, bytes memory payload) = fileModule.getStageFile(planId, orderId, STAGE_INIT, "uvp://file/a");
        require(exists, "bare file missing");
        require(keccak256(payload) == keccak256(bytes("payload-a")), "bare file payload mismatch");
        require(_countTopic(logs, STAGE_FILE_WRITTEN_TOPIC) == 1, "file event missing");
        require(_countTopic(logs, SIGNAL_SUBMITTED_TOPIC) == 0, "bare files recorded a signal");
        (uint256 count,,,) = machine.stageSignalState(planId, orderId, STAGE_INIT);
        require(count == 1, "bare files changed stage signal count");
    }

    function testSignalAndFilesAreAppliedAtomically() public {
        vm.recordLogs();
        _submitSignalAs(birthAccount, STAGE_INIT, SIGNAL_A, STAGE_INIT, _files("key", bytes("value")));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.hasSignal(planId, orderId, STAGE_INIT, SIGNAL_A), "signal missing");
        (bool exists, bytes memory payload) = fileModule.getStageFile(planId, orderId, STAGE_INIT, "key");
        require(exists, "file missing");
        require(keccak256(payload) == keccak256(bytes("value")), "file payload mismatch");
        require(_countTopic(logs, SIGNAL_SUBMITTED_TOPIC) == 1, "signal event missing");
        require(_countTopic(logs, STAGE_FILE_WRITTEN_TOPIC) == 1, "file event missing");
    }

    function testDeclaredWriterStageWritesTargetStageFileResource() public {
        _submitFilesAs(auditAccount, STAGE_INIT, _files("declared", bytes("from-audit")));

        (bool exists, bytes memory payload) = fileModule.getStageFile(planId, orderId, STAGE_INIT, "declared");
        require(exists, "declared writer file missing");
        require(keccak256(payload) == keccak256(bytes("from-audit")), "declared writer payload mismatch");
        require(UVPPlanMetadataModule(machine.planMetadataModule()).verifyFileWriterBinding(planId, STAGE_AUDIT, STAGE_INIT, writerProof), "plan file writer missing");
    }

    function testUndeclaredWriterStageIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector, orderId, STAGE_AUDIT, birthAccount
            )
        );
        _submitFilesAs(birthAccount, STAGE_AUDIT, _files("undeclared", bytes("payload")));
    }

    function testTargetStageSupplierWritesItsOwnFileResource() public {
        _submitFilesAs(auditAccount, STAGE_AUDIT, _files("self", bytes("self-payload")));

        (bool exists,) = fileModule.getStageFile(planId, orderId, STAGE_AUDIT, "self");
        require(exists, "self writer file missing");
    }

    function testDuplicateSignalAbsorbsFilesAndLeavesFirstPayload() public {
        _submitSignalAs(birthAccount, STAGE_INIT, SIGNAL_A, STAGE_INIT, _files("key", bytes("first")));

        vm.recordLogs();
        _submitSignalAs(birthAccount, STAGE_INIT, SIGNAL_A, STAGE_INIT, _files("key", bytes("second")));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool exists, bytes memory payload) = fileModule.getStageFile(planId, orderId, STAGE_INIT, "key");
        require(exists, "duplicate removed file");
        require(keccak256(payload) == keccak256(bytes("first")), "duplicate rewrote file");
        require(_countTopic(logs, SIGNAL_SUBMITTED_TOPIC) == 0, "duplicate emitted a signal");
        require(_countTopic(logs, STAGE_FILE_WRITTEN_TOPIC) == 0, "duplicate emitted a file");
    }

    function testFileAuthorizationFailureRevertsWholeSignal() public {
        UVPStateMachine.SignalSubmission memory submission = _signalSubmission(
            birthAccount, STAGE_INIT, SIGNAL_A, STAGE_AUDIT, _files("key", bytes("value"))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector, orderId, STAGE_AUDIT, birthAccount
            )
        );
        vm.prank(birthAccount);
        machine.submitSignal(submission, hex"");

        require(!machine.hasSignal(planId, orderId, STAGE_INIT, SIGNAL_A), "reverted signal was recorded");
        (bool exists,) = fileModule.getStageFile(planId, orderId, STAGE_AUDIT, "key");
        require(!exists, "reverted file was written");
    }

    function testPureFileSubmissionRequiresTargetStage() public {
        vm.expectRevert(UVPStateMachine.ZeroFileTargetStageId.selector);
        _submitFilesAs(auditAccount, bytes32(0), _files("key", bytes("value")));
    }

    function testEmptyFileSubmissionIsRejected() public {
        vm.expectRevert(StageFilesEmpty.selector);
        _submitFilesAs(auditAccount, STAGE_INIT, emptyStageFiles());
    }

    function _submitSignalAs(
        address submitter,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 targetStageId,
        StageFile[] memory files
    ) private {
        UVPStateMachine.SignalSubmission memory submission =
            _signalSubmission(submitter, sourceId, signalId, targetStageId, files);
        vm.prank(submitter);
        machine.submitSignal(submission, hex"");
    }

    function _signalSubmission(
        address submitter,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 targetStageId,
        StageFile[] memory files
    ) private view returns (UVPStateMachine.SignalSubmission memory) {
        bytes32[] memory emptyProof = new bytes32[](0);
        UVPStateMachine.FactAttribution memory attr = _emptyAttribution();
        if (signalId == SIGNAL_A && sourceId == STAGE_INIT) {
            attr.stageId = STAGE_INIT;
            attr.sourceId = STAGE_INIT;
            attr.signalId = SIGNAL_A;
            attr.capabilityProof = signalAProof;
        } else {
            attr.capabilityProof = emptyProof;
        }
        return UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: orderId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: keccak256(abi.encode(sourceId, signalId)),
            attribution: attr,
            targetStageId: targetStageId,
            files: files,
            submitter: submitter,
            deadline: block.timestamp + 1 hours
        });
    }

    function _submitFilesAs(address submitter, bytes32 targetStageId, StageFile[] memory files) private {
        UVPStateMachine.FactAttribution memory attr = _emptyAttribution();
        if (submitter == auditAccount) {
            attr.stageId = STAGE_AUDIT;
            attr.capabilityProof = writerProof;
        }
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: orderId,
            sourceId: bytes32(0),
            signalId: bytes32(0),
            payloadHash: bytes32(0),
            idempotencyKey: keccak256(abi.encode("files", targetStageId, files.length)),
            attribution: attr,
            targetStageId: targetStageId,
            files: files,
            submitter: submitter,
            deadline: block.timestamp + 1 hours
        });
        vm.prank(submitter);
        machine.submitSignal(submission, hex"");
    }

    function _files(string memory key, bytes memory payload) private pure returns (StageFile[] memory files) {
        files = new StageFile[](1);
        files[0] = StageFile({key: key, payload: payload});
    }

    function _emptyAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0),
            signalId: bytes32(0),
            stageId: bytes32(0),
            capabilityProof: new bytes32[](0)
        });
    }

    function _hook(bytes32 hookId, bytes32 stageId, bytes32 hookName, bytes32 signalId, uint8 flags)
        private
        pure
        returns (UVPStateMachine.CompactHook memory hook)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: STAGE_INIT,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory dependencyKeys = new bytes32[](1);
        dependencyKeys[0] = keccak256(abi.encode(STAGE_INIT, signalId));
        hook = UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: hookName,
            flags: flags,
            instructions: instructions,
            dependencyKeys: dependencyKeys
        });
    }

    function _twoHooks() private view returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _hook(
            HOOK_BIRTH, STAGE_INIT, HOOK_NAME_BIRTH, SIGNAL_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY
        );
        hooks[1] = _hook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_AUDIT, SIGNAL_MATERIALIZE, FLAG_EMIT_READY);
    }

    function _twoBindings() private view returns (UVPStateMachine.StageSupplierBinding[] memory bindings) {
        bindings = new UVPStateMachine.StageSupplierBinding[](2);
        bindings[0] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_INIT,
            supplierId: _supplierOf(birthAccount),
            kind: 0
        });
        bindings[1] = UVPStateMachine.StageSupplierBinding({
            stageId: STAGE_AUDIT,
            supplierId: _supplierOf(auditAccount),
            kind: 0
        });
    }

    function _commitFor(
        UVPStateMachine.CompactHook[] memory hooks,
        UVPStateMachine.StageSupplierBinding[] memory bindings
    ) private view returns (UVPStateMachine.PlanCommit memory) {
        return UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: MerkleCommitment.EMPTY_ROOT,
            supplierBindingsRoot: _bindingsRoot(bindings),
            deadline: block.timestamp + 1 hours
        });
    }

    function _registerSupplier(address account) private returns (bytes32 supplierId) {
        vm.prank(account);
        supplierId = suppliers.registerSupplier(account);
        suppliers.activateSupplier(supplierId);
    }

    function _supplierOf(address account) private view returns (bytes32) {
        return suppliers.supplierOf(account);
    }

    function _bindingsRoot(UVPStateMachine.StageSupplierBinding[] memory bindings) private pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](bindings.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(keccak256("UVP_SUPPLIER_BINDING_V1"), bindings[i].stageId, bindings[i].supplierId, bindings[i].kind)
            );
        }
        return MerkleCommitment.root(leaves);
    }

    function _planCommitDigest(UVPStateMachine.PlanCommit memory commit) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                machine.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        PLAN_COMMIT_TYPEHASH,
                        commit.publisher,
                        commit.hooksHash,
                        commit.capabilitiesRoot,
                        commit.supplierBindingsRoot,
                        commit.deadline
                    )
                )
            )
        );
    }

    function _sign(uint256 privateKey, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count += 1;
            }
        }
    }
}
