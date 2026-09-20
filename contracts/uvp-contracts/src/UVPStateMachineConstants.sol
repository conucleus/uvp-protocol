// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// 主合约 UVPStateMachine 与计划生命周期库 UVPPlanRegistration 共享的编译期
// 常量，文件级单一声明点，消除双份漂移面。Solidity 0.8.24 禁止 library
// 继承，故以文件级常量承载双方引用；均为编译期值，无 storage、无 ABI 影响。
// 主合约以 public constant 重导出 hook 标志与上限（保持拆分前的 ABI
// getter），其余供双方直接引用。

uint8 constant _HOOK_FLAG_ORDER_TRIGGER_MINT = 1;
uint8 constant _HOOK_FLAG_ORDER_TRIGGER_DOCK = 2;
uint8 constant _HOOK_FLAG_EMIT_READY = 4;
uint64 constant _MAX_HOOK_DELAY_SECONDS = 30 days;
uint256 constant _MAX_PLAN_DEPENDENCIES = 1024;
// finalizePlan 的元数据规模上限：selectorBindings 与 signalCapabilities
// 逐条写存储的注册循环 gas 随表规模无界增长（M24：≈324 条 binding 在
// 30M block gas 内恒 OOG，planId 烧死在 committed 态）。注册库在本上限
// 上先于 metadataHash 重算 fail-fast；UVPPlanMetadataModule 以 public
// constant 重导出并兜底。
uint256 constant _MAX_SIGNAL_CAPABILITIES = 256;
uint256 constant _MAX_SELECTOR_BINDINGS = 128;

bytes32 constant _EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
bytes32 constant _EIP712_NAME_HASH = keccak256("UVPStateMachine");
bytes32 constant _EIP712_VERSION_HASH = keccak256("0.10");
bytes32 constant _PLAN_RUNTIME_HASH_DOMAIN = keccak256("uvp.plan.runtime.v2");
bytes32 constant _PLAN_ID_HASH_DOMAIN = keccak256("uvp.plan.id.v1");
bytes32 constant _PLAN_COMMIT_TYPEHASH = keccak256(
    "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 metadataHash,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
);
