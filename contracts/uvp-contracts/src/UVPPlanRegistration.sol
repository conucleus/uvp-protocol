// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {UVPStateMachine} from "./UVPStateMachine.sol";
import {
    _HOOK_FLAG_ORDER_TRIGGER_MINT as HOOK_FLAG_ORDER_TRIGGER_MINT,
    _HOOK_FLAG_ORDER_TRIGGER_DOCK as HOOK_FLAG_ORDER_TRIGGER_DOCK,
    _HOOK_FLAG_EMIT_READY as HOOK_FLAG_EMIT_READY,
    _MAX_HOOK_DELAY_SECONDS as MAX_HOOK_DELAY_SECONDS,
    _MAX_PLAN_DEPENDENCIES as MAX_PLAN_DEPENDENCIES,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN,
    _PLAN_COMMIT_TYPEHASH
} from "./UVPStateMachineConstants.sol";

/// 计划生命周期库：commitPlan / finalizePlan 及其全部注册边界校验。
/// 以 Solidity 外部链接库机制部署，主合约经 DELEGATECALL 调用——状态写入
/// 主合约存储，address(this) 仍是主合约（EIP-712 域、事件 emitter、模块侧
/// msg.sender 鉴权全部保持）。库地址在链接时固定，只允许链接与本合约同批
/// 审查的代码；禁止将任何调用目标改为可变地址。
library UVPPlanRegistration {
    function commitPlan(
        mapping(bytes32 => UVPStateMachine.Plan) storage _plans,
        bool modulesFrozen,
        UVPStateMachine.PlanCommit calldata commit,
        UVPStateMachine.CompactHook[] calldata hooks,
        bytes calldata signature
    ) public returns (bytes32 planId) {
        if (!modulesFrozen) {
            revert UVPStateMachine.ModulesNotFrozen();
        }
        if (block.timestamp > commit.deadline) {
            revert UVPStateMachine.ExpiredPlanSignature(commit.deadline);
        }
        if (commit.publisher == address(0)) {
            revert UVPStateMachine.ZeroPlanPublisher();
        }
        if (hooks.length == 0) {
            revert UVPStateMachine.EmptyPlan();
        }
        bytes32 actualHooksHash = keccak256(abi.encode(hooks));
        if (actualHooksHash != commit.hooksHash) {
            revert UVPStateMachine.PlanMetadataHashMismatch(commit.hooksHash, actualHooksHash);
        }
        address recoveredSigner = _recoverSignalSubmitter(_planCommitDigest(commit), signature);
        if (recoveredSigner != commit.publisher) {
            revert UVPStateMachine.InvalidPlanSignature(commit.publisher, recoveredSigner);
        }

        bytes32 dockRoutesRoot = commit.dockRoutesRoot == bytes32(0) ? DockMerkle.EMPTY_ROOT : commit.dockRoutesRoot;
        bytes32 dockInterfaceRoot =
            commit.dockInterfaceRoot == bytes32(0) ? DockMerkle.EMPTY_ROOT : commit.dockInterfaceRoot;
        bytes32 runtimePlanHash =
            planRuntimeHash(commit.hooksHash, commit.metadataHash, dockRoutesRoot, dockInterfaceRoot);
        planId = planIdFor(commit.publisher, runtimePlanHash);
        UVPStateMachine.Plan storage plan = _plans[planId];
        if (plan.committed) {
            revert UVPStateMachine.PlanAlreadyRegistered();
        }
        plan.planHash = runtimePlanHash;
        plan.hooksHash = commit.hooksHash;
        plan.metadataHash = commit.metadataHash;
        plan.dockRoutesRoot = dockRoutesRoot;
        plan.dockInterfaceRoot = dockInterfaceRoot;
        plan.publisher = commit.publisher;
        plan.committed = true;

        // Cross-stage dependency scan scratch: scoped so the large memory
        // arrays release their stack slots before the commit events fire.
        {
            bytes32[] memory seenKeys = new bytes32[](MAX_PLAN_DEPENDENCIES);
            bytes32[] memory seenStages = new bytes32[](MAX_PLAN_DEPENDENCIES);
            bool[] memory seenTriggerOnly = new bool[](MAX_PLAN_DEPENDENCIES);
            // 阶段物化防御纵深：每个被注册 hook 的阶段必须至少有
            // 一个 order-trigger 或 EMIT_READY hook——纯 flags=0 watcher 阶段
            // 在链上永远无法物化（物化只由本阶段 hook Ready 触发，executor
            // patch 不物化），其 watcher 会让共享信号键的提交交易稳定回滚。
            // 编译器是第一道防线；这里是注册边界。
            bytes32[] memory stageScratch = new bytes32[](hooks.length);
            bool[] memory stageMaterializer = new bool[](hooks.length);
            uint256 seenCount;
            for (uint256 i = 0; i < hooks.length; i++) {
                seenCount = _registerPlanHook(plan, hooks[i], seenKeys, seenStages, seenTriggerOnly, seenCount);
                uint256 stageIndex = _seenDependencyIndex(stageScratch, i, hooks[i].stageId);
                if (stageIndex == type(uint256).max) {
                    stageScratch[i] = hooks[i].stageId;
                    stageMaterializer[i] = _hookCanMaterializeStage(hooks[i].flags);
                } else if (_hookCanMaterializeStage(hooks[i].flags)) {
                    stageMaterializer[stageIndex] = true;
                }
            }
            for (uint256 i = 0; i < hooks.length; i++) {
                if (stageScratch[i] == bytes32(0)) {
                    continue;
                }
                if (!stageMaterializer[i]) {
                    revert UVPStateMachine.StageNotMaterializable(stageScratch[i]);
                }
            }
        }

        emit UVPStateMachine.PlanCommitted(
            planId,
            runtimePlanHash,
            commit.publisher,
            commit.hooksHash,
            commit.metadataHash,
            hooks.length,
            dockRoutesRoot,
            dockInterfaceRoot
        );
        emit UVPStateMachine.PlanPublisherRecorded(planId, commit.publisher);
    }

    function finalizePlan(
        mapping(bytes32 => UVPStateMachine.Plan) storage _plans,
        address planMetadataModule,
        bytes32 planId,
        IUVPPlanMetadataModule.StageSelectorBinding[] calldata selectorBindings,
        IUVPPlanMetadataModule.SignalCapability[] calldata signalCapabilities
    ) public {
        UVPStateMachine.Plan storage plan = _plans[planId];
        if (!plan.committed) {
            revert UVPStateMachine.PlanNotCommitted();
        }
        if (plan.finalized) {
            revert UVPStateMachine.PlanAlreadyFinalized();
        }
        bytes32 actualMetadataHash = keccak256(abi.encode(selectorBindings, signalCapabilities));
        if (actualMetadataHash != plan.metadataHash) {
            revert UVPStateMachine.PlanMetadataHashMismatch(plan.metadataHash, actualMetadataHash);
        }

        // CEI：finalized 先于模块外调落定。模块回调（如重入 finalizePlan）
        // 必须看到已终态并按 PlanAlreadyFinalized 拒绝，而不是在 finalized
        // 落定前的窗口里二次过门。
        plan.finalized = true;
        IUVPPlanMetadataModule(planMetadataModule)
            .finalizePlanMetadata(
                planId, selectorBindings, signalCapabilities, plan.dockRoutesRoot, plan.dockInterfaceRoot
            );

        emit UVPStateMachine.PlanFinalized(planId, plan.planHash, plan.metadataHash);
        emit UVPStateMachine.PlanRegistered(planId, plan.planHash, plan.hookIds.length);
    }

    function _registerPlanHook(
        UVPStateMachine.Plan storage plan,
        UVPStateMachine.CompactHook calldata input,
        bytes32[] memory seenKeys,
        bytes32[] memory seenStages,
        bool[] memory seenTriggerOnly,
        uint256 seenCount
    ) private returns (uint256) {
        _validateHook(input);
        // 出生语义互斥——MINT 与 DOCK 不可同挂一个 hook。
        if (
            input.flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK)
                == (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK)
        ) {
            revert UVPStateMachine.InvalidHook();
        }
        // HookReady 三线口径统一：order-trigger 必须携带 EMIT_READY——编译器
        // 产物恒为 trigger|EMIT_READY；沉默 trigger（flags=1/2）的 HookReady
        // 发出口径在链上链下会分叉。与下方阶段物化守卫同构：注册边界拒绝。
        if (_isOrderTrigger(input.flags) && input.flags & HOOK_FLAG_EMIT_READY == 0) {
            revert UVPStateMachine.SilentOrderTriggerHook(input.hookId);
        }
        if (plan.hooks[input.hookId].exists) {
            revert UVPStateMachine.HookAlreadyRegistered();
        }

        UVPStateMachine.StoredHook storage hook = plan.hooks[input.hookId];
        hook.hookId = input.hookId;
        hook.stageId = input.stageId;
        hook.hookName = input.hookName;
        hook.flags = input.flags;
        hook.exists = true;

        for (uint256 j = 0; j < input.instructions.length; j++) {
            hook.instructions.push(input.instructions[j]);
        }

        uint256 updatedCount = seenCount;
        // 同一 hook 输入内的重复 dependencyKey 先去重。重复项会
        // 逐次推入 plan.dependencyIndex，此后该键每次信号提交都重复执行
        // _evaluateHook N 次，N 足够大即永久 OOG。
        uint256 inputKeyCount = 0;
        bytes32[] memory inputKeys = new bytes32[](input.dependencyKeys.length);
        for (uint256 j = 0; j < input.dependencyKeys.length; j++) {
            bytes32 dependencyKey = input.dependencyKeys[j];
            bool duplicatedInput = false;
            for (uint256 k = 0; k < inputKeyCount; k++) {
                if (inputKeys[k] == dependencyKey) {
                    duplicatedInput = true;
                    break;
                }
            }
            if (duplicatedInput) {
                continue;
            }
            inputKeys[inputKeyCount] = dependencyKey;
            inputKeyCount += 1;

            // Trigger watchers crossing stages are the normal selectedStages
            // flow: the evaluation guard skips triggers of unmaterialized
            // stages. The brick is a NON-trigger watcher in a stage that has
            // not materialized yet -- submitting the shared key would revert
            // that transaction forever.
            uint256 watcherIndex = _seenDependencyIndex(seenKeys, updatedCount, dependencyKey);
            if (watcherIndex == type(uint256).max) {
                if (updatedCount == seenKeys.length) {
                    revert UVPStateMachine.TooManyDependencies();
                }
                seenKeys[updatedCount] = dependencyKey;
                seenStages[updatedCount] = input.stageId;
                seenTriggerOnly[updatedCount] = _isOrderTrigger(input.flags);
                updatedCount += 1;
            } else {
                bool triggerOnly = seenTriggerOnly[watcherIndex] && _isOrderTrigger(input.flags);
                if (seenStages[watcherIndex] != input.stageId && !triggerOnly) {
                    revert UVPStateMachine.CrossStageDependency(dependencyKey);
                }
                seenTriggerOnly[watcherIndex] = triggerOnly;
            }

            hook.dependencyKeys.push(dependencyKey);
            plan.dependencyIndex[dependencyKey].push(input.hookId);
        }

        plan.hookIds.push(input.hookId);
        plan.stageExists[input.stageId] = true;
        return updatedCount;
    }

    function _validateHook(UVPStateMachine.CompactHook calldata hook) private pure {
        if (
            hook.hookId == bytes32(0) || hook.stageId == bytes32(0) || hook.hookName == bytes32(0)
                || hook.instructions.length == 0 || hook.dependencyKeys.length == 0
        ) {
            revert UVPStateMachine.InvalidHook();
        }

        // order-trigger（mint/dock）hook 内禁止 DELAY：outside 出生的事
        // 实与订单创建同笔交易（anchorAt=now），Delay(SIGNAL) 必得 Wait，
        // 出生路径永久 InvalidTriggerHook；dock entrance 由模块直接标记
        // Ready，DELAY 只是死代码。编译器产物的 trigger hook 恒为裸
        // SIGNAL；注册边界拒绝。
        bool orderTrigger = _isOrderTrigger(hook.flags);
        // 裸 SIGNAL 栈标志：NOT 的操作数约束（编码层契约——操作数必须是
        // 裸 SIGNAL 引用）。~(A&B)/~Delay(A) 一类组合否定的取消/锚点语义
        // 与编译器产物形态分叉，注册边界拒绝。
        bool[] memory bareSignal = new bool[](hook.instructions.length);
        // 正向锚点栈标志：延时操作数须含正向信号锚点（对齐 uvp-hook-dsl
        // validate_anchors）。全否定/缺席的操作数在 value=true 时
        // anchorAt=0，到期时刻恒在过去，Delay 沦为立即放行。
        // Signal/Delay 贡献正向锚点，Not 归零，And 取任一，Or 需
        // 每一分支都有（Or 的缺席分支可单独就绪且锚点为 0）。
        bool[] memory hasPosAnchor = new bool[](hook.instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < hook.instructions.length; i++) {
            UVPStateMachine.Instruction calldata instruction = hook.instructions[i];
            if (instruction.op == uint8(UVPStateMachine.InstructionOp.Signal)) {
                if (instruction.signalId == bytes32(0)) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                bareSignal[stackDepth] = true;
                hasPosAnchor[stackDepth] = true;
                stackDepth += 1;
            } else if (
                instruction.op == uint8(UVPStateMachine.InstructionOp.Not)
                    || instruction.op == uint8(UVPStateMachine.InstructionOp.Delay)
            ) {
                if (stackDepth == 0) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                if (instruction.op == uint8(UVPStateMachine.InstructionOp.Delay)) {
                    if (instruction.delaySeconds == 0) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    if (instruction.delaySeconds > MAX_HOOK_DELAY_SECONDS) {
                        revert UVPStateMachine.HookDelayTooLong(instruction.delaySeconds);
                    }
                    if (orderTrigger) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    if (!hasPosAnchor[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    // Delay 结果的锚点口径 = 操作数口径（成熟时刻成为新
                    // 锚点，正负性随操作数）。
                    bareSignal[stackDepth - 1] = false;
                } else {
                    // NOT 操作数必须裸 SIGNAL（uvp-hook-dsl validate_anchors
                    // 镜像的编码层契约）：~(A&B)/~Delay(A) 一类
                    // 组合否定的取消/锚点语义与编译器产物形态分叉。
                    if (!bareSignal[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    bareSignal[stackDepth - 1] = false;
                    hasPosAnchor[stackDepth - 1] = false;
                }
            } else if (
                instruction.op == uint8(UVPStateMachine.InstructionOp.And)
                    || instruction.op == uint8(UVPStateMachine.InstructionOp.Or)
            ) {
                if (instruction.arity < 2 || stackDepth < instruction.arity) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                bool anchored = instruction.op == uint8(UVPStateMachine.InstructionOp.And)
                    ? _anyPosAnchor(hasPosAnchor, stackDepth - instruction.arity, instruction.arity)
                    : _allPosAnchor(hasPosAnchor, stackDepth - instruction.arity, instruction.arity);
                stackDepth = stackDepth - instruction.arity + 1;
                bareSignal[stackDepth - 1] = false;
                hasPosAnchor[stackDepth - 1] = anchored;
            } else {
                // 词表外操作码显式拒绝：op 以 uint8 承载，旧扇入操作码
                // （数值 5）等未知值在此响亮回滚。
                revert UVPStateMachine.InvalidInstruction();
            }
        }
        if (stackDepth != 1) {
            revert UVPStateMachine.InvalidInstruction();
        }
        // 整体至少一正锚（validate_anchors 镜像）：纯否定条件（如 ~A）在
        // value=true 时 anchorAt=0——外层延时锚到过去、回放锚点无源，注册
        // 边界拒绝（编译器产物恒含正锚，这里是兜底）。
        if (!hasPosAnchor[0]) {
            revert UVPStateMachine.InvalidInstruction();
        }
    }

    function _anyPosAnchor(bool[] memory hasPosAnchor, uint256 base, uint256 arity)
        private
        pure
        returns (bool anchored)
    {
        for (uint256 i = 0; i < arity; i++) {
            if (hasPosAnchor[base + i]) {
                return true;
            }
        }
        return false;
    }

    function _allPosAnchor(bool[] memory hasPosAnchor, uint256 base, uint256 arity)
        private
        pure
        returns (bool anchored)
    {
        for (uint256 i = 0; i < arity; i++) {
            if (!hasPosAnchor[base + i]) {
                return false;
            }
        }
        return true;
    }

    function _seenDependencyIndex(bytes32[] memory seenKeys, uint256 seenCount, bytes32 dependencyKey)
        private
        pure
        returns (uint256)
    {
        for (uint256 k = 0; k < seenCount; k++) {
            if (seenKeys[k] == dependencyKey) {
                return k;
            }
        }
        return type(uint256).max;
    }

    function _isOrderTrigger(uint8 flags) private pure returns (bool) {
        return flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK) != 0;
    }

    /// 阶段物化三线统一：order-trigger 与 EMIT_READY hook 都能物化
    /// 自身阶段；纯 flags=0 watcher 不能。
    function _hookCanMaterializeStage(uint8 flags) private pure returns (bool) {
        return _isOrderTrigger(flags) || flags & HOOK_FLAG_EMIT_READY != 0;
    }

    function _planCommitDigest(UVPStateMachine.PlanCommit calldata commit) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.metadataHash,
                commit.dockRoutesRoot,
                commit.dockInterfaceRoot,
                commit.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _recoverSignalSubmitter(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert UVPStateMachine.InvalidSignalSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }

    function planRuntimeHash(bytes32 hooksHash, bytes32 metadataHash, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot)
        private
        pure
        returns (bytes32)
    {
        return
            keccak256(abi.encode(_PLAN_RUNTIME_HASH_DOMAIN, hooksHash, metadataHash, dockRoutesRoot, dockInterfaceRoot));
    }

    function planIdFor(address publisher, bytes32 runtimePlanHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_ID_HASH_DOMAIN, publisher, runtimePlanHash));
    }

    function DOMAIN_SEPARATOR() private view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }
}
