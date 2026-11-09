// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    FileOp,
    FileOpKind,
    FilePatch,
    FilePatchEmpty,
    IUVPFileResourceModule
} from "./interfaces/IUVPFileResourceModule.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";

/// File-map owner: per (plan, order, targetStage, key) contentHash/handle/patchHash and the
/// per-target filesHash chain. The canonical file-patch digest is single-sourced in
/// protocol-bindings; this contract mirrors it byte-for-byte for the golden vector.
contract UVPFileResourceModule is IUVPFileResourceModule {
    struct FileRecord {
        bytes32 contentHash;
        string handle;
        bytes32 patchHash;
        bool exists;
    }

    error FileBaseHashMismatch(bytes32 expected, bytes32 provided);
    error FileDigestMismatch(bytes32 expected, bytes32 provided);
    error FileHandleTooLong(uint256 length);
    error FileKeyExists(bytes32 key);
    error FileKeyMissing(bytes32 key);
    error FileOpKindInvalid(uint8 kind);
    error FileOpKeyZero();
    error FileOpsTooMany(uint256 count);
    error FileTargetStageUnknown(bytes32 planId, bytes32 targetStageId);
    error FileWriterUnauthorized(bytes32 orderId, bytes32 targetStageId, bytes32 writerStageId, address submitter);
    error UnknownOrder();
    error UnauthorizedStateMachine(address caller);

    uint256 private constant _MAX_FILE_OPS = 16;
    uint256 private constant _MAX_FILE_HANDLE_BYTES = 512;
    bytes32 private constant _DOMAIN_FILE_PATCH = keccak256("UVP_FILE_PATCH_V1");

    IUVPStateMachineCore public immutable stateMachine;

    mapping(
        bytes32 planId
            => mapping(bytes32 orderId => mapping(bytes32 targetStageId => mapping(bytes32 key => FileRecord record)))
    ) private _stageFiles;
    mapping(bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 targetStageId => bytes32 filesHash))) private
        _stageFilesHashes;
    mapping(
        bytes32 planId
            => mapping(bytes32 orderId => mapping(bytes32 targetStageId => mapping(bytes32 patchHash => bool applied)))
    ) private _appliedPatchHashes;

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function applyStageFilePatch(
        bytes32 planId,
        bytes32 orderId,
        bytes32 filesDigest,
        FilePatch calldata filePatch,
        address submitter
    ) external {
        if (msg.sender != address(stateMachine)) {
            revert UnauthorizedStateMachine(msg.sender);
        }

        uint256 opCount = filePatch.ops.length;
        if (opCount == 0) {
            revert FilePatchEmpty();
        }
        if (opCount > _MAX_FILE_OPS) {
            revert FileOpsTooMany(opCount);
        }

        bytes32 patchHash = filePatchDigest(planId, orderId, filePatch);
        if (patchHash != filesDigest) {
            revert FileDigestMismatch(patchHash, filesDigest);
        }
        if (_appliedPatchHashes[planId][orderId][filePatch.targetStageId][patchHash]) {
            return;
        }

        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.isPlanStage(planId, filePatch.targetStageId)) {
            revert FileTargetStageUnknown(planId, filePatch.targetStageId);
        }
        for (uint256 i = 0; i < opCount; i++) {
            _validateOp(filePatch.ops[i]);
        }

        _requireFileWriter(planId, orderId, filePatch, submitter);

        bytes32 previousFilesHash = _stageFilesHashes[planId][orderId][filePatch.targetStageId];
        if (filePatch.baseHash != previousFilesHash) {
            revert FileBaseHashMismatch(previousFilesHash, filePatch.baseHash);
        }

        mapping(bytes32 => FileRecord) storage targetFiles = _stageFiles[planId][orderId][filePatch.targetStageId];
        for (uint256 i = 0; i < opCount; i++) {
            _applyOp(targetFiles, filePatch.ops[i], patchHash);
        }
        _appliedPatchHashes[planId][orderId][filePatch.targetStageId][patchHash] = true;
        _stageFilesHashes[planId][orderId][filePatch.targetStageId] =
            keccak256(abi.encode(previousFilesHash, patchHash));

        emit StageFilePatchApplied(
            planId,
            orderId,
            filePatch.targetStageId,
            patchHash,
            filePatch.baseHash,
            submitter,
            filePatch.writerStageId,
            opCount
        );
        for (uint256 i = 0; i < opCount; i++) {
            FileOp calldata op = filePatch.ops[i];
            emit StageFileOpApplied(
                planId, orderId, filePatch.targetStageId, op.kind, op.key, op.contentHash, op.handle
            );
        }
    }

    function getStageFile(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 key)
        external
        view
        returns (bool exists, bytes32 contentHash, string memory handle, bytes32 patchHash)
    {
        FileRecord storage record = _stageFiles[planId][orderId][targetStageId][key];
        return (record.exists, record.contentHash, record.handle, record.patchHash);
    }

    function stageFilesHash(bytes32 planId, bytes32 orderId, bytes32 targetStageId) external view returns (bytes32) {
        return _stageFilesHashes[planId][orderId][targetStageId];
    }

    function filePatchDigest(bytes32 planId, bytes32 orderId, FilePatch calldata filePatch)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _DOMAIN_FILE_PATCH,
                planId,
                orderId,
                filePatch.targetStageId,
                filePatch.baseHash,
                filePatch.writerStageId,
                filePatch.ops
            )
        );
    }

    function _validateOp(FileOp calldata op) private pure {
        if (op.kind > uint8(FileOpKind.Remove)) {
            revert FileOpKindInvalid(op.kind);
        }
        if (op.key == bytes32(0)) {
            revert FileOpKeyZero();
        }
        uint256 handleLength = bytes(op.handle).length;
        if (handleLength > _MAX_FILE_HANDLE_BYTES) {
            revert FileHandleTooLong(handleLength);
        }
    }

    function _requireFileWriter(bytes32 planId, bytes32 orderId, FilePatch calldata filePatch, address submitter)
        private
        view
    {
        if (filePatch.writerStageId == bytes32(0)) {
            if (stateMachine.activeStageExecutor(planId, orderId, filePatch.targetStageId) != submitter) {
                revert FileWriterUnauthorized(orderId, filePatch.targetStageId, filePatch.writerStageId, submitter);
            }
            return;
        }
        bool capability = IUVPPlanMetadataModule(stateMachine.planMetadataModule())
            .verifyFileWriter(planId, filePatch.targetStageId, filePatch.writerStageId, filePatch.writerProof);
        if (capability && stateMachine.activeStageExecutor(planId, orderId, filePatch.writerStageId) == submitter) {
            return;
        }
        revert FileWriterUnauthorized(orderId, filePatch.targetStageId, filePatch.writerStageId, submitter);
    }

    function _applyOp(mapping(bytes32 => FileRecord) storage targetFiles, FileOp calldata op, bytes32 patchHash)
        private
    {
        FileRecord storage record = targetFiles[op.key];
        if (op.kind == uint8(FileOpKind.Add)) {
            if (record.exists) {
                revert FileKeyExists(op.key);
            }
            record.contentHash = op.contentHash;
            record.handle = op.handle;
            record.exists = true;
        } else if (op.kind == uint8(FileOpKind.Replace)) {
            if (!record.exists) {
                revert FileKeyMissing(op.key);
            }
            record.contentHash = op.contentHash;
            record.handle = op.handle;
        } else {
            if (!record.exists) {
                revert FileKeyMissing(op.key);
            }
            record.contentHash = bytes32(0);
            delete record.handle;
            record.exists = false;
        }
        record.patchHash = patchHash;
    }
}
