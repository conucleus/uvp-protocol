// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "uvp-contracts/UVPStateMachine.sol";
import {AdmissionVerdict, _MAX_HOOK_DELAY_SECONDS} from "uvp-contracts/UVPStateMachineConstants.sol";
import {IUVPIdentityRegistry} from "uvp-contracts/interfaces/IUVPIdentityRegistry.sol";
import {IUVPPlanMetadataModule} from "uvp-contracts/interfaces/IUVPPlanMetadataModule.sol";
import {StageFile} from "uvp-contracts/interfaces/IUVPFileResourceModule.sol";
import {ECDSA} from "uvp-contracts/libraries/ECDSA.sol";
import {UVPSignatures} from "uvp-contracts/libraries/UVPSignatures.sol";
import {IUVPDockController} from "./interfaces/IUVPDockController.sol";
import {IUVPStateMachineForDock, UVPDockEvaluator} from "./libraries/UVPDockEvaluator.sol";

// Standalone Dock controller deployed outside the frozen UVPStateMachine core.
// Registers itself as a supplier in UVPIdentityRegistry, validates and stores
// kind: Dock templates, manages unidirectional DockLink bindings, and reconciles
// source-order windows into target-order signals through UVPStateMachine.submitSignal.
contract UVPDockController is IUVPDockController {
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
    error DockConsentAccountMissing(bytes32 planId, bytes32 orderId, bytes32 consentStageId);
    error DockDocHashZero();
    error DockFromPlanUnknown(bytes32 planId);
    error DockLinkUnknown(bytes32 linkId);
    error DockOrderUnknown(bytes32 planId, bytes32 orderId);
    error DockOutputCapabilityNotFound(bytes32 planId, bytes32 signalId);
    error DockOutputDuplicate(bytes32 signalId);
    error DockOutputIndexOutOfBounds(bytes32 linkId, uint256 outputIndex, uint256 outputCount);
    error DockOutputsEmpty();
    error DockProofCountMismatch(uint256 expectedCount, uint256 actualCount);
    error DockRelationInvalid(uint8 relation);
    error DockSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error DockSelfLoop(bytes32 planId, bytes32 orderId);
    error DockSignalAtomMissing(bytes32 signalId);
    error DockStageAlreadyLinked(bytes32 planId, bytes32 orderId, bytes32 stageId, bytes32 existingLinkId);
    error DockStageNotAssignedToController(bytes32 planId, bytes32 orderId, bytes32 stageId, address actualAccount);
    error DockToPlanUnknown(bytes32 planId);
    error DockTooManyAtoms(uint256 count);
    error DockTooManyInstructions(uint256 count);
    error DockTooManyOutputs(uint256 count);
    error DockUnknown(bytes32 dkid);
    error DockWindowDelayInvalid(uint64 delaySeconds);
    error DockWindowEmpty(uint256 outputIndex);
    error DockWindowInvalid(uint256 outputIndex);
    error DockWindowSourceMismatch(uint256 outputIndex, bytes32 sourceId);
    error DockZeroInput();
    error ExpiredBindLinkSignature(uint256 deadline);
    error InvalidBindLinkEIP1271Signature(address expectedSigner);
    error InvalidBindLinkSignature(address expectedSigner, address recoveredSigner);
    error InvalidBindLinkSignatureLength(uint256 length);
    error UnauthorizedBindLinkCaller(address expectedSigner, address caller);

    uint256 private constant _MAX_DOCK_OUTPUTS = 64;
    uint256 private constant _MAX_DOCK_ATOMS = 64;
    uint256 private constant _MAX_DOCK_INSTRUCTIONS = 256;

    bytes4 private constant _EIP1271_MAGIC_VALUE = 0x1626ba7e;
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPDockController");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 private constant _BIND_LINK_TYPEHASH = keccak256(
        "UVPDockControllerBindLink(bytes32 dkid,bytes32 fromOrderId,bytes32 toOrderId,bytes32 toConsentStageId,uint256 deadline)"
    );

    UVPStateMachine public immutable stateMachine;
    bytes32 public immutable controllerSupplierId;

    mapping(bytes32 dkid => StoredDock dock) private _docks;
    mapping(bytes32 linkId => DockLink link) private _links;
    mapping(bytes32 stageSlotKey => bytes32 linkId) private _stageLinks;

    constructor(address stateMachineAddress) {
        if (stateMachineAddress == address(0)) {
            revert DockZeroInput();
        }
        stateMachine = UVPStateMachine(stateMachineAddress);
        controllerSupplierId = IUVPIdentityRegistry(stateMachine.identityRegistry()).registerSupplier(address(this));
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function bindLinkDigest(BindLinkRequest calldata req) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _BIND_LINK_TYPEHASH,
                        req.dkid,
                        req.fromOrderId,
                        req.toOrderId,
                        req.toConsentStageId,
                        req.deadline
                    )
                )
            )
        );
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
            registered[i] = _validateOutput(
                planMetadata, fromPlanId, fromSourceId, toPlanId, toStageId, toSourceId, outputs[i], i
            );
            for (uint256 j = 0; j < i; j++) {
                if (registered[j].signalId == registered[i].signalId) {
                    revert DockOutputDuplicate(registered[i].signalId);
                }
            }
        }

        _storeDock(dkid, fromPlanId, fromSourceId, toPlanId, toStageId, toSourceId, docHash, registered);
        emit DockRegistered(
            dkid, fromPlanId, toPlanId, fromSourceId, toStageId, toSourceId, docHash, msg.sender, registered
        );
    }

    function bindLink(BindLinkRequest calldata req, bytes calldata toSignature) external returns (bytes32 linkId) {
        return _bindLink(req, toSignature);
    }

    function bindLinkPair(
        BindLinkRequest calldata reqAtoB,
        bytes calldata sigB,
        BindLinkRequest calldata reqBtoA,
        bytes calldata sigA
    ) external returns (bytes32 linkAtoB, bytes32 linkBtoA) {
        linkAtoB = _bindLink(reqAtoB, sigB);
        linkBtoA = _bindLink(reqBtoA, sigA);
    }

    function reconcile(bytes32 linkId, bytes32[][] calldata outputCapabilityProofs)
        external
        returns (uint256 emittedCount)
    {
        DockLink storage link = _links[linkId];
        if (!link.exists) {
            revert DockLinkUnknown(linkId);
        }
        StoredDock storage dock = _docks[link.dkid];
        if (outputCapabilityProofs.length != dock.outputs.length) {
            revert DockProofCountMismatch(dock.outputs.length, outputCapabilityProofs.length);
        }

        for (uint256 i = 0; i < dock.outputs.length; i++) {
            if (_reconcileOutput(linkId, link, dock, i, outputCapabilityProofs[i])) {
                emittedCount += 1;
            }
        }
        emit DockLinkReconciled(linkId, emittedCount);
    }

    function reconcileOutput(bytes32 linkId, uint256 outputIndex, bytes32[] calldata capabilityProof)
        external
        returns (bool emitted)
    {
        DockLink storage link = _links[linkId];
        if (!link.exists) {
            revert DockLinkUnknown(linkId);
        }
        StoredDock storage dock = _docks[link.dkid];
        if (outputIndex >= dock.outputs.length) {
            revert DockOutputIndexOutOfBounds(linkId, outputIndex, dock.outputs.length);
        }
        return _reconcileOutput(linkId, link, dock, outputIndex, capabilityProof);
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
        returns (bytes32 signalId, uint8 relation, DockAtom[] memory atoms, WindowInstruction[] memory window)
    {
        StoredDock storage dock = _docks[dkid];
        if (!dock.exists || outputIndex >= dock.outputs.length) {
            return (bytes32(0), 0, new DockAtom[](0), new WindowInstruction[](0));
        }
        DockOutput storage output = dock.outputs[outputIndex];
        atoms = new DockAtom[](output.atoms.length);
        for (uint256 i = 0; i < output.atoms.length; i++) {
            atoms[i] = output.atoms[i];
        }
        window = new WindowInstruction[](output.window.length);
        for (uint256 i = 0; i < output.window.length; i++) {
            window[i] = output.window[i];
        }
        return (output.signalId, output.relation, atoms, window);
    }

    function getLink(bytes32 linkId) external view returns (DockLink memory) {
        return _links[linkId];
    }

    function getStageLink(bytes32 toPlanId, bytes32 toOrderId, bytes32 toStageId)
        external
        view
        returns (bytes32 linkId)
    {
        return _stageLinks[_stageSlotKey(toPlanId, toOrderId, toStageId)];
    }

    function dockOutputWindow(bytes32 linkId, uint256 outputIndex)
        external
        view
        returns (bool active, bool srcSatisfied, uint64 srcDueAt, bool dstAdmissionReady, bool emitted)
    {
        DockLink storage link = _links[linkId];
        if (!link.exists) {
            return (false, false, 0, false, false);
        }
        StoredDock storage dock = _docks[link.dkid];
        if (outputIndex >= dock.outputs.length) {
            return (false, false, 0, false, false);
        }

        DockOutput storage output = dock.outputs[outputIndex];
        active = true;
        emitted = stateMachine.hasSignal(link.toPlanId, link.toOrderId, dock.toSourceId, output.signalId);

        UVPStateMachine.EvalValue memory val = UVPDockEvaluator.evaluateStorage(
            IUVPStateMachineForDock(address(stateMachine)), link.fromPlanId, link.fromOrderId, output.window
        );
        srcSatisfied = val.value && !val.wait && !val.cancel;
        srcDueAt = val.wait ? val.dueAt : 0;

        (AdmissionVerdict admission,) =
            stateMachine.signalAdmissionVerdict(link.toPlanId, link.toOrderId, dock.toSourceId, output.signalId);
        dstAdmissionReady = admission == AdmissionVerdict.Ready;
    }

    function _bindLink(BindLinkRequest calldata req, bytes calldata toSignature) private returns (bytes32 linkId) {
        if (block.timestamp > req.deadline) {
            revert ExpiredBindLinkSignature(req.deadline);
        }
        if (req.fromOrderId == bytes32(0) || req.toOrderId == bytes32(0) || req.toConsentStageId == bytes32(0)) {
            revert DockZeroInput();
        }
        StoredDock storage dock = _docks[req.dkid];
        if (!dock.exists) {
            revert DockUnknown(req.dkid);
        }
        if (dock.fromPlanId == dock.toPlanId && req.fromOrderId == req.toOrderId) {
            revert DockSelfLoop(dock.fromPlanId, req.fromOrderId);
        }
        if (!stateMachine.orderExists(dock.fromPlanId, req.fromOrderId)) {
            revert DockOrderUnknown(dock.fromPlanId, req.fromOrderId);
        }
        if (!stateMachine.orderExists(dock.toPlanId, req.toOrderId)) {
            revert DockOrderUnknown(dock.toPlanId, req.toOrderId);
        }

        bytes32 stageSlotKey = _stageSlotKey(dock.toPlanId, req.toOrderId, dock.toStageId);
        bytes32 existingLinkId = _stageLinks[stageSlotKey];
        if (existingLinkId != bytes32(0)) {
            revert DockStageAlreadyLinked(dock.toPlanId, req.toOrderId, dock.toStageId, existingLinkId);
        }

        address assignedAccount = stateMachine.effectiveStageAccount(dock.toPlanId, req.toOrderId, dock.toStageId);
        if (assignedAccount != address(this)) {
            revert DockStageNotAssignedToController(dock.toPlanId, req.toOrderId, dock.toStageId, assignedAccount);
        }

        if (
            !IUVPPlanMetadataModule(stateMachine.planMetadataModule()).verifyStageSelectorBinding(
                dock.toPlanId, req.toConsentStageId, dock.toStageId, req.selectorProof
            )
        ) {
            revert DockSelectorBindingNotFound(dock.toPlanId, req.toConsentStageId, dock.toStageId);
        }

        address expectedSigner = stateMachine.effectiveStageAccount(dock.toPlanId, req.toOrderId, req.toConsentStageId);
        if (expectedSigner == address(0)) {
            revert DockConsentAccountMissing(dock.toPlanId, req.toOrderId, req.toConsentStageId);
        }
        _authenticateConsent(req, expectedSigner, toSignature);

        linkId = keccak256(
            abi.encode(
                "uvp.dock.link.v1",
                req.dkid,
                dock.fromPlanId,
                req.fromOrderId,
                dock.toPlanId,
                req.toOrderId,
                dock.toStageId
            )
        );
        _links[linkId] = DockLink({
            dkid: req.dkid,
            fromPlanId: dock.fromPlanId,
            fromOrderId: req.fromOrderId,
            toPlanId: dock.toPlanId,
            toOrderId: req.toOrderId,
            toStageId: dock.toStageId,
            toConsent: expectedSigner,
            boundAt: uint64(block.timestamp),
            exists: true
        });
        _stageLinks[stageSlotKey] = linkId;

        emit DockLinkBound(
            linkId,
            req.dkid,
            req.fromOrderId,
            dock.fromPlanId,
            dock.toPlanId,
            req.toOrderId,
            dock.toStageId,
            req.toConsentStageId,
            expectedSigner
        );
    }

    function _authenticateConsent(BindLinkRequest calldata req, address expectedSigner, bytes calldata toSignature)
        private
        view
    {
        if (toSignature.length == 0) {
            if (msg.sender != expectedSigner) {
                revert UnauthorizedBindLinkCaller(expectedSigner, msg.sender);
            }
            return;
        }

        bytes32 digest = bindLinkDigest(req);
        if (expectedSigner.code.length != 0) {
            (bool ok, bytes memory result) =
                expectedSigner.staticcall(abi.encodeWithSelector(_EIP1271_MAGIC_VALUE, digest, toSignature));
            if (!ok || result.length < 32 || abi.decode(result, (bytes4)) != _EIP1271_MAGIC_VALUE) {
                revert InvalidBindLinkEIP1271Signature(expectedSigner);
            }
            return;
        }

        if (toSignature.length != 65) {
            revert InvalidBindLinkSignatureLength(toSignature.length);
        }
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(toSignature.offset)
            s := calldataload(add(toSignature.offset, 0x20))
            v := byte(0, calldataload(add(toSignature.offset, 0x40)))
        }
        address recovered = ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
        if (recovered != expectedSigner) {
            revert InvalidBindLinkSignature(expectedSigner, recovered);
        }
    }

    function _reconcileOutput(
        bytes32 linkId,
        DockLink storage link,
        StoredDock storage dock,
        uint256 outputIndex,
        bytes32[] calldata capabilityProof
    ) private returns (bool) {
        DockOutput storage output = dock.outputs[outputIndex];
        if (stateMachine.hasSignal(link.toPlanId, link.toOrderId, dock.toSourceId, output.signalId)) {
            return false;
        }

        UVPStateMachine.EvalValue memory val = UVPDockEvaluator.evaluateStorage(
            IUVPStateMachineForDock(address(stateMachine)), link.fromPlanId, link.fromOrderId, output.window
        );
        if (!val.value || val.wait || val.cancel) {
            return false;
        }

        (AdmissionVerdict admission, uint64 dueAt) =
            stateMachine.signalAdmissionVerdict(link.toPlanId, link.toOrderId, dock.toSourceId, output.signalId);
        if (admission != AdmissionVerdict.Ready) {
            emit DockOutputDeferred(linkId, outputIndex, output.signalId, uint8(admission), dueAt);
            return false;
        }

        bytes32 idempotencyKey = keccak256(abi.encode("uvp.dock.output.v1", linkId, outputIndex));
        bytes32 payloadHash =
            keccak256(abi.encode("uvp.dock.provenance.v1", linkId, link.dkid, link.fromPlanId, link.fromOrderId));

        UVPStateMachine.SignalSubmission memory submission = UVPStateMachine.SignalSubmission({
            planId: link.toPlanId,
            orderId: link.toOrderId,
            sourceId: dock.toSourceId,
            signalId: output.signalId,
            payloadHash: payloadHash,
            idempotencyKey: idempotencyKey,
            attribution: UVPStateMachine.FactAttribution({
                sourceId: dock.toSourceId,
                signalId: output.signalId,
                stageId: dock.toStageId,
                capabilityProof: capabilityProof
            }),
            targetStageId: bytes32(0),
            files: new StageFile[](0),
            submitter: address(this),
            deadline: block.timestamp
        });

        (, bool inserted) = stateMachine.submitSignal(submission, "");
        if (!inserted) {
            return false;
        }

        emit DockOutputSubmitted(
            linkId,
            outputIndex,
            link.toOrderId,
            link.toPlanId,
            dock.toSourceId,
            output.signalId,
            payloadHash,
            idempotencyKey
        );
        return true;
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
        if (
            !planMetadata.verifySignalCapability(
                toPlanId, toStageId, toSourceId, output.signalId, output.relation, output.capabilityProof
            )
        ) {
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
            if (
                !planMetadata.verifySignalCapability(
                    fromPlanId, atom.stageId, fromSourceId, atom.signalId, atom.relation, atom.capabilityProof
                )
            ) {
                revert DockAtomCapabilityNotFound(fromPlanId, atom.stageId, atom.signalId);
            }
            atoms[i] = DockAtom({stageId: atom.stageId, signalId: atom.signalId, relation: atom.relation});
        }

        _validateWindow(output.window, fromSourceId, atoms, outputIndex);

        registered.signalId = output.signalId;
        registered.relation = output.relation;
        registered.atoms = atoms;
        registered.window = new WindowInstruction[](output.window.length);
        for (uint256 i = 0; i < output.window.length; i++) {
            registered.window[i] = output.window[i];
        }
    }

    function _validateWindow(
        WindowInstruction[] calldata window,
        bytes32 fromSourceId,
        DockAtom[] memory atoms,
        uint256 outputIndex
    ) private pure {
        bool[] memory seen = new bool[](atoms.length);
        uint256 stackDepth;
        for (uint256 i = 0; i < window.length; i++) {
            WindowInstruction calldata instruction = window[i];
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
                if (
                    stackDepth == 0 || instruction.delaySeconds == 0
                        || instruction.delaySeconds > _MAX_HOOK_DELAY_SECONDS
                ) {
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

    function _stageSlotKey(bytes32 toPlanId, bytes32 toOrderId, bytes32 toStageId) private pure returns (bytes32) {
        return keccak256(abi.encode(toPlanId, toOrderId, toStageId));
    }
}
