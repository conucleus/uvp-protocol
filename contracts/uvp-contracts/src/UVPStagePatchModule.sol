// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPFileResourceModule} from "./interfaces/IUVPFileResourceModule.sol";
import {IUVPDockRegistry} from "./interfaces/IUVPDockRegistry.sol";
import {IUVPIdentityRegistry} from "./interfaces/IUVPIdentityRegistry.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {MerkleCommitment} from "./libraries/MerkleCommitment.sol";
import {AdmissionVerdict, _SUPPLIER_BINDING_LEAF_DOMAIN} from "./UVPStateMachineConstants.sol";

interface IUVPPlanMetadataModuleForStagePatch {
    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool);
}

contract UVPStagePatchModule {
    string private constant _DOCK_PAYLOAD_FILE_KEY_NAME = "dock_link";
    bytes32 private constant _DOCK_PAYLOAD_FILE_KEY = keccak256("dock_link");
    bytes32 private constant _DOCK_BINDING_ID_DOMAIN = keccak256("uvp.dock.binding_id.v1");
    uint8 private constant _SUPPLIER_BINDING_KIND_CANDIDATE = 1;

    struct StageSupplierPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 supplierId;
        bytes32 previousSupplierId;
        uint256 patchNonce;
    }

    struct StageDockSupplierSelection {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 dockId;
        bytes32 supplierId;
        uint256 patchNonce;
    }

    struct DockBindingContext {
        bytes32 planId;
        bytes32 orderId;
        bytes32 targetStageId;
        bytes32 fromPlanId;
        bytes32 fromOrderId;
        bytes32 toSourceId;
        bytes32 bindingId;
        bytes32 supplierId;
        address supplierAccount;
    }

    error DockBindingContentHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error DockBindingFromOrderMismatch(bytes32 expectedOrderId, bytes32 providedOrderId);
    error DockBindingFromOrderUnknown(bytes32 planId, bytes32 orderId);
    error DockBindingNotSelected(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error DockBindingPayloadMissing(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error DockIdMismatch(bytes32 dockId, bytes32 docHash);
    error DockOrderPlanMismatch(bytes32 expectedPlanId, bytes32 providedPlanId);
    error DockOutputProofCountMismatch(uint256 expectedCount, uint256 providedCount);
    error DockPayloadMalformed(uint256 length);
    error DockStageMismatch(bytes32 expectedStageId, bytes32 providedStageId);
    error DockStageNotDockExecutor(bytes32 planId, bytes32 stageId);
    error DockUnknown(bytes32 dkid);
    error ExpiredStageSupplierPatchSignature(uint256 deadline);
    error InvalidStageSupplierPatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageSupplierPatchSignatureLength(uint256 length);
    error StageAlreadyHasSignal(bytes32 orderId, bytes32 targetStageId);
    error StageDockSupplierAlreadySelected(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error StageSupplierNotCandidate(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 supplierId);
    error StageSupplierPatchForbiddenOnBirthStage(bytes32 orderId, bytes32 targetStageId);
    error StageSupplierPatchForbiddenOnDockStage(bytes32 orderId, bytes32 targetStageId);
    error StageSupplierPatchForbiddenOnFixedStage(bytes32 orderId, bytes32 targetStageId);
    error StageSupplierPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error StageSupplierPatchPreviousSupplierMismatch(
        bytes32 orderId, bytes32 targetStageId, bytes32 expectedSupplierId, bytes32 previousSupplierId
    );
    error SupplierNotActive(bytes32 supplierId);
    error UnauthorizedStageSupplierPatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnknownOrder();
    error UnknownStage(bytes32 planId, bytes32 stageId);
    error ZeroDockId();
    error ZeroSelector();
    error ZeroSelectorStageId();
    error ZeroStageSupplier();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    bytes32 public constant DOCK_PAYLOAD_FILE_KEY = _DOCK_PAYLOAD_FILE_KEY;
    bytes32 public constant DOCK_BINDING_ID_DOMAIN = _DOCK_BINDING_ID_DOMAIN;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStagePatchModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 private constant _STAGE_SUPPLIER_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageSupplierPatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 supplierId,bytes32 previousSupplierId,uint256 patchNonce,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_DOCK_SUPPLIER_SELECTION_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageDockSupplierSelection(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 dockId,bytes32 supplierId,uint256 patchNonce,address selector,uint256 deadline)"
    );

    event StageSupplierPatchApplied(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 targetStageId,
        address selector,
        bytes32 supplierId,
        bytes32 previousSupplierId,
        uint256 patchNonce
    );
    event StageDockSupplierSelected(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 dockId,
        bytes32 supplierId,
        uint256 patchNonce
    );
    event DockBindingPoked(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 dockId,
        bytes32 bindingId,
        bytes32 fromPlanId,
        bytes32 fromOrderId,
        bytes32 supplierId,
        uint256 emittedCount
    );
    event DockOutputDeferred(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed bindingId,
        uint256 outputIndex,
        bytes32 signalId,
        uint8 verdict,
        uint64 dueAt
    );
    event DockOutputSubmitted(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 bindingId,
        uint256 outputIndex,
        bytes32 signalId,
        bytes32 supplierId
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function applyStageSupplierPatch(
        bytes32 planId,
        bytes32 orderId,
        StageSupplierPatch calldata patch,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) external {
        _applyStageSupplierPatch(planId, orderId, patch, msg.sender, address(0), bindingProof, candidateProof);
    }

    function applyStageSupplierPatchFor(
        bytes32 planId,
        bytes32 orderId,
        StageSupplierPatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        bytes calldata previousSupplierSignature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageSupplierPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        bytes32 digest = stageSupplierPatchDigest(planId, orderId, patch, selector, deadline);
        address recoveredSigner = _recoverStageSupplierPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageSupplierPatchSignature(selector, recoveredSigner);
        }

        address recoveredPreviousSupplier;
        if (previousSupplierSignature.length != 0) {
            recoveredPreviousSupplier = _recoverStageSupplierPatchSigner(digest, previousSupplierSignature);
        }

        _applyStageSupplierPatch(
            planId, orderId, patch, selector, recoveredPreviousSupplier, bindingProof, candidateProof
        );
    }

    function selectStageDockSupplier(
        bytes32 planId,
        bytes32 orderId,
        StageDockSupplierSelection calldata selection,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) external {
        _selectStageDockSupplier(planId, orderId, selection, msg.sender, bindingProof);
    }

    function selectStageDockSupplierFor(
        bytes32 planId,
        bytes32 orderId,
        StageDockSupplierSelection calldata selection,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageSupplierPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        bytes32 digest = stageDockSupplierSelectionDigest(planId, orderId, selection, selector, deadline);
        address recoveredSigner = _recoverStageSupplierPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageSupplierPatchSignature(selector, recoveredSigner);
        }
        _selectStageDockSupplier(planId, orderId, selection, selector, bindingProof);
    }

    function pokeDockBinding(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes calldata payloadContent,
        bytes32 fromOrderId,
        bytes32[][] calldata outputCapabilityProofs
    ) external returns (uint256 emittedCount) {
        (bytes32 supplierId,, bytes32 dockId) = stateMachine.stageSupplierAssignment(planId, orderId, targetStageId);
        if (supplierId == bytes32(0) || dockId == bytes32(0)) {
            revert DockBindingNotSelected(planId, orderId, targetStageId);
        }
        IUVPDockRegistry registry = _dockRegistry();
        (bytes32 fromPlanId,, bytes32 toSourceId,,, bool dockExists) = _dockFields(dockId);
        if (!dockExists) {
            revert DockUnknown(dockId);
        }
        address supplierAccount = stateMachine.effectiveStageAccount(planId, orderId, targetStageId);
        DockBindingContext memory context = _dockBindingContext(
            planId,
            orderId,
            targetStageId,
            fromPlanId,
            dockId,
            toSourceId,
            supplierId,
            supplierAccount,
            payloadContent,
            fromOrderId
        );
        uint256 outputCount = registry.dockOutputCount(dockId);
        if (outputCapabilityProofs.length != outputCount) {
            revert DockOutputProofCountMismatch(outputCount, outputCapabilityProofs.length);
        }
        for (uint256 i = 0; i < outputCount; i++) {
            if (_emitDockOutput(dockId, context, registry, i, outputCapabilityProofs[i])) {
                emittedCount += 1;
            }
        }
        emit DockBindingPoked(
            planId,
            orderId,
            targetStageId,
            dockId,
            context.bindingId,
            fromPlanId,
            fromOrderId,
            supplierId,
            emittedCount
        );
    }

    function getStageDockBinding(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId
    )
        external
        view
        returns (
            bool selected,
            bool current,
            bytes32 dockId,
            bytes32 supplierId,
            address supplierAccount,
            bytes32 fromPlanId,
            bytes32 bindingId
        )
    {
        (supplierId,, dockId) = stateMachine.stageSupplierAssignment(planId, orderId, targetStageId);
        selected = supplierId != bytes32(0) && dockId != bytes32(0);
        if (!selected) {
            return (false, false, bytes32(0), bytes32(0), address(0), bytes32(0), bytes32(0));
        }
        (bytes32 dockFromPlanId,,, bytes32 dockToStageId,, bool dockExists) = _dockFields(dockId);
        fromPlanId = dockFromPlanId;
        if (!dockExists || dockToStageId != targetStageId) {
            return (false, false, bytes32(0), bytes32(0), address(0), bytes32(0), bytes32(0));
        }
        supplierAccount = stateMachine.effectiveStageAccount(planId, orderId, targetStageId);
        (bool payloadExists,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY_NAME);
        current = payloadExists && fromOrderId != bytes32(0);
        if (!current) {
            return (true, false, dockId, supplierId, supplierAccount, fromPlanId, bytes32(0));
        }
        bindingId = keccak256(
            abi.encode(_DOCK_BINDING_ID_DOMAIN, dockId, planId, orderId, targetStageId, fromPlanId, fromOrderId)
        );
    }

    function dockOutputWindow(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId,
        uint256 outputIndex
    )
        external
        view
        returns (bool current, bool aSatisfied, uint64 aDueInSeconds, bool bSatisfied, bool emitted)
    {
        (bytes32 supplierId,, bytes32 dockId) = stateMachine.stageSupplierAssignment(planId, orderId, targetStageId);
        if (supplierId == bytes32(0) || dockId == bytes32(0)) {
            return (false, false, 0, false, false);
        }
        (bytes32 fromPlanId,, bytes32 toSourceId, bytes32 toStageId,, bool dockExists) = _dockFields(dockId);
        if (!dockExists || toStageId != targetStageId) {
            return (false, false, 0, false, false);
        }
        IUVPDockRegistry registry = _dockRegistry();
        (bool payloadExists,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY_NAME);
        current = payloadExists && fromOrderId != bytes32(0);
        if (outputIndex >= registry.dockOutputCount(dockId)) {
            return (current, false, 0, false, false);
        }
        (bytes32 signalId,,, IUVPStateMachineCore.WindowInstruction[] memory window) =
            registry.getDockOutput(dockId, outputIndex);
        (aSatisfied, aDueInSeconds) = stateMachine.evaluateDockWindow(fromPlanId, fromOrderId, window);
        (AdmissionVerdict bVerdict,) = stateMachine.signalAdmissionVerdict(planId, orderId, toSourceId, signalId);
        bSatisfied = bVerdict == AdmissionVerdict.Ready;
        emitted = stateMachine.hasSignal(planId, orderId, toSourceId, signalId);
    }

    function dockOutputAdmissionVerdict(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        uint256 outputIndex
    ) external view returns (AdmissionVerdict verdict, uint64 dueAt) {
        (bytes32 supplierId,, bytes32 dockId) = stateMachine.stageSupplierAssignment(planId, orderId, targetStageId);
        if (supplierId == bytes32(0) || dockId == bytes32(0)) {
            return (AdmissionVerdict.Wait, 0);
        }
        (, , bytes32 toSourceId, bytes32 toStageId, , bool dockExists) = _dockFields(dockId);
        if (!dockExists || toStageId != targetStageId) {
            return (AdmissionVerdict.Impossible, 0);
        }
        IUVPDockRegistry registry = _dockRegistry();
        if (outputIndex >= registry.dockOutputCount(dockId)) {
            return (AdmissionVerdict.Impossible, 0);
        }
        (bytes32 signalId,,,) = registry.getDockOutput(dockId, outputIndex);
        return stateMachine.signalAdmissionVerdict(planId, orderId, toSourceId, signalId);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function stageSupplierPatchDigest(
        bytes32 planId,
        bytes32 orderId,
        StageSupplierPatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _STAGE_SUPPLIER_PATCH_TYPEHASH,
                        planId,
                        orderId,
                        patch.selectorStageId,
                        patch.targetStageId,
                        patch.supplierId,
                        patch.previousSupplierId,
                        patch.patchNonce,
                        selector,
                        deadline
                    )
                )
            )
        );
    }

    function stageDockSupplierSelectionDigest(
        bytes32 planId,
        bytes32 orderId,
        StageDockSupplierSelection calldata selection,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _STAGE_DOCK_SUPPLIER_SELECTION_TYPEHASH,
                        planId,
                        orderId,
                        selection.selectorStageId,
                        selection.targetStageId,
                        selection.dockId,
                        selection.supplierId,
                        selection.patchNonce,
                        selector,
                        deadline
                    )
                )
            )
        );
    }

    function _applyStageSupplierPatch(
        bytes32 planId,
        bytes32 orderId,
        StageSupplierPatch calldata patch,
        address selector,
        address previousSupplierSigner,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) private {
        _validateStageSupplierPatch(planId, orderId, patch, selector, bindingProof, candidateProof);

        (, uint256 currentNonce,) = stateMachine.stageSupplierAssignment(planId, orderId, patch.targetStageId);
        if (patch.patchNonce <= currentNonce) {
            revert StageSupplierPatchNonceNotIncreasing(
                orderId, patch.targetStageId, currentNonce, patch.patchNonce
            );
        }
        _validateStageSupplierPatchTransition(planId, orderId, patch, previousSupplierSigner);

        stateMachine.activateStageSupplierFromModule(
            planId, orderId, patch.targetStageId, patch.supplierId, patch.patchNonce
        );
        emit StageSupplierPatchApplied(
            planId,
            orderId,
            patch.selectorStageId,
            patch.targetStageId,
            selector,
            patch.supplierId,
            patch.previousSupplierId,
            patch.patchNonce
        );
    }

    function _selectStageDockSupplier(
        bytes32 planId,
        bytes32 orderId,
        StageDockSupplierSelection calldata selection,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) private {
        _validateStageDockSelection(planId, orderId, selection, selector, bindingProof);

        (bytes32 activeSupplierId, uint256 activeNonce, bytes32 activeDockId) =
            stateMachine.stageSupplierAssignment(planId, orderId, selection.targetStageId);
        if (activeDockId == selection.dockId && activeSupplierId == selection.supplierId) {
            return;
        }
        if (activeDockId != bytes32(0) || activeSupplierId != bytes32(0)) {
            revert StageDockSupplierAlreadySelected(planId, orderId, selection.targetStageId);
        }
        if (selection.patchNonce <= activeNonce) {
            revert StageSupplierPatchNonceNotIncreasing(
                orderId, selection.targetStageId, activeNonce, selection.patchNonce
            );
        }
        stateMachine.activateStageDockSupplierFromModule(
            planId, orderId, selection.targetStageId, selection.supplierId, selection.dockId, selection.patchNonce
        );
        emit StageDockSupplierSelected(
            planId,
            orderId,
            selection.targetStageId,
            selection.dockId,
            selection.supplierId,
            selection.patchNonce
        );
    }

    function _validateStageSupplierPatch(
        bytes32 planId,
        bytes32 orderId,
        StageSupplierPatch calldata patch,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) private view {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.supplierId == bytes32(0)) {
            revert ZeroStageSupplier();
        }
        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.isPlanStage(planId, patch.targetStageId)) {
            revert UnknownStage(planId, patch.targetStageId);
        }
        if (stateMachine.stageHasOrderTriggerHook(planId, patch.targetStageId)) {
            revert StageSupplierPatchForbiddenOnBirthStage(orderId, patch.targetStageId);
        }
        if (stateMachine.stageHasDockExecutorHook(planId, patch.targetStageId)) {
            revert StageSupplierPatchForbiddenOnDockStage(orderId, patch.targetStageId);
        }
        if (!stateMachine.planStageHasDynamicSupplier(planId, patch.targetStageId)) {
            if (stateMachine.planStageIsCandidate(planId, patch.targetStageId)) {
                bytes32 leaf = keccak256(
                    abi.encodePacked(
                        _SUPPLIER_BINDING_LEAF_DOMAIN,
                        patch.targetStageId,
                        patch.supplierId,
                        _SUPPLIER_BINDING_KIND_CANDIDATE
                    )
                );
                bytes32 bindingsRoot = stateMachine.planSupplierBindingsRoot(planId);
                if (
                    bindingsRoot == bytes32(0) || bindingsRoot == MerkleCommitment.EMPTY_ROOT
                        || !MerkleCommitment.verify(bindingsRoot, leaf, candidateProof)
                ) {
                    revert StageSupplierNotCandidate(planId, orderId, patch.targetStageId, patch.supplierId);
                }
            } else {
                revert StageSupplierPatchForbiddenOnFixedStage(orderId, patch.targetStageId);
            }
        }
        if (
            bindingProof.selectorStageId != patch.selectorStageId
                || !_planMetadata()
                    .verifyStageSelectorBinding(planId, patch.selectorStageId, patch.targetStageId, bindingProof.proof)
        ) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!stateMachine.isEffectiveStageAccount(planId, orderId, patch.selectorStageId, selector)) {
            revert UnauthorizedStageSupplierPatchSelector(orderId, patch.selectorStageId, selector);
        }
        if (!_identityRegistry().isActiveSupplier(patch.supplierId)) {
            revert SupplierNotActive(patch.supplierId);
        }
    }

    function _validateStageSupplierPatchTransition(
        bytes32 planId,
        bytes32 orderId,
        StageSupplierPatch calldata patch,
        address previousSupplierSigner
    ) private view {
        (uint256 signalCount,,,) = stateMachine.stageSignalState(planId, orderId, patch.targetStageId);
        if (patch.previousSupplierId == bytes32(0)) {
            if (signalCount != 0) {
                revert StageAlreadyHasSignal(orderId, patch.targetStageId);
            }
            if (previousSupplierSigner != address(0)) {
                revert InvalidStageSupplierPatchSignature(address(0), previousSupplierSigner);
            }
            return;
        }

        if (signalCount == 0) {
            revert StageHasNoSignal(orderId, patch.targetStageId);
        }
        bytes32 effectiveSupplierId = stateMachine.effectiveStageSupplier(planId, orderId, patch.targetStageId);
        if (effectiveSupplierId != patch.previousSupplierId) {
            revert StageSupplierPatchPreviousSupplierMismatch(
                orderId, patch.targetStageId, effectiveSupplierId, patch.previousSupplierId
            );
        }
        address previousSupplierAccount = _identityRegistry().accountOf(patch.previousSupplierId);
        if (previousSupplierSigner != previousSupplierAccount) {
            revert InvalidStageSupplierPatchSignature(previousSupplierAccount, previousSupplierSigner);
        }
    }

    function _validateStageDockSelection(
        bytes32 planId,
        bytes32 orderId,
        StageDockSupplierSelection calldata selection,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) private view {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (selection.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (selection.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (selection.dockId == bytes32(0)) {
            revert ZeroDockId();
        }
        if (selection.supplierId == bytes32(0)) {
            revert ZeroStageSupplier();
        }
        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.isPlanStage(planId, selection.targetStageId)) {
            revert UnknownStage(planId, selection.targetStageId);
        }
        if (!stateMachine.stageHasDockExecutorHook(planId, selection.targetStageId)) {
            revert DockStageNotDockExecutor(planId, selection.targetStageId);
        }
        (, bytes32 toPlanId,, bytes32 toStageId,, bool exists) = _dockFields(selection.dockId);
        if (!exists) {
            revert DockUnknown(selection.dockId);
        }
        if (toPlanId != planId) {
            revert DockOrderPlanMismatch(planId, toPlanId);
        }
        if (toStageId != selection.targetStageId) {
            revert DockStageMismatch(selection.targetStageId, toStageId);
        }
        if (
            bindingProof.selectorStageId != selection.selectorStageId
                || !_planMetadata().verifyStageSelectorBinding(
                    planId, selection.selectorStageId, selection.targetStageId, bindingProof.proof
                )
        ) {
            revert StageSelectorBindingNotFound(planId, selection.selectorStageId, selection.targetStageId);
        }
        if (!stateMachine.isEffectiveStageAccount(planId, orderId, selection.selectorStageId, selector)) {
            revert UnauthorizedStageSupplierPatchSelector(orderId, selection.selectorStageId, selector);
        }
        if (!_identityRegistry().isActiveSupplier(selection.supplierId)) {
            revert SupplierNotActive(selection.supplierId);
        }
    }

    function _dockBindingContext(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromPlanId,
        bytes32 dockId,
        bytes32 toSourceId,
        bytes32 supplierId,
        address supplierAccount,
        bytes calldata payloadContent,
        bytes32 fromOrderId
    ) private view returns (DockBindingContext memory context) {
        if (!stateMachine.orderExists(fromPlanId, fromOrderId)) {
            revert DockBindingFromOrderUnknown(fromPlanId, fromOrderId);
        }
        (bool payloadExists, bytes memory storedPayload) =
            IUVPFileResourceModule(stateMachine.fileResourceModule())
                .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY_NAME);
        if (!payloadExists) {
            revert DockBindingPayloadMissing(planId, orderId, targetStageId);
        }
        bytes32 storedContentHash = keccak256(storedPayload);
        bytes32 actualContentHash = keccak256(payloadContent);
        if (actualContentHash != storedContentHash) {
            revert DockBindingContentHashMismatch(storedContentHash, actualContentHash);
        }
        bytes32 parsedFromOrderId = _parseDockPayload(payloadContent);
        if (parsedFromOrderId != fromOrderId) {
            revert DockBindingFromOrderMismatch(fromOrderId, parsedFromOrderId);
        }
        context = DockBindingContext({
            planId: planId,
            orderId: orderId,
            targetStageId: targetStageId,
            fromPlanId: fromPlanId,
            fromOrderId: fromOrderId,
            toSourceId: toSourceId,
            bindingId: keccak256(
                abi.encode(_DOCK_BINDING_ID_DOMAIN, dockId, planId, orderId, targetStageId, fromPlanId, fromOrderId)
            ),
            supplierId: supplierId,
            supplierAccount: supplierAccount
        });
    }

    function _emitDockOutput(
        bytes32 dockId,
        DockBindingContext memory context,
        IUVPDockRegistry registry,
        uint256 outputIndex,
        bytes32[] calldata capabilityProof
    ) private returns (bool submitted) {
        (bytes32 signalId,,, IUVPStateMachineCore.WindowInstruction[] memory window) =
            registry.getDockOutput(dockId, outputIndex);
        (bool aSatisfied,) = stateMachine.evaluateDockWindow(context.fromPlanId, context.fromOrderId, window);
        if (!aSatisfied) {
            return false;
        }
        if (stateMachine.hasSignal(context.planId, context.orderId, context.toSourceId, signalId)) {
            return false;
        }
        (AdmissionVerdict bVerdict, uint64 bDueAt) =
            stateMachine.signalAdmissionVerdict(context.planId, context.orderId, context.toSourceId, signalId);
        if (bVerdict != AdmissionVerdict.Ready) {
            emit DockOutputDeferred(
                context.planId,
                context.orderId,
                context.bindingId,
                outputIndex,
                signalId,
                uint8(bVerdict),
                bDueAt
            );
            return false;
        }
        IUVPStateMachineCore.FactAttribution memory attribution = IUVPStateMachineCore.FactAttribution({
            sourceId: context.toSourceId,
            signalId: signalId,
            stageId: context.targetStageId,
            capabilityProof: capabilityProof
        });
        submitted = stateMachine.submitDockOutputSignalFromModule(
            context.planId,
            context.orderId,
            context.toSourceId,
            signalId,
            context.bindingId,
            keccak256(abi.encode(_DOCK_BINDING_ID_DOMAIN, context.bindingId, signalId)),
            context.supplierAccount,
            attribution
        );
        if (submitted) {
            emit DockOutputSubmitted(
                context.planId,
                context.orderId,
                context.targetStageId,
                context.bindingId,
                outputIndex,
                signalId,
                context.supplierId
            );
        }
    }

    function _parseDockPayload(bytes calldata payload) private pure returns (bytes32 orderId) {
        uint256 length = payload.length;
        if (length != 66) {
            revert DockPayloadMalformed(length);
        }
        if (uint8(payload[0]) != 0x30 || uint8(payload[1]) != 0x78) {
            revert DockPayloadMalformed(length);
        }
        uint256 value;
        for (uint256 i = 2; i < 66; i++) {
            uint8 character = uint8(payload[i]);
            uint8 digit;
            if (character >= 0x30 && character <= 0x39) {
                digit = character - 0x30;
            } else if (character >= 0x61 && character <= 0x66) {
                digit = character - 0x57;
            } else {
                revert DockPayloadMalformed(length);
            }
            value = (value << 4) | digit;
        }
        return bytes32(value);
    }

    function _dockFields(bytes32 dockId)
        private
        view
        returns (
            bytes32 fromPlanId,
            bytes32 toPlanId,
            bytes32 toSourceId,
            bytes32 toStageId,
            bytes32 docHash,
            bool exists
        )
    {
        (fromPlanId, , toPlanId, toStageId, toSourceId, docHash, , exists) = _dockRegistry().getDock(dockId);
        if (exists && dockId != bytes32(bytes16(docHash))) {
            revert DockIdMismatch(dockId, docHash);
        }
    }

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForStagePatch) {
        return IUVPPlanMetadataModuleForStagePatch(stateMachine.planMetadataModule());
    }

    function _dockRegistry() private view returns (IUVPDockRegistry) {
        return IUVPDockRegistry(stateMachine.dockRegistry());
    }

    function _identityRegistry() private view returns (IUVPIdentityRegistry) {
        return IUVPIdentityRegistry(stateMachine.identityRegistry());
    }

    function _recoverStageSupplierPatchSigner(bytes32 digest, bytes calldata signature)
        private
        pure
        returns (address)
    {
        if (signature.length != 65) {
            revert InvalidStageSupplierPatchSignatureLength(signature.length);
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
}
