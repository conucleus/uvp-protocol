// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPFileResourceModule} from "../src/UVPFileResourceModule.sol";
import {FileOp, FileOpKind, FilePatch} from "../src/interfaces/IUVPFileResourceModule.sol";

// Parity probe (CODE-STYLE-PROHIBITIONS §8, Lead-approved §10 intent "golden matches Solidity mirror"):
// Compares two independent facts: protocol-bindings' TypeScript `filePatchDigest` golden vector
// (fixtures/file-patch-digest/v1/vectors.json, owner T4) and the Solidity mirror
// UVPFileResourceModule.filePatchDigest.
// Cannot be single-sourced: Solidity and TypeScript cannot share one encoder implementation.
// Cannot be generated: Foundry cannot execute the TS encoder at build time without FFI.
// Owner: protocol-bindings owns the canonical file-patch encoding; this test only pins the Solidity mirror.
// Delete when: the canonical encoding becomes a shared generated artifact or an on-chain-owned encoding.
contract UVPFilePatchDigestParityTest {
    bytes32 private constant PLAN_ID = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes32 private constant ORDER_ID = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes32 private constant TARGET_STAGE_ID = 0x3333333333333333333333333333333333333333333333333333333333333333;
    bytes32 private constant BASE_HASH = 0x4444444444444444444444444444444444444444444444444444444444444444;
    bytes32 private constant WRITER_STAGE_ID = 0x5555555555555555555555555555555555555555555555555555555555555555;
    bytes32 private constant WRITER_PROOF_SIBLING = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes32 private constant KEY = 0x6666666666666666666666666666666666666666666666666666666666666666;
    bytes32 private constant CONTENT_ONE = 0x7777777777777777777777777777777777777777777777777777777777777777;
    bytes32 private constant CONTENT_TWO = 0x8888888888888888888888888888888888888888888888888888888888888888;
    bytes32 private constant REMOVED_KEY = 0x9999999999999999999999999999999999999999999999999999999999999999;
    bytes32 private constant EXPECTED_FILES_DIGEST = 0xf30fc5e3e7fb3dca2520502a5d9466b29f5a998f333ac3816f684396a990208c;

    function testSolidityMirrorMatchesProtocolBindingsGoldenVector() public {
        UVPFileResourceModule fileModule = new UVPFileResourceModule(address(this));

        FileOp[] memory ops = new FileOp[](3);
        ops[0] = FileOp({kind: uint8(FileOpKind.Add), key: KEY, contentHash: CONTENT_ONE, handle: "uvp://file/one"});
        ops[1] = FileOp({kind: uint8(FileOpKind.Replace), key: KEY, contentHash: CONTENT_TWO, handle: "uvp://file/two"});
        ops[2] = FileOp({kind: uint8(FileOpKind.Remove), key: REMOVED_KEY, contentHash: bytes32(0), handle: ""});

        bytes32[] memory writerProof = new bytes32[](1);
        writerProof[0] = WRITER_PROOF_SIBLING;

        FilePatch memory patch = FilePatch({
            targetStageId: TARGET_STAGE_ID,
            baseHash: BASE_HASH,
            writerStageId: WRITER_STAGE_ID,
            writerProof: writerProof,
            ops: ops
        });

        require(
            fileModule.filePatchDigest(PLAN_ID, ORDER_ID, patch) == EXPECTED_FILES_DIGEST,
            "filePatchDigest diverges from protocol-bindings golden vector"
        );
    }
}
