// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPDockRegistry} from "../src/UVPDockRegistry.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {UVPSupplierRegistry} from "../src/UVPSupplierRegistry.sol";
import {FileOp, FileOpKind, FilePatch} from "../src/interfaces/IUVPFileResourceModule.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";
import {MerkleCommitment} from "../src/libraries/MerkleCommitment.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
import {_SUPPLIER_BINDING_LEAF_DOMAIN} from "../src/UVPStateMachineConstants.sol";
import {emptyFilePatch} from "./FilePatchTestHelpers.sol";

contract DirectSignalSupplier {
    function submit(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        UVPStateMachine.FactAttribution calldata attribution,
        FilePatch calldata filePatch
    ) external {
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: orderId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: payloadHash,
            idempotencyKey: idempotencyKey,
            attribution: attribution,
            filePatch: filePatch,
            patchHash: machineFilePatchHash(machine, filePatch),
            submitter: address(this),
            deadline: block.timestamp + 1 hours
        });
        machine.submitSignal(submission, hex"");
    }

    function machineFilePatchHash(UVPStateMachine machine, FilePatch calldata filePatch) private view returns (bytes32) {
        return UVPFileResourceModule(machine.fileResourceModule()).filePatchHash(filePatch);
    }
}

contract UVPStateMachineFilePatchTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant BIRTH_SUBMITTER_PRIVATE_KEY = 0xa11ce;
    uint256 private constant WRITER_PRIVATE_KEY = 0xb0b;
    uint256 private constant HANDOFF_WRITER_PRIVATE_KEY = 0xb0c;

    bytes32 private constant SOURCE_BOOTSTRAP = bytes32(uint256(0x3001));
    bytes32 private constant SOURCE_FILE = bytes32(uint256(0x3002));
    bytes32 private constant SIGNAL_ORDER_START = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_BOOTSTRAP_READY = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_FILE = bytes32(uint256(0x4010));
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_AUDIT = bytes32(uint256(0x5002));
    bytes32 private constant HOOK_BIRTH = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_FILES_READY = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_NAME_BIRTH = bytes32(uint256(0x7005));
    bytes32 private constant HOOK_NAME_FILES_READY = bytes32(uint256(0x7006));
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant PAYLOAD_HASH_2 = bytes32(uint256(0x8002));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant IDEMPOTENCY_KEY_2 = bytes32(uint256(0x9002));
    bytes32 private constant FILE_KEY = bytes32(uint256(0xd001));
    bytes32 private constant FILE_KEY_2 = bytes32(uint256(0xd002));
    bytes32 private constant FILE_CONTENT_HASH = bytes32(uint256(0xf001));
    bytes32 private constant FILE_CONTENT_HASH_2 = bytes32(uint256(0xf002));
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;

    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 supplierBindingsRoot,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignalSubmission(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 patchHash,bytes32 attributionHash,address submitter,uint256 deadline)"
    );
    bytes32 private constant FACT_ATTRIBUTION_TYPEHASH =
        keccak256("FactAttribution(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)");

    bytes32 private constant STAGE_FILE_PATCH_APPLIED_TOPIC = keccak256(
        "StageFilePatchApplied(bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32,uint256)"
    );
    bytes32 private constant STAGE_FILE_OP_APPLIED_TOPIC =
        keccak256("StageFileOpApplied(bytes32,bytes32,bytes32,uint8,bytes32,bytes32,string)");
    bytes32 private constant SIGNAL_SUBMITTED_TOPIC =
        keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,address,bytes32)");
    bytes32 private constant HOOK_STATUS_CHANGED_TOPIC =
        keccak256("HookStatusChanged(bytes32,bytes32,bytes32,uint8,uint8,uint64)");
    bytes32 private constant HOOK_READY_TOPIC = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)");
    bytes32 private constant STAGE_MATERIALIZED_TOPIC =
        keccak256("StageMaterialized(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)");

    UVPStateMachine private machine;
    UVPStagePatchModule private stagePatch;
    UVPFileResourceModule private fileResourceModule;
    UVPSupplierRegistry private suppliers;
    UVPPlanMetadataModule private planMetadataModule;
    bytes32 private planId;
    bytes32 private orderId;
    bytes32 private auditSupplierId;
    bytes32 private supplierHandoffId;
    bytes32[] private capabilityLeaves;
    bytes32[] private bindingLeaves;

    function testPureFilePatchForwardsDynamicOpsWithoutBusinessOrHookEffects() public {
        _setUpFor(_writer());

        FilePatch memory patch = _addPatch(
            bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/file-one", FILE_KEY_2, FILE_CONTENT_HASH_2
        );
        bytes32 patchHash = fileResourceModule.filePatchHash(patch);
        bytes32 filesDigest = fileResourceModule.filePatchDigest(planId, orderId, patch);

        UVPStateMachine.FactAttribution memory attribution = _emptyAttribution();
        vm.recordLogs();
        vm.prank(_writer());
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: bytes32(0),
                signalId: bytes32(0),
                payloadHash: bytes32(0),
                idempotencyKey: keccak256(abi.encode("file-patch")),
                attribution: attribution,
                filePatch: patch,
                patchHash: patchHash,
                submitter: _writer(),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(_countTopic(logs, STAGE_FILE_PATCH_APPLIED_TOPIC) == 1, "patch event count");
        require(_countTopic(logs, STAGE_FILE_OP_APPLIED_TOPIC) == 2, "op event count");
        require(_countTopic(logs, SIGNAL_SUBMITTED_TOPIC) == 0, "pure patch recorded a business signal");
        require(_countTopic(logs, HOOK_STATUS_CHANGED_TOPIC) == 0, "pure patch changed a hook");
        require(_countTopic(logs, HOOK_READY_TOPIC) == 0, "pure patch made a hook ready");
        require(_countTopic(logs, STAGE_MATERIALIZED_TOPIC) == 0, "pure patch materialized a stage");

        (bool exists, bytes32 contentHash, string memory handle, bytes32 storedPatchHash) =
            fileResourceModule.getStageFile(planId, orderId, STAGE_AUDIT, FILE_KEY);
        require(exists, "file record missing");
        require(contentHash == FILE_CONTENT_HASH, "content hash mismatch");
        require(keccak256(bytes(handle)) == keccak256(bytes("ipfs://uvp-eth/file-one")), "handle mismatch");
        require(storedPatchHash == filesDigest, "stored patch hash mismatch");
        require(fileResourceModule.stageFilesHash(planId, orderId, STAGE_AUDIT) != bytes32(0), "files hash missing");

        (uint256 stageCount,,,) = machine.stageSignalState(planId, orderId, STAGE_AUDIT);
        require(stageCount == 0, "pure patch incremented stageSignalState");
        require(!machine.hasSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE), "pure patch wrote a business signal");
        require(machine.sourceSignalCount(planId, orderId, bytes32(0)) == 0, "pure patch wrote a source signal");
    }

    function testContractSupplierAccountSubmitsSignalAndFileAtomically() public {
        DirectSignalSupplier supplierAccount = new DirectSignalSupplier();
        _setUpFor(address(supplierAccount));

        FilePatch memory patch = _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/contract-supplier", 0, 0);
        bytes32 filesDigest = fileResourceModule.filePatchDigest(planId, orderId, patch);
        supplierAccount.submit(
            machine,
            planId,
            orderId,
            SOURCE_FILE,
            SIGNAL_FILE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT),
            patch
        );

        require(machine.hasSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE), "contract supplier account signal missing");
        (bool exists,,, bytes32 storedPatchHash) = fileResourceModule.getStageFile(planId, orderId, STAGE_AUDIT, FILE_KEY);
        require(exists, "contract supplier account file patch missing");
        require(storedPatchHash == filesDigest, "contract supplier account patch hash mismatch");
        require(
            machine.effectiveStageAccount(planId, orderId, STAGE_AUDIT) == address(supplierAccount),
            "supplier account changed"
        );
    }

    function testSignalCannotWriteAnotherStageWithoutAllowlist() public {
        _setUpFor(_writer());

        FilePatch memory patch = _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/other-stage", 0, 0);
        patch.targetStageId = STAGE_INIT;
        bytes32 patchHash = fileResourceModule.filePatchHash(patch);

        UVPStateMachine.FactAttribution memory attribution = _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector,
                orderId,
                STAGE_INIT,
                bytes32(0),
                _writer()
            )
        );
        vm.prank(_writer());
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: SOURCE_FILE,
                signalId: SIGNAL_FILE,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: attribution,
                filePatch: patch,
                patchHash: patchHash,
                submitter: _writer(),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        require(!machine.hasSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE), "rejected patch recorded a signal");
    }

    function testAllowlistedWriterStageCanWriteTargetStage() public {
        _setUpFor(_writer());

        FilePatch memory patch = _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/allowlisted", 0, 0);
        patch.targetStageId = STAGE_INIT;
        patch.writerStageId = STAGE_AUDIT;
        patch.writerProof = _proofFor(planMetadataModule.fileWriterLeaf(STAGE_INIT, STAGE_AUDIT));
        bytes32 patchHash = fileResourceModule.filePatchHash(patch);

        UVPStateMachine.FactAttribution memory attribution = _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT);
        vm.prank(_writer());
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: SOURCE_FILE,
                signalId: SIGNAL_FILE,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: attribution,
                filePatch: patch,
                patchHash: patchHash,
                submitter: _writer(),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        (bool exists, bytes32 contentHash,,) = fileResourceModule.getStageFile(planId, orderId, STAGE_INIT, FILE_KEY);
        require(exists, "allowlisted writer-stage file patch missing");
        require(contentHash == FILE_CONTENT_HASH, "allowlisted content hash mismatch");
    }

    function testTamperedDeliveredPatchRejectedByPatchHash() public {
        _setUpFor(_writer());

        FilePatch memory signedPatch =
            _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/signed", 0, 0);
        FilePatch memory deliveredPatch =
            _addPatch(bytes32(0), FILE_KEY_2, FILE_CONTENT_HASH_2, "ipfs://uvp-eth/delivered", 0, 0);
        bytes32 deliveredPatchHash = fileResourceModule.filePatchHash(deliveredPatch);
        bytes32 signedPatchHash = fileResourceModule.filePatchHash(signedPatch);
        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: orderId,
            sourceId: bytes32(0),
            signalId: bytes32(0),
            payloadHash: bytes32(0),
            idempotencyKey: keccak256(abi.encode("file-patch")),
            attribution: _emptyAttribution(),
            filePatch: deliveredPatch,
            patchHash: signedPatchHash,
            submitter: _writer(),
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.PatchHashMismatch.selector, deliveredPatchHash, signedPatchHash)
        );
        vm.prank(_writer());
        machine.submitSignal(submission, hex"");
    }



    function testSupplierHandoffMovesFileWriteAuthorityToNewSupplierAccount() public {
        _setUpFor(_writer());
        address handoffWriter = vm.addr(HANDOFF_WRITER_PRIVATE_KEY);

        FilePatch memory firstPatch =
            _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/handoff-first", 0, 0);
        bytes32 firstDigest = fileResourceModule.filePatchHash(firstPatch);
        UVPStateMachine.FactAttribution memory firstAttribution =
            _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT);
        vm.prank(_writer());
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: SOURCE_FILE,
                signalId: SIGNAL_FILE,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: firstAttribution,
                filePatch: firstPatch,
                patchHash: firstDigest,
                submitter: _writer(),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        address birthSubmitter = vm.addr(BIRTH_SUBMITTER_PRIVATE_KEY);
        UVPStagePatchModule.StageSupplierPatch memory patch = UVPStagePatchModule.StageSupplierPatch({
            selectorStageId: STAGE_INIT,
            targetStageId: STAGE_AUDIT,
            supplierId: supplierHandoffId,
            previousSupplierId: auditSupplierId,
            patchNonce: 1
        });
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = stagePatch.stageSupplierPatchDigest(planId, orderId, patch, birthSubmitter, deadline);
        IUVPStateMachineCore.SelectorBindingProof memory selectorProof = IUVPStateMachineCore.SelectorBindingProof({
            selectorStageId: STAGE_INIT,
            proof: _proofFor(planMetadataModule.selectorBindingLeaf(STAGE_INIT, STAGE_AUDIT))
        });
        stagePatch.applyStageSupplierPatchFor(
            planId,
            orderId,
            patch,
            birthSubmitter,
            deadline,
            _sign(BIRTH_SUBMITTER_PRIVATE_KEY, digest),
            _sign(WRITER_PRIVATE_KEY, digest),
            selectorProof,
            _candidateProof(supplierHandoffId)
        );

        (bytes32 assignedSupplierId,,) = machine.stageSupplierAssignment(planId, orderId, STAGE_AUDIT);
        require(assignedSupplierId == supplierHandoffId, "handoff not applied");
        require(
            machine.effectiveStageAccount(planId, orderId, STAGE_AUDIT) == handoffWriter,
            "handoff supplier account not effective"
        );

        bytes32 filesHashAfterFirst = fileResourceModule.stageFilesHash(planId, orderId, STAGE_AUDIT);
        FilePatch memory rejectedPatch =
            _addPatch(filesHashAfterFirst, FILE_KEY_2, FILE_CONTENT_HASH_2, "ipfs://uvp-eth/handoff-rejected", 0, 0);
        bytes32 rejectedPatchHash = fileResourceModule.filePatchHash(rejectedPatch);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector,
                orderId,
                STAGE_AUDIT,
                bytes32(0),
                _writer()
            )
        );
        vm.prank(_writer());
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: bytes32(0),
                signalId: bytes32(0),
                payloadHash: bytes32(0),
                idempotencyKey: keccak256(abi.encode("file-patch")),
                attribution: _emptyAttribution(),
                filePatch: rejectedPatch,
                patchHash: rejectedPatchHash,
                submitter: _writer(),
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        FilePatch memory acceptedPatch =
            _addPatch(filesHashAfterFirst, FILE_KEY_2, FILE_CONTENT_HASH_2, "ipfs://uvp-eth/handoff-accepted", 0, 0);
        bytes32 acceptedPatchHash = fileResourceModule.filePatchHash(acceptedPatch);
        vm.prank(handoffWriter);
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: bytes32(0),
                signalId: bytes32(0),
                payloadHash: bytes32(0),
                idempotencyKey: keccak256(abi.encode("file-patch")),
                attribution: _emptyAttribution(),
                filePatch: acceptedPatch,
                patchHash: acceptedPatchHash,
                submitter: handoffWriter,
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );
        (bool exists, bytes32 contentHash,,) =
            fileResourceModule.getStageFile(planId, orderId, STAGE_AUDIT, FILE_KEY_2);
        require(exists && contentHash == FILE_CONTENT_HASH_2, "handoff supplier account could not write");
    }

    function _deployStack() private {
        machine = new UVPStateMachine();
        suppliers = new UVPSupplierRegistry();
        planMetadataModule = new UVPPlanMetadataModule(address(machine));
        fileResourceModule = new UVPFileResourceModule(address(machine));
        stagePatch = new UVPStagePatchModule(address(machine));
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(new UVPDerivedSignalModule(address(machine))));
        machine.setDockRegistry(address(new UVPDockRegistry(address(machine))));
        machine.setPlanMetadataModule(address(planMetadataModule));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
        machine.setFileResourceModule(address(fileResourceModule));
        machine.setSupplierRegistry(address(suppliers));
        machine.freezeModules();
    }

    function _setUpFor(address auditAccount) private {
        _deployStack();
        address birthSubmitter = vm.addr(BIRTH_SUBMITTER_PRIVATE_KEY);
        auditSupplierId = _registerSupplier(auditAccount);
        bytes32 supplierBirthId = _registerSupplier(birthSubmitter);
        supplierHandoffId = _registerSupplier(vm.addr(HANDOFF_WRITER_PRIVATE_KEY));

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _hook(
            HOOK_BIRTH,
            STAGE_INIT,
            HOOK_NAME_BIRTH,
            FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            SIGNAL_ORDER_START
        );
        hooks[1] = _hook(HOOK_FILES_READY, STAGE_AUDIT, HOOK_NAME_FILES_READY, FLAG_EMIT_READY, SIGNAL_BOOTSTRAP_READY);

        capabilityLeaves = new bytes32[](5);
        capabilityLeaves[0] =
            planMetadataModule.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, 0);
        capabilityLeaves[1] =
            planMetadataModule.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BOOTSTRAP_READY, 0);
        capabilityLeaves[2] = planMetadataModule.signalCapabilityLeaf(STAGE_AUDIT, SOURCE_FILE, SIGNAL_FILE, 0);
        capabilityLeaves[3] = planMetadataModule.fileWriterLeaf(STAGE_INIT, STAGE_AUDIT);
        capabilityLeaves[4] = planMetadataModule.selectorBindingLeaf(STAGE_INIT, STAGE_AUDIT);

        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](3);
        bindings[0] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_INIT, supplierId: supplierBirthId, kind: 0});
        bindings[1] =
            UVPStateMachine.StageSupplierBinding({stageId: STAGE_AUDIT, supplierId: auditSupplierId, kind: 0});
        bindings[2] =
            UVPStateMachine.StageSupplierBinding({stageId: STAGE_AUDIT, supplierId: supplierHandoffId, kind: 1});
        bindingLeaves = new bytes32[](bindings.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            bindingLeaves[i] = keccak256(
                abi.encodePacked(
                    _SUPPLIER_BINDING_LEAF_DOMAIN, bindings[i].stageId, bindings[i].supplierId, bindings[i].kind
                )
            );
        }

        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: MerkleCommitment.root(capabilityLeaves),
            supplierBindingsRoot: MerkleCommitment.root(bindingLeaves),
            deadline: block.timestamp + 1 hours
        });
        planId = machine.commitPlan(commit, hooks, bindings, _sign(PUBLISHER_PRIVATE_KEY, _planCommitDigest(commit)));
        machine.finalizePlan(planId);

        UVPStateMachine.SignalSubmission memory birth = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            attribution: _attribution(SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, STAGE_INIT),
            filePatch: emptyFilePatch(),
            patchHash: bytes32(0),
            submitter: birthSubmitter,
            deadline: block.timestamp + 1 hours
        });
        machine.submitSignal(birth, _sign(BIRTH_SUBMITTER_PRIVATE_KEY, _signalSubmissionDigest(birth)));
        orderId = _createdTriggerOrderId(birth);

        UVPStateMachine.FactAttribution memory bootstrapAttribution =
            _attribution(SOURCE_BOOTSTRAP, SIGNAL_BOOTSTRAP_READY, STAGE_INIT);
        FilePatch memory noFilePatch = emptyFilePatch();
        vm.prank(birthSubmitter);
        machine.submitSignal(
            UVPStateMachine.SignalSubmission({
                planId: planId,
                orderId: orderId,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_BOOTSTRAP_READY,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                attribution: bootstrapAttribution,
                filePatch: noFilePatch,
                patchHash: bytes32(0),
                submitter: birthSubmitter,
                deadline: block.timestamp + 1 hours
            }),
            hex""
        );

        (UVPStateMachine.HookStatus filesReadyStatus,, bool filesReadyEmitted) =
            machine.getHookStatus(planId, orderId, HOOK_FILES_READY);
        require(filesReadyStatus == UVPStateMachine.HookStatus.Ready, "audit stage hook not ready");
        require(filesReadyEmitted, "audit stage hook not emitted");
        require(
            machine.effectiveStageAccount(planId, orderId, STAGE_AUDIT) == auditAccount,
            "audit supplier account not effective"
        );
    }

    function _registerSupplier(address account) private returns (bytes32 supplierId) {
        vm.prank(account);
        supplierId = suppliers.registerSupplier(account);
        suppliers.activateSupplier(supplierId);
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

    function _signalSubmissionDigest(UVPStateMachine.SignalSubmission memory submission)
        private
        view
        returns (bytes32)
    {
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
                submission.patchHash,
                attributionHash,
                submission.submitter,
                submission.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", machine.DOMAIN_SEPARATOR(), structHash));
    }

    function _createdTriggerOrderId(UVPStateMachine.SignalSubmission memory submission)
        private
        returns (bytes32 generatedOrderId)
    {
        try machine.submitSignal(submission, _sign(BIRTH_SUBMITTER_PRIVATE_KEY, _signalSubmissionDigest(submission))) {
            revert("duplicate trigger submission did not revert");
        } catch (bytes memory reason) {
            require(reason.length == 100, "unexpected duplicate trigger payload length");
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
            require(selector == UVPStateMachine.DuplicateTriggerKey.selector, "unexpected duplicate trigger revert");
            (, , generatedOrderId) = abi.decode(_withoutSelector(reason), (address, bytes32, bytes32));
        }
    }

    function _withoutSelector(bytes memory reason) private pure returns (bytes memory data) {
        data = new bytes(reason.length - 4);
        for (uint256 i = 4; i < reason.length; i++) {
            data[i - 4] = reason[i];
        }
    }


    function _writer() private view returns (address) {
        return vm.addr(WRITER_PRIVATE_KEY);
    }

    function _hook(bytes32 hookId, bytes32 stageId, bytes32 hookName, uint8 flags, bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory dependencyKeys = new bytes32[](1);
        dependencyKeys[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId));
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: hookName,
            flags: flags,
            instructions: instructions,
            dependencyKeys: dependencyKeys
        });
    }

    function _addPatch(
        bytes32 baseHash,
        bytes32 firstKey,
        bytes32 firstContentHash,
        string memory firstHandle,
        bytes32 secondKey,
        bytes32 secondContentHash
    ) private pure returns (FilePatch memory patch) {
        uint256 opCount = secondKey == bytes32(0) ? 1 : 2;
        FileOp[] memory ops = new FileOp[](opCount);
        ops[0] = FileOp({
            kind: uint8(FileOpKind.Add), key: firstKey, contentHash: firstContentHash, handle: firstHandle
        });
        if (opCount == 2) {
            ops[1] = FileOp({
                kind: uint8(FileOpKind.Add), key: secondKey, contentHash: secondContentHash, handle: "ipfs://uvp-eth/second"
            });
        }
        patch = FilePatch({
            targetStageId: STAGE_AUDIT,
            baseHash: baseHash,
            writerStageId: bytes32(0),
            writerProof: new bytes32[](0),
            ops: ops
        });
    }

    function _attribution(bytes32 sourceId, bytes32 signalId, bytes32 stageId)
        private
        view
        returns (UVPStateMachine.FactAttribution memory)
    {
        bytes32 leaf = planMetadataModule.signalCapabilityLeaf(stageId, sourceId, signalId, 0);
        return UVPStateMachine.FactAttribution({
            sourceId: sourceId,
            signalId: signalId,
            stageId: stageId,
            capabilityProof: _proofFor(leaf)
        });
    }

    function _emptyAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
    }

    function _proofFor(bytes32 leaf) private view returns (bytes32[] memory) {
        bytes32 root = planMetadataModule.capabilitiesRoot(planId);
        require(MerkleCommitment.root(capabilityLeaves) == root, "test: capability root drifted");
        return _merkleProofFor(_sortedUnique(capabilityLeaves), leaf);
    }

    function _candidateProof(bytes32 supplierId) private view returns (bytes32[] memory) {
        bytes32 leaf = keccak256(
            abi.encodePacked(_SUPPLIER_BINDING_LEAF_DOMAIN, STAGE_AUDIT, supplierId, uint8(1))
        );
        return _merkleProofFor(_sortedUnique(bindingLeaves), leaf);
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count++;
            }
        }
    }

    function _sortedUnique(bytes32[] memory raw) private pure returns (bytes32[] memory sorted) {
        sorted = new bytes32[](raw.length);
        uint256 count;
        for (uint256 i = 0; i < raw.length; i++) {
            bool duplicate = false;
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
        bytes32[] memory buffer = new bytes32[](256);
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
}

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function addr(uint256 privateKey) external pure returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function prank(address msgSender) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function expectRevert(bytes calldata revertData) external;
}
