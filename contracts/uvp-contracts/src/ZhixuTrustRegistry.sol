// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ZhixuTrustRegistry {
    struct TrustDomain {
        address owner;
        bytes32 metadataHash;
        string metadataURI;
        bool exists;
    }

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

    error DomainAlreadyRegistered();
    error NotDomainOwner();
    error UnknownDomain();
    error UnknownPlanAttestation();
    error UnknownSupplierAttestation();
    error ZeroDomainId();
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

    mapping(bytes32 domainId => TrustDomain domain) private _domains;
    mapping(bytes32 domainId => mapping(bytes32 planId => PlanAttestation attestation)) private _planAttestations;
    mapping(bytes32 domainId => mapping(bytes32 supplierSubjectId => SupplierAttestation attestation)) private
        _supplierAttestations;

    event DomainRegistered(bytes32 indexed domainId, address indexed owner, bytes32 metadataHash, string metadataURI);
    event DomainUpdated(bytes32 indexed domainId, bytes32 metadataHash, string metadataURI);
    event DomainOwnerTransferred(bytes32 indexed domainId, address indexed previousOwner, address indexed newOwner);
    event PlanAttested(
        bytes32 indexed domainId,
        bytes32 indexed planId,
        bytes32 indexed planHash,
        bytes32 artifactHash,
        bytes32 policyHash,
        bytes32 metadataHash,
        string metadataURI,
        address attester
    );
    event PlanRevoked(
        bytes32 indexed domainId, bytes32 indexed planId, bytes32 reasonHash, string reasonURI, address revoker
    );
    event SupplierAttested(
        bytes32 indexed domainId,
        bytes32 indexed supplierSubjectId,
        address indexed wallet,
        bytes32 profileHash,
        bytes32 capabilityHash,
        bytes32 reputationHash,
        string metadataURI,
        address attester
    );
    event SupplierRevoked(
        bytes32 indexed domainId,
        bytes32 indexed supplierSubjectId,
        bytes32 reasonHash,
        string reasonURI,
        address revoker
    );

    modifier onlyDomainOwner(bytes32 domainId) {
        TrustDomain storage domain = _requireDomain(domainId);
        if (domain.owner != msg.sender) {
            revert NotDomainOwner();
        }
        _;
    }

    function registerDomain(bytes32 domainId, bytes32 metadataHash, string calldata metadataURI) external {
        if (domainId == bytes32(0)) {
            revert ZeroDomainId();
        }
        _requireNonZeroMetadataHash(metadataHash);
        TrustDomain storage domain = _domains[domainId];
        if (domain.exists) {
            revert DomainAlreadyRegistered();
        }

        domain.owner = msg.sender;
        domain.metadataHash = metadataHash;
        domain.metadataURI = metadataURI;
        domain.exists = true;

        emit DomainRegistered(domainId, msg.sender, metadataHash, metadataURI);
    }

    function updateDomain(bytes32 domainId, bytes32 metadataHash, string calldata metadataURI)
        external
        onlyDomainOwner(domainId)
    {
        _requireNonZeroMetadataHash(metadataHash);
        TrustDomain storage domain = _domains[domainId];
        domain.metadataHash = metadataHash;
        domain.metadataURI = metadataURI;

        emit DomainUpdated(domainId, metadataHash, metadataURI);
    }

    function transferDomainOwner(bytes32 domainId, address newOwner) external onlyDomainOwner(domainId) {
        if (newOwner == address(0)) {
            revert ZeroOwner();
        }

        address previousOwner = _domains[domainId].owner;
        _domains[domainId].owner = newOwner;

        emit DomainOwnerTransferred(domainId, previousOwner, newOwner);
    }

    function attestPlan(
        bytes32 domainId,
        bytes32 planId,
        bytes32 planHash,
        bytes32 artifactHash,
        bytes32 policyHash,
        bytes32 metadataHash,
        string calldata metadataURI
    ) external onlyDomainOwner(domainId) {
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

        PlanAttestation storage attestation = _planAttestations[domainId][planId];
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

        emit PlanAttested(domainId, planId, planHash, artifactHash, policyHash, metadataHash, metadataURI, msg.sender);
    }

    function revokePlan(bytes32 domainId, bytes32 planId, bytes32 reasonHash, string calldata reasonURI)
        external
        onlyDomainOwner(domainId)
    {
        PlanAttestation storage attestation = _planAttestations[domainId][planId];
        if (!attestation.attested) {
            revert UnknownPlanAttestation();
        }

        attestation.revoked = true;
        attestation.revokeReasonHash = reasonHash;
        attestation.revokeReasonURI = reasonURI;

        emit PlanRevoked(domainId, planId, reasonHash, reasonURI, msg.sender);
    }

    function attestSupplier(
        bytes32 domainId,
        bytes32 supplierSubjectId,
        address wallet,
        bytes32 profileHash,
        bytes32 capabilityHash,
        bytes32 reputationHash,
        string calldata metadataURI
    ) external onlyDomainOwner(domainId) {
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

        SupplierAttestation storage attestation = _supplierAttestations[domainId][supplierSubjectId];
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
            domainId, supplierSubjectId, wallet, profileHash, capabilityHash, reputationHash, metadataURI, msg.sender
        );
    }

    function revokeSupplier(bytes32 domainId, bytes32 supplierSubjectId, bytes32 reasonHash, string calldata reasonURI)
        external
        onlyDomainOwner(domainId)
    {
        SupplierAttestation storage attestation = _supplierAttestations[domainId][supplierSubjectId];
        if (!attestation.attested) {
            revert UnknownSupplierAttestation();
        }

        attestation.revoked = true;
        attestation.revokeReasonHash = reasonHash;
        attestation.revokeReasonURI = reasonURI;

        emit SupplierRevoked(domainId, supplierSubjectId, reasonHash, reasonURI, msg.sender);
    }

    function domainExists(bytes32 domainId) external view returns (bool) {
        return _domains[domainId].exists;
    }

    function domainOwner(bytes32 domainId) external view returns (address) {
        return _requireDomain(domainId).owner;
    }

    function getDomain(bytes32 domainId)
        external
        view
        returns (address owner, bytes32 metadataHash, string memory metadataURI)
    {
        TrustDomain storage domain = _requireDomain(domainId);
        return (domain.owner, domain.metadataHash, domain.metadataURI);
    }

    function getPlanAttestation(bytes32 domainId, bytes32 planId)
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
        PlanAttestation storage attestation = _planAttestations[domainId][planId];
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

    function isPlanActive(bytes32 domainId, bytes32 planId, bytes32 planHash) external view returns (bool) {
        PlanAttestation storage attestation = _planAttestations[domainId][planId];
        return attestation.attested && !attestation.revoked && attestation.planHash == planHash;
    }

    function isPlanRevoked(bytes32 domainId, bytes32 planId) external view returns (bool) {
        return _planAttestations[domainId][planId].revoked;
    }

    function getPlanHashes(bytes32 domainId, bytes32 planId)
        external
        view
        returns (bytes32 planHash, bytes32 artifactHash, bytes32 policyHash)
    {
        PlanAttestation storage attestation = _planAttestations[domainId][planId];
        return (attestation.planHash, attestation.artifactHash, attestation.policyHash);
    }

    function getSupplierAttestation(bytes32 domainId, bytes32 supplierSubjectId)
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
        SupplierAttestation storage attestation = _supplierAttestations[domainId][supplierSubjectId];
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

    function isSupplierActive(bytes32 domainId, bytes32 supplierSubjectId) external view returns (bool) {
        SupplierAttestation storage attestation = _supplierAttestations[domainId][supplierSubjectId];
        return attestation.attested && !attestation.revoked;
    }

    function _requireDomain(bytes32 domainId) private view returns (TrustDomain storage domain) {
        if (domainId == bytes32(0)) {
            revert ZeroDomainId();
        }
        domain = _domains[domainId];
        if (!domain.exists) {
            revert UnknownDomain();
        }
    }

    function _requireNonZeroMetadataHash(bytes32 metadataHash) private pure {
        if (metadataHash == bytes32(0)) {
            revert ZeroMetadataHash();
        }
    }
}
