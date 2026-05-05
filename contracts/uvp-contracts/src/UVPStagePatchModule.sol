// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

interface IUVPPlanMetadataModuleForStagePatch {
    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        external
        view
        returns (bool);
}

contract UVPStagePatchModule {
    struct StageExecutorPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 mode;
        address previousExecutor;
        bytes32 approvalSourceId;
        bytes32 approvalSignalId;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
    }

    struct StageResourcePatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 resourceKey;
        bytes32 manifestHash;
        bytes32 policyHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string manifestURI;
    }

    struct ActiveStageExecutorPatch {
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
        bool exists;
    }

    struct ActiveStageResourcePatch {
        bytes32 manifestHash;
        bytes32 policyHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string manifestURI;
        bool exists;
    }

    error ExpiredStageExecutorPatchSignature(uint256 deadline);
    error ExpiredStageResourcePatchSignature(uint256 deadline);
    error InvalidStageExecutorPatchMode(bytes32 mode);
    error InvalidStageExecutorPatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageExecutorPatchSignatureLength(uint256 length);
    error InvalidStageResourcePatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageResourcePatchSignatureLength(uint256 length);
    error StageAlreadyHasSignal(bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchApprovalSignalMissing(bytes32 orderId, bytes32 approvalSourceId, bytes32 approvalSignalId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error StageExecutorPatchPreviousExecutorMismatch(
        bytes32 orderId, bytes32 targetStageId, address expectedExecutor, address previousExecutor
    );
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    error StageResourcePatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey, uint256 previousNonce, uint256 patchNonce
    );
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error UnauthorizedStageExecutorPatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnauthorizedStageResourcePatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnknownOrder();
    error ZeroManifestHash();
    error ZeroPatchHash();
    error ZeroPolicyHash();
    error ZeroResourceKey();
    error ZeroSelector();
    error ZeroSelectorStageId();
    error ZeroStageExecutor();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    bytes32 public constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;
    bytes32 public constant RESOURCE_PATCH_SIGNAL_ID =
        0x6dff331f2bb7b785cbcd99a911e6d30dc8714f43b3b9ba80c658215445ddd0ba;
    bytes32 public constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");
    bytes32 public constant EXECUTOR_PATCH_MODE_HANDOFF = bytes32("handoff");
    bytes32 public constant EXECUTOR_PATCH_MODE_REPLACEMENT = bytes32("replacement");

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStagePatchModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.1");
    bytes32 private constant _STAGE_EXECUTOR_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageExecutorPatch(bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_RESOURCE_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageResourcePatch(bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC = keccak256(
        "StageExecutorPatchApplied(bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,bytes32,uint256,string)"
    );

    mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch)) private
        _activeStageExecutorPatches;
    mapping(
        bytes32 orderId
            => mapping(bytes32 targetStageId => mapping(bytes32 resourceKey => ActiveStageResourcePatch patch))
    ) private _activeStageResourcePatches;

    event StageExecutorPatchApplied(
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 indexed targetStageId,
        address selector,
        address executor,
        bytes32 role,
        bytes32 executorMetadataHash,
        bytes32 mode,
        address previousExecutor,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        bytes32 patchHash,
        uint256 patchNonce,
        string metadataURI
    );
    event StageResourcePatchApplied(
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 indexed targetStageId,
        address selector,
        bytes32 resourceKey,
        bytes32 manifestHash,
        bytes32 policyHash,
        bytes32 patchHash,
        uint256 patchNonce,
        string manifestURI
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function applyStageExecutorPatch(bytes32 orderId, StageExecutorPatch calldata patch) external {
        _applyStageExecutorPatch(orderId, patch, msg.sender, address(0));
    }

    function applyStageExecutorPatchFor(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        bytes calldata previousExecutorSignature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageExecutorPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        bytes32 digest = stageExecutorPatchDigest(orderId, patch, selector, deadline);
        address recoveredSigner = _recoverStageExecutorPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageExecutorPatchSignature(selector, recoveredSigner);
        }

        address recoveredPreviousExecutor;
        if (previousExecutorSignature.length != 0) {
            recoveredPreviousExecutor = _recoverStageExecutorPatchSigner(digest, previousExecutorSignature);
        }

        _applyStageExecutorPatch(orderId, patch, selector, recoveredPreviousExecutor);
    }

    function applyStageResourcePatch(bytes32 orderId, StageResourcePatch calldata patch) external {
        _applyStageResourcePatch(orderId, patch, msg.sender);
    }

    function applyStageResourcePatchFor(
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageResourcePatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        address recoveredSigner =
            _recoverStageResourcePatchSelector(stageResourcePatchDigest(orderId, patch, selector, deadline), signature);
        if (recoveredSigner != selector) {
            revert InvalidStageResourcePatchSignature(selector, recoveredSigner);
        }

        _applyStageResourcePatch(orderId, patch, selector);
    }

    function activeStageExecutor(bytes32 orderId, bytes32 targetStageId) external view returns (address) {
        return _activeStageExecutorPatches[orderId][targetStageId].executor;
    }

    function orderStageExecutorPatchNonce(bytes32 orderId, bytes32 targetStageId) external view returns (uint256) {
        return _activeStageExecutorPatches[orderId][targetStageId].patchNonce;
    }

    function getActiveStageExecutorPatch(bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        )
    {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[orderId][targetStageId];
        return (
            activePatch.exists,
            activePatch.executor,
            activePatch.role,
            activePatch.executorMetadataHash,
            activePatch.patchHash,
            activePatch.patchNonce,
            activePatch.metadataURI
        );
    }

    function orderStageResourcePatchNonce(bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (uint256)
    {
        return _activeStageResourcePatches[orderId][targetStageId][resourceKey].patchNonce;
    }

    function getActiveStageResourcePatch(bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (
            bool exists,
            bytes32 manifestHash,
            bytes32 policyHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory manifestURI
        )
    {
        ActiveStageResourcePatch storage activePatch = _activeStageResourcePatches[orderId][targetStageId][resourceKey];
        return (
            activePatch.exists,
            activePatch.manifestHash,
            activePatch.policyHash,
            activePatch.patchHash,
            activePatch.patchNonce,
            activePatch.manifestURI
        );
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function stageExecutorPatchDigest(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01", DOMAIN_SEPARATOR(), _stageExecutorPatchStructHash(orderId, patch, selector, deadline)
            )
        );
    }

    function stageResourcePatchDigest(
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _STAGE_RESOURCE_PATCH_TYPEHASH,
                orderId,
                patch.selectorStageId,
                patch.targetStageId,
                patch.resourceKey,
                patch.manifestHash,
                patch.policyHash,
                patch.patchHash,
                patch.patchNonce,
                keccak256(bytes(patch.manifestURI)),
                selector,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _applyStageExecutorPatch(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        address previousExecutorSigner
    ) private {
        _validateStageExecutorPatch(orderId, patch, selector);

        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[orderId][patch.targetStageId];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, patch.targetStageId, activePatch.patchNonce, patch.patchNonce
            );
        }
        _validateStageExecutorPatchMode(orderId, patch, activePatch, previousExecutorSigner);

        activePatch.executor = patch.executor;
        activePatch.role = patch.role;
        activePatch.executorMetadataHash = patch.executorMetadataHash;
        activePatch.patchHash = patch.patchHash;
        activePatch.patchNonce = patch.patchNonce;
        activePatch.metadataURI = patch.metadataURI;
        activePatch.exists = true;

        _emitStageExecutorPatchApplied(orderId, patch, selector);
        stateMachine.activateStageExecutorFromModule(
            orderId,
            patch.targetStageId,
            patch.executor,
            patch.role,
            patch.executorMetadataHash,
            patch.patchHash,
            patch.patchNonce
        );
    }

    function _validateStageExecutorPatch(bytes32 orderId, StageExecutorPatch calldata patch, address selector)
        private
        view
    {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (patch.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        if (!_isStageExecutorPatchMode(patch.mode)) {
            revert InvalidStageExecutorPatchMode(patch.mode);
        }
        if (!stateMachine.orderExists(orderId)) {
            revert UnknownOrder();
        }
        bytes32 planId = stateMachine.orderPlanId(orderId);
        if (!_planMetadata().isStageSelectorBound(planId, patch.selectorStageId, patch.targetStageId)) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!stateMachine.hasExplicitSignalAuthorization(orderId, patch.selectorStageId, EXECUTOR_PATCH_SIGNAL_ID, selector)) {
            revert UnauthorizedStageExecutorPatchSelector(orderId, patch.selectorStageId, selector);
        }
    }

    function _validateStageExecutorPatchMode(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        ActiveStageExecutorPatch storage activePatch,
        address previousExecutorSigner
    ) private view {
        uint256 signalCount = stateMachine.sourceSignalCount(orderId, patch.targetStageId);
        if (patch.mode == EXECUTOR_PATCH_MODE_ASSIGN) {
            if (patch.previousExecutor != address(0)) {
                revert StageExecutorPatchPreviousExecutorMismatch(
                    orderId, patch.targetStageId, address(0), patch.previousExecutor
                );
            }
            if (patch.approvalSourceId != bytes32(0) || patch.approvalSignalId != bytes32(0)) {
                revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
            }
            if (signalCount != 0) {
                revert StageAlreadyHasSignal(orderId, patch.targetStageId);
            }
            return;
        }

        if (signalCount == 0) {
            revert StageHasNoSignal(orderId, patch.targetStageId);
        }

        address expectedPreviousExecutor =
            activePatch.exists ? activePatch.executor : stateMachine.lastSignalSubmitter(orderId, patch.targetStageId);
        if (patch.previousExecutor != expectedPreviousExecutor) {
            revert StageExecutorPatchPreviousExecutorMismatch(
                orderId, patch.targetStageId, expectedPreviousExecutor, patch.previousExecutor
            );
        }

        if (patch.mode == EXECUTOR_PATCH_MODE_HANDOFF) {
            if (patch.approvalSourceId != bytes32(0) || patch.approvalSignalId != bytes32(0)) {
                revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
            }
            if (previousExecutorSigner != patch.previousExecutor) {
                revert InvalidStageExecutorPatchSignature(patch.previousExecutor, previousExecutorSigner);
            }
            return;
        }

        if (!stateMachine.hasSignal(orderId, patch.approvalSourceId, patch.approvalSignalId)) {
            revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
        }
    }

    function _applyStageResourcePatch(bytes32 orderId, StageResourcePatch calldata patch, address selector) private {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.resourceKey == bytes32(0)) {
            revert ZeroResourceKey();
        }
        if (patch.manifestHash == bytes32(0)) {
            revert ZeroManifestHash();
        }
        if (patch.policyHash == bytes32(0)) {
            revert ZeroPolicyHash();
        }
        if (patch.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        if (!stateMachine.orderExists(orderId)) {
            revert UnknownOrder();
        }

        bytes32 planId = stateMachine.orderPlanId(orderId);
        if (!_planMetadata().isStageSelectorBound(planId, patch.selectorStageId, patch.targetStageId)) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!stateMachine.hasExplicitSignalAuthorization(orderId, patch.selectorStageId, RESOURCE_PATCH_SIGNAL_ID, selector)) {
            revert UnauthorizedStageResourcePatchSelector(orderId, patch.selectorStageId, selector);
        }
        if (stateMachine.sourceSignalCount(orderId, patch.targetStageId) != 0) {
            revert StageAlreadyHasSignal(orderId, patch.targetStageId);
        }

        ActiveStageResourcePatch storage activePatch =
            _activeStageResourcePatches[orderId][patch.targetStageId][patch.resourceKey];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageResourcePatchNonceNotIncreasing(
                orderId, patch.targetStageId, patch.resourceKey, activePatch.patchNonce, patch.patchNonce
            );
        }

        activePatch.manifestHash = patch.manifestHash;
        activePatch.policyHash = patch.policyHash;
        activePatch.patchHash = patch.patchHash;
        activePatch.patchNonce = patch.patchNonce;
        activePatch.manifestURI = patch.manifestURI;
        activePatch.exists = true;

        emit StageResourcePatchApplied(
            orderId,
            patch.selectorStageId,
            patch.targetStageId,
            selector,
            patch.resourceKey,
            patch.manifestHash,
            patch.policyHash,
            patch.patchHash,
            patch.patchNonce,
            patch.manifestURI
        );
    }

    function _isStageExecutorPatchMode(bytes32 mode) private pure returns (bool) {
        return mode == EXECUTOR_PATCH_MODE_ASSIGN || mode == EXECUTOR_PATCH_MODE_HANDOFF
            || mode == EXECUTOR_PATCH_MODE_REPLACEMENT;
    }

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForStagePatch) {
        return IUVPPlanMetadataModuleForStagePatch(stateMachine.planMetadataModule());
    }

    function _stageExecutorPatchStructHash(
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) private pure returns (bytes32) {
        bytes memory encoded = new bytes(0x200);
        _writeWord(encoded, 0x00, _STAGE_EXECUTOR_PATCH_TYPEHASH);
        _writeWord(encoded, 0x20, orderId);
        _writeWord(encoded, 0x40, patch.selectorStageId);
        _writeWord(encoded, 0x60, patch.targetStageId);
        _writeAddress(encoded, 0x80, patch.executor);
        _writeWord(encoded, 0xa0, patch.role);
        _writeWord(encoded, 0xc0, patch.executorMetadataHash);
        _writeWord(encoded, 0xe0, patch.mode);
        _writeAddress(encoded, 0x100, patch.previousExecutor);
        _writeWord(encoded, 0x120, patch.approvalSourceId);
        _writeWord(encoded, 0x140, patch.approvalSignalId);
        _writeWord(encoded, 0x160, patch.patchHash);
        _writeWord(encoded, 0x180, bytes32(patch.patchNonce));
        _writeWord(encoded, 0x1a0, keccak256(bytes(patch.metadataURI)));
        _writeAddress(encoded, 0x1c0, selector);
        _writeWord(encoded, 0x1e0, bytes32(deadline));
        return keccak256(encoded);
    }

    function _emitStageExecutorPatchApplied(bytes32 orderId, StageExecutorPatch calldata patch, address selector)
        private
    {
        bytes memory metadataURI = bytes(patch.metadataURI);
        bytes memory eventData = new bytes(0x180 + _paddedLength(metadataURI.length));
        _writeAddress(eventData, 0x00, selector);
        _writeAddress(eventData, 0x20, patch.executor);
        _writeWord(eventData, 0x40, patch.role);
        _writeWord(eventData, 0x60, patch.executorMetadataHash);
        _writeWord(eventData, 0x80, patch.mode);
        _writeAddress(eventData, 0xa0, patch.previousExecutor);
        _writeWord(eventData, 0xc0, patch.approvalSourceId);
        _writeWord(eventData, 0xe0, patch.approvalSignalId);
        _writeWord(eventData, 0x100, patch.patchHash);
        _writeWord(eventData, 0x120, bytes32(patch.patchNonce));
        _writeWord(eventData, 0x140, bytes32(uint256(0x160)));
        _writeWord(eventData, 0x160, bytes32(metadataURI.length));
        _copyBytes(eventData, 0x180, metadataURI);

        bytes32 selectorStageId = patch.selectorStageId;
        bytes32 targetStageId = patch.targetStageId;
        bytes32 topic = _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC;
        assembly {
            log4(add(eventData, 0x20), mload(eventData), topic, orderId, selectorStageId, targetStageId)
        }
    }

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _copyBytes(bytes memory target, uint256 offset, bytes memory source) private pure {
        for (uint256 i = 0; i < source.length; i++) {
            target[offset + i] = source[i];
        }
    }

    function _paddedLength(uint256 length) private pure returns (uint256) {
        return (length + 31) & ~uint256(31);
    }

    function _recoverStageExecutorPatchSigner(bytes32 digest, bytes calldata signature)
        private
        pure
        returns (address)
    {
        if (signature.length != 65) {
            revert InvalidStageExecutorPatchSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }

    function _recoverStageResourcePatchSelector(bytes32 digest, bytes calldata signature)
        private
        pure
        returns (address)
    {
        if (signature.length != 65) {
            revert InvalidStageResourcePatchSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }
}
