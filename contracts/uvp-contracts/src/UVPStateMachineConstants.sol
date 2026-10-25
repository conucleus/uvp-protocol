// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

uint8 constant _HOOK_FLAG_ORDER_TRIGGER_MINT = 1;
uint8 constant _HOOK_FLAG_ORDER_TRIGGER_DOCK = 2;
uint8 constant _HOOK_FLAG_EMIT_READY = 4;
uint8 constant _HOOK_FLAG_ADMISSION = 8;

uint64 constant _MAX_HOOK_DELAY_SECONDS = 30 days;

uint256 constant _MAX_PLAN_DEPENDENCIES = 1024;

uint256 constant _MAX_HOOKS_PER_DEPENDENCY_KEY = 16;

uint256 constant _MAX_INSTRUCTION_DEPTH = 120;

bytes32 constant _EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
bytes32 constant _EIP712_NAME_HASH = keccak256("UVPStateMachine");
bytes32 constant _EIP712_VERSION_HASH = keccak256("0.15");

bytes32 constant _PLAN_RUNTIME_HASH_DOMAIN = keccak256("uvp.plan.runtime.v4");
bytes32 constant _PLAN_ID_HASH_DOMAIN = keccak256("uvp.plan.id.v1");
bytes32 constant _PLAN_COMMIT_TYPEHASH = keccak256(
    "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
);
bytes32 constant _EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");
