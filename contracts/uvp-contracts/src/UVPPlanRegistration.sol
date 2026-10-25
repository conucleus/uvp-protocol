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
    _MAX_HOOKS_PER_DEPENDENCY_KEY as MAX_HOOKS_PER_DEPENDENCY_KEY,
    _MAX_INSTRUCTION_DEPTH as MAX_INSTRUCTION_DEPTH,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN,
    _PLAN_COMMIT_TYPEHASH,
    _EXECUTOR_CANDIDATE_LEAF_DOMAIN
} from "./UVPStateMachineConstants.sol";

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

        bytes32 dockRoutesRoot = _orEmptyDockRoot(commit.dockRoutesRoot);
        bytes32 dockInterfaceRoot = _orEmptyDockRoot(commit.dockInterfaceRoot);
        bytes32 capabilitiesRoot = _orEmptyDockRoot(commit.capabilitiesRoot);
        bytes32 executorCandidatesRoot = _executorCandidatesRoot(executorCandidates);
        bytes32 committedCandidatesRoot = _orEmptyDockRoot(commit.executorCandidatesRoot);
        if (executorCandidatesRoot != committedCandidatesRoot) {
            revert UVPStateMachine.ExecutorCandidatesRootMismatch(committedCandidatesRoot, executorCandidatesRoot);
        }
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
        for (uint256 i = 0; i < executorCandidates.length; i++) {
            plan.executorCandidateStages[executorCandidates[i].stageId] = true;
        }

        {
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
            executorCandidatesRoot,
            commit.birthAuthorizer
        );
        emit UVPStateMachine.PlanPublisherRecorded(planId, commit.publisher);
    }

    function _orEmptyDockRoot(bytes32 root) private pure returns (bytes32) {
        return root == bytes32(0) ? DockMerkle.EMPTY_ROOT : root;
    }

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
        if (input.flags & HOOK_FLAG_ADMISSION != 0) {
            _registerPlanAdmission(plan, input);
            return seenCount;
        }
        _validateInstructions(input, false);
        if (
            input.flags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK)
                == (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_ORDER_TRIGGER_DOCK)
        ) {
            revert UVPStateMachine.InvalidHook();
        }
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
        for (uint256 j = 0; j < input.dependencyKeys.length; j++) {
            bytes32 dependencyKey = input.dependencyKeys[j];

            bytes32[] storage dependents = plan.dependencyIndex[dependencyKey];
            if (dependents.length != 0 && dependents[dependents.length - 1] == input.hookId) {
                continue;
            }
            if (dependents.length >= MAX_HOOKS_PER_DEPENDENCY_KEY) {
                revert UVPStateMachine.TooManyHooksPerDependencyKey(dependencyKey);
            }
            bool inputIsTrigger = _isOrderTrigger(input.flags);
            if (dependents.length == 0) {
                if (updatedCount == MAX_PLAN_DEPENDENCIES) {
                    revert UVPStateMachine.TooManyDependencies();
                }
                updatedCount += 1;
            } else {
                bool inputIsDock = input.flags & HOOK_FLAG_ORDER_TRIGGER_DOCK != 0;
                for (uint256 k = 0; k < dependents.length; k++) {
                    if (inputIsTrigger && _isOrderTrigger(plan.hooks[dependents[k]].flags)) {
                        if (inputIsDock || plan.hooks[dependents[k]].flags & HOOK_FLAG_ORDER_TRIGGER_DOCK != 0) {
                            revert UVPStateMachine.DuplicateBirthChannelKey(dependencyKey);
                        }
                    }
                }
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

    function _registerPlanAdmission(UVPStateMachine.Plan storage plan, UVPStateMachine.CompactHook calldata input)
        private
    {
        if (input.flags != HOOK_FLAG_ADMISSION) {
            revert UVPStateMachine.InvalidHook();
        }
        _validateInstructions(input, true);
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

    uint256 private constant _SLOT_BARE_SIGNAL = 1 << 0;
    uint256 private constant _SLOT_DELAY_RESULT = 1 << 1;
    uint256 private constant _SLOT_VETO_TERM = 1 << 2;
    uint256 private constant _SLOT_VETO_INSIDE = 1 << 3;
    uint256 private constant _SLOT_DELAY_INSIDE = 1 << 4;
    uint256 private constant _SLOT_POS_ANCHOR = 1 << 5;
    uint256 private constant _SLOT_DEPTH_INC = uint256(1) << 32;
    uint256 private constant _SLOT_DEPTH_FIELD = type(uint256).max << 32;

    function _validateInstructions(UVPStateMachine.CompactHook calldata input, bool admissionMode) private pure {
        if (
            input.hookId == bytes32(0) || input.stageId == bytes32(0) || input.hookName == bytes32(0)
                || input.instructions.length == 0 || input.dependencyKeys.length == 0
        ) {
            revert UVPStateMachine.InvalidHook();
        }

        bool orderTrigger = _isOrderTrigger(input.flags);
        uint256[] memory slots = new uint256[](input.instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < input.instructions.length; i++) {
            UVPStateMachine.Instruction calldata instruction = input.instructions[i];
            if (instruction.op == uint8(UVPStateMachine.InstructionOp.Signal)) {
                if (instruction.sourceId == bytes32(0)) {
                    revert UVPStateMachine.ZeroSourceId();
                }
                if (instruction.signalId == bytes32(0)) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                slots[stackDepth] = _SLOT_BARE_SIGNAL | _SLOT_POS_ANCHOR;
                stackDepth += 1;
            } else if (
                instruction.op == uint8(UVPStateMachine.InstructionOp.Not)
                    || instruction.op == uint8(UVPStateMachine.InstructionOp.Delay)
            ) {
                if (stackDepth == 0) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                uint256 operand = slots[stackDepth - 1];
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
                    if (operand & _SLOT_POS_ANCHOR == 0) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    if (!admissionMode && operand & (_SLOT_VETO_TERM | _SLOT_VETO_INSIDE) != 0) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    if (operand & _SLOT_DELAY_INSIDE != 0) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    slots[stackDepth - 1] =
                        ((operand & (_SLOT_POS_ANCHOR | _SLOT_DEPTH_FIELD)) | _SLOT_DELAY_RESULT | _SLOT_DELAY_INSIDE)
                            + _SLOT_DEPTH_INC;
                } else {
                    if (operand & (_SLOT_BARE_SIGNAL | _SLOT_DELAY_RESULT) == 0) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                    uint256 newVetoTerm = (operand & _SLOT_DELAY_RESULT) << 1;
                    slots[stackDepth - 1] =
                        ((operand & (_SLOT_DELAY_INSIDE | _SLOT_VETO_INSIDE | _SLOT_DEPTH_FIELD)) | newVetoTerm)
                            + _SLOT_DEPTH_INC;
                }
            } else if (
                instruction.op == uint8(UVPStateMachine.InstructionOp.And)
                    || instruction.op == uint8(UVPStateMachine.InstructionOp.Or)
            ) {
                if (instruction.arity < 2 || stackDepth < instruction.arity) {
                    revert UVPStateMachine.InvalidInstruction();
                }
                bool orHardGate = instruction.op == uint8(UVPStateMachine.InstructionOp.Or) && !admissionMode;
                uint256 folded;
                uint256 maxOperandDepth;
                for (uint256 j = stackDepth - instruction.arity; j < stackDepth; j++) {
                    uint256 operand = slots[j];
                    folded |= operand;
                    uint256 operandDepth = operand >> 32;
                    if (operandDepth > maxOperandDepth) {
                        maxOperandDepth = operandDepth;
                    }
                    if (orHardGate && operand & (_SLOT_VETO_TERM | _SLOT_POS_ANCHOR) != _SLOT_POS_ANCHOR) {
                        revert UVPStateMachine.InvalidInstruction();
                    }
                }
                stackDepth = stackDepth - instruction.arity + 1;
                if (orHardGate) {
                    slots[stackDepth - 1] =
                        (folded & (_SLOT_VETO_INSIDE | _SLOT_DELAY_INSIDE)) | _SLOT_POS_ANCHOR | ((maxOperandDepth + 1) << 32);
                } else {
                    slots[stackDepth - 1] =
                        (folded & (_SLOT_VETO_INSIDE | _SLOT_DELAY_INSIDE | _SLOT_POS_ANCHOR)) | ((maxOperandDepth + 1) << 32);
                }
            } else {
                revert UVPStateMachine.InvalidInstruction();
            }
            if (slots[stackDepth - 1] >> 32 > MAX_INSTRUCTION_DEPTH) {
                revert UVPStateMachine.InvalidInstruction();
            }
        }
        if (stackDepth != 1) {
            revert UVPStateMachine.InvalidInstruction();
        }
        if (!admissionMode) {
            if (slots[0] & _SLOT_VETO_TERM != 0) {
                revert UVPStateMachine.InvalidInstruction();
            }
            if (slots[0] & _SLOT_POS_ANCHOR == 0) {
                revert UVPStateMachine.InvalidInstruction();
            }
        }
        _requireDependencyKeysMatch(input.hookId, input.instructions, input.dependencyKeys);
    }

    function _requireDependencyKeysMatch(
        bytes32 hookId,
        UVPStateMachine.Instruction[] calldata instructions,
        bytes32[] calldata dependencyKeys
    ) private pure {
        uint256 signalKeyCount = 0;
        bytes32[] memory signalKeys = new bytes32[](instructions.length);
        for (uint256 i = 0; i < instructions.length; i++) {
            if (instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            bytes32 signalKey = keccak256(abi.encode(instructions[i].sourceId, instructions[i].signalId));
            if (!_containsKey(signalKeys, signalKeyCount, signalKey)) {
                signalKeys[signalKeyCount] = signalKey;
                signalKeyCount += 1;
            }
        }
        uint256 declaredKeyCount = 0;
        bytes32[] memory declaredKeys = new bytes32[](dependencyKeys.length);
        for (uint256 j = 0; j < dependencyKeys.length; j++) {
            bytes32 dependencyKey = dependencyKeys[j];
            if (_containsKey(declaredKeys, declaredKeyCount, dependencyKey)) {
                continue;
            }
            declaredKeys[declaredKeyCount] = dependencyKey;
            declaredKeyCount += 1;
            if (!_containsKey(signalKeys, signalKeyCount, dependencyKey)) {
                revert UVPStateMachine.HookDependencyKeyMismatch(hookId);
            }
        }
        if (declaredKeyCount != signalKeyCount) {
            revert UVPStateMachine.HookDependencyKeyMismatch(hookId);
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

    bytes32 private constant _L_ORDER_LINK_ORDER_ID_DOMAIN = keccak256("uvp.order_link.order_id.v1");
    bytes32 private constant _L_FORK_ORDER_ID_DOMAIN = keccak256("uvp.fork.order_id.v1");
    bytes32 private constant _L_TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

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
        if (trigger.sourceId == bytes32(0)) {
            revert UVPStateMachine.ZeroSourceId();
        }
        if (trigger.signalId == bytes32(0)) {
            revert UVPStateMachine.ZeroSignalId();
        }
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
        UVPStateMachine.Plan storage plan = _s.plans[trigger.planId];
        if (!plan.committed) {
            revert UVPStateMachine.PlanNotFinalized();
        }
        if (plan.birthAuthorizer != trigger.submitter) {
            revert UVPStateMachine.UnauthorizedBirthSubmitter(trigger.submitter);
        }

        bytes32 orderId = bytes32(
            uint256(keccak256(abi.encode(trigger.planId, trigger.sourceId, trigger.signalId, trigger.payloadHash)))
                & ~(uint256(1) << 255)
        );
        L_requireNotDockNamespace(orderId);

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
            true,
            birthStageId
        );
        L_requireTriggerHookReady(_s, trigger.planId, orderId, trigger.triggerHookId, trigger.triggerStageId);
    }

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

        UVPStateMachine.Order storage triggerOriginOrder = _s.orders[trigger.originPlanId][trigger.triggerOriginOrderId];
        if (!triggerOriginOrder.exists) {
            revert UVPStateMachine.UnknownOrder();
        }
        if (!L_hasSignal(
                _s, trigger.originPlanId, trigger.triggerOriginOrderId, trigger.originSourceId, trigger.originSignalId
            )) {
            revert UVPStateMachine.UnknownOrder();
        }
        bytes32 declaredOriginStage = L_resolveSourceStageFrom(
            _s, trigger.originPlanId, trigger.originSourceId, trigger.originSignalId, originFactAttributions
        );
        if (
            !L_eitherTriggerOriginConsent(
                _s,
                trigger.originPlanId,
                trigger.triggerOriginOrderId,
                trigger.originSourceId,
                trigger.originSignalId,
                trigger.submitter,
                relayer,
                declaredOriginStage
            )
        ) {
            revert UVPStateMachine.UnauthorizedTriggerOrigin(
                trigger.originPlanId, trigger.triggerOriginOrderId, trigger.submitter
            );
        }
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

        L_requireNotDockNamespace(trigger.orderId);

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

    function forkOrderGate(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 parentOrderId,
        bytes32 forkPayloadHash,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        UVPStateMachine.ForkBirthFact[] calldata birthFacts,
        UVPStateMachine.SignalAuthorization[] calldata authorizations
    ) external returns (bytes32 forkedOrderId) {
        address initiator = msg.sender;
        UVPStateMachine.Order storage parentOrder = _s.orders[planId][parentOrderId];
        if (!parentOrder.exists) {
            revert UVPStateMachine.UnknownOrder();
        }
        if (!L_hasSignal(_s, planId, parentOrderId, approvalSourceId, approvalSignalId)) {
            revert UVPStateMachine.ForkApprovalSignalUnknown(planId, parentOrderId, approvalSourceId, approvalSignalId);
        }
        {
            address approvalSubmitter =
                _s.signals[planId][parentOrderId][L_signalKey(approvalSourceId, approvalSignalId)].submitter;
            if (initiator != parentOrder.creator && initiator != approvalSubmitter) {
                revert UVPStateMachine.UnauthorizedOrderFork(planId, parentOrderId, initiator);
            }
        }

        forkedOrderId = L_forkOrderIdFor(planId, parentOrderId, forkPayloadHash);
        L_requireNotDockNamespace(forkedOrderId);
        L_createOrder(_s, planId, forkedOrderId, parentOrder.creator, initiator);
        _s.orders[planId][forkedOrderId].parentOrderId = parentOrderId;
        L_authorizeSignalSubmitters(_s, planId, forkedOrderId, authorizations);
        {
            bytes32[] memory replayedFactKeys = new bytes32[](birthFacts.length);
            for (uint256 i = 0; i < birthFacts.length; i++) {
                replayedFactKeys[i] = L_signalKey(birthFacts[i].sourceId, birthFacts[i].signalId);
            }
            emit UVPStateMachine.OrderForked(
                planId,
                forkedOrderId,
                parentOrderId,
                approvalSourceId,
                approvalSignalId,
                initiator,
                forkPayloadHash,
                replayedFactKeys
            );
        }
    }

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
                parentSignal.submitter,
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
        stageId = L_unattributedStage(_s, planId, sourceId, signalId);
    }

    function L_unattributedStage(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId
    ) private view returns (bytes32) {
        if (L_hasCapabilityVocabulary(_s, planId)) {
            revert UVPStateMachine.InvalidSignalCapability(planId, sourceId, signalId);
        }
        return L_isPlanStage(_s, planId, sourceId) ? sourceId : bytes32(0);
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
        stageId = L_unattributedStage(_s, planId, sourceId, signalId);
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

    function L_eitherTriggerOriginConsent(
        UVPStateMachine.SMState storage _s,
        bytes32 originPlanId,
        bytes32 originOrderId,
        bytes32 originSourceId,
        bytes32 originSignalId,
        address submitter,
        address relayer,
        bytes32 originStageId
    ) private view returns (bool) {
        if (
            L_triggerOriginConsent(
                _s, originPlanId, originOrderId, originSourceId, originSignalId, submitter, originStageId
            )
        ) {
            return true;
        }
        return L_triggerOriginConsent(_s, originPlanId, originOrderId, originSourceId, originSignalId, relayer, originStageId);
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
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, factStageId
        );
        L_evaluateAffectedHooks(_s, planId, orderId, key, sourceId, signalId, evaluateOrderTriggerHooks);
    }

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
        UVPStateMachine.StoredHook storage hook = L_validatedTriggerHook(_s, planId, triggerHookId, triggerStageId);
        UVPStateMachine.EvalValue memory result =
            L_evaluateInstructions(_s.signals[originPlanId][originOrderId], hook.instructions);
        if (!result.value || result.wait || result.cancel) {
            revert UVPStateMachine.InvalidTriggerHook(triggerHookId);
        }
    }

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
            if (
                L_eitherTriggerOriginConsent(
                    _s,
                    originPlanId,
                    originOrderId,
                    instruction.sourceId,
                    instruction.signalId,
                    submitter,
                    relayer,
                    originStageId
                )
            ) {
                continue;
            }
            revert UVPStateMachine.UnauthorizedTriggerOrigin(originPlanId, originOrderId, submitter);
        }
    }

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

    function L_requireNotDockNamespace(bytes32 orderId) private pure {
        if (uint256(orderId) & (uint256(1) << 255) != 0) {
            revert UVPStateMachine.InvalidDockOrderNamespace(orderId);
        }
    }

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
