// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
import {FileOp, FileOpKind, FilePatch} from "../src/interfaces/IUVPFileResourceModule.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";
import {emptyFilePatch} from "./FilePatchTestHelpers.sol";

/// Core 0.16 file-patch entry: splice forwarding, duplicate-signal absorption,
/// pure-patch isolation and the module's named digest rejections.
contract DirectSignalExecutor {
    function submit(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        UVPStateMachine.FactAttribution calldata attribution,
        bytes32 filesDigest,
        FilePatch calldata filePatch
    ) external {
        machine.submitSignal(
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, attribution, filesDigest, filePatch
        );
    }
}

contract UVPStateMachineFilePatchTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant BIRTH_SUBMITTER_PRIVATE_KEY = 0xa11ce;
    uint256 private constant WRITER_PRIVATE_KEY = 0xb0b;

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
    bytes32 private constant ROLE_EXECUTOR = bytes32(uint256(0xa003));
    bytes32 private constant EXECUTOR_METADATA_HASH = bytes32(uint256(0xa004));
    bytes32 private constant PATCH_HASH = bytes32(uint256(0xa006));
    bytes32 private constant FILE_KEY = bytes32(uint256(0xd001));
    bytes32 private constant FILE_KEY_2 = bytes32(uint256(0xd002));
    bytes32 private constant FILE_CONTENT_HASH = bytes32(uint256(0xf001));
    bytes32 private constant FILE_CONTENT_HASH_2 = bytes32(uint256(0xf002));

    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;

    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline,bytes32 filesDigest)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    bytes32 private constant STAGE_FILE_PATCH_APPLIED_TOPIC = keccak256(
        "StageFilePatchApplied(bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32,uint256)"
    );
    bytes32 private constant STAGE_FILE_OP_APPLIED_TOPIC =
        keccak256("StageFileOpApplied(bytes32,bytes32,bytes32,uint8,bytes32,bytes32,string)");
    bytes32 private constant SIGNAL_SUBMITTED_TOPIC =
        keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32)");
    bytes32 private constant HOOK_STATUS_CHANGED_TOPIC =
        keccak256("HookStatusChanged(bytes32,bytes32,bytes32,uint8,uint8,uint64)");
    bytes32 private constant HOOK_READY_TOPIC = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)");
    bytes32 private constant STAGE_MATERIALIZED_TOPIC =
        keccak256("StageMaterialized(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)");

    UVPStateMachine private machine;
    UVPFileResourceModule private fileResourceModule;
    UVPStagePatchModule private stagePatchModule;
    UVPPlanMetadataModule private planMetadataModule;
    bytes32 private planId;
    bytes32 private orderId;
    bytes32[] private capabilityLeaves;

    function testPureFilePatchForwardsDynamicOpsWithoutBusinessOrHookEffects() public {
        _setUp();

        FilePatch memory patch = _addPatch(
            bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/file-one", FILE_KEY_2, FILE_CONTENT_HASH_2
        );
        bytes32 filesDigest = fileResourceModule.filePatchDigest(planId, orderId, patch);

        vm.recordLogs();
        vm.prank(_writer());
        machine.submitSignal(
            planId,
            orderId,
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            _emptyAttribution(),
            filesDigest,
            patch
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(_countTopic(logs, STAGE_FILE_PATCH_APPLIED_TOPIC) == 1, "patch event count");
        require(_countTopic(logs, STAGE_FILE_OP_APPLIED_TOPIC) == 2, "op event count");
        require(_countTopic(logs, SIGNAL_SUBMITTED_TOPIC) == 0, "pure patch recorded a business signal");
        require(_countTopic(logs, HOOK_STATUS_CHANGED_TOPIC) == 0, "pure patch changed a hook");
        require(_countTopic(logs, HOOK_READY_TOPIC) == 0, "pure patch made a hook ready");
        require(_countTopic(logs, STAGE_MATERIALIZED_TOPIC) == 0, "pure patch materialized a stage");

        (bool exists, bytes32 contentHash, string memory handle, bytes32 patchHash) =
            fileResourceModule.getStageFile(planId, orderId, STAGE_AUDIT, FILE_KEY);
        require(exists, "file record missing");
        require(contentHash == FILE_CONTENT_HASH, "content hash mismatch");
        require(keccak256(bytes(handle)) == keccak256(bytes("ipfs://uvp-eth/file-one")), "handle mismatch");
        require(patchHash == filesDigest, "stored patch hash mismatch");
        require(fileResourceModule.stageFilesHash(planId, orderId, STAGE_AUDIT) != bytes32(0), "files hash missing");

        (uint256 stageCount,,,) = machine.stageSignalState(planId, orderId, STAGE_AUDIT);
        require(stageCount == 0, "pure patch incremented stageSignalState");
        require(!machine.hasSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE), "pure patch wrote a business signal");
        require(machine.sourceSignalCount(planId, orderId, bytes32(0)) == 0, "pure patch wrote a source signal");
    }

    function testContractExecutorSubmitsSignalAndFileAtomically() public {
        DirectSignalExecutor executor = new DirectSignalExecutor();
        _setUpFor(address(executor));

        FilePatch memory patch = _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/contract-executor", 0, 0);
        bytes32 filesDigest = fileResourceModule.filePatchDigest(planId, orderId, patch);
        executor.submit(
            machine,
            planId,
            orderId,
            SOURCE_FILE,
            SIGNAL_FILE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT),
            filesDigest,
            patch
        );

        require(machine.hasSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE), "contract executor signal missing");
        (bool exists,,, bytes32 patchHash) = fileResourceModule.getStageFile(planId, orderId, STAGE_AUDIT, FILE_KEY);
        require(exists, "contract executor file patch missing");
        require(patchHash == filesDigest, "contract executor patch hash mismatch");
        require(machine.activeStageExecutor(planId, orderId, STAGE_AUDIT) == address(executor), "executor changed");
    }

    function testSignalCannotWriteAnotherStageWithoutAllowlist() public {
        _setUp();

        FilePatch memory patch =
            _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/other-stage", 0, 0);
        patch.targetStageId = STAGE_INIT;
        bytes32 filesDigest = fileResourceModule.filePatchDigest(planId, orderId, patch);
        UVPStateMachine.FactAttribution memory attribution = _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT);

        vm.prank(_writer());
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector,
                orderId,
                STAGE_INIT,
                bytes32(0),
                _writer()
            )
        );
        machine.submitSignal(
            planId,
            orderId,
            SOURCE_FILE,
            SIGNAL_FILE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            attribution,
            filesDigest,
            patch
        );

        require(!machine.hasSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE), "rejected patch recorded a signal");
    }

    function testDuplicateBusinessSignalDoesNotReplayFilePatch() public {
        _setUp();

        FilePatch memory firstPatch = _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/first", 0, 0);
        bytes32 firstFilesDigest = fileResourceModule.filePatchDigest(planId, orderId, firstPatch);
        UVPStateMachine.FactAttribution memory firstAttribution =
            _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT);
        vm.prank(_writer());
        machine.submitSignal(
            planId,
            orderId,
            SOURCE_FILE,
            SIGNAL_FILE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            firstAttribution,
            firstFilesDigest,
            firstPatch
        );

        require(machine.hasSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE), "business signal missing");
        (uint256 stageCount,,,) = machine.stageSignalState(planId, orderId, STAGE_AUDIT);
        require(stageCount == 1, "stage signal count after first request");
        (bool firstExists,,, bytes32 firstPatchHash) =
            fileResourceModule.getStageFile(planId, orderId, STAGE_AUDIT, FILE_KEY);
        require(firstExists, "first patch not applied");
        require(firstPatchHash == firstFilesDigest, "first patch hash mismatch");
        bytes32 filesHashAfterFirst = fileResourceModule.stageFilesHash(planId, orderId, STAGE_AUDIT);

        FilePatch memory secondPatch =
            _addPatch(filesHashAfterFirst, FILE_KEY_2, FILE_CONTENT_HASH_2, "ipfs://uvp-eth/second", 0, 0);
        bytes32 secondFilesDigest = fileResourceModule.filePatchDigest(planId, orderId, secondPatch);
        UVPStateMachine.FactAttribution memory secondAttribution =
            _attribution(SOURCE_FILE, SIGNAL_FILE, STAGE_AUDIT);
        vm.prank(_writer());
        machine.submitSignal(
            planId,
            orderId,
            SOURCE_FILE,
            SIGNAL_FILE,
            PAYLOAD_HASH_2,
            IDEMPOTENCY_KEY_2,
            secondAttribution,
            secondFilesDigest,
            secondPatch
        );

        (bool firstSignalExists, bytes32 recordedPayloadHash,,,) =
            machine.getSignal(planId, orderId, SOURCE_FILE, SIGNAL_FILE);
        require(firstSignalExists, "duplicate request erased the signal");
        require(recordedPayloadHash == PAYLOAD_HASH, "duplicate request rewrote the signal");
        (bool secondExists,,,) = fileResourceModule.getStageFile(planId, orderId, STAGE_AUDIT, FILE_KEY_2);
        require(!secondExists, "duplicate request replayed the file patch");
        require(
            fileResourceModule.stageFilesHash(planId, orderId, STAGE_AUDIT) == filesHashAfterFirst,
            "duplicate request moved stage files hash"
        );
        (uint256 countAfterDuplicate,,,) = machine.stageSignalState(planId, orderId, STAGE_AUDIT);
        require(countAfterDuplicate == 1, "duplicate request incremented stageSignalState");
    }

    function testTamperedDeliveredPatchRejectedByModuleDigest() public {
        _setUp();

        FilePatch memory signedPatch =
            _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/signed", 0, 0);
        bytes32 signedFilesDigest = fileResourceModule.filePatchDigest(planId, orderId, signedPatch);

        FilePatch memory deliveredPatch =
            _addPatch(bytes32(0), FILE_KEY_2, FILE_CONTENT_HASH_2, "ipfs://uvp-eth/delivered", 0, 0);
        bytes32 deliveredFilesDigest = fileResourceModule.filePatchDigest(planId, orderId, deliveredPatch);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileDigestMismatch.selector, deliveredFilesDigest, signedFilesDigest
            )
        );
        vm.prank(_writer());
        machine.submitSignal(
            planId,
            orderId,
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            _emptyAttribution(),
            signedFilesDigest,
            deliveredPatch
        );
    }

    function testSignedFilesDigestMismatchRejected() public {
        _setUp();

        FilePatch memory patch = _addPatch(bytes32(0), FILE_KEY, FILE_CONTENT_HASH, "ipfs://uvp-eth/wrong-digest", 0, 0);
        bytes32 canonicalFilesDigest = fileResourceModule.filePatchDigest(planId, orderId, patch);
        bytes32 wrongFilesDigest = bytes32(uint256(0xdead));

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileDigestMismatch.selector, canonicalFilesDigest, wrongFilesDigest
            )
        );
        vm.prank(_writer());
        machine.submitSignal(
            planId,
            orderId,
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            _emptyAttribution(),
            wrongFilesDigest,
            patch
        );
    }

    function _setUp() private {
        _setUpFor(_writer());
    }

    function _setUpFor(address executor) private {
        UVPStateMachine newMachine = new UVPStateMachine();
        UVPStagePatchModule newStagePatch = new UVPStagePatchModule(address(newMachine));
        UVPDerivedSignalModule newDerivedSignal = new UVPDerivedSignalModule(address(newMachine));
        UVPPlanMetadataModule newPlanMetadata = new UVPPlanMetadataModule(address(newMachine));
        UVPDockingModule newDocking = new UVPDockingModule(address(newMachine), address(newPlanMetadata));
        UVPOrderLinkModule newOrderLink = new UVPOrderLinkModule(address(newMachine));
        UVPFileResourceModule newFileModule = new UVPFileResourceModule(address(newMachine));
        newMachine.setStagePatchModule(address(newStagePatch));
        newMachine.setDerivedSignalModule(address(newDerivedSignal));
        newMachine.setDockingModule(address(newDocking));
        newMachine.setPlanMetadataModule(address(newPlanMetadata));
        newMachine.setOrderLinkModule(address(newOrderLink));
        newMachine.setLens(address(new UVPStateMachineLens(address(newMachine))));
        newMachine.setFileResourceModule(address(newFileModule));
        newMachine.freezeModules();
        machine = newMachine;
        stagePatchModule = newStagePatch;
        planMetadataModule = newPlanMetadata;
        fileResourceModule = newFileModule;

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _hook(
            HOOK_BIRTH,
            STAGE_INIT,
            HOOK_NAME_BIRTH,
            FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            SIGNAL_ORDER_START
        );
        hooks[1] = _hook(HOOK_FILES_READY, STAGE_AUDIT, HOOK_NAME_FILES_READY, FLAG_EMIT_READY, SIGNAL_BOOTSTRAP_READY);

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = newPlanMetadata.selectorBindingLeaf(STAGE_INIT, STAGE_AUDIT);
        leaves[1] = newPlanMetadata.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, 0);
        leaves[2] = newPlanMetadata.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_BOOTSTRAP_READY, 0);
        leaves[3] = newPlanMetadata.signalCapabilityLeaf(STAGE_AUDIT, SOURCE_FILE, SIGNAL_FILE, 0);
        capabilityLeaves = _sortedUnique(leaves);

        UVPStateMachine.ExecutorCandidate[] memory candidates = new UVPStateMachine.ExecutorCandidate[](1);
        candidates[0] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: executor});
        bytes32[] memory candidateLeaves = new bytes32[](1);
        candidateLeaves[0] =
            keccak256(abi.encodePacked(stagePatchModule.EXECUTOR_CANDIDATE_LEAF_DOMAIN(), STAGE_AUDIT, executor));
        bytes32[] memory sortedCandidateLeaves = _sortedUnique(candidateLeaves);

        address birthSubmitter = vm.addr(BIRTH_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(leaves),
            dockRoutesRoot: DockMerkle.EMPTY_ROOT,
            dockInterfaceRoot: DockMerkle.EMPTY_ROOT,
            executorCandidatesRoot: DockMerkle.root(candidateLeaves),
            birthAuthorizer: birthSubmitter,
            deadline: block.timestamp + 1 hours
        });
        bytes32 commitDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        PLAN_COMMIT_TYPEHASH,
                        commit.publisher,
                        commit.hooksHash,
                        commit.capabilitiesRoot,
                        commit.dockRoutesRoot,
                        commit.dockInterfaceRoot,
                        commit.executorCandidatesRoot,
                        commit.birthAuthorizer,
                        commit.deadline
                    )
                )
            )
        );
        planId = newMachine.commitPlan(commit, hooks, candidates, _sign(PUBLISHER_PRIVATE_KEY, commitDigest));
        newMachine.finalizePlan(planId);

        UVPStateMachine.SignalAuthorization[] memory authorizations =
            new UVPStateMachine.SignalAuthorization[](3);
        authorizations[0] = _authorization(SOURCE_BOOTSTRAP, SIGNAL_BOOTSTRAP_READY, birthSubmitter);
        authorizations[1] = _authorization(SOURCE_FILE, SIGNAL_FILE, executor);
        authorizations[2] = _authorization(STAGE_AUDIT, fileResourceModule.FILE_WRITE_SIGNAL_ID(), executor);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: planId,
            creator: address(this),
            triggerHookId: HOOK_BIRTH,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: birthSubmitter,
            deadline: block.timestamp + 1 hours
        });
        orderId = newMachine.triggerOrderIdFor(planId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH);
        bytes32 triggerDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
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
                        newMachine.signalAuthorizationsHash(authorizations),
                        trigger.submitter,
                        trigger.deadline
                    )
                )
            )
        );
        newMachine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            _sign(BIRTH_SUBMITTER_PRIVATE_KEY, triggerDigest),
            _attribution(SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, STAGE_INIT)
        );

        UVPStateMachine.FactAttribution memory readyAttribution =
            _attribution(SOURCE_BOOTSTRAP, SIGNAL_BOOTSTRAP_READY, STAGE_INIT);
        vm.prank(birthSubmitter);
        newMachine.submitSignal(
            planId,
            orderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_BOOTSTRAP_READY,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            readyAttribution
        , bytes32(0), emptyFilePatch());

        (UVPStateMachine.HookStatus filesReadyStatus,, bool filesReadyEmitted) =
            newMachine.getHookStatus(planId, orderId, HOOK_FILES_READY);
        require(filesReadyStatus == UVPStateMachine.HookStatus.Ready, "audit stage hook not ready");
        require(filesReadyEmitted, "audit stage hook not emitted");

        IUVPStateMachineCore.SignalAuthorization[] memory noAuthorizations =
            new IUVPStateMachineCore.SignalAuthorization[](0);
        UVPStateMachine.SignalAuthorization[] memory noCoreAuthorizations =
            new UVPStateMachine.SignalAuthorization[](0);
        UVPStagePatchModule.StageExecutorPatch memory patch = UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: STAGE_INIT,
            targetStageId: STAGE_AUDIT,
            executor: executor,
            role: ROLE_EXECUTOR,
            executorMetadataHash: EXECUTOR_METADATA_HASH,
            mode: stagePatchModule.EXECUTOR_PATCH_MODE_ASSIGN(),
            previousExecutor: address(0),
            authorizationsHash: newMachine.signalAuthorizationsHash(noCoreAuthorizations),
            patchHash: PATCH_HASH,
            patchNonce: 1,
            metadataURI: "uvp-eth://file-writer"
        });
        IUVPStateMachineCore.SelectorBindingProof memory bindingProof = IUVPStateMachineCore.SelectorBindingProof({
            selectorStageId: STAGE_INIT,
            proof: _merkleProofFor(
                capabilityLeaves, newPlanMetadata.selectorBindingLeaf(STAGE_INIT, STAGE_AUDIT)
            )
        });
        newStagePatch.applyStageExecutorPatch(
            planId,
            orderId,
            patch,
            bindingProof,
            _merkleProofFor(sortedCandidateLeaves, candidateLeaves[0]),
            noAuthorizations
        );
        require(newMachine.activeStageExecutor(planId, orderId, STAGE_AUDIT) == executor, "executor not active");
    }

    function _domainSeparator() private view returns (bytes32) {
        return machine.DOMAIN_SEPARATOR();
    }

    function _signalDigest(
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        uint256 deadline,
        bytes32 filesDigest
    ) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        SIGNAL_SUBMISSION_TYPEHASH,
                        planId,
                        orderId,
                        sourceId,
                        signalId,
                        payloadHash,
                        idempotencyKey,
                        _writer(),
                        deadline,
                        filesDigest
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

    function _writer() private view returns (address) {
        return vm.addr(WRITER_PRIVATE_KEY);
    }

    function _hook(
        bytes32 hookId,
        bytes32 stageId,
        bytes32 hookName,
        uint8 flags,
        bytes32 signalId
    ) private pure returns (UVPStateMachine.CompactHook memory) {
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

    function _authorization(bytes32 sourceId, bytes32 signalId, address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization memory)
    {
        return UVPStateMachine.SignalAuthorization({
            sourceId: sourceId,
            signalId: signalId,
            submitter: submitter,
            role: ROLE_EXECUTOR,
            metadataHash: EXECUTOR_METADATA_HASH
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
            capabilityProof: _merkleProofFor(capabilityLeaves, leaf)
        });
    }

    function _emptyAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
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
