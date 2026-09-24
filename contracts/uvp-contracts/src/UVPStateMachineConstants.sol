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
// 发射适格面条目（admission）：CompactHook 槽位的第四种占用形态——
// hookId 槽承载被发射事实的 signalKey，hookName 槽承载 signalId。与
// 出生/就绪位互斥（chimera flags 在注册边界拒绝）。
uint8 constant _HOOK_FLAG_ADMISSION = 8;

uint64 constant _MAX_HOOK_DELAY_SECONDS = 30 days;

// 依赖键（signalKey）在 commitPlan 注册循环里逐键落 dependencyIndex
// storage，gas 随键数线性增长——上限钉住单笔 commit 的注册成本。能力表/
// 绑定表不设上限：finalizePlan 只写一个 capabilitiesRoot（链下建树、
// 使用方携 Merkle proof 逐叶验证），注册成本与表规模脱钩。
uint256 constant _MAX_PLAN_DEPENDENCIES = 1024;

bytes32 constant _EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
bytes32 constant _EIP712_NAME_HASH = keccak256("UVPStateMachine");
bytes32 constant _EIP712_VERSION_HASH = keccak256("0.12");

// runtime hash 覆盖全部五个承诺域：hooks、能力树、两条 dock 树——
// 不留"产物有、commitment 无"的悬空状态。
bytes32 constant _PLAN_RUNTIME_HASH_DOMAIN = keccak256("uvp.plan.runtime.v3");
bytes32 constant _PLAN_ID_HASH_DOMAIN = keccak256("uvp.plan.id.v1");
bytes32 constant _PLAN_COMMIT_TYPEHASH = keccak256(
    "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
);
