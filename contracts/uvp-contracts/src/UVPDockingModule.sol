// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";

/// @title UVPDockingModule v2 — 统一 Zhixu DockRoute（PRD93-95）
/// @notice v2 是破坏性重构（系统未上线，clean break）：
///          - 删除 linkDockedOrder/linkDockedOrderFor 手工 link；
///          - 所有 Zhixu dock 来自 committed route：openDockedOrder 在一笔
///            交易内原子完成 child 创建、link 登记、entrance fact 写入；
///          - submitDockedInput / submitDockedSignal permissionless：keeper
///            只提交可从链上 committed 状态推导的数据，无法自选内容。
///
/// 哈希域（与 Rust uvp-compiler::dock / TS compiler/src/dock.ts 逐字节一致）：
///   inputLeaf   = H("UVP_DOCK_INTERFACE_INPUT_V1",  defRef, portKey, kind, hookKey, sourceId, signalId, access)
///   routeId     = H("UVP_DOCK_ROUTE_ID_V1", localDefRef, stageKey)
///   inputBind   = H("UVP_DOCK_INPUT_BINDING_V1",  routeId, localHookId, portKey, targetSourceId, targetSignalId)
///   outputBind  = H("UVP_DOCK_OUTPUT_BINDING_V1", routeId, localSourceId, localSignalId, portKey,
///                    targetSourceId, targetSignalId)
///   routeHash   = H("UVP_DOCK_ROUTE_V1", routeId, targetDefRef, targetArtifactHash, targetInterfaceRoot,
///                    targetPlanId, idPolicy(0), sourceSeam, entranceBinding, access, inputsRoot, outputsRoot)
///   dockInst    = H("UVP_DOCK_INSTANCE_V1", runtimeDomain, localPlanId, localDefRef, localOrderKey, routeId, routeHash)
///   linkedOrder = H("UVP_DOCK_ORDER_V1", dockInstanceId, targetDefRef)
///   inputIdem   = H("UVP_DOCK_INPUT_IDEMPOTENCY_V1", dockInstanceId, inputBindingHash, occurrence(0))
///   outputIdem  = H("UVP_DOCK_OUTPUT_IDEMPOTENCY_V1", dockInstanceId, outputBindingHash, targetFactId)
contract UVPDockingModule {
    // ------------------------------------------------------------------
    // 类型
    // ------------------------------------------------------------------

    struct OpenDockRequestV1 {
        bytes32 dockInstanceId;
        bytes32 localPlanId;
        bytes32 localOrderId;
        bytes32 localStageId;
        bytes32 localHookId; // entrance 本地 hook（EMIT_READY，已 Ready）
        bytes32 localDefinitionRefHash; // 父定义身份（dockInstanceId preimage）
        bytes32 routeId;
        bytes32 routeHash;
        bytes32 targetDefinitionRefHash;
        bytes32 targetArtifactHash;
        bytes32 targetInterfaceRoot;
        bytes32 sourceSeamId;
        bytes32 entrancePortKey;
        bytes32 entranceBindingHash;
        uint8 accessPolicy; // 0=open 1=permit
        bytes32 inputsRoot;
        bytes32 outputsRoot;
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        bytes32 targetStageId;
        bytes32 targetHookId;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        // PRD95 §3.1：payload/idempotency 不接受调用方自报——全部由
        // committed route/binding + envelope word 重算，keeper 无法替换
        // 事实内容。
        uint8 parentDepth;
    }

    /// 目标接口 entrance 叶子（内容 + membership proof 分开提供）。
    struct DockInterfaceLeafV1 {
        bytes32 leafHash;
        bytes32 portKey;
        uint8 kind; // 1=entrance
        bytes32 hookKey;
        bytes32 sourceId;
        bytes32 signalId;
        uint8 accessPolicy;
    }

    struct DockInputBindingArg {
        bytes32 localHookId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        uint8 kind; // 0=signal 1=entrance
        bytes32 bindingHash;
    }

    struct DockOutputBindingArg {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        uint8 terminal; // 0=none 1=success 2=failure 3=cancelled
        bytes32 bindingHash;
    }

    struct EntrancePermitV1 {
        uint256 nonce;
        uint256 deadline;
        bytes signature; // accessPolicy=open 时允许为空
    }

    struct ActiveDockV1 {
        bytes32 localPlanId;
        bytes32 localOrderId;
        bytes32 localStageId;
        bytes32 routeId;
        bytes32 routeHash;
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        bytes32 sourceSeamId;
        bytes32 inputsRoot;
        bytes32 outputsRoot;
        uint8 depth;
        uint8 status; // 0=Opened 1=Terminal
        bool exists;
    }

    struct ActiveDockInputBindingV1 {
        bytes32 localHookId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        uint8 kind;
        bool exists;
    }

    struct ActiveDockOutputBindingV1 {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        uint8 terminal;
        bool exists;
    }

    // ------------------------------------------------------------------
    // 错误
    // ------------------------------------------------------------------

    error DockAlreadyOpened(bytes32 dockInstanceId);
    error DockBindingLimitExceeded(uint256 count, uint256 limit);
    error DockEndpointOccupied(bytes32 endpointKey);
    error DockInputAlreadyDelivered(bytes32 dockInstanceId, bytes32 inputBindingHash);
    error DockInputConflict(bytes32 dockInstanceId, bytes32 inputBindingHash);
    error DockInputHookNotReady(bytes32 localPlanId, bytes32 localOrderId, bytes32 localHookId);
    error DockInputKindMismatch(bytes32 inputBindingHash);
    error DockInputNotFound(bytes32 dockInstanceId, bytes32 inputBindingHash);
    error DockNotOpened(bytes32 dockInstanceId);
    error DockOutputAlreadyDelivered(bytes32 dockInstanceId, bytes32 outputBindingHash);
    error DockOutputBindingNotFound(bytes32 dockInstanceId, bytes32 outputBindingHash);
    error DockOutputNotReady(bytes32 dockInstanceId, bytes32 outputBindingHash);
    error DockRouteLeafMismatch(bytes32 expected, bytes32 actual);
    error DockInterfaceLeafMismatch(bytes32 expected, bytes32 actual);
    error DockDepthExceeded(uint8 parentDepth, uint8 maxDepth);
    error DockDepthMismatch(uint8 claimed, uint8 actual);
    error DockEntranceLeafMismatch(bytes32 field);
    error DockHookNotInputBound(bytes32 localPlanId, bytes32 localOrderId, bytes32 localHookId);
    error DockPermitExpired(uint256 deadline);
    error DockPermitInvalidSigner(address expected, address recovered);
    error DockPermitNonceAlreadyUsed(bytes32 dockInstanceId, uint256 nonce);
    error DockTargetRootMismatch(bytes32 expected, bytes32 actual);
    error DockUnknownLocalOrder();
    error DockUnknownTargetPlan();
    error InvalidHookFlags(uint8 flags);

    // ------------------------------------------------------------------
    // 事件（PRD95 §10.2，全部端点 plan/order + dockInstanceId 可恢复）
    // ------------------------------------------------------------------

    event DockOpened(
        bytes32 indexed dockInstanceId,
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 localPlanId,
        bytes32 targetPlanId,
        bytes32 routeId,
        bytes32 routeHash,
        uint8 depth,
        address opener
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
    event DockTerminal(bytes32 indexed dockInstanceId, uint8 terminal);

    // ------------------------------------------------------------------
    // 常量（PRD96 §3.2 compatibility manifest 冻结）
    // ------------------------------------------------------------------

    uint8 public constant MAX_DOCK_INPUTS = 8;
    uint8 public constant MAX_DOCK_OUTPUTS = 16;
    uint8 public constant MAX_DOCK_DEPTH = 8;
    uint8 public constant DOCK_ACCESS_OPEN = 0;
    uint8 public constant DOCK_ACCESS_PERMIT = 1;
    uint8 public constant DOCK_KIND_SIGNAL = 0;
    uint8 public constant DOCK_KIND_ENTRANCE = 1;
    uint8 public constant SM_FLAG_EMIT_READY = 4;

    bytes32 private constant _DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V1");
    bytes32 private constant _DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant _DOMAIN_SOURCE_FACT_SET_ZERO = bytes32(0);
    bytes32 private constant _DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V1");
    bytes32 private constant _DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V1");
    bytes32 private constant _DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V1");
    bytes32 private constant _DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V1");
    bytes32 private constant _DOMAIN_DOCK_ORDER = keccak256("UVP_DOCK_ORDER_V1");
    // Highest bit is reserved for deterministically-derived dock child
    // orders.  Public MINT/trigger-origin order creation rejects this
    // namespace, so a disclosed linkedOrderId cannot be front-run.
    bytes32 private constant _DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant _DOMAIN_INPUT_IDEMPOTENCY = keccak256("UVP_DOCK_INPUT_IDEMPOTENCY_V1");
    bytes32 private constant _DOMAIN_INPUT_PAYLOAD = keccak256("UVP_DOCK_INPUT_PAYLOAD_V1");
    bytes32 private constant _DOMAIN_OUTPUT_IDEMPOTENCY = keccak256("UVP_DOCK_OUTPUT_IDEMPOTENCY_V1");
    bytes32 private constant _DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPDockingModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("2");
    // creator 不进 permit：open 路由 creator 恒等于目标 plan publisher，
    // 与 permit 验签权威同源（planPublisher(targetPlanId)）。
    bytes32 private constant _PERMIT_TYPEHASH = keccak256(
        "UVPDockEntrancePermitV1(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
    );

    IUVPStateMachineCore public immutable stateMachine;
    IUVPPlanMetadataModule public immutable planMetadataModule;

    mapping(bytes32 dockInstanceId => ActiveDockV1 dock) private _docks;
    mapping(bytes32 dockInstanceId => mapping(bytes32 inputBindingHash => ActiveDockInputBindingV1 binding)) private
        _inputBindings;
    mapping(bytes32 dockInstanceId => mapping(bytes32 outputBindingHash => ActiveDockOutputBindingV1 binding)) private
        _outputBindings;
    mapping(bytes32 dockInstanceId => mapping(bytes32 inputBindingHash => bool delivered)) private _inputDelivered;
    mapping(bytes32 dockInstanceId => mapping(bytes32 outputBindingHash => bool delivered)) private _outputDelivered;
    // unique(localPlanId, localOrderId, localStageId, routeId)
    mapping(bytes32 localRouteInstanceKey => bytes32 dockInstanceId) public dockByLocalRoute;
    // unique(targetPlanId, linkedOrderId)
    mapping(bytes32 targetEndpointKey => bytes32 dockInstanceId) public dockByTargetOrder;
    mapping(bytes32 planId => mapping(bytes32 orderId => uint8 depth)) public dockDepthOfOrder;
    mapping(bytes32 dockInstanceId => uint256 usedPermitNonce) public usedEntrancePermitNonce;

    constructor(address stateMachineAddress, address planMetadataModuleAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
        planMetadataModule = IUVPPlanMetadataModule(planMetadataModuleAddress);
    }

    // ------------------------------------------------------------------
    // openDockedOrder（PRD95 §7）
    // ------------------------------------------------------------------

    function openDockedOrder(
        OpenDockRequestV1 calldata request,
        bytes32[] calldata routeProof,
        DockInterfaceLeafV1 calldata entranceLeaf,
        bytes32[] calldata interfaceProof,
        DockInputBindingArg[] calldata inputs,
        DockOutputBindingArg[] calldata outputs,
        EntrancePermitV1 calldata permit
    ) external returns (bool opened) {
        // 1. 父订单存在。
        if (!stateMachine.orderExists(request.localPlanId, request.localOrderId)) {
            revert DockUnknownLocalOrder();
        }
        // 2. 父 entrance 本地 hook：属于 localStageId、带 EMIT_READY、已 Ready。
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

        // routeId 重算：H(UVP_DOCK_ROUTE_ID_V1, localDefRef, stageKey)。
        bytes32 recomputedRouteId =
            keccak256(abi.encode(_DOMAIN_ROUTE_ID, request.localDefinitionRefHash, request.localStageId));
        if (recomputedRouteId != request.routeId) {
            revert DockRouteLeafMismatch(request.routeId, recomputedRouteId);
        }

        // 3/4. routeHash 重算 + membership proof（父 plan 的 dockRoutesRoot）。
        bytes32 recomputedEntranceBinding = _inputBindingHash(
            request.routeId,
            request.localHookId,
            request.entrancePortKey,
            request.targetSourceId,
            request.targetSignalId,
            DOCK_KIND_ENTRANCE
        );
        if (recomputedEntranceBinding != request.entranceBindingHash) {
            revert DockRouteLeafMismatch(request.entranceBindingHash, recomputedEntranceBinding);
        }
        if (inputs.length > MAX_DOCK_INPUTS || inputs.length == 0 || outputs.length > MAX_DOCK_OUTPUTS) {
            revert DockBindingLimitExceeded(
                inputs.length > MAX_DOCK_INPUTS || inputs.length == 0 ? inputs.length : outputs.length,
                inputs.length > MAX_DOCK_INPUTS || inputs.length == 0 ? MAX_DOCK_INPUTS : MAX_DOCK_OUTPUTS
            );
        }
        bytes32 recomputedInputsRoot = _inputsRoot(inputs);
        bytes32 recomputedOutputsRoot = _outputsRoot(outputs);
        bytes32 recomputedRouteHash = _routeHash(
            request.routeId,
            request.targetDefinitionRefHash,
            request.targetArtifactHash,
            request.targetInterfaceRoot,
            request.targetPlanId,
            request.sourceSeamId,
            request.entranceBindingHash,
            request.accessPolicy,
            recomputedInputsRoot,
            recomputedOutputsRoot
        );
        if (recomputedRouteHash != request.routeHash) {
            revert DockRouteLeafMismatch(request.routeHash, recomputedRouteHash);
        }
        if (!planMetadataModule.verifyDockRoute(request.localPlanId, request.routeHash, routeProof)) {
            revert DockRouteLeafMismatch(request.routeHash, bytes32(0));
        }

        // 5. 目标 plan 已 finalized，且其 committed dockInterfaceRoot 与
        //    route 固定的 targetInterfaceRoot 一致。
        if (!stateMachine.planExists(request.targetPlanId)) {
            revert DockUnknownTargetPlan();
        }
        bytes32 committedInterfaceRoot = planMetadataModule.dockInterfaceRoot(request.targetPlanId);
        if (committedInterfaceRoot != request.targetInterfaceRoot) {
            revert DockTargetRootMismatch(request.targetInterfaceRoot, committedInterfaceRoot);
        }
        // 6/7. entrance 叶子：kind、hook/stage/signal 与 request 一致。
        bytes32 recomputedLeaf = keccak256(
            abi.encode(
                _DOMAIN_INTERFACE_INPUT,
                request.targetDefinitionRefHash,
                entranceLeaf.portKey,
                entranceLeaf.kind,
                entranceLeaf.hookKey,
                entranceLeaf.sourceId,
                entranceLeaf.signalId,
                entranceLeaf.accessPolicy
            )
        );
        if (recomputedLeaf != entranceLeaf.leafHash) {
            revert DockInterfaceLeafMismatch(entranceLeaf.leafHash, recomputedLeaf);
        }
        if (!planMetadataModule.verifyDockInterfacePort(request.targetPlanId, entranceLeaf.leafHash, interfaceProof)) {
            revert DockInterfaceLeafMismatch(entranceLeaf.leafHash, bytes32(0));
        }
        if (entranceLeaf.kind != DOCK_KIND_ENTRANCE || entranceLeaf.accessPolicy != request.accessPolicy) {
            revert DockEntranceLeafMismatch(bytes32(uint256(entranceLeaf.kind)));
        }
        if (
            entranceLeaf.hookKey != request.targetHookId || entranceLeaf.sourceId != request.targetSourceId
                || entranceLeaf.signalId != request.targetSignalId || entranceLeaf.portKey != request.entrancePortKey
        ) {
            revert DockEntranceLeafMismatch(entranceLeaf.portKey);
        }

        // 8. 身份推导重算（keeper 不可自报 ID）。localOrderKey 为 bytes32
        //    order id 本身（EVM 轨订单键即 word）。
        bytes32 runtimeDomain = keccak256(abi.encode(_DOMAIN_RUNTIME_EIP155, block.chainid, address(stateMachine)));
        bytes32 recomputedDockInstance = keccak256(
            abi.encode(
                _DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                request.localPlanId,
                request.localDefinitionRefHash,
                request.localOrderId,
                request.routeId,
                request.routeHash
            )
        );
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
            return false; // 幂等重放：同一 dock 重复 open 无副作用
        }

        // 9. permit（open 无需签名；permit 校验目标 entrance authority）。
        //    必须在 dock 幂等检查之后，避免重放已成功的 permit 因 nonce
        //    已消费而回退，而不是按接口约定返回 false。
        if (request.accessPolicy == DOCK_ACCESS_PERMIT) {
            _verifyEntrancePermit(request, permit);
        } else if (request.accessPolicy != DOCK_ACCESS_OPEN) {
            revert DockEntranceLeafMismatch(bytes32(uint256(request.accessPolicy)));
        }

        // 10. 深度（父订单真实 dock 深度为权威，不信任请求自报值）。
        uint8 parentDepth = dockDepthOfOrder[request.localPlanId][request.localOrderId];
        if (parentDepth != request.parentDepth) {
            revert DockDepthMismatch(request.parentDepth, parentDepth);
        }
        if (parentDepth >= MAX_DOCK_DEPTH) {
            revert DockDepthExceeded(parentDepth, MAX_DOCK_DEPTH);
        }

        // 11. 唯一性：本 route instance 未绑定 child；目标 endpoint 未占用。
        bytes32 localRouteInstanceKey =
            keccak256(abi.encode(request.localPlanId, request.localOrderId, request.localStageId, request.routeId));
        bytes32 targetEndpointKey = keccak256(abi.encode(request.targetPlanId, request.linkedOrderId));
        if (dockByLocalRoute[localRouteInstanceKey] != bytes32(0)) {
            revert DockEndpointOccupied(localRouteInstanceKey);
        }
        if (dockByTargetOrder[targetEndpointKey] != bytes32(0)) {
            revert DockEndpointOccupied(targetEndpointKey);
        }
        // 12. 恰好一个 entrance + 逐 binding 重算。
        uint256 entranceCount;
        for (uint256 i = 0; i < inputs.length; i++) {
            bytes32 recomputed = _inputBindingHash(
                request.routeId,
                inputs[i].localHookId,
                inputs[i].portKey,
                inputs[i].targetSourceId,
                inputs[i].targetSignalId,
                inputs[i].kind
            );
            if (recomputed != inputs[i].bindingHash) {
                revert DockRouteLeafMismatch(inputs[i].bindingHash, recomputed);
            }
            if (inputs[i].kind == DOCK_KIND_ENTRANCE) {
                entranceCount += 1;
            }
        }
        if (entranceCount != 1) {
            revert DockInputKindMismatch(request.entranceBindingHash);
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            bytes32 recomputed = _outputBindingHash(
                request.routeId,
                outputs[i].localSourceId,
                outputs[i].localSignalId,
                outputs[i].portKey,
                outputs[i].targetSourceId,
                outputs[i].targetSignalId,
                outputs[i].terminal
            );
            if (recomputed != outputs[i].bindingHash) {
                revert DockRouteLeafMismatch(outputs[i].bindingHash, recomputed);
            }
        }

        // ---- 原子效果（PRD95 §7.3）：任一步 revert 全部回滚 ----
        _docks[request.dockInstanceId] = ActiveDockV1({
            localPlanId: request.localPlanId,
            localOrderId: request.localOrderId,
            localStageId: request.localStageId,
            routeId: request.routeId,
            routeHash: request.routeHash,
            targetPlanId: request.targetPlanId,
            linkedOrderId: request.linkedOrderId,
            sourceSeamId: request.sourceSeamId,
            inputsRoot: recomputedInputsRoot,
            outputsRoot: recomputedOutputsRoot,
            depth: parentDepth + 1,
            status: 0,
            exists: true
        });
        for (uint256 i = 0; i < inputs.length; i++) {
            _inputBindings[request.dockInstanceId][inputs[i].bindingHash] = ActiveDockInputBindingV1({
                localHookId: inputs[i].localHookId,
                portKey: inputs[i].portKey,
                targetSourceId: inputs[i].targetSourceId,
                targetSignalId: inputs[i].targetSignalId,
                kind: inputs[i].kind,
                exists: true
            });
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            _outputBindings[request.dockInstanceId][outputs[i].bindingHash] = ActiveDockOutputBindingV1({
                localSourceId: outputs[i].localSourceId,
                localSignalId: outputs[i].localSignalId,
                portKey: outputs[i].portKey,
                targetSourceId: outputs[i].targetSourceId,
                targetSignalId: outputs[i].targetSignalId,
                terminal: outputs[i].terminal,
                exists: true
            });
        }
        dockByLocalRoute[localRouteInstanceKey] = request.dockInstanceId;
        dockByTargetOrder[targetEndpointKey] = request.dockInstanceId;
        dockDepthOfOrder[request.targetPlanId][request.linkedOrderId] = parentDepth + 1;

        bytes32 entrancePayloadHash = _inputPayloadHash(
            request.dockInstanceId,
            request.routeHash,
            request.localPlanId,
            request.localOrderId,
            request.localStageId,
            request.localHookId,
            request.targetPlanId,
            request.linkedOrderId,
            request.entrancePortKey,
            request.targetSignalId
        );
        bytes32 entranceIdempotencyKey = keccak256(
            abi.encode(_DOMAIN_INPUT_IDEMPOTENCY, request.dockInstanceId, request.entranceBindingHash, uint256(0))
        );

        // PRD95 §18：keeper 只提供活性。creator 与子订单授权不得由 keeper
        // 自选——open 路由 creator = 目标 plan publisher；permit 路由
        // creator = permit 签名者。子订单信号授权随后按目标定义自身的
        // 授权流（executor patch/submitSignalFor）建立，不经 open 注入。
        address creator = stateMachine.planPublisher(request.targetPlanId);
        stateMachine.createDockedOrderFromModule(
            request.targetPlanId,
            request.linkedOrderId,
            creator,
            msg.sender,
            request.targetHookId,
            request.targetStageId,
            request.targetSourceId,
            request.targetSignalId,
            entrancePayloadHash,
            entranceIdempotencyKey,
            msg.sender,
            new IUVPStateMachineCore.SignalAuthorization[](0)
        );

        emit DockOpened(
            request.dockInstanceId,
            request.localOrderId,
            request.linkedOrderId,
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
            request.entranceBindingHash,
            request.localPlanId,
            request.localOrderId,
            request.targetPlanId,
            request.targetSignalId,
            entrancePayloadHash,
            msg.sender
        );
        return true;
    }

    // ------------------------------------------------------------------
    // submitDockedInput（PRD95 §8）
    // ------------------------------------------------------------------

    function submitDockedInput(bytes32 dockInstanceId, bytes32 localHookId, bytes32 inputBindingHash)
        external
        returns (bool submitted)
    {
        ActiveDockV1 storage dock = _docks[dockInstanceId];
        if (!dock.exists) {
            revert DockNotOpened(dockInstanceId);
        }
        if (_inputDelivered[dockInstanceId][inputBindingHash]) {
            return false; // 幂等重放
        }
        if (dock.status != 0) {
            revert DockInputConflict(dockInstanceId, inputBindingHash); // 终态后不再接受 signal input
        }
        ActiveDockInputBindingV1 storage binding = _inputBindings[dockInstanceId][inputBindingHash];
        if (!binding.exists) {
            revert DockInputNotFound(dockInstanceId, inputBindingHash);
        }
        if (binding.kind != DOCK_KIND_SIGNAL) {
            revert DockInputKindMismatch(inputBindingHash);
        }
        if (binding.localHookId != localHookId) {
            revert DockHookNotInputBound(dock.localPlanId, dock.localOrderId, localHookId);
        }
        // 父 hook 已 Ready（EMIT_READY 是 input dispatch 边）。
        uint8 hookFlags = stateMachine.planHookFlags(dock.localPlanId, localHookId);
        if (hookFlags & SM_FLAG_EMIT_READY == 0) {
            revert DockHookNotInputBound(dock.localPlanId, dock.localOrderId, localHookId);
        }
        (,, bool readyEmitted) = stateMachine.getHookStatus(dock.localPlanId, dock.localOrderId, localHookId);
        if (!readyEmitted) {
            revert DockInputHookNotReady(dock.localPlanId, dock.localOrderId, localHookId);
        }
        // 目标 mailbox fact 尚未写入；冲突 = 不同 provenance 的既有事实。
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
        stateMachine.recordDockedInputFromModule(
            dock.targetPlanId,
            dock.linkedOrderId,
            binding.targetSourceId,
            binding.targetSignalId,
            payloadHash,
            idempotencyKey,
            msg.sender
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
            msg.sender
        );
        return true;
    }

    // ------------------------------------------------------------------
    // submitDockedSignal（PRD95 §9）
    // ------------------------------------------------------------------

    function submitDockedSignal(bytes32 dockInstanceId, bytes32 outputBindingHash) external returns (bool submitted) {
        ActiveDockV1 storage dock = _docks[dockInstanceId];
        if (!dock.exists) {
            revert DockNotOpened(dockInstanceId);
        }
        if (_outputDelivered[dockInstanceId][outputBindingHash]) {
            return false; // 幂等重放
        }
        ActiveDockOutputBindingV1 storage binding = _outputBindings[dockInstanceId][outputBindingHash];
        if (!binding.exists) {
            revert DockOutputBindingNotFound(dockInstanceId, outputBindingHash);
        }
        // 目标事实必须真实存在；payload/submitter 全部读取自 StateMachine
        // 存储，keeper 无法替换（PRD95 §21 安全清单）。
        (bool exists, bytes32 payloadHash,,, address originalSubmitter) = stateMachine.getSignal(
            dock.targetPlanId, dock.linkedOrderId, binding.targetSourceId, binding.targetSignalId
        );
        if (!exists) {
            revert DockOutputNotReady(dockInstanceId, outputBindingHash);
        }
        bytes32 targetFactId = keccak256(abi.encode(binding.targetSourceId, binding.targetSignalId));
        bytes32 idempotencyKey =
            keccak256(abi.encode(_DOMAIN_OUTPUT_IDEMPOTENCY, dockInstanceId, outputBindingHash, targetFactId));

        _outputDelivered[dockInstanceId][outputBindingHash] = true;
        stateMachine.submitSignalFromModule(
            dock.localPlanId,
            dock.localOrderId,
            binding.localSourceId,
            binding.localSignalId,
            payloadHash,
            idempotencyKey,
            originalSubmitter
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
        if (binding.terminal != 0 && dock.status != 1) {
            dock.status = 1;
            emit DockTerminal(dockInstanceId, binding.terminal);
        }
        return true;
    }

    // ------------------------------------------------------------------
    // 视图
    // ------------------------------------------------------------------

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
            uint8 depth,
            uint8 status,
            bool exists
        )
    {
        ActiveDockV1 storage dock = _docks[dockInstanceId];
        return (
            dock.localPlanId,
            dock.localOrderId,
            dock.localStageId,
            dock.routeId,
            dock.routeHash,
            dock.targetPlanId,
            dock.linkedOrderId,
            dock.depth,
            dock.status,
            dock.exists
        );
    }

    function getDockInputBinding(bytes32 dockInstanceId, bytes32 inputBindingHash)
        external
        view
        returns (
            bytes32 localHookId,
            bytes32 portKey,
            bytes32 targetSourceId,
            bytes32 targetSignalId,
            uint8 kind,
            bool exists
        )
    {
        ActiveDockInputBindingV1 storage binding = _inputBindings[dockInstanceId][inputBindingHash];
        return (
            binding.localHookId,
            binding.portKey,
            binding.targetSourceId,
            binding.targetSignalId,
            binding.kind,
            binding.exists
        );
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
            uint8 terminal,
            bool exists
        )
    {
        ActiveDockOutputBindingV1 storage binding = _outputBindings[dockInstanceId][outputBindingHash];
        return (
            binding.localSourceId,
            binding.localSignalId,
            binding.portKey,
            binding.targetSourceId,
            binding.targetSignalId,
            binding.terminal,
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

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    function _verifyEntrancePermit(OpenDockRequestV1 calldata request, EntrancePermitV1 calldata permit) private {
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
                request.entrancePortKey,
                request.localPlanId,
                request.routeHash,
                request.dockInstanceId,
                request.linkedOrderId,
                uint256(0), // feeLimit：无费用机制时固定 0（PRD96 §15.5）
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
        assembly {
            r := mload(add(signature, 0x20))
            sigS := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (v < 27) {
            v += 27;
        }
        address recovered = ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: sigS}));
        if (recovered != authority) {
            revert DockPermitInvalidSigner(authority, recovered);
        }
        usedEntrancePermitNonce[request.dockInstanceId] = permit.nonce;
    }

    /// PRD95 §3.1 envelope：全部 word 来自 committed route/binding/dock
    /// 存储。sequence 固定 0。
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

    function _inputBindingHash(
        bytes32 routeId,
        bytes32 localHookId,
        bytes32 portKey,
        bytes32 targetSourceId,
        bytes32 targetSignalId,
        uint8 kind
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_INPUT_BINDING, routeId, localHookId, portKey, targetSourceId, targetSignalId, uint256(kind)
            )
        );
    }

    function _outputBindingHash(
        bytes32 routeId,
        bytes32 localSourceId,
        bytes32 localSignalId,
        bytes32 portKey,
        bytes32 targetSourceId,
        bytes32 targetSignalId,
        uint8 terminal
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_OUTPUT_BINDING,
                routeId,
                localSourceId,
                localSignalId,
                portKey,
                targetSourceId,
                targetSignalId,
                uint256(terminal)
            )
        );
    }

    function _routeHash(
        bytes32 routeId,
        bytes32 targetDefinitionRefHash,
        bytes32 targetArtifactHash,
        bytes32 targetInterfaceRoot,
        bytes32 targetPlanId,
        bytes32 sourceSeamId,
        bytes32 entranceBindingHash,
        uint8 accessPolicy,
        bytes32 inputsRoot,
        bytes32 outputsRoot
    ) private pure returns (bytes32) {
        // PRD95 §5.2：route leaf 提交目标 plan。targetPlanId 参与 preimage，
        // 使 openDockedOrder 的 routeHash 重算绑定 target plan——keeper 无法
        // 把 child 开到别的 plan（即使该 plan 复制了同样的 interface root）。
        return keccak256(
            abi.encode(
                _DOMAIN_ROUTE,
                routeId,
                targetDefinitionRefHash,
                targetArtifactHash,
                targetInterfaceRoot,
                targetPlanId,
                uint256(0), // idPolicy derived-v1
                sourceSeamId,
                entranceBindingHash,
                uint256(accessPolicy),
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
