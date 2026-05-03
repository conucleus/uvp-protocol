// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPSignatures} from "./UVPSignatures.sol";

library ECDSA {
    error InvalidSignature();
    error InvalidSignatureS(bytes32 s);
    error InvalidSignatureV(uint8 v);

    uint256 private constant _SECP256K1N_HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    function recover(bytes32 digest, UVPSignatures.Signature memory signature) internal pure returns (address signer) {
        if (uint256(signature.s) > _SECP256K1N_HALF_ORDER) {
            revert InvalidSignatureS(signature.s);
        }

        if (signature.v != 27 && signature.v != 28) {
            revert InvalidSignatureV(signature.v);
        }

        signer = ecrecover(digest, signature.v, signature.r, signature.s);
        if (signer == address(0)) {
            revert InvalidSignature();
        }
    }
}
