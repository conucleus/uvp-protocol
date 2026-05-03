// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract UVPDeploymentRegistry {
    enum DeploymentStatus {
        Unknown,
        Candidate,
        Canary,
        Active,
        Deprecated,
        Retired
    }

    struct Deployment {
        bytes32 deploymentId;
        address stateMachine;
        address trustRegistry;
        bytes32 officialDomainId;
        bytes32 artifactHash;
        bytes32 abiHash;
        uint64 deploymentBlock;
        uint64 activatedAtBlock;
        bytes32 evidenceHash;
        string metadataURI;
        DeploymentStatus status;
        bool exists;
    }

    error DeploymentAlreadyExists();
    error DeploymentAlreadyActive();
    error DeploymentNotActivatable();
    error DeploymentNotFound();
    error DeploymentIsRetired();
    error InvalidStateMachine();
    error InvalidTrustRegistry();
    error NotOwner();
    error ZeroAbiHash();
    error ZeroArtifactHash();
    error ZeroDeploymentBlock();
    error ZeroDeploymentId();
    error ZeroEvidenceHash();
    error ZeroOfficialDomainId();
    error ZeroOwner();
    error ZeroStateMachine();
    error ZeroTrustRegistry();

    address public owner;
    bytes32 public activeDeploymentId;

    mapping(bytes32 deploymentId => Deployment deployment) private _deployments;
    bytes32[] private _deploymentIds;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DeploymentRegistered(
        bytes32 indexed deploymentId,
        address indexed stateMachine,
        address indexed trustRegistry,
        bytes32 officialDomainId,
        bytes32 artifactHash,
        bytes32 abiHash,
        uint64 deploymentBlock,
        string metadataURI
    );
    event DeploymentCanaryMarked(bytes32 indexed deploymentId, bytes32 evidenceHash, string evidenceURI);
    event DeploymentActivated(
        bytes32 indexed previousDeploymentId, bytes32 indexed newDeploymentId, bytes32 evidenceHash, string evidenceURI
    );
    event DeploymentDeprecated(bytes32 indexed deploymentId, bytes32 reasonHash, string reasonURI);
    event DeploymentRetired(bytes32 indexed deploymentId, bytes32 reasonHash, string reasonURI);

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

    function registerDeployment(
        bytes32 deploymentId,
        address stateMachine,
        address trustRegistry,
        bytes32 officialDomainId,
        bytes32 artifactHash,
        bytes32 abiHash,
        uint64 deploymentBlock,
        string calldata metadataURI
    ) external onlyOwner {
        if (deploymentId == bytes32(0)) {
            revert ZeroDeploymentId();
        }
        if (stateMachine == address(0)) {
            revert ZeroStateMachine();
        }
        if (stateMachine.code.length == 0) {
            revert InvalidStateMachine();
        }
        if (trustRegistry == address(0)) {
            revert ZeroTrustRegistry();
        }
        if (trustRegistry.code.length == 0) {
            revert InvalidTrustRegistry();
        }
        if (officialDomainId == bytes32(0)) {
            revert ZeroOfficialDomainId();
        }
        if (artifactHash == bytes32(0)) {
            revert ZeroArtifactHash();
        }
        if (abiHash == bytes32(0)) {
            revert ZeroAbiHash();
        }
        if (deploymentBlock == 0) {
            revert ZeroDeploymentBlock();
        }
        Deployment storage deployment = _deployments[deploymentId];
        if (deployment.exists) {
            revert DeploymentAlreadyExists();
        }

        deployment.deploymentId = deploymentId;
        deployment.stateMachine = stateMachine;
        deployment.trustRegistry = trustRegistry;
        deployment.officialDomainId = officialDomainId;
        deployment.artifactHash = artifactHash;
        deployment.abiHash = abiHash;
        deployment.deploymentBlock = deploymentBlock;
        deployment.metadataURI = metadataURI;
        deployment.status = DeploymentStatus.Candidate;
        deployment.exists = true;
        _deploymentIds.push(deploymentId);

        emit DeploymentRegistered(
            deploymentId,
            stateMachine,
            trustRegistry,
            officialDomainId,
            artifactHash,
            abiHash,
            deploymentBlock,
            metadataURI
        );
    }

    function markCanary(bytes32 deploymentId, bytes32 evidenceHash, string calldata evidenceURI) external onlyOwner {
        Deployment storage deployment = _requireDeployment(deploymentId);
        _requireEvidence(evidenceHash);
        if (deployment.status == DeploymentStatus.Retired) {
            revert DeploymentIsRetired();
        }
        if (deployment.status != DeploymentStatus.Candidate && deployment.status != DeploymentStatus.Canary) {
            revert DeploymentNotActivatable();
        }

        deployment.status = DeploymentStatus.Canary;
        deployment.evidenceHash = evidenceHash;
        emit DeploymentCanaryMarked(deploymentId, evidenceHash, evidenceURI);
    }

    function activateDeployment(bytes32 deploymentId, bytes32 evidenceHash, string calldata evidenceURI)
        external
        onlyOwner
    {
        Deployment storage deployment = _requireDeployment(deploymentId);
        _requireEvidence(evidenceHash);
        if (deployment.status == DeploymentStatus.Retired) {
            revert DeploymentIsRetired();
        }
        if (deployment.status == DeploymentStatus.Active || activeDeploymentId == deploymentId) {
            revert DeploymentAlreadyActive();
        }
        if (deployment.status != DeploymentStatus.Canary) {
            revert DeploymentNotActivatable();
        }

        bytes32 previousDeploymentId = activeDeploymentId;
        if (previousDeploymentId != bytes32(0)) {
            Deployment storage previous = _deployments[previousDeploymentId];
            if (previous.exists && previous.status == DeploymentStatus.Active) {
                previous.status = DeploymentStatus.Deprecated;
                emit DeploymentDeprecated(previousDeploymentId, evidenceHash, evidenceURI);
            }
        }

        activeDeploymentId = deploymentId;
        deployment.status = DeploymentStatus.Active;
        deployment.activatedAtBlock = uint64(block.number);
        deployment.evidenceHash = evidenceHash;
        emit DeploymentActivated(previousDeploymentId, deploymentId, evidenceHash, evidenceURI);
    }

    function deprecateDeployment(bytes32 deploymentId, bytes32 reasonHash, string calldata reasonURI)
        external
        onlyOwner
    {
        Deployment storage deployment = _requireDeployment(deploymentId);
        if (deployment.status == DeploymentStatus.Retired) {
            revert DeploymentIsRetired();
        }
        if (deploymentId == activeDeploymentId) {
            activeDeploymentId = bytes32(0);
        }
        deployment.status = DeploymentStatus.Deprecated;
        emit DeploymentDeprecated(deploymentId, reasonHash, reasonURI);
    }

    function retireDeployment(bytes32 deploymentId, bytes32 reasonHash, string calldata reasonURI) external onlyOwner {
        Deployment storage deployment = _requireDeployment(deploymentId);
        if (deploymentId == activeDeploymentId) {
            activeDeploymentId = bytes32(0);
        }
        deployment.status = DeploymentStatus.Retired;
        emit DeploymentRetired(deploymentId, reasonHash, reasonURI);
    }

    function deploymentExists(bytes32 deploymentId) external view returns (bool) {
        return _deployments[deploymentId].exists;
    }

    function deploymentCount() external view returns (uint256) {
        return _deploymentIds.length;
    }

    function deploymentIdAt(uint256 index) external view returns (bytes32) {
        return _deploymentIds[index];
    }

    function getDeployment(bytes32 deploymentId) external view returns (Deployment memory) {
        return _requireDeploymentView(deploymentId);
    }

    function getActiveDeployment() external view returns (Deployment memory) {
        return _requireDeploymentView(activeDeploymentId);
    }

    function _requireDeployment(bytes32 deploymentId) private view returns (Deployment storage deployment) {
        deployment = _deployments[deploymentId];
        if (!deployment.exists) {
            revert DeploymentNotFound();
        }
    }

    function _requireDeploymentView(bytes32 deploymentId) private view returns (Deployment storage deployment) {
        deployment = _deployments[deploymentId];
        if (!deployment.exists) {
            revert DeploymentNotFound();
        }
    }

    function _requireEvidence(bytes32 evidenceHash) private pure {
        if (evidenceHash == bytes32(0)) {
            revert ZeroEvidenceHash();
        }
    }
}
