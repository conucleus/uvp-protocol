// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPFileResourceModule} from "./interfaces/IUVPFileResourceModule.sol";
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
    uint8 private constant _SUPPLIER_BINDING_KIND_CANDIDATE = 1;

    struct StageSupplierPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 supplierId;
        bytes32 previousSupplierId;
        uint256 patchNonce;
    }

    error ExpiredStageSupplierPatchSignature(uint256 deadline);
    error InvalidStageSupplierPatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageSupplierPatchSignatureLength(uint256 length);
    error StageAlreadyHasSignal(bytes32 orderId, bytes32 targetStageId);
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error StageSupplierNotCandidate(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 supplierId);
    error StageSupplierPatchForbiddenOnBirthStage(bytes32 orderId, bytes32 targetStageId);
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
    error ZeroSelector();
    error ZeroSelectorStageId();
    error ZeroStageSupplier();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStagePatchModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 private constant _STAGE_SUPPLIER_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageSupplierPatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 supplierId,bytes32 previousSupplierId,uint256 patchNonce,address selector,uint256 deadline)"
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

        (, uint256 currentNonce) = stateMachine.stageSupplierAssignment(planId, orderId, patch.targetStageId);
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

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForStagePatch) {
        return IUVPPlanMetadataModuleForStagePatch(stateMachine.planMetadataModule());
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
