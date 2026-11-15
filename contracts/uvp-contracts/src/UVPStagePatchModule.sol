// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPFileResourceModule} from "./interfaces/IUVPFileResourceModule.sol";
import {IUVPDockRegistry} from "./interfaces/IUVPDockRegistry.sol";
import {IUVPSupplierRegistry} from "./interfaces/IUVPSupplierRegistry.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {MerkleCommitment} from "./libraries/MerkleCommitment.sol";
import {_EXECUTOR_BINDING_LEAF_DOMAIN} from "./UVPStateMachineConstants.sol";

interface IUVPPlanMetadataModuleForStagePatch {
    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool);
}

contract UVPStagePatchModule {
    bytes32 private constant _DOCK_PAYLOAD_FILE_KEY = keccak256("dock_link");
    bytes32 private constant _DOCK_BINDING_ID_DOMAIN = keccak256("uvp.dock.binding_id.v1");
    uint8 private constant _EXECUTOR_BINDING_KIND_CANDIDATE = 1;

    struct StageExecutorPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 supplierId;
        bytes32 previousSupplierId;
        uint256 patchNonce;
    }

    struct StageDockExecutorSelection {
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
        address executor;
    }

    error DockBindingContentHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error DockBindingFromOrderMismatch(bytes32 expectedOrderId, bytes32 providedOrderId);
    error DockBindingFromOrderUnknown(bytes32 planId, bytes32 orderId);
    error DockBindingNotSelected(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error DockBindingPayloadMissing(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error DockOrderPlanMismatch(bytes32 expectedPlanId, bytes32 providedPlanId);
    error DockOutputProofCountMismatch(uint256 expectedCount, uint256 providedCount);
    error DockPayloadMalformed(uint256 length);
    error DockStageMismatch(bytes32 expectedStageId, bytes32 providedStageId);
    error DockStageNotDockExecutor(bytes32 planId, bytes32 stageId);
    error DockUnknown(bytes32 dkid);
    error ExpiredStageExecutorPatchSignature(uint256 deadline);
    error InvalidStageExecutorPatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageExecutorPatchSignatureLength(uint256 length);
    error StageAlreadyHasSignal(bytes32 orderId, bytes32 targetStageId);
    error StageDockExecutorAlreadySelected(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error StageExecutorNotCandidate(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 supplierId);
    error StageExecutorPatchForbiddenOnBirthStage(bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchForbiddenOnDockStage(bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchForbiddenOnFixedStage(bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error StageExecutorPatchPreviousSupplierMismatch(
        bytes32 orderId, bytes32 targetStageId, bytes32 expectedSupplierId, bytes32 previousSupplierId
    );
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error SupplierNotRegistered(bytes32 supplierId);
    error UnauthorizedStageExecutorPatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
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
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.5");
    bytes32 private constant _STAGE_EXECUTOR_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 supplierId,bytes32 previousSupplierId,uint256 patchNonce,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_DOCK_EXECUTOR_SELECTION_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageDockExecutorSelection(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 dockId,bytes32 supplierId,uint256 patchNonce,address selector,uint256 deadline)"
    );

    event StageExecutorPatchApplied(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 targetStageId,
        address selector,
        bytes32 supplierId,
        bytes32 previousSupplierId,
        uint256 patchNonce
    );
    event StageDockExecutorSelected(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 dockId,
        bytes32 fromPlanId,
        bytes32 supplierId,
        address selector,
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

    function applyStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) external {
        _applyStageExecutorPatch(planId, orderId, patch, msg.sender, address(0), bindingProof, candidateProof);
    }

    function applyStageExecutorPatchFor(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        bytes calldata previousExecutorSignature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageExecutorPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        bytes32 digest = stageExecutorPatchDigest(planId, orderId, patch, selector, deadline);
        address recoveredSigner = _recoverStageExecutorPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageExecutorPatchSignature(selector, recoveredSigner);
        }

        address recoveredPreviousExecutor;
        if (previousExecutorSignature.length != 0) {
            recoveredPreviousExecutor = _recoverStageExecutorPatchSigner(digest, previousExecutorSignature);
        }

        _applyStageExecutorPatch(
            planId, orderId, patch, selector, recoveredPreviousExecutor, bindingProof, candidateProof
        );
    }

    function selectStageDockExecutor(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) external {
        _selectStageDockExecutor(planId, orderId, selection, msg.sender, bindingProof);
    }

    function selectStageDockExecutorFor(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageExecutorPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        bytes32 digest = stageDockExecutorSelectionDigest(planId, orderId, selection, selector, deadline);
        address recoveredSigner = _recoverStageExecutorPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageExecutorPatchSignature(selector, recoveredSigner);
        }
        _selectStageDockExecutor(planId, orderId, selection, selector, bindingProof);
    }

    function pokeDockBinding(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes calldata payloadContent,
        bytes32 fromOrderId,
        bytes32[][] calldata outputCapabilityProofs
    ) external returns (uint256 emittedCount) {
        (bytes32 supplierId,, bytes32 dockId) = stateMachine.activeStageExecutorPatch(planId, orderId, targetStageId);
        if (supplierId == bytes32(0) || dockId == bytes32(0)) {
            revert DockBindingNotSelected(planId, orderId, targetStageId);
        }
        IUVPDockRegistry registry = _dockRegistry();
        (bytes32 fromPlanId,, bytes32 toSourceId,, bool dockExists) = _dockFields(dockId);
        if (!dockExists) {
            revert DockUnknown(dockId);
        }
        (, address executor) = stateMachine.effectiveStageExecutor(planId, orderId, targetStageId);
        DockBindingContext memory context = _dockBindingContext(
            planId, orderId, targetStageId, fromPlanId, dockId, toSourceId, supplierId, executor, payloadContent, fromOrderId
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
            address executor,
            bytes32 fromPlanId,
            bytes32 bindingId
        )
    {
        (supplierId,, dockId) = stateMachine.activeStageExecutorPatch(planId, orderId, targetStageId);
        selected = supplierId != bytes32(0) && dockId != bytes32(0);
        if (!selected) {
            return (false, false, bytes32(0), bytes32(0), address(0), bytes32(0), bytes32(0));
        }
        (bytes32 dockFromPlanId,,, bytes32 dockToStageId, bool dockExists) = _dockFields(dockId);
        fromPlanId = dockFromPlanId;
        if (!dockExists || dockToStageId != targetStageId) {
            return (false, false, bytes32(0), bytes32(0), address(0), bytes32(0), bytes32(0));
        }
        (, executor) = stateMachine.effectiveStageExecutor(planId, orderId, targetStageId);
        (bool payloadExists,,,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY);
        current = payloadExists && fromOrderId != bytes32(0);
        if (!current) {
            return (true, false, dockId, supplierId, executor, fromPlanId, bytes32(0));
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
        (bytes32 supplierId,, bytes32 dockId) = stateMachine.activeStageExecutorPatch(planId, orderId, targetStageId);
        if (supplierId == bytes32(0) || dockId == bytes32(0)) {
            return (false, false, 0, false, false);
        }
        (bytes32 fromPlanId,, bytes32 toSourceId, bytes32 toStageId, bool dockExists) = _dockFields(dockId);
        if (!dockExists || toStageId != targetStageId) {
            return (false, false, 0, false, false);
        }
        IUVPDockRegistry registry = _dockRegistry();
        (bool payloadExists,,,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY);
        current = payloadExists && fromOrderId != bytes32(0);
        if (outputIndex >= registry.dockOutputCount(dockId)) {
            return (current, false, 0, false, false);
        }
        (bytes32 signalId,,, IUVPStateMachineCore.WindowInstruction[] memory window) =
            registry.getDockOutput(dockId, outputIndex);
        (aSatisfied, aDueInSeconds) = stateMachine.evaluateDockWindow(fromPlanId, fromOrderId, window);
        bSatisfied = stateMachine.isSignalAdmissionSatisfied(planId, orderId, toSourceId, signalId);
        emitted = stateMachine.hasSignal(planId, orderId, toSourceId, signalId);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function stageExecutorPatchDigest(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _STAGE_EXECUTOR_PATCH_TYPEHASH,
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

    function stageDockExecutorSelectionDigest(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _STAGE_DOCK_EXECUTOR_SELECTION_TYPEHASH,
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

    function _applyStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        address previousExecutorSigner,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) private {
        _validateStageExecutorPatch(planId, orderId, patch, selector, bindingProof, candidateProof);

        (, uint256 currentNonce,) = stateMachine.activeStageExecutorPatch(planId, orderId, patch.targetStageId);
        if (patch.patchNonce <= currentNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, patch.targetStageId, currentNonce, patch.patchNonce
            );
        }
        _validateStageExecutorPatchTransition(planId, orderId, patch, previousExecutorSigner);

        stateMachine.activateStageExecutorFromModule(
            planId, orderId, patch.targetStageId, patch.supplierId, patch.patchNonce
        );
        emit StageExecutorPatchApplied(
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

    function _selectStageDockExecutor(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) private {
        (bytes32 fromPlanId,,,,) = _validateStageDockSelection(planId, orderId, selection, selector, bindingProof);

        (bytes32 activeSupplierId, uint256 activeNonce, bytes32 activeDockId) =
            stateMachine.activeStageExecutorPatch(planId, orderId, selection.targetStageId);
        if (activeDockId == selection.dockId && activeSupplierId == selection.supplierId) {
            return;
        }
        if (activeDockId != bytes32(0) || activeSupplierId != bytes32(0)) {
            revert StageDockExecutorAlreadySelected(planId, orderId, selection.targetStageId);
        }
        if (selection.patchNonce <= activeNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, selection.targetStageId, activeNonce, selection.patchNonce
            );
        }
        stateMachine.activateStageDockExecutorFromModule(
            planId, orderId, selection.targetStageId, selection.supplierId, selection.dockId, selection.patchNonce
        );
        emit StageDockExecutorSelected(
            planId,
            orderId,
            selection.targetStageId,
            selection.dockId,
            fromPlanId,
            selection.supplierId,
            selector,
            selection.patchNonce
        );
    }

    function _validateStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
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
            revert StageExecutorPatchForbiddenOnBirthStage(orderId, patch.targetStageId);
        }
        if (stateMachine.stageHasDockExecutorHook(planId, patch.targetStageId)) {
            revert StageExecutorPatchForbiddenOnDockStage(orderId, patch.targetStageId);
        }
        if (!stateMachine.planStageHasDynamicExecutor(planId, patch.targetStageId)) {
            if (stateMachine.planStageIsCandidate(planId, patch.targetStageId)) {
                bytes32 leaf = keccak256(
                    abi.encodePacked(
                        _EXECUTOR_BINDING_LEAF_DOMAIN,
                        patch.targetStageId,
                        patch.supplierId,
                        _EXECUTOR_BINDING_KIND_CANDIDATE
                    )
                );
                bytes32 bindingsRoot = stateMachine.planExecutorBindingsRoot(planId);
                if (
                    bindingsRoot == bytes32(0) || bindingsRoot == MerkleCommitment.EMPTY_ROOT
                        || !MerkleCommitment.verify(bindingsRoot, leaf, candidateProof)
                ) {
                    revert StageExecutorNotCandidate(planId, orderId, patch.targetStageId, patch.supplierId);
                }
            } else {
                revert StageExecutorPatchForbiddenOnFixedStage(orderId, patch.targetStageId);
            }
        }
        if (
            bindingProof.selectorStageId != patch.selectorStageId
                || !_planMetadata()
                    .verifyStageSelectorBinding(planId, patch.selectorStageId, patch.targetStageId, bindingProof.proof)
        ) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!stateMachine.isEffectiveStageExecutor(planId, orderId, patch.selectorStageId, selector)) {
            revert UnauthorizedStageExecutorPatchSelector(orderId, patch.selectorStageId, selector);
        }
        if (!_supplierRegistry().isRegisteredSupplier(patch.supplierId)) {
            revert SupplierNotRegistered(patch.supplierId);
        }
    }

    function _validateStageExecutorPatchTransition(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address previousExecutorSigner
    ) private view {
        (uint256 signalCount,,,) = stateMachine.stageSignalState(planId, orderId, patch.targetStageId);
        if (patch.previousSupplierId == bytes32(0)) {
            if (signalCount != 0) {
                revert StageAlreadyHasSignal(orderId, patch.targetStageId);
            }
            if (previousExecutorSigner != address(0)) {
                revert InvalidStageExecutorPatchSignature(address(0), previousExecutorSigner);
            }
            return;
        }

        if (signalCount == 0) {
            revert StageHasNoSignal(orderId, patch.targetStageId);
        }
        (bytes32 effectiveSupplierId, address effectiveExecutor) =
            stateMachine.effectiveStageExecutor(planId, orderId, patch.targetStageId);
        if (effectiveSupplierId != patch.previousSupplierId) {
            revert StageExecutorPatchPreviousSupplierMismatch(
                orderId, patch.targetStageId, effectiveSupplierId, patch.previousSupplierId
            );
        }
        if (previousExecutorSigner != effectiveExecutor) {
            revert InvalidStageExecutorPatchSignature(effectiveExecutor, previousExecutorSigner);
        }
    }

    function _validateStageDockSelection(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) private view returns (bytes32 fromPlanId, bytes32 toPlanId, bytes32 toSourceId, bytes32 toStageId, bool exists) {
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
        (fromPlanId, toPlanId, toSourceId, toStageId, exists) = _dockFields(selection.dockId);
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
        if (!stateMachine.isEffectiveStageExecutor(planId, orderId, selection.selectorStageId, selector)) {
            revert UnauthorizedStageExecutorPatchSelector(orderId, selection.selectorStageId, selector);
        }
        if (!_supplierRegistry().isRegisteredSupplier(selection.supplierId)) {
            revert SupplierNotRegistered(selection.supplierId);
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
        address executor,
        bytes calldata payloadContent,
        bytes32 fromOrderId
    ) private view returns (DockBindingContext memory context) {
        if (!stateMachine.orderExists(fromPlanId, fromOrderId)) {
            revert DockBindingFromOrderUnknown(fromPlanId, fromOrderId);
        }
        (bool payloadExists, bytes32 contentHash,,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY);
        if (!payloadExists) {
            revert DockBindingPayloadMissing(planId, orderId, targetStageId);
        }
        bytes32 actualContentHash = keccak256(payloadContent);
        if (actualContentHash != contentHash) {
            revert DockBindingContentHashMismatch(contentHash, actualContentHash);
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
            executor: executor
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
            context.executor,
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
            bool exists
        )
    {
        (fromPlanId, , toPlanId, toStageId, toSourceId, , , exists) = _dockRegistry().getDock(dockId);
    }

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForStagePatch) {
        return IUVPPlanMetadataModuleForStagePatch(stateMachine.planMetadataModule());
    }

    function _dockRegistry() private view returns (IUVPDockRegistry) {
        return IUVPDockRegistry(stateMachine.dockRegistry());
    }

    function _supplierRegistry() private view returns (IUVPSupplierRegistry) {
        return IUVPSupplierRegistry(stateMachine.supplierRegistry());
    }

    function _recoverStageExecutorPatchSigner(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidStageExecutorPatchSignatureLength(signature.length);
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
