// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StageFile} from "../src/interfaces/IUVPFileResourceModule.sol";

function emptyStageFiles() pure returns (StageFile[] memory files) {
    files = new StageFile[](0);
}
