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
// 0.12 → 0.13（UB-36①④/UB-39 破坏性 ABI 批）：委托授权通道与
// REPLACEMENT patch 模式退役、per-stage 原生计数、executor 候选集根、
// forkOrder 出生通道、PlanCommit 增 executorCandidatesRoot 槽。EIP-712
// 域版本随公共摘要面（PlanCommit/patch digest 结构变化）同步升位。
bytes32 constant _EIP712_VERSION_HASH = keccak256("0.13");

// runtime hash 覆盖全部六个承诺域：hooks、能力树、两条 dock 树、执行者
// 候选集树——不留"产物有、commitment 无"的悬空状态。v3 → v4：编码追加了
// executorCandidatesRoot 槽（UB-36②③），升域字符串避免跨版本哈希撞形。
bytes32 constant _PLAN_RUNTIME_HASH_DOMAIN = keccak256("uvp.plan.runtime.v4");
bytes32 constant _PLAN_ID_HASH_DOMAIN = keccak256("uvp.plan.id.v1");
bytes32 constant _PLAN_COMMIT_TYPEHASH = keccak256(
    "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,uint256 deadline)"
);
// 执行者候选集叶域（UB-36②③）：叶 = keccak256(abi.encodePacked(
// _EXECUTOR_CANDIDATE_LEAF_DOMAIN, stageId, executor))，DockMerkle 同款
// 排序去重建树；空集 = DockMerkle.EMPTY_ROOT（该形态下逐单 executor
// patch 恒拒——不开候选集的计划没有逐单换人面）。
bytes32 constant _EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");
