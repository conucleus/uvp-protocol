// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPDeploymentRegistry} from "../src/UVPDeploymentRegistry.sol";

interface DeploymentRegistryVm {
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function expectRevert(bytes4 revertData) external;
    function prank(address sender) external;
}

contract DummyDeploymentTarget {}

contract UVPDeploymentRegistryTest {
    DeploymentRegistryVm private constant vm =
        DeploymentRegistryVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant DEPLOYMENT_ID_V1 = bytes32(uint256(0x1001));
    bytes32 private constant DEPLOYMENT_ID_V2 = bytes32(uint256(0x1002));
    bytes32 private constant ARTIFACT_HASH = bytes32(uint256(0x3001));
    bytes32 private constant ABI_HASH = bytes32(uint256(0x3002));
    bytes32 private constant EVIDENCE_HASH = bytes32(uint256(0x4001));
    bytes32 private constant EVIDENCE_HASH_2 = bytes32(uint256(0x4002));
    bytes32 private constant REASON_HASH = bytes32(uint256(0x5001));

    address private constant NON_OWNER = address(0x4444);

    event DeploymentActivated(
        bytes32 indexed previousDeploymentId, bytes32 indexed newDeploymentId, bytes32 evidenceHash, string evidenceURI
    );

    function testOwnerCanRegisterCanaryAndActivateDeployment() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();
        address stateMachine = _target();

        registry.registerDeployment(
            DEPLOYMENT_ID_V1, stateMachine, ARTIFACT_HASH, ABI_HASH, 10, "ipfs://deployment/v1"
        );
        registry.markCanary(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");

        vm.expectEmit(true, true, true, true);
        emit DeploymentActivated(bytes32(0), DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
        registry.activateDeployment(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");

        require(registry.activeDeploymentId() == DEPLOYMENT_ID_V1, "active id");
        UVPDeploymentRegistry.Deployment memory deployment = registry.getDeployment(DEPLOYMENT_ID_V1);
        require(deployment.status == UVPDeploymentRegistry.DeploymentStatus.Active, "status");
        require(deployment.stateMachine == stateMachine, "state machine");
        require(deployment.evidenceHash == EVIDENCE_HASH, "evidence");
        require(deployment.activatedAtBlock > 0, "activated block");
    }

    function testOnlyOwnerCanMutateDeployments() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();

        vm.prank(NON_OWNER);
        vm.expectRevert(UVPDeploymentRegistry.NotOwner.selector);
        registry.registerDeployment(
            DEPLOYMENT_ID_V1, address(0x1111), ARTIFACT_HASH, ABI_HASH, 10, "ipfs://deployment/v1"
        );

        _register(registry, DEPLOYMENT_ID_V1);

        vm.prank(NON_OWNER);
        vm.expectRevert(UVPDeploymentRegistry.NotOwner.selector);
        registry.activateDeployment(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
    }

    function testRegisterDeploymentRejectsZeroInputs() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();
        address stateMachine = _target();

        vm.expectRevert(UVPDeploymentRegistry.ZeroDeploymentId.selector);
        registry.registerDeployment(bytes32(0), stateMachine, ARTIFACT_HASH, ABI_HASH, 10, "");

        vm.expectRevert(UVPDeploymentRegistry.ZeroStateMachine.selector);
        registry.registerDeployment(DEPLOYMENT_ID_V1, address(0), ARTIFACT_HASH, ABI_HASH, 10, "");

        vm.expectRevert(UVPDeploymentRegistry.ZeroArtifactHash.selector);
        registry.registerDeployment(DEPLOYMENT_ID_V1, stateMachine, bytes32(0), ABI_HASH, 10, "");

        vm.expectRevert(UVPDeploymentRegistry.ZeroAbiHash.selector);
        registry.registerDeployment(DEPLOYMENT_ID_V1, stateMachine, ARTIFACT_HASH, bytes32(0), 10, "");

        vm.expectRevert(UVPDeploymentRegistry.ZeroDeploymentBlock.selector);
        registry.registerDeployment(DEPLOYMENT_ID_V1, stateMachine, ARTIFACT_HASH, ABI_HASH, 0, "");
    }

    function testRegisterDeploymentRejectsNonContractAddresses() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();
        address nonContractStateMachine = address(uint160(uint256(keccak256("uvp-eth:not-a-state-machine"))));
        require(nonContractStateMachine.code.length == 0, "state machine has code");

        vm.expectRevert(UVPDeploymentRegistry.InvalidStateMachine.selector);
        registry.registerDeployment(DEPLOYMENT_ID_V1, nonContractStateMachine, ARTIFACT_HASH, ABI_HASH, 10, "");
    }

    function testActivationDeprecatesPreviousActiveDeployment() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();
        _register(registry, DEPLOYMENT_ID_V1);
        _register(registry, DEPLOYMENT_ID_V2);

        registry.markCanary(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
        registry.activateDeployment(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
        registry.markCanary(DEPLOYMENT_ID_V2, EVIDENCE_HASH_2, "ipfs://evidence/v2");
        registry.activateDeployment(DEPLOYMENT_ID_V2, EVIDENCE_HASH_2, "ipfs://evidence/v2");

        require(registry.activeDeploymentId() == DEPLOYMENT_ID_V2, "active v2");
        require(
            registry.getDeployment(DEPLOYMENT_ID_V1).status == UVPDeploymentRegistry.DeploymentStatus.Deprecated,
            "v1 not deprecated"
        );
        require(
            registry.getDeployment(DEPLOYMENT_ID_V2).status == UVPDeploymentRegistry.DeploymentStatus.Active,
            "v2 not active"
        );
    }

    function testCandidateCannotActivateBeforeCanaryEvidence() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();
        _register(registry, DEPLOYMENT_ID_V1);

        vm.expectRevert(UVPDeploymentRegistry.DeploymentNotActivatable.selector);
        registry.activateDeployment(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
    }

    function testRetiredDeploymentCannotBeReactivated() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();
        _register(registry, DEPLOYMENT_ID_V1);

        registry.retireDeployment(DEPLOYMENT_ID_V1, REASON_HASH, "ipfs://retired");
        vm.expectRevert(UVPDeploymentRegistry.DeploymentIsRetired.selector);
        registry.activateDeployment(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
    }

    function testActiveDeploymentCannotBeActivatedAgain() public {
        UVPDeploymentRegistry registry = new UVPDeploymentRegistry();
        _register(registry, DEPLOYMENT_ID_V1);

        registry.markCanary(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
        registry.activateDeployment(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
        vm.expectRevert(UVPDeploymentRegistry.DeploymentAlreadyActive.selector);
        registry.activateDeployment(DEPLOYMENT_ID_V1, EVIDENCE_HASH, "ipfs://evidence/v1");
    }

    function _register(UVPDeploymentRegistry registry, bytes32 deploymentId) private {
        registry.registerDeployment(deploymentId, _target(), ARTIFACT_HASH, ABI_HASH, 10, "ipfs://deployment");
    }

    function _target() private returns (address) {
        return address(new DummyDeploymentTarget());
    }
}
