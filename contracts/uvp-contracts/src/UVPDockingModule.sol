// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";

/// @title UVPDockingModule — 统一 Zhixu DockRoute（abiVersion 4.0）
/// @notice 所有 Zhixu dock 来自 committed route：openDockedOrder 在一笔
///          交易内原子完成 child 创建、link 登记、entrance fact 写入；
///          submitDockedInput / submitDockedSignal permissionless：keeper
///          只提交可从链上 committed 状态推导的数据，无法自选内容。
///          链轨只支持 order mode new（建单型委托）：routeHash 与
///          dockInstanceId 的 modeWord 槽位被钉为 new(0)，existing 模式
///          route 的哈希在重算处直接失配（显式拒绝，不静默降级）。
///
/// 哈希域（与 Rust uvp-compiler::dock / TS compiler/src/dock.ts 逐字节一致，
/// word 布局见 packages/compiler/docs/dock-word-layout.md；字符串 word 一律 keccak256(utf8(s))，
/// 整数 word 大端右对齐）：
///   defRef      = H("UVP_DEFINITION_REF_V1",         uidId)
///   portLeaf    = H("UVP_DOCK_INTERFACE_INPUT_V2",  uidId, interfaceNameId, portKey, hookKey)
///   interfaceLeaf = H("UVP_DOCK_INTERFACE_V2",      uidId, interfaceNameId, orderModesWord, inputsRoot, outputsRoot)
///   routeId     = H("UVP_DOCK_ROUTE_ID_V1",         localDefRef, stageKey)
///   inputBind   = H("UVP_DOCK_INPUT_BINDING_V2",    routeId, interfaceNameId, localHookId, portKey,
///                    targetSourceId, targetSignalId)
///   outputBind  = H("UVP_DOCK_OUTPUT_BINDING_V2",   routeId, interfaceNameId, localSourceId, localSignalId,
///                    portKey, targetSourceId, targetSignalId)
///   routeHash   = H("UVP_DOCK_ROUTE_V2",            localDefRef, targetDefRef, interfaceNameId,
///                    modeWord(new=0), inputBindingsRoot, outputBindingsRoot)
///   dockInst    = H("UVP_DOCK_INSTANCE_V2",         runtimeDomain, localPlanId, localDefRef, localOrderKey,
///                    routeId, routeHash, modeWord(new=0), interfaceNameId, targetPlanId)
///   linkedOrder = H("UVP_DOCK_ORDER_V1",            dockInstanceId, targetDefRef)
///   inputIdem   = H("UVP_DOCK_INPUT_IDEMPOTENCY_V1",dockInstanceId, inputBindingHash, occurrence(0))
///   outputIdem  = H("UVP_DOCK_OUTPUT_IDEMPOTENCY_V1",dockInstanceId, outputBindingHash, targetFactId)
/// uidId = keccak(zx-<32hex>)；interfaceNameId/portKey = keccak(接口名/端口名)；
/// localHookId/hookKey = keccak("<task>.<stage>#<channel>")；
/// orderModesWord：u8 位掩码 bit0=new、bit1=existing；route modeWord：new=0、existing=1。
/// 目标接口承诺是两级树：端口叶 → 接口 inputsRoot/outputsRoot →
/// interfaceLeaf → plan 的 dockInterfaceRoot（后一级由 planMetadataModule
/// 重算 interfaceLeaf 后验证 membership）。
contract UVPDockingModule {
    // ------------------------------------------------------------------
    // 类型
    // ------------------------------------------------------------------

    struct OpenDockRequestV2 {
        bytes32 dockInstanceId;
        bytes32 localPlanId;
        bytes32 localOrderId;
        bytes32 localStageId;
        bytes32 localHookId; // entrance 本地 hook（EMIT_READY，已 Ready）
        bytes32 localDefinitionRefHash; // 父定义身份（routeId/dockInstanceId preimage）
        bytes32 routeId;
        bytes32 routeHash;
        bytes32 interfaceNameId; // keccak(接口名)：绑定/路由/实例 preimage 与 permit 域
        bytes32 targetUidId; // keccak(zx-uid)：接口叶 preimage + defRef 重算锚
        bytes32 targetDefinitionRefHash; // H(UVP_DEFINITION_REF_V1, targetUidId)
        bytes32 targetPlanId;
        bytes32 linkedOrderId;
        bytes32 targetStageId;
        bytes32 targetHookId; // 目标 mailbox hook word（= 端口叶 hookKey）
        // payload/idempotency 不接受调用方自报——全部由
        // committed route/binding + envelope word 重算，keeper 无法替换
        // 事实内容。
        uint8 parentDepth;
    }

    /// entrance 端口叶（内容 + membership proof 分开提供；sourceId/signalId
    /// 是运行期寻址数据，只进绑定哈希，不入端口叶）。
    struct DockInterfacePortLeafV2 {
        bytes32 leafHash;
        bytes32 portKey;
        bytes32 hookKey;
    }

    /// 被绑定具名接口的承诺输入（interfaceLeaf preimage 的一部分；leaf 由
    /// planMetadataModule 重算，调用方无法自报叶值）。
    struct DockInterfaceCommitmentV2 {
        uint8 orderModesWord; // bit0=new bit1=existing；new 路由要求 bit0
        bytes32 inputsRoot; // merkle(该接口全部 inputPortLeaf_v2)
        bytes32 outputsRoot; // merkle(该接口全部 outputPortLeaf_v2)
    }

    /// 两级接口证明：entrance 端口叶 → 接口 inputsRoot；接口叶 → plan 的
    /// dockInterfaceRoot。聚合为单参数以容纳 open 的校验链栈深。
    struct DockInterfaceProofV2 {
        DockInterfacePortLeafV2 entranceLeaf;
        bytes32[] portProof;
        DockInterfaceCommitmentV2 commitment;
        bytes32[] interfaceProof;
    }

    struct DockInputBindingArg {
        bytes32 localHookId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        bytes32 bindingHash;
    }

    struct DockOutputBindingArg {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        // 接口 output 端口叶的 canonical 输出信号 word：叶内容经 outputsRoot
        // membership 由目标接口承诺背书（调用方不得自报叶值）。
        bytes32 portSignalWord;
        bytes32 bindingHash;
        bytes32[] portProof;
    }

    struct EntrancePermitV2 {
        uint256 nonce;
        uint256 deadline;
        // 空签名 = permissionless open；非空 = 目标 plan publisher 的
        // entrance 预授权（digest 绑定全部 open 端点身份）。
        bytes signature;
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

    // ------------------------------------------------------------------
    // 错误
    // ------------------------------------------------------------------

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
    /// output 绑定的事实键不在目标 plan 声明的产出词表（relation=0
    /// capability）内——错配绑定不得把目标接口未暴露的事实镜像进父单。
    error DockOutputFactNotDeclared(bytes32 targetPlanId, bytes32 targetSourceId, bytes32 targetSignalId);
    error DockHookNotInputBound(bytes32 localPlanId, bytes32 localOrderId, bytes32 localHookId);
    error DockPermitExpired(uint256 deadline);
    error DockPermitInvalidSigner(address expected, address recovered);
    error DockPermitNonceAlreadyUsed(bytes32 dockInstanceId, uint256 nonce);
    error DockTargetIdentityMismatch(bytes32 declared, bytes32 derived);
    error DockUnknownLocalOrder();
    error DockUnknownTargetPlan();

    // ------------------------------------------------------------------
    // 事件（全部端点 plan/order + dockInstanceId 可恢复）
    // ------------------------------------------------------------------

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

    // ------------------------------------------------------------------
    // 常量（compatibility manifest 冻结）
    // ------------------------------------------------------------------

    uint8 public constant MAX_DOCK_OUTPUTS = 16;
    uint8 public constant MAX_DOCK_DEPTH = 8;
    /// route modeWord：new=0。链轨只支持 new；existing(1) 不进任何
    /// 可调用路径（哈希重算钉死 0，失配即拒绝）。
    uint8 public constant DOCK_MODE_NEW = 0;
    /// 接口 orderModesWord 位掩码 bit0=new。new 路由的出生锚要求
    /// 目标接口宣告 new。
    uint8 public constant DOCK_INTERFACE_ORDER_MODE_NEW = 1;
    uint8 public constant SM_FLAG_EMIT_READY = 4;

    bytes32 private constant _DOMAIN_DEFINITION_REF = keccak256("UVP_DEFINITION_REF_V1");
    bytes32 private constant _DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V2");
    bytes32 private constant _DOMAIN_INTERFACE_OUTPUT = keccak256("UVP_DOCK_INTERFACE_OUTPUT_V2");
    bytes32 private constant _DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant _DOMAIN_SOURCE_FACT_SET_ZERO = bytes32(0);
    bytes32 private constant _DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V2");
    bytes32 private constant _DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V2");
    bytes32 private constant _DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V2");
    bytes32 private constant _DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V2");
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
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("4");
    // creator 不进 permit：open 路由 creator 恒等于目标 plan publisher，
    // 与 permit 验签权威同源（planPublisher(targetPlanId)）。
    bytes32 private constant _PERMIT_TYPEHASH = keccak256(
        "UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
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
    // unique(localPlanId, localOrderId, localStageId, routeId)
    mapping(bytes32 localRouteInstanceKey => bytes32 dockInstanceId) public dockByLocalRoute;
    // unique(targetPlanId, linkedOrderId)——链轨只有 new 模式：每 route
    // 恰一个子单，目标端点键即子单出生键。
    mapping(bytes32 targetEndpointKey => bytes32 dockInstanceId) public dockByTargetOrder;
    mapping(bytes32 planId => mapping(bytes32 orderId => uint8 depth)) public dockDepthOfOrder;
    mapping(bytes32 dockInstanceId => uint256 usedPermitNonce) public usedEntrancePermitNonce;

    constructor(address stateMachineAddress, address planMetadataModuleAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
        planMetadataModule = IUVPPlanMetadataModule(planMetadataModuleAddress);
    }

    // ------------------------------------------------------------------
    // openDockedOrder
    // ------------------------------------------------------------------

    function openDockedOrder(
        OpenDockRequestV2 calldata request,
        bytes32[] calldata routeProof,
        DockInterfaceProofV2 calldata interfaceProof,
        DockInputBindingArg[] calldata inputs,
        DockOutputBindingArg[] calldata outputs,
        EntrancePermitV2 calldata permit
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

        // 3. 目标定义身份闭环：接口承诺按 keccak(uid) 寻址，route/linkedOrder
        //    按 definitionRefHash 寻址——两者必须由同一 uid 派生，否则已提交
        //    route 可以指向一个 uid 而把 child 开进另一个 uid 的接口承诺。
        bytes32 derivedTargetDefRef = keccak256(abi.encode(_DOMAIN_DEFINITION_REF, request.targetUidId));
        if (derivedTargetDefRef != request.targetDefinitionRefHash) {
            revert DockTargetIdentityMismatch(request.targetDefinitionRefHash, derivedTargetDefRef);
        }

        // 4. new 模式恰一条 input 绑定（出生锚）。entrance 即 inputs[0]——
        //    不再接受请求级第二份入口声明，矛盾入口无从构造。
        if (inputs.length != 1) {
            revert DockBindingCountInvalid(inputs.length, 1);
        }
        // 就绪门与出生锚同源恒等（与 submitDockedInput 的绑定核对同形）：
        // request.localHookId 只喂就绪判定，绑定哈希与 envelope 以
        // inputs[0].localHookId 为准——两者不一致即兄弟 hook 冒名提前开仓，
        // payloadHash 与链下权威公式分叉。
        if (inputs[0].localHookId != request.localHookId) {
            revert DockHookNotInputBound(request.localPlanId, request.localOrderId, request.localHookId);
        }
        if (outputs.length > MAX_DOCK_OUTPUTS) {
            revert DockBindingLimitExceeded(outputs.length, MAX_DOCK_OUTPUTS);
        }
        bytes32 entranceBindingHash = _recomputeInputBinding(request.routeId, request.interfaceNameId, inputs[0]);
        bytes32 recomputedInputsRoot = _inputsRoot(inputs);
        bytes32 recomputedOutputsRoot = _outputsRoot(outputs);

        // 5. entrance 端口叶：重算 + 与唯一 input 绑定/mailbox hook 一致。
        bytes32 entranceLeafHash = _verifyEntrancePortLeaf(request, interfaceProof.entranceLeaf, inputs[0].portKey);

        // 6. 接口承诺：接口必须宣告 new（路由是 new 模式）；entrance 端口叶
        //    必须在该接口 inputsRoot 内。
        if (interfaceProof.commitment.orderModesWord & DOCK_INTERFACE_ORDER_MODE_NEW == 0) {
            revert DockInterfaceModeUnsupported(interfaceProof.commitment.orderModesWord);
        }
        if (!DockMerkle.verify(interfaceProof.commitment.inputsRoot, entranceLeafHash, interfaceProof.portProof)) {
            revert DockInterfaceLeafMismatch(entranceLeafHash, interfaceProof.commitment.inputsRoot);
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            _recomputeOutputBinding(request.routeId, request.interfaceNameId, outputs[i]);
            // output 端口 membership（input 侧同款二级承诺）：端口叶由承诺
            // 输入重算，必须落在目标接口 outputsRoot 内——否则已提交 route
            // 可把输出绑到目标接口从未宣告的端口（只重算绑定哈希入 routeHash
            // 不构成目标侧承诺）。
            bytes32 outputPortLeaf = keccak256(
                abi.encode(
                    _DOMAIN_INTERFACE_OUTPUT,
                    request.targetUidId,
                    request.interfaceNameId,
                    outputs[i].portKey,
                    outputs[i].portSignalWord
                )
            );
            if (!DockMerkle.verify(interfaceProof.commitment.outputsRoot, outputPortLeaf, outputs[i].portProof)) {
                revert DockInterfaceLeafMismatch(outputPortLeaf, interfaceProof.commitment.outputsRoot);
            }
        }

        // 7. routeHash 重算：modeWord 钉 new(0)——existing 路由的哈希在此
        //    失配（链轨对不支持模式的显式拒绝面）。
        bytes32 recomputedRouteHash = _routeHash(
            request.localDefinitionRefHash,
            request.targetDefinitionRefHash,
            request.interfaceNameId,
            recomputedInputsRoot,
            recomputedOutputsRoot
        );
        if (recomputedRouteHash != request.routeHash) {
            revert DockRouteLeafMismatch(request.routeHash, recomputedRouteHash);
        }
        if (!planMetadataModule.verifyDockRoute(request.localPlanId, request.routeHash, routeProof)) {
            revert DockRouteLeafMismatch(request.routeHash, bytes32(0));
        }

        // 8. 目标 plan 已 finalized，且其 dockInterfaceRoot 承诺被绑定的
        //    具名接口（接口叶由 planMetadataModule 重算，membership 由
        //    interfaceProof.interfaceProof 证明）。
        if (!stateMachine.planExists(request.targetPlanId)) {
            revert DockUnknownTargetPlan();
        }
        if (!_verifyTargetInterface(request, interfaceProof)) {
            revert DockInterfaceLeafMismatch(entranceLeafHash, bytes32(0));
        }
        // 8.5 出生锚事实键一致性：entrance 事实键必须是目标 mailbox hook 声明
        //     的 SIGNAL 依赖原子（目标 plan 的 receive 词表）。接口端口叶只
        //     承诺 (portKey, hookKey)，事实键只进绑定哈希——不钉在 hook 依赖
        //     声明上，已提交 route 可向目标 plan 注入任意事实键（首事实键先
        //     到先得）并连带把 mailbox hook 置 Ready。
        if (!stateMachine.planHookDependsOn(
                request.targetPlanId, request.targetHookId, inputs[0].targetSourceId, inputs[0].targetSignalId
            )) {
            revert DockEntranceFactNotDeclared(request.targetHookId, inputs[0].targetSourceId, inputs[0].targetSignalId);
        }
        // 8.6 output 事实键钉在目标 plan 自己声明的产出词表上（与 8.5 的
        //     planHookDependsOn 钉死风格对称）：接口 output 端口叶承诺的是
        //     canonical 信号 word（keccak("source::signalName")），与绑定侧
        //     (targetSourceId, targetSignalId)（各自 keccak）分属不同派生域，
        //     链上无法从 word 复原两者相等——不钉词表时，已提交 route 的
        //     发布者可错配绑定，把目标接口从未通过端口暴露的事实镜像进
        //     父单。无任何 capability 声明的手工目标 plan 与 mint/output
        //     词表闸同口径放行。
        if (planMetadataModule.planSignalCapabilityCount(request.targetPlanId) != 0) {
            for (uint256 i = 0; i < outputs.length; i++) {
                if (planMetadataModule.currentOrderFactStage(
                        request.targetPlanId, outputs[i].targetSourceId, outputs[i].targetSignalId
                    ) == bytes32(0)) {
                    revert DockOutputFactNotDeclared(
                        request.targetPlanId, outputs[i].targetSourceId, outputs[i].targetSignalId
                    );
                }
            }
        }

        // 9. 身份推导重算（keeper 不可自报 ID）。localOrderKey 为 bytes32
        //    order id 本身（EVM 轨订单键即 word）。modeWord/interfaceNameId
        //    槽位钉 new 路由的实例身份。
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
            return false; // 幂等重放：同一 dock 重复 open 无副作用
        }

        // 10. entrance permit（可选）：非空签名 = 目标 plan publisher 对本次
        //     open 的预授权。必须在 dock 幂等检查之后，避免重放已成功的
        //     permit 因 nonce 已消费而回退，而不是按接口约定返回 false。
        if (permit.signature.length != 0) {
            _verifyEntrancePermit(request, inputs[0].portKey, permit);
        }

        // 11. 深度（父订单真实 dock 深度为权威，不信任请求自报值）。
        uint8 parentDepth = dockDepthOfOrder[request.localPlanId][request.localOrderId];
        if (parentDepth != request.parentDepth) {
            revert DockDepthMismatch(request.parentDepth, parentDepth);
        }
        if (parentDepth >= MAX_DOCK_DEPTH) {
            revert DockDepthExceeded(parentDepth, MAX_DOCK_DEPTH);
        }

        // 12. 唯一性：本 route instance 未绑定 child；目标 endpoint 未占用。
        bytes32 localRouteInstanceKey =
            keccak256(abi.encode(request.localPlanId, request.localOrderId, request.localStageId, request.routeId));
        bytes32 targetEndpointKey = keccak256(abi.encode(request.targetPlanId, request.linkedOrderId));
        if (dockByLocalRoute[localRouteInstanceKey] != bytes32(0)) {
            revert DockEndpointOccupied(localRouteInstanceKey);
        }
        if (dockByTargetOrder[targetEndpointKey] != bytes32(0)) {
            revert DockEndpointOccupied(targetEndpointKey);
        }

        // ---- 原子效果：任一步 revert 全部回滚 ----
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
            inputs[0].portKey,
            inputs[0].targetSignalId
        );
        bytes32 entranceIdempotencyKey =
            keccak256(abi.encode(_DOMAIN_INPUT_IDEMPOTENCY, request.dockInstanceId, entranceBindingHash, uint256(0)));

        // keeper 只提供活性（relayer/opener 归 keeper）。creator 与 dock 事实
        // 提交者不得是 keeper——基础设施地址没有业务身份，混入
        // lastSignalSubmitter 会让 HANDOFF/REPLACEMENT 的"上一执行者"回退取
        // 到 keeper。dock 通道事实的提交者记为 creator（= 目标 plan
        // publisher，permit 路由的签名者同源，且本就是该子单的 patch
        // selector 权威）；子订单信号授权随后按目标定义自身的授权流
        // （executor patch / submitSignalFor）建立，不经 open 注入。
        address creator = stateMachine.planPublisher(request.targetPlanId);
        stateMachine.createDockedOrderFromModule(
            request.targetPlanId,
            request.linkedOrderId,
            creator,
            msg.sender,
            request.targetHookId,
            request.targetStageId,
            inputs[0].targetSourceId,
            inputs[0].targetSignalId,
            entrancePayloadHash,
            entranceIdempotencyKey,
            creator,
            new IUVPStateMachineCore.SignalAuthorization[](0)
        );

        // entrance 交付账本（UVP-08）：open 本身就是 entrance input 的一次
        // 交付（createDockedOrderFromModule 写入 entrance 事实并发
        // DockInputSubmitted），_inputDelivered 必须同步置位，否则
        // dockInputDelivered(dockInstanceId, entranceBindingHash) 与链上
        // 交付事实矛盾，且事后重放 submitDockedInput(entrance) 只会因
        // mailbox 既有事实 DockInputConflict。
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

    // ------------------------------------------------------------------
    // submitDockedInput
    // ------------------------------------------------------------------

    function submitDockedInput(bytes32 dockInstanceId, bytes32 localHookId, bytes32 inputBindingHash)
        external
        returns (bool submitted)
    {
        ActiveDockV2 storage dock = _docks[dockInstanceId];
        if (!dock.exists) {
            revert DockNotOpened(dockInstanceId);
        }
        if (_inputDelivered[dockInstanceId][inputBindingHash]) {
            return false; // 幂等重放
        }
        ActiveDockInputBindingV2 storage binding = _inputBindings[dockInstanceId][inputBindingHash];
        if (!binding.exists) {
            revert DockInputNotFound(dockInstanceId, inputBindingHash);
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
        // 目标 mailbox fact 尚未写入；冲突 = 不同 provenance 的既有事实
        // （A14：同一事实槽位不得复用表达新事实）。
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
        // 提交者记子订单 creator（目标 plan publisher），不记 keeper——与
        // open 的 entrance 事实同口径，基础设施地址不进业务归因。
        address childCreator = stateMachine.orderCreator(dock.targetPlanId, dock.linkedOrderId);
        stateMachine.recordDockedInputFromModule(
            dock.targetPlanId,
            dock.linkedOrderId,
            binding.targetSourceId,
            binding.targetSignalId,
            payloadHash,
            idempotencyKey,
            childCreator
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

    // ------------------------------------------------------------------
    // submitDockedSignal
    // ------------------------------------------------------------------

    function submitDockedSignal(bytes32 dockInstanceId, bytes32 outputBindingHash) external returns (bool submitted) {
        ActiveDockV2 storage dock = _docks[dockInstanceId];
        if (!dock.exists) {
            revert DockNotOpened(dockInstanceId);
        }
        // A14：一条 output 绑定至多交付一次（交付账本），目标事实槽位
        // 由 StateMachine idempotency 键兜底。
        if (_outputDelivered[dockInstanceId][outputBindingHash]) {
            return false; // 幂等重放
        }
        ActiveDockOutputBindingV2 storage binding = _outputBindings[dockInstanceId][outputBindingHash];
        if (!binding.exists) {
            revert DockOutputBindingNotFound(dockInstanceId, outputBindingHash);
        }
        // 目标事实必须真实存在；payload/submitter 全部读取自 StateMachine
        // 存储，keeper 无法替换。
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
        // 镜像事实的记账提交者取父单 creator（与 open/entrance 的"dock 通道
        // 事实提交者记 creator"同口径），不记子单事实的 originalSubmitter：
        // 后者是外部（子）plan 的参与方地址，写入父单
        // lastSignalSubmitter 会钉进 HANDOFF 无 active patch 时的"上一
        // 执行者"回退链——open 路径对 keeper 已同理由规避。子侧归因由
        // DockOutputSubmitted 携带 originalSubmitter 保留，链上事实归因
        // 仍可从事件完整重建。
        address parentCreator = stateMachine.orderCreator(dock.localPlanId, dock.localOrderId);
        stateMachine.submitSignalFromModule(
            dock.localPlanId,
            dock.localOrderId,
            binding.localSourceId,
            binding.localSignalId,
            payloadHash,
            idempotencyKey,
            parentCreator
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

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    function _verifyEntrancePermit(
        OpenDockRequestV2 calldata request,
        bytes32 entrancePortKey,
        EntrancePermitV2 calldata permit
    ) private {
        if (block.timestamp > permit.deadline) {
            revert DockPermitExpired(permit.deadline);
        }
        // nonce 序列从 1 起：storage 缺省 0 使 nonce=0 恒不可用（0>=0 即拒
        // 绝）——这是有意的发号下界，不是 off-by-one，签名方/构建器从 1 递增。
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
                uint256(0), // feeLimit：无费用机制时固定 0
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
        // v 值严格 {27,28}（与其余 EIP-712 验签入口同口径）：ECDSA.recover 对
        // 非 {27,28} 直接 InvalidSignatureV，不做 0/1 归一化。
        address recovered = ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: sigS}));
        if (recovered != authority) {
            revert DockPermitInvalidSigner(authority, recovered);
        }
        usedEntrancePermitNonce[request.dockInstanceId] = permit.nonce;
    }

    /// entrance 端口叶重算 + 与唯一 input 绑定/mailbox hook 的一致性。
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

    /// 目标 plan 的 dockInterfaceRoot 是否承诺被绑定的具名接口（两级树
    /// 的第二级；接口叶由 planMetadataModule 从承诺输入重算）。
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

    /// new 模式实例身份（9 word：runtimeDomain/localPlan/localDefRef/
    /// localOrderKey/routeId/routeHash/modeWord/interfaceNameId/targetPlanId）。
    /// 目标 plan 身份必须进 preimage：接口承诺 word（dockInterfaceRoot）可被
    /// 第三方复制进自建 plan，不绑 targetPlanId 时实例/子单身份无法与真正的
    /// 对接目标 plan 一一对应。
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

    /// envelope：全部 word 来自 committed route/binding/dock
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

    /// 重算单条 input 绑定哈希；失配即 revert（调用方不得自报 bindingHash）。
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
        bytes32 targetDefinitionRefHash,
        bytes32 interfaceNameId,
        bytes32 inputsRoot,
        bytes32 outputsRoot
    ) private pure returns (bytes32) {
        // modeWord 钉 new(0)：链轨只支持建单型路由，existing 路由哈希无法
        // 重算通过（目标运行期身份由 resolution manifest 与 route JSON 携带，
        // 不进 routeHash preimage）。
        return keccak256(
            abi.encode(
                _DOMAIN_ROUTE,
                localDefinitionRefHash,
                targetDefinitionRefHash,
                interfaceNameId,
                uint256(DOCK_MODE_NEW),
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
