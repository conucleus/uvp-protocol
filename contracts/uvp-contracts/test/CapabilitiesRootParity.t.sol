// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";

interface CapabilitiesRootVm {
    function projectRoot() external view returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function parseJsonBytes32(string calldata json, string calldata key) external view returns (bytes32);
    function parseJsonUint(string calldata json, string calldata key) external view returns (uint256);
}

contract CapabilitiesRootParityTest {
    CapabilitiesRootVm private constant vm =
        CapabilitiesRootVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _fixture() private view returns (string memory) {
        return vm.readFile(
            string.concat(vm.projectRoot(), "/../../packages/compiler/fixtures/capabilities-root/v1/vectors.json")
        );
    }

    function _sample(uint256 sample) private pure returns (string memory) {
        require(sample < GOLDEN_SAMPLE_COUNT, "capabilities-root golden sample out of range");
        return string.concat(".samples[", toString(sample), "]");
    }

    function _count(string memory json, string memory base) private view returns (uint256) {
        return vm.parseJsonUint(json, base);
    }

    uint256 private constant GOLDEN_SAMPLE_COUNT = 5;

    function testMixedTablesOddLeavesSampleMatches() public {
        _assertSampleMatches(0);
    }

    function testDuplicateLeavesDedupSampleMatches() public {
        _assertSampleMatches(1);
    }

    function testDeepTreeSampleMatches() public {
        _assertSampleMatches(2);
    }

    function testLargeTablesSampleMatches() public {
        _assertSampleMatches(3);
    }

    function testDuplicatePayloadHeavySampleMatches() public {
        _assertSampleMatches(4);
    }

    function _assertSampleMatches(uint256 sampleIndex) private {
        string memory fixture = _fixture();
        string memory sample = _sample(sampleIndex);
        UVPPlanMetadataModule metadataModule = new UVPPlanMetadataModule(address(0));

        uint256 bindingCount = _count(fixture, string.concat(sample, ".counts.selectorBindings"));
        uint256 capabilityCount = _count(fixture, string.concat(sample, ".counts.signalCapabilities"));
        require(bindingCount > 0 && capabilityCount > 0, "capabilities-root golden empty sample");

        bytes32 rootValue = vm.parseJsonBytes32(fixture, string.concat(sample, ".expected.root"));
        uint256 uniqueCount = _count(fixture, string.concat(sample, ".counts.sortedUniqueLeaves"));

        bytes32[] memory rawLeaves = new bytes32[](bindingCount + capabilityCount);
        uint256 cursor;

        for (uint256 i = 0; i < bindingCount; i++) {
            string memory inputBase = string.concat(sample, ".inputs.selectorBindings[", toString(i), "]");
            string memory expectedBase = string.concat(sample, ".expected.selectorBindingLeaves[", toString(i), "]");
            bytes32 leafValue = metadataModule.selectorBindingLeaf(
                vm.parseJsonBytes32(fixture, string.concat(inputBase, ".selectorStageId")),
                vm.parseJsonBytes32(fixture, string.concat(inputBase, ".targetStageId"))
            );
            _assertLeafAndProof(fixture, rootValue, leafValue, expectedBase);
            rawLeaves[cursor++] = leafValue;
        }

        for (uint256 i = 0; i < capabilityCount; i++) {
            string memory inputBase = string.concat(sample, ".inputs.signalCapabilities[", toString(i), "]");
            string memory expectedBase = string.concat(sample, ".expected.signalCapabilityLeaves[", toString(i), "]");
            bytes32 leafValue = metadataModule.signalCapabilityLeaf(
                vm.parseJsonBytes32(fixture, string.concat(inputBase, ".stageId")),
                vm.parseJsonBytes32(fixture, string.concat(inputBase, ".targetSourceId")),
                vm.parseJsonBytes32(fixture, string.concat(inputBase, ".signalId")),
                uint8(vm.parseJsonUint(fixture, string.concat(inputBase, ".targetOrderRelation")))
            );
            _assertLeafAndProof(fixture, rootValue, leafValue, expectedBase);
            rawLeaves[cursor++] = leafValue;
        }

        require(DockMerkle.root(rawLeaves) == rootValue, "capabilities-root golden root mismatch");

        bytes32[] memory uniqueLeaves = new bytes32[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            uniqueLeaves[i] =
                vm.parseJsonBytes32(fixture, string.concat(sample, ".expected.sortedUniqueLeaves[", toString(i), "]"));
            if (i > 0) {
                require(uniqueLeaves[i - 1] < uniqueLeaves[i], "capabilities-root golden leaves not strictly ascending");
            }
        }
        require(DockMerkle.root(uniqueLeaves) == rootValue, "capabilities-root golden unique-leaf root mismatch");
    }

    function _assertLeafAndProof(
        string memory fixture,
        bytes32 rootValue,
        bytes32 leafValue,
        string memory expectedBase
    ) private view {
        require(leafValue == vm.parseJsonBytes32(fixture, string.concat(expectedBase, ".leaf")), "leaf mismatch");
        uint256 proofLength = _count(fixture, string.concat(expectedBase, ".proofLength"));
        bytes32[] memory proof = new bytes32[](proofLength);
        for (uint256 i = 0; i < proofLength; i++) {
            proof[i] = vm.parseJsonBytes32(fixture, string.concat(expectedBase, ".proof[", toString(i), "]"));
        }
        require(DockMerkle.verify(rootValue, leafValue, proof), "proof does not verify against root");
    }

    function toString(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 buffer = value;
        uint256 digits;
        while (buffer != 0) {
            digits++;
            buffer /= 10;
        }
        bytes memory result = new bytes(digits);
        uint256 index = digits;
        buffer = value;
        while (buffer != 0) {
            index--;
            result[index] = bytes1(uint8(48 + (buffer % 10)));
            buffer /= 10;
        }
        return string(result);
    }
}
