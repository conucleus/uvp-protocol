// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum FileOpKind {
    Add,
    Replace,
    Remove
}

struct FileOp {
    uint8 kind;
    bytes32 key;
    bytes32 contentHash;
    string handle;
}

struct FilePatch {
    bytes32 targetStageId;
    bytes32 baseHash;
    bytes32 writerStageId;
    bytes32[] writerProof;
    FileOp[] ops;
}

error FilePatchEmpty();

interface IUVPFileResourceModule {
    function applyStageFilePatch(
        bytes32 planId,
        bytes32 orderId,
        bytes32 filesDigest,
        FilePatch calldata filePatch,
        address submitter,
        bytes32 authSourceId,
        bytes32 authSignalId,
        bool standalone
    ) external;

    function getStageFile(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 key)
        external
        view
        returns (bool exists, bytes32 contentHash, string memory handle, bytes32 patchHash);

    function stageFilesHash(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bytes32);

    event StageFilePatchApplied(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 patchHash,
        bytes32 baseHash,
        address submitter,
        bytes32 writerStageId,
        uint256 opCount
    );

    event StageFileOpApplied(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        uint8 kind,
        bytes32 key,
        bytes32 contentHash,
        string handle
    );
}
