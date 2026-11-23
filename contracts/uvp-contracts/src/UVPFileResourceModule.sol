// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPFileResourceModule, StageFile, StageFilesEmpty} from "./interfaces/IUVPFileResourceModule.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";

/// File-map owner: per (plan, order, target stage) opaque key -> payload entries.
/// Write authority is resolved by the state machine from the plan's fileWriters
/// stage list; this module never interprets a key or payload.
contract UVPFileResourceModule is IUVPFileResourceModule {
    struct FileRecord {
        bytes payload;
        bool exists;
    }

    error StageFilesTooMany(uint256 count);
    error StageFileKeyEmpty();
    error StageFileKeyTooLong(uint256 length);
    error StageFilePayloadTooLarge(uint256 length);
    error FileTargetStageUnknown(bytes32 planId, bytes32 targetStageId);
    error FileWriterUnauthorized(bytes32 orderId, bytes32 targetStageId, address submitter);
    error UnknownOrder();
    error UnauthorizedStateMachine(address caller);

    uint256 public constant MAX_STAGE_FILES = 16;
    uint256 public constant MAX_STAGE_FILE_KEY_BYTES = 128;
    uint256 public constant MAX_STAGE_FILE_PAYLOAD_BYTES = 4096;

    IUVPStateMachineCore public immutable stateMachine;

    mapping(
        bytes32 planId
            => mapping(bytes32 orderId => mapping(bytes32 targetStageId => mapping(bytes32 keyHash => FileRecord record)))
    ) private _stageFiles;

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function applyStageFiles(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        StageFile[] calldata files,
        address submitter
    ) external {
        if (msg.sender != address(stateMachine)) {
            revert UnauthorizedStateMachine(msg.sender);
        }
        uint256 fileCount = files.length;
        if (fileCount == 0) {
            revert StageFilesEmpty();
        }
        if (fileCount > MAX_STAGE_FILES) {
            revert StageFilesTooMany(fileCount);
        }
        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.isPlanStage(planId, targetStageId)) {
            revert FileTargetStageUnknown(planId, targetStageId);
        }
        if (!stateMachine.isAuthorizedFileWriter(planId, orderId, targetStageId, submitter)) {
            revert FileWriterUnauthorized(orderId, targetStageId, submitter);
        }

        mapping(bytes32 => FileRecord) storage targetFiles = _stageFiles[planId][orderId][targetStageId];
        for (uint256 i = 0; i < fileCount; i++) {
            StageFile calldata file = files[i];
            uint256 keyLength = bytes(file.key).length;
            if (keyLength == 0) {
                revert StageFileKeyEmpty();
            }
            if (keyLength > MAX_STAGE_FILE_KEY_BYTES) {
                revert StageFileKeyTooLong(keyLength);
            }
            uint256 payloadLength = file.payload.length;
            if (payloadLength > MAX_STAGE_FILE_PAYLOAD_BYTES) {
                revert StageFilePayloadTooLarge(payloadLength);
            }
            bytes32 keyHash = keccak256(bytes(file.key));
            targetFiles[keyHash] = FileRecord({payload: file.payload, exists: true});
            emit StageFileWritten(planId, orderId, targetStageId, file.key, file.payload, submitter);
        }
    }

    function getStageFile(bytes32 planId, bytes32 orderId, bytes32 targetStageId, string calldata key)
        external
        view
        returns (bool exists, bytes memory payload)
    {
        FileRecord storage record = _stageFiles[planId][orderId][targetStageId][keccak256(bytes(key))];
        return (record.exists, record.payload);
    }
}
