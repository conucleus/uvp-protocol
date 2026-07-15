// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract UVPIdentityRegistry {
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
    error BindingAlreadyRevoked(bytes32 bindingId);
    error EmptyDescriptorURI();
    error NotOwner();
    error UnknownIdentityBinding(bytes32 bindingId);
    error ZeroAccount();
    error ZeroDescriptorHash();
    error ZeroOwner();
    error ZeroSubjectId();

    bytes32 private constant _BINDING_ID_DOMAIN = keccak256("uvp.identity.binding.v1");

    address public owner;
    uint256 public bindingNonce;

    mapping(bytes32 bindingId => IdentityBinding binding) private _bindings;
    mapping(address account => bytes32 bindingId) public activeBindingForAccount;

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
}
