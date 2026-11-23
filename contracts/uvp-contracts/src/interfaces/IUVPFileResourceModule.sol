// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct StageFile {
    string key;
    bytes payload;
}

error StageFilesEmpty();

interface IUVPFileResourceModule {
    function applyStageFiles(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        StageFile[] calldata files,
        address submitter
    ) external;

    function getStageFile(bytes32 planId, bytes32 orderId, bytes32 targetStageId, string calldata key)
        external
        view
        returns (bool exists, bytes memory payload);

    event StageFileWritten(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        string key,
        bytes payload,
        address submitter
    );
}
