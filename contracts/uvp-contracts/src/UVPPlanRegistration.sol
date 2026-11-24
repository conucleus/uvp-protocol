// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {MerkleCommitment} from "./libraries/MerkleCommitment.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {IUVPIdentityRegistry} from "./interfaces/IUVPIdentityRegistry.sol";
import {IUVPFileResourceModule, StageFilesEmpty} from "./interfaces/IUVPFileResourceModule.sol";
import {UVPStateMachine} from "./UVPStateMachine.sol";
import {UVPHookEvaluator} from "./libraries/UVPHookEvaluator.sol";
import {
    _HOOK_FLAG_ORDER_TRIGGER_MINT as HOOK_FLAG_ORDER_TRIGGER_MINT,
    _HOOK_FLAG_EMIT_READY as HOOK_FLAG_EMIT_READY,
    _HOOK_FLAG_ADMISSION as HOOK_FLAG_ADMISSION,
    _HOOK_FLAG_DOCK_EXECUTOR as HOOK_FLAG_DOCK_EXECUTOR,
    _HOOK_FLAG_DYNAMIC_EXECUTOR as HOOK_FLAG_DYNAMIC_EXECUTOR,
    _MAX_HOOK_DELAY_SECONDS as MAX_HOOK_DELAY_SECONDS,
    _MAX_PLAN_DEPENDENCIES as MAX_PLAN_DEPENDENCIES,
    _MAX_HOOKS_PER_DEPENDENCY_KEY as MAX_HOOKS_PER_DEPENDENCY_KEY,
    _MAX_INSTRUCTION_DEPTH as MAX_INSTRUCTION_DEPTH,
    _MAX_SUPPLIER_BINDINGS as MAX_SUPPLIER_BINDINGS,
    _MAX_FILE_WRITERS as MAX_FILE_WRITERS,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_RUNTIME_HASH_DOMAIN,
    _PLAN_ID_HASH_DOMAIN,
    _PLAN_COMMIT_TYPEHASH,
    _SUPPLIER_BINDING_LEAF_DOMAIN,
    _FACT_ATTRIBUTION_TYPEHASH,
    _SIGNAL_SUBMISSION_TYPEHASH
} from "./UVPStateMachineConstants.sol";

library UVPPlanRegistration {
    uint8 private constant _STAGE_TRIGGER = 1;
    uint8 private constant _STAGE_DOCK = 2;
    uint8 private constant _STAGE_DYNAMIC = 4;
    bytes4 private constant _EIP1271_MAGIC_VALUE = 0x1626ba7e;

    function commitPlan(
        mapping(bytes32 => UVPStateMachine.Plan) storage _plans,
        bool modulesFrozen,
        address identityRegistry,
        UVPStateMachine.PlanCommit calldata commit,
        UVPStateMachine.CompactHook[] calldata hooks,
        UVPStateMachine.StageSupplierBinding[] calldata bindings,
        UVPStateMachine.StageFileWriter[] calldata fileWriters,
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
        if (bindings.length > MAX_SUPPLIER_BINDINGS) {
            revert UVPStateMachine.TooManySupplierBindings(bindings.length);
        }
        if (fileWriters.length > MAX_FILE_WRITERS) {
            revert UVPStateMachine.TooManyFileWriters(fileWriters.length);
        }
        bytes32 actualFileWritersHash = keccak256(abi.encode(fileWriters));
        if (actualFileWritersHash != commit.fileWritersHash) {
            revert UVPStateMachine.FileWritersHashMismatch(commit.fileWritersHash, actualFileWritersHash);
        }
        bytes32 actualHooksHash = keccak256(abi.encode(hooks));
        if (actualHooksHash != commit.hooksHash) {
            revert UVPStateMachine.HooksHashMismatch(commit.hooksHash, actualHooksHash);
        }
        address recoveredSigner = _recoverPlanPublisher(_planCommitDigest(commit), signature);
        if (recoveredSigner != commit.publisher) {
            revert UVPStateMachine.InvalidPlanSignature(commit.publisher, recoveredSigner);
        }

        bytes32 capabilitiesRoot = _orEmptyRoot(commit.capabilitiesRoot);
        bytes32 supplierBindingsRoot = _supplierBindingsRoot(bindings);
        if (supplierBindingsRoot != commit.supplierBindingsRoot) {
            revert UVPStateMachine.SupplierBindingsRootMismatch(commit.supplierBindingsRoot, supplierBindingsRoot);
        }
        bytes32 runtimePlanHash =
            planRuntimeHash(commit.hooksHash, capabilitiesRoot, supplierBindingsRoot, commit.fileWritersHash);
        planId = planIdFor(commit.publisher, runtimePlanHash);
        UVPStateMachine.Plan storage plan = _plans[planId];
        if (plan.committed) {
            revert UVPStateMachine.PlanAlreadyRegistered();
        }
        plan.planHash = runtimePlanHash;
        plan.hooksHash = commit.hooksHash;
        plan.capabilitiesRoot = capabilitiesRoot;
        plan.supplierBindingsRoot = supplierBindingsRoot;
        plan.fileWritersHash = commit.fileWritersHash;
        plan.publisher = commit.publisher;
        plan.committed = true;

        {
            bytes32[] memory stages = new bytes32[](hooks.length);
            uint8[] memory stageKinds = new uint8[](hooks.length);
            bool[] memory materializable = new bool[](hooks.length);
            uint256 stageCount;
            uint256 seenCount;
            for (uint256 i = 0; i < hooks.length; i++) {
                seenCount = _registerPlanHook(plan, hooks[i], seenCount);
                uint8 hookFlags = hooks[i].flags;
                bool admission = hookFlags == HOOK_FLAG_ADMISSION;
                bool dynamic = !admission && hookFlags & HOOK_FLAG_DYNAMIC_EXECUTOR != 0;
                if (dynamic) {
                    if (
                        hookFlags & (HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_DOCK_EXECUTOR) != 0
                            || hookFlags & HOOK_FLAG_EMIT_READY == 0
                    ) {
                        revert UVPStateMachine.InconsistentDynamicSupplierFlag(hooks[i].stageId);
                    }
                }
                uint256 stageIndex = _seenDependencyIndex(stages, stageCount, hooks[i].stageId);
                if (stageIndex == type(uint256).max) {
                    stageIndex = stageCount;
                    stages[stageIndex] = hooks[i].stageId;
                    stageCount += 1;
                }
                if (!admission) {
                    if (hookFlags & HOOK_FLAG_ORDER_TRIGGER_MINT != 0) {
                        stageKinds[stageIndex] |= _STAGE_TRIGGER;
                    }
                    if (hookFlags & HOOK_FLAG_DOCK_EXECUTOR != 0) {
                        stageKinds[stageIndex] |= _STAGE_DOCK;
                    }
                    if (dynamic) {
                        stageKinds[stageIndex] |= _STAGE_DYNAMIC;
                    }
                }
                if (_hookCanMaterializeStage(hookFlags)) {
                    materializable[stageIndex] = true;
                }
            }
            for (uint256 i = 0; i < stageCount; i++) {
                if (!materializable[i]) {
                    revert UVPStateMachine.StageNotMaterializable(stages[i]);
                }
                if (stageKinds[i] & _STAGE_DYNAMIC != 0) {
                    plan.dynamicSupplierStages[stages[i]] = true;
                }
            }
            _applySupplierBindings(plan, bindings, identityRegistry, stages, stageKinds, stageCount);
            _applyFileWriters(plan, fileWriters, stages, stageCount);
        }

        emit UVPStateMachine.PlanCommitted(
            planId,
            runtimePlanHash,
            commit.publisher,
            commit.hooksHash,
            capabilitiesRoot,
            hooks.length,
            supplierBindingsRoot
        );
        emit UVPStateMachine.PlanPublisherRecorded(planId, commit.publisher);
    }

    function _orEmptyRoot(bytes32 root) private pure returns (bytes32) {
        return root == bytes32(0) ? MerkleCommitment.EMPTY_ROOT : root;
    }

    function _supplierBindingsRoot(UVPStateMachine.StageSupplierBinding[] calldata bindings)
        private
        pure
        returns (bytes32)
    {
        bytes32[] memory leaves = new bytes32[](bindings.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    _SUPPLIER_BINDING_LEAF_DOMAIN, bindings[i].stageId, bindings[i].supplierId, bindings[i].kind
                )
            );
        }
        return MerkleCommitment.root(leaves);
    }

    function _applySupplierBindings(
        UVPStateMachine.Plan storage plan,
        UVPStateMachine.StageSupplierBinding[] calldata bindings,
        address identityRegistry,
        bytes32[] memory stages,
        uint8[] memory stageKinds,
        uint256 stageCount
    ) private {
        for (uint256 i = 0; i < bindings.length; i++) {
            UVPStateMachine.StageSupplierBinding calldata binding = bindings[i];
            if (binding.kind != 0) {
                continue;
            }
            uint256 stageIndex = _seenDependencyIndex(stages, stageCount, binding.stageId);
            if (stageIndex == type(uint256).max) {
                revert UVPStateMachine.UnknownPlanStage(binding.stageId);
            }
            if (stageKinds[stageIndex] & (_STAGE_DOCK | _STAGE_DYNAMIC) != 0) {
                revert UVPStateMachine.SupplierBindingForbiddenForStage(binding.stageId);
            }
            if (plan.stageDefaultSuppliers[binding.stageId] != bytes32(0)) {
                revert UVPStateMachine.DuplicateSupplierBinding(binding.stageId, binding.supplierId, binding.kind);
            }
            _requireActiveSupplier(identityRegistry, binding.supplierId);
            plan.stageDefaultSuppliers[binding.stageId] = binding.supplierId;
        }

        for (uint256 i = 0; i < bindings.length; i++) {
            UVPStateMachine.StageSupplierBinding calldata binding = bindings[i];
            if (binding.kind == 0) {
                continue;
            }
            if (binding.kind != 1) {
                revert UVPStateMachine.InvalidSupplierBindingKind(binding.kind);
            }
            uint256 stageIndex = _seenDependencyIndex(stages, stageCount, binding.stageId);
            if (stageIndex == type(uint256).max) {
                revert UVPStateMachine.UnknownPlanStage(binding.stageId);
            }
            if (stageKinds[stageIndex] & (_STAGE_TRIGGER | _STAGE_DOCK | _STAGE_DYNAMIC) != 0) {
                revert UVPStateMachine.CandidateSupplierBindingForbiddenForStage(binding.stageId);
            }
            if (plan.stageDefaultSuppliers[binding.stageId] == bytes32(0)) {
                revert UVPStateMachine.CandidateSupplierBindingRequiresDefault(binding.stageId);
            }
            for (uint256 j = 0; j < i; j++) {
                if (
                    bindings[j].kind == 1 && bindings[j].stageId == binding.stageId
                        && bindings[j].supplierId == binding.supplierId
                ) {
                    revert UVPStateMachine.DuplicateSupplierBinding(
                        binding.stageId, binding.supplierId, binding.kind
                    );
                }
            }
            _requireActiveSupplier(identityRegistry, binding.supplierId);
            plan.stageCandidateStages[binding.stageId] = true;
        }
    }

    function _applyFileWriters(
        UVPStateMachine.Plan storage plan,
        UVPStateMachine.StageFileWriter[] calldata fileWriters,
        bytes32[] memory stages,
        uint256 stageCount
    ) private {
        for (uint256 i = 0; i < fileWriters.length; i++) {
            UVPStateMachine.StageFileWriter calldata writer = fileWriters[i];
            if (writer.targetStageId == bytes32(0)) {
                revert UVPStateMachine.ZeroFileTargetStageId();
            }
            if (writer.writerStageId == bytes32(0) || writer.writerStageId == writer.targetStageId) {
                revert UVPStateMachine.InvalidFileWriter(writer.targetStageId, writer.writerStageId);
            }
            if (_seenDependencyIndex(stages, stageCount, writer.targetStageId) == type(uint256).max) {
                revert UVPStateMachine.UnknownPlanStage(writer.targetStageId);
            }
            if (_seenDependencyIndex(stages, stageCount, writer.writerStageId) == type(uint256).max) {
                revert UVPStateMachine.UnknownPlanStage(writer.writerStageId);
            }
            bytes32[] storage targetWriters = plan.fileWriterStages[writer.targetStageId];
            for (uint256 j = 0; j < targetWriters.length; j++) {
                if (targetWriters[j] == writer.writerStageId) {
                    revert UVPStateMachine.DuplicateFileWriter(writer.targetStageId, writer.writerStageId);
                }
            }
            targetWriters.push(writer.writerStageId);
        }
    }

    function _requireActiveSupplier(address identityRegistry, bytes32 supplierId) private view {
        if (identityRegistry == address(0)) {
            revert UVPStateMachine.IdentityRegistryNotConfigured();
        }
        if (!IUVPIdentityRegistry(identityRegistry).isActiveSupplier(supplierId)) {
            revert UVPStateMachine.SupplierNotActive(supplierId);
        }
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
            .finalizePlanMetadata(planId, plan.capabilitiesRoot);

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
            _isOrderTrigger(input.flags)
                && (
                    input.instructions.length != 1
                        || input.instructions[0].op != uint8(UVPStateMachine.InstructionOp.Signal)
                )
        ) {
            revert UVPStateMachine.InvalidTriggerHook(input.hookId);
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
            if (dependents.length == 0) {
                if (updatedCount == MAX_PLAN_DEPENDENCIES) {
                    revert UVPStateMachine.TooManyDependencies();
                }
                updatedCount += 1;
            }

            hook.dependencyKeys.push(dependencyKey);
            dependents.push(input.hookId);
        }

        plan.hookIds.push(input.hookId);
        plan.stageHookIds[input.stageId].push(input.hookId);
        plan.stageExists[input.stageId] = true;
        return updatedCount;
    }

    function _registerPlanAdmission(UVPStateMachine.Plan storage plan, UVPStateMachine.CompactHook calldata input)
        private
    {
        if (input.flags != HOOK_FLAG_ADMISSION) {
            revert UVPStateMachine.InvalidHook();
        }
        if (!_admissionKeyMatches(plan, input)) {
            revert UVPStateMachine.InvalidAdmissionHook(input.hookId);
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

    function _admissionKeyMatches(UVPStateMachine.Plan storage plan, UVPStateMachine.CompactHook calldata input)
        private
        view
        returns (bool)
    {
        if (input.hookId == L_signalKey(input.stageId, input.hookName)) {
            return true;
        }
        for (uint256 h = 0; h < plan.hookIds.length; h++) {
            UVPStateMachine.Instruction[] storage instructions = plan.hooks[plan.hookIds[h]].instructions;
            for (uint256 i = 0; i < instructions.length; i++) {
                if (instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                    continue;
                }
                if (input.hookId == L_signalKey(instructions[i].sourceId, input.hookName)) {
                    return true;
                }
            }
        }
        for (uint256 i = 0; i < input.instructions.length; i++) {
            if (input.instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            if (input.hookId == L_signalKey(input.instructions[i].sourceId, input.hookName)) {
                return true;
            }
        }
        return false;
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
        return flags & HOOK_FLAG_ORDER_TRIGGER_MINT != 0;
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
                commit.supplierBindingsRoot,
                commit.fileWritersHash,
                commit.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _recoverPlanPublisher(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert UVPStateMachine.InvalidSignalSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }

    function planRuntimeHash(
        bytes32 hooksHash,
        bytes32 capabilitiesRoot,
        bytes32 supplierBindingsRoot,
        bytes32 fileWritersHash
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(_PLAN_RUNTIME_HASH_DOMAIN, hooksHash, capabilitiesRoot, supplierBindingsRoot, fileWritersHash)
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

    function submitSignal(
        UVPStateMachine.SMState storage _s,
        UVPStateMachine.SignalSubmission calldata submission,
        bytes calldata signature,
        address fileResourceModule
    ) external returns (bytes32 orderId, bool inserted) {
        if (block.timestamp > submission.deadline) {
            revert UVPStateMachine.ExpiredSignalSignature(submission.deadline);
        }
        if (submission.idempotencyKey == bytes32(0)) {
            revert UVPStateMachine.ZeroIdempotencyKey();
        }
        _authenticate(submission, signature);

        if (submission.orderId == bytes32(0)) {
            (orderId, inserted) = _createOrderFromTrigger(_s, submission, fileResourceModule);
        } else {
            (orderId, inserted) = _submitToOrder(_s, submission, fileResourceModule);
        }
    }

    function _authenticate(UVPStateMachine.SignalSubmission calldata submission, bytes calldata signature)
        private
        view
    {
        if (signature.length == 0) {
            if (submission.submitter != msg.sender) {
                revert UVPStateMachine.UnauthorizedDirectSubmitter(submission.submitter, msg.sender);
            }
            return;
        }
        if (submission.submitter == address(0)) {
            revert UVPStateMachine.ZeroSubmitter();
        }
        bytes32 digest = _signalSubmissionDigest(submission);
        if (submission.submitter.code.length != 0) {
            (bool ok, bytes memory result) =
                submission.submitter.staticcall(abi.encodeWithSelector(_EIP1271_MAGIC_VALUE, digest, signature));
            if (!ok || result.length < 32 || abi.decode(result, (bytes4)) != _EIP1271_MAGIC_VALUE) {
                revert UVPStateMachine.InvalidEIP1271Signature(submission.submitter);
            }
            return;
        }
        address recoveredSigner = L_recoverSignalSubmitter(digest, signature);
        if (recoveredSigner != submission.submitter) {
            revert UVPStateMachine.InvalidSignalSubmitterSignature(submission.submitter, recoveredSigner);
        }
    }

    function _createOrderFromTrigger(
        UVPStateMachine.SMState storage _s,
        UVPStateMachine.SignalSubmission calldata submission,
        address fileResourceModule
    ) private returns (bytes32 orderId, bool inserted) {
        (bytes32 triggerHookId, bytes32 triggerStageId) =
            _resolveTriggerHook(_s, submission.planId, submission.sourceId, submission.signalId);
        bytes32 attributedStageId = L_resolveSourceStage(
            _s, submission.planId, submission.sourceId, submission.signalId, submission.attribution
        );
        if (attributedStageId != bytes32(0) && attributedStageId != triggerStageId) {
            revert UVPStateMachine.InvalidFactAttribution(
                submission.planId, submission.sourceId, submission.signalId, attributedStageId
            );
        }
        _requireEffectiveSupplierAccount(_s, submission.planId, bytes32(0), triggerStageId, submission.submitter);
        L_requireSignalAdmission(_s, submission.planId, bytes32(0), submission.sourceId, submission.signalId);

        bytes32 existingOrderId = _s.usedTriggerKeys[submission.submitter][submission.idempotencyKey];
        if (existingOrderId != bytes32(0)) {
            revert UVPStateMachine.DuplicateTriggerKey(
                submission.submitter, submission.idempotencyKey, existingOrderId
            );
        }

        orderId = _newOrderId(_s, submission.planId);
        L_createOrder(_s, submission.planId, orderId);
        emit UVPStateMachine.OrderTriggered(
            orderId,
            submission.planId,
            triggerStageId,
            triggerHookId,
            submission.sourceId,
            submission.signalId,
            submission.submitter
        );
        L_recordSignal(
            _s,
            submission.planId,
            orderId,
            submission.sourceId,
            submission.signalId,
            submission.payloadHash,
            submission.idempotencyKey,
            submission.submitter,
            true,
            triggerStageId
        );
        _requireTriggerHookReady(_s, submission.planId, orderId, triggerHookId);
        _s.usedTriggerKeys[submission.submitter][submission.idempotencyKey] = orderId;
        _applyFiles(
            submission,
            orderId,
            submission.targetStageId == bytes32(0) ? triggerStageId : submission.targetStageId,
            fileResourceModule
        );
        inserted = true;
    }

    function _submitToOrder(
        UVPStateMachine.SMState storage _s,
        UVPStateMachine.SignalSubmission calldata submission,
        address fileResourceModule
    ) private returns (bytes32 orderId, bool inserted) {
        orderId = submission.orderId;
        if (!_s.orders[submission.planId][orderId].exists) {
            revert UVPStateMachine.UnknownOrder();
        }
        if (submission.signalId == bytes32(0)) {
            if (submission.files.length == 0) {
                revert StageFilesEmpty();
            }
            if (submission.targetStageId == bytes32(0)) {
                revert UVPStateMachine.ZeroFileTargetStageId();
            }
            _applyFiles(submission, orderId, submission.targetStageId, fileResourceModule);
            return (orderId, false);
        }
        bytes32 sourceStageId;
        (sourceStageId, inserted) = _submitBusinessSignal(_s, submission);
        if (inserted) {
            _applyFiles(
                submission,
                orderId,
                submission.targetStageId == bytes32(0) ? sourceStageId : submission.targetStageId,
                fileResourceModule
            );
        }
    }

    function _submitBusinessSignal(
        UVPStateMachine.SMState storage _s,
        UVPStateMachine.SignalSubmission calldata submission
    ) private returns (bytes32 sourceStageId, bool inserted) {
        if (submission.sourceId == bytes32(0)) {
            revert UVPStateMachine.ZeroSourceId();
        }
        sourceStageId = L_resolveSourceStage(
            _s, submission.planId, submission.sourceId, submission.signalId, submission.attribution
        );
        if (sourceStageId == bytes32(0)) {
            revert UVPStateMachine.SignalStageUnknown(
                submission.planId, submission.sourceId, submission.signalId
            );
        }
        if (!_s.orders[submission.planId][submission.orderId].materializedStages[sourceStageId]) {
            revert UVPStateMachine.UnknownHook();
        }
        _requireEffectiveSupplierAccount(
            _s, submission.planId, submission.orderId, sourceStageId, submission.submitter
        );
        if (L_hasSignal(_s, submission.planId, submission.orderId, submission.sourceId, submission.signalId)) {
            return (sourceStageId, false);
        }
        L_requireSignalAdmission(
            _s, submission.planId, submission.orderId, submission.sourceId, submission.signalId
        );
        L_recordSignal(
            _s,
            submission.planId,
            submission.orderId,
            submission.sourceId,
            submission.signalId,
            submission.payloadHash,
            submission.idempotencyKey,
            submission.submitter,
            false,
            sourceStageId
        );
        inserted = true;
    }

    function _resolveTriggerHook(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 sourceId,
        bytes32 signalId
    ) private view returns (bytes32 hookId, bytes32 stageId) {
        UVPStateMachine.Plan storage plan = _s.plans[planId];
        if (!plan.finalized) {
            revert UVPStateMachine.PlanNotFinalized();
        }
        bytes32[] storage hookIds = plan.dependencyIndex[L_signalKey(sourceId, signalId)];
        for (uint256 i = 0; i < hookIds.length; i++) {
            if (hookIds[i] == hookId) {
                continue;
            }
            UVPStateMachine.StoredHook storage hook = plan.hooks[hookIds[i]];
            if (!L_isOrderTrigger(hook.flags)) {
                continue;
            }
            if (hookId != bytes32(0)) {
                revert UVPStateMachine.AmbiguousTriggerSignal(sourceId, signalId);
            }
            hookId = hookIds[i];
            stageId = hook.stageId;
        }
        if (hookId == bytes32(0)) {
            revert UVPStateMachine.NotTriggerSignal(sourceId, signalId);
        }
    }

    function _newOrderId(UVPStateMachine.SMState storage _s, bytes32 planId) private returns (bytes32 orderId) {
        for (uint256 i = 0; i < 16; i++) {
            bytes32 candidate = keccak256(abi.encode(block.prevrandao, address(this), _s.orderNonce));
            _s.orderNonce += 1;
            if (candidate != bytes32(0) && !_s.orders[planId][candidate].exists) {
                return candidate;
            }
        }
        revert UVPStateMachine.OrderIdCollision(planId);
    }

    function _requireEffectiveSupplierAccount(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId,
        address submitter
    ) private view {
        bytes32 supplierId = L_effectiveStageSupplier(_s, planId, orderId, stageId);
        if (supplierId == bytes32(0)) {
            revert UVPStateMachine.StageSupplierNotAssigned(orderId, stageId);
        }
        address account = _activeSupplierAccount(_s, supplierId);
        if (account == address(0)) {
            revert UVPStateMachine.SupplierNotActive(supplierId);
        }
        if (account != submitter) {
            revert UVPStateMachine.UnauthorizedStageSupplierAccount(orderId, stageId, submitter, account);
        }
    }

    function _activeSupplierAccount(UVPStateMachine.SMState storage _s, bytes32 supplierId)
        private
        view
        returns (address)
    {
        address registry = _s.identityRegistry;
        if (registry == address(0)) {
            revert UVPStateMachine.IdentityRegistryNotConfigured();
        }
        IUVPIdentityRegistry registryContract = IUVPIdentityRegistry(registry);
        if (!registryContract.isActiveSupplier(supplierId)) {
            return address(0);
        }
        return registryContract.accountOf(supplierId);
    }

    function _requireTriggerHookReady(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 triggerHookId
    ) private view {
        UVPStateMachine.HookRuntime storage runtime = _s.orders[planId][orderId].hookRuntimes[triggerHookId];
        if (!runtime.exists || runtime.status != UVPStateMachine.HookStatus.Ready || !runtime.readyEmitted) {
            revert UVPStateMachine.InvalidTriggerHook(triggerHookId);
        }
    }

    function _applyFiles(
        UVPStateMachine.SignalSubmission calldata submission,
        bytes32 orderId,
        bytes32 targetStageId,
        address fileResourceModule
    ) private {
        if (submission.files.length == 0) {
            return;
        }
        IUVPFileResourceModule(fileResourceModule).applyStageFiles(
            submission.planId, orderId, targetStageId, submission.files, submission.submitter
        );
    }

    function _signalSubmissionDigest(UVPStateMachine.SignalSubmission calldata submission)
        private
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                _SIGNAL_SUBMISSION_TYPEHASH,
                submission.planId,
                submission.orderId,
                submission.sourceId,
                submission.signalId,
                submission.payloadHash,
                submission.idempotencyKey,
                submission.targetStageId,
                keccak256(abi.encode(submission.files)),
                _attributionHash(submission.attribution),
                submission.submitter,
                submission.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _attributionHash(UVPStateMachine.FactAttribution calldata attribution) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _FACT_ATTRIBUTION_TYPEHASH,
                attribution.sourceId,
                attribution.signalId,
                attribution.stageId,
                keccak256(abi.encode(attribution.capabilityProof))
            )
        );
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
        return flags & HOOK_FLAG_ORDER_TRIGGER_MINT != 0;
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

    function L_effectiveStageSupplier(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId
    ) private view returns (bytes32) {
        if (stageId == bytes32(0)) {
            return bytes32(0);
        }
        bytes32 assignedSupplierId = _s.stageSupplierAssignments[planId][orderId][stageId].supplierId;
        if (assignedSupplierId != bytes32(0)) {
            return assignedSupplierId;
        }
        return _s.plans[planId].stageDefaultSuppliers[stageId];
    }

    function L_createOrder(UVPStateMachine.SMState storage _s, bytes32 planId, bytes32 orderId) private {
        UVPStateMachine.Plan storage plan = _s.plans[planId];
        UVPStateMachine.Order storage order = _s.orders[planId][orderId];
        order.relayer = msg.sender;
        order.exists = true;
        order.admissionsDeclared = plan.admissionsDeclared;

        for (uint256 i = 0; i < plan.hookIds.length; i++) {
            UVPStateMachine.StoredHook storage hook = plan.hooks[plan.hookIds[i]];
            if (L_isOrderTrigger(hook.flags)) {
                L_initializeHookRuntime(order.hookRuntimes[plan.hookIds[i]]);
            }
        }

        emit UVPStateMachine.OrderRegistered(orderId, planId);
        emit UVPStateMachine.OrderRelayerRecorded(planId, orderId, msg.sender);
    }

    function L_requireSignalAdmission(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId
    ) private view {
        if (!_s.plans[planId].admissionsDeclared) {
            return;
        }
        UVPStateMachine.StoredAdmission storage admission = _s.plans[planId].admissions[L_signalKey(sourceId, signalId)];
        if (!admission.exists) {
            return;
        }
        UVPStateMachine.EvalValue memory result =
            UVPHookEvaluator.evaluateStorage(_s.signals[planId][orderId], admission.instructions);
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
            planId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, msg.sender, factStageId
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
        L_initializeHookRuntime(runtime);
        if (
            runtime.status == UVPStateMachine.HookStatus.Cancelled || runtime.status == UVPStateMachine.HookStatus.Ready
        ) {
            return;
        }

        UVPStateMachine.HookStatus previousStatus = runtime.status;
        uint64 previousDueAt = runtime.dueAt;
        UVPStateMachine.EvalValue memory result =
            UVPHookEvaluator.evaluateStorage(_s.signals[planId][orderId], hook.instructions);
        UVPStateMachine.HookStatus nextStatus = UVPStateMachine.HookStatus.Init;
        uint64 nextDueAt;
        if (result.cancel) {
            nextStatus = UVPStateMachine.HookStatus.Cancelled;
        } else if (result.wait) {
            nextStatus = UVPStateMachine.HookStatus.Wait;
            nextDueAt = result.dueAt;
        } else if (result.value) {
            nextStatus = UVPStateMachine.HookStatus.Ready;
            nextDueAt = result.dueAt;
        }

        runtime.status = nextStatus;
        runtime.dueAt = nextDueAt;

        if (previousStatus != nextStatus || previousDueAt != nextDueAt) {
            emit UVPStateMachine.HookStatusChanged(planId, orderId, hookId, previousStatus, nextStatus, nextDueAt);
        }

        if (nextStatus == UVPStateMachine.HookStatus.Ready && !runtime.readyEmitted) {
            if (order.materializedStages[hook.stageId]) {
                runtime.readyEmitted = true;
                emit UVPStateMachine.HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
            } else if (_hookCanMaterializeStage(hook.flags)) {
                L_materializeStage(_s, planId, orderId, hook.stageId, hookId, triggerSourceId, triggerSignalId);
            }
        }
    }

    function L_initializeHookRuntime(UVPStateMachine.HookRuntime storage runtime) private {
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

        emit UVPStateMachine.StageMaterialized(
            planId, orderId, stageId, triggerHookId, triggerSourceId, triggerSignalId
        );

        bytes32[] storage stageHooks = _s.plans[planId].stageHookIds[stageId];
        for (uint256 i = 0; i < stageHooks.length; i++) {
            L_settleStageHook(_s, planId, orderId, stageHooks[i]);
        }
    }

    function L_settleStageHook(
        UVPStateMachine.SMState storage _s,
        bytes32 planId,
        bytes32 orderId,
        bytes32 hookId
    ) private {
        UVPStateMachine.HookRuntime storage runtime = _s.orders[planId][orderId].hookRuntimes[hookId];
        L_initializeHookRuntime(runtime);
        if (runtime.status != UVPStateMachine.HookStatus.Ready) {
            return;
        }
        if (runtime.readyEmitted) {
            return;
        }
        runtime.readyEmitted = true;
        UVPStateMachine.StoredHook storage hook = _s.plans[planId].hooks[hookId];
        emit UVPStateMachine.HookReady(planId, orderId, hookId, hook.stageId, hook.hookName);
    }

    function L_recoverSignalSubmitter(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert UVPStateMachine.InvalidSignalSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }
}
