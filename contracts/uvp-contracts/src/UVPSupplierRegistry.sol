// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPSupplierRegistry} from "./interfaces/IUVPSupplierRegistry.sol";

// Supplier identity registry: permissionless self-registration mints the SID
// and binds the caller's account permanently; only registrar-gated status
// changes follow. This registry is the sole on-chain execution identity — the
// state machine resolves every stage's submitting account here
// (`accountOf` + `active` status), so no other registry participates in
// execution authorization. UUID minting and its encoding live here as the
// single source; off-chain layers only format the low 16 bytes as a UUID
// string.
contract UVPSupplierRegistry is IUVPSupplierRegistry {
    error AccountAlreadyRegistered(address account, bytes32 supplierId);
    error CallerNotAccount(address caller, address account);
    error InvalidSupplierStatusTransition(bytes32 supplierId, SupplierStatus currentStatus, SupplierStatus nextStatus);
    error NotOwner();
    error NotRegistrar();
    error UnknownSupplier(bytes32 supplierId);
    error ZeroOwner();

    address public owner;

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

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroOwner();
        }
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
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
            // Why: the store formats this value as a standard 36-character UUID,
            // so the v4 version nibble and RFC 4122 variant bits are part of the
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
