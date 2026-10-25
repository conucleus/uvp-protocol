// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";

contract UVPDockingModule {
    struct OpenDockRequestV2 {
        bytes32 dockInstanceId;
        bytes32 localPlanId;
        bytes32 localOrderId;
        bytes32 localStageId;
        bytes32 localHookId;
        bytes32 localDefinitionRefHash;
        bytes32 routeId;
        bytes32 routeHash;
        bytes32 interfaceNameId;
        bytes32 targetUidId;
        bytes32 targetDefinitionRefHash;
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        bytes32 targetStageId;
        bytes32 targetHookId;
        uint8 parentDepth;
    }

    struct AttachDockRequestV1 {
        bytes32 dockInstanceId;
        bytes32 localPlanId;
        bytes32 localOrderId;
        bytes32 localStageId;
        bytes32 localDefinitionRefHash;
        bytes32 routeId;
        bytes32 routeHash;
        bytes32 interfaceNameId;
        bytes32 targetUidId;
        bytes32 targetDefinitionRefHash;
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        bytes32 targetStageId;
        uint8 parentDepth;
        bytes32 targetCandidatesRoot;
    }

    struct DockInterfacePortLeafV2 {
        bytes32 leafHash;
        bytes32 portKey;
        bytes32 hookKey;
    }

    struct DockInterfaceCommitmentV2 {
        uint8 orderModesWord;
        bytes32 inputsRoot;
        bytes32 outputsRoot;
    }

    struct DockInterfaceProofV2 {
        DockInterfacePortLeafV2 entranceLeaf;
        bytes32[] portProof;
        DockInterfaceCommitmentV2 commitment;
        bytes32[] interfaceProof;
    }

    struct DockAttachInterfaceProofV1 {
        DockInterfaceCommitmentV2 commitment;
        bytes32[] interfaceProof;
        bytes32[] candidateProof;
    }

    struct DockInputBindingArg {
        bytes32 localHookId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        bytes32 bindingHash;
    }

    struct AttachInputBindingArg {
        bytes32 localHookId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        bytes32 bindingHash;
        bytes32 targetHookId;
        bytes32[] portProof;
    }

    struct DockOutputBindingArg {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        bytes32 bindingHash;
        bytes32[] portProof;
    }

    struct EntrancePermitV2 {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    struct DockTargetConsentV1 {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    struct OpenAuthorizationV2 {
        EntrancePermitV2 permit;
        DockTargetConsentV1 consent;
    }

    struct OpenDockCallV1 {
        OpenDockRequestV2 request;
        bytes32[] routeProof;
        DockInterfaceProofV2 interfaceProof;
        DockInputBindingArg[] inputs;
        DockOutputBindingArg[] outputs;
        OpenAuthorizationV2 authorization;
        IUVPStateMachineCore.FactAttribution[] outputAttributions;
        IUVPStateMachineCore.FactAttribution entranceAttribution;
    }

    struct ActiveDockV2 {
        bytes32 localPlanId;
        bytes32 localOrderId;
        bytes32 localStageId;
        bytes32 routeId;
        bytes32 routeHash;
        bytes32 interfaceNameId;
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        uint8 depth;
        bool exists;
    }

    struct ActiveDockInputBindingV2 {
        bytes32 localHookId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        bool exists;
    }

    struct ActiveDockOutputBindingV2 {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        bool exists;
    }

    error DockBindingCountInvalid(uint256 count, uint256 required);
    error DockBindingLimitExceeded(uint256 count, uint256 limit);
    error DockEndpointOccupied(bytes32 endpointKey);
    error DockInputConflict(bytes32 dockInstanceId, bytes32 inputBindingHash);
    error DockInputHookNotReady(bytes32 localPlanId, bytes32 localOrderId, bytes32 localHookId);
    error DockInputNotFound(bytes32 dockInstanceId, bytes32 inputBindingHash);
    error DockNotOpened(bytes32 dockInstanceId);
    error DockOutputBindingNotFound(bytes32 dockInstanceId, bytes32 outputBindingHash);
    error DockOutputNotReady(bytes32 dockInstanceId, bytes32 outputBindingHash);
    error DockRouteLeafMismatch(bytes32 expected, bytes32 actual);
    error DockInterfaceLeafMismatch(bytes32 expected, bytes32 actual);
    error DockInterfaceModeUnsupported(uint8 orderModesWord);
    error DockDepthExceeded(uint8 parentDepth, uint8 maxDepth);
    error DockDepthMismatch(uint8 claimed, uint8 actual);
    error DockEntranceLeafMismatch(bytes32 field);
    error DockEntranceFactNotDeclared(bytes32 targetHookId, bytes32 targetSourceId, bytes32 targetSignalId);
    error DockOutputFactNotDeclared(bytes32 targetPlanId, bytes32 targetSourceId, bytes32 targetSignalId);
    error DockHookNotInputBound(bytes32 localPlanId, bytes32 localOrderId, bytes32 localHookId);
    error DockPermitExpired(uint256 deadline);
    error DockPermitInvalidSigner(address expected, address recovered);
    error DockPermitNonceAlreadyUsed(bytes32 dockInstanceId, uint256 nonce);
    error DockTargetIdentityMismatch(bytes32 declared, bytes32 derived);
    error DockUnknownLocalOrder();
    error DockUnknownTargetPlan();
    error DockUnknownTargetOrder(bytes32 targetPlanId, bytes32 linkedOrderId);
    error DockSelfAttach(bytes32 planId, bytes32 orderId);
    error DockAttachConsentRequired(bytes32 dockInstanceId, address caller);
    error DockCandidateLeafMismatch(bytes32 leaf, bytes32 root);
    error DockOpenConsentRequired(bytes32 dockInstanceId, address caller);
    error DockAncestorCycle(bytes32 planId, bytes32 orderId);
    error UnauthorizedDockSignalsAuthorizer(address caller, address publisher);

    event DockOpened(
        bytes32 indexed dockInstanceId,
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 interfaceNameId,
        bytes32 localPlanId,
        bytes32 targetPlanId,
        bytes32 routeId,
        bytes32 routeHash,
        uint8 depth,
        address opener
    );
    event DockAttached(
        bytes32 indexed dockInstanceId,
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 interfaceNameId,
        bytes32 localPlanId,
        bytes32 targetPlanId,
        bytes32 routeId,
        bytes32 routeHash,
        uint8 depth,
        address attacher
    );
    event DockInputSubmitted(
        bytes32 indexed dockInstanceId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed inputBindingHash,
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 targetPlanId,
        bytes32 targetSignalId,
        bytes32 payloadHash,
        address submitter
    );
    event DockOutputSubmitted(
        bytes32 indexed dockInstanceId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed outputBindingHash,
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 targetPlanId,
        bytes32 targetSignalId,
        bytes32 localSignalId,
        bytes32 payloadHash,
        address submitter
    );
    event DockOutputSatisfied(
        bytes32 indexed dockInstanceId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed outputBindingHash,
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 targetPlanId,
        bytes32 targetSignalId,
        bytes32 localSignalId,
        bytes32 payloadHash,
        address submitter
    );
    event DockOrderSignalsAuthorized(
        bytes32 indexed dockInstanceId,
        bytes32 indexed targetPlanId,
        bytes32 indexed linkedOrderId,
        uint256 count,
        bytes32 authorizationHash
    );

    uint8 public constant MAX_DOCK_OUTPUTS = 16;
    uint8 public constant MAX_DOCK_EDGES = 8;
    uint8 public constant DOCK_MODE_NEW = 0;
    uint8 public constant DOCK_MODE_EXISTING = 1;
    uint8 public constant DOCK_INTERFACE_ORDER_MODE_NEW = 1;
    uint8 public constant DOCK_INTERFACE_ORDER_MODE_EXISTING = 2;
    uint8 public constant SM_FLAG_EMIT_READY = 4;

    bytes32 private constant _DOMAIN_DEFINITION_REF = keccak256("UVP_DEFINITION_REF_V1");
    bytes32 private constant _DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V2");
    bytes32 private constant _DOMAIN_INTERFACE_OUTPUT = keccak256("UVP_DOCK_INTERFACE_OUTPUT_V3");
    bytes32 private constant _DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant _DOMAIN_SOURCE_FACT_SET_ZERO = bytes32(0);
    bytes32 private constant _DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V2");
    bytes32 private constant _DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V2");
    bytes32 private constant _DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V3");
    bytes32 private constant _DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V2");
    bytes32 private constant _DOMAIN_DOCK_CANDIDATE = keccak256("UVP_DOCK_CANDIDATE_V2");
    bytes32 private constant _DOMAIN_DOCK_ORDER = keccak256("UVP_DOCK_ORDER_V1");
    bytes32 private constant _DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant _DOMAIN_INPUT_IDEMPOTENCY = keccak256("UVP_DOCK_INPUT_IDEMPOTENCY_V1");
    bytes32 private constant _DOMAIN_INPUT_PAYLOAD = keccak256("UVP_DOCK_INPUT_PAYLOAD_V1");
    bytes32 private constant _DOMAIN_OUTPUT_IDEMPOTENCY = keccak256("UVP_DOCK_OUTPUT_IDEMPOTENCY_V1");
    bytes32 private constant _DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPDockingModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("4");
    bytes32 private constant _PERMIT_TYPEHASH = keccak256(
        "UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant _ATTACH_PERMIT_TYPEHASH = keccak256(
        "UVPDockAttachPermitV1(bytes32 targetPlanId,bytes32 targetOrderId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant _OPEN_CONSENT_TYPEHASH = keccak256(
        "UVPDockOpenConsentV1(bytes32 targetPlanId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 localOrderId,bytes32 routeId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 nonce,uint256 deadline)"
    );

    IUVPStateMachineCore public immutable stateMachine;
    IUVPPlanMetadataModule public immutable planMetadataModule;

    mapping(bytes32 dockInstanceId => ActiveDockV2 dock) private _docks;
    mapping(bytes32 dockInstanceId => mapping(bytes32 inputBindingHash => ActiveDockInputBindingV2 binding)) private
        _inputBindings;
    mapping(bytes32 dockInstanceId => mapping(bytes32 outputBindingHash => ActiveDockOutputBindingV2 binding)) private
        _outputBindings;
    mapping(bytes32 dockInstanceId => mapping(bytes32 inputBindingHash => bool delivered)) private _inputDelivered;
    mapping(bytes32 dockInstanceId => mapping(bytes32 outputBindingHash => bool delivered)) private _outputDelivered;
    mapping(bytes32 localRouteInstanceKey => bytes32 dockInstanceId) public dockByLocalRoute;
    mapping(bytes32 targetEndpointKey => bytes32 dockInstanceId) public dockByTargetOrder;
    mapping(bytes32 planId => mapping(bytes32 orderId => uint8 edgeCount)) public dockEdgeCountOfOrder;
    mapping(bytes32 planId => mapping(bytes32 orderId => bytes32 dockInstanceId)) public dockParentOfOrder;
    mapping(bytes32 dockInstanceId => uint256 usedPermitNonce) public usedEntrancePermitNonce;
    mapping(bytes32 dockInstanceId => uint256 usedNonce) public usedOpenConsentNonce;

    constructor(address stateMachineAddress, address planMetadataModuleAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
        planMetadataModule = IUVPPlanMetadataModule(planMetadataModuleAddress);
    }

    function openDockedOrder(OpenDockCallV1 calldata call) external returns (bool opened) {
        bytes32 entranceBindingHash = _verifyOpenCommitments(
            call.request, call.routeProof, call.interfaceProof, call.inputs, call.outputs, call.outputAttributions
        );
        (bool alreadyOpen, uint8 parentDepth) = _requireOpenGates(call.request, call.inputs, call.authorization);
        if (alreadyOpen) {
            return false;
        }
        return _applyOpenEffects(
            call.request, call.inputs, call.outputs, entranceBindingHash, parentDepth, call.entranceAttribution
        );
    }

    function _verifyOpenCommitments(
        OpenDockRequestV2 calldata request,
        bytes32[] calldata routeProof,
        DockInterfaceProofV2 calldata interfaceProof,
        DockInputBindingArg[] calldata inputs,
        DockOutputBindingArg[] calldata outputs,
        IUVPStateMachineCore.FactAttribution[] calldata outputAttributions
    ) private view returns (bytes32 entranceBindingHash) {
        if (!stateMachine.orderExists(request.localPlanId, request.localOrderId)) {
            revert DockUnknownLocalOrder();
        }
        uint8 hookFlags = stateMachine.planHookFlags(request.localPlanId, request.localHookId);
        if (hookFlags & SM_FLAG_EMIT_READY == 0) {
            revert DockHookNotInputBound(request.localPlanId, request.localOrderId, request.localHookId);
        }
        if (stateMachine.planHookStageId(request.localPlanId, request.localHookId) != request.localStageId) {
            revert DockHookNotInputBound(request.localPlanId, request.localOrderId, request.localHookId);
        }
        (,, bool readyEmitted) =
            stateMachine.getHookStatus(request.localPlanId, request.localOrderId, request.localHookId);
        if (!readyEmitted) {
            revert DockInputHookNotReady(request.localPlanId, request.localOrderId, request.localHookId);
        }

        bytes32 recomputedRouteId =
            keccak256(abi.encode(_DOMAIN_ROUTE_ID, request.localDefinitionRefHash, request.localStageId));
        if (recomputedRouteId != request.routeId) {
            revert DockRouteLeafMismatch(request.routeId, recomputedRouteId);
        }

        bytes32 derivedTargetDefRef = keccak256(abi.encode(_DOMAIN_DEFINITION_REF, request.targetUidId));
        if (derivedTargetDefRef != request.targetDefinitionRefHash) {
            revert DockTargetIdentityMismatch(request.targetDefinitionRefHash, derivedTargetDefRef);
        }

        if (inputs.length != 1) {
            revert DockBindingCountInvalid(inputs.length, 1);
        }
        if (inputs[0].localHookId != request.localHookId) {
            revert DockHookNotInputBound(request.localPlanId, request.localOrderId, request.localHookId);
        }
        if (outputs.length > MAX_DOCK_OUTPUTS) {
            revert DockBindingLimitExceeded(outputs.length, MAX_DOCK_OUTPUTS);
        }
        entranceBindingHash = _recomputeInputBinding(request.routeId, request.interfaceNameId, inputs[0]);
        bytes32 recomputedInputsRoot = _inputsRoot(inputs);
        bytes32 recomputedOutputsRoot = _outputsRoot(outputs);

        bytes32 entranceLeafHash = _verifyEntrancePortLeaf(request, interfaceProof.entranceLeaf, inputs[0].portKey);

        if (interfaceProof.commitment.orderModesWord & DOCK_INTERFACE_ORDER_MODE_NEW == 0) {
            revert DockInterfaceModeUnsupported(interfaceProof.commitment.orderModesWord);
        }
        if (!DockMerkle.verify(interfaceProof.commitment.inputsRoot, entranceLeafHash, interfaceProof.portProof)) {
            revert DockInterfaceLeafMismatch(entranceLeafHash, interfaceProof.commitment.inputsRoot);
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            _recomputeOutputBinding(request.routeId, request.interfaceNameId, outputs[i]);
            _verifyOutputPortMembership(
                request.targetUidId, request.interfaceNameId, outputs[i], interfaceProof.commitment.outputsRoot
            );
        }
        bytes32 recomputedRouteHash = _routeHash(
            request.localDefinitionRefHash,
            request.targetDefinitionRefHash,
            request.targetPlanId,
            request.interfaceNameId,
            DOCK_MODE_NEW,
            recomputedInputsRoot,
            recomputedOutputsRoot
        );
        if (recomputedRouteHash != request.routeHash) {
            revert DockRouteLeafMismatch(request.routeHash, recomputedRouteHash);
        }
        if (!planMetadataModule.verifyDockRoute(request.localPlanId, request.routeHash, routeProof)) {
            revert DockRouteLeafMismatch(request.routeHash, bytes32(0));
        }

        if (!stateMachine.planExists(request.targetPlanId)) {
            revert DockUnknownTargetPlan();
        }
        if (!_verifyTargetInterface(request, interfaceProof)) {
            revert DockInterfaceLeafMismatch(entranceLeafHash, bytes32(0));
        }
        if (!stateMachine.planHookDependsOn(
                request.targetPlanId, request.targetHookId, inputs[0].targetSourceId, inputs[0].targetSignalId
            )) {
            revert DockEntranceFactNotDeclared(request.targetHookId, inputs[0].targetSourceId, inputs[0].targetSignalId);
        }
        _verifyOutputVocabulary(request.targetPlanId, outputs, outputAttributions);
    }

    function _requireOpenGates(
        OpenDockRequestV2 calldata request,
        DockInputBindingArg[] calldata inputs,
        OpenAuthorizationV2 calldata authorization
    ) private returns (bool alreadyOpen, uint8 parentDepth) {
        EntrancePermitV2 calldata permit = authorization.permit;
        DockTargetConsentV1 calldata consent = authorization.consent;
        bytes32 runtimeDomain = keccak256(abi.encode(_DOMAIN_RUNTIME_EIP155, block.chainid, address(stateMachine)));
        bytes32 recomputedDockInstance = _dockInstanceId(request, runtimeDomain);
        if (recomputedDockInstance != request.dockInstanceId) {
            revert DockRouteLeafMismatch(request.dockInstanceId, recomputedDockInstance);
        }
        bytes32 recomputedLinkedOrder = bytes32(
            uint256(keccak256(abi.encode(_DOMAIN_DOCK_ORDER, request.dockInstanceId, request.targetDefinitionRefHash)))
                | uint256(_DOCK_ORDER_NAMESPACE_MASK)
        );
        if (recomputedLinkedOrder != request.linkedOrderId) {
            revert DockRouteLeafMismatch(request.linkedOrderId, recomputedLinkedOrder);
        }
        if (_docks[request.dockInstanceId].exists) {
            return (true, 0);
        }

        if (permit.signature.length != 0) {
            _verifyEntrancePermit(request, inputs[0].portKey, permit);
        }
        _requireOpenConsent(request, consent);

        uint8 parentDepth = dockEdgeCountOfOrder[request.localPlanId][request.localOrderId];
        if (parentDepth != request.parentDepth) {
            revert DockDepthMismatch(request.parentDepth, parentDepth);
        }
        if (parentDepth >= MAX_DOCK_EDGES) {
            revert DockDepthExceeded(parentDepth, MAX_DOCK_EDGES);
        }

        bytes32 localRouteInstanceKey =
            keccak256(abi.encode(request.localPlanId, request.localOrderId, request.localStageId, request.routeId));
        bytes32 targetEndpointKey = keccak256(abi.encode(request.targetPlanId, request.linkedOrderId));
        if (dockByLocalRoute[localRouteInstanceKey] != bytes32(0)) {
            revert DockEndpointOccupied(localRouteInstanceKey);
        }
        if (dockByTargetOrder[targetEndpointKey] != bytes32(0)) {
            revert DockEndpointOccupied(targetEndpointKey);
        }
        return (false, parentDepth);
    }

    function _applyOpenEffects(
        OpenDockRequestV2 calldata request,
        DockInputBindingArg[] calldata inputs,
        DockOutputBindingArg[] calldata outputs,
        bytes32 entranceBindingHash,
        uint8 parentDepth,
        IUVPStateMachineCore.FactAttribution calldata entranceAttribution
    ) private returns (bool) {
        bytes32 localRouteInstanceKey =
            keccak256(abi.encode(request.localPlanId, request.localOrderId, request.localStageId, request.routeId));
        bytes32 targetEndpointKey = keccak256(abi.encode(request.targetPlanId, request.linkedOrderId));
        _docks[request.dockInstanceId] = ActiveDockV2({
            localPlanId: request.localPlanId,
            localOrderId: request.localOrderId,
            localStageId: request.localStageId,
            routeId: request.routeId,
            routeHash: request.routeHash,
            interfaceNameId: request.interfaceNameId,
            targetPlanId: request.targetPlanId,
            linkedOrderId: request.linkedOrderId,
            depth: parentDepth + 1,
            exists: true
        });
        _inputBindings[request.dockInstanceId][entranceBindingHash] = ActiveDockInputBindingV2({
            localHookId: inputs[0].localHookId,
            portKey: inputs[0].portKey,
            targetSourceId: inputs[0].targetSourceId,
            targetSignalId: inputs[0].targetSignalId,
            exists: true
        });
        for (uint256 i = 0; i < outputs.length; i++) {
            _outputBindings[request.dockInstanceId][outputs[i].bindingHash] = ActiveDockOutputBindingV2({
                localSourceId: outputs[i].localSourceId,
                localSignalId: outputs[i].localSignalId,
                portKey: outputs[i].portKey,
                targetSourceId: outputs[i].targetSourceId,
                targetSignalId: outputs[i].targetSignalId,
                exists: true
            });
        }
        dockByLocalRoute[localRouteInstanceKey] = request.dockInstanceId;
        dockByTargetOrder[targetEndpointKey] = request.dockInstanceId;
        dockEdgeCountOfOrder[request.targetPlanId][request.linkedOrderId] = parentDepth + 1;
        dockParentOfOrder[request.targetPlanId][request.linkedOrderId] = request.dockInstanceId;

        bytes32 entrancePayloadHash = _inputPayloadHash(
            request.dockInstanceId,
            request.routeHash,
            request.localPlanId,
            request.localOrderId,
            request.localStageId,
            request.localHookId,
            request.targetPlanId,
            request.linkedOrderId,
            inputs[0].portKey,
            inputs[0].targetSignalId
        );
        bytes32 entranceIdempotencyKey =
            keccak256(abi.encode(_DOMAIN_INPUT_IDEMPOTENCY, request.dockInstanceId, entranceBindingHash, uint256(0)));

        address creator = stateMachine.planPublisher(request.targetPlanId);
        IUVPStateMachineCore.DockEntranceRequest memory entranceRequest = IUVPStateMachineCore.DockEntranceRequest({
            targetPlanId: request.targetPlanId,
            linkedOrderId: request.linkedOrderId,
            creator: creator,
            relayer: msg.sender,
            entranceHookId: request.targetHookId,
            entranceStageId: request.targetStageId,
            sourceId: inputs[0].targetSourceId,
            signalId: inputs[0].targetSignalId,
            payloadHash: entrancePayloadHash,
            idempotencyKey: entranceIdempotencyKey,
            submitter: creator,
            authorizations: new IUVPStateMachineCore.SignalAuthorization[](0),
            entranceAttribution: entranceAttribution
        });
        stateMachine.createDockedOrderFromModule(entranceRequest);

        _inputDelivered[request.dockInstanceId][entranceBindingHash] = true;

        emit DockOpened(
            request.dockInstanceId,
            request.localOrderId,
            request.linkedOrderId,
            request.interfaceNameId,
            request.localPlanId,
            request.targetPlanId,
            request.routeId,
            request.routeHash,
            parentDepth + 1,
            msg.sender
        );
        emit DockInputSubmitted(
            request.dockInstanceId,
            request.linkedOrderId,
            entranceBindingHash,
            request.localPlanId,
            request.localOrderId,
            request.targetPlanId,
            inputs[0].targetSignalId,
            entrancePayloadHash,
            creator
        );
        return true;
    }

    /// @notice target plan publisher 对已建立 dock 的目标单写入显式订单级
    ///          信号授权（授权来源 = publisher 身份腿，与 open consent /
    ///          子单 creator 同源）。dock 子单出生授权集为空、出生阶段又
    ///          禁止 executor patch，本入口是子单内部阶段推进的显式授权面；
    ///          键/提交者校验与事件由 StateMachine 按出生通道同口径完成。
    function authorizeDockedOrderSignals(
        bytes32 dockInstanceId,
        IUVPStateMachineCore.SignalAuthorization[] calldata authorizations
    ) external {
        ActiveDockV2 storage dock = _docks[dockInstanceId];
        if (!dock.exists) {
            revert DockNotOpened(dockInstanceId);
        }
        address publisher = stateMachine.planPublisher(dock.targetPlanId);
        if (msg.sender != publisher) {
            revert UnauthorizedDockSignalsAuthorizer(msg.sender, publisher);
        }
        stateMachine.authorizeDockedSignalsFromModule(dock.targetPlanId, dock.linkedOrderId, authorizations);
        emit DockOrderSignalsAuthorized(
            dockInstanceId,
            dock.targetPlanId,
            dock.linkedOrderId,
            authorizations.length,
            stateMachine.signalAuthorizationsHash(authorizations)
        );
    }

    /// @notice 挂接一条 committed existing 路由到既有目标单：不铸子单、
    ///          不触碰 dock 子单 namespace，效果集是 O(1) 存储写（与链上
    ///          存量 dock 数无关）。建立后 submitDockedInput/
    ///          submitDockedSignal 与 new 模式完全同构（linkedOrderId 语义
    ///          = 既有目标单）；attach 前已成立的目标输出由 submitDockedSignal
    ///          按 output 绑定重放回填（permissionless，事实读 StateMachine
    ///          存储）。同意门在幂等检查之后：成功挂接的重放对任何人
    ///          return false，不因同意/nonce 已消费而回退。
    function attachDockedOrder(
        AttachDockRequestV1 calldata request,
        bytes32[] calldata routeProof,
        DockAttachInterfaceProofV1 calldata attachProof,
        AttachInputBindingArg[] calldata inputs,
        DockOutputBindingArg[] calldata outputs,
        EntrancePermitV2 calldata permit,
        IUVPStateMachineCore.FactAttribution[] calldata outputAttributions
    ) external returns (bool attached) {
        if (!stateMachine.orderExists(request.localPlanId, request.localOrderId)) {
            revert DockUnknownLocalOrder();
        }
        bytes32 recomputedRouteId =
            keccak256(abi.encode(_DOMAIN_ROUTE_ID, request.localDefinitionRefHash, request.localStageId));
        if (recomputedRouteId != request.routeId) {
            revert DockRouteLeafMismatch(request.routeId, recomputedRouteId);
        }
        bytes32 derivedTargetDefRef = keccak256(abi.encode(_DOMAIN_DEFINITION_REF, request.targetUidId));
        if (derivedTargetDefRef != request.targetDefinitionRefHash) {
            revert DockTargetIdentityMismatch(request.targetDefinitionRefHash, derivedTargetDefRef);
        }
        if (!stateMachine.orderExists(request.targetPlanId, request.linkedOrderId)) {
            revert DockUnknownTargetOrder(request.targetPlanId, request.linkedOrderId);
        }
        if (request.localPlanId == request.targetPlanId && request.localOrderId == request.linkedOrderId) {
            revert DockSelfAttach(request.localPlanId, request.localOrderId);
        }
        if (outputs.length > MAX_DOCK_OUTPUTS) {
            revert DockBindingLimitExceeded(outputs.length, MAX_DOCK_OUTPUTS);
        }

        if (attachProof.commitment.orderModesWord & DOCK_INTERFACE_ORDER_MODE_EXISTING == 0) {
            revert DockInterfaceModeUnsupported(attachProof.commitment.orderModesWord);
        }

        bytes32[] memory inputLeaves = new bytes32[](inputs.length);
        _requireUniqueInputTargets(request.dockInstanceId, inputs);
        for (uint256 i = 0; i < inputs.length; i++) {
            AttachInputBindingArg calldata binding = inputs[i];
            bytes32 recomputed = _inputBindingHash(
                request.routeId,
                request.interfaceNameId,
                binding.localHookId,
                binding.portKey,
                binding.targetSourceId,
                binding.targetSignalId
            );
            if (recomputed != binding.bindingHash) {
                revert DockRouteLeafMismatch(binding.bindingHash, recomputed);
            }
            inputLeaves[i] = recomputed;
            uint8 hookFlags = stateMachine.planHookFlags(request.localPlanId, binding.localHookId);
            if (hookFlags & SM_FLAG_EMIT_READY == 0) {
                revert DockHookNotInputBound(request.localPlanId, request.localOrderId, binding.localHookId);
            }
            if (stateMachine.planHookStageId(request.localPlanId, binding.localHookId) != request.localStageId) {
                revert DockHookNotInputBound(request.localPlanId, request.localOrderId, binding.localHookId);
            }
            bytes32 inputPortLeaf = keccak256(
                abi.encode(
                    _DOMAIN_INTERFACE_INPUT,
                    request.targetUidId,
                    request.interfaceNameId,
                    binding.portKey,
                    binding.targetHookId
                )
            );
            if (!DockMerkle.verify(attachProof.commitment.inputsRoot, inputPortLeaf, binding.portProof)) {
                revert DockInterfaceLeafMismatch(inputPortLeaf, attachProof.commitment.inputsRoot);
            }
            if (stateMachine.planHookStageId(request.targetPlanId, binding.targetHookId) != request.targetStageId) {
                revert DockEntranceLeafMismatch(binding.portKey);
            }
            if (!stateMachine.planHookDependsOn(
                    request.targetPlanId, binding.targetHookId, binding.targetSourceId, binding.targetSignalId
                )) {
                revert DockEntranceFactNotDeclared(binding.targetHookId, binding.targetSourceId, binding.targetSignalId);
            }
        }
        bytes32 recomputedInputsRoot = DockMerkle.root(inputLeaves);
        bytes32 recomputedOutputsRoot = _outputsRoot(outputs);
        for (uint256 i = 0; i < outputs.length; i++) {
            _recomputeOutputBinding(request.routeId, request.interfaceNameId, outputs[i]);
            _verifyOutputPortMembership(
                request.targetUidId, request.interfaceNameId, outputs[i], attachProof.commitment.outputsRoot
            );
        }

        bytes32 recomputedRouteHash = _routeHash(
            request.localDefinitionRefHash,
            request.targetDefinitionRefHash,
            request.targetPlanId,
            request.interfaceNameId,
            DOCK_MODE_EXISTING,
            recomputedInputsRoot,
            recomputedOutputsRoot
        );
        if (recomputedRouteHash != request.routeHash) {
            bytes32 dynamicRouteHash = _routeHash(
                request.localDefinitionRefHash,
                request.targetCandidatesRoot,
                bytes32(0),
                request.interfaceNameId,
                DOCK_MODE_EXISTING,
                recomputedInputsRoot,
                recomputedOutputsRoot
            );
            if (dynamicRouteHash != request.routeHash) {
                revert DockRouteLeafMismatch(request.routeHash, dynamicRouteHash);
            }
            bytes32 candidateLeaf = keccak256(
                abi.encode(
                    _DOMAIN_DOCK_CANDIDATE,
                    request.routeId,
                    request.targetDefinitionRefHash,
                    request.targetPlanId,
                    request.interfaceNameId
                )
            );
            if (!DockMerkle.verify(request.targetCandidatesRoot, candidateLeaf, attachProof.candidateProof)) {
                revert DockCandidateLeafMismatch(candidateLeaf, request.targetCandidatesRoot);
            }
        }
        if (!planMetadataModule.verifyDockRoute(request.localPlanId, request.routeHash, routeProof)) {
            revert DockRouteLeafMismatch(request.routeHash, bytes32(0));
        }

        if (!stateMachine.planExists(request.targetPlanId)) {
            revert DockUnknownTargetPlan();
        }
        if (!planMetadataModule.verifyDockInterfacePort(
                request.targetPlanId,
                request.targetUidId,
                request.interfaceNameId,
                attachProof.commitment.orderModesWord,
                attachProof.commitment.inputsRoot,
                attachProof.commitment.outputsRoot,
                attachProof.interfaceProof
            )) {
            revert DockInterfaceLeafMismatch(bytes32(0), bytes32(0));
        }
        _verifyOutputVocabulary(request.targetPlanId, outputs, outputAttributions);

        bytes32 runtimeDomain = keccak256(abi.encode(_DOMAIN_RUNTIME_EIP155, block.chainid, address(stateMachine)));
        bytes32 recomputedDockInstance = _dockInstanceIdExisting(request, runtimeDomain);
        if (recomputedDockInstance != request.dockInstanceId) {
            revert DockRouteLeafMismatch(request.dockInstanceId, recomputedDockInstance);
        }
        if (_docks[request.dockInstanceId].exists) {
            return false;
        }

        _requireAttachConsent(request, permit);

        uint8 parentDepth = dockEdgeCountOfOrder[request.localPlanId][request.localOrderId];
        if (parentDepth != request.parentDepth) {
            revert DockDepthMismatch(request.parentDepth, parentDepth);
        }
        if (parentDepth >= MAX_DOCK_EDGES) {
            revert DockDepthExceeded(parentDepth, MAX_DOCK_EDGES);
        }
        _requireNotDockAncestor(request);

        bytes32 localRouteInstanceKey =
            keccak256(abi.encode(request.localPlanId, request.localOrderId, request.localStageId, request.routeId));
        if (dockByLocalRoute[localRouteInstanceKey] != bytes32(0)) {
            revert DockEndpointOccupied(localRouteInstanceKey);
        }

        _docks[request.dockInstanceId] = ActiveDockV2({
            localPlanId: request.localPlanId,
            localOrderId: request.localOrderId,
            localStageId: request.localStageId,
            routeId: request.routeId,
            routeHash: request.routeHash,
            interfaceNameId: request.interfaceNameId,
            targetPlanId: request.targetPlanId,
            linkedOrderId: request.linkedOrderId,
            depth: parentDepth + 1,
            exists: true
        });
        for (uint256 i = 0; i < inputs.length; i++) {
            _inputBindings[request.dockInstanceId][inputs[i].bindingHash] = ActiveDockInputBindingV2({
                localHookId: inputs[i].localHookId,
                portKey: inputs[i].portKey,
                targetSourceId: inputs[i].targetSourceId,
                targetSignalId: inputs[i].targetSignalId,
                exists: true
            });
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            _outputBindings[request.dockInstanceId][outputs[i].bindingHash] = ActiveDockOutputBindingV2({
                localSourceId: outputs[i].localSourceId,
                localSignalId: outputs[i].localSignalId,
                portKey: outputs[i].portKey,
                targetSourceId: outputs[i].targetSourceId,
                targetSignalId: outputs[i].targetSignalId,
                exists: true
            });
        }
        dockByLocalRoute[localRouteInstanceKey] = request.dockInstanceId;
        if (dockEdgeCountOfOrder[request.targetPlanId][request.linkedOrderId] < parentDepth + 1) {
            dockEdgeCountOfOrder[request.targetPlanId][request.linkedOrderId] = parentDepth + 1;
            dockParentOfOrder[request.targetPlanId][request.linkedOrderId] = request.dockInstanceId;
        }

        emit DockAttached(
            request.dockInstanceId,
            request.localOrderId,
            request.linkedOrderId,
            request.interfaceNameId,
            request.localPlanId,
            request.targetPlanId,
            request.routeId,
            request.routeHash,
            parentDepth + 1,
            msg.sender
        );
        return true;
    }

    function submitDockedInput(
        bytes32 dockInstanceId,
        bytes32 localHookId,
        bytes32 inputBindingHash,
        IUVPStateMachineCore.FactAttribution calldata attribution
    ) external returns (bool submitted) {
        ActiveDockV2 storage dock = _docks[dockInstanceId];
        if (!dock.exists) {
            revert DockNotOpened(dockInstanceId);
        }
        if (_inputDelivered[dockInstanceId][inputBindingHash]) {
            return false;
        }
        ActiveDockInputBindingV2 storage binding = _inputBindings[dockInstanceId][inputBindingHash];
        if (!binding.exists) {
            revert DockInputNotFound(dockInstanceId, inputBindingHash);
        }
        if (binding.localHookId != localHookId) {
            revert DockHookNotInputBound(dock.localPlanId, dock.localOrderId, localHookId);
        }
        uint8 hookFlags = stateMachine.planHookFlags(dock.localPlanId, localHookId);
        if (hookFlags & SM_FLAG_EMIT_READY == 0) {
            revert DockHookNotInputBound(dock.localPlanId, dock.localOrderId, localHookId);
        }
        (,, bool readyEmitted) = stateMachine.getHookStatus(dock.localPlanId, dock.localOrderId, localHookId);
        if (!readyEmitted) {
            revert DockInputHookNotReady(dock.localPlanId, dock.localOrderId, localHookId);
        }
        if (stateMachine.hasSignal(
                dock.targetPlanId, dock.linkedOrderId, binding.targetSourceId, binding.targetSignalId
            )) {
            revert DockInputConflict(dockInstanceId, inputBindingHash);
        }
        bytes32 idempotencyKey =
            keccak256(abi.encode(_DOMAIN_INPUT_IDEMPOTENCY, dockInstanceId, inputBindingHash, uint256(0)));
        bytes32 payloadHash = _inputPayloadHash(
            dockInstanceId,
            dock.routeHash,
            dock.localPlanId,
            dock.localOrderId,
            dock.localStageId,
            localHookId,
            dock.targetPlanId,
            dock.linkedOrderId,
            binding.portKey,
            binding.targetSignalId
        );

        _inputDelivered[dockInstanceId][inputBindingHash] = true;
        address childCreator = stateMachine.orderCreator(dock.targetPlanId, dock.linkedOrderId);
        stateMachine.recordDockedInputFromModule(
            IUVPStateMachineCore.DockInputFact({
                planId: dock.targetPlanId,
                orderId: dock.linkedOrderId,
                sourceId: binding.targetSourceId,
                signalId: binding.targetSignalId,
                payloadHash: payloadHash,
                idempotencyKey: idempotencyKey,
                submitter: childCreator,
                attribution: attribution
            })
        );

        emit DockInputSubmitted(
            dockInstanceId,
            dock.linkedOrderId,
            inputBindingHash,
            dock.localPlanId,
            dock.localOrderId,
            dock.targetPlanId,
            binding.targetSignalId,
            payloadHash,
            childCreator
        );
        return true;
    }

    function submitDockedSignal(
        bytes32 dockInstanceId,
        bytes32 outputBindingHash,
        IUVPStateMachineCore.FactAttribution calldata attribution
    ) external returns (bool submitted) {
        ActiveDockV2 storage dock = _docks[dockInstanceId];
        if (!dock.exists) {
            revert DockNotOpened(dockInstanceId);
        }
        if (_outputDelivered[dockInstanceId][outputBindingHash]) {
            return false;
        }
        ActiveDockOutputBindingV2 storage binding = _outputBindings[dockInstanceId][outputBindingHash];
        if (!binding.exists) {
            revert DockOutputBindingNotFound(dockInstanceId, outputBindingHash);
        }
        (bool exists, bytes32 payloadHash,,, address originalSubmitter) = stateMachine.getSignal(
            dock.targetPlanId, dock.linkedOrderId, binding.targetSourceId, binding.targetSignalId
        );
        if (!exists) {
            revert DockOutputNotReady(dockInstanceId, outputBindingHash);
        }
        {
            (bool mirrorExists, bytes32 mirrorPayload,,,) = stateMachine.getSignal(
                dock.localPlanId, dock.localOrderId, binding.localSourceId, binding.localSignalId
            );
            if (mirrorExists && mirrorPayload == payloadHash) {
                _outputDelivered[dockInstanceId][outputBindingHash] = true;
                emit DockOutputSatisfied(
                    dockInstanceId,
                    dock.linkedOrderId,
                    outputBindingHash,
                    dock.localPlanId,
                    dock.localOrderId,
                    dock.targetPlanId,
                    binding.targetSignalId,
                    binding.localSignalId,
                    payloadHash,
                    originalSubmitter
                );
                return true;
            }
        }
        bytes32 targetFactId = keccak256(abi.encode(binding.targetSourceId, binding.targetSignalId));
        bytes32 idempotencyKey =
            keccak256(abi.encode(_DOMAIN_OUTPUT_IDEMPOTENCY, dockInstanceId, outputBindingHash, targetFactId));

        _outputDelivered[dockInstanceId][outputBindingHash] = true;
        address parentCreator = stateMachine.orderCreator(dock.localPlanId, dock.localOrderId);
        stateMachine.submitSignalFromModule(
            dock.localPlanId,
            dock.localOrderId,
            binding.localSourceId,
            binding.localSignalId,
            payloadHash,
            idempotencyKey,
            parentCreator,
            attribution
        );

        emit DockOutputSubmitted(
            dockInstanceId,
            dock.linkedOrderId,
            outputBindingHash,
            dock.localPlanId,
            dock.localOrderId,
            dock.targetPlanId,
            binding.targetSignalId,
            binding.localSignalId,
            payloadHash,
            originalSubmitter
        );
        return true;
    }

    function getActiveDock(bytes32 dockInstanceId)
        external
        view
        returns (
            bytes32 localPlanId,
            bytes32 localOrderId,
            bytes32 localStageId,
            bytes32 routeId,
            bytes32 routeHash,
            bytes32 targetPlanId,
            bytes32 linkedOrderId,
            bytes32 interfaceNameId,
            uint8 depth,
            bool exists
        )
    {
        ActiveDockV2 storage dock = _docks[dockInstanceId];
        return (
            dock.localPlanId,
            dock.localOrderId,
            dock.localStageId,
            dock.routeId,
            dock.routeHash,
            dock.targetPlanId,
            dock.linkedOrderId,
            dock.interfaceNameId,
            dock.depth,
            dock.exists
        );
    }

    function getDockInputBinding(bytes32 dockInstanceId, bytes32 inputBindingHash)
        external
        view
        returns (bytes32 localHookId, bytes32 portKey, bytes32 targetSourceId, bytes32 targetSignalId, bool exists)
    {
        ActiveDockInputBindingV2 storage binding = _inputBindings[dockInstanceId][inputBindingHash];
        return (binding.localHookId, binding.portKey, binding.targetSourceId, binding.targetSignalId, binding.exists);
    }

    function getDockOutputBinding(bytes32 dockInstanceId, bytes32 outputBindingHash)
        external
        view
        returns (
            bytes32 localSourceId,
            bytes32 localSignalId,
            bytes32 portKey,
            bytes32 targetSourceId,
            bytes32 targetSignalId,
            bool exists
        )
    {
        ActiveDockOutputBindingV2 storage binding = _outputBindings[dockInstanceId][outputBindingHash];
        return (
            binding.localSourceId,
            binding.localSignalId,
            binding.portKey,
            binding.targetSourceId,
            binding.targetSignalId,
            binding.exists
        );
    }

    function dockInputDelivered(bytes32 dockInstanceId, bytes32 inputBindingHash) external view returns (bool) {
        return _inputDelivered[dockInstanceId][inputBindingHash];
    }

    function dockOutputDelivered(bytes32 dockInstanceId, bytes32 outputBindingHash) external view returns (bool) {
        return _outputDelivered[dockInstanceId][outputBindingHash];
    }

    function entrancePermitDigest(
        bytes32 targetPlanId,
        bytes32 targetEntrancePortId,
        bytes32 interfaceNameId,
        bytes32 localPlanId,
        bytes32 routeHash,
        bytes32 dockInstanceId,
        bytes32 linkedOrderId,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _PERMIT_TYPEHASH,
                targetPlanId,
                targetEntrancePortId,
                interfaceNameId,
                localPlanId,
                routeHash,
                dockInstanceId,
                linkedOrderId,
                uint256(0),
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function attachPermitDigest(
        bytes32 targetPlanId,
        bytes32 targetOrderId,
        bytes32 interfaceNameId,
        bytes32 localPlanId,
        bytes32 routeHash,
        bytes32 dockInstanceId,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _ATTACH_PERMIT_TYPEHASH,
                targetPlanId,
                targetOrderId,
                interfaceNameId,
                localPlanId,
                routeHash,
                dockInstanceId,
                uint256(0),
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function openConsentDigest(
        bytes32 targetPlanId,
        bytes32 interfaceNameId,
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 routeId,
        bytes32 routeHash,
        bytes32 dockInstanceId,
        bytes32 linkedOrderId,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _OPEN_CONSENT_TYPEHASH,
                targetPlanId,
                interfaceNameId,
                localPlanId,
                localOrderId,
                routeId,
                routeHash,
                dockInstanceId,
                linkedOrderId,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _verifyEntrancePermit(
        OpenDockRequestV2 calldata request,
        bytes32 entrancePortKey,
        EntrancePermitV2 calldata permit
    ) private {
        if (block.timestamp > permit.deadline) {
            revert DockPermitExpired(permit.deadline);
        }
        if (usedEntrancePermitNonce[request.dockInstanceId] >= permit.nonce) {
            revert DockPermitNonceAlreadyUsed(request.dockInstanceId, permit.nonce);
        }
        address authority = stateMachine.planPublisher(request.targetPlanId);
        bytes32 structHash = keccak256(
            abi.encode(
                _PERMIT_TYPEHASH,
                request.targetPlanId,
                entrancePortKey,
                request.interfaceNameId,
                request.localPlanId,
                request.routeHash,
                request.dockInstanceId,
                request.linkedOrderId,
                uint256(0),
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (permit.signature.length != 65) {
            revert DockPermitInvalidSigner(authority, address(0));
        }
        bytes memory signature = permit.signature;
        bytes32 r;
        bytes32 sigS;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            sigS := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        address recovered = ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: sigS}));
        if (recovered != authority) {
            revert DockPermitInvalidSigner(authority, recovered);
        }
        usedEntrancePermitNonce[request.dockInstanceId] = permit.nonce;
    }

    function _requireAttachConsent(AttachDockRequestV1 calldata request, EntrancePermitV2 calldata permit) private {
        if (stateMachine.orderCreator(request.targetPlanId, request.linkedOrderId) == msg.sender) {
            return;
        }
        if (
            stateMachine.activeStageExecutor(request.targetPlanId, request.linkedOrderId, request.targetStageId)
                == msg.sender
        ) {
            return;
        }
        if (permit.signature.length == 0) {
            revert DockAttachConsentRequired(request.dockInstanceId, msg.sender);
        }
        _verifyAttachPermit(request, permit);
    }

    function _verifyAttachPermit(AttachDockRequestV1 calldata request, EntrancePermitV2 calldata permit) private {
        if (block.timestamp > permit.deadline) {
            revert DockPermitExpired(permit.deadline);
        }
        if (usedEntrancePermitNonce[request.dockInstanceId] >= permit.nonce) {
            revert DockPermitNonceAlreadyUsed(request.dockInstanceId, permit.nonce);
        }
        address authority = stateMachine.planPublisher(request.targetPlanId);
        bytes32 structHash = keccak256(
            abi.encode(
                _ATTACH_PERMIT_TYPEHASH,
                request.targetPlanId,
                request.linkedOrderId,
                request.interfaceNameId,
                request.localPlanId,
                request.routeHash,
                request.dockInstanceId,
                uint256(0),
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (permit.signature.length != 65) {
            revert DockPermitInvalidSigner(authority, address(0));
        }
        bytes memory signature = permit.signature;
        bytes32 r;
        bytes32 sigS;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            sigS := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        address recovered = ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: sigS}));
        if (recovered != authority) {
            revert DockPermitInvalidSigner(authority, recovered);
        }
        usedEntrancePermitNonce[request.dockInstanceId] = permit.nonce;
    }

    function _requireOpenConsent(OpenDockRequestV2 calldata request, DockTargetConsentV1 calldata consent) private {
        address authority = stateMachine.planPublisher(request.targetPlanId);
        if (msg.sender == authority) {
            return;
        }
        if (consent.signature.length == 0) {
            revert DockOpenConsentRequired(request.dockInstanceId, msg.sender);
        }
        if (block.timestamp > consent.deadline) {
            revert DockPermitExpired(consent.deadline);
        }
        if (usedOpenConsentNonce[request.dockInstanceId] >= consent.nonce) {
            revert DockPermitNonceAlreadyUsed(request.dockInstanceId, consent.nonce);
        }
        bytes32 structHash = keccak256(
            abi.encode(
                _OPEN_CONSENT_TYPEHASH,
                request.targetPlanId,
                request.interfaceNameId,
                request.localPlanId,
                request.localOrderId,
                request.routeId,
                request.routeHash,
                request.dockInstanceId,
                request.linkedOrderId,
                consent.nonce,
                consent.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (consent.signature.length != 65) {
            revert DockPermitInvalidSigner(authority, address(0));
        }
        bytes memory signature = consent.signature;
        bytes32 r;
        bytes32 sigS;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            sigS := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        address recovered = ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: sigS}));
        if (recovered != authority) {
            revert DockPermitInvalidSigner(authority, recovered);
        }
        usedOpenConsentNonce[request.dockInstanceId] = consent.nonce;
    }

    function _requireNotDockAncestor(AttachDockRequestV1 calldata request) private view {
        bytes32 cursorPlan = request.localPlanId;
        bytes32 cursorOrder = request.localOrderId;
        for (uint256 hop = 0; hop < MAX_DOCK_EDGES; hop++) {
            bytes32 parentDockId = dockParentOfOrder[cursorPlan][cursorOrder];
            if (parentDockId == bytes32(0)) {
                return;
            }
            ActiveDockV2 storage parentDock = _docks[parentDockId];
            if (!parentDock.exists) {
                return;
            }
            if (parentDock.localPlanId == request.targetPlanId && parentDock.localOrderId == request.linkedOrderId) {
                revert DockAncestorCycle(request.targetPlanId, request.linkedOrderId);
            }
            cursorPlan = parentDock.localPlanId;
            cursorOrder = parentDock.localOrderId;
        }
    }
    function _verifyEntrancePortLeaf(
        OpenDockRequestV2 calldata request,
        DockInterfacePortLeafV2 calldata entranceLeaf,
        bytes32 entrancePortKey
    ) private pure returns (bytes32) {
        bytes32 recomputed = keccak256(
            abi.encode(
                _DOMAIN_INTERFACE_INPUT,
                request.targetUidId,
                request.interfaceNameId,
                entranceLeaf.portKey,
                entranceLeaf.hookKey
            )
        );
        if (recomputed != entranceLeaf.leafHash) {
            revert DockInterfaceLeafMismatch(entranceLeaf.leafHash, recomputed);
        }
        if (entranceLeaf.hookKey != request.targetHookId || entranceLeaf.portKey != entrancePortKey) {
            revert DockEntranceLeafMismatch(entranceLeaf.portKey);
        }
        return entranceLeaf.leafHash;
    }

    function _verifyOutputPortMembership(
        bytes32 targetUidId,
        bytes32 interfaceNameId,
        DockOutputBindingArg calldata binding,
        bytes32 outputsRoot
    ) private pure returns (bytes32) {
        bytes32 outputPortLeaf = keccak256(
            abi.encode(
                _DOMAIN_INTERFACE_OUTPUT,
                targetUidId,
                interfaceNameId,
                binding.portKey,
                binding.targetSourceId,
                binding.targetSignalId
            )
        );
        if (!DockMerkle.verify(outputsRoot, outputPortLeaf, binding.portProof)) {
            revert DockInterfaceLeafMismatch(outputPortLeaf, outputsRoot);
        }
        return outputPortLeaf;
    }

    function _verifyOutputVocabulary(
        bytes32 targetPlanId,
        DockOutputBindingArg[] calldata outputs,
        IUVPStateMachineCore.FactAttribution[] calldata outputAttributions
    ) private view {
        if (!planMetadataModule.hasCapabilityVocabulary(targetPlanId)) {
            return;
        }
        if (outputAttributions.length != outputs.length) {
            revert DockOutputFactNotDeclared(targetPlanId, bytes32(0), bytes32(0));
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            IUVPStateMachineCore.FactAttribution calldata attribution = outputAttributions[i];
            if (
                attribution.sourceId != outputs[i].targetSourceId || attribution.signalId != outputs[i].targetSignalId
                    || attribution.stageId == bytes32(0)
                    || !planMetadataModule.verifySignalCapability(
                        targetPlanId,
                        attribution.stageId,
                        outputs[i].targetSourceId,
                        outputs[i].targetSignalId,
                        0,
                        attribution.capabilityProof
                    )
            ) {
                revert DockOutputFactNotDeclared(targetPlanId, outputs[i].targetSourceId, outputs[i].targetSignalId);
            }
        }
    }

    function _verifyTargetInterface(OpenDockRequestV2 calldata request, DockInterfaceProofV2 calldata interfaceProof)
        private
        view
        returns (bool)
    {
        return planMetadataModule.verifyDockInterfacePort(
            request.targetPlanId,
            request.targetUidId,
            request.interfaceNameId,
            interfaceProof.commitment.orderModesWord,
            interfaceProof.commitment.inputsRoot,
            interfaceProof.commitment.outputsRoot,
            interfaceProof.interfaceProof
        );
    }

    function _dockInstanceId(OpenDockRequestV2 calldata request, bytes32 runtimeDomain) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                request.localPlanId,
                request.localDefinitionRefHash,
                request.localOrderId,
                request.routeId,
                request.routeHash,
                uint256(DOCK_MODE_NEW),
                request.interfaceNameId,
                request.targetPlanId
            )
        );
    }

    function _dockInstanceIdExisting(AttachDockRequestV1 calldata request, bytes32 runtimeDomain)
        private
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                request.localPlanId,
                request.localDefinitionRefHash,
                request.localOrderId,
                request.routeId,
                request.routeHash,
                uint256(DOCK_MODE_EXISTING),
                request.interfaceNameId,
                request.targetPlanId,
                request.linkedOrderId
            )
        );
    }

    function _inputPayloadHash(
        bytes32 dockInstanceId,
        bytes32 routeHash,
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 localStageId,
        bytes32 localHookId,
        bytes32 targetPlanId,
        bytes32 linkedOrderId,
        bytes32 targetPortKey,
        bytes32 targetSignalId
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_INPUT_PAYLOAD,
                dockInstanceId,
                routeHash,
                localPlanId,
                localOrderId,
                localStageId,
                localHookId,
                targetPlanId,
                linkedOrderId,
                targetPortKey,
                targetSignalId,
                uint256(0),
                _DOMAIN_SOURCE_FACT_SET_ZERO
            )
        );
    }

    function _requireUniqueInputTargets(bytes32 dockInstanceId, AttachInputBindingArg[] calldata inputs)
        private
        pure
    {
        bytes32[] memory seenTargetFacts = new bytes32[](inputs.length);
        uint256 seenTargetFactCount;
        for (uint256 i = 0; i < inputs.length; i++) {
            bytes32 targetFactKey = keccak256(abi.encode(inputs[i].targetSourceId, inputs[i].targetSignalId));
            for (uint256 j = 0; j < seenTargetFactCount; j++) {
                if (seenTargetFacts[j] == targetFactKey) {
                    revert DockInputConflict(dockInstanceId, inputs[i].bindingHash);
                }
            }
            seenTargetFacts[seenTargetFactCount] = targetFactKey;
            seenTargetFactCount += 1;
        }
    }

    function _recomputeInputBinding(bytes32 routeId, bytes32 interfaceNameId, DockInputBindingArg calldata binding)
        private
        pure
        returns (bytes32)
    {
        bytes32 recomputed = _inputBindingHash(
            routeId,
            interfaceNameId,
            binding.localHookId,
            binding.portKey,
            binding.targetSourceId,
            binding.targetSignalId
        );
        if (recomputed != binding.bindingHash) {
            revert DockRouteLeafMismatch(binding.bindingHash, recomputed);
        }
        return recomputed;
    }

    function _recomputeOutputBinding(bytes32 routeId, bytes32 interfaceNameId, DockOutputBindingArg calldata binding)
        private
        pure
    {
        bytes32 recomputed = _outputBindingHash(
            routeId,
            interfaceNameId,
            binding.localSourceId,
            binding.localSignalId,
            binding.portKey,
            binding.targetSourceId,
            binding.targetSignalId
        );
        if (recomputed != binding.bindingHash) {
            revert DockRouteLeafMismatch(binding.bindingHash, recomputed);
        }
    }

    function _inputBindingHash(
        bytes32 routeId,
        bytes32 interfaceNameId,
        bytes32 localHookId,
        bytes32 portKey,
        bytes32 targetSourceId,
        bytes32 targetSignalId
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_INPUT_BINDING, routeId, interfaceNameId, localHookId, portKey, targetSourceId, targetSignalId
            )
        );
    }

    function _outputBindingHash(
        bytes32 routeId,
        bytes32 interfaceNameId,
        bytes32 localSourceId,
        bytes32 localSignalId,
        bytes32 portKey,
        bytes32 targetSourceId,
        bytes32 targetSignalId
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_OUTPUT_BINDING,
                routeId,
                interfaceNameId,
                localSourceId,
                localSignalId,
                portKey,
                targetSourceId,
                targetSignalId
            )
        );
    }

    function _routeHash(
        bytes32 localDefinitionRefHash,
        bytes32 targetSlotWord,
        bytes32 targetPlanIdWord,
        bytes32 interfaceNameId,
        uint256 modeWord,
        bytes32 inputsRoot,
        bytes32 outputsRoot
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_ROUTE,
                localDefinitionRefHash,
                targetSlotWord,
                targetPlanIdWord,
                interfaceNameId,
                modeWord,
                inputsRoot,
                outputsRoot
            )
        );
    }

    function _inputsRoot(DockInputBindingArg[] calldata inputs) private pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            leaves[i] = inputs[i].bindingHash;
        }
        return DockMerkle.root(leaves);
    }

    function _outputsRoot(DockOutputBindingArg[] calldata outputs) private pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](outputs.length);
        for (uint256 i = 0; i < outputs.length; i++) {
            leaves[i] = outputs[i].bindingHash;
        }
        return DockMerkle.root(leaves);
    }
}
