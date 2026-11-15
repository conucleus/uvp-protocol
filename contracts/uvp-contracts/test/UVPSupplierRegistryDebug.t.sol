// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPSupplierRegistryDebug} from "../src/UVPSupplierRegistryDebug.sol";
import {IUVPSupplierRegistry} from "../src/interfaces/IUVPSupplierRegistry.sol";

interface Vm {
    function expectRevert(bytes4) external;
    function prank(address) external;
}

contract UVPSupplierRegistryDebugTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant DEBUG_EXECUTOR = address(0xD3B06);
    address private constant EXPLICIT_EXECUTOR = address(0xA11CE);
    address private constant OTHER_EXECUTOR = address(0xB0B);
    address private constant NON_OWNER = address(0xCAFE);
    bytes32 private constant SUPPLIER_A = keccak256("supplier:uvp-store:acme");
    bytes32 private constant SUPPLIER_B = keccak256("supplier:uvp-store:other");
    bytes32 private constant SUPPLIER_NEVER_REGISTERED = keccak256("supplier:uvp-store:never");

    function testAnyNonzeroSupplierIdResolvesDebugExecutor() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_EXECUTOR);

        require(registry.executorOf(SUPPLIER_A) == DEBUG_EXECUTOR, "supplier A not resolved");
        require(registry.executorOf(SUPPLIER_B) == DEBUG_EXECUTOR, "supplier B not resolved");
        require(registry.executorOf(bytes32(uint256(1))) == DEBUG_EXECUTOR, "arbitrary supplier not resolved");
    }

    function testDebugSetExecutorOverridesSupplier() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_EXECUTOR);

        registry.debugSetExecutor(SUPPLIER_A, EXPLICIT_EXECUTOR);
        require(registry.executorOf(SUPPLIER_A) == EXPLICIT_EXECUTOR, "explicit executor not resolved");
        require(registry.supplierOf(EXPLICIT_EXECUTOR) == SUPPLIER_A, "explicit supplier not resolved");
        require(registry.executorOf(SUPPLIER_B) == DEBUG_EXECUTOR, "fallback executor changed");

        registry.debugSetExecutor(SUPPLIER_A, OTHER_EXECUTOR);
        require(registry.executorOf(SUPPLIER_A) == OTHER_EXECUTOR, "executor not overridden");
        require(registry.supplierOf(OTHER_EXECUTOR) == SUPPLIER_A, "rotated supplier not resolved");
        require(registry.supplierOf(EXPLICIT_EXECUTOR) == bytes32(0), "stale supplier binding");

        vm.prank(NON_OWNER);
        vm.expectRevert(UVPSupplierRegistryDebug.NotOwner.selector);
        registry.debugSetExecutor(SUPPLIER_B, NON_OWNER);
    }

    function testIsRegisteredSupplierWithoutRegistration() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_EXECUTOR);

        require(registry.isRegisteredSupplier(SUPPLIER_A), "supplier A not registered");
        require(registry.isRegisteredSupplier(SUPPLIER_NEVER_REGISTERED), "unregistered supplier rejected");
    }

    function testStateMachineResolvesDebugExecutorThroughSupplierRegistrySlot() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_EXECUTOR);
        UVPStateMachine machine = new UVPStateMachine();
        machine.setSupplierRegistry(address(registry));

        IUVPSupplierRegistry slotRegistry = IUVPSupplierRegistry(machine.supplierRegistry());
        require(address(slotRegistry) == address(registry), "supplier registry slot mismatch");
        require(slotRegistry.isRegisteredSupplier(SUPPLIER_NEVER_REGISTERED), "slot supplier not registered");
        require(slotRegistry.executorOf(SUPPLIER_NEVER_REGISTERED) == DEBUG_EXECUTOR, "slot executor mismatch");
    }

    function testZeroSupplierIdIsRejectedAndUnregistered() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_EXECUTOR);

        require(registry.executorOf(bytes32(0)) == address(0), "zero supplier resolved");
        require(!registry.isRegisteredSupplier(bytes32(0)), "zero supplier registered");
        require(registry.supplierOf(address(0)) == bytes32(0), "zero executor bound");

        vm.expectRevert(UVPSupplierRegistryDebug.ZeroSupplierId.selector);
        registry.debugSetExecutor(bytes32(0), EXPLICIT_EXECUTOR);
    }
}
