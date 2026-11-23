// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Single on-chain identity boundary: owner-gated off-chain subject/account
// bindings plus the supplier capability/account registry that the state machine
// resolves execution authority through. A supplierId is a chain-minted UUID in
// the low 16 bytes of a bytes32 and is permanently bound to exactly one
// supplier account; only the account itself may mint it, and only a registrar
// may move its status.
interface IUVPIdentityRegistry {
    enum SupplierStatus {
        Pending,
        Active,
        Suspended,
        Revoked
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event IdentityBindingRegistered(
        bytes32 indexed bindingId,
        bytes32 indexed subjectId,
        address indexed account,
        bytes32 descriptorHash,
        string descriptorURI,
        address registrar
    );
    event IdentityBindingRevoked(bytes32 indexed bindingId, bytes32 reasonHash, string reasonURI, address revoker);
    event SupplierRegistered(bytes32 indexed supplierId, address indexed account);
    event SupplierStatusChanged(
        bytes32 indexed supplierId,
        SupplierStatus previousStatus,
        SupplierStatus newStatus,
        address indexed account
    );
    event SupplierRegistrarSet(address indexed registrar, bool allowed);

    function owner() external view returns (address);

    function bindingNonce() external view returns (uint256);

    function activeBindingForAccount(address account) external view returns (bytes32);

    function registerIdentityBinding(
        bytes32 subjectId,
        address account,
        bytes32 descriptorHash,
        string calldata descriptorURI
    ) external returns (bytes32 bindingId);

    function revokeIdentityBinding(bytes32 bindingId, bytes32 reasonHash, string calldata reasonURI) external;

    function getIdentityBinding(bytes32 bindingId)
        external
        view
        returns (
            bytes32 subjectId,
            address account,
            bytes32 descriptorHash,
            string memory descriptorURI,
            address registrar,
            bool registered,
            bool revoked,
            bytes32 revokeReasonHash,
            string memory revokeReasonURI
        );

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
