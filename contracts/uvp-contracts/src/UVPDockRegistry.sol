// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPDockRegistry} from "./interfaces/IUVPDockRegistry.sol";
import {_MAX_HOOK_DELAY_SECONDS} from "./UVPStateMachineConstants.sol";

contract UVPDockRegistry is IUVPDockRegistry {
    struct StoredDock {
        bytes32 fromPlanId;
        bytes32 fromSourceId;
        bytes32 toPlanId;
        bytes32 toStageId;
        bytes32 toSourceId;
        bytes32 docHash;
        address publisher;
        bool exists;
        DockOutput[] outputs;
    }

    error DockAlreadyRegistered(bytes32 dkid);
    error DockAtomCapabilityNotFound(bytes32 planId, bytes32 stageId, bytes32 signalId);
    error DockAtomDuplicate(bytes32 stageId, bytes32 signalId);
    error DockAtomKeyZero();
    error DockAtomUnreferenced(bytes32 stageId, bytes32 signalId);
    error DockCapabilityVocabularyMissing(bytes32 planId);
    error DockDocHashZero();
    error DockFromPlanUnknown(bytes32 planId);
    error DockOutputCapabilityNotFound(bytes32 planId, bytes32 signalId);
    error DockOutputDuplicate(bytes32 signalId);
    error DockOutputsEmpty();
    error DockRelationInvalid(uint8 relation);
    error DockSignalAtomMissing(bytes32 signalId);
    error DockToPlanUnknown(bytes32 planId);
    error DockTooManyAtoms(uint256 count);
    error DockTooManyInstructions(uint256 count);
    error DockTooManyOutputs(uint256 count);
    error DockWindowDelayInvalid(uint64 delaySeconds);
    error DockWindowEmpty(uint256 outputIndex);
    error DockWindowInvalid(uint256 outputIndex);
    error DockWindowSourceMismatch(uint256 outputIndex, bytes32 sourceId);
    error DockZeroInput();

    uint256 private constant _MAX_DOCK_OUTPUTS = 64;
    uint256 private constant _MAX_DOCK_ATOMS = 64;
    uint256 private constant _MAX_DOCK_INSTRUCTIONS = 256;

    IUVPStateMachineCore public immutable stateMachine;

    mapping(bytes32 dkid => StoredDock dock) private _docks;

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function registerDock(
        bytes32 fromPlanId,
        bytes32 fromSourceId,
        bytes32 toPlanId,
        bytes32 toStageId,
        bytes32 toSourceId,
        bytes32 docHash,
        DockOutputInput[] calldata outputs
    ) external returns (bytes32 dkid) {
        if (docHash == bytes32(0)) {
            revert DockDocHashZero();
        }
        if (
            fromPlanId == bytes32(0) || fromSourceId == bytes32(0) || toPlanId == bytes32(0)
                || toStageId == bytes32(0) || toSourceId == bytes32(0)
        ) {
            revert DockZeroInput();
        }
        if (outputs.length == 0) {
            revert DockOutputsEmpty();
        }
        if (outputs.length > _MAX_DOCK_OUTPUTS) {
            revert DockTooManyOutputs(outputs.length);
        }
        if (!stateMachine.planExists(fromPlanId)) {
            revert DockFromPlanUnknown(fromPlanId);
        }
        if (!stateMachine.planExists(toPlanId)) {
            revert DockToPlanUnknown(toPlanId);
        }

        IUVPPlanMetadataModule planMetadata = IUVPPlanMetadataModule(stateMachine.planMetadataModule());
        if (!planMetadata.hasCapabilityVocabulary(fromPlanId)) {
            revert DockCapabilityVocabularyMissing(fromPlanId);
        }
        if (!planMetadata.hasCapabilityVocabulary(toPlanId)) {
            revert DockCapabilityVocabularyMissing(toPlanId);
        }

        bytes32 outputsHash = keccak256(abi.encode(outputs));
        dkid = keccak256(abi.encode(docHash, fromPlanId, toPlanId, outputsHash));
        if (_docks[dkid].exists) {
            revert DockAlreadyRegistered(dkid);
        }

        DockOutput[] memory registered = new DockOutput[](outputs.length);
        for (uint256 i = 0; i < outputs.length; i++) {
            registered[i] = _validateOutput(planMetadata, fromPlanId, fromSourceId, toPlanId, toStageId, toSourceId, outputs[i], i);
            for (uint256 j = 0; j < i; j++) {
                if (registered[j].signalId == registered[i].signalId) {
                    revert DockOutputDuplicate(registered[i].signalId);
                }
            }
        }

        _storeDock(dkid, fromPlanId, fromSourceId, toPlanId, toStageId, toSourceId, docHash, registered);
        emit DockRegistered(
            dkid,
            fromPlanId,
            toPlanId,
            fromSourceId,
            toStageId,
            toSourceId,
            docHash,
            msg.sender,
            registered
        );
    }

    function dockExists(bytes32 dkid) external view returns (bool) {
        return _docks[dkid].exists;
    }

    function dockOutputCount(bytes32 dkid) external view returns (uint256) {
        return _docks[dkid].outputs.length;
    }

    function getDock(bytes32 dkid)
        external
        view
        returns (
            bytes32 fromPlanId,
            bytes32 fromSourceId,
            bytes32 toPlanId,
            bytes32 toStageId,
            bytes32 toSourceId,
            bytes32 docHash,
            address publisher,
            bool exists
        )
    {
        StoredDock storage dock = _docks[dkid];
        return (
            dock.fromPlanId,
            dock.fromSourceId,
            dock.toPlanId,
            dock.toStageId,
            dock.toSourceId,
            dock.docHash,
            dock.publisher,
            dock.exists
        );
    }

    function getDockOutput(bytes32 dkid, uint256 outputIndex)
        external
        view
        returns (
            bytes32 signalId,
            uint8 relation,
            DockAtom[] memory atoms,
            IUVPStateMachineCore.WindowInstruction[] memory window
        )
    {
        StoredDock storage dock = _docks[dkid];
        if (!dock.exists || outputIndex >= dock.outputs.length) {
            return (bytes32(0), 0, new DockAtom[](0), new IUVPStateMachineCore.WindowInstruction[](0));
        }
        DockOutput storage output = dock.outputs[outputIndex];
        atoms = new DockAtom[](output.atoms.length);
        for (uint256 i = 0; i < output.atoms.length; i++) {
            atoms[i] = output.atoms[i];
        }
        window = new IUVPStateMachineCore.WindowInstruction[](output.window.length);
        for (uint256 i = 0; i < output.window.length; i++) {
            window[i] = output.window[i];
        }
        return (output.signalId, output.relation, atoms, window);
    }

    function _validateOutput(
        IUVPPlanMetadataModule planMetadata,
        bytes32 fromPlanId,
        bytes32 fromSourceId,
        bytes32 toPlanId,
        bytes32 toStageId,
        bytes32 toSourceId,
        DockOutputInput calldata output,
        uint256 outputIndex
    ) private view returns (DockOutput memory registered) {
        if (output.signalId == bytes32(0)) {
            revert DockZeroInput();
        }
        if (output.relation != 0) {
            revert DockRelationInvalid(output.relation);
        }
        if (!planMetadata.verifySignalCapability(
                toPlanId, toStageId, toSourceId, output.signalId, output.relation, output.capabilityProof
            )) {
            revert DockOutputCapabilityNotFound(toPlanId, output.signalId);
        }
        if (output.window.length == 0) {
            revert DockWindowEmpty(outputIndex);
        }
        if (output.window.length > _MAX_DOCK_INSTRUCTIONS) {
            revert DockTooManyInstructions(output.window.length);
        }
        if (output.atoms.length == 0) {
            revert DockWindowEmpty(outputIndex);
        }
        if (output.atoms.length > _MAX_DOCK_ATOMS) {
            revert DockTooManyAtoms(output.atoms.length);
        }

        DockAtom[] memory atoms = new DockAtom[](output.atoms.length);
        for (uint256 i = 0; i < output.atoms.length; i++) {
            DockAtomInput calldata atom = output.atoms[i];
            if (atom.stageId == bytes32(0) || atom.signalId == bytes32(0)) {
                revert DockAtomKeyZero();
            }
            if (atom.relation != 0) {
                revert DockRelationInvalid(atom.relation);
            }
            for (uint256 j = 0; j < i; j++) {
                if (atoms[j].stageId == atom.stageId && atoms[j].signalId == atom.signalId) {
                    revert DockAtomDuplicate(atom.stageId, atom.signalId);
                }
            }
            if (!planMetadata.verifySignalCapability(
                    fromPlanId, atom.stageId, fromSourceId, atom.signalId, atom.relation, atom.capabilityProof
                )) {
                revert DockAtomCapabilityNotFound(fromPlanId, atom.stageId, atom.signalId);
            }
            atoms[i] = DockAtom({stageId: atom.stageId, signalId: atom.signalId, relation: atom.relation});
        }

        _validateWindow(output.window, fromSourceId, atoms, outputIndex);

        registered.signalId = output.signalId;
        registered.relation = output.relation;
        registered.atoms = atoms;
        registered.window = new IUVPStateMachineCore.WindowInstruction[](output.window.length);
        for (uint256 i = 0; i < output.window.length; i++) {
            registered.window[i] = output.window[i];
        }
    }

    function _validateWindow(
        IUVPStateMachineCore.WindowInstruction[] calldata window,
        bytes32 fromSourceId,
        DockAtom[] memory atoms,
        uint256 outputIndex
    ) private pure {
        bool[] memory seen = new bool[](atoms.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < window.length; i++) {
            IUVPStateMachineCore.WindowInstruction calldata instruction = window[i];
            if (instruction.op == 0) {
                if (instruction.sourceId != fromSourceId) {
                    revert DockWindowSourceMismatch(outputIndex, instruction.sourceId);
                }
                uint256 atomIndex = _atomIndex(atoms, instruction.signalId);
                if (atomIndex == type(uint256).max) {
                    revert DockSignalAtomMissing(instruction.signalId);
                }
                seen[atomIndex] = true;
                stackDepth += 1;
            } else if (instruction.op == 1) {
                if (stackDepth == 0) {
                    revert DockWindowInvalid(outputIndex);
                }
            } else if (instruction.op == 4) {
                if (stackDepth == 0 || instruction.delaySeconds == 0 || instruction.delaySeconds > _MAX_HOOK_DELAY_SECONDS) {
                    revert DockWindowDelayInvalid(instruction.delaySeconds);
                }
            } else if (instruction.op == 2 || instruction.op == 3) {
                uint256 arity = instruction.arity;
                if (arity < 2 || stackDepth < arity) {
                    revert DockWindowInvalid(outputIndex);
                }
                stackDepth = stackDepth - arity + 1;
            } else {
                revert DockWindowInvalid(outputIndex);
            }
        }
        if (stackDepth != 1) {
            revert DockWindowInvalid(outputIndex);
        }
        for (uint256 i = 0; i < atoms.length; i++) {
            if (!seen[i]) {
                revert DockAtomUnreferenced(atoms[i].stageId, atoms[i].signalId);
            }
        }
    }

    function _atomIndex(DockAtom[] memory atoms, bytes32 signalId) private pure returns (uint256) {
        for (uint256 i = 0; i < atoms.length; i++) {
            if (atoms[i].signalId == signalId) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _storeDock(
        bytes32 dkid,
        bytes32 fromPlanId,
        bytes32 fromSourceId,
        bytes32 toPlanId,
        bytes32 toStageId,
        bytes32 toSourceId,
        bytes32 docHash,
        DockOutput[] memory registered
    ) private {
        StoredDock storage dock = _docks[dkid];
        dock.fromPlanId = fromPlanId;
        dock.fromSourceId = fromSourceId;
        dock.toPlanId = toPlanId;
        dock.toStageId = toStageId;
        dock.toSourceId = toSourceId;
        dock.docHash = docHash;
        dock.publisher = msg.sender;
        dock.exists = true;
        for (uint256 i = 0; i < registered.length; i++) {
            DockOutput memory output = registered[i];
            dock.outputs.push();
            DockOutput storage stored = dock.outputs[i];
            stored.signalId = output.signalId;
            stored.relation = output.relation;
            for (uint256 j = 0; j < output.atoms.length; j++) {
                stored.atoms.push(output.atoms[j]);
            }
            for (uint256 j = 0; j < output.window.length; j++) {
                stored.window.push(output.window[j]);
            }
        }
    }
}
