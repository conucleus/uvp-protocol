// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum AdmissionVerdict {
    Wait,
    Impossible,
    Ready
}

uint8 constant _HOOK_FLAG_ORDER_TRIGGER_MINT = 1;
uint8 constant _HOOK_FLAG_EMIT_READY = 4;
uint8 constant _HOOK_FLAG_ADMISSION = 8;
uint8 constant _HOOK_FLAG_DOCK_EXECUTOR = 16;
uint8 constant _HOOK_FLAG_DYNAMIC_EXECUTOR = 32;

uint64 constant _MAX_HOOK_DELAY_SECONDS = 30 days;

uint256 constant _MAX_PLAN_DEPENDENCIES = 1024;

uint256 constant _MAX_HOOKS_PER_DEPENDENCY_KEY = 16;

uint256 constant _MAX_INSTRUCTION_DEPTH = 120;

uint256 constant _MAX_SUPPLIER_BINDINGS = 256;

bytes32 constant _EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
bytes32 constant _EIP712_NAME_HASH = keccak256("UVPStateMachine");
bytes32 constant _EIP712_VERSION_HASH = keccak256("1");

bytes32 constant _PLAN_RUNTIME_HASH_DOMAIN = keccak256("uvp.plan.runtime.v8");
bytes32 constant _PLAN_ID_HASH_DOMAIN = keccak256("uvp.plan.id.v1");
bytes32 constant _PLAN_COMMIT_TYPEHASH = keccak256(
    "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 supplierBindingsRoot,uint256 deadline)"
);
bytes32 constant _SUPPLIER_BINDING_LEAF_DOMAIN = keccak256("UVP_SUPPLIER_BINDING_V1");
bytes32 constant _FACT_ATTRIBUTION_TYPEHASH =
    keccak256("FactAttribution(bytes32 sourceId,bytes32 signalId,bytes32 stageId,bytes32[] capabilityProof)");
bytes32 constant _SIGNAL_SUBMISSION_TYPEHASH = keccak256(
    "UVPStateMachineSignalSubmission(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 targetStageId,bytes32 filesHash,bytes32 attributionHash,address submitter,uint256 deadline)"
);
