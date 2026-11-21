// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPSupplierRegistry} from "./interfaces/IUVPSupplierRegistry.sol";

// QA-only supplier registry for local/QA flows. Production deployments must
// never wire this contract; production uses UVPSupplierRegistry.
contract UVPSupplierRegistryQa is IUVPSupplierRegistry {
    error AccountAlreadyRegistered(address account, bytes32 supplierId);
    error CallerNotAccount(address caller, address account);
    error InvalidSupplierStatusTransition(bytes32 supplierId, SupplierStatus currentStatus, SupplierStatus nextStatus);
    error NotOwner();
    error RegistrarNotSupported();
    error UnknownSupplier(bytes32 supplierId);
    error ZeroOwner();

    address public owner;

    mapping(bytes32 supplierId => address account) private _accountOf;
    mapping(address account => bytes32 supplierId) private _supplierOf;
    mapping(bytes32 supplierId => SupplierStatus status) private _statusOf;
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
        // Why: event replay seeds SupplierRegistered as Pending, so the immediate
        // Active status must be emitted as that transition or projections disagree
        // with statusOf.
        _applyStatus(supplierId, SupplierStatus.Pending, SupplierStatus.Active);
    }

    function activateSupplier(bytes32 supplierId) external {
        SupplierStatus currentStatus = _requireSupplier(supplierId);
        if (currentStatus == SupplierStatus.Active) {
            return;
        }
        if (currentStatus == SupplierStatus.Revoked) {
            revert InvalidSupplierStatusTransition(supplierId, currentStatus, SupplierStatus.Active);
        }
        _applyStatus(supplierId, currentStatus, SupplierStatus.Active);
    }

    function suspendSupplier(bytes32 supplierId) external {
        SupplierStatus currentStatus = _requireSupplier(supplierId);
        if (currentStatus != SupplierStatus.Active) {
            revert InvalidSupplierStatusTransition(supplierId, currentStatus, SupplierStatus.Suspended);
        }
        _applyStatus(supplierId, currentStatus, SupplierStatus.Suspended);
    }

    function revokeSupplier(bytes32 supplierId) external {
        SupplierStatus currentStatus = _requireSupplier(supplierId);
        if (currentStatus == SupplierStatus.Revoked) {
            revert InvalidSupplierStatusTransition(supplierId, currentStatus, SupplierStatus.Revoked);
        }
        _applyStatus(supplierId, currentStatus, SupplierStatus.Revoked);
    }

    function setRegistrar(address, bool) external pure {
        revert RegistrarNotSupported();
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
        // Why: SID formatting (v4 version nibble + RFC 4122 variant in the low
        // 128 bits) duplicates UVPSupplierRegistry's mint contract; keep both in
        // sync until the mint has one shared source.
        while (true) {
            uint256 entropy = uint256(keccak256(abi.encodePacked(account, block.prevrandao, block.timestamp, nonce)));
            uint128 uuid = uint128(entropy);
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
