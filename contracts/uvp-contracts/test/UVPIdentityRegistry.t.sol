// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPIdentityRegistry} from "../src/UVPIdentityRegistry.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
}

contract UVPIdentityRegistryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ACCOUNT_A = address(0xA11CE);
    address private constant ACCOUNT_B = address(0xB0B);
    address private constant OTHER = address(0xCAFE);
    bytes32 private constant SUBJECT = keccak256("subject:uvp-store:acme");
    bytes32 private constant OTHER_SUBJECT = keccak256("subject:uvp-store:other");
    bytes32 private constant DESCRIPTOR = keccak256("descriptor:v1");

    function testOwnerRegistersMultipleWalletsForOneSubject() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 first = registry.registerIdentityBinding(SUBJECT, ACCOUNT_A, DESCRIPTOR, "https://store.test/acme/v1");
        bytes32 second = registry.registerIdentityBinding(SUBJECT, ACCOUNT_B, DESCRIPTOR, "https://store.test/acme/v1");

        assertTrue(first != second);
        assertEq(registry.activeBindingForAccount(ACCOUNT_A), first);
        assertEq(registry.activeBindingForAccount(ACCOUNT_B), second);
    }

    function testOnlyOwnerCanRegisterOrRevoke() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        vm.prank(OTHER);
        vm.expectRevert(UVPIdentityRegistry.NotOwner.selector);
        registry.registerIdentityBinding(SUBJECT, ACCOUNT_A, DESCRIPTOR, "https://store.test/acme/v1");

        bytes32 bindingId =
            registry.registerIdentityBinding(SUBJECT, ACCOUNT_A, DESCRIPTOR, "https://store.test/acme/v1");
        vm.prank(OTHER);
        vm.expectRevert(UVPIdentityRegistry.NotOwner.selector);
        registry.revokeIdentityBinding(bindingId, keccak256("reason"), "https://store.test/reasons/1");
    }

    function testWalletHasAtMostOneActiveSubjectPerRegistry() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 bindingId =
            registry.registerIdentityBinding(SUBJECT, ACCOUNT_A, DESCRIPTOR, "https://store.test/acme/v1");

        vm.expectRevert(abi.encodeWithSelector(UVPIdentityRegistry.AccountAlreadyBound.selector, ACCOUNT_A, bindingId));
        registry.registerIdentityBinding(OTHER_SUBJECT, ACCOUNT_A, keccak256("other"), "https://store.test/other/v1");
    }

    function testRevocationIsBindingScopedAndAllowsRebinding() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 first = registry.registerIdentityBinding(SUBJECT, ACCOUNT_A, DESCRIPTOR, "https://store.test/acme/v1");
        bytes32 second = registry.registerIdentityBinding(SUBJECT, ACCOUNT_B, DESCRIPTOR, "https://store.test/acme/v1");

        registry.revokeIdentityBinding(first, keccak256("wallet-rotated"), "https://store.test/reasons/rotation");
        assertEq(registry.activeBindingForAccount(ACCOUNT_A), bytes32(0));
        assertEq(registry.activeBindingForAccount(ACCOUNT_B), second);

        bytes32 replacement = registry.registerIdentityBinding(
            SUBJECT, ACCOUNT_A, keccak256("descriptor:v2"), "https://store.test/acme/v2"
        );
        assertTrue(replacement != first);
        assertEq(registry.activeBindingForAccount(ACCOUNT_A), replacement);

        (,,,,, bool registered, bool revoked,,) = registry.getIdentityBinding(first);
        assertTrue(registered);
        assertTrue(revoked);
    }

    function testRejectsInvalidBindingInputs() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        vm.expectRevert(UVPIdentityRegistry.ZeroSubjectId.selector);
        registry.registerIdentityBinding(bytes32(0), ACCOUNT_A, DESCRIPTOR, "https://store.test/acme/v1");

        vm.expectRevert(UVPIdentityRegistry.ZeroAccount.selector);
        registry.registerIdentityBinding(SUBJECT, address(0), DESCRIPTOR, "https://store.test/acme/v1");

        vm.expectRevert(UVPIdentityRegistry.ZeroDescriptorHash.selector);
        registry.registerIdentityBinding(SUBJECT, ACCOUNT_A, bytes32(0), "https://store.test/acme/v1");

        vm.expectRevert(UVPIdentityRegistry.EmptyDescriptorURI.selector);
        registry.registerIdentityBinding(SUBJECT, ACCOUNT_A, DESCRIPTOR, "");
    }

    function assertTrue(bool value) private pure {
        require(value, "assertTrue failed");
    }

    function assertEq(bytes32 left, bytes32 right) private pure {
        require(left == right, "assertEq failed");
    }
}
