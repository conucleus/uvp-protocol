// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPSupplierRegistry} from "./interfaces/IUVPSupplierRegistry.sol";

// QA-only boundary: every nonzero supplierId resolves to one fixed debug account
// and reads as active, so local flows need no self-registration or activation.
// There is deliberately no reverse index (one fixed account cannot be the
// reverse of every SID), and every write reverts instead of faking registration
// state. Production deployment scripts must never wire this contract.
contract UVPSupplierRegistryDebug is IUVPSupplierRegistry {
    error DebugRegistryIsReadOnly();
    error UnknownSupplier(bytes32 supplierId);
    error ZeroDebugAccount();

    address public immutable debugAccount;

    constructor(address debugAccount_) {
        if (debugAccount_ == address(0)) {
            revert ZeroDebugAccount();
        }
        debugAccount = debugAccount_;
    }

    function registerSupplier(address) external pure returns (bytes32) {
        revert DebugRegistryIsReadOnly();
    }

    function activateSupplier(bytes32) external pure {
        revert DebugRegistryIsReadOnly();
    }

    function suspendSupplier(bytes32) external pure {
        revert DebugRegistryIsReadOnly();
    }

    function revokeSupplier(bytes32) external pure {
        revert DebugRegistryIsReadOnly();
    }

    function setRegistrar(address, bool) external pure {
        revert DebugRegistryIsReadOnly();
    }

    function transferOwnership(address) external pure {
        revert DebugRegistryIsReadOnly();
    }

    function accountOf(bytes32 supplierId) external view returns (address) {
        return supplierId == bytes32(0) ? address(0) : debugAccount;
    }

    function statusOf(bytes32 supplierId) external view returns (SupplierStatus) {
        if (supplierId == bytes32(0)) {
            revert UnknownSupplier(supplierId);
        }
        return SupplierStatus.Active;
    }

    function isActiveSupplier(bytes32 supplierId) external pure returns (bool) {
        return supplierId != bytes32(0);
    }

    function supplierOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }
}
