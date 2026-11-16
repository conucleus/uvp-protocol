// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPSupplierRegistry} from "../src/interfaces/IUVPSupplierRegistry.sol";
import {UVPSupplierRegistry} from "../src/UVPSupplierRegistry.sol";

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

contract UVPSupplierRegistryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant ACCOUNT_A = address(0xA11CE);
    address private constant ACCOUNT_B = address(0xB0B);
    address private constant OTHER = address(0xCAFE);

    event SupplierStatusChanged(
        bytes32 indexed supplierId,
        IUVPSupplierRegistry.SupplierStatus previousStatus,
        IUVPSupplierRegistry.SupplierStatus newStatus,
        address indexed account
    );

    function testSelfRegistrationBindsDistinctSupplierIdsToAccounts() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();

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
        _assertStatus(registry, supplierA, IUVPSupplierRegistry.SupplierStatus.Pending);
        assertFalse(registry.isActiveSupplier(supplierA));
    }

    function testRegistrationEventCarriesMintedSupplierIdAndAccount() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
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
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        uint256 supplierId = uint256(_register(registry, ACCOUNT_A));

        assertEq(supplierId >> 128, 0);
        assertEq((supplierId >> 76) & 0xf, 4);
        assertEq((supplierId >> 62) & 0x3, 2);
    }

    function testRegistrationRejectsCallerRegisteringAnotherAccount() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();

        vm.prank(ACCOUNT_A);
        vm.expectRevert(abi.encodeWithSelector(UVPSupplierRegistry.CallerNotAccount.selector, ACCOUNT_A, ACCOUNT_B));
        registry.registerSupplier(ACCOUNT_B);
    }

    function testAccountCannotMintSecondSupplierEvenAfterRevoke() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);

        registry.revokeSupplier(supplierId);
        _assertStatus(registry, supplierId, IUVPSupplierRegistry.SupplierStatus.Revoked);
        assertEq(registry.accountOf(supplierId), ACCOUNT_A);
        assertEq(registry.supplierOf(ACCOUNT_A), supplierId);

        vm.prank(ACCOUNT_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPSupplierRegistry.AccountAlreadyRegistered.selector, ACCOUNT_A, supplierId)
        );
        registry.registerSupplier(ACCOUNT_A);
    }

    function testRegistrarLifecycleKeepsAccountPermanent() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);
        IUVPSupplierRegistry.SupplierStatus pending = IUVPSupplierRegistry.SupplierStatus.Pending;
        IUVPSupplierRegistry.SupplierStatus active = IUVPSupplierRegistry.SupplierStatus.Active;
        IUVPSupplierRegistry.SupplierStatus suspended = IUVPSupplierRegistry.SupplierStatus.Suspended;
        IUVPSupplierRegistry.SupplierStatus revoked = IUVPSupplierRegistry.SupplierStatus.Revoked;

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
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);
        IUVPSupplierRegistry.SupplierStatus pending = IUVPSupplierRegistry.SupplierStatus.Pending;
        IUVPSupplierRegistry.SupplierStatus active = IUVPSupplierRegistry.SupplierStatus.Active;
        IUVPSupplierRegistry.SupplierStatus suspended = IUVPSupplierRegistry.SupplierStatus.Suspended;
        IUVPSupplierRegistry.SupplierStatus revoked = IUVPSupplierRegistry.SupplierStatus.Revoked;

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
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        bytes32 unknownSupplierId = keccak256("supplier:uvp-store:unknown");

        assertEq(registry.accountOf(unknownSupplierId), address(0));
        assertEq(registry.supplierOf(OTHER), bytes32(0));
        assertFalse(registry.isActiveSupplier(unknownSupplierId));

        vm.expectRevert(abi.encodeWithSelector(UVPSupplierRegistry.UnknownSupplier.selector, unknownSupplierId));
        registry.statusOf(unknownSupplierId);

        vm.expectRevert(abi.encodeWithSelector(UVPSupplierRegistry.UnknownSupplier.selector, unknownSupplierId));
        registry.activateSupplier(unknownSupplierId);

        vm.expectRevert(abi.encodeWithSelector(UVPSupplierRegistry.UnknownSupplier.selector, unknownSupplierId));
        registry.revokeSupplier(unknownSupplierId);
    }

    function testOnlyRegistrarMovesStatusAndOnlyOwnerSetsRegistrar() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        bytes32 supplierId = _register(registry, ACCOUNT_A);

        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotRegistrar.selector);
        registry.activateSupplier(supplierId);

        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotOwner.selector);
        registry.setRegistrar(OTHER, true);

        registry.setRegistrar(OTHER, true);
        vm.prank(OTHER);
        registry.activateSupplier(supplierId);
        assertTrue(registry.isActiveSupplier(supplierId));

        registry.setRegistrar(OTHER, false);
        bytes32 secondSupplierId = _register(registry, ACCOUNT_B);
        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotRegistrar.selector);
        registry.activateSupplier(secondSupplierId);

        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotOwner.selector);
        registry.transferOwnership(OTHER);

        registry.transferOwnership(OTHER);
        assertEq(registry.owner(), OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotOwner.selector);
        registry.setRegistrar(ACCOUNT_A, true);
    }

    function _register(UVPSupplierRegistry registry, address account) private returns (bytes32 supplierId) {
        vm.prank(account);
        supplierId = registry.registerSupplier(account);
    }

    function _expectInvalidTransition(
        UVPSupplierRegistry registry,
        bytes32 supplierId,
        IUVPSupplierRegistry.SupplierStatus currentStatus,
        IUVPSupplierRegistry.SupplierStatus nextStatus
    ) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPSupplierRegistry.InvalidSupplierStatusTransition.selector, supplierId, currentStatus, nextStatus
            )
        );
    }

    function _assertStatus(
        UVPSupplierRegistry registry,
        bytes32 supplierId,
        IUVPSupplierRegistry.SupplierStatus expectedStatus
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
