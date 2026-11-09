// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {FileOp, FileOpKind, FilePatch} from "../src/interfaces/IUVPFileResourceModule.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract UVPFileResourceModuleTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant PLAN_ID = keccak256("plan");
    bytes32 private constant ORDER_ID = keccak256("order");
    bytes32 private constant TARGET_STAGE = keccak256("target");
    bytes32 private constant WRITER_STAGE = keccak256("writer");
    bytes32 private constant KEY = keccak256("key");
    bytes32 private constant CONTENT_HASH_1 = keccak256("content-1");
    bytes32 private constant CONTENT_HASH_2 = keccak256("content-2");
    bytes32 private constant WRONG_DIGEST = keccak256("wrong-digest");

    address private constant TARGET_EXECUTOR = address(uint160(0xa11ce));
    address private constant WRITER_EXECUTOR = address(uint160(0xb0b));
    address private constant OUTSIDER = address(uint160(0xbad));

    UVPFileResourceModule private _fileModule;
    UVPPlanMetadataModule private _metadata;
    mapping(bytes32 stageId => address executor) private _activeExecutors;

    function setUp() public {
        _metadata = new UVPPlanMetadataModule(address(this));
        _fileModule = new UVPFileResourceModule(address(this));
        _activeExecutors[TARGET_STAGE] = TARGET_EXECUTOR;
    }

    function orderExists(bytes32, bytes32) external pure returns (bool) {
        return true;
    }

    function isPlanStage(bytes32, bytes32) external pure returns (bool) {
        return true;
    }

    function planExists(bytes32) external pure returns (bool) {
        return true;
    }

    function activeStageExecutor(bytes32, bytes32, bytes32 stageId) external view returns (address) {
        return _activeExecutors[stageId];
    }

    function planMetadataModule() external view returns (address) {
        return address(_metadata);
    }

    function testAddStoresContentHashHandleAndPatchHash() public {
        _apply(_singleOpPatch(bytes32(0), bytes32(0), _add(KEY, CONTENT_HASH_1, "uvp://file/one")), TARGET_EXECUTOR);

        (bool exists, bytes32 contentHash, string memory handle, bytes32 patchHash) =
            _fileModule.getStageFile(PLAN_ID, ORDER_ID, TARGET_STAGE, KEY);
        require(exists, "key not stored");
        require(contentHash == CONTENT_HASH_1, "content hash");
        require(keccak256(bytes(handle)) == keccak256(bytes("uvp://file/one")), "handle");
        require(patchHash != bytes32(0), "patch hash");
        require(_fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE) != bytes32(0), "files hash");
    }

    function testAddRejectsExistingKey() public {
        _apply(_singleOpPatch(bytes32(0), bytes32(0), _add(KEY, CONTENT_HASH_1, "uvp://file/one")), TARGET_EXECUTOR);
        bytes32 currentFilesHash = _fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE);

        FilePatch memory patch =
            _singleOpPatch(currentFilesHash, bytes32(0), _add(KEY, CONTENT_HASH_2, "uvp://file/two"));
        bytes32 digest = _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, patch);
        vm.expectRevert(abi.encodeWithSelector(UVPFileResourceModule.FileKeyExists.selector, KEY));
        _fileModule.applyStageFilePatch(PLAN_ID, ORDER_ID, digest, patch, TARGET_EXECUTOR);
    }

    function testReplaceAndRemoveRejectMissingKey() public {
        FilePatch memory replacePatch =
            _singleOpPatch(bytes32(0), bytes32(0), _replace(KEY, CONTENT_HASH_1, "uvp://file/one"));
        bytes32 replaceDigest = _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, replacePatch);
        vm.expectRevert(abi.encodeWithSelector(UVPFileResourceModule.FileKeyMissing.selector, KEY));
        _fileModule.applyStageFilePatch(PLAN_ID, ORDER_ID, replaceDigest, replacePatch, TARGET_EXECUTOR);

        FilePatch memory removePatch = _singleOpPatch(bytes32(0), bytes32(0), _remove(KEY));
        bytes32 removeDigest = _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, removePatch);
        vm.expectRevert(abi.encodeWithSelector(UVPFileResourceModule.FileKeyMissing.selector, KEY));
        _fileModule.applyStageFilePatch(PLAN_ID, ORDER_ID, removeDigest, removePatch, TARGET_EXECUTOR);
    }

    function testReplaceAndRemoveRewriteTheView() public {
        _apply(_singleOpPatch(bytes32(0), bytes32(0), _add(KEY, CONTENT_HASH_1, "uvp://file/one")), TARGET_EXECUTOR);

        bytes32 firstFilesHash = _fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE);
        _apply(
            _singleOpPatch(firstFilesHash, bytes32(0), _replace(KEY, CONTENT_HASH_2, "uvp://file/two")), TARGET_EXECUTOR
        );
        (bool replaced, bytes32 replacedHash, string memory replacedHandle,) =
            _fileModule.getStageFile(PLAN_ID, ORDER_ID, TARGET_STAGE, KEY);
        require(replaced, "replace removed key");
        require(replacedHash == CONTENT_HASH_2, "replaced content hash");
        require(keccak256(bytes(replacedHandle)) == keccak256(bytes("uvp://file/two")), "replaced handle");

        bytes32 secondFilesHash = _fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE);
        _apply(_singleOpPatch(secondFilesHash, bytes32(0), _remove(KEY)), TARGET_EXECUTOR);
        (bool existsAfterRemove, bytes32 removedHash, string memory removedHandle,) =
            _fileModule.getStageFile(PLAN_ID, ORDER_ID, TARGET_STAGE, KEY);
        require(!existsAfterRemove, "remove kept key alive");
        require(removedHash == bytes32(0), "remove kept content hash");
        require(bytes(removedHandle).length == 0, "remove kept handle");
        require(
            _fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE) != secondFilesHash, "remove did not advance"
        );
    }

    function testBaseHashMustMatchCurrentFilesHash() public {
        _apply(_singleOpPatch(bytes32(0), bytes32(0), _add(KEY, CONTENT_HASH_1, "uvp://file/one")), TARGET_EXECUTOR);
        bytes32 currentFilesHash = _fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE);

        FilePatch memory stalePatch =
            _singleOpPatch(bytes32(0), bytes32(0), _replace(KEY, CONTENT_HASH_2, "uvp://file/two"));
        bytes32 staleDigest = _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, stalePatch);
        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.FileBaseHashMismatch.selector, currentFilesHash, bytes32(0))
        );
        _fileModule.applyStageFilePatch(PLAN_ID, ORDER_ID, staleDigest, stalePatch, TARGET_EXECUTOR);
    }

    function testFilesDigestMustMatchCanonicalPatch() public {
        FilePatch memory patch = _singleOpPatch(bytes32(0), bytes32(0), _add(KEY, CONTENT_HASH_1, "uvp://file/one"));
        bytes32 expectedDigest = _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, patch);

        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.FileDigestMismatch.selector, expectedDigest, WRONG_DIGEST)
        );
        _fileModule.applyStageFilePatch(PLAN_ID, ORDER_ID, WRONG_DIGEST, patch, TARGET_EXECUTOR);
    }

    function testDuplicatePatchIsAbsorbedWithoutStateOrLogs() public {
        FilePatch memory patch = _singleOpPatch(bytes32(0), bytes32(0), _add(KEY, CONTENT_HASH_1, "uvp://file/one"));
        _apply(patch, TARGET_EXECUTOR);
        bytes32 appliedFilesHash = _fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE);

        vm.recordLogs();
        _apply(patch, TARGET_EXECUTOR);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(logs.length == 0, "duplicate re-emitted events");
        require(
            _fileModule.stageFilesHash(PLAN_ID, ORDER_ID, TARGET_STAGE) == appliedFilesHash,
            "duplicate moved files hash"
        );
        (bool exists, bytes32 contentHash,,) = _fileModule.getStageFile(PLAN_ID, ORDER_ID, TARGET_STAGE, KEY);
        require(exists && contentHash == CONTENT_HASH_1, "duplicate rewrote key");
    }

    function testSelfWriterMustBeTargetStageExecutor() public {
        FilePatch memory patch = _singleOpPatch(bytes32(0), bytes32(0), _add(KEY, CONTENT_HASH_1, "uvp://file/one"));
        bytes32 digest = _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, patch);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector, ORDER_ID, TARGET_STAGE, bytes32(0), OUTSIDER
            )
        );
        _fileModule.applyStageFilePatch(PLAN_ID, ORDER_ID, digest, patch, OUTSIDER);
    }

    function testWriterStageRequiresCapabilityLeaf() public {
        _activeExecutors[WRITER_STAGE] = WRITER_EXECUTOR;
        FilePatch memory patch = _singleOpPatch(bytes32(0), WRITER_STAGE, _add(KEY, CONTENT_HASH_1, "uvp://file/one"));
        bytes32 digest = _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, patch);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.FileWriterUnauthorized.selector,
                ORDER_ID,
                TARGET_STAGE,
                WRITER_STAGE,
                WRITER_EXECUTOR
            )
        );
        _fileModule.applyStageFilePatch(PLAN_ID, ORDER_ID, digest, patch, WRITER_EXECUTOR);
    }

    function testWriterStageCapabilityAuthorizesWriterExecutor() public {
        _activeExecutors[WRITER_STAGE] = WRITER_EXECUTOR;
        _metadata.finalizePlanMetadata(
            PLAN_ID, _metadata.fileWriterLeaf(TARGET_STAGE, WRITER_STAGE), bytes32(0), bytes32(0)
        );
        FilePatch memory patch = _singleOpPatch(bytes32(0), WRITER_STAGE, _add(KEY, CONTENT_HASH_1, "uvp://file/one"));

        _apply(patch, WRITER_EXECUTOR);

        (bool exists, bytes32 contentHash,,) = _fileModule.getStageFile(PLAN_ID, ORDER_ID, TARGET_STAGE, KEY);
        require(exists && contentHash == CONTENT_HASH_1, "writer-stage patch not applied");
    }

    function _apply(FilePatch memory patch, address submitter) private {
        _fileModule.applyStageFilePatch(
            PLAN_ID, ORDER_ID, _fileModule.filePatchDigest(PLAN_ID, ORDER_ID, patch), patch, submitter
        );
    }

    function _singleOpPatch(bytes32 baseHash, bytes32 writerStageId, FileOp memory op)
        private
        pure
        returns (FilePatch memory patch)
    {
        FileOp[] memory ops = new FileOp[](1);
        ops[0] = op;
        patch = FilePatch({
            targetStageId: TARGET_STAGE,
            baseHash: baseHash,
            writerStageId: writerStageId,
            writerProof: new bytes32[](0),
            ops: ops
        });
    }

    function _add(bytes32 key, bytes32 contentHash, string memory handle) private pure returns (FileOp memory) {
        return FileOp({kind: uint8(FileOpKind.Add), key: key, contentHash: contentHash, handle: handle});
    }

    function _replace(bytes32 key, bytes32 contentHash, string memory handle) private pure returns (FileOp memory) {
        return FileOp({kind: uint8(FileOpKind.Replace), key: key, contentHash: contentHash, handle: handle});
    }

    function _remove(bytes32 key) private pure returns (FileOp memory) {
        return FileOp({kind: uint8(FileOpKind.Remove), key: key, contentHash: bytes32(0), handle: ""});
    }
}
