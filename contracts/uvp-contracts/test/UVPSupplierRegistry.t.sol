// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPSupplierRegistry} from "../src/UVPSupplierRegistry.sol";

interface Vm {
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function prank(address) external;
}

contract UVPSupplierRegistryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant EXECUTOR_A = address(0xA11CE);
    address private constant EXECUTOR_B = address(0xB0B);
    address private constant EXECUTOR_C = address(0xC0FFEE);
    address private constant OTHER = address(0xCAFE);
    bytes32 private constant SUPPLIER_A = keccak256("supplier:uvp-store:acme");
    bytes32 private constant SUPPLIER_B = keccak256("supplier:uvp-store:other");

    function testOwnerRegistersSupplier() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);

        assertEq(registry.executorOf(SUPPLIER_A), EXECUTOR_A);
        assertEq(registry.supplierOf(EXECUTOR_A), SUPPLIER_A);
        assertTrue(registry.isRegisteredSupplier(SUPPLIER_A));
        assertFalse(registry.isRegisteredSupplier(SUPPLIER_B));
    }

    function testRegisterRejectsDuplicateSupplier() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);

        vm.expectRevert(abi.encodeWithSelector(UVPSupplierRegistry.SupplierAlreadyRegistered.selector, SUPPLIER_A));
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_B);
    }

    function testRegisterRejectsDuplicateExecutor() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);

        vm.expectRevert(
            abi.encodeWithSelector(UVPSupplierRegistry.ExecutorAlreadyBound.selector, EXECUTOR_A, SUPPLIER_A)
        );
        registry.registerSupplier(SUPPLIER_B, EXECUTOR_A);
    }

    function testRotateClearsPreviousExecutorAndRejectsCollision() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);
        registry.registerSupplier(SUPPLIER_B, EXECUTOR_B);

        vm.expectRevert(
            abi.encodeWithSelector(UVPSupplierRegistry.ExecutorAlreadyBound.selector, EXECUTOR_B, SUPPLIER_B)
        );
        registry.rotateSupplierExecutor(SUPPLIER_A, EXECUTOR_B);

        registry.rotateSupplierExecutor(SUPPLIER_A, EXECUTOR_C);
        assertEq(registry.executorOf(SUPPLIER_A), EXECUTOR_C);
        assertEq(registry.supplierOf(EXECUTOR_C), SUPPLIER_A);
        assertEq(registry.supplierOf(EXECUTOR_A), bytes32(0));
        assertEq(registry.supplierOf(EXECUTOR_B), SUPPLIER_B);
    }

    function testRevokeClearsBothDirections() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);

        registry.revokeSupplier(SUPPLIER_A);
        assertEq(registry.executorOf(SUPPLIER_A), address(0));
        assertEq(registry.supplierOf(EXECUTOR_A), bytes32(0));
        assertFalse(registry.isRegisteredSupplier(SUPPLIER_A));

        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);
        assertEq(registry.executorOf(SUPPLIER_A), EXECUTOR_A);
        assertEq(registry.supplierOf(EXECUTOR_A), SUPPLIER_A);
    }

    function testRegistrarAuthorization() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();

        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotOwner.selector);
        registry.setRegistrar(OTHER, true);

        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotRegistrar.selector);
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);

        registry.setRegistrar(OTHER, true);

        vm.prank(OTHER);
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);
        assertEq(registry.executorOf(SUPPLIER_A), EXECUTOR_A);

        vm.prank(OTHER);
        registry.rotateSupplierExecutor(SUPPLIER_A, EXECUTOR_B);
        assertEq(registry.executorOf(SUPPLIER_A), EXECUTOR_B);

        vm.prank(OTHER);
        registry.revokeSupplier(SUPPLIER_A);
        assertEq(registry.executorOf(SUPPLIER_A), address(0));

        registry.setRegistrar(OTHER, false);

        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotRegistrar.selector);
        registry.registerSupplier(SUPPLIER_A, EXECUTOR_A);
    }

    function testTransferOwnershipMovesAdminRights() public {
        UVPSupplierRegistry registry = new UVPSupplierRegistry();

        vm.prank(OTHER);
        vm.expectRevert(UVPSupplierRegistry.NotOwner.selector);
        registry.transferOwnership(OTHER);

        registry.transferOwnership(OTHER);
        assertEq(registry.owner(), OTHER);

        vm.expectRevert(UVPSupplierRegistry.NotOwner.selector);
        registry.setRegistrar(OTHER, true);

        vm.prank(OTHER);
        registry.setRegistrar(OTHER, true);
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
}
