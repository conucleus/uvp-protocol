// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {StageFile, StageFilesEmpty} from "../src/interfaces/IUVPFileResourceModule.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract UVPFileResourceModuleTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant PLAN_ID = keccak256("plan");
    bytes32 private constant ORDER_ID = keccak256("order");
    bytes32 private constant TARGET_STAGE = keccak256("target");
    bytes32 private constant OTHER_STAGE = keccak256("other");

    address private constant TARGET_ACCOUNT = address(uint160(0xa11ce));
    address private constant WRITER_ACCOUNT = address(uint160(0xb0b));
    address private constant OUTSIDER = address(uint160(0xbad));

    UVPFileResourceModule private _fileModule;
    mapping(address account => bool authorized) private _authorized;

    function setUp() public {
        _fileModule = new UVPFileResourceModule(address(this));
        _authorized[TARGET_ACCOUNT] = true;
        _authorized[WRITER_ACCOUNT] = true;
    }

    function orderExists(bytes32, bytes32) external pure returns (bool) {
        return true;
    }

    function isPlanStage(bytes32, bytes32 stageId) external pure returns (bool) {
        return stageId == TARGET_STAGE;
    }

    function isAuthorizedFileWriter(bytes32, bytes32, bytes32, address account) external view returns (bool) {
        return _authorized[account];
    }

    function testWritesAndReadsOpaquePayload() public {
        _apply(_singleFile("uvp://file/one", bytes("payload-one")), TARGET_ACCOUNT);

        (bool exists, bytes memory payload) =
            _fileModule.getStageFile(PLAN_ID, ORDER_ID, TARGET_STAGE, "uvp://file/one");
        require(exists, "key not stored");
        require(keccak256(payload) == keccak256(bytes("payload-one")), "payload mismatch");
    }

    function testOverwritesExistingKeyWithoutOpsOrBaseHash() public {
        _apply(_singleFile("key", bytes("one")), TARGET_ACCOUNT);
        _apply(_singleFile("key", bytes("two")), TARGET_ACCOUNT);

        (bool exists, bytes memory payload) = _fileModule.getStageFile(PLAN_ID, ORDER_ID, TARGET_STAGE, "key");
        require(exists, "overwrite removed key");
        require(keccak256(payload) == keccak256(bytes("two")), "overwrite did not replace payload");
    }

    function testEmitsOneEventPerFile() public {
        StageFile[] memory files = new StageFile[](2);
        files[0] = StageFile({key: "a", payload: bytes("1")});
        files[1] = StageFile({key: "b", payload: bytes("2")});
        vm.recordLogs();
        _apply(files, WRITER_ACCOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("StageFileWritten(bytes32,bytes32,bytes32,string,bytes,address)");
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                count += 1;
            }
        }
        require(count == 2, "event count mismatch");
    }

    function testRejectsEmptyFiles() public {
        StageFile[] memory files = new StageFile[](0);
        vm.expectRevert(StageFilesEmpty.selector);
        _fileModule.applyStageFiles(PLAN_ID, ORDER_ID, TARGET_STAGE, files, TARGET_ACCOUNT, bytes32(0), new bytes32[](0));
    }

    function testRejectsMoreThanTheCap() public {
        StageFile[] memory files = new StageFile[](_fileModule.MAX_STAGE_FILES() + 1);
        for (uint256 i = 0; i < files.length; i++) {
            files[i] = StageFile({key: "key", payload: bytes("payload")});
        }
        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.StageFilesTooMany.selector, files.length)
        );
        _fileModule.applyStageFiles(PLAN_ID, ORDER_ID, TARGET_STAGE, files, TARGET_ACCOUNT, bytes32(0), new bytes32[](0));
    }

    function testRejectsUnknownTargetStage() public {
        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.FileTargetStageUnknown.selector, PLAN_ID, OTHER_STAGE)
        );
        _fileModule.applyStageFiles(
            PLAN_ID, ORDER_ID, OTHER_STAGE, _singleFile("key", bytes("payload")), TARGET_ACCOUNT,
            bytes32(0),
            new bytes32[](0)
        );
    }

    function testRejectsUnauthorizedWriter() public {
        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.FileWriterUnauthorized.selector, ORDER_ID, TARGET_STAGE, OUTSIDER)
        );
        _fileModule.applyStageFiles(
            PLAN_ID, ORDER_ID, TARGET_STAGE, _singleFile("key", bytes("payload")), OUTSIDER, bytes32(0), new bytes32[](0)
        );
    }

    function testRejectsEmptyKey() public {
        vm.expectRevert(UVPFileResourceModule.StageFileKeyEmpty.selector);
        _fileModule.applyStageFiles(
            PLAN_ID, ORDER_ID, TARGET_STAGE, _singleFile("", bytes("payload")), TARGET_ACCOUNT,
            bytes32(0),
            new bytes32[](0)
        );
    }

    function testRejectsOversizedKey() public {
        bytes memory keyBytes = new bytes(_fileModule.MAX_STAGE_FILE_KEY_BYTES() + 1);
        string memory key = string(keyBytes);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.StageFileKeyTooLong.selector, _fileModule.MAX_STAGE_FILE_KEY_BYTES() + 1
            )
        );
        _fileModule.applyStageFiles(
            PLAN_ID, ORDER_ID, TARGET_STAGE, _singleFile(key, bytes("payload")), TARGET_ACCOUNT,
            bytes32(0),
            new bytes32[](0)
        );
    }

    function testRejectsOversizedPayload() public {
        bytes memory payload = new bytes(_fileModule.MAX_STAGE_FILE_PAYLOAD_BYTES() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPFileResourceModule.StageFilePayloadTooLarge.selector,
                _fileModule.MAX_STAGE_FILE_PAYLOAD_BYTES() + 1
            )
        );
        _fileModule.applyStageFiles(
            PLAN_ID, ORDER_ID, TARGET_STAGE, _singleFile("key", payload), TARGET_ACCOUNT,
            bytes32(0),
            new bytes32[](0)
        );
    }

    function testOnlyStateMachineMayWrite() public {
        StageFile[] memory files = _singleFile("key", bytes("payload"));
        vm.expectRevert(
            abi.encodeWithSelector(UVPFileResourceModule.UnauthorizedStateMachine.selector, OUTSIDER)
        );
        vm.prank(OUTSIDER);
        _fileModule.applyStageFiles(PLAN_ID, ORDER_ID, TARGET_STAGE, files, TARGET_ACCOUNT, bytes32(0), new bytes32[](0));
    }

    function _apply(StageFile[] memory files, address submitter) private {
        _fileModule.applyStageFiles(PLAN_ID, ORDER_ID, TARGET_STAGE, files, submitter, bytes32(0), new bytes32[](0));
    }

    function _singleFile(string memory key, bytes memory payload) private pure returns (StageFile[] memory files) {
        files = new StageFile[](1);
        files[0] = StageFile({key: key, payload: payload});
    }
}
