// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPDockRegistry} from "../src/UVPDockRegistry.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {FilePatch} from "../src/interfaces/IUVPFileResourceModule.sol";
import {UVPSupplierRegistry} from "../src/UVPSupplierRegistry.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";
import {MerkleCommitment} from "../src/libraries/MerkleCommitment.sol";
import {_EXECUTOR_BINDING_LEAF_DOMAIN} from "../src/UVPStateMachineConstants.sol";
import {emptyFilePatch} from "./FilePatchTestHelpers.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function addr(uint256 privateKey) external view returns (address keyAddr);
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address msgSender) external;
    function recordLogs() external;
    function sign(uint256 privateKey, bytes32 digest) external view returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

contract ExecutorChangeBlackBoxTest {
    struct PreparedPatch {
        UVPStagePatchModule.StageExecutorPatch patch;
        IUVPStateMachineCore.SelectorBindingProof bindingProof;
        bytes32[] candidateProof;
        address selector;
        uint256 deadline;
        bytes selectorSignature;
        bytes previousExecutorSignature;
    }

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant SOURCE_BOOTSTRAP = bytes32(uint256(0x3001));
    bytes32 private constant SOURCE_DYN = bytes32(uint256(0x3002));
    bytes32 private constant SIGNAL_ORDER_START = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_INIT_CMP = bytes32(uint256(0x4002));
    bytes32 private constant SIGNAL_FIXED_READY = bytes32(uint256(0x4003));
    bytes32 private constant SIGNAL_DYN_READY = bytes32(uint256(0x4004));
    bytes32 private constant SIGNAL_STAGE_DONE = bytes32(uint256(0x4005));
    bytes32 private constant SIGNAL_STAGE_REVIEW = bytes32(uint256(0x4006));
    bytes32 private constant SIGNAL_DYN = bytes32(uint256(0x4007));
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_AUDIT = bytes32(uint256(0x5002));
    bytes32 private constant STAGE_FIXED = bytes32(uint256(0x5003));
    bytes32 private constant STAGE_DYN = bytes32(uint256(0x5004));
    bytes32 private constant HOOK_BIRTH = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_AUDIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_FIXED = bytes32(uint256(0x6002));
    bytes32 private constant HOOK_DYN = bytes32(uint256(0x6003));
    bytes32 private constant HOOK_NAME_BIRTH = bytes32(uint256(0x7005));
    bytes32 private constant HOOK_NAME_AUDIT = bytes32(uint256(0x7006));
    bytes32 private constant HOOK_NAME_FIXED = bytes32(uint256(0x7007));
    bytes32 private constant HOOK_NAME_DYN = bytes32(uint256(0x7008));
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant PAYLOAD_HASH_2 = bytes32(uint256(0x8002));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant IDEMPOTENCY_KEY_2 = bytes32(uint256(0x9002));
    bytes32 private constant SUPPLIER_SELECTOR = bytes32(uint256(0x5101));
    bytes32 private constant SUPPLIER_DEFAULT = bytes32(uint256(0x5102));
    bytes32 private constant SUPPLIER_FIXED = bytes32(uint256(0x5103));
    bytes32 private constant SUPPLIER_CAND1 = bytes32(uint256(0x5104));
    bytes32 private constant SUPPLIER_CAND2 = bytes32(uint256(0x5105));
    bytes32 private constant SUPPLIER_CAND3 = bytes32(uint256(0x5106));
    bytes32 private constant SUPPLIER_DYN = bytes32(uint256(0x5107));

    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_DYNAMIC_EXECUTOR = 32;

    uint256 private constant SELECTOR_PRIVATE_KEY = 0xa11ce;
    uint256 private constant DEFAULT_PRIVATE_KEY = 0xb0e;
    uint256 private constant FIXED_PRIVATE_KEY = 0xb0f;
    uint256 private constant CAND1_PRIVATE_KEY = 0xb0b;
    uint256 private constant CAND2_PRIVATE_KEY = 0xb0c;
    uint256 private constant CAND3_PRIVATE_KEY = 0xb0d;
    uint256 private constant DYN_PRIVATE_KEY = 0xb10;
    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;

    address private constant CREATOR = address(uint160(0xc0de));
    address private constant STRANGER = address(uint160(0xbad));

    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 executorBindingsRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );

    UVPStateMachine private machine;
    UVPStagePatchModule private stagePatch;
    UVPSupplierRegistry private suppliers;
    UVPPlanMetadataModule private metadata;
    UVPFileResourceModule private files;
    bytes32 private planId;
    bytes32 private orderId;
    bytes32[] private capabilityLeaves;
    bytes32[] private bindingLeaves;

    function setUp() public {
        _deployStack();
        _commitAndBirth();
    }

    function testCandidateProofMustMatchStageSupplierAndStageType() public {
        UVPStagePatchModule.StageExecutorPatch memory patch =
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 1);

        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, planId, orderId, STAGE_AUDIT, SUPPLIER_CAND1
            ),
            patch,
            _bindingProof(STAGE_AUDIT),
            new bytes32[](0)
        );
        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, planId, orderId, STAGE_AUDIT, SUPPLIER_CAND1
            ),
            patch,
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND2)
        );

        _applyDirect(patch, _bindingProof(STAGE_AUDIT), _candidateProof(SUPPLIER_CAND1));
        (bytes32 supplierId, uint256 patchNonce, bytes32 dockId) =
            machine.activeStageExecutorPatch(planId, orderId, STAGE_AUDIT);
        require(supplierId == SUPPLIER_CAND1 && patchNonce == 1 && dockId == bytes32(0), "candidate patch not applied");
        (bytes32 effectiveSupplierId, address effectiveExecutor) =
            machine.effectiveStageExecutor(planId, orderId, STAGE_AUDIT);
        require(effectiveSupplierId == SUPPLIER_CAND1 && effectiveExecutor == _cand1(), "effective executor wrong");
    }

    function testFixedAndBirthStagePatchesForbidden() public {
        UVPStagePatchModule.StageExecutorPatch memory fixedPatch =
            _patch(STAGE_FIXED, SUPPLIER_FIXED, bytes32(0), 1);
        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchForbiddenOnFixedStage.selector, orderId, STAGE_FIXED
            ),
            fixedPatch,
            IUVPStateMachineCore.SelectorBindingProof({selectorStageId: STAGE_INIT, proof: new bytes32[](0)}),
            new bytes32[](0)
        );

        UVPStagePatchModule.StageExecutorPatch memory birthPatch =
            _patch(STAGE_INIT, SUPPLIER_SELECTOR, bytes32(0), 1);
        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchForbiddenOnBirthStage.selector, orderId, STAGE_INIT
            ),
            birthPatch,
            IUVPStateMachineCore.SelectorBindingProof({selectorStageId: STAGE_INIT, proof: new bytes32[](0)}),
            new bytes32[](0)
        );
    }

    function testSelectorMustBeEffectiveExecutorAndOrderCreatorHasNoBypass() public {
        UVPStagePatchModule.StageExecutorPatch memory patch =
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 1);

        IUVPStateMachineCore.SelectorBindingProof memory selectorProof = _bindingProof(STAGE_AUDIT);
        bytes32[] memory candidateProof = _candidateProof(SUPPLIER_CAND1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageExecutorPatchSelector.selector, orderId, STAGE_INIT, CREATOR
            )
        );
        vm.prank(CREATOR);
        stagePatch.applyStageExecutorPatch(planId, orderId, patch, selectorProof, candidateProof);

        PreparedPatch memory prepared = _prepareWithSelector(patch, _cand1(), CAND1_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageExecutorPatchSelector.selector, orderId, STAGE_INIT, _cand1()
            )
        );
        _sendRelayed(prepared);
    }

    function testSelectorBindingProofMustMatch() public {
        UVPStagePatchModule.StageExecutorPatch memory patch =
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 1);

        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageSelectorBindingNotFound.selector, planId, STAGE_INIT, STAGE_AUDIT
            ),
            patch,
            IUVPStateMachineCore.SelectorBindingProof({selectorStageId: STAGE_AUDIT, proof: new bytes32[](0)}),
            _candidateProof(SUPPLIER_CAND1)
        );
        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageSelectorBindingNotFound.selector, planId, STAGE_INIT, STAGE_AUDIT
            ),
            patch,
            IUVPStateMachineCore.SelectorBindingProof({selectorStageId: STAGE_INIT, proof: new bytes32[](0)}),
            _candidateProof(SUPPLIER_CAND1)
        );
    }

    function testAssignThenHandoffLifecycle() public {
        _applyDirect(
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 1),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND1)
        );
        _submit(STAGE_AUDIT, STAGE_AUDIT, SIGNAL_STAGE_DONE, _cand1());

        _expectPatchRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, orderId, STAGE_AUDIT),
            _patch(STAGE_AUDIT, SUPPLIER_CAND2, bytes32(0), 2),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND2)
        );

        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchPreviousSupplierMismatch.selector,
                orderId,
                STAGE_AUDIT,
                SUPPLIER_CAND1,
                SUPPLIER_DEFAULT
            ),
            _patch(STAGE_AUDIT, SUPPLIER_CAND2, SUPPLIER_DEFAULT, 2),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND2)
        );

        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, _cand1(), address(0)
            ),
            _patch(STAGE_AUDIT, SUPPLIER_CAND2, SUPPLIER_CAND1, 2),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND2)
        );

        PreparedPatch memory wrongSigner = _prepare(_patch(STAGE_AUDIT, SUPPLIER_CAND2, SUPPLIER_CAND1, 2));
        wrongSigner.previousExecutorSignature =
            _signatureOver(DEFAULT_PRIVATE_KEY, _digestFor(orderId, wrongSigner.patch, wrongSigner.selector, wrongSigner.deadline));
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, _cand1(), _default()
            )
        );
        _sendRelayed(wrongSigner);

        PreparedPatch memory handoff = _prepare(_patch(STAGE_AUDIT, SUPPLIER_CAND2, SUPPLIER_CAND1, 2));
        handoff.previousExecutorSignature =
            _signatureOver(CAND1_PRIVATE_KEY, _digestFor(orderId, handoff.patch, handoff.selector, handoff.deadline));
        _sendRelayed(handoff);
        (bytes32 supplierId, uint256 patchNonce,) = machine.activeStageExecutorPatch(planId, orderId, STAGE_AUDIT);
        require(supplierId == SUPPLIER_CAND2 && patchNonce == 2, "handoff not applied");

        _submit(STAGE_AUDIT, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, _cand2());
        (,,,, address submitter) = machine.getSignal(planId, orderId, STAGE_AUDIT, SIGNAL_STAGE_REVIEW);
        require(submitter == _cand2(), "handoff executor submit not recorded");
    }

    function testPatchNonceMustIncrease() public {
        _applyDirect(
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 2),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND1)
        );
        _expectPatchRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchNonceNotIncreasing.selector, orderId, STAGE_AUDIT, 2, 2
            ),
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 2),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND1)
        );
    }

    function testDynamicStagePatchSkipsCandidateProofAndRequiresAssignment() public {
        _submitExpectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, orderId, STAGE_DYN),
            SOURCE_DYN,
            STAGE_DYN,
            SIGNAL_DYN,
            _dyn()
        );

        _applyDirect(_patch(STAGE_DYN, SUPPLIER_DYN, bytes32(0), 1), _bindingProof(STAGE_DYN), new bytes32[](0));
        (bytes32 supplierId, uint256 patchNonce, bytes32 dockId) =
            machine.activeStageExecutorPatch(planId, orderId, STAGE_DYN);
        require(supplierId == SUPPLIER_DYN && patchNonce == 1 && dockId == bytes32(0), "dynamic assign not applied");

        _submit(SOURCE_DYN, STAGE_DYN, SIGNAL_DYN, _dyn());
        (uint256 count,,,) = machine.stageSignalState(planId, orderId, STAGE_DYN);
        require(count == 1, "dynamic stage fact not counted");

        _expectPatchRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, orderId, STAGE_DYN),
            _patch(STAGE_DYN, SUPPLIER_DYN, bytes32(0), 2),
            _bindingProof(STAGE_DYN),
            new bytes32[](0)
        );
    }

    function testRevokedSupplierCannotBeAssigned() public {
        suppliers.revokeSupplier(SUPPLIER_CAND3);
        _expectPatchRevert(
            abi.encodeWithSelector(UVPStagePatchModule.SupplierNotRegistered.selector, SUPPLIER_CAND3),
            _patch(STAGE_AUDIT, SUPPLIER_CAND3, bytes32(0), 1),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND3)
        );
    }

    function testEffectiveExecutorBoundSubmitAfterPatch() public {
        _applyDirect(
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 1),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND1)
        );

        _submitExpectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, orderId, STAGE_AUDIT, _default(), _cand1()
            ),
            STAGE_AUDIT,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            _default()
        );

        _submitExpectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, orderId, STAGE_AUDIT, STRANGER, _cand1()
            ),
            STAGE_AUDIT,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            STRANGER
        );

        _submit(STAGE_AUDIT, STAGE_AUDIT, SIGNAL_STAGE_DONE, _cand1());
        (,,,, address submitter) = machine.getSignal(planId, orderId, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(submitter == _cand1(), "patched executor submit not recorded");
    }

    function testRelayedPatchRejectsCrossPatchSelectorSignatureAndExpiredDeadline() public {
        UVPStagePatchModule.StageExecutorPatch memory signedPatch =
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 1);
        UVPStagePatchModule.StageExecutorPatch memory submittedPatch =
            _patch(STAGE_AUDIT, SUPPLIER_CAND2, bytes32(0), 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 signedDigest = stagePatch.stageExecutorPatchDigest(planId, orderId, signedPatch, _selector(), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELECTOR_PRIVATE_KEY, signedDigest);
        bytes32 submittedDigest =
            stagePatch.stageExecutorPatchDigest(planId, orderId, submittedPatch, _selector(), deadline);
        address expectedRecovered = ecrecover(submittedDigest, v, r, s);
        IUVPStateMachineCore.SelectorBindingProof memory selectorProof = _bindingProof(STAGE_AUDIT);
        bytes32[] memory submittedCandidateProof = _candidateProof(SUPPLIER_CAND2);
        bytes32[] memory signedCandidateProof = _candidateProof(SUPPLIER_CAND1);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, _selector(), expectedRecovered
            )
        );
        stagePatch.applyStageExecutorPatchFor(
            planId,
            orderId,
            submittedPatch,
            _selector(),
            deadline,
            abi.encodePacked(r, s, v),
            "",
            selectorProof,
            submittedCandidateProof
        );

        uint256 expiredDeadline = block.timestamp - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.ExpiredStageExecutorPatchSignature.selector, expiredDeadline
            )
        );
        stagePatch.applyStageExecutorPatchFor(
            planId,
            orderId,
            signedPatch,
            _selector(),
            expiredDeadline,
            "",
            "",
            selectorProof,
            signedCandidateProof
        );
    }

    function testPatchOnForkedOrderUsesReplayedStageCounts() public {
        _applyDirect(
            _patch(STAGE_AUDIT, SUPPLIER_CAND1, bytes32(0), 1),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND1)
        );
        _submit(STAGE_AUDIT, STAGE_AUDIT, SIGNAL_STAGE_DONE, _cand1());

        UVPStateMachine.ForkBirthFact[] memory facts = new UVPStateMachine.ForkBirthFact[](2);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_DONE, payloadHash: PAYLOAD_HASH, idempotencyKey: IDEMPOTENCY_KEY
        });
        facts[1] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_INIT_CMP,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY
        });
        vm.prank(CREATOR);
        bytes32 child = machine.forkOrder(
            planId, orderId, bytes32(uint256(0xF100)), STAGE_AUDIT, SIGNAL_STAGE_DONE, facts
        );
        (uint256 childCount, address childLast,,) = machine.stageSignalState(planId, child, STAGE_AUDIT);
        require(childCount == 1 && childLast == _cand1(), "replayed stage count wrong");

        _expectPatchRevertOn(
            child,
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, child, STAGE_AUDIT),
            _patch(STAGE_AUDIT, SUPPLIER_CAND2, bytes32(0), 1),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND2)
        );
        _expectPatchRevertOn(
            child,
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchPreviousSupplierMismatch.selector,
                child,
                STAGE_AUDIT,
                SUPPLIER_DEFAULT,
                SUPPLIER_CAND1
            ),
            _patch(STAGE_AUDIT, SUPPLIER_CAND2, SUPPLIER_CAND1, 2),
            _bindingProof(STAGE_AUDIT),
            _candidateProof(SUPPLIER_CAND2)
        );

        PreparedPatch memory handoff =
            _prepareFor(child, _patch(STAGE_AUDIT, SUPPLIER_CAND2, SUPPLIER_DEFAULT, 2));
        handoff.previousExecutorSignature =
            _signatureOver(DEFAULT_PRIVATE_KEY, _digestFor(child, handoff.patch, handoff.selector, handoff.deadline));
        _sendRelayedFor(child, handoff);
        (bytes32 supplierId,,) = machine.activeStageExecutorPatch(planId, child, STAGE_AUDIT);
        require(supplierId == SUPPLIER_CAND2, "fork child handoff failed");

        UVPStateMachine.FactAttribution memory reviewAttribution =
            _attribution(STAGE_AUDIT, STAGE_AUDIT, SIGNAL_STAGE_REVIEW);
        FilePatch memory noFilePatch = emptyFilePatch();
        vm.prank(_cand2());
        machine.submitSignal(
            planId,
            child,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH_2,
            IDEMPOTENCY_KEY_2,
            reviewAttribution,
            bytes32(0),
            noFilePatch
        );
    }

    function _deployStack() private {
        machine = new UVPStateMachine();
        suppliers = new UVPSupplierRegistry();
        metadata = new UVPPlanMetadataModule(address(machine));
        stagePatch = new UVPStagePatchModule(address(machine));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(machine));
        UVPDockRegistry dockRegistry = new UVPDockRegistry(address(machine));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(machine));
        files = new UVPFileResourceModule(address(machine));
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(derivedSignal));
        machine.setDockRegistry(address(dockRegistry));
        machine.setPlanMetadataModule(address(metadata));
        machine.setOrderLinkModule(address(orderLink));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
        machine.setFileResourceModule(address(files));
        machine.setSupplierRegistry(address(suppliers));
        machine.freezeModules();

        suppliers.registerSupplier(SUPPLIER_SELECTOR, _selector());
        suppliers.registerSupplier(SUPPLIER_DEFAULT, _default());
        suppliers.registerSupplier(SUPPLIER_FIXED, _fixed());
        suppliers.registerSupplier(SUPPLIER_CAND1, _cand1());
        suppliers.registerSupplier(SUPPLIER_CAND2, _cand2());
        suppliers.registerSupplier(SUPPLIER_CAND3, _cand3());
        suppliers.registerSupplier(SUPPLIER_DYN, _dyn());
    }

    function _commitAndBirth() private {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](4);
        hooks[0] = _hook(
            HOOK_BIRTH, STAGE_INIT, HOOK_NAME_BIRTH, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, SIGNAL_ORDER_START
        );
        hooks[1] = _hook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_AUDIT, FLAG_EMIT_READY, SIGNAL_INIT_CMP);
        hooks[2] = _hook(HOOK_FIXED, STAGE_FIXED, HOOK_NAME_FIXED, FLAG_EMIT_READY, SIGNAL_FIXED_READY);
        hooks[3] = _hook(
            HOOK_DYN, STAGE_DYN, HOOK_NAME_DYN, FLAG_EMIT_READY | FLAG_DYNAMIC_EXECUTOR, SIGNAL_DYN_READY
        );

        capabilityLeaves = new bytes32[](9);
        capabilityLeaves[0] = metadata.selectorBindingLeaf(STAGE_INIT, STAGE_AUDIT);
        capabilityLeaves[1] = metadata.selectorBindingLeaf(STAGE_INIT, STAGE_DYN);
        capabilityLeaves[2] = metadata.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, 0);
        capabilityLeaves[3] = metadata.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, 0);
        capabilityLeaves[4] = metadata.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_FIXED_READY, 0);
        capabilityLeaves[5] = metadata.signalCapabilityLeaf(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_DYN_READY, 0);
        capabilityLeaves[6] = metadata.signalCapabilityLeaf(STAGE_AUDIT, STAGE_AUDIT, SIGNAL_STAGE_DONE, 0);
        capabilityLeaves[7] = metadata.signalCapabilityLeaf(STAGE_AUDIT, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, 0);
        capabilityLeaves[8] = metadata.signalCapabilityLeaf(STAGE_DYN, SOURCE_DYN, SIGNAL_DYN, 0);

        UVPStateMachine.ExecutorBinding[] memory bindings = new UVPStateMachine.ExecutorBinding[](6);
        bindings[0] = UVPStateMachine.ExecutorBinding({stageId: STAGE_INIT, supplierId: SUPPLIER_SELECTOR, kind: 0});
        bindings[1] = UVPStateMachine.ExecutorBinding({stageId: STAGE_AUDIT, supplierId: SUPPLIER_DEFAULT, kind: 0});
        bindings[2] = UVPStateMachine.ExecutorBinding({stageId: STAGE_FIXED, supplierId: SUPPLIER_FIXED, kind: 0});
        bindings[3] = UVPStateMachine.ExecutorBinding({stageId: STAGE_AUDIT, supplierId: SUPPLIER_CAND1, kind: 1});
        bindings[4] = UVPStateMachine.ExecutorBinding({stageId: STAGE_AUDIT, supplierId: SUPPLIER_CAND2, kind: 1});
        bindings[5] = UVPStateMachine.ExecutorBinding({stageId: STAGE_AUDIT, supplierId: SUPPLIER_CAND3, kind: 1});
        bindingLeaves = new bytes32[](bindings.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            bindingLeaves[i] = keccak256(
                abi.encodePacked(
                    _EXECUTOR_BINDING_LEAF_DOMAIN, bindings[i].stageId, bindings[i].supplierId, bindings[i].kind
                )
            );
        }

        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: MerkleCommitment.root(capabilityLeaves),
            executorBindingsRoot: MerkleCommitment.root(bindingLeaves),
            birthAuthorizer: _selector(),
            deadline: block.timestamp + 1 hours
        });
        planId = machine.commitPlan(commit, hooks, bindings, _sign(PUBLISHER_PRIVATE_KEY, _planCommitDigest(commit)));
        machine.finalizePlan(planId);

        orderId = machine.triggerOrderIdFor(planId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            UVPStateMachine.TriggerOrderFromOutsideRequest({
                planId: planId,
                creator: CREATOR,
                triggerHookId: HOOK_BIRTH,
                triggerStageId: STAGE_INIT,
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_ORDER_START,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: IDEMPOTENCY_KEY,
                submitter: _selector(),
                deadline: block.timestamp + 1 hours
            });
        machine.triggerOrderFromOutsideFor(
            trigger,
            _sign(SELECTOR_PRIVATE_KEY, _triggerDigest(trigger)),
            _attribution(STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START)
        );

        _submit(SOURCE_BOOTSTRAP, STAGE_INIT, SIGNAL_INIT_CMP, _selector());
        _submit(SOURCE_BOOTSTRAP, STAGE_INIT, SIGNAL_FIXED_READY, _selector());
        _submit(SOURCE_BOOTSTRAP, STAGE_INIT, SIGNAL_DYN_READY, _selector());
        _requireHookReady(HOOK_AUDIT);
        _requireHookReady(HOOK_FIXED);
        _requireHookReady(HOOK_DYN);
    }

    function _requireHookReady(bytes32 hookId) private view {
        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(planId, orderId, hookId);
        require(status == UVPStateMachine.HookStatus.Ready && readyEmitted, "hook not ready");
    }

    function _patch(bytes32 targetStageId, bytes32 supplierId, bytes32 previousSupplierId, uint256 patchNonce)
        private
        pure
        returns (UVPStagePatchModule.StageExecutorPatch memory)
    {
        return UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: STAGE_INIT,
            targetStageId: targetStageId,
            supplierId: supplierId,
            previousSupplierId: previousSupplierId,
            patchNonce: patchNonce
        });
    }

    function _applyDirect(
        UVPStagePatchModule.StageExecutorPatch memory patch,
        IUVPStateMachineCore.SelectorBindingProof memory bindingProof,
        bytes32[] memory candidateProof
    ) private {
        vm.prank(_selector());
        stagePatch.applyStageExecutorPatch(planId, orderId, patch, bindingProof, candidateProof);
    }

    function _expectPatchRevert(
        bytes memory revertData,
        UVPStagePatchModule.StageExecutorPatch memory patch,
        IUVPStateMachineCore.SelectorBindingProof memory bindingProof,
        bytes32[] memory candidateProof
    ) private {
        _expectPatchRevertOn(orderId, revertData, patch, bindingProof, candidateProof);
    }

    function _expectPatchRevertOn(
        bytes32 targetOrderId,
        bytes memory revertData,
        UVPStagePatchModule.StageExecutorPatch memory patch,
        IUVPStateMachineCore.SelectorBindingProof memory bindingProof,
        bytes32[] memory candidateProof
    ) private {
        vm.prank(_selector());
        vm.expectRevert(revertData);
        stagePatch.applyStageExecutorPatch(planId, targetOrderId, patch, bindingProof, candidateProof);
    }

    function _prepare(UVPStagePatchModule.StageExecutorPatch memory patch)
        private
        returns (PreparedPatch memory prepared)
    {
        prepared = _prepareFor(orderId, patch);
    }

    function _prepareFor(bytes32 targetOrderId, UVPStagePatchModule.StageExecutorPatch memory patch)
        private
        returns (PreparedPatch memory prepared)
    {
        prepared.patch = patch;
        prepared.selector = _selector();
        prepared.deadline = block.timestamp + 1 hours;
        prepared.bindingProof = _bindingProof(patch.targetStageId);
        prepared.candidateProof = _candidateProof(patch.supplierId);
        prepared.selectorSignature =
            _signatureOver(SELECTOR_PRIVATE_KEY, _digestFor(targetOrderId, patch, _selector(), prepared.deadline));
    }

    function _prepareWithSelector(
        UVPStagePatchModule.StageExecutorPatch memory patch,
        address selector,
        uint256 selectorPrivateKey
    ) private returns (PreparedPatch memory prepared) {
        prepared = _prepare(patch);
        prepared.selector = selector;
        prepared.selectorSignature = _signatureOver(selectorPrivateKey, _digestFor(orderId, patch, selector, prepared.deadline));
    }

    function _digestFor(
        bytes32 targetOrderId,
        UVPStagePatchModule.StageExecutorPatch memory patch,
        address selector,
        uint256 deadline
    ) private view returns (bytes32) {
        return stagePatch.stageExecutorPatchDigest(planId, targetOrderId, patch, selector, deadline);
    }

    function _sendRelayed(PreparedPatch memory prepared) private {
        _sendRelayedFor(orderId, prepared);
    }

    function _sendRelayedFor(bytes32 targetOrderId, PreparedPatch memory prepared) private {
        stagePatch.applyStageExecutorPatchFor(
            planId,
            targetOrderId,
            prepared.patch,
            prepared.selector,
            prepared.deadline,
            prepared.selectorSignature,
            prepared.previousExecutorSignature,
            prepared.bindingProof,
            prepared.candidateProof
        );
    }

    function _submit(bytes32 sourceId, bytes32 factStageId, bytes32 signalId, address submitter) private {
        UVPStateMachine.FactAttribution memory attribution = _attribution(factStageId, sourceId, signalId);
        FilePatch memory noFilePatch = emptyFilePatch();
        vm.prank(submitter);
        machine.submitSignal(
            planId, orderId, sourceId, signalId, PAYLOAD_HASH, IDEMPOTENCY_KEY, attribution, bytes32(0), noFilePatch
        );
    }

    function _submitExpectRevert(
        bytes memory revertData,
        bytes32 sourceId,
        bytes32 factStageId,
        bytes32 signalId,
        address submitter
    ) private {
        UVPStateMachine.FactAttribution memory attribution = _attribution(factStageId, sourceId, signalId);
        FilePatch memory noFilePatch = emptyFilePatch();
        vm.expectRevert(revertData);
        vm.prank(submitter);
        machine.submitSignal(
            planId, orderId, sourceId, signalId, PAYLOAD_HASH, IDEMPOTENCY_KEY, attribution, bytes32(0), noFilePatch
        );
    }

    function _attribution(bytes32 stageId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (UVPStateMachine.FactAttribution memory)
    {
        bytes32 leaf = metadata.signalCapabilityLeaf(stageId, sourceId, signalId, 0);
        return UVPStateMachine.FactAttribution({
            sourceId: sourceId,
            signalId: signalId,
            stageId: stageId,
            capabilityProof: _proofFrom(capabilityLeaves, leaf)
        });
    }

    function _bindingProof(bytes32 targetStageId)
        private
        view
        returns (IUVPStateMachineCore.SelectorBindingProof memory)
    {
        bytes32 leaf = metadata.selectorBindingLeaf(STAGE_INIT, targetStageId);
        return IUVPStateMachineCore.SelectorBindingProof({
            selectorStageId: STAGE_INIT,
            proof: _proofFrom(capabilityLeaves, leaf)
        });
    }

    function _candidateProof(bytes32 supplierId) private view returns (bytes32[] memory) {
        bytes32 leaf = keccak256(
            abi.encodePacked(_EXECUTOR_BINDING_LEAF_DOMAIN, STAGE_AUDIT, supplierId, uint8(1))
        );
        for (uint256 i = 0; i < bindingLeaves.length; i++) {
            if (bindingLeaves[i] == leaf) {
                return _proofFrom(bindingLeaves, leaf);
            }
        }
        return new bytes32[](0);
    }

    function _proofFrom(bytes32[] memory rawLeaves, bytes32 leaf) private pure returns (bytes32[] memory) {
        bytes32[] memory sorted = _sortedUnique(rawLeaves);
        return _merkleProofFor(sorted, leaf);
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
                        commit.executorBindingsRoot,
                        commit.birthAuthorizer,
                        commit.deadline
                    )
                )
            )
        );
    }

    function _triggerDigest(UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                machine.DOMAIN_SEPARATOR(),
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
                        trigger.submitter,
                        trigger.deadline
                    )
                )
            )
        );
    }

    function _signatureOver(uint256 privateKey, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _sign(uint256 privateKey, bytes32 digest) private returns (bytes memory) {
        return _signatureOver(privateKey, digest);
    }

    function _selector() private view returns (address) {
        return vm.addr(SELECTOR_PRIVATE_KEY);
    }

    function _default() private view returns (address) {
        return vm.addr(DEFAULT_PRIVATE_KEY);
    }

    function _fixed() private view returns (address) {
        return vm.addr(FIXED_PRIVATE_KEY);
    }

    function _cand1() private view returns (address) {
        return vm.addr(CAND1_PRIVATE_KEY);
    }

    function _cand2() private view returns (address) {
        return vm.addr(CAND2_PRIVATE_KEY);
    }

    function _cand3() private view returns (address) {
        return vm.addr(CAND3_PRIVATE_KEY);
    }

    function _dyn() private view returns (address) {
        return vm.addr(DYN_PRIVATE_KEY);
    }

    function _cand1Static() private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(uint256(CAND1_PRIVATE_KEY))))));
    }

    function _cand2Static() private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(uint256(CAND2_PRIVATE_KEY))))));
    }

    function _defaultStatic() private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(uint256(DEFAULT_PRIVATE_KEY))))));
    }

    function _dynStatic() private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(uint256(DYN_PRIVATE_KEY))))));
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
