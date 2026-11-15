// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPSupplierRegistry} from "./interfaces/IUVPSupplierRegistry.sol";

contract UVPSupplierRegistry is IUVPSupplierRegistry {
    error ExecutorAlreadyBound(address executor, bytes32 supplierId);
    error NotOwner();
    error NotRegistrar();
    error SupplierAlreadyRegistered(bytes32 supplierId);
    error UnknownSupplier(bytes32 supplierId);
    error ZeroExecutor();
    error ZeroOwner();
    error ZeroSupplierId();

    address public owner;

    mapping(bytes32 supplierId => address executor) private _executorOfSupplier;
    mapping(address executor => bytes32 supplierId) private _supplierOfExecutor;
    mapping(address registrar => bool allowed) private _registrars;

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    modifier onlyOwnerOrRegistrar() {
        if (msg.sender != owner && !_registrars[msg.sender]) {
            revert NotRegistrar();
        }
        _;
    }

    function registerSupplier(bytes32 supplierId, address executor) external onlyOwnerOrRegistrar {
        if (supplierId == bytes32(0)) {
            revert ZeroSupplierId();
        }
        if (executor == address(0)) {
            revert ZeroExecutor();
        }
        if (_executorOfSupplier[supplierId] != address(0)) {
            revert SupplierAlreadyRegistered(supplierId);
        }
        bytes32 boundSupplierId = _supplierOfExecutor[executor];
        if (boundSupplierId != bytes32(0)) {
            revert ExecutorAlreadyBound(executor, boundSupplierId);
        }
        _executorOfSupplier[supplierId] = executor;
        _supplierOfExecutor[executor] = supplierId;
        emit SupplierRegistered(supplierId, executor);
    }

    function rotateSupplierExecutor(bytes32 supplierId, address newExecutor) external onlyOwnerOrRegistrar {
        address previousExecutor = _executorOfSupplier[supplierId];
        if (previousExecutor == address(0)) {
            revert UnknownSupplier(supplierId);
        }
        if (newExecutor == address(0)) {
            revert ZeroExecutor();
        }
        bytes32 boundSupplierId = _supplierOfExecutor[newExecutor];
        if (boundSupplierId != bytes32(0)) {
            revert ExecutorAlreadyBound(newExecutor, boundSupplierId);
        }
        _executorOfSupplier[supplierId] = newExecutor;
        _supplierOfExecutor[newExecutor] = supplierId;
        delete _supplierOfExecutor[previousExecutor];
        emit SupplierExecutorRotated(supplierId, previousExecutor, newExecutor);
    }

    function revokeSupplier(bytes32 supplierId) external onlyOwnerOrRegistrar {
        address executor = _executorOfSupplier[supplierId];
        if (executor == address(0)) {
            revert UnknownSupplier(supplierId);
        }
        delete _executorOfSupplier[supplierId];
        delete _supplierOfExecutor[executor];
        emit SupplierRevoked(supplierId, executor);
    }

    function setRegistrar(address registrar, bool allowed) external onlyOwner {
        _registrars[registrar] = allowed;
        emit SupplierRegistrarSet(registrar, allowed);
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
        return _executorOfSupplier[supplierId];
    }

    function supplierOf(address executor) external view returns (bytes32) {
        return _supplierOfExecutor[executor];
    }

    function isRegisteredSupplier(bytes32 supplierId) external view returns (bool) {
        return _executorOfSupplier[supplierId] != address(0);
    }
}
