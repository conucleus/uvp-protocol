// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";
import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";

/// @title UVPDockingModule — 统一 Zhixu DockRoute（abiVersion 4.4）
/// @notice 所有 Zhixu dock 来自 committed route，两种 order mode：
///          - new（openDockedOrder）：一笔交易内原子完成 child 创建、link
///            登记、entrance fact 写入，并同步置位 entrance 交付账本。恰一条
///            input 绑定且开仓即被消费为出生锚——submitDockedInput 对 new
///            dock 是纯幂等重放面（恒 return false），不是活的交付路径。
///          - existing（attachDockedOrder）：对等挂接既有目标单，不铸子单
///            （O(1) 效果集，与存量 dock 数无关）。建立须过同意门：目标单
///            creator / 目标单在任执行者 / 目标 plan publisher 的 EIP-712
///            attach 预授权，三者之一（空签名只表示不携显式授权，
///            permissionless 的重放/回填面不受影响）。attach 后与 new 完全
///            同构：submitDockedInput 逐端口交付（恰一次+幂等重放，对
///            existing 是活的交付路径），submitDockedSignal 把目标单事实
///            （含 attach 前已成立者）镜像回父单——回填即重放，事实只读
///            StateMachine 存储，keeper 无法自选内容。
///          N:1 拼批：多个父 route instance 可挂同一目标单（幂等键是父侧
///          dockByLocalRoute，不是目标端点）；目标侧"谁挂了我"投影由
///          DockAttached 事件（indexed linkedOrderId）承载。
///          target:null 动态选择：未解析路由以候选集 root 占据 routeHash
///          的目标槽（随 dockRoutesRoot 在 finalize 冻结），attach 携
///          (候选叶, membership proof) 选定；选定目标进 dockInstanceId
///          preimage（existing 第 10 word = 目标单键），叠加父 route
///          instance 唯一键即终身钉住。链下的退避重试/预算/死信归 keeper，
///          链上只做确定性验证与幂等。
///          哈希域公式的唯一权威规格见
///          packages/compiler/docs/dock-word-layout.md（三线对拍钉死）；
///          出生原子性/同意门/keeper 信任模型的设计叙事见
///          docs/design-notes.md §2。
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

    /// existing 模式挂接请求。与 OpenDockRequestV2 的差异全部源自
    /// "不铸子单"：linkedOrderId 是调用方选定的既有目标单（不再是
    /// dockInstanceId 派生子单），无 localHookId（没有出生锚），新增
    /// targetCandidatesRoot（动态选择路由的目标槽 word；静态路由该槽
    /// 就是 targetDefinitionRefHash，此字段填 0 即可）。
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
        // executor 同意腿的阶段锚 + input 端口 hook 的归属校验位。
        bytes32 targetStageId;
        uint8 parentDepth;
        bytes32 targetCandidatesRoot;
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
        bytes32 outputsRoot; // merkle(该接口全部 outputPortLeaf_v3)
    }

    /// 两级接口证明：entrance 端口叶 → 接口 inputsRoot；接口叶 → plan 的
    /// dockInterfaceRoot。聚合为单参数以容纳 open 的校验链栈深。
    struct DockInterfaceProofV2 {
        DockInterfacePortLeafV2 entranceLeaf;
        bytes32[] portProof;
        DockInterfaceCommitmentV2 commitment;
        bytes32[] interfaceProof;
    }

    /// attach 的接口证明：接口叶 → 目标 plan dockInterfaceRoot，加上
    /// （动态选择路由的）候选叶 → 候选集 root。attach 没有单端口
    /// entrance——每个 input 绑定自带端口叶重算材料（AttachInputBindingArg
    /// 的 targetHookId + portProof）。
    struct DockAttachInterfaceProofV1 {
        DockInterfaceCommitmentV2 commitment;
        bytes32[] interfaceProof;
        // 静态路由传空数组；动态路由必须证明选定目标 ∈ 候选集。
        bytes32[] candidateProof;
    }

    struct DockInputBindingArg {
        bytes32 localHookId;
        bytes32 portKey;
        bytes32 targetSourceId;
        bytes32 targetSignalId;
        bytes32 bindingHash;
    }

    /// attach 的 input 绑定：binding 哈希公式与 new 模式逐字节一致
    /// （targetHookId 不进绑定哈希，只在端口叶里）；多出的字段是端口叶
    /// membership 的重算材料——existing 接口可有多个 input 端口，逐绑定
    /// 携证明（形状对称于 DockOutputBindingArg 自带 portProof）。
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
    /// attach 的前置：目标单必须已存在（对等挂接的对象是既有订单）。
    error DockUnknownTargetOrder(bytes32 targetPlanId, bytes32 linkedOrderId);
    /// 同意门：调用方既不是目标单 creator、也不是目标单 targetStageId 的
    /// 在任执行者，又不携目标 plan publisher 的 attach 预授权。
    error DockAttachConsentRequired(bytes32 dockInstanceId, address caller);
    /// 动态选择：选定目标的候选叶不在路由承诺的候选集 root 内。
    error DockCandidateLeafMismatch(bytes32 leaf, bytes32 root);

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
    /// existing 模式挂接事件（形状对齐 DockOpened，便于索引侧同构解码）。
    /// 不内联任何已成立输出清单：目标侧事实的唯一权威是 StateMachine 存储
    /// + 交付账本事件（DockOutputSubmitted/DockOutputSatisfied），把清单
    /// 复制进本事件会造出第二事实源；链下回放方按路由产物枚举 output 绑定
    /// 后逐条 submitDockedSignal 重放即可（回填=重放）。
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
    /// 兄弟 output 绑定的等价交付满足：本绑定没有发生新的镜像写入，父单
    /// 本地事实已由同键同 payload 的另一条绑定送达；账本置位随本事件落地，
    /// 消费方据此把该绑定收敛为已交付。
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

    // ------------------------------------------------------------------
    // 常量（compatibility manifest 冻结）
    // ------------------------------------------------------------------

    uint8 public constant MAX_DOCK_OUTPUTS = 16;
    uint8 public constant MAX_DOCK_DEPTH = 8;
    /// route modeWord：new=0、existing=1。open 路由钉 new，attach 路由钉
    /// existing——modeWord 进 routeHash 与 dockInstanceId 双 preimage，
    /// 两模式身份不可互冒。
    uint8 public constant DOCK_MODE_NEW = 0;
    uint8 public constant DOCK_MODE_EXISTING = 1;
    /// 接口 orderModesWord 位掩码 bit0=new、bit1=existing。new 路由的出生锚
    /// 要求目标接口宣告 new；attach 路由对称要求宣告 existing。
    uint8 public constant DOCK_INTERFACE_ORDER_MODE_NEW = 1;
    uint8 public constant DOCK_INTERFACE_ORDER_MODE_EXISTING = 2;
    uint8 public constant SM_FLAG_EMIT_READY = 4;

    bytes32 private constant _DOMAIN_DEFINITION_REF = keccak256("UVP_DEFINITION_REF_V1");
    bytes32 private constant _DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V2");
    // output 端口叶 V3：叶直接钉绑定侧的事实键分量 (targetSourceId,
    // targetSignalId)。若叶承诺 canonical 信号 word（keccak("src::name")），
    // 则与绑定侧分量哈希分属不同派生域——链上无法互证两者指同一事实，
    // 调用方可把 DONE 端口绑到词表内另一个事实，目标方承诺被架空；分量
    // 入叶让错配绑定在 membership 处直接失配。
    bytes32 private constant _DOMAIN_INTERFACE_OUTPUT = keccak256("UVP_DOCK_INTERFACE_OUTPUT_V3");
    bytes32 private constant _DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant _DOMAIN_SOURCE_FACT_SET_ZERO = bytes32(0);
    bytes32 private constant _DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V2");
    bytes32 private constant _DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V2");
    bytes32 private constant _DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V2");
    bytes32 private constant _DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V2");
    // target:null 动态选择的候选叶域：leaf = H(domain, routeId,
    // targetDefinitionRefHash, interfaceNameId)。routeId 绑定（父定义,
    // 父阶段），跨路由/跨父复用候选叶在 membership 处失配；候选集 root
    // 本身经 routeHash 目标槽进 dockRoutesRoot（finalize 冻结）。
    bytes32 private constant _DOMAIN_DOCK_CANDIDATE = keccak256("UVP_DOCK_CANDIDATE_V1");
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
    // attach 预授权：digest 绑定全部挂接端点身份（含目标单键——授权的
    // 是"把这个既有单挂给这条父路由"，不是对整个 plan 的通配）。签名
    // 权威与 entrance permit 同源：目标 plan publisher（与 new 路由
    // "creator 恒等于目标 plan publisher"同口径）。
    bytes32 private constant _ATTACH_PERMIT_TYPEHASH = keccak256(
        "UVPDockAttachPermitV1(bytes32 targetPlanId,bytes32 targetOrderId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
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
    // unique(localPlanId, localOrderId, localStageId, routeId)——new 与
    // existing 共用的父侧幂等键：每 route instance 一条 dock（new 的子单
    // 出生键 / existing 的选定目标，都在 dockInstanceId preimage 内）。
    mapping(bytes32 localRouteInstanceKey => bytes32 dockInstanceId) public dockByLocalRoute;
    // unique(targetPlanId, linkedOrderId)——new 模式专属：每 route 恰一个
    // 子单，目标端点键即子单出生键。existing 不写本索引：N:1 拼批时多个
    // dock 共享同一目标端点，唯一值索引无法承载（覆盖写会反过来破坏 new
    // 的端点唯一不变量）；目标侧"谁挂了我"的投影由 DockAttached 事件
    // （indexed linkedOrderId）承载。
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
        EntrancePermitV2 calldata permit,
        IUVPStateMachineCore.FactAttribution[] calldata outputAttributions
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
            // 不构成目标侧承诺）。叶 V3 以绑定自己的事实键分量为承诺内容：
            // 绑到"另一个合法事实"同样失配，目标方对每端口暴露哪条事实的
            // 承诺由此闭合。
            _verifyOutputPortMembership(
                request.targetUidId, request.interfaceNameId, outputs[i], interfaceProof.commitment.outputsRoot
            );
        }

        // 7. routeHash 重算：open 路由 modeWord 钉 new(0)——existing 路由的
        //    哈希在此失配（existing 走 attachDockedOrder，各自钉死模式）。
        bytes32 recomputedRouteHash = _routeHash(
            request.localDefinitionRefHash,
            request.targetDefinitionRefHash,
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
        //    planHookDependsOn 钉死风格对称）：接口 output 端口叶承诺的是
        //    canonical 信号 word（keccak("source::signalName")），与绑定侧
        //    (targetSourceId, targetSignalId)（各自 keccak）分属不同派生域，
        //    链上无法从 word 复原两者相等——不钉词表时，已提交 route 的
        //    发布者可错配绑定，把目标接口从未通过端口暴露的事实镜像进
        //    父单。成员资格由 outputAttributions 逐项携 proof 自证（叶子
        //    由承诺输入重算，调用方不得自报叶值）；无任何 capability 声明
        //    的手工目标 plan 与 mint/output 词表闸同口径放行。
        _verifyOutputVocabulary(request.targetPlanId, outputs, outputAttributions);

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
    // attachDockedOrder（existing 模式：对等挂接既有目标单）
    // ------------------------------------------------------------------

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
        // 1. 父订单存在。
        if (!stateMachine.orderExists(request.localPlanId, request.localOrderId)) {
            revert DockUnknownLocalOrder();
        }
        // 2. routeId 重算（与 open 同公式，父侧路由身份不分模式）。
        bytes32 recomputedRouteId =
            keccak256(abi.encode(_DOMAIN_ROUTE_ID, request.localDefinitionRefHash, request.localStageId));
        if (recomputedRouteId != request.routeId) {
            revert DockRouteLeafMismatch(request.routeId, recomputedRouteId);
        }
        // 3. 目标定义身份闭环（uid → defRef，与 open 同款）。
        bytes32 derivedTargetDefRef = keccak256(abi.encode(_DOMAIN_DEFINITION_REF, request.targetUidId));
        if (derivedTargetDefRef != request.targetDefinitionRefHash) {
            revert DockTargetIdentityMismatch(request.targetDefinitionRefHash, derivedTargetDefRef);
        }
        // 4. 挂接对象必须是既有目标单（attach 的存在性前提，不是派生结果）。
        if (!stateMachine.orderExists(request.targetPlanId, request.linkedOrderId)) {
            revert DockUnknownTargetOrder(request.targetPlanId, request.linkedOrderId);
        }
        if (outputs.length > MAX_DOCK_OUTPUTS) {
            revert DockBindingLimitExceeded(outputs.length, MAX_DOCK_OUTPUTS);
        }

        // 5. 接口承诺必须宣告 existing（对称于 new 路由要求 bit0）。
        if (attachProof.commitment.orderModesWord & DOCK_INTERFACE_ORDER_MODE_EXISTING == 0) {
            revert DockInterfaceModeUnsupported(attachProof.commitment.orderModesWord);
        }

        // 6. input 绑定：哈希重算 + 父 hook 结构校验（EMIT_READY 属于
        //    localStageId——就绪本身是交付期门，attach 不要求 hook 已 Ready：
        //    没有出生锚在建立时被消费，输入逐端口由 submitDockedInput 在
        //    就绪后交付）+ 端口叶 membership + 目标侧 receive 词表钉死。
        bytes32[] memory inputLeaves = new bytes32[](inputs.length);
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
            // 端口叶（与 open 的 entrance 叶同域）：(portKey, hookKey) 由
            // 承诺输入重算，membership 钉在接口 inputsRoot。
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
            // 端口 hook 归属 targetStageId（executor 同意腿的阶段锚与端口
            // 挂钩一致），且事实键在该 hook 的 SIGNAL 依赖声明内（receive
            // 词表，与 open 的出生锚 8.5 同口径）。
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

        // 7. routeHash 重算（modeWord 钉 existing）：先按静态目标槽
        //    （= targetDefinitionRefHash）重算；失配则该槽必为动态路由的
        //    候选集 root——重算匹配后，选定目标必须携候选叶 membership
        //    proof。两种形态的槽 word 都在已提交 route 叶内（调用方无法
        //    自造：换槽 word 即换叶，dockRoutesRoot membership 失配）。
        bytes32 recomputedRouteHash = _routeHash(
            request.localDefinitionRefHash,
            request.targetDefinitionRefHash,
            request.interfaceNameId,
            DOCK_MODE_EXISTING,
            recomputedInputsRoot,
            recomputedOutputsRoot
        );
        if (recomputedRouteHash != request.routeHash) {
            bytes32 dynamicRouteHash = _routeHash(
                request.localDefinitionRefHash,
                request.targetCandidatesRoot,
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
                    _DOMAIN_DOCK_CANDIDATE, request.routeId, request.targetDefinitionRefHash, request.interfaceNameId
                )
            );
            if (!DockMerkle.verify(request.targetCandidatesRoot, candidateLeaf, attachProof.candidateProof)) {
                revert DockCandidateLeafMismatch(candidateLeaf, request.targetCandidatesRoot);
            }
        }
        if (!planMetadataModule.verifyDockRoute(request.localPlanId, request.routeHash, routeProof)) {
            revert DockRouteLeafMismatch(request.routeHash, bytes32(0));
        }

        // 8. 目标 plan 已 finalized，且其 dockInterfaceRoot 承诺被绑定的
        //    具名接口（接口叶由 planMetadataModule 重算）。
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

        // 9. 身份推导重算（keeper 不可自报 ID）：existing 10 word，尾 word =
        //    既有目标单键（选定目标钉进实例身份）。
        bytes32 runtimeDomain = keccak256(abi.encode(_DOMAIN_RUNTIME_EIP155, block.chainid, address(stateMachine)));
        bytes32 recomputedDockInstance = _dockInstanceIdExisting(request, runtimeDomain);
        if (recomputedDockInstance != request.dockInstanceId) {
            revert DockRouteLeafMismatch(request.dockInstanceId, recomputedDockInstance);
        }
        if (_docks[request.dockInstanceId].exists) {
            return false; // 幂等重放：同一 dock 重复 attach 无副作用
        }

        // 10. 同意门（creator / 在任执行者 / publisher 预授权，三者之一）。
        _requireAttachConsent(request, permit);

        // 11. 深度：父订单真实 dock 深度为权威；目标单深度取 max——attach
        //     不建单但计入 dock 链长，不抬升会让深度账本对"经由 attach
        //     延长的链"失明，MAX_DOCK_DEPTH 的环路/长链防护被绕过。
        uint8 parentDepth = dockDepthOfOrder[request.localPlanId][request.localOrderId];
        if (parentDepth != request.parentDepth) {
            revert DockDepthMismatch(request.parentDepth, parentDepth);
        }
        if (parentDepth >= MAX_DOCK_DEPTH) {
            revert DockDepthExceeded(parentDepth, MAX_DOCK_DEPTH);
        }

        // 12. 唯一性：父 route instance 一次性（选定后钉住的执行面）。
        //     目标端点不设唯一键——N:1 拼批，多父可挂同一目标单。
        bytes32 localRouteInstanceKey =
            keccak256(abi.encode(request.localPlanId, request.localOrderId, request.localStageId, request.routeId));
        if (dockByLocalRoute[localRouteInstanceKey] != bytes32(0)) {
            revert DockEndpointOccupied(localRouteInstanceKey);
        }

        // ---- 原子效果：O(1) 存储写，无子单、无事实写入 ----
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
        if (dockDepthOfOrder[request.targetPlanId][request.linkedOrderId] < parentDepth + 1) {
            dockDepthOfOrder[request.targetPlanId][request.linkedOrderId] = parentDepth + 1;
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

    /// output 镜像回写父单。本地事实键的词表成员资格与属主阶段由调用方
    /// 携 proof 自证（证明材料是公开编译产物，keeper 无特权）。
    function submitDockedSignal(
        bytes32 dockInstanceId,
        bytes32 outputBindingHash,
        IUVPStateMachineCore.FactAttribution calldata attribution,
        IUVPStateMachineCore.SelectorBindingProof calldata selectorBinding
    ) external returns (bool submitted) {
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
        // 同一本地事实键的多条 output 绑定（不同端口/目标事实）在链上无去
        // 重：首条交付后，兄弟绑定镜像同一本地键必然撞 SignalAlreadyExists
        // ——先写已交付位再外调的回滚路径会让该绑定永久不可交付。按本地事
        // 实键幂等吸收：镜像槽位已存在且 payload 一致即视为本绑定已由等价
        // 交付满足——必须落交付账本并显式发事件，否则投影侧永远认为该绑定
        // 未交付，keeper 每个重发窗口都会再提交一次（永不收敛的 gas 循环）。
        // 不复用 DockOutputSubmitted：本分支没有发生新的镜像写入，按既有
        // 事件形状广播会让父侧投影再落一条并不存在的映射事实时间线。
        // payload 不一致则落入底层 SignalAlreadyExists，fail-closed——同一
        // 本地键不得表达两种内容。
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
                return false;
            }
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
            parentCreator,
            attribution,
            selectorBinding
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

    /// attach 预授权 digest（签名权威 = 目标 plan publisher；nonce 账本与
    /// entrance permit 共用 usedEntrancePermitNonce，按 dockInstanceId 寻址
    /// ——两种模式的实例身份经 modeWord 分流，恒不撞键）。
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

    /// attach 同意门：目标单 creator / 目标单 targetStageId 的在任执行者 /
    /// 目标 plan publisher 的 EIP-712 预授权，三者之一。空签名只表示不携
    /// 显式授权（与前两腿的 permissionless 中继兼容），不是放行——三腿
    /// 全空即拒绝。executor 腿经请求自报 targetStageId 锚定（O(1)，不枚举
    /// 订单阶段集）：只有该单某阶段的真实在任执行者才可能命中。
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
        // nonce 序列从 1 起（与 _verifyEntrancePermit 同口径的 storage 下界）。
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

    /// output 端口叶重算 + membership（open/attach 共用）：叶 V3 钉绑定侧
    /// 事实键分量，错配绑定在此失配。
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

    /// output 事实键的产出词表闸（open/attach 共用）：有词表的目标 plan
    /// 逐项要求 outputAttributions 携 relation=0 capability 证明。
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

    /// existing 模式实例身份（10 word：new 的 9 word 后追加目标单键）。
    /// 尾 word 与 TS `dockInstanceId(targetOrderRef=…)` 的 word 形态槽对拍：
    /// EVM 轨订单键即 bytes32 word，原字入槽（不二次哈希）。选定目标
    /// （plan + 单键）由此钉进实例身份——同一父 route instance 换目标即换
    /// dockInstanceId，再叠 dockByLocalRoute 唯一键即"选定后终身钉住"。
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
        bytes32 targetSlotWord,
        bytes32 interfaceNameId,
        uint256 modeWord,
        bytes32 inputsRoot,
        bytes32 outputsRoot
    ) private pure returns (bytes32) {
        // modeWord 由调用路径钉死（open=new/attach=existing）；targetSlotWord
        // 是路由的目标承诺槽——静态路由为 targetDefinitionRefHash，
        // target:null 动态路由为候选集 root（目标运行期身份由 resolution
        // manifest 与 route JSON 携带，不进 routeHash preimage）。
        return keccak256(
            abi.encode(
                _DOMAIN_ROUTE,
                localDefinitionRefHash,
                targetSlotWord,
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
