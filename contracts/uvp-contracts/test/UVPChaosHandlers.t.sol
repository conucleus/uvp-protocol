// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";

/// chaos invariant 线的窄 Vm 接口（不 vendor forge-std，与
/// UVPStateMachineInvariants.t.sol 同惯例；本线额外需要 recordLogs 族——
/// 事件计数 ghost 的观察原语）。
///
/// 工具链依赖：getRecordedLogs 按 drain 语义工作（返回并清空自上次调用
/// 以来的增量）；本文件 foundry 1.7.1 验证，升级后若改回全量返回，事件
/// 计数 ghost 会双计。
interface ChaosVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function addr(uint256 privateKey) external returns (address keyAddr);
    function expectRevert(bytes calldata revertData) external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function recordLogs() external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

/// 链轨 chaos Stage 1：forge invariant 扩面（成衣行业世界）。
///
/// 世界 = 成衣工坊主计划（裁剪→缝纫→后整理，含延时质检、否决位、发射
/// 适格窗、执行者候选集换人面、治理分叉）＋ 染厂→成衣工厂的委托 dock
/// 对接（new 铸子单 / existing 挂接，双模各占独立路由）＋ dock 子单向外
/// 的链式对接（depth=2+ 可达）＋ 备选计划（OR / AND×delay 混合钩）出生
/// 混入面。
///
/// 随机面（自动收集集）覆盖动作全集：submitSignal / submitSignalFor（含
/// 错签者与过期签名攻击变体）/ followGarmentProcess / pokeTimer /
/// warpTime / openDock / attachDock / chainDock / submitDockedInput /
/// submitDockedSignal / applyStageExecutorPatch（assign/handoff）/
/// forkOrder / commitPlan / birthAltOrder / submitAltSignal。
///
/// ghost 扩面（每动作后全量复查 + 计数器）：
///
/// 1. 终态不可改写（Ready/Cancelled 之后永不再变）；
/// 2. first-win：每信号槽首写 payloadHash 之后永不再变，且 once-exists
///    的事实槽永续存在（吸收稳定性）；
/// 3. 等待期限单调：锚点推导形态族（延时 / OR / AND×delay）上 dueAt
///    单调不减；
/// 4. 接纳计数与 SignalSubmitted 事件严格一致（recordLogs 观察）；
/// 5. revert 动作零状态变更（前后世界 digest 全等）且不落事实事件；
/// 6. dock 每单总挂接边数恒 ≤ MAX_DOCK_EDGES（父链账本口径，链式
///    形态下边数=2+；最长路径不进合约）。
contract UVPChaosInvariantTest {
    ChaosHandler private handler;

    function setUp() public {
        handler = new ChaosHandler();
        handler.bootstrap();
    }

    function invariant_TerminalHookStatesAreImmutable() external view {
        require(handler.terminalViolationCount() == 0, "chaos: terminal hook state was rewritten");
    }

    function invariant_SignalFirstWriteWins() external view {
        require(handler.firstWriteViolationCount() == 0, "chaos: first-write payload was overwritten");
    }

    function invariant_WaitDeadlineIsMonotonic() external view {
        require(handler.waitDeadlineViolationCount() == 0, "chaos: wait dueAt regressed");
    }

    function invariant_AdmittedFactsMatchSignalSubmittedEvents() external view {
        require(
            handler.signalSlotTransitionCount() == handler.signalSubmittedEventCount(),
            "chaos: fact admissions diverged from SignalSubmitted events"
        );
    }

    function invariant_RevertedActionsLeaveNoTrace() external view {
        require(handler.revertDigestViolationCount() == 0, "chaos: reverted action changed state");
        require(handler.revertEventViolationCount() == 0, "chaos: reverted action emitted a fact event");
    }

    function invariant_DockDepthWithinBound() external view {
        require(handler.dockDepthViolationCount() == 0, "chaos: dock edges exceeded MAX_DOCK_EDGES");
    }
}

contract ChaosHandler {
    ChaosVm private constant vm = ChaosVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ------------------------------------------------------------------
    // 常量：域、typehash、flags
    // ------------------------------------------------------------------

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.15");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_FOR_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;

    // preimage v2 域（与 packages/compiler/docs/dock-word-layout.md 逐字节一致）。
    bytes32 private constant DOMAIN_DEFINITION_REF = keccak256("UVP_DEFINITION_REF_V1");
    bytes32 private constant DOMAIN_INTERFACE = keccak256("UVP_DOCK_INTERFACE_V2");
    bytes32 private constant DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V2");
    bytes32 private constant DOMAIN_INTERFACE_OUTPUT = keccak256("UVP_DOCK_INTERFACE_OUTPUT_V3");
    bytes32 private constant DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V2");
    bytes32 private constant DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V2");
    bytes32 private constant DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V3");
    bytes32 private constant DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V2");
    bytes32 private constant DOMAIN_DOCK_ORDER = keccak256("UVP_DOCK_ORDER_V1");
    bytes32 private constant DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);

    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");

    uint8 private constant FLAG_MINT = 1;
    uint8 private constant FLAG_DOCK = 2;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_ADMISSION = 8;

    // ------------------------------------------------------------------
    // 常量：成衣世界词表
    // ------------------------------------------------------------------

    // 主计划（成衣工坊）：裁剪 → 缝纫 → 后整理。
    bytes32 private constant SOURCE_BRAND = keccak256("brand");
    bytes32 private constant SOURCE_SHOP = keccak256("shop");
    bytes32 private constant SIG_ORDER_PLACED = keccak256("order.placed");
    bytes32 private constant SIG_CUT_COMPLETED = keccak256("cut.completed");
    bytes32 private constant SIG_QC_PASSED = keccak256("qc.passed");
    bytes32 private constant SIG_SEW_FINISHED = keccak256("sew.finished");
    bytes32 private constant SIG_SEW_REWORK = keccak256("sew.rework");
    bytes32 private constant SIG_SEW_BATCH_CLOSED = keccak256("sew.batchClosed");
    bytes32 private constant SIG_DISPUTE_RULED = keccak256("dispute.ruled");
    bytes32 private constant SIG_FINISH_IRONED = keccak256("finish.ironed");

    bytes32 private constant STAGE_CUTTING = keccak256("cutting");
    bytes32 private constant STAGE_SEWING = keccak256("sewing");
    bytes32 private constant STAGE_FINISHING = keccak256("finishing");

    bytes32 private constant HOOK_ORDER_BIRTH = keccak256("cutting#ORDER_BIRTH");
    bytes32 private constant HOOK_CUT_DONE = keccak256("sewing#CUT_DONE");
    bytes32 private constant HOOK_QC_TIMER = keccak256("sewing#QC_TIMER");
    bytes32 private constant HOOK_SEW_VETO = keccak256("sewing#SEW_VETO");
    bytes32 private constant HOOK_SEW_CLOSED = keccak256("finishing#SEW_CLOSED");
    bytes32 private constant HOOK_IRON_DONE = keccak256("finishing#IRON_DONE");

    // 染厂（dock 父侧）：染色 → 出货。
    bytes32 private constant SOURCE_MILL = keccak256("mill");
    bytes32 private constant SIG_LOT_STARTED = keccak256("lot.started");
    bytes32 private constant SIG_LOT_SHIPPED = keccak256("lot.shipped");
    bytes32 private constant STAGE_DYEING = keccak256("dyeing");
    bytes32 private constant STAGE_DISPATCH = keccak256("dispatch");
    bytes32 private constant HOOK_LOT_BIRTH = keccak256("dyeing#LOT_BIRTH");
    bytes32 private constant HOOK_SHIPPED = keccak256("dispatch#SHIPPED");

    // 成衣工厂（dock 目标侧）：车间单阶段三钩。
    bytes32 private constant SOURCE_DYE = keccak256("dye");
    bytes32 private constant SOURCE_AUDIT = keccak256("audit");
    bytes32 private constant SIG_PLANT_ORDERED = keccak256("plant.ordered");
    bytes32 private constant SIG_LOT_ARRIVED = keccak256("lot.arrived");
    bytes32 private constant SIG_PLANT_AMENDED = keccak256("plant.amended");
    bytes32 private constant STAGE_WORKSHOP = keccak256("workshop");
    bytes32 private constant HOOK_DOCK_ENTRANCE = keccak256("workshop#DOCK_ENTRANCE");
    bytes32 private constant HOOK_PLANT_MINT = keccak256("workshop#MINT");
    bytes32 private constant HOOK_PLANT_RECEIVE = keccak256("workshop#RECEIVE");

    bytes32 private constant INTERFACE_NAME_ID = keccak256("production");
    bytes32 private constant PLANT_UID_ID = keccak256("zx-chao5a11ce0c0ffee0ddba5e5eed1c0deb0a");
    bytes32 private constant PORT_FABRIC_IN = keccak256("fabricIn");
    bytes32 private constant PORT_AUDIT_IN = keccak256("auditIn");
    bytes32 private constant PORT_GARMENT_OUT = keccak256("garmentOut");
    bytes32 private constant PORT_PROGRESS_OUT = keccak256("progressOut");
    // 输出镜像的本地（染厂侧）事实键。
    bytes32 private constant SIG_MILL_RECEIVED = keccak256("garment.received");
    bytes32 private constant SIG_MILL_PROGRESS = keccak256("garment.progress");

    bytes32 private constant ROLE_EXECUTOR = bytes32(uint256(0xa003));
    bytes32 private constant AUTH_METADATA_HASH = bytes32(uint256(0xa002));
    bytes32 private constant EXECUTOR_METADATA_HASH = bytes32(uint256(0xa004));
    bytes32 private constant MODE_ASSIGN = bytes32("assign");
    bytes32 private constant MODE_HANDOFF = bytes32("handoff");

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant MILL_PUBLISHER_PRIVATE_KEY = 0xB0B;
    uint256 private constant PLANT_PUBLISHER_PRIVATE_KEY = 0xB0C;
    // 链式对接的 echo 计划发布者（B-01：路由承诺目标 planId，计划不能
    // 自指——同接口承诺的 echo 计划承接链式路由的目标侧）。
    uint256 private constant ECHO_PUBLISHER_PRIVATE_KEY = 0xB0D;
    uint256 private constant SUBMITTER_PRIVATE_KEY = 0xa11ce;
    uint256 private constant FINISHER_A_PRIVATE_KEY = 0xB1;
    uint256 private constant FINISHER_B_PRIVATE_KEY = 0xB2;
    uint256 private constant ROGUE_PRIVATE_KEY = 0xBAD5;

    uint256 private constant BASE_ORDER_COUNT = 2;
    uint256 private constant MILL_ORDER_COUNT = 3;
    uint256 private constant PLANT_TARGET_COUNT = 3;
    uint256 private constant FORK_PAYLOAD_COUNT = 4;
    uint256 private constant ALT_PLAN_COUNT = 3;

    uint256 private constant BASE_SIGNAL_COUNT = 8;
    uint256 private constant MILL_SIGNAL_COUNT = 4;
    uint256 private constant PLANT_SIGNAL_COUNT = 3;
    uint256 private constant ALT_SIGNAL_COUNT = 3;
    uint256 private constant BASE_HOOK_COUNT = 6;
    uint256 private constant MILL_HOOK_COUNT = 2;
    uint256 private constant PLANT_HOOK_COUNT = 3;
    uint256 private constant ALT_HOOK_COUNT = 5;

    // ------------------------------------------------------------------
    // 世界状态
    // ------------------------------------------------------------------

    UVPStateMachine private machine;
    UVPDockingModule private docking;
    UVPStagePatchModule private stagePatch;

    bytes32 private basePlanId;
    bytes32 private millPlanId;
    bytes32 private plantPlanId;
    bytes32 private runtimeDomain;
    bytes32 private millDefinitionRef = keccak256("chaos.dye-mill.definition-ref");
    bytes32 private plantDefinitionRef = keccak256(abi.encode(DOMAIN_DEFINITION_REF, PLANT_UID_ID));

    bytes32[BASE_ORDER_COUNT] private baseOrders;
    bytes32[MILL_ORDER_COUNT] private millOrders;
    bytes32[PLANT_TARGET_COUNT] private plantTargets;
    bytes32[] private forkChildren;
    bytes32[FORK_PAYLOAD_COUNT] private forkPayloads;

    // dock 派生量（bootstrap 一次性算定）。
    bytes32 private openRouteId;
    bytes32 private openRouteHash;
    bytes32 private attachRouteId;
    bytes32 private attachRouteHash;
    bytes32 private openEntranceBinding;
    bytes32 private attachInputBinding;
    bytes32 private garmentOutBinding;
    bytes32 private progressOutBinding;
    bytes32 private attachGarmentOutBinding;
    bytes32 private attachProgressOutBinding;
    bytes32[MILL_ORDER_COUNT] private openInstanceIds;
    bytes32[MILL_ORDER_COUNT] private dockChildIds;
    bool[MILL_ORDER_COUNT] private dockChildLive;
    bytes32[MILL_ORDER_COUNT * PLANT_TARGET_COUNT] private attachInstanceIds;
    bytes32 private plantInputsRoot;
    bytes32 private plantOutputsRoot;
    bytes32 private fabricInLeaf;
    bytes32 private auditInLeaf;
    bytes32 private garmentOutLeaf;
    bytes32 private progressOutLeaf;
    bytes32 private plantInterfaceLeaf;
    bytes32[] private routeTreeLeaves;
    bytes32[] private routeChainTreeLeaves;

    // 链式对接派生量（dock 子单作为父再向外一层）。
    bytes32 private chainRouteId;
    bytes32 private chainOpenRouteHash;
    bytes32 private chainAttachRouteHash;
    bytes32 private chainEntranceBinding;
    bytes32 private chainAttachInputBinding;
    bytes32[MILL_ORDER_COUNT] private chainInstanceIds;
    bytes32 private echoPlanId;
    bytes32[PLANT_TARGET_COUNT] private echoTargets;
    bytes32[MILL_ORDER_COUNT] private grandchildIds;
    bool[MILL_ORDER_COUNT] private grandchildLive;
    bytes32[MILL_ORDER_COUNT * PLANT_TARGET_COUNT] private chainAttachInstanceIds;

    bool[ALT_PLAN_COUNT] private altPlanCommitted;
    bytes32[ALT_PLAN_COUNT] private altPlanIds;
    bytes32[ALT_PLAN_COUNT] private altOrders;
    bool[ALT_PLAN_COUNT] private altOrderLive;
    address private submitterAddr;

    // 能力表镜像（造 proof 用；与 UVPDockingModule.t.sol 同款测试镜像）。
    struct StageSelectorBinding {
        bytes32 selectorStageId;
        bytes32 targetStageId;
    }

    struct SignalCapability {
        bytes32 stageId;
        bytes32 targetSourceId;
        bytes32 signalId;
        uint8 targetOrderRelation;
    }

    struct CapabilityTables {
        SignalCapability[] capabilities;
        bytes32[] sortedLeaves;
        bytes32[] candidateLeaves;
    }

    mapping(bytes32 planId => CapabilityTables tables) private capabilityTables;

    // ------------------------------------------------------------------
    // ghost 观察态
    // ------------------------------------------------------------------

    mapping(bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 hookId => uint8))) private ghostTerminal;
    mapping(bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 hookId => uint64))) private ghostMaxWaitDueAt;
    mapping(bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 signalKey => bytes32))) private ghostFirstPayload;

    uint256 public terminalViolationCount;
    uint256 public firstWriteViolationCount;
    uint256 public waitDeadlineViolationCount;
    uint256 public signalSlotTransitionCount;
    uint256 public signalSubmittedEventCount;
    uint256 public revertDigestViolationCount;
    uint256 public revertEventViolationCount;
    uint256 public dockDepthViolationCount;

    bytes32 private constant SIGNAL_SUBMITTED_TOPIC0 =
        keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32)");
    bytes32 private constant SIGNAL_SUBMITTER_AUTHORIZED_TOPIC0 =
        keccak256("SignalSubmitterAuthorized(bytes32,bytes32,bytes32,bytes32,address,bytes32,bytes32)");
    bytes32 private constant HOOK_STATUS_CHANGED_TOPIC0 =
        keccak256("HookStatusChanged(bytes32,bytes32,bytes32,uint8,uint8,uint64)");
    bytes32 private constant HOOK_READY_TOPIC0 = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)");
    bytes32 private constant STAGE_MATERIALIZED_TOPIC0 =
        keccak256("StageMaterialized(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)");
    bytes32 private constant STAGE_EXECUTOR_ACTIVATED_TOPIC0 =
        keccak256("StageExecutorActivated(bytes32,bytes32,bytes32,address,bytes32,bytes32,uint256,string)");
    bytes32 private constant STAGE_EXECUTOR_PATCH_APPLIED_TOPIC0 =
        keccak256(
            "StageExecutorPatchApplied(bytes32,bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,uint256,string)"
        );
    bytes32 private constant DOCK_OPENED_TOPIC0 =
        keccak256("DockOpened(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,uint8,address)");
    bytes32 private constant DOCK_ATTACHED_TOPIC0 =
        keccak256("DockAttached(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,uint8,address)");
    bytes32 private constant DOCK_INPUT_SUBMITTED_TOPIC0 =
        keccak256("DockInputSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)");
    bytes32 private constant DOCK_OUTPUT_SUBMITTED_TOPIC0 =
        keccak256("DockOutputSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)");
    bytes32 private constant DOCK_OUTPUT_SATISFIED_TOPIC0 =
        keccak256("DockOutputSatisfied(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)");

    bool private bootstrapped;
    bool private baselineMode;

    // ------------------------------------------------------------------
    // bootstrap：装配世界
    // ------------------------------------------------------------------

    function bootstrap() external {
        require(!bootstrapped, "chaos: already bootstrapped");
        bootstrapped = true;
        baselineMode = true;

        machine = new UVPStateMachine();
        UVPStagePatchModule patch = new UVPStagePatchModule(address(machine));
        UVPDerivedSignalModule derived = new UVPDerivedSignalModule(address(machine));
        UVPPlanMetadataModule metadata = new UVPPlanMetadataModule(address(machine));
        docking = new UVPDockingModule(address(machine), address(metadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(machine));
        stagePatch = patch;
        machine.setStagePatchModule(address(patch));
        machine.setDerivedSignalModule(address(derived));
        machine.setDockingModule(address(docking));
        machine.setPlanMetadataModule(address(metadata));
        machine.setOrderLinkModule(address(orderLink));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
        machine.freezeModules();

        submitterAddr = vm.addr(SUBMITTER_PRIVATE_KEY);
        runtimeDomain = keccak256(abi.encode(DOMAIN_RUNTIME_EIP155, block.chainid, address(machine)));

        _computeDockStaticParts();
        // B-01 注册顺序：routeHash 承诺目标链上 planId——echo（链式对接的
        // 目标侧）先注册，plant 的链式路由叶按 echoPlanId 计算，mill 的
        // 路由叶按 plantPlanId 计算（计划间 dock 目标图必须是注册期 DAG，
        // 自指路由在身份上不可构造）。
        echoPlanId = _registerEchoPlantPlan();
        _computeChainRouteHashes();
        plantPlanId = _registerPlantPlan();
        _computeMillRouteHashes();
        millPlanId = _registerMillPlan();
        basePlanId = _registerBasePlan();

        for (uint256 i = 0; i < BASE_ORDER_COUNT; i++) {
            baseOrders[i] = _birthBaseOrder(i);
        }
        // plant 目标单先出生：mill 出生时绑定 attach 实例 id 需要它们。
        for (uint256 i = 0; i < PLANT_TARGET_COUNT; i++) {
            plantTargets[i] = _birthPlantTarget(i);
            echoTargets[i] = _birthEchoTarget(i);
        }
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            millOrders[i] = _birthMillOrder(i);
            machine.submitSignal(
                millPlanId,
                millOrders[i],
                SOURCE_MILL,
                SIG_LOT_SHIPPED,
                keccak256(abi.encode("chaos.mill.shipped", i)),
                keccak256(abi.encode("chaos.mill.shipped.idem", i)),
                _noAttribution()
            );
        }
        for (uint256 i = 0; i < FORK_PAYLOAD_COUNT; i++) {
            forkPayloads[i] = keccak256(abi.encode("chaos.fork.payload", i));
        }

        // 基线观察先建立 ghost 初值（不计数）；recordLogs 随后武装——
        // 事件计数与槽转移计数同一起点起跳。
        _observe();
        baselineMode = false;
        vm.recordLogs();
        vm.getRecordedLogs();
    }

    // ------------------------------------------------------------------
    // 随机面：动作全集（公共非 view 函数进自动收集集）
    // ------------------------------------------------------------------

    /// 直接事实提交：三计划全订单池 × 各自信号池。dock 子单与输出镜像槽
    /// 不在成功面——dock 出生通道不落显式授权，公共提交面恒
    /// UnauthorizedSignalSubmitter；对 dock 子单 entrance 事实的重放走下方
    /// 显式 revert 断言腿（受控验证 fail-closed，而非盲 _guarded）。
    function submitSignal(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        bytes32 planId;
        bytes32 orderId;
        bytes32 sourceId;
        bytes32 signalId;
        uint256 pick = seed % 14;
        if (pick < 8) {
            planId = basePlanId;
            orderId = _basePool((seed >> 16) % (BASE_ORDER_COUNT + forkChildren.length));
            (sourceId, signalId) = _baseSignalAt((seed >> 8) % BASE_SIGNAL_COUNT);
        } else if (pick < 11) {
            planId = millPlanId;
            orderId = millOrders[(seed >> 8) % MILL_ORDER_COUNT];
            (sourceId, signalId) = _millSignalAt((seed >> 12) % MILL_SIGNAL_COUNT);
        } else {
            planId = plantPlanId;
            orderId = _plantPool((seed >> 8) % (PLANT_TARGET_COUNT + _livePlantDockOrders()));
            (sourceId, signalId) = _plantSignalAt((seed >> 12) % PLANT_SIGNAL_COUNT);
        }
        if (planId == plantPlanId && sourceId == SOURCE_DYE && signalId == SIG_LOT_ARRIVED && _isLiveDockOrder(orderId)) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    UVPStateMachine.UnauthorizedSignalSubmitter.selector, orderId, sourceId, signalId, address(this)
                )
            );
            machine.submitSignal(
                planId,
                orderId,
                sourceId,
                signalId,
                keccak256(abi.encode("chaos.signal.payload", seed)),
                keccak256(abi.encode("chaos.signal.idem", seed)),
                _attributionFor(planId, sourceId, signalId)
            );
        } else {
            _guarded(
                abi.encodeCall(
                    machine.submitSignal,
                    (
                        planId,
                        orderId,
                        sourceId,
                        signalId,
                        keccak256(abi.encode("chaos.signal.payload", seed)),
                        keccak256(abi.encode("chaos.signal.idem", seed)),
                        _attributionFor(planId, sourceId, signalId)
                    )
                ),
                address(machine)
            );
        }
        _afterAction();
    }

    /// 转发提交（EIP-712）：含错签者与过期签名两个攻击变体。
    function submitSignalFor(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        bytes32 orderId = _basePool(seed % (BASE_ORDER_COUNT + forkChildren.length));
        (bytes32 sourceId, bytes32 signalId) = _baseSignalAt((seed >> 8) % BASE_SIGNAL_COUNT);
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        uint256 variant = (seed >> 16) % 3;
        uint256 deadline = variant == 2 ? block.timestamp - 1 : block.timestamp + 1 hours;
        bytes32 payloadHash = keccak256(abi.encode("chaos.for.payload", seed));
        bytes32 idempotencyKey = keccak256(abi.encode("chaos.for.idem", seed));
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNAL_FOR_TYPEHASH, basePlanId, orderId, sourceId, signalId, payloadHash, idempotencyKey, submitter, deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            variant == 1 ? ROGUE_PRIVATE_KEY : SUBMITTER_PRIVATE_KEY,
            keccak256(abi.encodePacked("\x19\x01", machine.DOMAIN_SEPARATOR(), structHash))
        );
        _guarded(
            abi.encodeCall(
                machine.submitSignalFor,
                (
                    basePlanId,
                    orderId,
                    sourceId,
                    signalId,
                    payloadHash,
                    idempotencyKey,
                    submitter,
                    deadline,
                    abi.encodePacked(r, s, v),
                    _attributionFor(basePlanId, sourceId, signalId)
                )
            ),
            address(machine)
        );
        _afterAction();
    }


    /// 工序追随者：按成衣工序阶梯（裁剪完成→质检→缝纫完成→批次封口）
    /// 推进随机订单的下一个缺口；随机注入返工/裁决信号。现实执行者按
    /// 工序行动，这条 handler 把深阶梯形态拉进随机面的可达集。
    function followGarmentProcess(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        bytes32 orderId = _basePool(seed % (BASE_ORDER_COUNT + forkChildren.length));
        uint256 variant = (seed >> 12) % 4;
        if (variant == 0) {
            _guarded(
                abi.encodeCall(
                    machine.submitSignal,
                    (
                        basePlanId,
                        orderId,
                        SOURCE_SHOP,
                        SIG_SEW_REWORK,
                        keccak256(abi.encode("chaos.ladder.rework", orderId, seed)),
                        keccak256(abi.encode("chaos.ladder.rework.idem", orderId, seed)),
                        _attributionFor(basePlanId, SOURCE_SHOP, SIG_SEW_REWORK)
                    )
                ),
                address(machine)
            );
        } else if (variant == 1) {
            _guarded(
                abi.encodeCall(
                    machine.submitSignal,
                    (
                        basePlanId,
                        orderId,
                        SOURCE_SHOP,
                        SIG_DISPUTE_RULED,
                        keccak256(abi.encode("chaos.ladder.dispute", orderId, seed)),
                        keccak256(abi.encode("chaos.ladder.dispute.idem", orderId, seed)),
                        _attributionFor(basePlanId, SOURCE_SHOP, SIG_DISPUTE_RULED)
                    )
                ),
                address(machine)
            );
        } else {
            (bytes32 sourceId, bytes32 signalId) = _nextLadderSignal(orderId);
            _guarded(
                abi.encodeCall(
                    machine.submitSignal,
                    (
                        basePlanId,
                        orderId,
                        sourceId,
                        signalId,
                        keccak256(abi.encode("chaos.ladder.payload", orderId, signalId, seed)),
                        keccak256(abi.encode("chaos.ladder.idem", orderId, signalId, seed)),
                        _attributionFor(basePlanId, sourceId, signalId)
                    )
                ),
                address(machine)
            );
        }
        _afterAction();
    }

    function _nextLadderSignal(bytes32 orderId) private view returns (bytes32 sourceId, bytes32 signalId) {
        if (!machine.hasSignal(basePlanId, orderId, SOURCE_SHOP, SIG_CUT_COMPLETED)) {
            return (SOURCE_SHOP, SIG_CUT_COMPLETED);
        }
        if (!machine.hasSignal(basePlanId, orderId, SOURCE_SHOP, SIG_QC_PASSED)) {
            return (SOURCE_SHOP, SIG_QC_PASSED);
        }
        if (!machine.hasSignal(basePlanId, orderId, SOURCE_SHOP, SIG_SEW_FINISHED)) {
            return (SOURCE_SHOP, SIG_SEW_FINISHED);
        }
        return (SOURCE_SHOP, SIG_SEW_BATCH_CLOSED);
    }

    function pokeTimer(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        bytes32 planId;
        bytes32 orderId;
        bytes32 hookId;
        uint256 pick = seed % 14;
        if (pick < 8) {
            planId = basePlanId;
            orderId = _basePool((seed >> 16) % (BASE_ORDER_COUNT + forkChildren.length));
            hookId = _baseHookAt((seed >> 8) % BASE_HOOK_COUNT);
        } else if (pick < 11) {
            planId = millPlanId;
            orderId = millOrders[(seed >> 8) % MILL_ORDER_COUNT];
            hookId = _millHookAt((seed >> 12) % MILL_HOOK_COUNT);
        } else {
            planId = plantPlanId;
            orderId = _plantPool((seed >> 8) % (PLANT_TARGET_COUNT + _livePlantDockOrders()));
            hookId = _plantHookAt((seed >> 12) % PLANT_HOOK_COUNT);
        }
        _guarded(abi.encodeCall(machine.pokeTimer, (planId, orderId, hookId)), address(machine));
        _afterAction();
    }

    /// 时间轴混沌：有界跳时（+1s..+3d）。
    function warpTime(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        vm.warp(block.timestamp + 1 + (seed % 259200));
        _afterAction();
    }

    /// new 模式开仓（铸成衣工厂子单）：首次成功，重放幂等 return false。
    function openDock(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        _guardedOpen(seed % MILL_ORDER_COUNT);
        _afterAction();
    }

    /// existing 模式挂接（不铸子单，同意门走目标单 creator 腿）。attach 走
    /// 染色阶段的独立路由（routeId ≠ openRouteId），与 open 对同一 mill 单
    /// 的 dockByLocalRoute 槽不争用——双模可并存。
    function attachDock(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        _guardedAttach(seed % MILL_ORDER_COUNT, (seed >> 4) % PLANT_TARGET_COUNT);
        _afterAction();
    }

    /// 链式对接：live dock 子单作为父再向外一层（open 铸孙单 / attach 挂
    /// 既有目标单），depth=2+ 进入可达集；同父子路由一次性，先到先钉。
    function chainDock(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        uint256 liveCount = _liveDockChildren();
        if (liveCount == 0) {
            _afterAction();
            return;
        }
        uint256 pick = seed % liveCount;
        uint256 chosen = type(uint256).max;
        uint256 seen;
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (dockChildLive[i]) {
                if (seen == pick) {
                    chosen = i;
                    break;
                }
                seen += 1;
            }
        }
        if ((seed >> 4) % 2 == 0) {
            _guardedChainOpen(chosen);
        } else {
            _guardedChainAttach(chosen, (seed >> 8) % PLANT_TARGET_COUNT);
        }
        _afterAction();
    }

    /// 挂接后的 input 交付（permissionless，幂等）。attach 路由的父侧
    /// hook 是出生钩（染色阶段），出生即 Ready。
    function submitDockedInput(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        uint256 idx = seed % (MILL_ORDER_COUNT * PLANT_TARGET_COUNT);
        _guarded(
            abi.encodeCall(
                docking.submitDockedInput,
                (
                    attachInstanceIds[idx],
                    HOOK_LOT_BIRTH,
                    attachInputBinding,
                    _coreAttribution(_attributionFor(plantPlanId, SOURCE_AUDIT, SIG_PLANT_AMENDED))
                )
            ),
            address(docking)
        );
        _afterAction();
    }

    /// 输出镜像回写（目标事实已成立时首投 true，重放幂等）。
    function submitDockedSignal(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        uint256 i = seed % MILL_ORDER_COUNT;
        bytes32 binding = (seed >> 4) % 2 == 0 ? garmentOutBinding : progressOutBinding;
        _guarded(
            abi.encodeCall(
                docking.submitDockedSignal,
                (openInstanceIds[i], binding, _coreAttribution(_noAttribution()))
            ),
            address(docking)
        );
        _afterAction();
    }

    /// 执行者变更（assign/handoff 自适应；handoff 携上一执行者会签）。
    /// selector 恒为 SUBMITTER（出生授权池带 EXECUTOR_PATCH 信号授权）。
    function applyStageExecutorPatch(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        bytes32 orderId = _basePool(seed % (BASE_ORDER_COUNT + forkChildren.length));
        address executor =
            (seed >> 8) % 2 == 0 ? vm.addr(FINISHER_A_PRIVATE_KEY) : vm.addr(FINISHER_B_PRIVATE_KEY);
        (uint256 count, address lastSubmitter,, bool ambiguous) =
            machine.stageSignalState(basePlanId, orderId, STAGE_FINISHING);
        (bool patchExists, address incumbent,,,, uint256 activeNonce,) =
            stagePatch.getActiveStageExecutorPatch(basePlanId, orderId, STAGE_FINISHING);

        IUVPStateMachineCore.SignalAuthorization[] memory auths = _finishingAuths(executor);
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        uint256 deadline = block.timestamp + 1 hours;
        UVPStagePatchModule.StageExecutorPatch memory patch = UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: STAGE_SEWING,
            targetStageId: STAGE_FINISHING,
            executor: executor,
            role: ROLE_EXECUTOR,
            executorMetadataHash: EXECUTOR_METADATA_HASH,
            mode: count == 0 ? MODE_ASSIGN : MODE_HANDOFF,
            previousExecutor: address(0),
            authorizationsHash: _coreAuthsHash(auths),
            patchHash: keccak256(abi.encode("chaos.patch", orderId, seed)),
            patchNonce: activeNonce + 1,
            metadataURI: "uvp-eth://chaos/garment-patch"
        });
        bytes memory previousExecutorSignature = "";
        if (count != 0) {
            patch.previousExecutor = patchExists ? incumbent : lastSubmitter;
            uint256 previousKey = _signableKey(patch.previousExecutor);
            if (!ambiguous && previousKey != 0) {
                bytes32 prevDigest = stagePatch.stageExecutorPatchDigest(basePlanId, orderId, patch, selector, deadline);
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(previousKey, prevDigest);
                previousExecutorSignature = abi.encodePacked(r, s, v);
            }
        }
        bytes32 digest = stagePatch.stageExecutorPatchDigest(basePlanId, orderId, patch, selector, deadline);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        _guarded(
            abi.encodeCall(
                stagePatch.applyStageExecutorPatchFor,
                (
                    basePlanId,
                    orderId,
                    patch,
                    selector,
                    deadline,
                    abi.encodePacked(sr, ss, sv),
                    previousExecutorSignature,
                    IUVPStateMachineCore.SelectorBindingProof({
                        selectorStageId: STAGE_SEWING,
                        proof: _merkleProofFor(
                            capabilityTables[basePlanId].sortedLeaves, _selectorBindingLeaf()
                        )
                    }),
                    _candidateProof(executor),
                    auths
                )
            ),
            address(stagePatch)
        );
        _afterAction();
    }

    /// 治理分叉：裁决信号存在即分叉，同载荷重放幂等拒绝。fork 子单全量
    /// 入池（线性去重，无上限）。
    function forkOrder(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        bytes32 parent = _basePool(seed % (BASE_ORDER_COUNT + forkChildren.length));
        bytes32 forkPayloadHash = forkPayloads[seed % FORK_PAYLOAD_COUNT];
        UVPStateMachine.ForkBirthFact[] memory facts = _forkBirthFacts(parent);
        _guarded(
            abi.encodeCall(
                machine.forkOrder,
                (basePlanId, parent, forkPayloadHash, SOURCE_SHOP, SIG_DISPUTE_RULED, facts, _baseAuthPool())
            ),
            address(machine)
        );
        bytes32 child = machine.forkOrderIdFor(basePlanId, parent, forkPayloadHash);
        if (machine.orderExists(basePlanId, child)) {
            bool known = false;
            for (uint256 i = 0; i < forkChildren.length; i++) {
                if (forkChildren[i] == child) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                forkChildren.push(child);
            }
        }
        _afterAction();
    }

    /// 新计划混入：成衣工坊变体（不同质检延时），重放幂等拒绝。
    function commitAltPlan(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        uint256 variant = seed % ALT_PLAN_COUNT;
        UVPStateMachine.CompactHook[] memory hooks = _altPlanHooks(variant);
        UVPStateMachine.PlanCommit memory commit = _planCommitTemplate(hooks, PUBLISHER_PRIVATE_KEY);
        bytes memory signature = _planCommitSignature(commit, PUBLISHER_PRIVATE_KEY);
        if (!altPlanCommitted[variant]) {
            _guarded(
                abi.encodeCall(
                    machine.commitPlan, (commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), signature)
                ),
                address(machine)
            );
            bytes32 candidate = machine.planIdFor(
                commit.publisher,
                machine.planRuntimeHash(
                    commit.hooksHash,
                    commit.capabilitiesRoot,
                    commit.dockRoutesRoot,
                    commit.dockInterfaceRoot,
                    commit.executorCandidatesRoot
                )
            );
            if (machine.planCommitted(candidate)) {
                _guarded(abi.encodeCall(machine.finalizePlan, (candidate)), address(machine));
                altPlanIds[variant] = candidate;
                altPlanCommitted[variant] = true;
            }
        } else {
            // 已注册变体的重放：仍走真通道（PlanAlreadyRegistered 被吸收，
            // revert-digest ghost 顺带复查零状态变更）。
            _guarded(
                abi.encodeCall(
                    machine.commitPlan, (commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), signature)
                ),
                address(machine)
            );
        }
        _afterAction();
    }

    /// 备选计划出生：已注册的 alt 计划铸首单，计划运行态（延时 / OR /
    /// AND×delay 钩）自此可达；未注册变体的出生 revert 由 _guarded 吸收。
    function birthAltOrder(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        uint256 variant = seed % ALT_PLAN_COUNT;
        if (!altOrderLive[variant]) {
            bytes32 payload = keccak256(abi.encode("chaos.alt.birth", variant));
            UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine
                .TriggerOrderFromOutsideRequest({
                    planId: altPlanIds[variant],
                    creator: address(this),
                    triggerHookId: _altBirthHookId(variant),
                    triggerStageId: _altBirthStageId(variant),
                    sourceId: SOURCE_BRAND,
                    signalId: _altBirthSignalId(variant),
                    payloadHash: payload,
                    idempotencyKey: keccak256(abi.encode("chaos.alt.idem", variant)),
                    submitter: submitterAddr,
                    deadline: type(uint256).max
                });
            UVPStateMachine.SignalAuthorization[] memory auths = _altAuthPool(variant);
            _guarded(
                abi.encodeCall(
                    machine.triggerOrderFromOutsideFor, (trigger, auths, _triggerSignature(trigger, auths), _noAttribution())
                ),
                address(machine)
            );
            bytes32 orderId =
                machine.triggerOrderIdFor(altPlanIds[variant], SOURCE_BRAND, _altBirthSignalId(variant), payload);
            if (machine.orderExists(altPlanIds[variant], orderId)) {
                altOrders[variant] = orderId;
                altOrderLive[variant] = true;
            }
        }
        _afterAction();
    }

    /// 备选计划信号面：对 live alt 单投 qc.passed / 变体 sew.finished，
    /// 驱动延时、OR、AND×delay 钩进入 Wait（dueAt 单调性的真实防线）。
    function submitAltSignal(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        uint256 liveCount;
        for (uint256 v = 0; v < ALT_PLAN_COUNT; v++) {
            if (altOrderLive[v]) {
                liveCount += 1;
            }
        }
        if (liveCount == 0) {
            _afterAction();
            return;
        }
        uint256 pick = seed % liveCount;
        uint256 variant = type(uint256).max;
        uint256 seen;
        for (uint256 v = 0; v < ALT_PLAN_COUNT; v++) {
            if (altOrderLive[v]) {
                if (seen == pick) {
                    variant = v;
                    break;
                }
                seen += 1;
            }
        }
        bytes32 signalId = (seed >> 8) % 2 == 0 ? SIG_QC_PASSED : _altSewSignalId(variant);
        _guarded(
            abi.encodeCall(
                machine.submitSignal,
                (
                    altPlanIds[variant],
                    altOrders[variant],
                    SOURCE_SHOP,
                    signalId,
                    keccak256(abi.encode("chaos.alt.payload", variant, seed)),
                    keccak256(abi.encode("chaos.alt.idem", variant, seed)),
                    _noAttribution()
                )
            ),
            address(machine)
        );
        _afterAction();
    }


    // ------------------------------------------------------------------
    // 动作执行外壳：digest 前后断言 + revert 事件零落断言
    // ------------------------------------------------------------------

    function _guarded(bytes memory callData, address target) private {
        bytes32 before = _worldDigest();
        (bool success,) = target.call(callData);
        _afterCall(success, before);
    }

    function _guardedOpen(uint256 i) private {
        bytes32 before = _worldDigest();
        (bool success,) = _tryOpen(i);
        _afterCall(success, before);
        if (success) {
            dockChildLive[i] = true;
        }
    }

    function _guardedAttach(uint256 i, uint256 j) private {
        bytes32 before = _worldDigest();
        (bool success,) = _tryAttach(i, j);
        _afterCall(success, before);
    }

    function _guardedChainOpen(uint256 i) private {
        bytes32 before = _worldDigest();
        (bool success,) = _tryChainOpen(i);
        _afterCall(success, before);
        if (success) {
            grandchildLive[i] = true;
        }
    }

    function _guardedChainAttach(uint256 i, uint256 j) private {
        bytes32 before = _worldDigest();
        (bool success,) = _tryChainAttach(i, j);
        _afterCall(success, before);
    }

    function _afterCall(bool success, bytes32 before) private {
        if (success) {
            return;
        }
        if (_worldDigest() != before) {
            revertDigestViolationCount += 1;
        }
        ChaosVm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && _isFactEventTopic0(logs[i].topics[0])) {
                revertEventViolationCount += 1;
                break;
            }
        }
    }

    /// 动作后统一：吃掉 recordLogs 增量并计数 SignalSubmitted，然后全量
    /// ghost 复查。
    function _afterAction() private {
        ChaosVm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == SIGNAL_SUBMITTED_TOPIC0) {
                signalSubmittedEventCount += 1;
            }
        }
        _observe();
    }

    // ------------------------------------------------------------------
    // ghost 观察：每动作后全量复查（fail-fast + 计数器）
    // ------------------------------------------------------------------

    function _observe() private {
        bytes32[] memory baseOrderList = _baseOrderList();
        _observePlan(basePlanId, _baseHookIds(), baseOrderList, _baseSignalSources(), _baseSignalIds());
        bytes32[MILL_ORDER_COUNT] memory millOrderList = millOrders;
        _observePlan(
            millPlanId,
            _millHookIds(),
            _fixedToArray3(millOrderList),
            _millSignalSources(),
            _millSignalIds()
        );
        bytes32[] memory plantOrderList = _plantOrderList();
        _observePlan(plantPlanId, _plantHookIds(), plantOrderList, _plantSignalSources(), _plantSignalIds());
        // echo 计划（链式对接目标侧）同口径观察：echo 目标单 + 链式子单。
        bytes32[] memory echoOrderList = _echoOrderList();
        _observePlan(echoPlanId, _plantHookIds(), echoOrderList, _plantSignalSources(), _plantSignalIds());
        for (uint256 v = 0; v < ALT_PLAN_COUNT; v++) {
            if (!altOrderLive[v]) {
                continue;
            }
            _observePlan(altPlanIds[v], _altHookIds(v), _single(altOrders[v]), _altSignalSources(v), _altSignalIds(v));
        }
        _observeDockDepth();
    }

    function _observePlan(
        bytes32 planId,
        bytes32[] memory hookIds,
        bytes32[] memory orders,
        bytes32[] memory signalSources,
        bytes32[] memory signalIds
    ) private {
        for (uint256 o = 0; o < orders.length; o++) {
            bytes32 orderId = orders[o];
            if (orderId == bytes32(0)) {
                continue;
            }
            for (uint256 h = 0; h < hookIds.length; h++) {
                bytes32 hookId = hookIds[h];
                try machine.getHookStatus(planId, orderId, hookId) returns (
                    UVPStateMachine.HookStatus status, uint64 dueAt, bool
                ) {
                    uint8 terminal = ghostTerminal[planId][orderId][hookId];
                    if (terminal != 0) {
                        if (uint8(status) != terminal) {
                            terminalViolationCount += 1;
                        }
                    } else if (
                        status == UVPStateMachine.HookStatus.Ready || status == UVPStateMachine.HookStatus.Cancelled
                    ) {
                        ghostTerminal[planId][orderId][hookId] = uint8(status);
                    }
                    if (status == UVPStateMachine.HookStatus.Wait) {
                        if (dueAt < ghostMaxWaitDueAt[planId][orderId][hookId]) {
                            waitDeadlineViolationCount += 1;
                        } else if (dueAt > ghostMaxWaitDueAt[planId][orderId][hookId]) {
                            ghostMaxWaitDueAt[planId][orderId][hookId] = dueAt;
                        }
                    }
                } catch {}
            }
            for (uint256 s = 0; s < signalIds.length; s++) {
                bytes32 sourceId = signalSources[s];
                bytes32 signalId = signalIds[s];
                try machine.getSignal(planId, orderId, sourceId, signalId) returns (
                    bool exists,
                    bytes32 payloadHash,
                    bytes32,
                    uint64,
                    address
                ) {
                    bytes32 key = keccak256(abi.encode(sourceId, signalId));
                    bytes32 first = ghostFirstPayload[planId][orderId][key];
                    if (!exists) {
                        if (first != bytes32(0)) {
                            // once-exists 的事实槽消失：吸收稳定性违例。
                            firstWriteViolationCount += 1;
                        }
                        continue;
                    }
                    if (first == bytes32(0)) {
                        ghostFirstPayload[planId][orderId][key] = payloadHash;
                        if (!baselineMode) {
                            signalSlotTransitionCount += 1;
                        }
                    } else if (payloadHash != first) {
                        firstWriteViolationCount += 1;
                    }
                } catch {}
            }
        }
    }

    function _observeDockDepth() private {
        uint8 maxEdges = docking.MAX_DOCK_EDGES();
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (docking.dockEdgeCountOfOrder(plantPlanId, dockChildIds[i]) > maxEdges) {
                dockDepthViolationCount += 1;
            }
            if (docking.dockEdgeCountOfOrder(echoPlanId, grandchildIds[i]) > maxEdges) {
                dockDepthViolationCount += 1;
            }
        }
        for (uint256 j = 0; j < PLANT_TARGET_COUNT; j++) {
            if (docking.dockEdgeCountOfOrder(plantPlanId, plantTargets[j]) > maxEdges) {
                dockDepthViolationCount += 1;
            }
            if (docking.dockEdgeCountOfOrder(echoPlanId, echoTargets[j]) > maxEdges) {
                dockDepthViolationCount += 1;
            }
        }
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (docking.dockEdgeCountOfOrder(millPlanId, millOrders[i]) > maxEdges) {
                dockDepthViolationCount += 1;
            }
        }
    }

    function _isFactEventTopic0(bytes32 topic0) private pure returns (bool) {
        return topic0 == SIGNAL_SUBMITTED_TOPIC0 || topic0 == SIGNAL_SUBMITTER_AUTHORIZED_TOPIC0
            || topic0 == HOOK_STATUS_CHANGED_TOPIC0 || topic0 == HOOK_READY_TOPIC0
            || topic0 == STAGE_MATERIALIZED_TOPIC0 || topic0 == STAGE_EXECUTOR_ACTIVATED_TOPIC0
            || topic0 == STAGE_EXECUTOR_PATCH_APPLIED_TOPIC0 || topic0 == DOCK_OPENED_TOPIC0
            || topic0 == DOCK_ATTACHED_TOPIC0 || topic0 == DOCK_INPUT_SUBMITTED_TOPIC0
            || topic0 == DOCK_OUTPUT_SUBMITTED_TOPIC0 || topic0 == DOCK_OUTPUT_SATISFIED_TOPIC0;
    }

    // ------------------------------------------------------------------
    // 世界 digest（revert 零状态变更断言的真值源）
    // ------------------------------------------------------------------

    function _worldDigest() private view returns (bytes32 digest) {
        // 滚动折叠：三计划 + live alt 计划全部钩子运行态（status/dueAt/
        // readyEmitted）与信号槽（exists/payload/submitter）、订单级显式
        // 信号授权位、执行者 patch 账本（缝纫/后整理双槽）、dock 账本
        //（实例存在性/深度/交付位）。
        bytes32[] memory baseOrderList = _baseOrderList();
        bytes32[] memory baseHooks = _baseHookIds();
        bytes32[] memory baseSources = _baseSignalSources();
        bytes32[] memory baseSignals = _baseSignalIds();
        digest =
            _foldPlanRuntime(digest, basePlanId, baseHooks, baseOrderList, baseSources, baseSignals, "base-runtime");
        bytes32[MILL_ORDER_COUNT] memory millOrderList = millOrders;
        digest = _foldPlanRuntime(
            digest,
            millPlanId,
            _millHookIds(),
            _fixedToArray3(millOrderList),
            _millSignalSources(),
            _millSignalIds(),
            "mill-runtime"
        );
        bytes32[] memory plantOrderList = _plantOrderList();
        digest = _foldPlanRuntime(
            digest, plantPlanId, _plantHookIds(), plantOrderList, _plantSignalSources(), _plantSignalIds(), "plant-runtime"
        );
        for (uint256 v = 0; v < ALT_PLAN_COUNT; v++) {
            if (!altOrderLive[v]) {
                continue;
            }
            digest = _foldPlanRuntime(
                digest,
                altPlanIds[v],
                _altHookIds(v),
                _single(altOrders[v]),
                _altSignalSources(v),
                _altSignalIds(v),
                "alt-runtime"
            );
        }
        digest = _foldAuthorizations(digest, basePlanId, baseOrderList, baseSources, baseSignals);
        digest = _foldAuthorizations(
            digest, millPlanId, _fixedToArray3(millOrderList), _millSignalSources(), _millSignalIds()
        );
        digest = _foldAuthorizations(digest, plantPlanId, plantOrderList, _plantSignalSources(), _plantSignalIds());
        for (uint256 o = 0; o < baseOrderList.length; o++) {
            if (baseOrderList[o] == bytes32(0)) {
                continue;
            }
            digest = keccak256(
                abi.encode(
                    digest,
                    "finishing-executor",
                    machine.activeStageExecutor(basePlanId, baseOrderList[o], STAGE_FINISHING)
                )
            );
            digest = _foldPatchSlot(digest, baseOrderList[o], STAGE_SEWING);
            digest = _foldPatchSlot(digest, baseOrderList[o], STAGE_FINISHING);
        }
        digest = _foldDockLedger(digest);
        digest = keccak256(abi.encode(digest, forkChildren.length));
    }

    function _foldPlanRuntime(
        bytes32 digest,
        bytes32 planId,
        bytes32[] memory hookIds,
        bytes32[] memory orders,
        bytes32[] memory signalSources,
        bytes32[] memory signalIds,
        bytes32 tag
    ) private view returns (bytes32) {
        for (uint256 o = 0; o < orders.length; o++) {
            if (orders[o] == bytes32(0)) {
                continue;
            }
            for (uint256 h = 0; h < hookIds.length; h++) {
                try machine.getHookStatus(planId, orders[o], hookIds[h]) returns (
                    UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted
                ) {
                    digest = keccak256(abi.encode(digest, tag, hookIds[h], uint8(status), dueAt, readyEmitted));
                } catch {}
            }
            for (uint256 s = 0; s < signalIds.length; s++) {
                try machine.getSignal(planId, orders[o], signalSources[s], signalIds[s]) returns (
                    bool exists,
                    bytes32 payloadHash,
                    bytes32,
                    uint64,
                    address submitter
                ) {
                    digest = keccak256(abi.encode(digest, tag, signalIds[s], exists, payloadHash, submitter));
                } catch {}
            }
        }
        return digest;
    }

    function _foldAuthorizations(
        bytes32 digest,
        bytes32 planId,
        bytes32[] memory orders,
        bytes32[] memory signalSources,
        bytes32[] memory signalIds
    ) private view returns (bytes32) {
        for (uint256 o = 0; o < orders.length; o++) {
            if (orders[o] == bytes32(0)) {
                continue;
            }
            for (uint256 s = 0; s < signalIds.length; s++) {
                digest = keccak256(
                    abi.encode(
                        digest,
                        "auth-handler",
                        signalIds[s],
                        machine.hasExplicitSignalAuthorization(
                            planId, orders[o], signalSources[s], signalIds[s], address(this)
                        )
                    )
                );
                digest = keccak256(
                    abi.encode(
                        digest,
                        "auth-submitter",
                        signalIds[s],
                        machine.hasExplicitSignalAuthorization(
                            planId, orders[o], signalSources[s], signalIds[s], submitterAddr
                        )
                    )
                );
            }
        }
        return digest;
    }

    function _foldPatchSlot(bytes32 digest, bytes32 orderId, bytes32 stageId) private view returns (bytes32) {
        (bool patchExists, address incumbent,,,, uint256 activeNonce,) =
            stagePatch.getActiveStageExecutorPatch(basePlanId, orderId, stageId);
        return keccak256(abi.encode(digest, "patch-slot", stageId, patchExists, incumbent, activeNonce));
    }

    function _foldDockLedger(bytes32 digest) private view returns (bytes32) {
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            digest = keccak256(abi.encode(digest, "mill-depth", docking.dockEdgeCountOfOrder(millPlanId, millOrders[i])));
        }
        bytes32[] memory plantOrderList = _plantOrderList();
        for (uint256 o = 0; o < plantOrderList.length; o++) {
            digest = keccak256(
                abi.encode(digest, "plant-depth", docking.dockEdgeCountOfOrder(plantPlanId, plantOrderList[o]))
            );
        }
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            digest = _foldDockInstance(digest, openInstanceIds[i]);
            digest = _foldDockInstance(digest, chainInstanceIds[i]);
            digest = _foldDockInstance(digest, grandchildIds[i]);
            digest = keccak256(
                abi.encode(
                    digest,
                    "dock-input-delivered",
                    openInstanceIds[i],
                    docking.dockInputDelivered(openInstanceIds[i], openEntranceBinding)
                )
            );
            digest = keccak256(
                abi.encode(
                    digest,
                    "dock-output-delivered",
                    openInstanceIds[i],
                    docking.dockOutputDelivered(openInstanceIds[i], garmentOutBinding),
                    docking.dockOutputDelivered(openInstanceIds[i], progressOutBinding)
                )
            );
            for (uint256 j = 0; j < PLANT_TARGET_COUNT; j++) {
                digest = _foldDockInstance(digest, attachInstanceIds[i * PLANT_TARGET_COUNT + j]);
                digest = _foldDockInstance(digest, chainAttachInstanceIds[i * PLANT_TARGET_COUNT + j]);
                digest = keccak256(
                    abi.encode(
                        digest,
                        "dock-input-delivered",
                        attachInstanceIds[i * PLANT_TARGET_COUNT + j],
                        docking.dockInputDelivered(attachInstanceIds[i * PLANT_TARGET_COUNT + j], attachInputBinding)
                    )
                );
            }
        }
        return digest;
    }

    function _foldDockInstance(bytes32 digest, bytes32 dockInstanceId) private view returns (bytes32) {
        (,,,,,,,, uint8 depth, bool exists) = docking.getActiveDock(dockInstanceId);
        return keccak256(abi.encode(digest, "dock-instance", dockInstanceId, exists, depth));
    }

    // ------------------------------------------------------------------
    // 池 helper
    // ------------------------------------------------------------------

    function _basePool(uint256 idx) private view returns (bytes32) {
        if (idx < BASE_ORDER_COUNT) {
            return baseOrders[idx];
        }
        uint256 childIdx = idx - BASE_ORDER_COUNT;
        if (childIdx < forkChildren.length) {
            return forkChildren[childIdx];
        }
        return baseOrders[0];
    }

    function _plantPool(uint256 idx) private view returns (bytes32) {
        if (idx < PLANT_TARGET_COUNT) {
            return plantTargets[idx];
        }
        uint256 childIdx = idx - PLANT_TARGET_COUNT;
        uint256 seen;
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (dockChildLive[i]) {
                if (seen == childIdx) {
                    return dockChildIds[i];
                }
                seen += 1;
            }
            if (grandchildLive[i]) {
                if (seen == childIdx) {
                    return grandchildIds[i];
                }
                seen += 1;
            }
        }
        return plantTargets[0];
    }

    function _liveDockChildren() private view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (dockChildLive[i]) {
                count += 1;
            }
        }
        return count;
    }

    function _livePlantDockOrders() private view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (dockChildLive[i]) {
                count += 1;
            }
            if (grandchildLive[i]) {
                count += 1;
            }
        }
        return count;
    }

    function _isLiveDockOrder(bytes32 orderId) private view returns (bool) {
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if ((dockChildLive[i] && dockChildIds[i] == orderId) || (grandchildLive[i] && grandchildIds[i] == orderId)) {
                return true;
            }
        }
        return false;
    }

    function _echoOrderList() private view returns (bytes32[] memory orders) {
        orders = new bytes32[](PLANT_TARGET_COUNT + _livePlantDockOrders());
        for (uint256 i = 0; i < PLANT_TARGET_COUNT; i++) {
            orders[i] = echoTargets[i];
        }
        uint256 cursor = PLANT_TARGET_COUNT;
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (grandchildLive[i]) {
                orders[cursor++] = grandchildIds[i];
            }
        }
    }

    function _baseOrderList() private view returns (bytes32[] memory orders) {
        orders = new bytes32[](BASE_ORDER_COUNT + forkChildren.length);
        for (uint256 i = 0; i < BASE_ORDER_COUNT; i++) {
            orders[i] = baseOrders[i];
        }
        for (uint256 i = 0; i < forkChildren.length; i++) {
            orders[BASE_ORDER_COUNT + i] = forkChildren[i];
        }
    }

    function _plantOrderList() private view returns (bytes32[] memory orders) {
        orders = new bytes32[](PLANT_TARGET_COUNT + _livePlantDockOrders());
        for (uint256 i = 0; i < PLANT_TARGET_COUNT; i++) {
            orders[i] = plantTargets[i];
        }
        uint256 cursor = PLANT_TARGET_COUNT;
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (dockChildLive[i]) {
                orders[cursor++] = dockChildIds[i];
            }
            if (grandchildLive[i]) {
                orders[cursor++] = grandchildIds[i];
            }
        }
    }

    function _baseSignalAt(uint256 idx) private pure returns (bytes32 sourceId, bytes32 signalId) {
        if (idx == 0) return (SOURCE_BRAND, SIG_ORDER_PLACED);
        if (idx == 1) return (SOURCE_SHOP, SIG_CUT_COMPLETED);
        if (idx == 2) return (SOURCE_SHOP, SIG_QC_PASSED);
        if (idx == 3) return (SOURCE_SHOP, SIG_SEW_FINISHED);
        if (idx == 4) return (SOURCE_SHOP, SIG_SEW_REWORK);
        if (idx == 5) return (SOURCE_SHOP, SIG_SEW_BATCH_CLOSED);
        if (idx == 6) return (SOURCE_SHOP, SIG_DISPUTE_RULED);
        return (SOURCE_SHOP, SIG_FINISH_IRONED);
    }

    function _baseSignalSources() private pure returns (bytes32[] memory sources) {
        sources = new bytes32[](BASE_SIGNAL_COUNT);
        for (uint256 i = 0; i < BASE_SIGNAL_COUNT; i++) {
            (sources[i],) = _baseSignalAt(i);
        }
    }

    function _baseSignalIds() private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](BASE_SIGNAL_COUNT);
        for (uint256 i = 0; i < BASE_SIGNAL_COUNT; i++) {
            (, ids[i]) = _baseSignalAt(i);
        }
    }

    function _millSignalAt(uint256 idx) private pure returns (bytes32 sourceId, bytes32 signalId) {
        if (idx == 0) return (SOURCE_MILL, SIG_LOT_STARTED);
        if (idx == 1) return (SOURCE_MILL, SIG_LOT_SHIPPED);
        // dock 输出镜像的本地落点：submitDockedSignal 的模块写路径槽位。
        if (idx == 2) return (SOURCE_MILL, SIG_MILL_RECEIVED);
        return (SOURCE_MILL, SIG_MILL_PROGRESS);
    }

    function _millSignalSources() private pure returns (bytes32[] memory sources) {
        sources = new bytes32[](MILL_SIGNAL_COUNT);
        for (uint256 i = 0; i < MILL_SIGNAL_COUNT; i++) {
            (sources[i],) = _millSignalAt(i);
        }
    }

    function _millSignalIds() private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](MILL_SIGNAL_COUNT);
        for (uint256 i = 0; i < MILL_SIGNAL_COUNT; i++) {
            (, ids[i]) = _millSignalAt(i);
        }
    }

    function _plantSignalAt(uint256 idx) private pure returns (bytes32 sourceId, bytes32 signalId) {
        if (idx == 0) return (SOURCE_BRAND, SIG_PLANT_ORDERED);
        if (idx == 1) return (SOURCE_DYE, SIG_LOT_ARRIVED);
        return (SOURCE_AUDIT, SIG_PLANT_AMENDED);
    }

    function _plantSignalSources() private pure returns (bytes32[] memory sources) {
        sources = new bytes32[](PLANT_SIGNAL_COUNT);
        for (uint256 i = 0; i < PLANT_SIGNAL_COUNT; i++) {
            (sources[i],) = _plantSignalAt(i);
        }
    }

    function _plantSignalIds() private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](PLANT_SIGNAL_COUNT);
        for (uint256 i = 0; i < PLANT_SIGNAL_COUNT; i++) {
            (, ids[i]) = _plantSignalAt(i);
        }
    }

    function _baseHookAt(uint256 idx) private pure returns (bytes32) {
        if (idx == 0) return HOOK_ORDER_BIRTH;
        if (idx == 1) return HOOK_CUT_DONE;
        if (idx == 2) return HOOK_QC_TIMER;
        if (idx == 3) return HOOK_SEW_VETO;
        if (idx == 4) return HOOK_SEW_CLOSED;
        return HOOK_IRON_DONE;
    }

    function _baseHookIds() private pure returns (bytes32[] memory hooks) {
        hooks = new bytes32[](BASE_HOOK_COUNT);
        for (uint256 i = 0; i < BASE_HOOK_COUNT; i++) {
            hooks[i] = _baseHookAt(i);
        }
    }

    function _millHookAt(uint256 idx) private pure returns (bytes32) {
        return idx == 0 ? HOOK_LOT_BIRTH : HOOK_SHIPPED;
    }

    function _millHookIds() private pure returns (bytes32[] memory hooks) {
        hooks = new bytes32[](MILL_HOOK_COUNT);
        for (uint256 i = 0; i < MILL_HOOK_COUNT; i++) {
            hooks[i] = _millHookAt(i);
        }
    }

    function _plantHookAt(uint256 idx) private pure returns (bytes32) {
        if (idx == 0) return HOOK_DOCK_ENTRANCE;
        if (idx == 1) return HOOK_PLANT_MINT;
        return HOOK_PLANT_RECEIVE;
    }

    function _plantHookIds() private pure returns (bytes32[] memory hooks) {
        hooks = new bytes32[](PLANT_HOOK_COUNT);
        for (uint256 i = 0; i < PLANT_HOOK_COUNT; i++) {
            hooks[i] = _plantHookAt(i);
        }
    }

    function _altSalt(uint256 variant) private pure returns (bytes32) {
        return keccak256(abi.encode("chaos.alt", variant));
    }

    function _altBirthHookId(uint256 variant) private pure returns (bytes32) {
        return keccak256(abi.encode(_altSalt(variant), "birth"));
    }

    function _altBirthStageId(uint256 variant) private pure returns (bytes32) {
        return keccak256(abi.encode(_altSalt(variant), "cutting"));
    }

    function _altBirthSignalId(uint256 variant) private pure returns (bytes32) {
        return keccak256(abi.encode(_altSalt(variant), "order.placed"));
    }

    function _altSewStageId(uint256 variant) private pure returns (bytes32) {
        return keccak256(abi.encode(_altSalt(variant), "sewing"));
    }

    function _altSewSignalId(uint256 variant) private pure returns (bytes32) {
        return keccak256(abi.encode(_altSalt(variant), "sew.finished"));
    }

    function _altSignalAt(uint256 variant, uint256 idx)
        private
        pure
        returns (bytes32 sourceId, bytes32 signalId)
    {
        if (idx == 0) return (SOURCE_BRAND, _altBirthSignalId(variant));
        if (idx == 1) return (SOURCE_SHOP, SIG_QC_PASSED);
        return (SOURCE_SHOP, _altSewSignalId(variant));
    }

    function _altSignalSources(uint256 variant) private pure returns (bytes32[] memory sources) {
        sources = new bytes32[](ALT_SIGNAL_COUNT);
        for (uint256 i = 0; i < ALT_SIGNAL_COUNT; i++) {
            (sources[i],) = _altSignalAt(variant, i);
        }
    }

    function _altSignalIds(uint256 variant) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](ALT_SIGNAL_COUNT);
        for (uint256 i = 0; i < ALT_SIGNAL_COUNT; i++) {
            (, ids[i]) = _altSignalAt(variant, i);
        }
    }

    function _altHookAt(uint256 variant, uint256 idx) private pure returns (bytes32) {
        if (idx == 0) return _altBirthHookId(variant);
        if (idx == 1) return keccak256(abi.encode(_altSalt(variant), "qc"));
        if (idx == 2) return keccak256(abi.encode(_altSalt(variant), "qc-or"));
        if (idx == 3) return keccak256(abi.encode(_altSalt(variant), "qc-and"));
        return keccak256(abi.encode(_altSalt(variant), "watch"));
    }

    function _altHookIds(uint256 variant) private pure returns (bytes32[] memory hooks) {
        hooks = new bytes32[](ALT_HOOK_COUNT);
        for (uint256 i = 0; i < ALT_HOOK_COUNT; i++) {
            hooks[i] = _altHookAt(variant, i);
        }
    }

    function _fixedToArray3(bytes32[MILL_ORDER_COUNT] memory fixedList)
        private
        pure
        returns (bytes32[] memory items)
    {
        items = new bytes32[](fixedList.length);
        for (uint256 i = 0; i < fixedList.length; i++) {
            items[i] = fixedList[i];
        }
    }

    // ------------------------------------------------------------------
    // 装配 helper：计划注册与出生
    // ------------------------------------------------------------------

    function _registerBasePlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](7);

        hooks[0] =
            _signalHook(HOOK_ORDER_BIRTH, STAGE_CUTTING, FLAG_MINT | FLAG_EMIT_READY, SOURCE_BRAND, SIG_ORDER_PLACED);
        hooks[1] = _signalHook(HOOK_CUT_DONE, STAGE_SEWING, FLAG_EMIT_READY, SOURCE_SHOP, SIG_CUT_COMPLETED);

        UVPStateMachine.Instruction[] memory qcInstrs = new UVPStateMachine.Instruction[](2);
        qcInstrs[0] = _sig(SOURCE_SHOP, SIG_QC_PASSED);
        qcInstrs[1] = _delay(300);
        hooks[2] = _hookWithFlags(HOOK_QC_TIMER, STAGE_SEWING, FLAG_EMIT_READY, qcInstrs, _deps(SOURCE_SHOP, SIG_QC_PASSED));

        // 否决位：缝纫完成 & ~返工（栈序：负臂先压再 NOT）。
        UVPStateMachine.Instruction[] memory vetoInstrs = new UVPStateMachine.Instruction[](4);
        vetoInstrs[0] = _sig(SOURCE_SHOP, SIG_SEW_REWORK);
        vetoInstrs[1] = _not();
        vetoInstrs[2] = _sig(SOURCE_SHOP, SIG_SEW_FINISHED);
        vetoInstrs[3] = _and(2);
        hooks[3] = _hookWithFlags(
            HOOK_SEW_VETO,
            STAGE_SEWING,
            FLAG_EMIT_READY,
            vetoInstrs,
            _deps2(SOURCE_SHOP, SIG_SEW_FINISHED, SOURCE_SHOP, SIG_SEW_REWORK)
        );

        // 后整理物化 primer：观测缝纫批次封口（缝纫阶段能力，观察者唯一）。
        hooks[4] =
            _signalHook(HOOK_SEW_CLOSED, STAGE_FINISHING, FLAG_EMIT_READY, SOURCE_SHOP, SIG_SEW_BATCH_CLOSED);
        hooks[5] = _signalHook(HOOK_IRON_DONE, STAGE_FINISHING, FLAG_EMIT_READY, SOURCE_SHOP, SIG_FINISH_IRONED);

        // 发射适格窗（flag=8 槽位）：窗口内 ¬(rework+60) 求值 value=true
        // 携衰减 dueAt——_requireSignalAdmission 只判 value/wait/cancel，
        // 窗口内同样放行（本钩不构成窗口排除）；decay 边界由 TS 侧
        // admission-window 场景负责。
        UVPStateMachine.Instruction[] memory admInstrs = new UVPStateMachine.Instruction[](5);
        admInstrs[0] = _sig(SOURCE_SHOP, SIG_QC_PASSED);
        admInstrs[1] = _sig(SOURCE_SHOP, SIG_SEW_REWORK);
        admInstrs[2] = _delay(60);
        admInstrs[3] = _not();
        admInstrs[4] = _and(2);
        hooks[6] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_SHOP, SIG_SEW_FINISHED)),
            stageId: STAGE_SEWING,
            hookName: keccak256(abi.encode("chaos.admission", SIG_SEW_FINISHED)),
            flags: FLAG_ADMISSION,
            instructions: admInstrs,
            dependencyKeys: _deps2(SOURCE_SHOP, SIG_QC_PASSED, SOURCE_SHOP, SIG_SEW_REWORK)
        });

        // 能力阶梯：cut.completed 属裁剪（物化 bootstrap），缝纫信号属缝纫，
        // finish.ironed 属后整理。
        SignalCapability[] memory capabilities = new SignalCapability[](8);
        capabilities[0] = SignalCapability(STAGE_CUTTING, SOURCE_BRAND, SIG_ORDER_PLACED, 0);
        capabilities[1] = SignalCapability(STAGE_CUTTING, SOURCE_SHOP, SIG_CUT_COMPLETED, 0);
        capabilities[2] = SignalCapability(STAGE_SEWING, SOURCE_SHOP, SIG_QC_PASSED, 0);
        capabilities[3] = SignalCapability(STAGE_SEWING, SOURCE_SHOP, SIG_SEW_FINISHED, 0);
        capabilities[4] = SignalCapability(STAGE_SEWING, SOURCE_SHOP, SIG_SEW_REWORK, 0);
        capabilities[5] = SignalCapability(STAGE_SEWING, SOURCE_SHOP, SIG_SEW_BATCH_CLOSED, 0);
        capabilities[6] = SignalCapability(STAGE_SEWING, SOURCE_SHOP, SIG_DISPUTE_RULED, 0);
        capabilities[7] = SignalCapability(STAGE_FINISHING, SOURCE_SHOP, SIG_FINISH_IRONED, 0);

        StageSelectorBinding[] memory bindings = new StageSelectorBinding[](1);
        bindings[0] = StageSelectorBinding(STAGE_SEWING, STAGE_FINISHING);

        UVPStateMachine.ExecutorCandidate[] memory candidates = new UVPStateMachine.ExecutorCandidate[](2);
        candidates[0] =
            UVPStateMachine.ExecutorCandidate({stageId: STAGE_FINISHING, executor: vm.addr(FINISHER_A_PRIVATE_KEY)});
        candidates[1] =
            UVPStateMachine.ExecutorCandidate({stageId: STAGE_FINISHING, executor: vm.addr(FINISHER_B_PRIVATE_KEY)});

        return _commitAndFinalize(hooks, bindings, capabilities, candidates, PUBLISHER_PRIVATE_KEY);
    }

    function _registerMillPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_LOT_BIRTH, STAGE_DYEING, FLAG_MINT | FLAG_EMIT_READY, SOURCE_MILL, SIG_LOT_STARTED);
        hooks[1] = _signalHook(HOOK_SHIPPED, STAGE_DISPATCH, FLAG_EMIT_READY, SOURCE_MILL, SIG_LOT_SHIPPED);
        UVPStateMachine.PlanCommit memory commit = _planCommitTemplate(hooks, MILL_PUBLISHER_PRIVATE_KEY);
        commit.dockRoutesRoot = DockMerkle.root(routeTreeLeaves);
        bytes memory signature = _planCommitSignature(commit, MILL_PUBLISHER_PRIVATE_KEY);
        bytes32 planId = machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), signature);
        machine.finalizePlan(planId);
        return planId;
    }

    function _registerPlantPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] =
            _signalHook(HOOK_DOCK_ENTRANCE, STAGE_WORKSHOP, FLAG_DOCK | FLAG_EMIT_READY, SOURCE_DYE, SIG_LOT_ARRIVED);
        hooks[1] = _signalHook(HOOK_PLANT_MINT, STAGE_WORKSHOP, FLAG_MINT | FLAG_EMIT_READY, SOURCE_BRAND, SIG_PLANT_ORDERED);
        hooks[2] = _signalHook(HOOK_PLANT_RECEIVE, STAGE_WORKSHOP, FLAG_EMIT_READY, SOURCE_AUDIT, SIG_PLANT_AMENDED);

        SignalCapability[] memory capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability(STAGE_WORKSHOP, SOURCE_BRAND, SIG_PLANT_ORDERED, 0);
        capabilities[1] = SignalCapability(STAGE_WORKSHOP, SOURCE_DYE, SIG_LOT_ARRIVED, 0);
        capabilities[2] = SignalCapability(STAGE_WORKSHOP, SOURCE_AUDIT, SIG_PLANT_AMENDED, 0);

        return _commitAndFinalizeWithRoots(
            hooks,
            capabilities,
            PLANT_PUBLISHER_PRIVATE_KEY,
            DockMerkle.root(_single(plantInterfaceLeaf)),
            DockMerkle.root(routeChainTreeLeaves)
        );
    }

    /// echo 计划：plant 接口承诺的镜像承载者（同 hooks/词表/接口根，独立
    /// publisher）——B-01 后计划不能把路由承诺给自己，链式对接的目标侧由
    /// echo 计划承接（接口叶仍按 PLANT_UID_ID 寻址：commitPlan 不校验叶与
    /// 定义的自洽，发布面自证在编译轨）。
    function _registerEchoPlantPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] =
            _signalHook(HOOK_DOCK_ENTRANCE, STAGE_WORKSHOP, FLAG_DOCK | FLAG_EMIT_READY, SOURCE_DYE, SIG_LOT_ARRIVED);
        hooks[1] = _signalHook(HOOK_PLANT_MINT, STAGE_WORKSHOP, FLAG_MINT | FLAG_EMIT_READY, SOURCE_BRAND, SIG_PLANT_ORDERED);
        hooks[2] = _signalHook(HOOK_PLANT_RECEIVE, STAGE_WORKSHOP, FLAG_EMIT_READY, SOURCE_AUDIT, SIG_PLANT_AMENDED);

        SignalCapability[] memory capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability(STAGE_WORKSHOP, SOURCE_BRAND, SIG_PLANT_ORDERED, 0);
        capabilities[1] = SignalCapability(STAGE_WORKSHOP, SOURCE_DYE, SIG_LOT_ARRIVED, 0);
        capabilities[2] = SignalCapability(STAGE_WORKSHOP, SOURCE_AUDIT, SIG_PLANT_AMENDED, 0);

        return _commitAndFinalizeWithRoots(
            hooks,
            capabilities,
            ECHO_PUBLISHER_PRIVATE_KEY,
            DockMerkle.root(_single(plantInterfaceLeaf)),
            DockMerkle.EMPTY_ROOT
        );
    }

    function _computeDockStaticParts() private {
        openRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, millDefinitionRef, STAGE_DISPATCH));
        // attach 独立路由（染色阶段）：与 open 的 dispatch 路由不同 routeId，
        // dockByLocalRoute 槽不争用，双模对同一 mill 单可并存。
        attachRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, millDefinitionRef, STAGE_DYEING));
        openEntranceBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                openRouteId,
                INTERFACE_NAME_ID,
                HOOK_SHIPPED,
                PORT_FABRIC_IN,
                SOURCE_DYE,
                SIG_LOT_ARRIVED
            )
        );
        attachInputBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                attachRouteId,
                INTERFACE_NAME_ID,
                HOOK_LOT_BIRTH,
                PORT_AUDIT_IN,
                SOURCE_AUDIT,
                SIG_PLANT_AMENDED
            )
        );
        garmentOutBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                openRouteId,
                INTERFACE_NAME_ID,
                SOURCE_MILL,
                SIG_MILL_RECEIVED,
                PORT_GARMENT_OUT,
                SOURCE_DYE,
                SIG_LOT_ARRIVED
            )
        );
        progressOutBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                openRouteId,
                INTERFACE_NAME_ID,
                SOURCE_MILL,
                SIG_MILL_PROGRESS,
                PORT_PROGRESS_OUT,
                SOURCE_DYE,
                SIG_LOT_ARRIVED
            )
        );
        attachGarmentOutBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                attachRouteId,
                INTERFACE_NAME_ID,
                SOURCE_MILL,
                SIG_MILL_RECEIVED,
                PORT_GARMENT_OUT,
                SOURCE_DYE,
                SIG_LOT_ARRIVED
            )
        );
        attachProgressOutBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                attachRouteId,
                INTERFACE_NAME_ID,
                SOURCE_MILL,
                SIG_MILL_PROGRESS,
                PORT_PROGRESS_OUT,
                SOURCE_DYE,
                SIG_LOT_ARRIVED
            )
        );
        fabricInLeaf =
            keccak256(abi.encode(DOMAIN_INTERFACE_INPUT, PLANT_UID_ID, INTERFACE_NAME_ID, PORT_FABRIC_IN, HOOK_DOCK_ENTRANCE));
        auditInLeaf =
            keccak256(abi.encode(DOMAIN_INTERFACE_INPUT, PLANT_UID_ID, INTERFACE_NAME_ID, PORT_AUDIT_IN, HOOK_PLANT_RECEIVE));
        plantInputsRoot = DockMerkle.root(_two(fabricInLeaf, auditInLeaf));
        garmentOutLeaf = keccak256(
            abi.encode(DOMAIN_INTERFACE_OUTPUT, PLANT_UID_ID, INTERFACE_NAME_ID, PORT_GARMENT_OUT, SOURCE_DYE, SIG_LOT_ARRIVED)
        );
        progressOutLeaf = keccak256(
            abi.encode(
                DOMAIN_INTERFACE_OUTPUT, PLANT_UID_ID, INTERFACE_NAME_ID, PORT_PROGRESS_OUT, SOURCE_DYE, SIG_LOT_ARRIVED
            )
        );
        plantOutputsRoot = DockMerkle.root(_two(garmentOutLeaf, progressOutLeaf));
        plantInterfaceLeaf = keccak256(
            abi.encode(DOMAIN_INTERFACE, PLANT_UID_ID, INTERFACE_NAME_ID, uint256(3), plantInputsRoot, plantOutputsRoot)
        );

    }

    /// mill→plant 路由哈希（域 V3，B-01）：目标 planId 入 preimage——plant
    /// 注册后计算，mill plan 提交路由叶。
    function _computeMillRouteHashes() private {
        openRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                millDefinitionRef,
                plantDefinitionRef,
                plantPlanId,
                INTERFACE_NAME_ID,
                uint256(0),
                DockMerkle.root(_single(openEntranceBinding)),
                DockMerkle.root(_two(garmentOutBinding, progressOutBinding))
            )
        );
        attachRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                millDefinitionRef,
                plantDefinitionRef,
                plantPlanId,
                INTERFACE_NAME_ID,
                uint256(1),
                DockMerkle.root(_single(attachInputBinding)),
                DockMerkle.root(_two(attachGarmentOutBinding, attachProgressOutBinding))
            )
        );
        routeTreeLeaves = _two(openRouteHash, attachRouteHash);
    }

    /// 链式对接路由（车间阶段，plant 子单 → echo 计划）：dock 子单作为父
    /// 再向外一层。B-01 起目标 planId（echoPlanId）入 preimage——echo 注册
    /// 后计算，plant plan 提交路由叶（计划不能自指）。
    function _computeChainRouteHashes() private {
        chainRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, plantDefinitionRef, STAGE_WORKSHOP));
        chainEntranceBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                chainRouteId,
                INTERFACE_NAME_ID,
                HOOK_DOCK_ENTRANCE,
                PORT_FABRIC_IN,
                SOURCE_DYE,
                SIG_LOT_ARRIVED
            )
        );
        chainAttachInputBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                chainRouteId,
                INTERFACE_NAME_ID,
                HOOK_DOCK_ENTRANCE,
                PORT_AUDIT_IN,
                SOURCE_AUDIT,
                SIG_PLANT_AMENDED
            )
        );
        chainOpenRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                plantDefinitionRef,
                plantDefinitionRef,
                echoPlanId,
                INTERFACE_NAME_ID,
                uint256(0),
                DockMerkle.root(_single(chainEntranceBinding)),
                DockMerkle.EMPTY_ROOT
            )
        );
        chainAttachRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                plantDefinitionRef,
                plantDefinitionRef,
                echoPlanId,
                INTERFACE_NAME_ID,
                uint256(1),
                DockMerkle.root(_single(chainAttachInputBinding)),
                DockMerkle.EMPTY_ROOT
            )
        );
        routeChainTreeLeaves = _two(chainOpenRouteHash, chainAttachRouteHash);
    }

    function _birthBaseOrder(uint256 idx) private returns (bytes32) {
        bytes32 payload = keccak256(abi.encode("chaos.base.birth", idx));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: basePlanId,
            creator: address(this),
            triggerHookId: HOOK_ORDER_BIRTH,
            triggerStageId: STAGE_CUTTING,
            sourceId: SOURCE_BRAND,
            signalId: SIG_ORDER_PLACED,
            payloadHash: payload,
            idempotencyKey: keccak256(abi.encode("chaos.base.idem", idx)),
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        UVPStateMachine.SignalAuthorization[] memory auths = _baseAuthPool();
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _triggerSignature(trigger, auths), _attributionFor(basePlanId, SOURCE_BRAND, SIG_ORDER_PLACED)
        );
        return machine.triggerOrderIdFor(basePlanId, SOURCE_BRAND, SIG_ORDER_PLACED, payload);
    }

    function _birthMillOrder(uint256 idx) private returns (bytes32) {
        bytes32 payload = keccak256(abi.encode("chaos.mill.birth", idx));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: millPlanId,
            creator: address(this),
            triggerHookId: HOOK_LOT_BIRTH,
            triggerStageId: STAGE_DYEING,
            sourceId: SOURCE_MILL,
            signalId: SIG_LOT_STARTED,
            payloadHash: payload,
            idempotencyKey: keccak256(abi.encode("chaos.mill.idem", idx)),
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](2);
        auths[0] = _auth(SOURCE_MILL, SIG_LOT_STARTED, address(this));
        auths[1] = _auth(SOURCE_MILL, SIG_LOT_SHIPPED, address(this));
        machine.triggerOrderFromOutsideFor(trigger, auths, _triggerSignature(trigger, auths), _noAttribution());
        bytes32 orderId = machine.triggerOrderIdFor(millPlanId, SOURCE_MILL, SIG_LOT_STARTED, payload);
        _bindDockDerivedIds(idx, orderId);
        return orderId;
    }

    function _birthPlantTarget(uint256 idx) private returns (bytes32) {
        bytes32 payload = keccak256(abi.encode("chaos.plant.birth", idx));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: plantPlanId,
            creator: address(this),
            triggerHookId: HOOK_PLANT_MINT,
            triggerStageId: STAGE_WORKSHOP,
            sourceId: SOURCE_BRAND,
            signalId: SIG_PLANT_ORDERED,
            payloadHash: payload,
            idempotencyKey: keccak256(abi.encode("chaos.plant.idem", idx)),
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](3);
        auths[0] = _auth(SOURCE_BRAND, SIG_PLANT_ORDERED, address(this));
        auths[1] = _auth(SOURCE_DYE, SIG_LOT_ARRIVED, address(this));
        auths[2] = _auth(SOURCE_AUDIT, SIG_PLANT_AMENDED, address(this));
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _triggerSignature(trigger, auths), _attributionFor(plantPlanId, SOURCE_BRAND, SIG_PLANT_ORDERED)
        );
        return machine.triggerOrderIdFor(plantPlanId, SOURCE_BRAND, SIG_PLANT_ORDERED, payload);
    }

    function _birthEchoTarget(uint256 idx) private returns (bytes32) {
        bytes32 payload = keccak256(abi.encode("chaos.echo.birth", idx));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: echoPlanId,
            creator: address(this),
            triggerHookId: HOOK_PLANT_MINT,
            triggerStageId: STAGE_WORKSHOP,
            sourceId: SOURCE_BRAND,
            signalId: SIG_PLANT_ORDERED,
            payloadHash: payload,
            idempotencyKey: keccak256(abi.encode("chaos.echo.idem", idx)),
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](3);
        auths[0] = _auth(SOURCE_BRAND, SIG_PLANT_ORDERED, address(this));
        auths[1] = _auth(SOURCE_DYE, SIG_LOT_ARRIVED, address(this));
        auths[2] = _auth(SOURCE_AUDIT, SIG_PLANT_AMENDED, address(this));
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _triggerSignature(trigger, auths), _attributionFor(echoPlanId, SOURCE_BRAND, SIG_PLANT_ORDERED)
        );
        return machine.triggerOrderIdFor(echoPlanId, SOURCE_BRAND, SIG_PLANT_ORDERED, payload);
    }

    function _bindDockDerivedIds(uint256 millIdx, bytes32 millOrderId) private {
        openInstanceIds[millIdx] = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                millPlanId,
                millDefinitionRef,
                millOrderId,
                openRouteId,
                openRouteHash,
                uint256(0),
                INTERFACE_NAME_ID,
                plantPlanId
            )
        );
        dockChildIds[millIdx] = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, openInstanceIds[millIdx], plantDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        for (uint256 j = 0; j < PLANT_TARGET_COUNT; j++) {
            attachInstanceIds[millIdx * PLANT_TARGET_COUNT + j] = keccak256(
                abi.encode(
                    DOMAIN_DOCK_INSTANCE,
                    runtimeDomain,
                    millPlanId,
                    millDefinitionRef,
                    millOrderId,
                    attachRouteId,
                    attachRouteHash,
                    uint256(1),
                    INTERFACE_NAME_ID,
                    plantPlanId,
                    plantTargets[j]
                )
            );
        }
        chainInstanceIds[millIdx] = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                plantPlanId,
                plantDefinitionRef,
                dockChildIds[millIdx],
                chainRouteId,
                chainOpenRouteHash,
                uint256(0),
                INTERFACE_NAME_ID,
                echoPlanId
            )
        );
        grandchildIds[millIdx] = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, chainInstanceIds[millIdx], plantDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        for (uint256 j = 0; j < PLANT_TARGET_COUNT; j++) {
            chainAttachInstanceIds[millIdx * PLANT_TARGET_COUNT + j] = keccak256(
                abi.encode(
                    DOMAIN_DOCK_INSTANCE,
                    runtimeDomain,
                    plantPlanId,
                    plantDefinitionRef,
                    dockChildIds[millIdx],
                    chainRouteId,
                    chainAttachRouteHash,
                    uint256(1),
                    INTERFACE_NAME_ID,
                    echoPlanId,
                    echoTargets[j]
                )
            );
        }
    }

    // ------------------------------------------------------------------
    // dock 动作构造
    // ------------------------------------------------------------------

    function _tryOpen(uint256 i) private returns (bool success, bytes memory returnData) {
        UVPDockingModule.OpenDockRequestV2 memory request = UVPDockingModule.OpenDockRequestV2({
            dockInstanceId: openInstanceIds[i],
            localPlanId: millPlanId,
            localOrderId: millOrders[i],
            localStageId: STAGE_DISPATCH,
            localHookId: HOOK_SHIPPED,
            localDefinitionRefHash: millDefinitionRef,
            routeId: openRouteId,
            routeHash: openRouteHash,
            interfaceNameId: INTERFACE_NAME_ID,
            targetUidId: PLANT_UID_ID,
            targetDefinitionRefHash: plantDefinitionRef,
            targetPlanId: plantPlanId,
            linkedOrderId: dockChildIds[i],
            targetStageId: STAGE_WORKSHOP,
            targetHookId: HOOK_DOCK_ENTRANCE,
            parentDepth: 0
        });
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](1);
        inputs[0] = UVPDockingModule.DockInputBindingArg({
            localHookId: HOOK_SHIPPED,
            portKey: PORT_FABRIC_IN,
            targetSourceId: SOURCE_DYE,
            targetSignalId: SIG_LOT_ARRIVED,
            bindingHash: openEntranceBinding
        });
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _openOutputs();
        IUVPStateMachineCore.FactAttribution[] memory outputAttributions = new IUVPStateMachineCore.FactAttribution[](2);
        outputAttributions[0] = _coreAttribution(_attributionFor(plantPlanId, SOURCE_DYE, SIG_LOT_ARRIVED));
        outputAttributions[1] = outputAttributions[0];
        return address(docking).call(
            abi.encodeCall(
                docking.openDockedOrder,
                (
                    _openCall(
                        request,
                        _routeProof(openRouteHash),
                        _openInterfaceProof(),
                        inputs,
                        outputs,
                        _openAuth(_permitEmpty(), _openConsent(request, PLANT_PUBLISHER_PRIVATE_KEY)),
                        outputAttributions,
                        _coreAttribution(_attributionFor(plantPlanId, SOURCE_DYE, SIG_LOT_ARRIVED))
                    )
                )
            )
        );
    }

    /// B-01 open 目标侧同意（chaos 线：handler ≠ publisher，必携签名）。
    function _openConsent(
        UVPDockingModule.OpenDockRequestV2 memory request,
        uint256 publisherKey
    ) private returns (UVPDockingModule.DockTargetConsentV1 memory) {
        UVPDockingModule.DockTargetConsentV1 memory consent;
        consent.nonce = 1;
        consent.deadline = type(uint256).max;
        bytes32 digest = docking.openConsentDigest(
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
        );
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(publisherKey, digest);
        consent.signature = abi.encodePacked(r, sv, v);
        return consent;
    }

    function _openAuth(
        UVPDockingModule.EntrancePermitV2 memory permit,
        UVPDockingModule.DockTargetConsentV1 memory consent
    ) private pure returns (UVPDockingModule.OpenAuthorizationV2 memory) {
        return UVPDockingModule.OpenAuthorizationV2({permit: permit, consent: consent});
    }

    function _openCall(
        UVPDockingModule.OpenDockRequestV2 memory request,
        bytes32[] memory routeProof,
        UVPDockingModule.DockInterfaceProofV2 memory interfaceProof,
        UVPDockingModule.DockInputBindingArg[] memory inputs,
        UVPDockingModule.DockOutputBindingArg[] memory outputs,
        UVPDockingModule.OpenAuthorizationV2 memory authorization,
        IUVPStateMachineCore.FactAttribution[] memory outputAttributions,
        IUVPStateMachineCore.FactAttribution memory entranceAttribution
    ) private pure returns (UVPDockingModule.OpenDockCallV1 memory) {
        return UVPDockingModule.OpenDockCallV1({
            request: request,
            routeProof: routeProof,
            interfaceProof: interfaceProof,
            inputs: inputs,
            outputs: outputs,
            authorization: authorization,
            outputAttributions: outputAttributions,
            entranceAttribution: entranceAttribution
        });
    }

    function _tryAttach(uint256 i, uint256 j) private returns (bool success, bytes memory returnData) {
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = UVPDockingModule.DockAttachInterfaceProofV1({
            commitment: UVPDockingModule.DockInterfaceCommitmentV2({
                orderModesWord: 3,
                inputsRoot: plantInputsRoot,
                outputsRoot: plantOutputsRoot
            }),
            interfaceProof: new bytes32[](0),
            candidateProof: new bytes32[](0)
        });
        UVPDockingModule.AttachDockRequestV1 memory request = UVPDockingModule.AttachDockRequestV1({
            dockInstanceId: attachInstanceIds[i * PLANT_TARGET_COUNT + j],
            localPlanId: millPlanId,
            localOrderId: millOrders[i],
            localStageId: STAGE_DYEING,
            localDefinitionRefHash: millDefinitionRef,
            routeId: attachRouteId,
            routeHash: attachRouteHash,
            interfaceNameId: INTERFACE_NAME_ID,
            targetUidId: PLANT_UID_ID,
            targetDefinitionRefHash: plantDefinitionRef,
            targetPlanId: plantPlanId,
            linkedOrderId: plantTargets[j],
            targetStageId: STAGE_WORKSHOP,
            parentDepth: 0,
            targetCandidatesRoot: bytes32(0)
        });
        UVPDockingModule.AttachInputBindingArg[] memory inputs = new UVPDockingModule.AttachInputBindingArg[](1);
        inputs[0] = UVPDockingModule.AttachInputBindingArg({
            localHookId: HOOK_LOT_BIRTH,
            portKey: PORT_AUDIT_IN,
            targetSourceId: SOURCE_AUDIT,
            targetSignalId: SIG_PLANT_AMENDED,
            bindingHash: attachInputBinding,
            targetHookId: HOOK_PLANT_RECEIVE,
            portProof: _array1(fabricInLeaf)
        });
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _attachOutputs();
        IUVPStateMachineCore.FactAttribution[] memory outputAttributions = new IUVPStateMachineCore.FactAttribution[](2);
        outputAttributions[0] = _coreAttribution(_attributionFor(plantPlanId, SOURCE_DYE, SIG_LOT_ARRIVED));
        outputAttributions[1] = outputAttributions[0];
        return address(docking).call(
            abi.encodeCall(
                docking.attachDockedOrder,
                (request, _routeProof(attachRouteHash), proof, inputs, outputs, _permitEmpty(), outputAttributions)
            )
        );
    }

    function _openOutputs() private view returns (UVPDockingModule.DockOutputBindingArg[] memory outputs) {
        outputs = new UVPDockingModule.DockOutputBindingArg[](2);
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: SOURCE_MILL,
            localSignalId: SIG_MILL_RECEIVED,
            portKey: PORT_GARMENT_OUT,
            targetSourceId: SOURCE_DYE,
            targetSignalId: SIG_LOT_ARRIVED,
            bindingHash: garmentOutBinding,
            portProof: _array1(progressOutLeaf)
        });
        outputs[1] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: SOURCE_MILL,
            localSignalId: SIG_MILL_PROGRESS,
            portKey: PORT_PROGRESS_OUT,
            targetSourceId: SOURCE_DYE,
            targetSignalId: SIG_LOT_ARRIVED,
            bindingHash: progressOutBinding,
            portProof: _array1(garmentOutLeaf)
        });
    }

    function _attachOutputs() private view returns (UVPDockingModule.DockOutputBindingArg[] memory outputs) {
        outputs = new UVPDockingModule.DockOutputBindingArg[](2);
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: SOURCE_MILL,
            localSignalId: SIG_MILL_RECEIVED,
            portKey: PORT_GARMENT_OUT,
            targetSourceId: SOURCE_DYE,
            targetSignalId: SIG_LOT_ARRIVED,
            bindingHash: attachGarmentOutBinding,
            portProof: _array1(progressOutLeaf)
        });
        outputs[1] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: SOURCE_MILL,
            localSignalId: SIG_MILL_PROGRESS,
            portKey: PORT_PROGRESS_OUT,
            targetSourceId: SOURCE_DYE,
            targetSignalId: SIG_LOT_ARRIVED,
            bindingHash: attachProgressOutBinding,
            portProof: _array1(garmentOutLeaf)
        });
    }

    function _openInterfaceProof() private view returns (UVPDockingModule.DockInterfaceProofV2 memory proof) {
        proof = UVPDockingModule.DockInterfaceProofV2({
            entranceLeaf: UVPDockingModule.DockInterfacePortLeafV2({
                leafHash: fabricInLeaf,
                portKey: PORT_FABRIC_IN,
                hookKey: HOOK_DOCK_ENTRANCE
            }),
            portProof: _array1(auditInLeaf),
            commitment: UVPDockingModule.DockInterfaceCommitmentV2({
                orderModesWord: 3,
                inputsRoot: plantInputsRoot,
                outputsRoot: plantOutputsRoot
            }),
            interfaceProof: new bytes32[](0)
        });
    }

    function _tryChainOpen(uint256 i) private returns (bool success, bytes memory returnData) {
        UVPDockingModule.OpenDockRequestV2 memory request = UVPDockingModule.OpenDockRequestV2({
            dockInstanceId: chainInstanceIds[i],
            localPlanId: plantPlanId,
            localOrderId: dockChildIds[i],
            localStageId: STAGE_WORKSHOP,
            localHookId: HOOK_DOCK_ENTRANCE,
            localDefinitionRefHash: plantDefinitionRef,
            routeId: chainRouteId,
            routeHash: chainOpenRouteHash,
            interfaceNameId: INTERFACE_NAME_ID,
            targetUidId: PLANT_UID_ID,
            targetDefinitionRefHash: plantDefinitionRef,
            targetPlanId: echoPlanId,
            linkedOrderId: grandchildIds[i],
            targetStageId: STAGE_WORKSHOP,
            targetHookId: HOOK_DOCK_ENTRANCE,
            parentDepth: docking.dockEdgeCountOfOrder(plantPlanId, dockChildIds[i])
        });
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](1);
        inputs[0] = UVPDockingModule.DockInputBindingArg({
            localHookId: HOOK_DOCK_ENTRANCE,
            portKey: PORT_FABRIC_IN,
            targetSourceId: SOURCE_DYE,
            targetSignalId: SIG_LOT_ARRIVED,
            bindingHash: chainEntranceBinding
        });
        return address(docking).call(
            abi.encodeCall(
                docking.openDockedOrder,
                (
                    _openCall(
                        request,
                        _routeProof(chainOpenRouteHash),
                        _openInterfaceProof(),
                        inputs,
                        new UVPDockingModule.DockOutputBindingArg[](0),
                        _openAuth(_permitEmpty(), _openConsent(request, ECHO_PUBLISHER_PRIVATE_KEY)),
                        new IUVPStateMachineCore.FactAttribution[](0),
                        _coreAttribution(_attributionFor(echoPlanId, SOURCE_DYE, SIG_LOT_ARRIVED))
                    )
                )
            )
        );
    }

    function _tryChainAttach(uint256 i, uint256 j) private returns (bool success, bytes memory returnData) {
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = UVPDockingModule.DockAttachInterfaceProofV1({
            commitment: UVPDockingModule.DockInterfaceCommitmentV2({
                orderModesWord: 3,
                inputsRoot: plantInputsRoot,
                outputsRoot: plantOutputsRoot
            }),
            interfaceProof: new bytes32[](0),
            candidateProof: new bytes32[](0)
        });
        UVPDockingModule.AttachDockRequestV1 memory request = UVPDockingModule.AttachDockRequestV1({
            dockInstanceId: chainAttachInstanceIds[i * PLANT_TARGET_COUNT + j],
            localPlanId: plantPlanId,
            localOrderId: dockChildIds[i],
            localStageId: STAGE_WORKSHOP,
            localDefinitionRefHash: plantDefinitionRef,
            routeId: chainRouteId,
            routeHash: chainAttachRouteHash,
            interfaceNameId: INTERFACE_NAME_ID,
            targetUidId: PLANT_UID_ID,
            targetDefinitionRefHash: plantDefinitionRef,
            targetPlanId: echoPlanId,
            linkedOrderId: echoTargets[j],
            targetStageId: STAGE_WORKSHOP,
            parentDepth: docking.dockEdgeCountOfOrder(plantPlanId, dockChildIds[i]),
            targetCandidatesRoot: bytes32(0)
        });
        UVPDockingModule.AttachInputBindingArg[] memory inputs = new UVPDockingModule.AttachInputBindingArg[](1);
        inputs[0] = UVPDockingModule.AttachInputBindingArg({
            localHookId: HOOK_DOCK_ENTRANCE,
            portKey: PORT_AUDIT_IN,
            targetSourceId: SOURCE_AUDIT,
            targetSignalId: SIG_PLANT_AMENDED,
            bindingHash: chainAttachInputBinding,
            targetHookId: HOOK_PLANT_RECEIVE,
            portProof: _array1(fabricInLeaf)
        });
        return address(docking).call(
            abi.encodeCall(
                docking.attachDockedOrder,
                (
                    request,
                    _routeProof(chainAttachRouteHash),
                    proof,
                    inputs,
                    new UVPDockingModule.DockOutputBindingArg[](0),
                    _permitEmpty(),
                    new IUVPStateMachineCore.FactAttribution[](0)
                )
            )
        );
    }

    function _routeProof(bytes32 routeHash) private view returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        if (routeHash == openRouteHash) {
            proof[0] = attachRouteHash;
        } else if (routeHash == attachRouteHash) {
            proof[0] = openRouteHash;
        } else if (routeHash == chainOpenRouteHash) {
            proof[0] = chainAttachRouteHash;
        } else {
            proof[0] = chainOpenRouteHash;
        }
    }

    function _permitEmpty() private pure returns (UVPDockingModule.EntrancePermitV2 memory) {
        return UVPDockingModule.EntrancePermitV2({nonce: 0, deadline: 0, signature: ""});
    }

    // ------------------------------------------------------------------
    // fork / patch 构造
    // ------------------------------------------------------------------

    function _forkBirthFacts(bytes32 parent)
        private
        view
        returns (UVPStateMachine.ForkBirthFact[] memory facts)
    {
        facts = new UVPStateMachine.ForkBirthFact[](2);
        (bool birthExists, bytes32 birthPayload, bytes32 birthIdem,,) =
            machine.getSignal(basePlanId, parent, SOURCE_BRAND, SIG_ORDER_PLACED);
        (bool ruledExists, bytes32 ruledPayload, bytes32 ruledIdem,,) =
            machine.getSignal(basePlanId, parent, SOURCE_SHOP, SIG_DISPUTE_RULED);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BRAND,
            signalId: SIG_ORDER_PLACED,
            payloadHash: birthExists ? birthPayload : bytes32(uint256(0xDEAD)),
            idempotencyKey: birthExists ? birthIdem : bytes32(uint256(0xDEAD))
        });
        facts[1] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_SHOP,
            signalId: SIG_DISPUTE_RULED,
            payloadHash: ruledExists ? ruledPayload : bytes32(uint256(0xDEAD)),
            idempotencyKey: ruledExists ? ruledIdem : bytes32(uint256(0xDEAD))
        });
    }

    function _baseAuthPool() private returns (UVPStateMachine.SignalAuthorization[] memory auths) {
        address signer = vm.addr(SUBMITTER_PRIVATE_KEY);
        auths = new UVPStateMachine.SignalAuthorization[](17);
        auths[0] = _auth(SOURCE_BRAND, SIG_ORDER_PLACED, address(this));
        auths[1] = _auth(SOURCE_BRAND, SIG_ORDER_PLACED, signer);
        auths[2] = _auth(SOURCE_SHOP, SIG_CUT_COMPLETED, address(this));
        auths[3] = _auth(SOURCE_SHOP, SIG_CUT_COMPLETED, signer);
        auths[4] = _auth(SOURCE_SHOP, SIG_QC_PASSED, address(this));
        auths[5] = _auth(SOURCE_SHOP, SIG_QC_PASSED, signer);
        auths[6] = _auth(SOURCE_SHOP, SIG_SEW_FINISHED, address(this));
        auths[7] = _auth(SOURCE_SHOP, SIG_SEW_FINISHED, signer);
        auths[8] = _auth(SOURCE_SHOP, SIG_SEW_REWORK, address(this));
        auths[9] = _auth(SOURCE_SHOP, SIG_SEW_REWORK, signer);
        auths[10] = _auth(SOURCE_SHOP, SIG_SEW_BATCH_CLOSED, address(this));
        auths[11] = _auth(SOURCE_SHOP, SIG_SEW_BATCH_CLOSED, signer);
        auths[12] = _auth(SOURCE_SHOP, SIG_DISPUTE_RULED, address(this));
        auths[13] = _auth(SOURCE_SHOP, SIG_DISPUTE_RULED, signer);
        auths[14] = _auth(SOURCE_SHOP, SIG_FINISH_IRONED, signer);
        auths[15] = _auth(SOURCE_SHOP, SIG_FINISH_IRONED, vm.addr(FINISHER_A_PRIVATE_KEY));
        // patch selector 腿：SUBMITTER 对 EXECUTOR_PATCH 信号的显式授权。
        auths[16] = _auth(STAGE_SEWING, EXECUTOR_PATCH_SIGNAL_ID, signer);
    }

    function _finishingAuths(address executor)
        private
        pure
        returns (IUVPStateMachineCore.SignalAuthorization[] memory auths)
    {
        auths = new IUVPStateMachineCore.SignalAuthorization[](1);
        auths[0] = IUVPStateMachineCore.SignalAuthorization({
            sourceId: SOURCE_SHOP,
            signalId: SIG_FINISH_IRONED,
            submitter: executor,
            role: ROLE_EXECUTOR,
            metadataHash: EXECUTOR_METADATA_HASH
        });
    }

    function _coreAuthsHash(IUVPStateMachineCore.SignalAuthorization[] memory auths)
        private
        pure
        returns (bytes32 rollingHash)
    {
        rollingHash = keccak256(abi.encode(auths.length));
        for (uint256 i = 0; i < auths.length; i++) {
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    auths[i].sourceId,
                    auths[i].signalId,
                    auths[i].submitter,
                    auths[i].role,
                    auths[i].metadataHash
                )
            );
        }
    }

    function _selectorBindingLeaf() private pure returns (bytes32) {
        return keccak256(abi.encode(SELECTOR_BINDING_LEAF_DOMAIN, STAGE_SEWING, STAGE_FINISHING));
    }

    function _candidateProof(address executor) private view returns (bytes32[] memory) {
        bytes32 leaf = keccak256(abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, STAGE_FINISHING, executor));
        return _merkleProofFor(capabilityTables[basePlanId].candidateLeaves, leaf);
    }

    /// 已知私钥地址 → 私钥；其余（如 handler 合约自身）不可签名，返回 0。
    function _signableKey(address account) private returns (uint256) {
        if (account == vm.addr(FINISHER_A_PRIVATE_KEY)) {
            return FINISHER_A_PRIVATE_KEY;
        }
        if (account == vm.addr(FINISHER_B_PRIVATE_KEY)) {
            return FINISHER_B_PRIVATE_KEY;
        }
        if (account == vm.addr(SUBMITTER_PRIVATE_KEY)) {
            return SUBMITTER_PRIVATE_KEY;
        }
        return 0;
    }

    function _altPlanHooks(uint256 variant)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        bytes32 salt = _altSalt(variant);
        bytes32 sewingStageId = _altSewStageId(variant);
        bytes32 sewSignalId = _altSewSignalId(variant);
        hooks = new UVPStateMachine.CompactHook[](5);
        hooks[0] = _signalHook(
            _altBirthHookId(variant),
            _altBirthStageId(variant),
            FLAG_MINT | FLAG_EMIT_READY,
            SOURCE_BRAND,
            _altBirthSignalId(variant)
        );
        UVPStateMachine.Instruction[] memory delayInstrs = new UVPStateMachine.Instruction[](2);
        delayInstrs[0] = _sig(SOURCE_SHOP, SIG_QC_PASSED);
        delayInstrs[1] = _delay(variant == 0 ? 5 : (variant == 1 ? 30 : 300));
        hooks[1] = _hookWithFlags(
            keccak256(abi.encode(salt, "qc")), sewingStageId, FLAG_EMIT_READY, delayInstrs, _deps(SOURCE_SHOP, SIG_QC_PASSED)
        );
        // OR 形态：qc.passed ∨ 变体 sew.finished——等待期限取最早就绪成员。
        UVPStateMachine.Instruction[] memory orInstrs = new UVPStateMachine.Instruction[](3);
        orInstrs[0] = _sig(SOURCE_SHOP, SIG_QC_PASSED);
        orInstrs[1] = _sig(SOURCE_SHOP, sewSignalId);
        orInstrs[2] = _or(2);
        hooks[2] = _hookWithFlags(
            keccak256(abi.encode(salt, "qc-or")),
            sewingStageId,
            FLAG_EMIT_READY,
            orInstrs,
            _deps2(SOURCE_SHOP, SIG_QC_PASSED, SOURCE_SHOP, sewSignalId)
        );
        // AND×delay 混合形态：双臂各自延时后合取——等待期限取最晚成员。
        UVPStateMachine.Instruction[] memory andInstrs = new UVPStateMachine.Instruction[](5);
        andInstrs[0] = _sig(SOURCE_SHOP, SIG_QC_PASSED);
        andInstrs[1] = _delay(variant == 0 ? 9 : (variant == 1 ? 45 : 280));
        andInstrs[2] = _sig(SOURCE_SHOP, sewSignalId);
        andInstrs[3] = _delay(variant == 0 ? 13 : (variant == 1 ? 70 : 330));
        andInstrs[4] = _and(2);
        hooks[3] = _hookWithFlags(
            keccak256(abi.encode(salt, "qc-and")),
            sewingStageId,
            FLAG_EMIT_READY,
            andInstrs,
            _deps2(SOURCE_SHOP, SIG_QC_PASSED, SOURCE_SHOP, sewSignalId)
        );
        hooks[4] =
            _signalHook(keccak256(abi.encode(salt, "watch")), sewingStageId, FLAG_EMIT_READY, SOURCE_SHOP, sewSignalId);
    }

    function _altAuthPool(uint256 variant)
        private
        view
        returns (UVPStateMachine.SignalAuthorization[] memory auths)
    {
        bytes32 birthSignalId = _altBirthSignalId(variant);
        bytes32 sewSignalId = _altSewSignalId(variant);
        auths = new UVPStateMachine.SignalAuthorization[](6);
        auths[0] = _auth(SOURCE_BRAND, birthSignalId, address(this));
        auths[1] = _auth(SOURCE_BRAND, birthSignalId, submitterAddr);
        auths[2] = _auth(SOURCE_SHOP, SIG_QC_PASSED, address(this));
        auths[3] = _auth(SOURCE_SHOP, SIG_QC_PASSED, submitterAddr);
        auths[4] = _auth(SOURCE_SHOP, sewSignalId, address(this));
        auths[5] = _auth(SOURCE_SHOP, sewSignalId, submitterAddr);
    }

    // ------------------------------------------------------------------
    // 注册与签名 helper
    // ------------------------------------------------------------------

    function _commitAndFinalize(
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory bindings,
        SignalCapability[] memory capabilities,
        UVPStateMachine.ExecutorCandidate[] memory candidates,
        uint256 publisherKey
    ) private returns (bytes32) {
        bytes32[] memory leaves = _capabilityLeaves(bindings, capabilities);
        bytes32[] memory candidateLeaves = _candidateLeaves(candidates);
        UVPStateMachine.PlanCommit memory commit = _planCommitTemplate(hooks, publisherKey);
        commit.capabilitiesRoot = DockMerkle.root(leaves);
        commit.executorCandidatesRoot = DockMerkle.root(candidateLeaves);
        bytes memory signature = _planCommitSignature(commit, publisherKey);
        bytes32 planId = machine.commitPlan(commit, hooks, candidates, signature);
        CapabilityTables storage tables = capabilityTables[planId];
        tables.capabilities = capabilities;
        tables.sortedLeaves = _sortedUnique(leaves);
        tables.candidateLeaves = _sortedUnique(candidateLeaves);
        machine.finalizePlan(planId);
        return planId;
    }

    function _commitAndFinalizeWithRoots(
        UVPStateMachine.CompactHook[] memory hooks,
        SignalCapability[] memory capabilities,
        uint256 publisherKey,
        bytes32 dockInterfaceRoot,
        bytes32 dockRoutesRoot
    ) private returns (bytes32) {
        bytes32[] memory leaves = _capabilityLeaves(new StageSelectorBinding[](0), capabilities);
        UVPStateMachine.PlanCommit memory commit = _planCommitTemplate(hooks, publisherKey);
        commit.capabilitiesRoot = DockMerkle.root(leaves);
        commit.dockInterfaceRoot = dockInterfaceRoot;
        commit.dockRoutesRoot = dockRoutesRoot;
        bytes memory signature = _planCommitSignature(commit, publisherKey);
        bytes32 planId = machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), signature);
        CapabilityTables storage tables = capabilityTables[planId];
        tables.capabilities = capabilities;
        tables.sortedLeaves = _sortedUnique(leaves);
        machine.finalizePlan(planId);
        return planId;
    }

    function _planCommitTemplate(
        UVPStateMachine.CompactHook[] memory hooks,
        uint256 publisherKey
    ) private returns (UVPStateMachine.PlanCommit memory commit) {
        commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(publisherKey),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.EMPTY_ROOT,
            dockRoutesRoot: DockMerkle.EMPTY_ROOT,
            dockInterfaceRoot: DockMerkle.EMPTY_ROOT,
            executorCandidatesRoot: DockMerkle.EMPTY_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
    }

    function _planCommitSignature(
        UVPStateMachine.PlanCommit memory commit,
        uint256 publisherKey
    ) private returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.capabilitiesRoot,
                commit.dockRoutesRoot,
                commit.dockInterfaceRoot,
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        EIP712_DOMAIN_TYPEHASH,
                        STATE_MACHINE_NAME_HASH,
                        STATE_MACHINE_VERSION_HASH,
                        block.chainid,
                        address(machine)
                    )
                ),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _triggerSignature(
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory auths
    ) private returns (bytes memory) {
        bytes32 authorizationsHash = machine.signalAuthorizationsHash(auths);
        bytes32 structHash = keccak256(
            abi.encode(
                TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH,
                trigger.planId,
                trigger.creator,
                trigger.triggerHookId,
                trigger.triggerStageId,
                trigger.sourceId,
                trigger.signalId,
                trigger.payloadHash,
                trigger.idempotencyKey,
                authorizationsHash,
                trigger.submitter,
                trigger.deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        EIP712_DOMAIN_TYPEHASH,
                        STATE_MACHINE_NAME_HASH,
                        STATE_MACHINE_VERSION_HASH,
                        block.chainid,
                        address(machine)
                    )
                ),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _attributionFor(bytes32 planId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (UVPStateMachine.FactAttribution memory attribution)
    {
        CapabilityTables storage tables = capabilityTables[planId];
        for (uint256 i = 0; i < tables.capabilities.length; i++) {
            SignalCapability storage capability = tables.capabilities[i];
            if (
                capability.targetOrderRelation == 0 && capability.targetSourceId == sourceId
                    && capability.signalId == signalId
            ) {
                bytes32 leaf = keccak256(
                    abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, capability.stageId, sourceId, signalId, uint256(0))
                );
                return UVPStateMachine.FactAttribution({
                    sourceId: sourceId,
                    signalId: signalId,
                    stageId: capability.stageId,
                    capabilityProof: _merkleProofFor(tables.sortedLeaves, leaf)
                });
            }
        }
        return _noAttribution();
    }

    function _coreAttribution(UVPStateMachine.FactAttribution memory attribution)
        private
        pure
        returns (IUVPStateMachineCore.FactAttribution memory)
    {
        return IUVPStateMachineCore.FactAttribution({
            sourceId: attribution.sourceId,
            signalId: attribution.signalId,
            stageId: attribution.stageId,
            capabilityProof: attribution.capabilityProof
        });
    }

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0),
            signalId: bytes32(0),
            stageId: bytes32(0),
            capabilityProof: new bytes32[](0)
        });
    }

    function _auth(bytes32 sourceId, bytes32 signalId, address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization memory)
    {
        return UVPStateMachine.SignalAuthorization({
            sourceId: sourceId,
            signalId: signalId,
            submitter: submitter,
            role: ROLE_EXECUTOR,
            metadataHash: AUTH_METADATA_HASH
        });
    }

    function _signalHook(
        bytes32 hookId,
        bytes32 stageId,
        uint8 flags,
        bytes32 sourceId,
        bytes32 signalId
    ) private pure returns (UVPStateMachine.CompactHook memory) {
        UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](1);
        instrs[0] = _sig(sourceId, signalId);
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: keccak256(abi.encode("chaos.hookname", hookId)),
            flags: flags,
            instructions: instrs,
            dependencyKeys: _deps(sourceId, signalId)
        });
    }

    function _hookWithFlags(
        bytes32 hookId,
        bytes32 stageId,
        uint8 flags,
        UVPStateMachine.Instruction[] memory instrs,
        bytes32[] memory deps
    ) private pure returns (UVPStateMachine.CompactHook memory) {
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: keccak256(abi.encode("chaos.hookname", hookId)),
            flags: flags,
            instructions: instrs,
            dependencyKeys: deps
        });
    }

    function _sig(bytes32 sourceId, bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.Instruction memory)
    {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: sourceId,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
    }

    function _not() private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
    }

    function _and(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.And),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _or(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Or),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _delay(uint64 delaySeconds) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: delaySeconds
        });
    }

    function _deps(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(sourceId, signalId));
    }

    function _deps2(bytes32 s1, bytes32 id1, bytes32 s2, bytes32 id2)
        private
        pure
        returns (bytes32[] memory deps)
    {
        deps = new bytes32[](2);
        deps[0] = keccak256(abi.encode(s1, id1));
        deps[1] = keccak256(abi.encode(s2, id2));
    }

    // ------------------------------------------------------------------
    // merkle 镜像（与 DockMerkle.sortUnique/root 同口径）
    // ------------------------------------------------------------------

    function _capabilityLeaves(
        StageSelectorBinding[] memory bindings,
        SignalCapability[] memory capabilities
    ) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](bindings.length + capabilities.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            leaves[i] =
                keccak256(abi.encode(SELECTOR_BINDING_LEAF_DOMAIN, bindings[i].selectorStageId, bindings[i].targetStageId));
        }
        for (uint256 i = 0; i < capabilities.length; i++) {
            leaves[bindings.length + i] = keccak256(
                abi.encode(
                    SIGNAL_CAPABILITY_LEAF_DOMAIN,
                    capabilities[i].stageId,
                    capabilities[i].targetSourceId,
                    capabilities[i].signalId,
                    uint256(capabilities[i].targetOrderRelation)
                )
            );
        }
    }

    function _candidateLeaves(UVPStateMachine.ExecutorCandidate[] memory candidates)
        private
        pure
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](candidates.length);
        for (uint256 i = 0; i < candidates.length; i++) {
            leaves[i] =
                keccak256(abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, candidates[i].stageId, candidates[i].executor));
        }
    }

    function _sortedUnique(bytes32[] memory raw) private pure returns (bytes32[] memory sorted) {
        sorted = new bytes32[](raw.length);
        uint256 count;
        for (uint256 i = 0; i < raw.length; i++) {
            bool duplicate = false;
            for (uint256 j = 0; j < count; j++) {
                if (sorted[j] == raw[i]) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                sorted[count++] = raw[i];
            }
        }
        for (uint256 i = 1; i < count; i++) {
            bytes32 key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key;
        }
        bytes32[] memory exact = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            exact[i] = sorted[i];
        }
        return exact;
    }

    function _pairOf(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return left <= right ? keccak256(abi.encodePacked(left, right)) : keccak256(abi.encodePacked(right, left));
    }

    function _merkleProofFor(bytes32[] memory sorted, bytes32 leaf) private pure returns (bytes32[] memory proof) {
        uint256 index = type(uint256).max;
        for (uint256 i = 0; i < sorted.length; i++) {
            if (sorted[i] == leaf) {
                index = i;
                break;
            }
        }
        require(index != type(uint256).max, "chaos: leaf not in tree");
        bytes32[] memory buffer = new bytes32[](64);
        uint256 count;
        bytes32[] memory level = sorted;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) {
                buffer[count++] = level[sibling];
            }
            uint256 nextLength = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLength);
            uint256 cursor;
            for (uint256 i = 0; i + 1 < level.length; i += 2) {
                next[cursor++] = _pairOf(level[i], level[i + 1]);
            }
            if (level.length % 2 == 1) {
                next[cursor] = level[level.length - 1];
            }
            level = next;
            index /= 2;
        }
        proof = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            proof[i] = buffer[i];
        }
    }

    function _single(bytes32 leaf) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](1);
        leaves[0] = leaf;
    }

    function _two(bytes32 a, bytes32 b) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](2);
        leaves[0] = a;
        leaves[1] = b;
    }

    function _array1(bytes32 leaf) private pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = leaf;
    }
}
