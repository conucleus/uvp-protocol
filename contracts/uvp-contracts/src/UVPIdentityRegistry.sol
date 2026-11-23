// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPIdentityRegistry} from "./interfaces/IUVPIdentityRegistry.sol";

// Single on-chain identity boundary. Owner-gated subject/account bindings are
// the trust-attestation surface; supplier capability/account bindings are the
// execution-identity source the state machine resolves stage authority through.
// The two namespaces share one owner but never authorize each other: an
// identity binding grants no execution authority, and a supplier status grants
// no off-chain subject claim.
contract UVPIdentityRegistry is IUVPIdentityRegistry {
    struct IdentityBinding {
        bytes32 subjectId;
        address account;
        bytes32 descriptorHash;
        string descriptorURI;
        address registrar;
        bool registered;
        bool revoked;
        bytes32 revokeReasonHash;
        string revokeReasonURI;
    }

    error AccountAlreadyBound(address account, bytes32 bindingId);
    error AccountAlreadyRegistered(address account, bytes32 supplierId);
    error BindingAlreadyRevoked(bytes32 bindingId);
    error CallerNotAccount(address caller, address account);
    error EmptyDescriptorURI();
    error InvalidSupplierStatusTransition(bytes32 supplierId, SupplierStatus currentStatus, SupplierStatus nextStatus);
    error NotOwner();
    error NotRegistrar();
    error UnknownIdentityBinding(bytes32 bindingId);
    error UnknownSupplier(bytes32 supplierId);
    error ZeroAccount();
    error ZeroDescriptorHash();
    error ZeroOwner();
    error ZeroSubjectId();

    bytes32 private constant _BINDING_ID_DOMAIN = keccak256("uvp.identity.binding.v1");

    address public owner;
    uint256 public bindingNonce;

    mapping(bytes32 bindingId => IdentityBinding binding) private _bindings;
    mapping(address account => bytes32 bindingId) public activeBindingForAccount;

    mapping(bytes32 supplierId => address account) private _accountOf;
    mapping(address account => bytes32 supplierId) private _supplierOf;
    mapping(bytes32 supplierId => SupplierStatus status) private _statusOf;
    mapping(address registrar => bool allowed) private _registrars;
    uint256 private _uuidNonce;

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

    modifier onlyRegistrar() {
        if (msg.sender != owner && !_registrars[msg.sender]) {
            revert NotRegistrar();
        }
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroOwner();
        }
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function registerIdentityBinding(
        bytes32 subjectId,
        address account,
        bytes32 descriptorHash,
        string calldata descriptorURI
    ) external onlyOwner returns (bytes32 bindingId) {
        if (subjectId == bytes32(0)) {
            revert ZeroSubjectId();
        }
        if (account == address(0)) {
            revert ZeroAccount();
        }
        if (descriptorHash == bytes32(0)) {
            revert ZeroDescriptorHash();
        }
        if (bytes(descriptorURI).length == 0) {
            revert EmptyDescriptorURI();
        }
        bytes32 activeBindingId = activeBindingForAccount[account];
        if (activeBindingId != bytes32(0)) {
            revert AccountAlreadyBound(account, activeBindingId);
        }

        uint256 nonce = ++bindingNonce;
        bindingId = keccak256(
            abi.encode(_BINDING_ID_DOMAIN, block.chainid, address(this), nonce, subjectId, account, descriptorHash)
        );
        _bindings[bindingId] = IdentityBinding({
            subjectId: subjectId,
            account: account,
            descriptorHash: descriptorHash,
            descriptorURI: descriptorURI,
            registrar: msg.sender,
            registered: true,
            revoked: false,
            revokeReasonHash: bytes32(0),
            revokeReasonURI: ""
        });
        activeBindingForAccount[account] = bindingId;

        emit IdentityBindingRegistered(bindingId, subjectId, account, descriptorHash, descriptorURI, msg.sender);
    }

    function revokeIdentityBinding(bytes32 bindingId, bytes32 reasonHash, string calldata reasonURI)
        external
        onlyOwner
    {
        IdentityBinding storage binding = _bindings[bindingId];
        if (!binding.registered) {
            revert UnknownIdentityBinding(bindingId);
        }
        if (binding.revoked) {
            revert BindingAlreadyRevoked(bindingId);
        }

        binding.revoked = true;
        binding.revokeReasonHash = reasonHash;
        binding.revokeReasonURI = reasonURI;
        if (activeBindingForAccount[binding.account] == bindingId) {
            delete activeBindingForAccount[binding.account];
        }

        emit IdentityBindingRevoked(bindingId, reasonHash, reasonURI, msg.sender);
    }

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
        )
    {
        IdentityBinding storage binding = _bindings[bindingId];
        return (
            binding.subjectId,
            binding.account,
            binding.descriptorHash,
            binding.descriptorURI,
            binding.registrar,
            binding.registered,
            binding.revoked,
            binding.revokeReasonHash,
            binding.revokeReasonURI
        );
    }

    function registerSupplier(address account) external returns (bytes32 supplierId) {
        if (msg.sender != account) {
            revert CallerNotAccount(msg.sender, account);
        }
        bytes32 existingSupplierId = _supplierOf[account];
        if (existingSupplierId != bytes32(0)) {
            revert AccountAlreadyRegistered(account, existingSupplierId);
        }
        supplierId = _mintSupplierId(account);
        _accountOf[supplierId] = account;
        _supplierOf[account] = supplierId;
        emit SupplierRegistered(supplierId, account);
    }

    function activateSupplier(bytes32 supplierId) external onlyRegistrar {
        SupplierStatus currentStatus = _requireSupplier(supplierId);
        if (currentStatus != SupplierStatus.Pending && currentStatus != SupplierStatus.Suspended) {
            revert InvalidSupplierStatusTransition(supplierId, currentStatus, SupplierStatus.Active);
        }
        _applyStatus(supplierId, currentStatus, SupplierStatus.Active);
    }

    function suspendSupplier(bytes32 supplierId) external onlyRegistrar {
        SupplierStatus currentStatus = _requireSupplier(supplierId);
        if (currentStatus != SupplierStatus.Active) {
            revert InvalidSupplierStatusTransition(supplierId, currentStatus, SupplierStatus.Suspended);
        }
        _applyStatus(supplierId, currentStatus, SupplierStatus.Suspended);
    }

    function revokeSupplier(bytes32 supplierId) external onlyRegistrar {
        SupplierStatus currentStatus = _requireSupplier(supplierId);
        if (currentStatus == SupplierStatus.Revoked) {
            revert InvalidSupplierStatusTransition(supplierId, currentStatus, SupplierStatus.Revoked);
        }
        _applyStatus(supplierId, currentStatus, SupplierStatus.Revoked);
    }

    function setRegistrar(address registrar, bool allowed) external onlyOwner {
        _registrars[registrar] = allowed;
        emit SupplierRegistrarSet(registrar, allowed);
    }

    function accountOf(bytes32 supplierId) external view returns (address) {
        return _accountOf[supplierId];
    }

    function statusOf(bytes32 supplierId) external view returns (SupplierStatus) {
        return _requireSupplier(supplierId);
    }

    function isActiveSupplier(bytes32 supplierId) external view returns (bool) {
        return _accountOf[supplierId] != address(0) && _statusOf[supplierId] == SupplierStatus.Active;
    }

    function supplierOf(address account) external view returns (bytes32) {
        return _supplierOf[account];
    }

    function _applyStatus(bytes32 supplierId, SupplierStatus currentStatus, SupplierStatus newStatus) private {
        _statusOf[supplierId] = newStatus;
        emit SupplierStatusChanged(supplierId, currentStatus, newStatus, _accountOf[supplierId]);
    }

    function _requireSupplier(bytes32 supplierId) private view returns (SupplierStatus) {
        if (_accountOf[supplierId] == address(0)) {
            revert UnknownSupplier(supplierId);
        }
        return _statusOf[supplierId];
    }

    function _mintSupplierId(address account) private returns (bytes32 supplierId) {
        uint256 nonce = _uuidNonce;
        while (true) {
            uint256 entropy = uint256(keccak256(abi.encodePacked(account, block.prevrandao, block.timestamp, nonce)));
            uint128 uuid = uint128(entropy);
            // The store formats this value as a standard 36-character UUID, so
            // the v4 version nibble and RFC 4122 variant bits are part of the
            // on-chain output contract.
            uuid = (uuid & ~(uint128(0xf) << 76)) | (uint128(0x4) << 76);
            uuid = (uuid & ~(uint128(0x3) << 62)) | (uint128(0x2) << 62);
            supplierId = bytes32(uint256(uuid));
            if (_accountOf[supplierId] == address(0)) {
                _uuidNonce = nonce + 1;
                return supplierId;
            }
            unchecked {
                ++nonce;
            }
        }
    }
}
