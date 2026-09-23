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
            revert UVPStateMachine.HooksHashMismatch(commit.hooksHash, actualHooksHash);
        }
        address recoveredSigner = _recoverSignalSubmitter(_planCommitDigest(commit), signature);
        if (recoveredSigner != commit.publisher) {
            revert UVPStateMachine.InvalidPlanSignature(commit.publisher, recoveredSigner);
        }

        bytes32 dockRoutesRoot = commit.dockRoutesRoot == bytes32(0) ? DockMerkle.EMPTY_ROOT : commit.dockRoutesRoot;
        bytes32 dockInterfaceRoot =
            commit.dockInterfaceRoot == bytes32(0) ? DockMerkle.EMPTY_ROOT : commit.dockInterfaceRoot;
        bytes32 capabilitiesRoot =
            commit.capabilitiesRoot == bytes32(0) ? DockMerkle.EMPTY_ROOT : commit.capabilitiesRoot;
        bytes32 runtimePlanHash =
            planRuntimeHash(commit.hooksHash, capabilitiesRoot, dockRoutesRoot, dockInterfaceRoot);
        planId = planIdFor(commit.publisher, runtimePlanHash);
        UVPStateMachine.Plan storage plan = _plans[planId];
        if (plan.committed) {
            revert UVPStateMachine.PlanAlreadyRegistered();
        }
        plan.planHash = runtimePlanHash;
        plan.hooksHash = commit.hooksHash;
        plan.capabilitiesRoot = capabilitiesRoot;
        plan.dockRoutesRoot = dockRoutesRoot;
        plan.dockInterfaceRoot = dockInterfaceRoot;
        plan.publisher = commit.publisher;
        plan.committed = true;

        // Cross-stage dependency scan scratch: scoped so the large memory
        // arrays release their stack slots before the commit events fire.
        {
            // 阶段物化防御纵深：每个被注册 hook 的阶段必须至少有
            // 一个 order-trigger 或 EMIT_READY hook——纯 flags=0 watcher 阶段
            // 在链上永远无法物化（物化只由本阶段 hook Ready 触发，executor
            // patch 不物化），其 watcher 会让共享信号键的提交交易稳定回滚。
            // 编译器是第一道防线；这里是注册边界。
            bytes32[] memory stageScratch = new bytes32[](hooks.length);
            bool[] memory stageMaterializer = new bool[](hooks.length);
            uint256 seenCount;
            for (uint256 i = 0; i < hooks.length; i++) {
                seenCount = _registerPlanHook(plan, hooks[i], seenCount);
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
            capabilitiesRoot,
            hooks.length,
            dockRoutesRoot,
            dockInterfaceRoot
        );
        emit UVPStateMachine.PlanPublisherRecorded(planId, commit.publisher);
    }

    /// finalize 与表规模解耦：能力表/绑定表已在 commit 时以 capabilitiesRoot
    /// 形态被 publisher 签名承诺，叶子成员资格由使用方逐叶携 proof 验证
    /// （悬空阶段引用、属主唯一性等表内不变量由编译器在产物层强制）。
    function finalizePlan(mapping(bytes32 => UVPStateMachine.Plan) storage _plans, address planMetadataModule, bytes32 planId)
        public
    {
        UVPStateMachine.Plan storage plan = _plans[planId];
        if (!plan.committed) {
            revert UVPStateMachine.PlanNotCommitted();
        }
        if (plan.finalized) {
            revert UVPStateMachine.PlanAlreadyFinalized();
        }

        // CEI：finalized 先于模块外调落定。模块回调（如重入 finalizePlan）
        // 必须看到已终态并按 PlanAlreadyFinalized 拒绝，而不是在 finalized
        // 落定前的窗口里二次过门。
        plan.finalized = true;
        IUVPPlanMetadataModule(planMetadataModule)
            .finalizePlanMetadata(planId, plan.capabilitiesRoot, plan.dockRoutesRoot, plan.dockInterfaceRoot);

        emit UVPStateMachine.PlanFinalized(planId, plan.planHash, plan.capabilitiesRoot);
        emit UVPStateMachine.PlanRegistered(planId, plan.planHash, plan.hookIds.length);
    }

    function _registerPlanHook(
        UVPStateMachine.Plan storage plan,
        UVPStateMachine.CompactHook calldata input,
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

            // 跨 hook 去重与跨阶段闸读已落库的 dependencyIndex（O(1) 判
            // 重），不做 memory 全表线性扫描：对每个新键做
            // _seenDependencyIndex 全表扫描，满配 1024 键 ≈ 52 万次迭代
            // （O(n²)），叠加每键双 push 的存储成本后 TooManyDependencies
            // 在 30M block gas 内恒先被 OOG 挡住。首键注册前 hook 定义
            // （stageId/flags）已写全，重复键回读已注册 hook 即可重建
            // scratch 语义：首见阶段取 dependents[0]，trigger-only 折叠取
            // 已注册 hook 集合的 AND（与逐次 AND 折叠逐点等价）。
            // Trigger watchers crossing stages are the normal selectedStages
            // flow: the evaluation guard skips triggers of unmaterialized
            // stages. The brick is a NON-trigger watcher in a stage that has
            // not materialized yet -- submitting the shared key would revert
            // that transaction forever.
            bytes32[] storage dependents = plan.dependencyIndex[dependencyKey];
            bool inputIsTrigger = _isOrderTrigger(input.flags);
            if (dependents.length == 0) {
                if (updatedCount == MAX_PLAN_DEPENDENCIES) {
                    revert UVPStateMachine.TooManyDependencies();
                }
                updatedCount += 1;
            } else {
                bool inputIsDock = input.flags & HOOK_FLAG_ORDER_TRIGGER_DOCK != 0;
                // U2 出生通道键查重——独立全量循环，绝不与 triggerOnly 折叠
                // 的早退 break 共线：折叠在首个非 trigger 依赖处 break 是刻意
                // 行为，查重若共用该循环，排在同阶段 watcher 之后的 trigger
                // 依赖会被 break 永远跳过，出生键冲突静默放行。按通道语义
                // 分界：
                // - 跨通道（mint∪dock）：outside 出生与 dock 出生是
                //   两个不同的出生上下文，共享出生键会让任一侧的
                //   出生事务把另一侧的出生线一并推 Ready、物化幻影
                //   阶段——拒绝。
                // - dock∪dock：entrance 键按 route 钉死
                //   （planHookDependsOn），一键挂两条 entrance 意味着
                //   任一 route 的子单会物化另一 route 的阶段——拒绝。
                // - mint∪mint：一事实扇出多条 mint 出生线是产品现行
                //   形态（customs 基准 plan：order::registered 同时
                //   出生执行者选择与资源发布两阶段），同一 mint 出生
                //   上下文内物化，不是幻影——放行。
                for (uint256 k = 0; k < dependents.length; k++) {
                    if (inputIsTrigger && _isOrderTrigger(plan.hooks[dependents[k]].flags)) {
                        if (inputIsDock || plan.hooks[dependents[k]].flags & HOOK_FLAG_ORDER_TRIGGER_DOCK != 0) {
                            revert UVPStateMachine.DuplicateBirthChannelKey(dependencyKey);
                        }
                    }
                }
                // 跨阶段闸的 trigger-only 折叠：dependents 全为 trigger 时
                // 跨阶段共享合法（selectedStages 流：求值守卫跳过未物化
                // 阶段的 trigger），首个非 trigger 依赖即定音——早退安全。
                bool triggerOnly = inputIsTrigger;
                for (uint256 k = 0; k < dependents.length; k++) {
                    if (!_isOrderTrigger(plan.hooks[dependents[k]].flags)) {
                        triggerOnly = false;
                        break;
                    }
                }
                if (plan.hooks[dependents[0]].stageId != input.stageId && !triggerOnly) {
                    revert UVPStateMachine.CrossStageDependency(dependencyKey);
                }
            }

            hook.dependencyKeys.push(dependencyKey);
            dependents.push(input.hookId);
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
        // 裸 SIGNAL 引用，或下方否决位形态的 DELAY 产出）。~(A&B) 一类
        // 组合否定的取消/锚点语义与编译器产物形态分叉，注册边界拒绝。
        bool[] memory bareSignal = new bool[](hook.instructions.length);
        // DELAY 产出标志：NOT 的第二类合法操作数——衰减否决位
        // ~(signal+duration) 的内层。
        bool[] memory delayResult = new bool[](hook.instructions.length);
        // 否决位标志（本槽即 `~(DELAY)` 产出，尚待合取父项消费）与
        // 子树含否决位标志（穿透 AND/OR 传递）。位置规则镜像
        // uvp-hook-dsl validate_anchors 的 veto_slot /
        // inside_delay_operand 双闸：否决位唯一合法位置是合取直接子项，
        // 且 Delay 操作数内任何深度一律禁止——否决位的 Ready 会衰减，
        // Delay 成熟是永久的，外层延时锚在已过期的否决上会静默放行。
        bool[] memory vetoTerm = new bool[](hook.instructions.length);
        bool[] memory vetoInside = new bool[](hook.instructions.length);
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
                // 零字 sourceId 事实键与其余写入口同口径拒绝
                // （triggerOrderFromOutsideFor/_authorizeSignalSubmitter 均显式
                // 拒零键）：sourceId==0 绕过 _signalStageId（恒返回 0），是
                // stage 物化与 executor 门的永久豁免键，且该键一经注册即随
                // dependencyIndex 常驻求值路径——注册边界封死。
                if (instruction.sourceId == bytes32(0)) {
                    revert UVPStateMachine.ZeroSourceId();
                }
                if (instruction.signalId == bytes32(0)) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                bareSignal[stackDepth] = true;
                hasPosAnchor[stackDepth] = true;
                delayResult[stackDepth] = false;
                vetoTerm[stackDepth] = false;
                vetoInside[stackDepth] = false;
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
                    if (vetoTerm[stackDepth - 1] || vetoInside[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    // Delay 结果的锚点口径 = 操作数口径（成熟时刻成为新
                    // 锚点，正负性随操作数）。
                    bareSignal[stackDepth - 1] = false;
                    delayResult[stackDepth - 1] = true;
                    vetoTerm[stackDepth - 1] = false;
                    vetoInside[stackDepth - 1] = false;
                } else {
                    // NOT 操作数词表：裸 SIGNAL（现状）或 DELAY 产出（衰减
                    // 否决位内层）。否决位自身的合法位置（合取直接子项）
                    // 由 vetoTerm 位交给消费方校验。
                    if (!bareSignal[stackDepth - 1] && !delayResult[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    vetoTerm[stackDepth - 1] = delayResult[stackDepth - 1];
                    vetoInside[stackDepth - 1] = vetoInside[stackDepth - 1] || vetoTerm[stackDepth - 1];
                    bareSignal[stackDepth - 1] = false;
                    delayResult[stackDepth - 1] = false;
                    hasPosAnchor[stackDepth - 1] = false;
                }
            } else if (
                instruction.op == uint8(UVPStateMachine.InstructionOp.And)
                    || instruction.op == uint8(UVPStateMachine.InstructionOp.Or)
            ) {
                if (instruction.arity < 2 || stackDepth < instruction.arity) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                if (instruction.op == uint8(UVPStateMachine.InstructionOp.Or)) {
                    // 否决位唯一合法位置是合取直接子项：Or 分支位一律拒绝
                    // （uvp-hook-dsl validate_anchors 的 veto_slot 闸镜像）。
                    for (uint256 j = stackDepth - instruction.arity; j < stackDepth; j++) {
                        if (vetoTerm[j]) {
                            revert UVPStateMachine.InvalidInstruction();
                        }
                    }
                }
                bool vetoInsideResult = false;
                for (uint256 j = stackDepth - instruction.arity; j < stackDepth; j++) {
                    vetoInsideResult = vetoInsideResult || vetoInside[j];
                }
                bool anchored = instruction.op == uint8(UVPStateMachine.InstructionOp.And)
                    ? _anyPosAnchor(hasPosAnchor, stackDepth - instruction.arity, instruction.arity)
                    : _allPosAnchor(hasPosAnchor, stackDepth - instruction.arity, instruction.arity);
                stackDepth = stackDepth - instruction.arity + 1;
                bareSignal[stackDepth - 1] = false;
                delayResult[stackDepth - 1] = false;
                vetoTerm[stackDepth - 1] = false;
                vetoInside[stackDepth - 1] = vetoInsideResult;
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
        // 根位的否决位拒绝（否决位必须由合取父项消费，validate_anchors
        // 镜像）：根否决位同时缺正锚，两条闸都以 InvalidInstruction 拒绝，
        // 显式判定让拒绝面可读而不是靠正锚闸的副作用。
        if (vetoTerm[0]) {
            revert UVPStateMachine.InvalidInstruction();
        }
        // 整体至少一正锚（validate_anchors 镜像）：纯否定条件（如 ~A）在
        // value=true 时 anchorAt=0——外层延时锚到过去、回放锚点无源，注册
        // 边界拒绝（编译器产物恒含正锚，这里是兜底）。
        if (!hasPosAnchor[0]) {
            revert UVPStateMachine.InvalidInstruction();
        }
        // dependencyKeys 与 SIGNAL 原子键集合逐点一致。未声明的
        // SIGNAL 键不进 dependencyIndex——该事实到达永不触发本 hook 求值，
        // hook 永久 Init 且零告警（幻影 watcher）；多余声明的键只是死索引。
        // 编译器产物恒一致；手签 plan 在注册边界对拍拒绝。
        uint256 signalKeyCount = 0;
        bytes32[] memory signalKeys = new bytes32[](hook.instructions.length);
        for (uint256 i = 0; i < hook.instructions.length; i++) {
            if (hook.instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            bytes32 signalKey = keccak256(abi.encode(hook.instructions[i].sourceId, hook.instructions[i].signalId));
            if (!_containsKey(signalKeys, signalKeyCount, signalKey)) {
                signalKeys[signalKeyCount] = signalKey;
                signalKeyCount += 1;
            }
        }
        uint256 declaredKeyCount = 0;
        bytes32[] memory declaredKeys = new bytes32[](hook.dependencyKeys.length);
        for (uint256 j = 0; j < hook.dependencyKeys.length; j++) {
            bytes32 dependencyKey = hook.dependencyKeys[j];
            if (_containsKey(declaredKeys, declaredKeyCount, dependencyKey)) {
                continue;
            }
            declaredKeys[declaredKeyCount] = dependencyKey;
            declaredKeyCount += 1;
            if (!_containsKey(signalKeys, signalKeyCount, dependencyKey)) {
                revert UVPStateMachine.HookDependencyKeyMismatch(hook.hookId);
            }
        }
        if (declaredKeyCount != signalKeyCount) {
            revert UVPStateMachine.HookDependencyKeyMismatch(hook.hookId);
        }
    }

    function _containsKey(bytes32[] memory keys, uint256 keyCount, bytes32 key) private pure returns (bool) {
        for (uint256 i = 0; i < keyCount; i++) {
            if (keys[i] == key) {
                return true;
            }
        }
        return false;
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
                commit.capabilitiesRoot,
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

    function planRuntimeHash(bytes32 hooksHash, bytes32 capabilitiesRoot, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot)
        private
        pure
        returns (bytes32)
    {
        return
            keccak256(abi.encode(_PLAN_RUNTIME_HASH_DOMAIN, hooksHash, capabilitiesRoot, dockRoutesRoot, dockInterfaceRoot));
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
