// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPIdentityRegistry} from "../src/UVPIdentityRegistry.sol";
import {IUVPIdentityRegistry} from "../src/interfaces/IUVPIdentityRegistry.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function getRecordedLogs() external returns (Log[] memory);
    function prank(address) external;
    function recordLogs() external;
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

contract UVPIdentityRegistrySupplierTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ACCOUNT_A = address(0xA11CE);
    address private constant ACCOUNT_B = address(0xB0B);
    address private constant OTHER = address(0xCAFE);
    bytes32 private constant SUBJECT = keccak256("subject:uvp-store:acme");
    bytes32 private constant DESCRIPTOR = keccak256("descriptor:v1");

    event SupplierStatusChanged(
        bytes32 indexed supplierId,
        IUVPIdentityRegistry.SupplierStatus previousStatus,
        IUVPIdentityRegistry.SupplierStatus newStatus,
        address indexed account
    );

    function testIdentityBindingsAndSupplierCapabilitiesShareOneRegistryWithoutCrossAuthorization() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 bindingId = registry.registerIdentityBinding(
            SUBJECT, ACCOUNT_A, DESCRIPTOR, "https://store.test/acme/v1"
        );

        vm.prank(ACCOUNT_A);
        bytes32 supplierId = registry.registerSupplier(ACCOUNT_A);
        registry.activateSupplier(supplierId);

        assertEq(registry.activeBindingForAccount(ACCOUNT_A), bindingId);
        assertEq(registry.accountOf(supplierId), ACCOUNT_A);
        assertTrue(registry.isActiveSupplier(supplierId));
        assertEq(registry.supplierOf(ACCOUNT_B), bytes32(0));
        assertEq(registry.activeBindingForAccount(ACCOUNT_B), bytes32(0));
    }

    function testSelfRegistrationBindsDistinctSupplierIdsToAccounts() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();

        bytes32 supplierA = _register(registry, ACCOUNT_A);
        bytes32 supplierB = _register(registry, ACCOUNT_B);
        bytes32 supplierSelf = registry.registerSupplier(address(this));

        require(supplierA != supplierB, "supplier A/B reused");
        require(supplierA != supplierSelf, "supplier A/self reused");
        require(supplierB != supplierSelf, "supplier B/self reused");

        assertEq(registry.accountOf(supplierA), ACCOUNT_A);
        assertEq(registry.accountOf(supplierB), ACCOUNT_B);
        assertEq(registry.accountOf(supplierSelf), address(this));
        assertEq(registry.supplierOf(ACCOUNT_A), supplierA);
        assertEq(registry.supplierOf(ACCOUNT_B), supplierB);
        assertEq(registry.supplierOf(address(this)), supplierSelf);
        _assertStatus(registry, supplierA, IUVPIdentityRegistry.SupplierStatus.Pending);
        assertFalse(registry.isActiveSupplier(supplierA));
    }

    function testRegistrationEventCarriesMintedSupplierIdAndAccount() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        vm.recordLogs();
        bytes32 supplierId = _register(registry, ACCOUNT_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "unexpected log count");
        require(logs[0].emitter == address(registry), "wrong emitter");
        require(logs[0].topics.length == 3, "wrong topic count");
        assertEq(logs[0].topics[1], supplierId);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(ACCOUNT_A))));
    }

    function testMintedSupplierIdIsUuidV4InLowSixteenBytes() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        uint256 supplierId = uint256(_register(registry, ACCOUNT_A));

        assertEq(supplierId >> 128, 0);
        assertEq((supplierId >> 76) & 0xf, 4);
        assertEq((supplierId >> 62) & 0x3, 2);
    }

    function testRegistrationRejectsCallerRegisteringAnotherAccount() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();

        vm.prank(ACCOUNT_A);
        vm.expectRevert(abi.encodeWithSelector(UVPIdentityRegistry.CallerNotAccount.selector, ACCOUNT_A, ACCOUNT_B));
        registry.registerSupplier(ACCOUNT_B);
    }

    function testAccountCannotMintSecondSupplierEvenAfterRevoke() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);

        registry.revokeSupplier(supplierId);
        _assertStatus(registry, supplierId, IUVPIdentityRegistry.SupplierStatus.Revoked);
        assertEq(registry.accountOf(supplierId), ACCOUNT_A);
        assertEq(registry.supplierOf(ACCOUNT_A), supplierId);

        vm.prank(ACCOUNT_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPIdentityRegistry.AccountAlreadyRegistered.selector, ACCOUNT_A, supplierId)
        );
        registry.registerSupplier(ACCOUNT_A);
    }

    function testRegistrarLifecycleKeepsAccountPermanent() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);
        IUVPIdentityRegistry.SupplierStatus pending = IUVPIdentityRegistry.SupplierStatus.Pending;
        IUVPIdentityRegistry.SupplierStatus active = IUVPIdentityRegistry.SupplierStatus.Active;
        IUVPIdentityRegistry.SupplierStatus suspended = IUVPIdentityRegistry.SupplierStatus.Suspended;
        IUVPIdentityRegistry.SupplierStatus revoked = IUVPIdentityRegistry.SupplierStatus.Revoked;

        vm.expectEmit(true, true, false, true);
        emit SupplierStatusChanged(supplierId, pending, active, ACCOUNT_A);
        registry.activateSupplier(supplierId);
        _assertStatus(registry, supplierId, active);
        assertTrue(registry.isActiveSupplier(supplierId));

        vm.expectEmit(true, true, false, true);
        emit SupplierStatusChanged(supplierId, active, suspended, ACCOUNT_A);
        registry.suspendSupplier(supplierId);
        _assertStatus(registry, supplierId, suspended);
        assertFalse(registry.isActiveSupplier(supplierId));

        vm.expectEmit(true, true, false, true);
        emit SupplierStatusChanged(supplierId, suspended, active, ACCOUNT_A);
        registry.activateSupplier(supplierId);
        _assertStatus(registry, supplierId, active);

        vm.expectEmit(true, true, false, true);
        emit SupplierStatusChanged(supplierId, active, revoked, ACCOUNT_A);
        registry.revokeSupplier(supplierId);
        _assertStatus(registry, supplierId, revoked);
        assertEq(registry.accountOf(supplierId), ACCOUNT_A);
        assertEq(registry.supplierOf(ACCOUNT_A), supplierId);
    }

    function testRejectedStatusTransitionsRevertWithNamedCause() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);
        IUVPIdentityRegistry.SupplierStatus pending = IUVPIdentityRegistry.SupplierStatus.Pending;
        IUVPIdentityRegistry.SupplierStatus active = IUVPIdentityRegistry.SupplierStatus.Active;
        IUVPIdentityRegistry.SupplierStatus suspended = IUVPIdentityRegistry.SupplierStatus.Suspended;
        IUVPIdentityRegistry.SupplierStatus revoked = IUVPIdentityRegistry.SupplierStatus.Revoked;

        _expectInvalidTransition(registry, supplierId, pending, suspended);
        registry.suspendSupplier(supplierId);

        registry.activateSupplier(supplierId);
        _expectInvalidTransition(registry, supplierId, active, active);
        registry.activateSupplier(supplierId);

        registry.suspendSupplier(supplierId);
        _expectInvalidTransition(registry, supplierId, suspended, suspended);
        registry.suspendSupplier(supplierId);

        registry.revokeSupplier(supplierId);
        _expectInvalidTransition(registry, supplierId, revoked, active);
        registry.activateSupplier(supplierId);
        _expectInvalidTransition(registry, supplierId, revoked, suspended);
        registry.suspendSupplier(supplierId);
        _expectInvalidTransition(registry, supplierId, revoked, revoked);
        registry.revokeSupplier(supplierId);
    }

    function testUnknownSupplierReadsFailClosed() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 unknownSupplierId = keccak256("supplier:uvp-store:unknown");

        assertEq(registry.accountOf(unknownSupplierId), address(0));
        assertEq(registry.supplierOf(OTHER), bytes32(0));
        assertFalse(registry.isActiveSupplier(unknownSupplierId));

        vm.expectRevert(abi.encodeWithSelector(UVPIdentityRegistry.UnknownSupplier.selector, unknownSupplierId));
        registry.statusOf(unknownSupplierId);

        vm.expectRevert(abi.encodeWithSelector(UVPIdentityRegistry.UnknownSupplier.selector, unknownSupplierId));
        registry.activateSupplier(unknownSupplierId);

        vm.expectRevert(abi.encodeWithSelector(UVPIdentityRegistry.UnknownSupplier.selector, unknownSupplierId));
        registry.revokeSupplier(unknownSupplierId);
    }

    function testOnlyRegistrarMovesStatusAndOnlyOwnerSetsRegistrar() public {
        UVPIdentityRegistry registry = new UVPIdentityRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);

        vm.prank(OTHER);
        vm.expectRevert(UVPIdentityRegistry.NotRegistrar.selector);
        registry.activateSupplier(supplierId);

        vm.prank(OTHER);
        vm.expectRevert(UVPIdentityRegistry.NotOwner.selector);
        registry.setRegistrar(OTHER, true);

        registry.setRegistrar(OTHER, true);
        vm.prank(OTHER);
        registry.activateSupplier(supplierId);
        assertTrue(registry.isActiveSupplier(supplierId));

        registry.setRegistrar(OTHER, false);
        bytes32 secondSupplierId = _register(registry, ACCOUNT_B);
        vm.prank(OTHER);
        vm.expectRevert(UVPIdentityRegistry.NotRegistrar.selector);
        registry.activateSupplier(secondSupplierId);

        vm.prank(OTHER);
        vm.expectRevert(UVPIdentityRegistry.NotOwner.selector);
        registry.transferOwnership(OTHER);

        registry.transferOwnership(OTHER);
        assertEq(registry.owner(), OTHER);
        vm.expectRevert(UVPIdentityRegistry.NotOwner.selector);
        registry.setRegistrar(ACCOUNT_A, true);
    }

    function _register(UVPIdentityRegistry registry, address account) private returns (bytes32 supplierId) {
        vm.prank(account);
        supplierId = registry.registerSupplier(account);
    }

    function _expectInvalidTransition(
        UVPIdentityRegistry registry,
        bytes32 supplierId,
        IUVPIdentityRegistry.SupplierStatus currentStatus,
        IUVPIdentityRegistry.SupplierStatus nextStatus
    ) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPIdentityRegistry.InvalidSupplierStatusTransition.selector, supplierId, currentStatus, nextStatus
            )
        );
    }

    function _assertStatus(
        UVPIdentityRegistry registry,
        bytes32 supplierId,
        IUVPIdentityRegistry.SupplierStatus expectedStatus
    ) private view {
        require(registry.statusOf(supplierId) == expectedStatus, "unexpected supplier status");
    }

    function assertTrue(bool value) private pure {
        require(value, "assertTrue failed");
    }

    function assertFalse(bool value) private pure {
        require(!value, "assertFalse failed");
    }

    function assertEq(address left, address right) private pure {
        require(left == right, "assertEq address failed");
    }

    function assertEq(bytes32 left, bytes32 right) private pure {
        require(left == right, "assertEq bytes32 failed");
    }

    function assertEq(uint256 left, uint256 right) private pure {
        require(left == right, "assertEq uint256 failed");
    }
}
