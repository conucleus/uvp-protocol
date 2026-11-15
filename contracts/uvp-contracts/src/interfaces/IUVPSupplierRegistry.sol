// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUVPSupplierRegistry {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SupplierRegistered(bytes32 indexed supplierId, address indexed executor);
    event SupplierExecutorRotated(
        bytes32 indexed supplierId, address indexed previousExecutor, address indexed newExecutor
    );
    event SupplierRevoked(bytes32 indexed supplierId, address indexed executor);
    event SupplierRegistrarSet(address indexed registrar, bool allowed);

    function registerSupplier(bytes32 supplierId, address executor) external;

    function rotateSupplierExecutor(bytes32 supplierId, address newExecutor) external;

    function revokeSupplier(bytes32 supplierId) external;

    function setRegistrar(address registrar, bool allowed) external;

    function transferOwnership(address newOwner) external;

    function executorOf(bytes32 supplierId) external view returns (address);

    function supplierOf(address executor) external view returns (bytes32);

    function isRegisteredSupplier(bytes32 supplierId) external view returns (bool);
}
