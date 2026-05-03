// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library UVPSignatures {
    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
}
