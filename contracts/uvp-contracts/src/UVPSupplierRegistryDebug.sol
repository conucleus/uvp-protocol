// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPSupplierRegistry} from "./interfaces/IUVPSupplierRegistry.sol";

// QA-only boundary: every nonzero supplierId reads as registered so local flows
// need no registrar step. Production deployment scripts must never wire this
// contract; production uses UVPSupplierRegistry.
contract UVPSupplierRegistryDebug is IUVPSupplierRegistry {
    error NotOwner();
    error ZeroExecutor();
    error ZeroOwner();
    error ZeroSupplierId();

    address public owner;
    address public immutable debugExecutor;

    mapping(bytes32 supplierId => address executor) private _explicitExecutor;
    mapping(address executor => bytes32 supplierId) private _explicitSupplier;

    constructor(address debugExecutor_) {
        if (debugExecutor_ == address(0)) {
            revert ZeroExecutor();
        }
        owner = msg.sender;
        debugExecutor = debugExecutor_;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    function debugSetExecutor(bytes32 supplierId, address executor) external onlyOwner {
        if (supplierId == bytes32(0)) {
            revert ZeroSupplierId();
        }
        if (executor == address(0)) {
            revert ZeroExecutor();
        }
        address previousExecutor = _explicitExecutor[supplierId];
        if (previousExecutor != address(0) && _explicitSupplier[previousExecutor] == supplierId) {
            delete _explicitSupplier[previousExecutor];
        }
        _explicitExecutor[supplierId] = executor;
        _explicitSupplier[executor] = supplierId;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroOwner();
        }
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function executorOf(bytes32 supplierId) external view returns (address) {
        if (supplierId == bytes32(0)) {
            return address(0);
        }
        address explicitExecutor = _explicitExecutor[supplierId];
        if (explicitExecutor != address(0)) {
            return explicitExecutor;
        }
        return debugExecutor;
    }

    function supplierOf(address executor) external view returns (bytes32) {
        return _explicitSupplier[executor];
    }

    function isRegisteredSupplier(bytes32 supplierId) external view returns (bool) {
        return supplierId != bytes32(0);
    }

    function registerSupplier(bytes32, address) external {}

    function rotateSupplierExecutor(bytes32, address) external {}

    function revokeSupplier(bytes32) external {}

    function setRegistrar(address, bool) external onlyOwner {}
}
