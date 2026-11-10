// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FileOp, FilePatch} from "../src/interfaces/IUVPFileResourceModule.sol";

function emptyFilePatch() pure returns (FilePatch memory patch) {
    patch.ops = new FileOp[](0);
}
