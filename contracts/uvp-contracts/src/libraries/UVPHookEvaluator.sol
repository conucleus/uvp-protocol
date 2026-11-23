// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../UVPStateMachine.sol";
import {AdmissionVerdict} from "../UVPStateMachineConstants.sol";

library UVPHookEvaluator {
    function evaluate(
        mapping(bytes32 => UVPStateMachine.SignalRecord) storage signals,
        UVPStateMachine.Instruction[] memory instructions
    ) internal view returns (UVPStateMachine.EvalValue memory) {
        UVPStateMachine.EvalValue[] memory stack = new UVPStateMachine.EvalValue[](instructions.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < instructions.length; i++) {
            UVPStateMachine.Instruction memory instruction = instructions[i];
            if (instruction.op == uint8(UVPStateMachine.InstructionOp.Signal)) {
                stack[stackDepth++] = _signalValue(signals, instruction.sourceId, instruction.signalId);
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.Not)) {
                stack[stackDepth - 1] = _notValue(stack[stackDepth - 1]);
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.Delay)) {
                stack[stackDepth - 1] = _delayValue(stack[stackDepth - 1], instruction.delaySeconds);
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.And)) {
                UVPStateMachine.EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _andValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else if (instruction.op == uint8(UVPStateMachine.InstructionOp.Or)) {
                UVPStateMachine.EvalValue memory value = stack[stackDepth - instruction.arity];
                for (uint256 j = stackDepth - instruction.arity + 1; j < stackDepth; j++) {
                    value = _orValue(value, stack[j]);
                }
                stackDepth = stackDepth - instruction.arity;
                stack[stackDepth++] = value;
            } else {
                revert UVPStateMachine.InvalidInstruction();
            }
        }
        return stack[0];
    }

    function evaluateStorage(
        mapping(bytes32 => UVPStateMachine.SignalRecord) storage signals,
        UVPStateMachine.Instruction[] storage instructions
    ) internal view returns (UVPStateMachine.EvalValue memory) {
        UVPStateMachine.Instruction[] memory loaded = new UVPStateMachine.Instruction[](instructions.length);
        for (uint256 i = 0; i < instructions.length; i++) {
            loaded[i] = instructions[i];
        }
        return evaluate(signals, loaded);
    }

    function verdict(UVPStateMachine.EvalValue memory value) internal pure returns (AdmissionVerdict) {
        if (value.value && !value.wait && !value.cancel) {
            return AdmissionVerdict.Ready;
        }
        if (value.cancel) {
            return AdmissionVerdict.Impossible;
        }
        return AdmissionVerdict.Wait;
    }

    function _signalValue(
        mapping(bytes32 => UVPStateMachine.SignalRecord) storage signals,
        bytes32 sourceId,
        bytes32 signalId
    ) private view returns (UVPStateMachine.EvalValue memory) {
        UVPStateMachine.SignalRecord storage signal = signals[keccak256(abi.encode(sourceId, signalId))];
        if (!signal.exists) {
            return UVPStateMachine.EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
        }
        return UVPStateMachine.EvalValue({value: true, wait: false, cancel: false, dueAt: 0, anchorAt: signal.submittedAt});
    }

    function _notValue(UVPStateMachine.EvalValue memory value)
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

    function _delayValue(UVPStateMachine.EvalValue memory value, uint64 delaySeconds)
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

    function _andValue(UVPStateMachine.EvalValue memory left, UVPStateMachine.EvalValue memory right)
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
                dueAt: _minDue(left.dueAt, right.dueAt),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if ((left.wait && (right.value || right.wait)) || (right.wait && (left.value || left.wait))) {
            return UVPStateMachine.EvalValue({
                value: false,
                wait: true,
                cancel: false,
                dueAt: _maxDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
                anchorAt: _maxAnchor(left.anchorAt, right.anchorAt)
            });
        }
        return UVPStateMachine.EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _orValue(UVPStateMachine.EvalValue memory left, UVPStateMachine.EvalValue memory right)
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
                dueAt: _minDue(left.wait ? left.dueAt : 0, right.wait ? right.dueAt : 0),
                anchorAt: _minAnchor(left.anchorAt, right.anchorAt)
            });
        }
        if (left.cancel && right.cancel) {
            return UVPStateMachine.EvalValue({value: false, wait: false, cancel: true, dueAt: 0, anchorAt: 0});
        }
        return UVPStateMachine.EvalValue({value: false, wait: false, cancel: false, dueAt: 0, anchorAt: 0});
    }

    function _minDue(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }

    function _maxDue(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function _maxAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        return left > right ? left : right;
    }

    function _minAnchor(uint64 left, uint64 right) private pure returns (uint64) {
        if (left == 0) {
            return right;
        }
        if (right == 0 || left < right) {
            return left;
        }
        return right;
    }
}
