// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ZhixuTrustRegistry {
    struct PlanAttestation {
        bytes32 planHash;
        bytes32 artifactHash;
        bytes32 policyHash;
        bytes32 metadataHash;
        string metadataURI;
        address attester;
        bool attested;
        bool revoked;
        bytes32 revokeReasonHash;
        string revokeReasonURI;
    }

    struct SupplierAttestation {
        address wallet;
        bytes32 profileHash;
        bytes32 capabilityHash;
        bytes32 reputationHash;
        string metadataURI;
        address attester;
        bool attested;
        bool revoked;
        bytes32 revokeReasonHash;
        string revokeReasonURI;
    }

    error NotOwner();
    error UnknownPlanAttestation();
    error UnknownSupplierAttestation();
    error ZeroPlanId();
    error ZeroSupplierSubjectId();
    error ZeroOwner();
    error ZeroWallet();
    error ZeroPlanHash();
    error ZeroArtifactHash();
    error ZeroPolicyHash();
    error ZeroMetadataHash();
    error ZeroProfileHash();
    error ZeroCapabilityHash();
    error ZeroReputationHash();

    address public owner;

    mapping(bytes32 planId => PlanAttestation attestation) private _planAttestations;
    mapping(bytes32 supplierSubjectId => SupplierAttestation attestation) private _supplierAttestations;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PlanAttested(
        bytes32 indexed planId,
        bytes32 indexed planHash,
        bytes32 artifactHash,
        bytes32 policyHash,
        bytes32 metadataHash,
        string metadataURI,
        address attester
    );
    event PlanRevoked(bytes32 indexed planId, bytes32 reasonHash, string reasonURI, address revoker);
    event SupplierAttested(
        bytes32 indexed supplierSubjectId,
        address indexed wallet,
        bytes32 profileHash,
        bytes32 capabilityHash,
        bytes32 reputationHash,
        string metadataURI,
        address attester
    );
    event SupplierRevoked(bytes32 indexed supplierSubjectId, bytes32 reasonHash, string reasonURI, address revoker);

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

    function attestPlan(
        bytes32 planId,
        bytes32 planHash,
        bytes32 artifactHash,
        bytes32 policyHash,
        bytes32 metadataHash,
        string calldata metadataURI
    ) external onlyOwner {
        if (planId == bytes32(0)) {
            revert ZeroPlanId();
        }
        if (planHash == bytes32(0)) {
            revert ZeroPlanHash();
        }
        if (artifactHash == bytes32(0)) {
            revert ZeroArtifactHash();
        }
        if (policyHash == bytes32(0)) {
            revert ZeroPolicyHash();
        }
        _requireNonZeroMetadataHash(metadataHash);

        PlanAttestation storage attestation = _planAttestations[planId];
        attestation.planHash = planHash;
        attestation.artifactHash = artifactHash;
        attestation.policyHash = policyHash;
        attestation.metadataHash = metadataHash;
        attestation.metadataURI = metadataURI;
        attestation.attester = msg.sender;
        attestation.attested = true;
        attestation.revoked = false;
        attestation.revokeReasonHash = bytes32(0);
        attestation.revokeReasonURI = "";

        emit PlanAttested(planId, planHash, artifactHash, policyHash, metadataHash, metadataURI, msg.sender);
    }

    function revokePlan(bytes32 planId, bytes32 reasonHash, string calldata reasonURI) external onlyOwner {
        PlanAttestation storage attestation = _planAttestations[planId];
        if (!attestation.attested) {
            revert UnknownPlanAttestation();
        }

        attestation.revoked = true;
        attestation.revokeReasonHash = reasonHash;
        attestation.revokeReasonURI = reasonURI;

        emit PlanRevoked(planId, reasonHash, reasonURI, msg.sender);
    }

    function attestSupplier(
        bytes32 supplierSubjectId,
        address wallet,
        bytes32 profileHash,
        bytes32 capabilityHash,
        bytes32 reputationHash,
        string calldata metadataURI
    ) external onlyOwner {
        if (supplierSubjectId == bytes32(0)) {
            revert ZeroSupplierSubjectId();
        }
        if (wallet == address(0)) {
            revert ZeroWallet();
        }
        if (profileHash == bytes32(0)) {
            revert ZeroProfileHash();
        }
        if (capabilityHash == bytes32(0)) {
            revert ZeroCapabilityHash();
        }
        if (reputationHash == bytes32(0)) {
            revert ZeroReputationHash();
        }

        SupplierAttestation storage attestation = _supplierAttestations[supplierSubjectId];
        attestation.wallet = wallet;
        attestation.profileHash = profileHash;
        attestation.capabilityHash = capabilityHash;
        attestation.reputationHash = reputationHash;
        attestation.metadataURI = metadataURI;
        attestation.attester = msg.sender;
        attestation.attested = true;
        attestation.revoked = false;
        attestation.revokeReasonHash = bytes32(0);
        attestation.revokeReasonURI = "";

        emit SupplierAttested(
            supplierSubjectId, wallet, profileHash, capabilityHash, reputationHash, metadataURI, msg.sender
        );
    }

    function revokeSupplier(bytes32 supplierSubjectId, bytes32 reasonHash, string calldata reasonURI)
        external
        onlyOwner
    {
        SupplierAttestation storage attestation = _supplierAttestations[supplierSubjectId];
        if (!attestation.attested) {
            revert UnknownSupplierAttestation();
        }

        attestation.revoked = true;
        attestation.revokeReasonHash = reasonHash;
        attestation.revokeReasonURI = reasonURI;

        emit SupplierRevoked(supplierSubjectId, reasonHash, reasonURI, msg.sender);
    }

    function getPlanAttestation(bytes32 planId)
        external
        view
        returns (
            bytes32 planHash,
            bytes32 artifactHash,
            bytes32 policyHash,
            bytes32 metadataHash,
            string memory metadataURI,
            address attester,
            bool attested,
            bool revoked,
            bytes32 revokeReasonHash,
            string memory revokeReasonURI
        )
    {
        PlanAttestation storage attestation = _planAttestations[planId];
        return (
            attestation.planHash,
            attestation.artifactHash,
            attestation.policyHash,
            attestation.metadataHash,
            attestation.metadataURI,
            attestation.attester,
            attestation.attested,
            attestation.revoked,
            attestation.revokeReasonHash,
            attestation.revokeReasonURI
        );
    }

    function isPlanActive(bytes32 planId, bytes32 planHash) external view returns (bool) {
        PlanAttestation storage attestation = _planAttestations[planId];
        return attestation.attested && !attestation.revoked && attestation.planHash == planHash;
    }

    function isPlanRevoked(bytes32 planId) external view returns (bool) {
        return _planAttestations[planId].revoked;
    }

    function getPlanHashes(bytes32 planId)
        external
        view
        returns (bytes32 planHash, bytes32 artifactHash, bytes32 policyHash)
    {
        PlanAttestation storage attestation = _planAttestations[planId];
        return (attestation.planHash, attestation.artifactHash, attestation.policyHash);
    }

    function getSupplierAttestation(bytes32 supplierSubjectId)
        external
        view
        returns (
            address wallet,
            bytes32 profileHash,
            bytes32 capabilityHash,
            bytes32 reputationHash,
            string memory metadataURI,
            address attester,
            bool attested,
            bool revoked,
            bytes32 revokeReasonHash,
            string memory revokeReasonURI
        )
    {
        SupplierAttestation storage attestation = _supplierAttestations[supplierSubjectId];
        return (
            attestation.wallet,
            attestation.profileHash,
            attestation.capabilityHash,
            attestation.reputationHash,
            attestation.metadataURI,
            attestation.attester,
            attestation.attested,
            attestation.revoked,
            attestation.revokeReasonHash,
            attestation.revokeReasonURI
        );
    }

    function isSupplierActive(bytes32 supplierSubjectId) external view returns (bool) {
        SupplierAttestation storage attestation = _supplierAttestations[supplierSubjectId];
        return attestation.attested && !attestation.revoked;
    }

    function _requireNonZeroMetadataHash(bytes32 metadataHash) private pure {
        if (metadataHash == bytes32(0)) {
            revert ZeroMetadataHash();
        }
    }
}
