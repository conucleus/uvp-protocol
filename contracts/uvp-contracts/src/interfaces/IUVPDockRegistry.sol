// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./IUVPStateMachineCore.sol";

interface IUVPDockRegistry {
    struct DockAtom {
        bytes32 stageId;
        bytes32 signalId;
        uint8 relation;
    }

    struct DockOutput {
        bytes32 signalId;
        uint8 relation;
        DockAtom[] atoms;
        IUVPStateMachineCore.WindowInstruction[] window;
    }

    struct DockAtomInput {
        bytes32 stageId;
        bytes32 signalId;
        uint8 relation;
        bytes32[] capabilityProof;
    }

    struct DockOutputInput {
        bytes32 signalId;
        uint8 relation;
        DockAtomInput[] atoms;
        IUVPStateMachineCore.WindowInstruction[] window;
        bytes32[] capabilityProof;
    }

    event DockRegistered(
        bytes32 indexed dkid,
        bytes32 indexed fromPlanId,
        bytes32 indexed toPlanId,
        bytes32 fromSourceId,
        bytes32 toStageId,
        bytes32 toSourceId,
        bytes32 docHash,
        address publisher,
        DockOutput[] outputs
    );

    function registerDock(
        bytes32 fromPlanId,
        bytes32 fromSourceId,
        bytes32 toPlanId,
        bytes32 toStageId,
        bytes32 toSourceId,
        bytes32 docHash,
        DockOutputInput[] calldata outputs
    ) external returns (bytes32 dkid);

    function dockExists(bytes32 dkid) external view returns (bool);

    function dockOutputCount(bytes32 dkid) external view returns (uint256);

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
        );

    function getDockOutput(bytes32 dkid, uint256 outputIndex)
        external
        view
        returns (
            bytes32 signalId,
            uint8 relation,
            DockAtom[] memory atoms,
            IUVPStateMachineCore.WindowInstruction[] memory window
        );
}
