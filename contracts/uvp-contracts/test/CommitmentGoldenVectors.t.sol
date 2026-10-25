// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";

interface CommitmentVm {
    function projectRoot() external view returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function parseJsonBytes32(string calldata json, string calldata key) external view returns (bytes32);
    function parseJsonUint(string calldata json, string calldata key) external view returns (uint256);
    function parseJsonString(string calldata json, string calldata key) external view returns (string memory);
    function parseJsonAddress(string calldata json, string calldata key) external view returns (address);
}

contract CommitmentGoldenVectorsTest {
    CommitmentVm private constant vm = CommitmentVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private constant HOOK_PLAN_HASH_DOMAIN = "uvp:hook-plan-artifact:v1";
    string private constant ONCHAIN_PLAN_HASH_DOMAIN = "uvp:onchain-hook-plan-artifact:v1";

    uint256 private constant CASE_COUNT = 10;
    uint256 private constant REGISTER_HOOKS_VECTOR_COUNT = 1;

    function _fixture() private view returns (string memory) {
        return
            vm.readFile(
                string.concat(vm.projectRoot(), "/../../../uvp-core/fixtures/commitments/golden-vectors.v1.json")
            );
    }

    function testSchemaVersionMatches() public view {
        string memory fixture = _fixture();
        require(
            keccak256(bytes(vm.parseJsonString(fixture, ".schemaVersion")))
                == keccak256(bytes("uvp.commitmentGoldenVectors.v1")),
            "commitment golden vectors schemaVersion drifted"
        );
    }

    function testRegisterHooksVectorsMatch() public view {
        string memory fixture = _fixture();
        for (uint256 i = 0; i < REGISTER_HOOKS_VECTOR_COUNT; i++) {
            string memory base = string.concat(".registerHooksVectors[", toString(i), "]");
            uint256 hookCount = vm.parseJsonUint(fixture, string.concat(base, ".counts.hooks"));
            UVPStateMachine.CompactHook[] memory hooks = _readHooks(fixture, base, hookCount);
            require(
                keccak256(abi.encode(hooks))
                    == vm.parseJsonBytes32(fixture, string.concat(base, ".expected.hooksHash")),
                "register-hooks golden hooksHash mismatch"
            );
        }
    }

    function testCaseCountsArePinned() public {
        string memory fixture = _fixture();
        (bool caseBeyond,) =
            _tryAddress(fixture, string.concat(".cases[", toString(CASE_COUNT), "].expected.hooksHash"));
        require(!caseBeyond, "commitment golden cases grew; bump CASE_COUNT and add entrypoints");
        (bool vectorBeyond,) = _tryAddress(
            fixture,
            string.concat(".registerHooksVectors[", toString(REGISTER_HOOKS_VECTOR_COUNT), "].expected.hooksHash")
        );
        require(!vectorBeyond, "register-hooks golden vectors grew; bump REGISTER_HOOKS_VECTOR_COUNT");
    }

    function _tryAddress(string memory json, string memory path) private returns (bool ok, address value) {
        try vm.parseJsonAddress(json, path) returns (address parsed) {
            return (true, parsed);
        } catch {
            return (false, address(0));
        }
    }

    function testCase0Matches() public {
        _assertCaseMatches(0);
    }

    function testCase1Matches() public {
        _assertCaseMatches(1);
    }

    function testCase2Matches() public {
        _assertCaseMatches(2);
    }

    function testCase3Matches() public {
        _assertCaseMatches(3);
    }

    function testCase4Matches() public {
        _assertCaseMatches(4);
    }

    function testCase5Matches() public {
        _assertCaseMatches(5);
    }

    function testCase6Matches() public {
        _assertCaseMatches(6);
    }

    function testCase7Matches() public {
        _assertCaseMatches(7);
    }

    function testCase8Matches() public {
        _assertCaseMatches(8);
    }

    function testCase9Matches() public {
        _assertCaseMatches(9);
    }

    function _assertCaseMatches(uint256 caseIndex) private {
        require(caseIndex < CASE_COUNT, "commitment golden case out of range");
        string memory fixture = _fixture();
        string memory base = string.concat(".cases[", toString(caseIndex), "]");
        uint256 hookCount = vm.parseJsonUint(fixture, string.concat(base, ".counts.hooks"));
        require(hookCount > 0, "commitment golden case carries no hooks");

        UVPStateMachine.CompactHook[] memory hooks = _readHooks(fixture, base, hookCount);
        bytes32 hooksHash = keccak256(abi.encode(hooks));
        require(
            hooksHash == vm.parseJsonBytes32(fixture, string.concat(base, ".expected.hooksHash")),
            "commitment golden hooksHash mismatch"
        );

        UVPStateMachine machine = new UVPStateMachine();
        bytes32 runtimePlanHash = machine.planRuntimeHash(
            hooksHash,
            vm.parseJsonBytes32(fixture, string.concat(base, ".expected.capabilitiesRoot")),
            vm.parseJsonBytes32(fixture, string.concat(base, ".expected.dockRoutesRoot")),
            vm.parseJsonBytes32(fixture, string.concat(base, ".expected.dockInterfaceRoot")),
            vm.parseJsonBytes32(fixture, string.concat(base, ".expected.executorCandidatesRoot"))
        );
        require(
            runtimePlanHash == vm.parseJsonBytes32(fixture, string.concat(base, ".expected.runtimePlanHash")),
            "commitment golden runtime planHash mismatch"
        );

        require(
            keccak256(
                bytes(
                    string.concat(
                        HOOK_PLAN_HASH_DOMAIN,
                        ":",
                        vm.parseJsonString(fixture, string.concat(base, ".preimages.hookPlanCanonical"))
                    )
                )
            ) == vm.parseJsonBytes32(fixture, string.concat(base, ".expected.hookPlanHash")),
            "commitment golden hookPlanHash preimage mismatch"
        );
        require(
            keccak256(
                bytes(
                    string.concat(
                        ONCHAIN_PLAN_HASH_DOMAIN,
                        ":",
                        vm.parseJsonString(fixture, string.concat(base, ".preimages.onchainPlanCanonical"))
                    )
                )
            ) == vm.parseJsonBytes32(fixture, string.concat(base, ".expected.onchainPlanHash")),
            "commitment golden onchainPlanHash preimage mismatch"
        );
    }

    function _readHooks(string memory fixture, string memory base, uint256 hookCount)
        private
        view
        returns (UVPStateMachine.CompactHook[] memory)
    {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](hookCount);
        for (uint256 i = 0; i < hookCount; i++) {
            string memory hookBase = string.concat(base, ".input.hooks[", toString(i), "]");
            uint256 instructionCount =
                vm.parseJsonUint(fixture, string.concat(base, ".counts.instructions[", toString(i), "]"));
            uint256 dependencyCount =
                vm.parseJsonUint(fixture, string.concat(base, ".counts.dependencyKeys[", toString(i), "]"));

            UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](instructionCount);
            for (uint256 j = 0; j < instructionCount; j++) {
                string memory instructionBase = string.concat(hookBase, ".instructions[", toString(j), "]");
                instructions[j] = UVPStateMachine.Instruction({
                    op: uint8(vm.parseJsonUint(fixture, string.concat(instructionBase, ".op"))),
                    sourceId: vm.parseJsonBytes32(fixture, string.concat(instructionBase, ".sourceId")),
                    signalId: vm.parseJsonBytes32(fixture, string.concat(instructionBase, ".signalId")),
                    arity: uint16(vm.parseJsonUint(fixture, string.concat(instructionBase, ".arity"))),
                    delaySeconds: uint64(vm.parseJsonUint(fixture, string.concat(instructionBase, ".delaySeconds")))
                });
            }

            bytes32[] memory dependencyKeys = new bytes32[](dependencyCount);
            for (uint256 k = 0; k < dependencyCount; k++) {
                dependencyKeys[k] =
                    vm.parseJsonBytes32(fixture, string.concat(hookBase, ".dependencyKeys[", toString(k), "]"));
            }

            hooks[i] = UVPStateMachine.CompactHook({
                hookId: vm.parseJsonBytes32(fixture, string.concat(hookBase, ".hookId")),
                stageId: vm.parseJsonBytes32(fixture, string.concat(hookBase, ".stageId")),
                hookName: vm.parseJsonBytes32(fixture, string.concat(hookBase, ".hookName")),
                flags: uint8(vm.parseJsonUint(fixture, string.concat(hookBase, ".flags"))),
                instructions: instructions,
                dependencyKeys: dependencyKeys
            });
        }
        return hooks;
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
