// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPSupplierRegistry} from "../src/interfaces/IUVPSupplierRegistry.sol";
import {UVPSupplierRegistryDebug} from "../src/UVPSupplierRegistryDebug.sol";

interface DebugVm {
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
}

contract UVPSupplierRegistryDebugTest {
    DebugVm private constant vm = DebugVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant DEBUG_ACCOUNT = address(0xD3B06);
    address private constant OTHER_ACCOUNT = address(0xA11CE);
    bytes32 private constant SUPPLIER_A = bytes32(uint256(0x1111));
    bytes32 private constant SUPPLIER_B = bytes32(uint256(0x2222));

    function testEveryNonzeroSupplierIdResolvesFixedAccountAsActive() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_ACCOUNT);

        assertEq(registry.accountOf(SUPPLIER_A), DEBUG_ACCOUNT);
        assertEq(registry.accountOf(SUPPLIER_B), DEBUG_ACCOUNT);
        assertTrue(registry.isActiveSupplier(SUPPLIER_A));
        assertTrue(registry.isActiveSupplier(SUPPLIER_B));
        require(
            registry.statusOf(SUPPLIER_A) == IUVPSupplierRegistry.SupplierStatus.Active, "supplier A not active"
        );
        require(
            registry.statusOf(SUPPLIER_B) == IUVPSupplierRegistry.SupplierStatus.Active, "supplier B not active"
        );
        assertEq(registry.supplierOf(DEBUG_ACCOUNT), bytes32(0));
    }

    function testZeroSupplierIdReadsFailClosed() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_ACCOUNT);

        assertEq(registry.accountOf(bytes32(0)), address(0));
        assertFalse(registry.isActiveSupplier(bytes32(0)));
        vm.expectRevert(abi.encodeWithSelector(UVPSupplierRegistryDebug.UnknownSupplier.selector, bytes32(0)));
        registry.statusOf(bytes32(0));
    }

    function testMutationEntrypointsRevertInsteadOfFakingRegistration() public {
        UVPSupplierRegistryDebug registry = new UVPSupplierRegistryDebug(DEBUG_ACCOUNT);

        vm.expectRevert(UVPSupplierRegistryDebug.DebugRegistryIsReadOnly.selector);
        registry.registerSupplier(DEBUG_ACCOUNT);
        vm.expectRevert(UVPSupplierRegistryDebug.DebugRegistryIsReadOnly.selector);
        registry.activateSupplier(SUPPLIER_A);
        vm.expectRevert(UVPSupplierRegistryDebug.DebugRegistryIsReadOnly.selector);
        registry.suspendSupplier(SUPPLIER_A);
        vm.expectRevert(UVPSupplierRegistryDebug.DebugRegistryIsReadOnly.selector);
        registry.revokeSupplier(SUPPLIER_A);
        vm.expectRevert(UVPSupplierRegistryDebug.DebugRegistryIsReadOnly.selector);
        registry.setRegistrar(OTHER_ACCOUNT, true);
        vm.expectRevert(UVPSupplierRegistryDebug.DebugRegistryIsReadOnly.selector);
        registry.transferOwnership(OTHER_ACCOUNT);
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
