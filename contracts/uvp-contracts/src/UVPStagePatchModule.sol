// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPFileResourceModule} from "./interfaces/IUVPFileResourceModule.sol";
import {IUVPDockRegistry} from "./interfaces/IUVPDockRegistry.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {MerkleCommitment} from "./libraries/MerkleCommitment.sol";

interface IUVPPlanMetadataModuleForStagePatch {
    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool);
}

bytes32 constant _EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");

contract UVPStagePatchModule {
    bytes32 private constant _FILE_WRITE_SIGNAL_ID = keccak256("uvp.file_write.signal.v1");
    bytes32 private constant _DOCK_PAYLOAD_FILE_KEY = keccak256("dock_link");
    bytes32 private constant _DOCK_BINDING_ID_DOMAIN = keccak256("uvp.dock.binding_id.v1");

    struct StageExecutorPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 mode;
        address previousExecutor;
        bytes32 authorizationsHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
    }

    struct StageDockExecutorSelection {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 dockId;
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 authorizationsHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
    }

    struct ActiveStageExecutorPatch {
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
        bytes32 dockId;
        bytes32 dockFromPlanId;
        bool exists;
    }

    struct DockBindingContext {
        bytes32 planId;
        bytes32 orderId;
        bytes32 targetStageId;
        bytes32 fromPlanId;
        bytes32 fromOrderId;
        bytes32 toSourceId;
        bytes32 bindingId;
        address executor;
    }

    error DockBindingFromOrderMismatch(bytes32 expectedOrderId, bytes32 providedOrderId);
    error DockBindingFromOrderUnknown(bytes32 planId, bytes32 orderId);
    error DockBindingNotSelected(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error DockBindingContentHashMismatch(bytes32 expectedHash, bytes32 actualHash);
    error DockBindingPayloadMissing(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error DockExecutorAuthorizationMissing(bytes32 signalId);
    error DockOrderPlanMismatch(bytes32 expectedPlanId, bytes32 providedPlanId);
    error DockOutputProofCountMismatch(uint256 expectedCount, uint256 providedCount);
    error DockPayloadMalformed(uint256 length);
    error DockStageMismatch(bytes32 expectedStageId, bytes32 providedStageId);
    error DockStageNotDockExecutor(bytes32 planId, bytes32 stageId);
    error DockUnknown(bytes32 dkid);
    error ExpiredStageExecutorPatchSignature(uint256 deadline);
    error InvalidStageExecutorPatchMode(bytes32 mode);
    error InvalidStageExecutorPatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageExecutorPatchSignatureLength(uint256 length);
    error StageAlreadyHasSignal(bytes32 orderId, bytes32 targetStageId);
    error StageDockExecutorAlreadySelected(bytes32 planId, bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error StageExecutorPatchPreviousExecutorMismatch(
        bytes32 orderId, bytes32 targetStageId, address expectedExecutor, address previousExecutor
    );
    error StageExecutorPatchForbiddenOnDockStage(bytes32 orderId, bytes32 targetStageId);
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchForbiddenOnBirthStage(bytes32 orderId, bytes32 targetStageId);
    error StagePreviousExecutorAmbiguous(bytes32 orderId, bytes32 targetStageId, uint64 submittedAt);
    error StageExecutorNotCandidate(bytes32 planId, bytes32 orderId, bytes32 targetStageId, address executor);
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error UnauthorizedStageExecutorPatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnknownOrder();
    error UnknownStage(bytes32 planId, bytes32 stageId);
    error ZeroDockId();
    error ZeroPatchHash();
    error ZeroSelector();
    error ZeroSelectorStageId();
    error ZeroStageExecutor();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    bytes32 public constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;
    bytes32 public constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");
    bytes32 public constant EXECUTOR_PATCH_MODE_HANDOFF = bytes32("handoff");
    bytes32 public constant EXECUTOR_CANDIDATE_LEAF_DOMAIN = _EXECUTOR_CANDIDATE_LEAF_DOMAIN;
    bytes32 public constant DOCK_PAYLOAD_FILE_KEY = _DOCK_PAYLOAD_FILE_KEY;
    bytes32 public constant DOCK_BINDING_ID_DOMAIN = _DOCK_BINDING_ID_DOMAIN;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStagePatchModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.4");
    bytes32 private constant _STAGE_EXECUTOR_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 authorizationsHash,bytes32 patchHash,uint256 patchNonce,string metadataURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_DOCK_EXECUTOR_SELECTION_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageDockExecutorSelection(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 dockId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 authorizationsHash,bytes32 patchHash,uint256 patchNonce,string metadataURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC = keccak256(
        "StageExecutorPatchApplied(bytes32,bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,uint256,string)"
    );

    mapping(
        bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch))
    ) private _activeStageExecutorPatches;

    event StageExecutorPatchApplied(
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 indexed targetStageId,
        bytes32 planId,
        address selector,
        address executor,
        bytes32 role,
        bytes32 executorMetadataHash,
        bytes32 mode,
        address previousExecutor,
        bytes32 authorizationsHash,
        bytes32 patchHash,
        uint256 patchNonce,
        string metadataURI
    );
    event StageDockExecutorSelected(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 dockId,
        bytes32 fromPlanId,
        address executor,
        address selector,
        bytes32 patchHash,
        uint256 patchNonce,
        string metadataURI
    );
    event DockBindingPoked(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 dockId,
        bytes32 bindingId,
        bytes32 fromPlanId,
        bytes32 fromOrderId,
        address executor,
        uint256 emittedCount
    );
    event DockOutputSubmitted(
        bytes32 indexed planId,
        bytes32 indexed orderId,
        bytes32 indexed targetStageId,
        bytes32 bindingId,
        uint256 outputIndex,
        bytes32 signalId,
        address executor
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function applyStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) external {
        _applyStageExecutorPatch(
            planId, orderId, patch, msg.sender, address(0), bindingProof, candidateProof, executorAuthorizations
        );
    }

    function applyStageExecutorPatchFor(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        bytes calldata previousExecutorSignature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageExecutorPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        bytes32 digest = stageExecutorPatchDigest(planId, orderId, patch, selector, deadline);
        address recoveredSigner = _recoverStageExecutorPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageExecutorPatchSignature(selector, recoveredSigner);
        }

        address recoveredPreviousExecutor;
        if (previousExecutorSignature.length != 0) {
            recoveredPreviousExecutor = _recoverStageExecutorPatchSigner(digest, previousExecutorSignature);
        }

        _applyStageExecutorPatch(
            planId,
            orderId,
            patch,
            selector,
            recoveredPreviousExecutor,
            bindingProof,
            candidateProof,
            executorAuthorizations
        );
    }

    function selectStageDockExecutor(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) external {
        _selectStageDockExecutor(planId, orderId, selection, msg.sender, bindingProof, executorAuthorizations);
    }

    function selectStageDockExecutorFor(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageExecutorPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        bytes32 digest = stageDockExecutorSelectionDigest(planId, orderId, selection, selector, deadline);
        address recoveredSigner = _recoverStageExecutorPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageExecutorPatchSignature(selector, recoveredSigner);
        }
        _selectStageDockExecutor(planId, orderId, selection, selector, bindingProof, executorAuthorizations);
    }

    function pokeDockBinding(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes calldata payloadContent,
        bytes32 fromOrderId,
        bytes32[][] calldata outputCapabilityProofs
    ) external returns (uint256 emittedCount) {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][targetStageId];
        if (!activePatch.exists || activePatch.dockId == bytes32(0)) {
            revert DockBindingNotSelected(planId, orderId, targetStageId);
        }
        DockBindingContext memory context =
            _dockBindingContext(planId, orderId, targetStageId, payloadContent, fromOrderId, activePatch);
        IUVPDockRegistry registry = _dockRegistry();
        uint256 outputCount = registry.dockOutputCount(activePatch.dockId);
        if (outputCapabilityProofs.length != outputCount) {
            revert DockOutputProofCountMismatch(outputCount, outputCapabilityProofs.length);
        }
        for (uint256 i = 0; i < outputCount; i++) {
            if (_emitDockOutput(activePatch.dockId, context, registry, i, outputCapabilityProofs[i])) {
                emittedCount += 1;
            }
        }
        emit DockBindingPoked(
            planId,
            orderId,
            targetStageId,
            activePatch.dockId,
            context.bindingId,
            context.fromPlanId,
            context.fromOrderId,
            context.executor,
            emittedCount
        );
    }

    function activeStageExecutor(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (address)
    {
        return _activeStageExecutorPatches[planId][orderId][targetStageId].executor;
    }

    function orderStageExecutorPatchNonce(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (uint256)
    {
        return _activeStageExecutorPatches[planId][orderId][targetStageId].patchNonce;
    }

    function getActiveStageExecutorPatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        )
    {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][targetStageId];
        return (
            activePatch.exists,
            activePatch.executor,
            activePatch.role,
            activePatch.executorMetadataHash,
            activePatch.patchHash,
            activePatch.patchNonce,
            activePatch.metadataURI
        );
    }

    function getActiveStageDockSelection(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (bool exists, bytes32 dockId, bytes32 fromPlanId, address executor)
    {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][targetStageId];
        if (!activePatch.exists || activePatch.dockId == bytes32(0)) {
            return (false, bytes32(0), bytes32(0), address(0));
        }
        return (true, activePatch.dockId, activePatch.dockFromPlanId, activePatch.executor);
    }

    function getStageDockBinding(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId
    )
        external
        view
        returns (
            bool selected,
            bool current,
            bytes32 dockId,
            address executor,
            bytes32 fromPlanId,
            bytes32 bindingId
        )
    {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][targetStageId];
        selected = activePatch.exists && activePatch.dockId != bytes32(0);
        if (!selected) {
            return (false, false, bytes32(0), address(0), bytes32(0), bytes32(0));
        }
        dockId = activePatch.dockId;
        executor = activePatch.executor;
        fromPlanId = activePatch.dockFromPlanId;
        (bool payloadExists,,,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY);
        current = payloadExists && fromOrderId != bytes32(0);
        if (!current) {
            return (true, false, dockId, executor, fromPlanId, bytes32(0));
        }
        bindingId = keccak256(
            abi.encode(
                _DOCK_BINDING_ID_DOMAIN,
                dockId,
                planId,
                orderId,
                targetStageId,
                fromPlanId,
                fromOrderId
            )
        );
    }

    function dockOutputWindow(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes32 fromOrderId,
        uint256 outputIndex
    )
        external
        view
        returns (bool current, bool aSatisfied, uint64 aDueInSeconds, bool bSatisfied, bool emitted)
    {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][targetStageId];
        if (!activePatch.exists || activePatch.dockId == bytes32(0)) {
            return (false, false, 0, false, false);
        }
        IUVPDockRegistry registry = _dockRegistry();
        (,, bytes32 toSourceId,,) = _dockFields(activePatch.dockId);
        (bool payloadExists,,,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY);
        current = payloadExists && fromOrderId != bytes32(0);
        uint256 outputCount = registry.dockOutputCount(activePatch.dockId);
        if (outputIndex >= outputCount) {
            return (current, false, 0, false, false);
        }
        (bytes32 signalId,,, IUVPStateMachineCore.WindowInstruction[] memory window) =
            registry.getDockOutput(activePatch.dockId, outputIndex);
        (aSatisfied, aDueInSeconds) = stateMachine.evaluateDockWindow(activePatch.dockFromPlanId, fromOrderId, window);
        bSatisfied = stateMachine.isSignalAdmissionSatisfied(planId, orderId, toSourceId, signalId);
        emitted = stateMachine.hasSignal(planId, orderId, toSourceId, signalId);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function stageExecutorPatchDigest(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                _stageExecutorPatchStructHash(planId, orderId, patch, selector, deadline)
            )
        );
    }

    function stageDockExecutorSelectionDigest(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                _stageDockExecutorSelectionStructHash(planId, orderId, selection, selector, deadline)
            )
        );
    }

    function _applyStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        address previousExecutorSigner,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) private {
        _validateStageExecutorPatch(planId, orderId, patch, selector, bindingProof, candidateProof);

        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][patch.targetStageId];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, patch.targetStageId, activePatch.patchNonce, patch.patchNonce
            );
        }
        _validateStageExecutorPatchMode(planId, orderId, patch, activePatch, previousExecutorSigner);
        address previousExecutor = activePatch.executor;
        if (stateMachine.signalAuthorizationsHash(executorAuthorizations) != patch.authorizationsHash) {
            revert InvalidStageExecutorPatchSignature(selector, address(0));
        }

        activePatch.executor = patch.executor;
        activePatch.role = patch.role;
        activePatch.executorMetadataHash = patch.executorMetadataHash;
        activePatch.patchHash = patch.patchHash;
        activePatch.patchNonce = patch.patchNonce;
        activePatch.metadataURI = patch.metadataURI;
        activePatch.exists = true;

        _emitStageExecutorPatchApplied(planId, orderId, patch, selector);
        stateMachine.activateStageExecutorFromModule(
            planId,
            orderId,
            patch.targetStageId,
            patch.executor,
            patch.role,
            patch.executorMetadataHash,
            patch.patchHash,
            patch.patchNonce,
            patch.metadataURI
        );
        stateMachine.authorizeSignalSubmittersFromModule(planId, orderId, executorAuthorizations);
        if (previousExecutor != address(0) && previousExecutor != patch.executor) {
            IUVPStateMachineCore.SignalAuthorization[] memory revokes =
                new IUVPStateMachineCore.SignalAuthorization[](1);
            revokes[0] = IUVPStateMachineCore.SignalAuthorization({
                sourceId: patch.targetStageId,
                signalId: _FILE_WRITE_SIGNAL_ID,
                submitter: previousExecutor,
                role: bytes32(0),
                metadataHash: bytes32(0)
            });
            stateMachine.revokeSignalSubmittersFromModule(planId, orderId, revokes);
        }
    }

    function _selectStageDockExecutor(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) private {
        _validateStageDockSelection(planId, orderId, selection, selector, bindingProof);

        ActiveStageExecutorPatch storage activePatch =
            _activeStageExecutorPatches[planId][orderId][selection.targetStageId];
        if (activePatch.exists && activePatch.dockId == selection.dockId) {
            if (activePatch.executor == selection.executor) {
                return;
            }
            revert StageDockExecutorAlreadySelected(planId, orderId, selection.targetStageId);
        }
        if (activePatch.dockId != bytes32(0)) {
            revert StageDockExecutorAlreadySelected(planId, orderId, selection.targetStageId);
        }
        if (selection.patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, selection.targetStageId, activePatch.patchNonce, selection.patchNonce
            );
        }
        if (stateMachine.signalAuthorizationsHash(executorAuthorizations) != selection.authorizationsHash) {
            revert InvalidStageExecutorPatchSignature(selector, address(0));
        }

        IUVPDockRegistry registry = _dockRegistry();
        (bytes32 fromPlanId, bytes32 dockToPlanId, bytes32 toSourceId, bytes32 dockToStageId, bool dockExists) =
            _dockFields(selection.dockId);
        if (!dockExists) {
            revert DockUnknown(selection.dockId);
        }
        if (dockToPlanId != planId) {
            revert DockOrderPlanMismatch(planId, dockToPlanId);
        }
        if (dockToStageId != selection.targetStageId) {
            revert DockStageMismatch(selection.targetStageId, dockToStageId);
        }
        _requireDockExecutorAuthorizations(registry, selection.dockId, toSourceId, selection.executor, executorAuthorizations);

        activePatch.executor = selection.executor;
        activePatch.role = selection.role;
        activePatch.executorMetadataHash = selection.executorMetadataHash;
        activePatch.patchHash = selection.patchHash;
        activePatch.patchNonce = selection.patchNonce;
        activePatch.metadataURI = selection.metadataURI;
        activePatch.dockId = selection.dockId;
        activePatch.dockFromPlanId = fromPlanId;
        activePatch.exists = true;

        emit StageDockExecutorSelected(
            planId,
            orderId,
            selection.targetStageId,
            selection.dockId,
            fromPlanId,
            selection.executor,
            selector,
            selection.patchHash,
            selection.patchNonce,
            selection.metadataURI
        );
        stateMachine.activateStageExecutorFromModule(
            planId,
            orderId,
            selection.targetStageId,
            selection.executor,
            selection.role,
            selection.executorMetadataHash,
            selection.patchHash,
            selection.patchNonce,
            selection.metadataURI
        );
        stateMachine.authorizeSignalSubmittersFromModule(planId, orderId, executorAuthorizations);
    }

    function _requireDockExecutorAuthorizations(
        IUVPDockRegistry registry,
        bytes32 dockId,
        bytes32 toSourceId,
        address executor,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) private view {
        uint256 outputCount = registry.dockOutputCount(dockId);
        for (uint256 i = 0; i < outputCount; i++) {
            (bytes32 signalId,,,) = registry.getDockOutput(dockId, i);
            bool covered;
            for (uint256 j = 0; j < executorAuthorizations.length; j++) {
                IUVPStateMachineCore.SignalAuthorization calldata authorization = executorAuthorizations[j];
                if (
                    authorization.sourceId == toSourceId && authorization.signalId == signalId
                        && authorization.submitter == executor
                ) {
                    covered = true;
                    break;
                }
            }
            if (!covered) {
                revert DockExecutorAuthorizationMissing(signalId);
            }
        }
    }

    function _dockBindingContext(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetStageId,
        bytes calldata payloadContent,
        bytes32 fromOrderId,
        ActiveStageExecutorPatch storage activePatch
    ) private view returns (DockBindingContext memory context) {
        if (!stateMachine.orderExists(activePatch.dockFromPlanId, fromOrderId)) {
            revert DockBindingFromOrderUnknown(activePatch.dockFromPlanId, fromOrderId);
        }
        (bool payloadExists, bytes32 contentHash,,) = IUVPFileResourceModule(stateMachine.fileResourceModule())
            .getStageFile(planId, orderId, targetStageId, _DOCK_PAYLOAD_FILE_KEY);
        if (!payloadExists) {
            revert DockBindingPayloadMissing(planId, orderId, targetStageId);
        }
        bytes32 actualContentHash = keccak256(payloadContent);
        if (actualContentHash != contentHash) {
            revert DockBindingContentHashMismatch(contentHash, actualContentHash);
        }
        bytes32 parsedFromOrderId = _parseDockPayload(payloadContent);
        if (parsedFromOrderId != fromOrderId) {
            revert DockBindingFromOrderMismatch(fromOrderId, parsedFromOrderId);
        }
        (,, bytes32 toSourceId,,) = _dockFields(activePatch.dockId);
        context = DockBindingContext({
            planId: planId,
            orderId: orderId,
            targetStageId: targetStageId,
            fromPlanId: activePatch.dockFromPlanId,
            fromOrderId: fromOrderId,
            toSourceId: toSourceId,
            bindingId: keccak256(
                abi.encode(
                    _DOCK_BINDING_ID_DOMAIN,
                    activePatch.dockId,
                    planId,
                    orderId,
                    targetStageId,
                    activePatch.dockFromPlanId,
                    fromOrderId
                )
            ),
            executor: activePatch.executor
        });
    }

    function _emitDockOutput(
        bytes32 dockId,
        DockBindingContext memory context,
        IUVPDockRegistry registry,
        uint256 outputIndex,
        bytes32[] calldata capabilityProof
    ) private returns (bool submitted) {
        (bytes32 signalId,,, IUVPStateMachineCore.WindowInstruction[] memory window) =
            registry.getDockOutput(dockId, outputIndex);
        (bool aSatisfied,) = stateMachine.evaluateDockWindow(context.fromPlanId, context.fromOrderId, window);
        if (!aSatisfied) {
            return false;
        }
        if (stateMachine.hasSignal(context.planId, context.orderId, context.toSourceId, signalId)) {
            return false;
        }
        IUVPStateMachineCore.FactAttribution memory attribution = IUVPStateMachineCore.FactAttribution({
            sourceId: context.toSourceId,
            signalId: signalId,
            stageId: context.targetStageId,
            capabilityProof: capabilityProof
        });
        submitted = stateMachine.submitDockOutputSignalFromModule(
            context.planId,
            context.orderId,
            context.toSourceId,
            signalId,
            context.bindingId,
            keccak256(abi.encode(_DOCK_BINDING_ID_DOMAIN, context.bindingId, signalId)),
            context.executor,
            attribution
        );
        if (submitted) {
            emit DockOutputSubmitted(
                context.planId,
                context.orderId,
                context.targetStageId,
                context.bindingId,
                outputIndex,
                signalId,
                context.executor
            );
        }
    }

    function _parseDockPayload(bytes calldata payload) private pure returns (bytes32 orderId) {
        uint256 length = payload.length;
        if (length != 66) {
            revert DockPayloadMalformed(length);
        }
        if (uint8(payload[0]) != 0x30 || uint8(payload[1]) != 0x78) {
            revert DockPayloadMalformed(length);
        }
        uint256 value;
        for (uint256 i = 2; i < 66; i++) {
            uint8 character = uint8(payload[i]);
            uint8 digit;
            if (character >= 0x30 && character <= 0x39) {
                digit = character - 0x30;
            } else if (character >= 0x61 && character <= 0x66) {
                digit = character - 0x57;
            } else {
                revert DockPayloadMalformed(length);
            }
            value = (value << 4) | digit;
        }
        return bytes32(value);
    }

    function _validateStageDockSelection(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) private view {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (selection.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (selection.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (selection.dockId == bytes32(0)) {
            revert ZeroDockId();
        }
        if (selection.executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (selection.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.stageHasDockExecutorHook(planId, selection.targetStageId)) {
            revert DockStageNotDockExecutor(planId, selection.targetStageId);
        }
        (bytes32 dockFromPlanId, bytes32 dockToPlanId,, bytes32 dockToStageId, bool dockExists) =
            _dockFields(selection.dockId);
        if (!dockExists) {
            revert DockUnknown(selection.dockId);
        }
        dockFromPlanId;
        if (dockToPlanId != planId) {
            revert DockOrderPlanMismatch(planId, dockToPlanId);
        }
        if (dockToStageId != selection.targetStageId) {
            revert DockStageMismatch(selection.targetStageId, dockToStageId);
        }
        if (
            bindingProof.selectorStageId != selection.selectorStageId
                || !_planMetadata().verifyStageSelectorBinding(
                    planId, selection.selectorStageId, selection.targetStageId, bindingProof.proof
                )
        ) {
            revert StageSelectorBindingNotFound(planId, selection.selectorStageId, selection.targetStageId);
        }
        if (
            !stateMachine.hasExplicitSignalAuthorization(
                    planId, orderId, selection.selectorStageId, EXECUTOR_PATCH_SIGNAL_ID, selector
                ) && selector != stateMachine.orderCreator(planId, orderId)
        ) {
            revert UnauthorizedStageExecutorPatchSelector(orderId, selection.selectorStageId, selector);
        }
    }

    function _validateStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) private view {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (patch.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        if (!_isStageExecutorPatchMode(patch.mode)) {
            revert InvalidStageExecutorPatchMode(patch.mode);
        }
        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }
        if (stateMachine.stageHasOrderTriggerHook(planId, patch.targetStageId)) {
            revert StageExecutorPatchForbiddenOnBirthStage(orderId, patch.targetStageId);
        }
        if (stateMachine.stageHasDockExecutorHook(planId, patch.targetStageId)) {
            revert StageExecutorPatchForbiddenOnDockStage(orderId, patch.targetStageId);
        }
        {
            bytes32 candidatesRoot = stateMachine.planExecutorCandidatesRoot(planId);
            bytes32 leaf =
                keccak256(abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, patch.targetStageId, patch.executor));
            if (candidatesRoot == MerkleCommitment.EMPTY_ROOT || !MerkleCommitment.verify(candidatesRoot, leaf, candidateProof)) {
                revert StageExecutorNotCandidate(planId, orderId, patch.targetStageId, patch.executor);
            }
        }
        if (
            bindingProof.selectorStageId != patch.selectorStageId
                || !_planMetadata()
                    .verifyStageSelectorBinding(planId, patch.selectorStageId, patch.targetStageId, bindingProof.proof)
        ) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        if (
            !stateMachine.hasExplicitSignalAuthorization(
                    planId, orderId, patch.selectorStageId, EXECUTOR_PATCH_SIGNAL_ID, selector
                ) && selector != stateMachine.orderCreator(planId, orderId)
        ) {
            revert UnauthorizedStageExecutorPatchSelector(orderId, patch.selectorStageId, selector);
        }
    }

    function _validateStageExecutorPatchMode(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        ActiveStageExecutorPatch storage activePatch,
        address previousExecutorSigner
    ) private view {
        if (patch.mode != EXECUTOR_PATCH_MODE_HANDOFF && previousExecutorSigner != address(0)) {
            revert InvalidStageExecutorPatchSignature(address(0), previousExecutorSigner);
        }
        (uint256 signalCount, address latestSignalSubmitter, uint64 latestSubmittedAt, bool latestAmbiguous) =
            stateMachine.stageSignalState(planId, orderId, patch.targetStageId);
        if (patch.mode == EXECUTOR_PATCH_MODE_ASSIGN) {
            if (patch.previousExecutor != address(0)) {
                revert StageExecutorPatchPreviousExecutorMismatch(
                    orderId, patch.targetStageId, address(0), patch.previousExecutor
                );
            }
            if (signalCount != 0) {
                revert StageAlreadyHasSignal(orderId, patch.targetStageId);
            }
            return;
        }

        if (signalCount == 0) {
            revert StageHasNoSignal(orderId, patch.targetStageId);
        }

        address expectedPreviousExecutor = activePatch.exists ? activePatch.executor : latestSignalSubmitter;
        if (!activePatch.exists && latestAmbiguous) {
            revert StagePreviousExecutorAmbiguous(orderId, patch.targetStageId, latestSubmittedAt);
        }
        if (patch.previousExecutor != expectedPreviousExecutor) {
            revert StageExecutorPatchPreviousExecutorMismatch(
                orderId, patch.targetStageId, expectedPreviousExecutor, patch.previousExecutor
            );
        }

        if (previousExecutorSigner != patch.previousExecutor) {
            revert InvalidStageExecutorPatchSignature(patch.previousExecutor, previousExecutorSigner);
        }
    }

    function _dockFields(bytes32 dockId)
        private
        view
        returns (
            bytes32 fromPlanId,
            bytes32 toPlanId,
            bytes32 toSourceId,
            bytes32 toStageId,
            bool exists
        )
    {
        (fromPlanId, , toPlanId, toStageId, toSourceId, , , exists) = _dockRegistry().getDock(dockId);
    }

    function _isStageExecutorPatchMode(bytes32 mode) private pure returns (bool) {
        return mode == EXECUTOR_PATCH_MODE_ASSIGN || mode == EXECUTOR_PATCH_MODE_HANDOFF;
    }

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForStagePatch) {
        return IUVPPlanMetadataModuleForStagePatch(stateMachine.planMetadataModule());
    }

    function _dockRegistry() private view returns (IUVPDockRegistry) {
        return IUVPDockRegistry(stateMachine.dockRegistry());
    }

    function _stageExecutorPatchStructHash(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) private pure returns (bytes32) {
        bytes memory encoded = new bytes(0x200);
        _writeWord(encoded, 0x00, _STAGE_EXECUTOR_PATCH_TYPEHASH);
        _writeWord(encoded, 0x20, planId);
        _writeWord(encoded, 0x40, orderId);
        _writeWord(encoded, 0x60, patch.selectorStageId);
        _writeWord(encoded, 0x80, patch.targetStageId);
        _writeAddress(encoded, 0xa0, patch.executor);
        _writeWord(encoded, 0xc0, patch.role);
        _writeWord(encoded, 0xe0, patch.executorMetadataHash);
        _writeWord(encoded, 0x100, patch.mode);
        _writeAddress(encoded, 0x120, patch.previousExecutor);
        _writeWord(encoded, 0x140, patch.authorizationsHash);
        _writeWord(encoded, 0x160, patch.patchHash);
        _writeWord(encoded, 0x180, bytes32(patch.patchNonce));
        _writeWord(encoded, 0x1a0, keccak256(bytes(patch.metadataURI)));
        _writeAddress(encoded, 0x1c0, selector);
        _writeWord(encoded, 0x1e0, bytes32(deadline));
        return keccak256(encoded);
    }

    function _stageDockExecutorSelectionStructHash(
        bytes32 planId,
        bytes32 orderId,
        StageDockExecutorSelection calldata selection,
        address selector,
        uint256 deadline
    ) private pure returns (bytes32) {
        bytes memory encoded = new bytes(0x1e0);
        _writeWord(encoded, 0x00, _STAGE_DOCK_EXECUTOR_SELECTION_TYPEHASH);
        _writeWord(encoded, 0x20, planId);
        _writeWord(encoded, 0x40, orderId);
        _writeWord(encoded, 0x60, selection.selectorStageId);
        _writeWord(encoded, 0x80, selection.targetStageId);
        _writeWord(encoded, 0xa0, selection.dockId);
        _writeAddress(encoded, 0xc0, selection.executor);
        _writeWord(encoded, 0xe0, selection.role);
        _writeWord(encoded, 0x100, selection.executorMetadataHash);
        _writeWord(encoded, 0x120, selection.authorizationsHash);
        _writeWord(encoded, 0x140, selection.patchHash);
        _writeWord(encoded, 0x160, bytes32(selection.patchNonce));
        _writeWord(encoded, 0x180, keccak256(bytes(selection.metadataURI)));
        _writeAddress(encoded, 0x1a0, selector);
        _writeWord(encoded, 0x1c0, bytes32(deadline));
        return keccak256(encoded);
    }

    function _emitStageExecutorPatchApplied(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector
    ) private {
        bytes memory metadataURI = bytes(patch.metadataURI);
        bytes memory eventData = new bytes(0x180 + _paddedLength(metadataURI.length));
        _writeWord(eventData, 0x00, planId);
        _writeAddress(eventData, 0x20, selector);
        _writeAddress(eventData, 0x40, patch.executor);
        _writeWord(eventData, 0x60, patch.role);
        _writeWord(eventData, 0x80, patch.executorMetadataHash);
        _writeWord(eventData, 0xa0, patch.mode);
        _writeAddress(eventData, 0xc0, patch.previousExecutor);
        _writeWord(eventData, 0xe0, patch.authorizationsHash);
        _writeWord(eventData, 0x100, patch.patchHash);
        _writeWord(eventData, 0x120, bytes32(patch.patchNonce));
        _writeWord(eventData, 0x140, bytes32(uint256(0x160)));
        _writeWord(eventData, 0x160, bytes32(metadataURI.length));
        _copyBytes(eventData, 0x180, metadataURI);

        bytes32 selectorStageId = patch.selectorStageId;
        bytes32 targetStageId = patch.targetStageId;
        bytes32 topic = _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC;
        assembly ("memory-safe") {
            log4(add(eventData, 0x20), mload(eventData), topic, orderId, selectorStageId, targetStageId)
        }
    }

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _copyBytes(bytes memory target, uint256 offset, bytes memory source) private pure {
        for (uint256 i = 0; i < source.length; i++) {
            target[offset + i] = source[i];
        }
    }

    function _paddedLength(uint256 length) private pure returns (uint256) {
        return (length + 31) & ~uint256(31);
    }

    function _recoverStageExecutorPatchSigner(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidStageExecutorPatchSignatureLength(signature.length);
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
