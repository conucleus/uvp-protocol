// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ZhixuTrustRegistry} from "../src/ZhixuTrustRegistry.sol";

interface RegistryVm {
    function expectRevert(bytes4 revertData) external;
    function prank(address sender) external;
}

contract ZhixuTrustRegistryTest {
    RegistryVm private constant vm = RegistryVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant PLAN_ID = bytes32(uint256(0x2001));
    bytes32 private constant PLAN_HASH = bytes32(uint256(0x2002));
    bytes32 private constant ARTIFACT_HASH = bytes32(uint256(0x2003));
    bytes32 private constant POLICY_HASH = bytes32(uint256(0x2004));
    bytes32 private constant METADATA_HASH = bytes32(uint256(0x2005));
    bytes32 private constant REASON_HASH = bytes32(uint256(0x3001));
    bytes32 private constant SUPPLIER_SUBJECT_ID = bytes32(uint256(0x4001));
    bytes32 private constant PROFILE_HASH = bytes32(uint256(0x4002));
    bytes32 private constant CAPABILITY_HASH = bytes32(uint256(0x4003));
    bytes32 private constant REPUTATION_HASH = bytes32(uint256(0x4004));

    address private constant OTHER = address(0x2222);
    address private constant NEW_OWNER = address(0x3333);
    address private constant SUPPLIER_WALLET = address(0x4444);

    function testRegistryOwnerCanTransferOwnership() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        require(registry.owner() == address(this), "bad owner");

        vm.prank(OTHER);
        vm.expectRevert(ZhixuTrustRegistry.NotOwner.selector);
        registry.transferOwnership(NEW_OWNER);

        registry.transferOwnership(NEW_OWNER);
        require(registry.owner() == NEW_OWNER, "transfer failed");

        vm.prank(NEW_OWNER);
        registry.attestPlan(PLAN_ID, PLAN_HASH, ARTIFACT_HASH, POLICY_HASH, METADATA_HASH, "https://store/plan");
    }

    function testOnlyOwnerCanAttestAndRevokePlan() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        vm.prank(OTHER);
        vm.expectRevert(ZhixuTrustRegistry.NotOwner.selector);
        registry.attestPlan(PLAN_ID, PLAN_HASH, ARTIFACT_HASH, POLICY_HASH, METADATA_HASH, "https://store/plan");

        registry.attestPlan(PLAN_ID, PLAN_HASH, ARTIFACT_HASH, POLICY_HASH, METADATA_HASH, "https://store/plan");

        (
            bytes32 planHash,
            bytes32 artifactHash,
            bytes32 policyHash,
            bytes32 metadataHash,
            string memory metadataURI,
            address attester,
            bool attested,
            bool revoked,
            ,
        ) = registry.getPlanAttestation(PLAN_ID);
        require(planHash == PLAN_HASH, "bad plan hash");
        require(artifactHash == ARTIFACT_HASH, "bad artifact hash");
        require(policyHash == POLICY_HASH, "bad policy hash");
        require(metadataHash == METADATA_HASH, "bad metadata hash");
        require(_same(metadataURI, "https://store/plan"), "bad metadata uri");
        require(attester == address(this), "bad attester");
        require(attested, "not attested");
        require(!revoked, "unexpected revoked");

        vm.prank(OTHER);
        vm.expectRevert(ZhixuTrustRegistry.NotOwner.selector);
        registry.revokePlan(PLAN_ID, REASON_HASH, "https://store/revoke");

        registry.revokePlan(PLAN_ID, REASON_HASH, "https://store/revoke");
        (,,,,,,, bool isRevoked, bytes32 revokeReasonHash, string memory revokeReasonURI) =
            registry.getPlanAttestation(PLAN_ID);
        require(isRevoked, "not revoked");
        require(revokeReasonHash == REASON_HASH, "bad revoke reason hash");
        require(_same(revokeReasonURI, "https://store/revoke"), "bad revoke uri");
    }

    function testOnlyOwnerCanAttestAndRevokeSupplier() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        vm.prank(OTHER);
        vm.expectRevert(ZhixuTrustRegistry.NotOwner.selector);
        registry.attestSupplier(
            SUPPLIER_SUBJECT_ID,
            SUPPLIER_WALLET,
            PROFILE_HASH,
            CAPABILITY_HASH,
            REPUTATION_HASH,
            "https://store/supplier"
        );

        registry.attestSupplier(
            SUPPLIER_SUBJECT_ID,
            SUPPLIER_WALLET,
            PROFILE_HASH,
            CAPABILITY_HASH,
            REPUTATION_HASH,
            "https://store/supplier"
        );

        (
            address wallet,
            bytes32 profileHash,
            bytes32 capabilityHash,
            bytes32 reputationHash,
            string memory metadataURI,
            address attester,
            bool attested,
            bool revoked,
            ,
        ) = registry.getSupplierAttestation(SUPPLIER_SUBJECT_ID);
        require(wallet == SUPPLIER_WALLET, "bad wallet");
        require(profileHash == PROFILE_HASH, "bad profile hash");
        require(capabilityHash == CAPABILITY_HASH, "bad capability hash");
        require(reputationHash == REPUTATION_HASH, "bad reputation hash");
        require(_same(metadataURI, "https://store/supplier"), "bad metadata uri");
        require(attester == address(this), "bad attester");
        require(attested, "not attested");
        require(!revoked, "unexpected revoked");

        registry.revokeSupplier(SUPPLIER_SUBJECT_ID, REASON_HASH, "https://store/supplier-revoke");
        (,,,,,,, bool isRevoked, bytes32 revokeReasonHash, string memory revokeReasonURI) =
            registry.getSupplierAttestation(SUPPLIER_SUBJECT_ID);
        require(isRevoked, "not revoked");
        require(revokeReasonHash == REASON_HASH, "bad revoke reason hash");
        require(_same(revokeReasonURI, "https://store/supplier-revoke"), "bad revoke uri");
    }

    function testRevocationDoesNotDeleteHistoricalAttestation() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        registry.attestPlan(PLAN_ID, PLAN_HASH, ARTIFACT_HASH, POLICY_HASH, METADATA_HASH, "https://store/plan");
        registry.revokePlan(PLAN_ID, REASON_HASH, "https://store/revoke");

        (bytes32 planHash, bytes32 artifactHash,,,,, bool attested, bool revoked,,) =
            registry.getPlanAttestation(PLAN_ID);
        require(attested, "attestation deleted");
        require(revoked, "not revoked");
        require(planHash == PLAN_HASH, "plan hash deleted");
        require(artifactHash == ARTIFACT_HASH, "artifact hash deleted");
    }

    function testPlanActiveRevokedAndHashGetters() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        require(!registry.isPlanActive(PLAN_ID, PLAN_HASH), "unknown plan active");
        require(!registry.isPlanRevoked(PLAN_ID), "unknown plan revoked");
        (bytes32 emptyPlanHash, bytes32 emptyArtifactHash, bytes32 emptyPolicyHash) = registry.getPlanHashes(PLAN_ID);
        require(emptyPlanHash == bytes32(0), "unexpected empty plan hash");
        require(emptyArtifactHash == bytes32(0), "unexpected empty artifact hash");
        require(emptyPolicyHash == bytes32(0), "unexpected empty policy hash");

        registry.attestPlan(PLAN_ID, PLAN_HASH, ARTIFACT_HASH, POLICY_HASH, METADATA_HASH, "https://store/plan");
        require(registry.isPlanActive(PLAN_ID, PLAN_HASH), "plan not active");
        require(!registry.isPlanActive(PLAN_ID, bytes32(uint256(0x9999))), "wrong hash active");
        require(!registry.isPlanRevoked(PLAN_ID), "active plan revoked");
        (bytes32 planHash, bytes32 artifactHash, bytes32 policyHash) = registry.getPlanHashes(PLAN_ID);
        require(planHash == PLAN_HASH, "bad getter plan hash");
        require(artifactHash == ARTIFACT_HASH, "bad getter artifact hash");
        require(policyHash == POLICY_HASH, "bad getter policy hash");

        registry.revokePlan(PLAN_ID, REASON_HASH, "https://store/revoke");
        require(!registry.isPlanActive(PLAN_ID, PLAN_HASH), "revoked plan active");
        require(registry.isPlanRevoked(PLAN_ID), "plan not revoked");
    }

    function testSupplierActiveGetter() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        require(!registry.isSupplierActive(SUPPLIER_SUBJECT_ID), "unknown supplier active");

        registry.attestSupplier(
            SUPPLIER_SUBJECT_ID,
            SUPPLIER_WALLET,
            PROFILE_HASH,
            CAPABILITY_HASH,
            REPUTATION_HASH,
            "https://store/supplier"
        );
        require(registry.isSupplierActive(SUPPLIER_SUBJECT_ID), "supplier not active");

        registry.revokeSupplier(SUPPLIER_SUBJECT_ID, REASON_HASH, "https://store/supplier-revoke");
        require(!registry.isSupplierActive(SUPPLIER_SUBJECT_ID), "revoked supplier active");
    }

    function testRevertsForUnknownAttestations() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        vm.expectRevert(ZhixuTrustRegistry.UnknownPlanAttestation.selector);
        registry.revokePlan(PLAN_ID, REASON_HASH, "https://store/revoke");

        vm.expectRevert(ZhixuTrustRegistry.UnknownSupplierAttestation.selector);
        registry.revokeSupplier(SUPPLIER_SUBJECT_ID, REASON_HASH, "https://store/revoke");
    }

    function testRejectsZeroPlanAttestationHashes() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        vm.expectRevert(ZhixuTrustRegistry.ZeroPlanHash.selector);
        registry.attestPlan(PLAN_ID, bytes32(0), ARTIFACT_HASH, POLICY_HASH, METADATA_HASH, "https://store/plan");

        vm.expectRevert(ZhixuTrustRegistry.ZeroArtifactHash.selector);
        registry.attestPlan(PLAN_ID, PLAN_HASH, bytes32(0), POLICY_HASH, METADATA_HASH, "https://store/plan");

        vm.expectRevert(ZhixuTrustRegistry.ZeroPolicyHash.selector);
        registry.attestPlan(PLAN_ID, PLAN_HASH, ARTIFACT_HASH, bytes32(0), METADATA_HASH, "https://store/plan");

        vm.expectRevert(ZhixuTrustRegistry.ZeroMetadataHash.selector);
        registry.attestPlan(PLAN_ID, PLAN_HASH, ARTIFACT_HASH, POLICY_HASH, bytes32(0), "https://store/plan");
    }

    function testRejectsZeroSupplierAttestationHashes() public {
        ZhixuTrustRegistry registry = new ZhixuTrustRegistry();

        vm.expectRevert(ZhixuTrustRegistry.ZeroProfileHash.selector);
        registry.attestSupplier(
            SUPPLIER_SUBJECT_ID,
            SUPPLIER_WALLET,
            bytes32(0),
            CAPABILITY_HASH,
            REPUTATION_HASH,
            "https://store/supplier"
        );

        vm.expectRevert(ZhixuTrustRegistry.ZeroCapabilityHash.selector);
        registry.attestSupplier(
            SUPPLIER_SUBJECT_ID,
            SUPPLIER_WALLET,
            PROFILE_HASH,
            bytes32(0),
            REPUTATION_HASH,
            "https://store/supplier"
        );

        vm.expectRevert(ZhixuTrustRegistry.ZeroReputationHash.selector);
        registry.attestSupplier(
            SUPPLIER_SUBJECT_ID,
            SUPPLIER_WALLET,
            PROFILE_HASH,
            CAPABILITY_HASH,
            bytes32(0),
            "https://store/supplier"
        );
    }

    function _same(string memory left, string memory right) private pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
