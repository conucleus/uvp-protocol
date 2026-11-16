// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Supplier identity boundary: a supplierId is a chain-minted UUID carried in the
// low 16 bytes of a bytes32 and is permanently bound to exactly one supplier
// account. Status gates formal use; the bound account is never written again.
interface IUVPSupplierRegistry {
    enum SupplierStatus {
        Pending,
        Active,
        Suspended,
        Revoked
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SupplierRegistered(bytes32 indexed supplierId, address indexed account);
    event SupplierStatusChanged(
        bytes32 indexed supplierId,
        SupplierStatus previousStatus,
        SupplierStatus newStatus,
        address indexed account
    );
    event SupplierRegistrarSet(address indexed registrar, bool allowed);

    function registerSupplier(address account) external returns (bytes32 supplierId);

    function activateSupplier(bytes32 supplierId) external;

    function suspendSupplier(bytes32 supplierId) external;

    function revokeSupplier(bytes32 supplierId) external;

    function setRegistrar(address registrar, bool allowed) external;

    function transferOwnership(address newOwner) external;

    function accountOf(bytes32 supplierId) external view returns (address);

    function statusOf(bytes32 supplierId) external view returns (SupplierStatus);

    function isActiveSupplier(bytes32 supplierId) external view returns (bool);

    function supplierOf(address account) external view returns (bytes32);
}
