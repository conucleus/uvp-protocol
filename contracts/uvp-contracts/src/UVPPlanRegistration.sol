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
    _HOOK_FLAG_ADMISSION as HOOK_FLAG_ADMISSION,
    _MAX_HOOK_DELAY_SECONDS as MAX_HOOK_DELAY_SECONDS,
    _MAX_PLAN_DEPENDENCIES as MAX_PLAN_DEPENDENCIES,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN,
    _PLAN_COMMIT_TYPEHASH,
    _EXECUTOR_CANDIDATE_LEAF_DOMAIN
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
        UVPStateMachine.ExecutorCandidate[] calldata executorCandidates,
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
        // 执行者候选集（UB-36②③）：叶 = keccak256(abi.encodePacked(
        // _EXECUTOR_CANDIDATE_LEAF_DOMAIN, stageId, executor))，DockMerkle
        // 同款排序去重建树；零条目（或 commit 侧零字）= EMPTY_ROOT，该形态
        // 下逐单 executor patch 恒拒（不开候选集的计划没有逐单换人面）。
        bytes32 executorCandidatesRoot = _executorCandidatesRoot(executorCandidates);
        bytes32 runtimePlanHash = planRuntimeHash(
            commit.hooksHash, capabilitiesRoot, dockRoutesRoot, dockInterfaceRoot, executorCandidatesRoot
        );
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
        plan.executorCandidatesRoot = executorCandidatesRoot;
        plan.publisher = commit.publisher;
        plan.birthAuthorizer = commit.birthAuthorizer;
        plan.committed = true;
        // 候选集阶段投影（B8a）：assign 前置闸的免证判定材料随建树数组
        // 落库——数组与 root 同源（planId 即由数组派生 root 键出），此处
        // 落库的是同一承诺的阶段面，不引入第二个可信来源。
        for (uint256 i = 0; i < executorCandidates.length; i++) {
            plan.executorCandidateStages[executorCandidates[i].stageId] = true;
        }

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
            dockInterfaceRoot,
            executorCandidatesRoot
        );
        emit UVPStateMachine.PlanPublisherRecorded(planId, commit.publisher);
    }

    /// 执行者候选集建树（UB-36②③）：叶公式与 DockMerkle 排序去重口径
    /// 与链下建树方（编译器/发布器）逐字节一致；重复条目去重后不改变根。
    function _executorCandidatesRoot(UVPStateMachine.ExecutorCandidate[] calldata executorCandidates)
        private
        pure
        returns (bytes32)
    {
        bytes32[] memory leaves = new bytes32[](executorCandidates.length);
        for (uint256 i = 0; i < executorCandidates.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    _EXECUTOR_CANDIDATE_LEAF_DOMAIN, executorCandidates[i].stageId, executorCandidates[i].executor
                )
            );
        }
        return DockMerkle.root(leaves);
    }

    /// finalize 与表规模解耦：能力表/绑定表已在 commit 时以 capabilitiesRoot
    /// 形态被 publisher 签名承诺，叶子成员资格由使用方逐叶携 proof 验证
    /// （悬空阶段引用、属主唯一性等表内不变量由编译器在产物层强制）。
    function finalizePlan(
        mapping(bytes32 => UVPStateMachine.Plan) storage _plans,
        address planMetadataModule,
        bytes32 planId
    ) public {
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
        // 适格面槽位（flag=8）：进 plan.admissions（按被发射事实的
        // signalKey = hookId 槽寻址），不进 plan.hooks/dependencyIndex/
        // hookIds——适格在提交一拍求值，不为事实到达所重评。与 hook 槽
        // 共享 hooksHash 承诺与提交顺序（commitPlan 的阶段物化扫描对
        // 两类槽位一视同仁：仅适格、无物化 hook 的阶段在此暴露）。
        if (input.flags & HOOK_FLAG_ADMISSION != 0) {
            _registerPlanAdmission(plan, input);
            return seenCount;
        }
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

    /// 适格面注册：hookId 槽 = 被发射事实的 signalKey（提交路径只持有
    /// (sourceId, signalId)，signalKey 是它可计算的唯一寻址键；全名在
    /// plan 内唯一属主保证键不碰撞）。首条适格置 plan.admissionsDeclared
    /// （与 committed/finalized 同槽），_createOrder 复制进订单供提交
    /// 卡点短路。chimera flags 拒绝：适格与出生/就绪位共用一个 word 会
    /// 让同一槽位同时寻址两个人口。
    function _registerPlanAdmission(UVPStateMachine.Plan storage plan, UVPStateMachine.CompactHook calldata input)
        private
    {
        if (input.flags != HOOK_FLAG_ADMISSION) {
            revert UVPStateMachine.InvalidHook();
        }
        _validateAdmission(input);
        UVPStateMachine.StoredAdmission storage admission = plan.admissions[input.hookId];
        if (admission.exists) {
            revert UVPStateMachine.AdmissionAlreadyRegistered(input.hookId);
        }
        admission.exists = true;
        for (uint256 j = 0; j < input.instructions.length; j++) {
            admission.instructions.push(input.instructions[j]);
        }
        plan.admissionsDeclared = true;
    }

    /// `_validateHook` 的过滤档兄弟（发射适格面）：适格只在到达一拍对
    /// pre-state 求值、不参与任何调度——无根位/OR 分支正锚要求（衰减否决
    /// 位 ~(A+duration) 位置全放开——任何位置的瞬时值都良定义，裸衰减根
    /// 合法，NOT 的合法位不动）。与钩子档同源的保留闸：NOT 操作数词表
    ///（裸 SIGNAL 或 DELAY 产出，组合否定拒绝）、DELAY 时长 ∈ (0, 30d]、
    /// DELAY 操作数必须有正向锚点（UB-1：无锚延时在求值侧永不放行——
    /// Rust 权威 eval_expr 的 Delay 臂对无锚 Ready 操作数返回 NeedsMore，
    /// 注册即拒而不是留死代码）、嵌套延时闸（uvp-hook-dsl
    /// validate_filter_hook 同样先过 reject_nested_delay）、AND/OR
    /// arity ≥ 2、栈深充足、结束恰一值、dependencyKeys 与 SIGNAL 原子键
    /// 逐点一致。自引用/出生锚/订阅原子是编译期拒绝（uvp-compiler
    /// D028-D030），注册门看到的只有指令形态。
    function _validateAdmission(UVPStateMachine.CompactHook calldata admission) private pure {
        if (
            admission.hookId == bytes32(0) || admission.stageId == bytes32(0) || admission.hookName == bytes32(0)
                || admission.instructions.length == 0 || admission.dependencyKeys.length == 0
        ) {
            revert UVPStateMachine.InvalidHook();
        }

        // 裸 SIGNAL 栈标志：NOT 操作数约束（裸 SIGNAL 或下方 DELAY 产出）。
        bool[] memory bareSignal = new bool[](admission.instructions.length);
        // DELAY 产出标志：NOT 的第二类合法操作数（否决位内层）。
        bool[] memory delayResult = new bool[](admission.instructions.length);
        // 子树含 DELAY 标志（UB-1 嵌套延时闸，reject_nested_delay 镜像）。
        bool[] memory delayInside = new bool[](admission.instructions.length);
        // 正向锚点标志：DELAY 操作数闸的判定材料（Signal 贡献，Not 归零，
        // Delay 承袭操作数，And/Or 取任一——过滤档无 OR 分支硬闸）。
        bool[] memory hasPosAnchor = new bool[](admission.instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < admission.instructions.length; i++) {
            UVPStateMachine.Instruction calldata instruction = admission.instructions[i];
            if (instruction.op == uint8(UVPStateMachine.InstructionOp.Signal)) {
                // 零字事实键与其余写入口同口径拒绝（_validateHook 镜像）：
                // 零 sourceId 是 stage 物化与 executor 门的永久豁免键。
                if (instruction.sourceId == bytes32(0)) {
                    revert UVPStateMachine.ZeroSourceId();
                }
                if (instruction.signalId == bytes32(0)) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                bareSignal[stackDepth] = true;
                hasPosAnchor[stackDepth] = true;
                delayResult[stackDepth] = false;
                delayInside[stackDepth] = false;
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
                    // UB-1 无锚延时注册即拒：过滤档允许纯否定操作数存在
                    //（瞬时值良定义），但禁止它直接喂延时——无锚延时在求值
                    // 侧是恒未决死代码（Rust 权威同口径）。
                    if (!hasPosAnchor[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    if (delayInside[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    bareSignal[stackDepth - 1] = false;
                    delayResult[stackDepth - 1] = true;
                    delayInside[stackDepth - 1] = true;
                } else {
                    if (!bareSignal[stackDepth - 1] && !delayResult[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    bareSignal[stackDepth - 1] = false;
                    delayResult[stackDepth - 1] = false;
                    hasPosAnchor[stackDepth - 1] = false;
                    // delayInside 经 NOT 透传（否决位内层仍是延时操作数）。
                }
            } else if (
                instruction.op == uint8(UVPStateMachine.InstructionOp.And)
                    || instruction.op == uint8(UVPStateMachine.InstructionOp.Or)
            ) {
                if (instruction.arity < 2 || stackDepth < instruction.arity) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                bool delayInsideResult = false;
                for (uint256 j = stackDepth - instruction.arity; j < stackDepth; j++) {
                    delayInsideResult = delayInsideResult || delayInside[j];
                }
                stackDepth = stackDepth - instruction.arity + 1;
                bareSignal[stackDepth - 1] = false;
                delayResult[stackDepth - 1] = false;
                delayInside[stackDepth - 1] = delayInsideResult;
                hasPosAnchor[stackDepth - 1] = _anyPosAnchor(hasPosAnchor, stackDepth - 1, instruction.arity);
            } else {
                revert UVPStateMachine.InvalidInstruction();
            }
        }
        if (stackDepth != 1) {
            revert UVPStateMachine.InvalidInstruction();
        }
        // dependencyKeys 与 SIGNAL 原子键集合逐点一致（_validateHook 同
        // 口径）：错位键让制品与链上注册面分叉，注册边界对拍拒绝。
        uint256 signalKeyCount = 0;
        bytes32[] memory signalKeys = new bytes32[](admission.instructions.length);
        for (uint256 i = 0; i < admission.instructions.length; i++) {
            if (admission.instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            bytes32 signalKey =
                keccak256(abi.encode(admission.instructions[i].sourceId, admission.instructions[i].signalId));
            if (!_containsKey(signalKeys, signalKeyCount, signalKey)) {
                signalKeys[signalKeyCount] = signalKey;
                signalKeyCount += 1;
            }
        }
        uint256 declaredKeyCount = 0;
        bytes32[] memory declaredKeys = new bytes32[](admission.dependencyKeys.length);
        for (uint256 j = 0; j < admission.dependencyKeys.length; j++) {
            bytes32 dependencyKey = admission.dependencyKeys[j];
            if (_containsKey(declaredKeys, declaredKeyCount, dependencyKey)) {
                continue;
            }
            declaredKeys[declaredKeyCount] = dependencyKey;
            declaredKeyCount += 1;
            if (!_containsKey(signalKeys, signalKeyCount, dependencyKey)) {
                revert UVPStateMachine.HookDependencyKeyMismatch(admission.hookId);
            }
        }
        if (declaredKeyCount != signalKeyCount) {
            revert UVPStateMachine.HookDependencyKeyMismatch(admission.hookId);
        }
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
        // 子树含 DELAY 标志（UB-1 嵌套延时闸）：Delay 的操作数子树内含
        // 任何 DELAY 一律拒绝——镜像 uvp-hook-dsl ast/mod.rs 的
        // reject_nested_delay（inside_delay 位经 Not/And/Or 全深度传递，
        // 正位与否决位同闸：`~(A+5s)` 合法，`(~(A+5s))+3s`、
        // `(A & (B+5s))+3s`、`~((A+5s)+3s)` 全拒）。嵌套延时链的求值语义
        // （内层 Wait 命中外层 Delay 操作数）在 Rust 权威侧是显式
        // unreachable 错误，链上注册边界先拒。
        bool[] memory delayInside = new bool[](hook.instructions.length);
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
                delayInside[stackDepth] = false;
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
                    // 嵌套延时闸（UB-1）：操作数子树内已含 DELAY 即拒绝
                    //（reject_nested_delay 镜像）。
                    if (delayInside[stackDepth - 1]) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    // Delay 结果的锚点口径 = 操作数口径（成熟时刻成为新
                    // 锚点，正负性随操作数）；delayInside 置位——本子树从
                    // 此处于某延时的操作数内。
                    bareSignal[stackDepth - 1] = false;
                    delayResult[stackDepth - 1] = true;
                    vetoTerm[stackDepth - 1] = false;
                    vetoInside[stackDepth - 1] = false;
                    delayInside[stackDepth - 1] = true;
                } else {
                    // NOT 操作数词表：裸 SIGNAL（现状）或 DELAY 产出（衰减
                    // 否决位内层）。否决位自身的合法位置（合取直接子项）
                    // 由 vetoTerm 位交给消费方校验；delayInside 随 NOT 透传
                    //（~(A+5s) 的否决位深处仍是延时操作数的一部分）。
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
                bool orGate = instruction.op == uint8(UVPStateMachine.InstructionOp.Or);
                if (orGate) {
                    // 否决位唯一合法位置是合取直接子项：Or 分支位一律拒绝
                    //（uvp-hook-dsl validate_anchors 的 veto_slot 闸镜像）。
                    for (uint256 j = stackDepth - instruction.arity; j < stackDepth; j++) {
                        if (vetoTerm[j]) {
                            revert UVPStateMachine.InvalidInstruction();
                        }
                    }
                }
                bool vetoInsideResult = false;
                bool delayInsideResult = false;
                for (uint256 j = stackDepth - instruction.arity; j < stackDepth; j++) {
                    vetoInsideResult = vetoInsideResult || vetoInside[j];
                    delayInsideResult = delayInsideResult || delayInside[j];
                }
                bool anchored;
                if (orGate) {
                    // OR 分支正锚硬闸（UB-1）：每一分支都必须含正向锚点，
                    // 不满足直接 revert——不再作为软标志允许外层 AND 抢救
                    //（镜像 uvp-hook-dsl validate_anchors 的 Or 臂
                    // "each OR branch must contain a positive signal anchor"）。
                    // 无锚分支可单独就绪且 anchorAt=0，赢得 OR 出线后让
                    // 外层延时锚到过去（求值侧 _orValue/_delayValue 的无锚
                    // 防御是纵深，注册边界先拒）。
                    anchored = _allPosAnchor(hasPosAnchor, stackDepth - instruction.arity, instruction.arity);
                    if (!anchored) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                } else {
                    anchored = _anyPosAnchor(hasPosAnchor, stackDepth - instruction.arity, instruction.arity);
                }
                stackDepth = stackDepth - instruction.arity + 1;
                bareSignal[stackDepth - 1] = false;
                delayResult[stackDepth - 1] = false;
                vetoTerm[stackDepth - 1] = false;
                vetoInside[stackDepth - 1] = vetoInsideResult;
                delayInside[stackDepth - 1] = delayInsideResult;
                hasPosAnchor[stackDepth - 1] = anchored;
            } else {
                // 词表外操作码显式拒绝：op 以 uint8 承载，旧扇入操作码
                //（数值 5）等未知值在此响亮回滚。
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
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
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

    function planRuntimeHash(
        bytes32 hooksHash,
        bytes32 capabilitiesRoot,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot,
        bytes32 executorCandidatesRoot
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _PLAN_RUNTIME_HASH_DOMAIN,
                hooksHash,
                capabilitiesRoot,
                dockRoutesRoot,
                dockInterfaceRoot,
                executorCandidatesRoot
            )
        );
    }

    function planIdFor(address publisher, bytes32 runtimePlanHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_PLAN_ID_HASH_DOMAIN, publisher, runtimePlanHash));
    }

    function DOMAIN_SEPARATOR() private view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    // ==================================================================
    // 订单出生/镜像运行时（EIP-170 瘦身外置，UB-36①④/UB-2/UB-39 批随迁）
    // ==================================================================
    // 主合约对以下入口保留公共 ABI 签名与模块鉴权（msg.sender 检查），执行体
    // 经 DELEGATECALL 进入本库——状态写入主合约存储、事件 emitter 与
    // EIP-712 域（address(this)）保持不变，与 commitPlan/finalizePlan 的
    // 外置模式同构：
    //   - triggerOrderFromOutsideFor（outside 出生）
    //   - triggerOrderFromSignalFromModule（trigger-origin 出生 + 同意链）
    //   - hasTriggerOriginConsent（视图）
    //   - forkOrder（UB-39 新增出生通道，门/建单段 + 重放段）
    //   - createDockedOrderFromModule / recordDockedInputFromModule
    //
    // 存储访问经 UVPStateMachine.OrderRuntimeCtx（storage 指针成员的
    // memory 结构体）单参数传递：storage 指针是运行期值、占真实栈位（与
    // 主合约内隐式槽常量的免费再生物化不同），逐参数传递会让求值链撞
    // via_ir 深栈上限——_s 收拢后库内链路与主合约同源副本的栈形一致。
    // 求值引擎（指令求值/事实落库/hook 物化）在本库与主合约各持一份
    // 逐字节同源的副本（主合约的 submitSignal 热路径仍需就地求值，无法
    // 整体外移）；两份副本的语义对拍由既有 forge 测试与冻结 fixture 的
    // bytecode 哈希钉住。库私有副本以 L_ 前缀命名，防止审查时与主合约
    // 同名函数混淆。

    bytes32 private constant _L_ORDER_LINK_ORDER_ID_DOMAIN = keccak256("uvp.order_link.order_id.v1");
    bytes32 private constant _L_FORK_ORDER_ID_DOMAIN = keccak256("uvp.fork.order_id.v1");
    bytes32 private constant _L_TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    /// outside 出生入口执行体（主合约 triggerOrderFromOutsideFor 的外置体；
    /// relayer = DELEGATECALL 下的 msg.sender）。
    function triggerOrderFromOutside(
        UVPStateMachine.SMState storage _s,
        UVPStateMachine.TriggerOrderFromOutsideRequest calldata trigger,
        UVPStateMachine.SignalAuthorization[] calldata authorizations,
        bytes calldata signature,
        UVPStateMachine.FactAttribution calldata birthFactAttribution
    ) external {
        if (block.timestamp > trigger.deadline) {
            revert UVPStateMachine.ExpiredSignalSignature(trigger.deadline);
        }
        if (trigger.submitter == address(0)) {
            revert UVPStateMachine.ZeroSubmitter();
        }
        // 出生事实零字与其余写入口同口径拒绝：零 capability 的手工 plan 不
        // 做词表闸，而零字事实键在词表内恒无成员资格——零字事实是 stage
        // 物化与 executor 门的永久豁免键，且会以 lastSignalSubmitter 污染
        // HANDOFF 回退链。
        if (trigger.sourceId == bytes32(0)) {
            revert UVPStateMachine.ZeroSourceId();
        }
        if (trigger.signalId == bytes32(0)) {
            revert UVPStateMachine.ZeroSignalId();
        }
        // 出生事实属主解析统一走 L_resolveSourceStage：声明属主必须验过能力
        // 叶，有词表的 plan 不携有效 attribution 即响亮回滚（词表闸
        // fail-closed，UB-2 计数不可被"省证"绕过）；零词表手工 plan 按
        // source==stage 回退。解析结果随 L_recordSignal 进 per-stage 计数。
        bytes32 birthStageId =
            L_resolveSourceStage(_s, trigger.planId, trigger.sourceId, trigger.signalId, birthFactAttribution);

        {
            bytes32 authorizationsHash = L_signalAuthorizationsHash(authorizations);
            address recoveredSigner =
                L_recoverSignalSubmitter(L_triggerOrderFromOutsideDigest(trigger, authorizationsHash), signature);
            if (recoveredSigner != trigger.submitter) {
                revert UVPStateMachine.InvalidTriggerOrderSignature(trigger.submitter, recoveredSigner);
            }
        }
        // 出生授权闸（10.4 复裁选 A）：outside 出生只认计划承诺的
        // birthAuthorizer——持受害者签名请求的中继方自签竞争请求（换
        // creator/authorizations 抢占订单号与下游授权面）在此被精确拒绝；
        // 零地址 = 该计划关闭 outside 出生通道。fork/派生通道自有同意门，
        // 不在本闸射程。未知 plan 先回 L_createOrder 家族的 PlanNotFinalized。
        UVPStateMachine.Plan storage plan = _s.plans[trigger.planId];
        if (!plan.committed) {
            revert UVPStateMachine.PlanNotFinalized();
        }
        if (plan.birthAuthorizer != trigger.submitter) {
            revert UVPStateMachine.UnauthorizedBirthSubmitter(trigger.submitter);
        }

        // 一事一单执行体：订单 id 由合约从事实纯函数派生（与主合约
        // triggerOrderIdFor 同公式：keccak256(abi.encode(...)) 恒清 dock
        // 命名空间位），重放同一事实恒定派生同一 id，按
        // OrderAlreadyRegistered 幂等拒绝。
        bytes32 orderId = bytes32(
            uint256(keccak256(abi.encode(trigger.planId, trigger.sourceId, trigger.signalId, trigger.payloadHash)))
                & ~(uint256(1) << 255)
        );
        // The high-bit namespace is reserved for deterministic dock child
        // orders. A derived id colliding with it is a hash-collision-level
        // event; fail closed rather than let a dock child be front-run.
        if (uint256(orderId) & (uint256(1) << 255) != 0) {
            revert UVPStateMachine.InvalidDockOrderNamespace(orderId);
        }

        L_createOrder(_s, trigger.planId, orderId, trigger.creator, msg.sender);
        L_authorizeSignalSubmitters(_s, trigger.planId, orderId, authorizations);
        emit UVPStateMachine.OrderTriggered(
            orderId,
            trigger.planId,
            trigger.triggerStageId,
            trigger.triggerHookId,
            trigger.sourceId,
            trigger.signalId,
            trigger.submitter
        );
        // 无单外部出生同样过适格筛：出生订单的 pre-state 是空集，正锚
        // 表达式的裁决自然是拒绝——这是封死「gated 信号绕窗铸单」的
        // 口子（内部出生/dock 写入不经适格面）。
        L_requireSignalAdmission(_s, trigger.planId, orderId, trigger.sourceId, trigger.signalId);
        L_recordSignal(
            _s,
            trigger.planId,
            orderId,
            trigger.sourceId,
            trigger.signalId,
            trigger.payloadHash,
            trigger.idempotencyKey,
            trigger.submitter,
            // 出生事务内的出生事实写入：这是 outside 出生路径对 order-trigger
            // hook 求值的唯一合法时点（就绪结果随后被出生闸断言）。
            true,
            birthStageId
        );
        L_requireTriggerHookReady(_s, trigger.planId, orderId, trigger.triggerHookId, trigger.triggerStageId);
    }

    /// trigger-origin 出生入口执行体（主合约 triggerOrderFromSignalFromModule
    /// 的外置体；模块鉴权在主合约 wrapper 内完成）。
    function triggerOrderFromSignal(
        UVPStateMachine.SMState storage _s,
        UVPStateMachine.TriggerOrderFromSignalRequest calldata trigger,
        UVPStateMachine.SignalAuthorization[] calldata authorizations,
        address relayer,
        UVPStateMachine.FactAttribution[] calldata originFactAttributions
    ) external {
        if (trigger.submitter == address(0)) {
            revert UVPStateMachine.ZeroSubmitter();
        }

        // trigger-origin 订单按 (originPlanId, triggerOriginOrderId)
        // 复合键寻址，跨 plan 链接必须显式声明 origin 的 plan。
        UVPStateMachine.Order storage triggerOriginOrder = _s.orders[trigger.originPlanId][trigger.triggerOriginOrderId];
        if (!triggerOriginOrder.exists) {
            revert UVPStateMachine.UnknownOrder();
        }
        if (!L_hasSignal(
                _s, trigger.originPlanId, trigger.triggerOriginOrderId, trigger.originSourceId, trigger.originSignalId
            )) {
            revert UVPStateMachine.UnknownOrder();
        }
        // origin 事实的属主阶段由调用方携 proof 自证（能力树 membership）；
        // 有词表的 origin plan 不携证即回滚（InvalidSignalCapability，与
        // 提交/出生路径同口径），零词表 plan 才保留 source==stage 回退。
        bytes32 declaredOriginStage = L_resolveSourceStageFrom(
            _s, trigger.originPlanId, trigger.originSourceId, trigger.originSignalId, originFactAttributions
        );
        // trigger link 建立需要 origin 侧同意。执行 relayer 或
        // EIP712 请求 submitter 必须在 origin 订单的同意集合内（创建者 /
        // origin 源阶段执行者 / origin 事实的授权提交者）。语义：能对 origin
        // 订单说出该事实的一方，才允许把它作为 trigger-origin 消费、在其上
        // 派生新订单。外部 plan 镜像公开 capability 声明不足以建立链接——
        // 这封死 capability 镜像攻击链（镜像 plan → 镜像 link → 回写注入）。
        if (
            !L_triggerOriginConsent(
                    _s,
                    trigger.originPlanId,
                    trigger.triggerOriginOrderId,
                    trigger.originSourceId,
                    trigger.originSignalId,
                    trigger.submitter,
                    declaredOriginStage
                )
                && !L_triggerOriginConsent(
                    _s,
                    trigger.originPlanId,
                    trigger.triggerOriginOrderId,
                    trigger.originSourceId,
                    trigger.originSignalId,
                    relayer,
                    declaredOriginStage
                )
        ) {
            revert UVPStateMachine.UnauthorizedTriggerOrigin(
                trigger.originPlanId, trigger.triggerOriginOrderId, trigger.submitter
            );
        }
        // orderId 不可自报（0300 H-1）：合约按 link 事实派生，请求携带的
        // orderId 只作镜像校验——与 routeId/dockInstanceId 的"重算即拒绝"
        // 口径一致（攻击推演见 docs/design-notes.md §1）。
        {
            bytes32 derivedOrderId = L_orderLinkOrderIdFor(
                trigger.planId,
                trigger.originPlanId,
                trigger.triggerOriginOrderId,
                trigger.originSourceId,
                trigger.originSignalId,
                trigger.payloadHash
            );
            if (trigger.orderId != derivedOrderId) {
                revert UVPStateMachine.InvalidOrderLinkOrderId(trigger.orderId, derivedOrderId);
            }
        }
        L_requireTriggerHookReadyForOrder(
            _s,
            trigger.originPlanId,
            trigger.triggerOriginOrderId,
            trigger.planId,
            trigger.triggerHookId,
            trigger.triggerStageId
        );
        // 每个被消费的 SIGNAL 指令独立过 origin 同意门（UVP-08）：声明
        // 的 origin 事实已同意，但 hook 求值实际读取的其它事实同样构成
        // "把 origin 订单的事实拿去派生新单"，逐一校验。跳过未发生的
        // 事实不是因为它们不影响求值——恰恰相反，经 NOT 它们可以让表
        // 达式就绪（A & ~X 正是在 X 未发生时为真）——而是因为同意门只
        // 约束"已被说出"的事实：未发生的事实不是 origin 订单上任何一方
        // 的发言，不存在可被要求同意的主体（"X 未发生"是全链可见的缺
        // 席状态，不是 origin 订单的私有信息）。
        L_requireTriggerHookSignalConsent(
            _s,
            trigger.originPlanId,
            trigger.triggerOriginOrderId,
            trigger.planId,
            trigger.triggerHookId,
            trigger.triggerStageId,
            trigger.submitter,
            relayer,
            originFactAttributions
        );

        if (uint256(trigger.orderId) & (uint256(1) << 255) != 0) {
            revert UVPStateMachine.InvalidDockOrderNamespace(trigger.orderId);
        }

        L_createOrder(_s, trigger.planId, trigger.orderId, trigger.creator, relayer);
        L_authorizeSignalSubmitters(_s, trigger.planId, trigger.orderId, authorizations);
        emit UVPStateMachine.OrderTriggered(
            trigger.orderId,
            trigger.planId,
            trigger.triggerStageId,
            trigger.triggerHookId,
            trigger.originSourceId,
            trigger.originSignalId,
            trigger.submitter
        );
        L_markTriggerHookReady(
            _s,
            trigger.planId,
            trigger.orderId,
            trigger.triggerHookId,
            trigger.triggerStageId,
            trigger.originSourceId,
            trigger.originSignalId
        );
    }

    /// fork 出生通道·门与建单段（UB-39）：授权门（裁决信号存在 + initiator
    /// ∈ {父单 creator, 裁决信号提交者}）、forkedOrderId 派生、建单、血缘
    /// 落库、授权写入与 OrderForked 事件。与重放段（forkOrderReplay）由
    /// 主合约 wrapper 顺序调用——拆段压 via_ir 深栈，状态全部落主合约
    /// 存储，同一事务内拆段无原子性风险。
    function forkOrderGate(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 parentOrderId,
        bytes32 forkPayloadHash,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        UVPStateMachine.SignalAuthorization[] calldata authorizations
    ) external returns (bytes32 forkedOrderId) {
        // DELEGATECALL 保持 msg.sender：initiator 即主合约入口的直接调用方。
        address initiator = msg.sender;
        UVPStateMachine.Order storage parentOrder = _s.orders[planId][parentOrderId];
        if (!parentOrder.exists) {
            revert UVPStateMachine.UnknownOrder();
        }
        // 裁决信号必须存在于父单（零字键在父单恒无信号，同拒）。
        if (!L_hasSignal(_s, planId, parentOrderId, approvalSourceId, approvalSignalId)) {
            revert UVPStateMachine.ForkApprovalSignalUnknown(planId, parentOrderId, approvalSourceId, approvalSignalId);
        }
        // 授权门：父单 creator 或裁决信号提交者。
        {
            address approvalSubmitter =
                _s.signals[planId][parentOrderId][L_signalKey(approvalSourceId, approvalSignalId)].submitter;
            if (initiator != parentOrder.creator && initiator != approvalSubmitter) {
                revert UVPStateMachine.UnauthorizedOrderFork(planId, parentOrderId, initiator);
            }
        }

        forkedOrderId = L_forkOrderIdFor(planId, parentOrderId, forkPayloadHash);
        if (uint256(forkedOrderId) & (uint256(1) << 255) != 0) {
            revert UVPStateMachine.InvalidDockOrderNamespace(forkedOrderId);
        }
        // creator 承袭父单（血缘连续：fork 是同一业务订单的治理分叉，不是
        // 新下单方）；relayer 记 initiator（其身份由 OrderForked 事件单独
        // 携带，creator 面不因 relayer 混入）。
        L_createOrder(_s, planId, forkedOrderId, parentOrder.creator, initiator);
        _s.orders[planId][forkedOrderId].parentOrderId = parentOrderId;
        L_authorizeSignalSubmitters(_s, planId, forkedOrderId, authorizations);
        emit UVPStateMachine.OrderForked(
            planId, forkedOrderId, parentOrderId, approvalSourceId, approvalSignalId, initiator
        );
    }

    /// fork 出生通道·重放段（UB-39）：birthFacts 逐字段对父单历史核验
    ///（fail-closed）后写入（SignalSubmitted 事件口径，order-trigger hook
    /// 在重放事务内求值），全部事实落库后对非 order-trigger hook 统一补扫
    /// 一遍（skip 语义与 L_evaluateAffectedHooks 一致：未物化阶段的纯
    /// flags=0 watcher 跳过，EMIT_READY 求值并物化）。
    /// 每条事实的 per-stage 归属按 source==stage 回退解析（sourceId 是
    /// 本 plan 已注册 stage id 时归属该 stage；词表携证解析需要 proof，
    /// 而 fork 签名面按裁决不含 per-fact attribution——fork 事实已在父单
    /// 提交时过全部词表闸，重放侧不重复收证，词表属主事实（sourceId !=
    /// stageId）不进 fork 单的 per-stage 计数；hook 状态不受影响，
    /// ASSIGN 时序闸在 fork 单上只覆盖 stage 命名事实）。
    function forkOrderReplay(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 parentOrderId,
        bytes32 forkedOrderId,
        UVPStateMachine.ForkBirthFact[] calldata birthFacts
    ) external {
        if (birthFacts.length > 256) {
            revert UVPStateMachine.TooManyForkBirthFacts(birthFacts.length);
        }
        mapping(bytes32 => UVPStateMachine.SignalRecord) storage parentFacts = _s.signals[planId][parentOrderId];
        for (uint256 i = 0; i < birthFacts.length; i++) {
            UVPStateMachine.ForkBirthFact calldata fact = birthFacts[i];
            UVPStateMachine.SignalRecord storage parentSignal = parentFacts[L_signalKey(fact.sourceId, fact.signalId)];
            if (
                !parentSignal.exists || parentSignal.payloadHash != fact.payloadHash
                    || parentSignal.idempotencyKey != fact.idempotencyKey
            ) {
                revert UVPStateMachine.InvalidForkBirthFact(parentOrderId, fact.sourceId, fact.signalId);
            }
            bytes32 factStageId = L_isPlanStage(_s, planId, fact.sourceId) ? fact.sourceId : bytes32(0);
            L_recordSignal(
                _s,
                planId,
                forkedOrderId,
                fact.sourceId,
                fact.signalId,
                fact.payloadHash,
                fact.idempotencyKey,
                // 提交者承袭父单事实的原始提交者：业务归因（谁说出的该事实）
                // 不因重放换头。
                parentSignal.submitter,
                // 出生事务内的重放写入：order-trigger hook 允许求值（fork 的
                // 出生线语义与 outside/dock 出生同构）。
                true,
                factStageId
            );
        }

        UVPStateMachine.Plan storage plan = _s.plans[planId];
        UVPStateMachine.Order storage forkedOrder = _s.orders[planId][forkedOrderId];
        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            UVPStateMachine.StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (L_isOrderTrigger(hook.flags)) {
                continue;
            }
            if (hook.flags & HOOK_FLAG_EMIT_READY == 0 && !forkedOrder.materializedStages[hook.stageId]) {
                continue;
            }
            L_evaluateHook(_s, planId, forkedOrderId, plan.hookIds[i], bytes32(0), bytes32(0));
        }
    }

    // ---------------- L_ 私有副本（与主合约同源，见文件头说明） ----------------

    function L_signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function L_hasSignal(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId
    ) private view returns (bool) {
        return _s.signals[planId][orderId][L_signalKey(sourceId, signalId)].exists;
    }

    function L_isOrderTrigger(uint8 flags) private pure returns (bool) {
        return flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK) != 0;
    }

    function L_isPlanStage(UVPStateMachine.SMState storage _s, bytes32 planId, bytes32 stageId)
        private
        view
        returns (bool)
    {
        if (stageId == bytes32(0)) {
            return false;
        }
        return _s.plans[planId].stageExists[stageId];
    }

    function L_hasCapabilityVocabulary(UVPStateMachine.SMState storage _s, bytes32 planId) private view returns (bool) {
        if (_s.planMetadataModule == address(0)) {
            return false;
        }
        return IUVPPlanMetadataModule(_s.planMetadataModule).hasCapabilityVocabulary(planId);
    }

    /// 属主自证验证（主合约 _verifiedFactOwner 同源副本）。
    function L_verifiedFactOwner(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId,
        UVPStateMachine.FactAttribution calldata attribution
    ) private view returns (bytes32 stageId) {
        if (attribution.stageId == bytes32(0)) {
            return bytes32(0);
        }
        if (attribution.sourceId != sourceId || attribution.signalId != signalId) {
            revert UVPStateMachine.InvalidFactAttribution(planId, sourceId, signalId, attribution.stageId);
        }
        if (!IUVPPlanMetadataModule(_s.planMetadataModule)
                .verifySignalCapability(
                    planId, attribution.stageId, sourceId, signalId, 0, attribution.capabilityProof
                )) {
            revert UVPStateMachine.InvalidFactAttribution(planId, sourceId, signalId, attribution.stageId);
        }
        return attribution.stageId;
    }

    /// 属主阶段解析（主合约 _resolveSourceStage 同源副本）。
    function L_resolveSourceStage(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId,
        UVPStateMachine.FactAttribution calldata attribution
    ) private view returns (bytes32 stageId) {
        stageId = L_verifiedFactOwner(_s, planId, sourceId, signalId, attribution);
        if (stageId != bytes32(0)) {
            return stageId;
        }
        if (L_hasCapabilityVocabulary(_s, planId)) {
            revert UVPStateMachine.InvalidSignalCapability(planId, sourceId, signalId);
        }
        if (L_isPlanStage(_s, planId, sourceId)) {
            stageId = sourceId;
        }
    }

    function L_resolveSourceStageFrom(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId,
        UVPStateMachine.FactAttribution[] calldata attributions
    ) private view returns (bytes32 stageId) {
        for (uint256 i = 0; i < attributions.length; i++) {
            if (
                attributions[i].stageId != bytes32(0) && attributions[i].sourceId == sourceId
                    && attributions[i].signalId == signalId
            ) {
                return L_verifiedFactOwner(_s, planId, sourceId, signalId, attributions[i]);
            }
        }
        if (L_hasCapabilityVocabulary(_s, planId)) {
            revert UVPStateMachine.InvalidSignalCapability(planId, sourceId, signalId);
        }
        if (L_isPlanStage(_s, planId, sourceId)) {
            stageId = sourceId;
        }
    }

    function L_hasExplicitSignalAuthorization(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter
    ) private view returns (bool) {
        if (signalId == bytes32(0) || submitter == address(0)) {
            return false;
        }
        return _s.signalAuthorizations[planId][orderId][L_signalKey(sourceId, signalId)][submitter].exists;
    }

    /// origin 侧同意判定（主合约 _triggerOriginConsent 同源副本）：创建者 /
    /// 显式授权提交者 / origin 源阶段在任执行者（UB-36① 后显式授权是唯一
    /// 授权来源，收紧方向）。
    function L_triggerOriginConsent(
        UVPStateMachine.SMState storage _s,
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address party,
        bytes32 originStageId
    ) private view returns (bool) {
        if (party == address(0)) {
            return false;
        }
        UVPStateMachine.Order storage originOrder = _s.orders[originPlanId][originOrderId];
        if (!originOrder.exists) {
            return false;
        }
        if (originOrder.creator == party) {
            return true;
        }
        // 显式 order 级授权独立于执行者委任（不可被 patch 撤销）。
        if (L_hasExplicitSignalAuthorization(_s, originPlanId, originOrderId, originSourceId, originSignalId, party)) {
            return true;
        }
        UVPStateMachine.ActiveStageExecutorPatch storage activePatch =
            _s.activeStageExecutorPatches[originPlanId][originOrderId][originStageId];
        if (originStageId != bytes32(0) && activePatch.exists) {
            return activePatch.executor == party;
        }
        return false;
    }

    function L_createOrder(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        address creator,
        address relayer
    ) private {
        if (orderId == bytes32(0)) {
            revert UVPStateMachine.ZeroOrderId();
        }
        if (creator == address(0)) {
            revert UVPStateMachine.ZeroOrderCreator();
        }
        UVPStateMachine.Plan storage plan = _s.plans[planId];
        if (!plan.finalized) {
            revert UVPStateMachine.PlanNotFinalized();
        }
        UVPStateMachine.Order storage order = _s.orders[planId][orderId];
        if (order.exists) {
            revert UVPStateMachine.OrderAlreadyRegistered();
        }
        order.relayer = relayer;
        order.creator = creator;
        order.exists = true;
        order.admissionsDeclared = plan.admissionsDeclared;

        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            UVPStateMachine.StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (L_isOrderTrigger(hook.flags)) {
                L_initializeHookRuntime(order, plan.hookIds[i]);
            }
        }

        emit UVPStateMachine.OrderRegistered(orderId, planId);
        emit UVPStateMachine.OrderRelayerRecorded(planId, orderId, relayer, creator);
    }

    function L_authorizeSignalSubmitters(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        UVPStateMachine.SignalAuthorization[] calldata authorizations
    ) private {
        for (uint256 i = 0; i < authorizations.length; i++) {
            UVPStateMachine.SignalAuthorization calldata authorization = authorizations[i];
            if (authorization.signalId == bytes32(0)) {
                revert UVPStateMachine.ZeroSignalId();
            }
            if (authorization.sourceId == bytes32(0)) {
                revert UVPStateMachine.ZeroSourceId();
            }
            if (authorization.submitter == address(0)) {
                revert UVPStateMachine.ZeroSubmitter();
            }

            bytes32 key = L_signalKey(authorization.sourceId, authorization.signalId);
            UVPStateMachine.StoredSignalAuthorization storage stored =
                _s.signalAuthorizations[planId][orderId][key][authorization.submitter];
            if (stored.exists) {
                revert UVPStateMachine.SignalSubmitterAlreadyAuthorized(
                    orderId, authorization.sourceId, authorization.signalId, authorization.submitter
                );
            }

            stored.role = authorization.role;
            stored.metadataHash = authorization.metadataHash;
            stored.exists = true;

            emit UVPStateMachine.SignalSubmitterAuthorized(
                planId,
                orderId,
                authorization.sourceId,
                authorization.signalId,
                authorization.submitter,
                authorization.role,
                authorization.metadataHash
            );
        }
    }

    /// 授权集哈希（主合约 signalAuthorizationsHash 同公式副本）。
    function L_signalAuthorizationsHash(UVPStateMachine.SignalAuthorization[] calldata authorizations)
        private
        pure
        returns (bytes32)
    {
        bytes32 rollingHash = keccak256(abi.encode(authorizations.length));
        for (uint256 i = 0; i < authorizations.length; i++) {
            UVPStateMachine.SignalAuthorization calldata authorization = authorizations[i];
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    authorization.sourceId,
                    authorization.signalId,
                    authorization.submitter,
                    authorization.role,
                    authorization.metadataHash
                )
            );
        }
        return rollingHash;
    }

    /// 发射适格面卡点（主合约 _requireSignalAdmission 同源副本）。
    function L_requireSignalAdmission(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId
    ) private view {
        if (!_s.orders[planId][orderId].admissionsDeclared) {
            return;
        }
        UVPStateMachine.StoredAdmission storage admission = _s.plans[planId].admissions[L_signalKey(sourceId, signalId)];
        if (!admission.exists) {
            return;
        }
        UVPStateMachine.EvalValue memory result =
            L_evaluateInstructions(_s.signals[planId][orderId], admission.instructions);
        if (!result.value || result.wait || result.cancel) {
            revert UVPStateMachine.SignalAdmissionRejected(orderId, sourceId, signalId);
        }
    }

    /// 事实落库 + per-stage 原生计数（主合约 _recordSignal 同源副本）。
    function L_recordSignal(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        bool evaluateOrderTriggerHooks,
        bytes32 factStageId
    ) private {
        UVPStateMachine.Order storage order = _s.orders[planId][orderId];
        if (!order.exists) {
            revert UVPStateMachine.UnknownOrder();
        }
        bytes32 key = L_signalKey(sourceId, signalId);
        UVPStateMachine.SignalRecord storage signal = _s.signals[planId][orderId][key];
        if (signal.exists) {
            revert UVPStateMachine.SignalAlreadyExists();
        }

        signal.sourceId = sourceId;
        signal.signalId = signalId;
        signal.payloadHash = payloadHash;
        signal.idempotencyKey = idempotencyKey;
        signal.submittedAt = uint64(block.timestamp);
        signal.submitter = submitter;
        signal.exists = true;
        {
            UVPStateMachine.SourceSignalAccount storage sourceAccount =
                _s.sourceSignalAccounts[planId][orderId][sourceId];
            sourceAccount.count += 1;
            sourceAccount.lastSubmitter = submitter;
        }
        if (factStageId != bytes32(0)) {
            UVPStateMachine.StageSignalAccount storage account = _s.stageSignalAccounts[planId][orderId][factStageId];
            account.count += 1;
            uint64 submittedAt = uint64(block.timestamp);
            if (submittedAt > account.lastAt) {
                account.lastAt = submittedAt;
                account.lastSubmitter = submitter;
                account.ambiguous = false;
            } else if (submittedAt == account.lastAt && submitter != account.lastSubmitter) {
                account.ambiguous = true;
            }
        }

        emit UVPStateMachine.SignalSubmitted(
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter
        );
        L_evaluateAffectedHooks(_s, planId, orderId, key, sourceId, signalId, evaluateOrderTriggerHooks);
    }

    /// 出生锚订单归属 + 到达重评（主合约 _evaluateAffectedHooks 同源副本）。
    function L_evaluateAffectedHooks(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 dependencyKey,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId,
        bool evaluateOrderTriggerHooks
    ) private {
        UVPStateMachine.Plan storage plan = _s.plans[planId];
        UVPStateMachine.Order storage order = _s.orders[planId][orderId];
        bytes32[] storage hookIds = plan.dependencyIndex[dependencyKey];
        if (evaluateOrderTriggerHooks) {
            for (uint256 i = 0; i < hookIds.length; i++) {
                UVPStateMachine.StoredHook storage hook = plan.hooks[hookIds[i]];
                if (L_isOrderTrigger(hook.flags)) {
                    L_evaluateHook(_s, planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
                }
            }
        }
        for (uint256 i = 0; i < hookIds.length; i++) {
            UVPStateMachine.StoredHook storage hook = plan.hooks[hookIds[i]];
            if (!L_isOrderTrigger(hook.flags)) {
                if (hook.flags & HOOK_FLAG_EMIT_READY == 0 && !order.materializedStages[hook.stageId]) {
                    continue;
                }
                L_evaluateHook(_s, planId, orderId, hookIds[i], triggerSourceId, triggerSignalId);
            }
        }
    }

    /// hook 求值（主合约 _evaluateHook 同源副本；order-trigger 与
    /// EMIT_READY 的 Ready 分支语义相同，合并书写）。
    function L_evaluateHook(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 hookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        UVPStateMachine.Plan storage plan = _s.plans[planId];
        UVPStateMachine.StoredHook storage hook = plan.hooks[hookId];
        if (!hook.exists) {
            revert UVPStateMachine.UnknownHook();
        }

        UVPStateMachine.Order storage order = _s.orders[planId][orderId];
        UVPStateMachine.HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (!runtime.exists) {
            if (
                !L_isOrderTrigger(hook.flags) && hook.flags & HOOK_FLAG_EMIT_READY == 0
                    && !order.materializedStages[hook.stageId]
            ) {
                revert UVPStateMachine.UnknownHook();
            }
            L_initializeHookRuntime(order, hookId);
        }
        if (
            runtime.status == UVPStateMachine.HookStatus.Cancelled || runtime.status == UVPStateMachine.HookStatus.Ready
        ) {
            return;
        }

        UVPStateMachine.HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        UVPStateMachine.EvalValue memory result = L_evaluateInstructions(_s.signals[planId][orderId], hook.instructions);
        UVPStateMachine.HookStatus nextStatus = UVPStateMachine.HookStatus.Init;
        uint64 nextDueAt;
        if (result.cancel) {
            nextStatus = UVPStateMachine.HookStatus.Cancelled;
        } else if (result.wait) {
            nextStatus = UVPStateMachine.HookStatus.Wait;
            nextDueAt = result.dueAt;
        } else if (result.value) {
            nextStatus = UVPStateMachine.HookStatus.Ready;
        }

        runtime.status = nextStatus;
        runtime.dueAt = nextDueAt;

        if (previousStatus != nextStatus || previousDueAt != nextDueAt) {
            emit UVPStateMachine.HookStatusChanged(planId, orderId, hookId, previousStatus, nextStatus, nextDueAt);
        }

        if (nextStatus == UVPStateMachine.HookStatus.Ready && !runtime.readyEmitted) {
            // 发射面与主合约同构：仅 order-trigger / EMIT_READY 钩发
            // HookReady 并物化——flags=0 纯 watcher 判 Ready 不发事件、不
            // 物化（fork 重放路径不得产出顺序提交不会产生的幻影就绪）。
            if (hook.flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK | HOOK_FLAG_EMIT_READY) != 0) {
                runtime.readyEmitted = true;
                L_materializeStage(_s, planId, orderId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
                emit UVPStateMachine.HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
            }
        }
    }

    function L_initializeHookRuntime(UVPStateMachine.Order storage order, bytes32 hookId) private {
        UVPStateMachine.HookRuntime storage runtime = order.hookRuntimes[hookId];
        if (runtime.exists) {
            return;
        }
        runtime.status = UVPStateMachine.HookStatus.Init;
        runtime.dueAt = 0;
        runtime.readyEmitted = false;
        runtime.exists = true;
    }

    function L_materializeStage(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId,
        bytes32 triggerHookId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        UVPStateMachine.Order storage order = _s.orders[planId][orderId];
        if (!order.materialized) {
            order.materialized = true;
            emit UVPStateMachine.OrderMaterialized(orderId, planId, stageId);
        }
        if (order.materializedStages[stageId]) {
            return;
        }
        order.materializedStages[stageId] = true;

        UVPStateMachine.Plan storage plan = _s.plans[planId];
        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            UVPStateMachine.StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (hook.stageId == stageId) {
                L_initializeHookRuntime(order, hook.hookId);
            }
        }

        emit UVPStateMachine.StageMaterialized(
            planId, orderId, stageId, triggerHookId, triggerSourceId, triggerSignalId
        );
    }

    /// 指令求值（主合约 _evaluateInstructions + 值运算同源副本，含 UB-1
    /// 无锚防御：L_delayValue 对 anchorAt==0 永不放行、L_orValue 无锚分支
    /// 永不出线）。
    function L_evaluateInstructions(
        mapping(bytes32 => UVPStateMachine.SignalRecord) storage orderSignals,
        UVPStateMachine.Instruction[] storage instructions
    ) private view returns (UVPStateMachine.EvalValue memory) {
        UVPStateMachine.EvalValue[] memory stack = new UVPStateMachine.EvalValue[](instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < instructions.length; i++) {
            UVPStateMachine.Instruction storage instruction = instructions[i];
            if (instruction.op == uint8(UVPStateMachine.InstructionOp.Signal)) {
                stack[stackDepth++] = L_signalValue(orderSignals, instruction.sourceId, instruction.signalId);
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.Not)) {
                stack[stackDepth - 1] = L_notValue(stack[stackDepth - 1]);
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.Delay)) {
                stack[stackDepth - 1] = L_delayValue(stack[stackDepth - 1], instruction.delaySeconds);
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.And)) {
                UVPStateMachine.EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = L_andValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.Or)) {
                UVPStateMachine.EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = L_orValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else {
                revert UVPStateMachine.InvalidInstruction();
            }
        }
        return stack[0];
    }

    function L_signalValue(
        mapping(bytes32 => UVPStateMachine.SignalRecord) storage orderSignals,
        bytes32 sourceId,
        bytes32 signalId
    ) private view returns (UVPStateMachine.EvalValue memory) {
        UVPStateMachine.SignalRecord storage signal = orderSignals[L_signalKey(sourceId, signalId)];
        if (!signal.exists) {
            return UVPStateMachine.EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        return
            UVPStateMachine.EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: signal.submittedAt});
    }

    function L_notValue(UVPStateMachine.EvalValue memory value)
        private
        pure
        returns (UVPStateMachine.EvalValue memory)
    {
        if (value.value) {
            return UVPStateMachine.EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        if (value.wait) {
            return UVPStateMachine.EvalValue({value: true, wait: false, cancel: false, dueAt: value.dueAt, anchorAt: 0});
        }
        return UVPStateMachine.EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function L_delayValue(UVPStateMachine.EvalValue memory value, uint64 delaySeconds)
        private
        view
        returns (UVPStateMachine.EvalValue memory)
    {
        if (value.cancel || !value.value) {
            return value;
        }
        // 无锚永不放行（UB-1，与 Rust 权威 eval_expr Delay 臂对齐：Ready 且
        // anchors 为空返回 NeedsMore，不把 anchorAt=0 当 0 时刻起算）。
        if (value.anchorAt == 0) {
            return UVPStateMachine.EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        uint64 dueAt = value.anchorAt + delaySeconds;
        if (block.timestamp < dueAt) {
            return UVPStateMachine.EvalValue({
                value: false, wait: true, cancel: false, dueAt: dueAt, anchorAt: value.anchorAt
            });
        }
        return UVPStateMachine.EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: dueAt});
    }

    function L_andValue(UVPStateMachine.EvalValue memory left, UVPStateMachine.EvalValue memory right)
        private
        pure
        returns (UVPStateMachine.EvalValue memory)
    {
        if (left.cancel || right.cancel) {
            return UVPStateMachine.EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        if (left.value && right.value) {
            return UVPStateMachine.EvalValue({
                value: true,
                wait: false,
                cancel: false,
                dueAt: L_minDue(left.dueAt, right.dueAt),
                anchorAt: L_maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if ((left.wait && (right.value || right.wait)) || (right.wait && (left.value || left.wait))) {
            return UVPStateMachine.EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: L_maxDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
                anchorAt: L_maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        return UVPStateMachine.EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function L_orValue(UVPStateMachine.EvalValue memory left, UVPStateMachine.EvalValue memory right)
        private
        pure
        returns (UVPStateMachine.EvalValue memory)
    {
        if (left.value || right.value) {
            // UB-1：无锚分支永不出线（Rust branch_maturity (None,_) => false；
            // 有锚对无锚恒胜，双方有锚取早者）。incumbent=左，candidate=右只在
            // 严格更好时替换：右胜仅当右有锚而左无锚、或双有锚且右严格更早——
            // 四格全表 (0,0)/(t,0) 保左、(0,t) 右胜、(t,t) 取早者且平局保先到
            //（左）分支，与主合约 _orValue 逐格同表。
            bool leftWins;
            if (left.value && !right.value) {
                leftWins = true;
            } else if (!left.value && right.value) {
                leftWins = false;
            } else {
                leftWins = !(right.anchorAt != 0 && (left.anchorAt == 0 || right.anchorAt < left.anchorAt));
            }
            return UVPStateMachine.EvalValue({
                value: true,
                wait: false,
                cancel: false,
                dueAt: leftWins ? left.dueAt : right.dueAt,
                anchorAt: leftWins ? left.anchorAt : right.anchorAt
            });
        }
        if (left.wait || right.wait) {
            // 等待期限只由等待成员贡献（Rust: waits.min()；0=无限语义）。
            return UVPStateMachine.EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: L_minDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
                anchorAt: L_minAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if (left.cancel && right.cancel) {
            return UVPStateMachine.EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        return UVPStateMachine.EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function L_minDue(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }

    function L_maxDue(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function L_maxAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function L_minAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }

    function L_validatedTriggerHook(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId
    ) private view returns (UVPStateMachine.StoredHook storage hook) {
        hook = L_validatedOrderTriggerHook(_s, planId, triggerHookId, triggerStageId, HOOK_FLAG_ORDER_TRIGGER_MINT);
    }

    function L_validatedOrderTriggerHook(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        uint8 requiredFlag
    ) private view returns (UVPStateMachine.StoredHook storage hook) {
        UVPStateMachine.Plan storage plan = _s.plans[planId];
        if (!plan.finalized) {
            revert UVPStateMachine.UnknownPlan();
        }

        hook = plan.hooks[triggerHookId];
        if (!hook.exists || hook.flags & requiredFlag == 0 || hook.stageId != triggerStageId) {
            revert UVPStateMachine.InvalidTriggerHook(triggerHookId);
        }
    }

    function L_requireTriggerHookReady(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 triggerHookId,
        bytes32 triggerStageId
    ) private view {
        L_validatedTriggerHook(_s, planId, triggerHookId, triggerStageId);

        UVPStateMachine.HookRuntime storage runtime = _s.orders[planId][orderId].hookRuntimes[triggerHookId];
        if (!runtime.exists || runtime.status != UVPStateMachine.HookStatus.Ready || !runtime.readyEmitted) {
            revert UVPStateMachine.InvalidTriggerHook(triggerHookId);
        }
    }

    function L_requireTriggerHookReadyForOrder(
        UVPStateMachine.SMState storage _s,
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId
    ) private view {
        // 语义保持不变：用新单 plan 的 trigger hook 定义，评估 origin 订单的
        // 信号状态（origin 事实在 origin 订单的作用域内可见）。
        UVPStateMachine.StoredHook storage hook = L_validatedTriggerHook(_s, planId, triggerHookId, triggerStageId);
        UVPStateMachine.EvalValue memory result =
            L_evaluateInstructions(_s.signals[originPlanId][originOrderId], hook.instructions);
        if (!result.value || result.wait || result.cancel) {
            revert UVPStateMachine.InvalidTriggerHook(triggerHookId);
        }
    }

    /// UVP-08：trigger hook 的每一条 SIGNAL 指令读取的 origin 事实都必须
    /// 独立通过同意门（未发生的事实不是 origin 订单任何一方的发言，
    /// 只约束"已被说出"的事实；每条事实的属主阶段从 originFactAttributions
    /// 携证解析，有词表的 origin plan 缺证事实响亮回滚）。
    function L_requireTriggerHookSignalConsent(
        UVPStateMachine.SMState storage _s,
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 planId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        address submitter,
        address relayer,
        UVPStateMachine.FactAttribution[] calldata originFactAttributions
    ) private view {
        UVPStateMachine.StoredHook storage hook = L_validatedTriggerHook(_s, planId, triggerHookId, triggerStageId);
        for (uint256 i = 0; i < hook.instructions.length; i++) {
            UVPStateMachine.Instruction storage instruction = hook.instructions[i];
            if (instruction.op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            if (!L_hasSignal(_s, originPlanId, originOrderId, instruction.sourceId, instruction.signalId)) {
                continue;
            }
            bytes32 originStageId = L_resolveSourceStageFrom(
                _s, originPlanId, instruction.sourceId, instruction.signalId, originFactAttributions
            );
            if (L_triggerOriginConsent(
                    _s,
                    originPlanId,
                    originOrderId,
                    instruction.sourceId,
                    instruction.signalId,
                    submitter,
                    originStageId
                )) {
                continue;
            }
            if (
                relayer != address(0)
                    && L_triggerOriginConsent(
                        _s,
                        originPlanId,
                        originOrderId,
                        instruction.sourceId,
                        instruction.signalId,
                        relayer,
                        originStageId
                    )
            ) {
                continue;
            }
            revert UVPStateMachine.UnauthorizedTriggerOrigin(originPlanId, originOrderId, submitter);
        }
    }

    /// order-link 派生单的 trigger hook 就绪落位（仅 order-link 出生路径
    /// 使用）。与 outside/dock 不同，派生单在标记前没有事务内求值——
    /// 子单事实集为空，多原子触发线在子单作用域内永不可达 Ready；其
    /// 就绪裁决由 L_requireTriggerHookReadyForOrder 以 origin 订单的事实
    /// 作用域预先断言（求值面 = origin 事实）。本入口保留链接路径的
    /// 旧守卫：Cancelled（终态矛盾）拒绝，其余落 Ready——outside/dock
    /// 的断言式守卫（非 Ready 即拒）只适用于"先求值后标记"的出生路径。
    function L_markTriggerHookReady(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 triggerHookId,
        bytes32 triggerStageId,
        bytes32 triggerSourceId,
        bytes32 triggerSignalId
    ) private {
        UVPStateMachine.StoredHook storage hook = L_validatedTriggerHook(_s, planId, triggerHookId, triggerStageId);
        UVPStateMachine.Order storage order = _s.orders[planId][orderId];
        UVPStateMachine.HookRuntime storage runtime = order.hookRuntimes[triggerHookId];
        if (!runtime.exists) {
            L_initializeHookRuntime(order, triggerHookId);
        }
        if (runtime.status == UVPStateMachine.HookStatus.Cancelled) {
            revert UVPStateMachine.InvalidTriggerHook(triggerHookId);
        }

        UVPStateMachine.HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        runtime.status = UVPStateMachine.HookStatus.Ready;
        runtime.dueAt = 0;

        if (previousStatus != UVPStateMachine.HookStatus.Ready || previousDueAt != 0) {
            emit UVPStateMachine.HookStatusChanged(
                planId, orderId, triggerHookId, previousStatus, UVPStateMachine.HookStatus.Ready, 0
            );
        }

        if (!runtime.readyEmitted) {
            runtime.readyEmitted = true;
            L_materializeStage(_s, planId, orderId, triggerStageId, triggerHookId, triggerSourceId, triggerSignalId);
            emit UVPStateMachine.HookReady(planId, orderId, triggerHookId, hook.stageId, hook.hookName);
        }
    }


    /// order-link 派生订单号（主合约 orderLinkOrderIdFor 同公式副本）。
    function L_orderLinkOrderIdFor(
        bytes32 planId,
        bytes32 originPlanId,
        bytes32 triggerOriginOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        bytes32 payloadHash
    ) private pure returns (bytes32) {
        return bytes32(
            uint256(
                keccak256(
                    abi.encode(
                        _L_ORDER_LINK_ORDER_ID_DOMAIN,
                        planId,
                        originPlanId,
                        triggerOriginOrderId,
                        originSourceId,
                        originSignalId,
                        payloadHash
                    )
                )
            ) & ~(uint256(1) << 255)
        );
    }

    /// fork 派生订单号（主合约 forkOrderIdFor 同公式副本）。
    function L_forkOrderIdFor(bytes32 planId, bytes32 parentOrderId, bytes32 forkPayloadHash)
        private
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(keccak256(abi.encode(_L_FORK_ORDER_ID_DOMAIN, planId, parentOrderId, forkPayloadHash)))
                & ~(uint256(1) << 255)
        );
    }

    function L_triggerOrderFromOutsideDigest(
        UVPStateMachine.TriggerOrderFromOutsideRequest calldata trigger,
        bytes32 authorizationsHash
    ) private view returns (bytes32) {
        bytes memory encoded = new bytes(0x180);
        L_writeWord(encoded, 0x00, _L_TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH);
        L_writeWord(encoded, 0x20, trigger.planId);
        L_writeAddress(encoded, 0x40, trigger.creator);
        L_writeWord(encoded, 0x60, trigger.triggerHookId);
        L_writeWord(encoded, 0x80, trigger.triggerStageId);
        L_writeWord(encoded, 0xa0, trigger.sourceId);
        L_writeWord(encoded, 0xc0, trigger.signalId);
        L_writeWord(encoded, 0xe0, trigger.payloadHash);
        L_writeWord(encoded, 0x100, trigger.idempotencyKey);
        L_writeWord(encoded, 0x120, authorizationsHash);
        L_writeAddress(encoded, 0x140, trigger.submitter);
        L_writeWord(encoded, 0x160, bytes32(trigger.deadline));
        bytes32 structHash = keccak256(encoded);
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function L_writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function L_writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        L_writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function L_recoverSignalSubmitter(bytes32 digest, bytes calldata signature) private pure returns (address) {
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
}
