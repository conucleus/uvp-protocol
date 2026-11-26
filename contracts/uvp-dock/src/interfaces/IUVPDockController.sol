// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Public interface for UVPDockController: permissionless Dock template
// registration, target-consented unidirectional DockLink bindings (supporting
// 1:N fan-out and atomic bidirectional pairs), and permissionless reconcile
// against UVPStateMachine via standard getSignal / submitSignal calls.
interface IUVPDockController {
    struct WindowInstruction {
        uint8 op;
        bytes32 sourceId;
        bytes32 signalId;
        uint16 arity;
        uint64 delaySeconds;
    }

    struct DockAtom {
        bytes32 stageId;
        bytes32 signalId;
        uint8 relation;
    }

    struct DockOutput {
        bytes32 signalId;
        uint8 relation;
        DockAtom[] atoms;
        WindowInstruction[] window;
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
        WindowInstruction[] window;
        bytes32[] capabilityProof;
    }

    struct DockLink {
        bytes32 dkid;
        bytes32 fromPlanId;
        bytes32 fromOrderId;
        bytes32 toPlanId;
        bytes32 toOrderId;
        bytes32 toStageId;
        address toConsent;
        uint64 boundAt;
        bool exists;
    }

    struct BindLinkRequest {
        bytes32 dkid;
        bytes32 fromOrderId;
        bytes32 toOrderId;
        bytes32 toConsentStageId;
        bytes32[] selectorProof;
        uint256 deadline;
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

    event DockLinkBound(
        bytes32 indexed linkId,
        bytes32 indexed dkid,
        bytes32 indexed fromOrderId,
        bytes32 fromPlanId,
        bytes32 toPlanId,
        bytes32 toOrderId,
        bytes32 toStageId,
        bytes32 toConsentStageId,
        address toConsent
    );

    event DockOutputDeferred(
        bytes32 indexed linkId,
        uint256 indexed outputIndex,
        bytes32 signalId,
        uint8 admissionVerdict,
        uint64 dueAt
    );

    event DockOutputSubmitted(
        bytes32 indexed linkId,
        uint256 indexed outputIndex,
        bytes32 indexed toOrderId,
        bytes32 toPlanId,
        bytes32 toSourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey
    );

    event DockLinkReconciled(bytes32 indexed linkId, uint256 emittedCount);

    function controllerSupplierId() external view returns (bytes32);

    function registerDock(
        bytes32 fromPlanId,
        bytes32 fromSourceId,
        bytes32 toPlanId,
        bytes32 toStageId,
        bytes32 toSourceId,
        bytes32 docHash,
        DockOutputInput[] calldata outputs
    ) external returns (bytes32 dkid);

    function bindLink(BindLinkRequest calldata req, bytes calldata toSignature) external returns (bytes32 linkId);

    function bindLinkPair(
        BindLinkRequest calldata reqAtoB,
        bytes calldata sigB,
        BindLinkRequest calldata reqBtoA,
        bytes calldata sigA
    ) external returns (bytes32 linkAtoB, bytes32 linkBtoA);

    function reconcile(bytes32 linkId, bytes32[][] calldata outputCapabilityProofs)
        external
        returns (uint256 emittedCount);

    function reconcileOutput(bytes32 linkId, uint256 outputIndex, bytes32[] calldata capabilityProof)
        external
        returns (bool emitted);

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
        returns (bytes32 signalId, uint8 relation, DockAtom[] memory atoms, WindowInstruction[] memory window);

    function getLink(bytes32 linkId) external view returns (DockLink memory);

    function getStageLink(bytes32 toPlanId, bytes32 toOrderId, bytes32 toStageId)
        external
        view
        returns (bytes32 linkId);

    function dockOutputWindow(bytes32 linkId, uint256 outputIndex)
        external
        view
        returns (bool active, bool srcSatisfied, uint64 srcDueAt, bool dstAdmissionReady, bool emitted);
}
