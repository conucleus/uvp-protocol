// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";

/// chaos invariant 线的窄 Vm 接口（不 vendor forge-std，与
/// UVPStateMachineInvariants.t.sol 同惯例；本线额外需要 recordLogs 族——
/// 事件计数 ghost 的观察原语）。
interface ChaosVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function addr(uint256 privateKey) external returns (address keyAddr);
    function getRecordedLogs() external returns (Log[] memory logs);
    function recordLogs() external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

/// 链轨 chaos Stage 1：forge invariant 扩面（成衣行业世界）。
///
/// 世界 = 成衣工坊主计划（裁剪→缝纫→后整理，含延时质检、否决位、发射
/// 适格窗、执行者候选集换人面、治理分叉）＋ 染厂→成衣工厂的委托 dock
/// 对接（new 铸子单 / existing 挂接，双模接口）＋ 备选计划混入面。
///
/// 随机面（自动收集集）覆盖动作全集：submitSignal / submitSignalFor（含
/// 错签者与过期签名攻击变体）/ pokeTimer / warpTime / openDockedOrder /
/// attachDockedOrder / submitDockedInput / submitDockedSignal /
/// applyStageExecutorPatch（assign/handoff）/ forkOrder / commitPlan。
///
/// ghost 扩面（每动作后全量复查 + 计数器）：
///
/// 1. 终态不可改写（Ready/Cancelled 之后永不再变）；
/// 2. first-win：每信号槽首写 payloadHash 之后永不再变，且 once-exists
///    的事实槽永续存在（吸收稳定性）；
/// 3. 等待期限单调：锚点推导形态族上 dueAt 单调不减；
/// 4. 接纳计数与 SignalSubmitted 事件严格一致（recordLogs 观察）；
/// 5. revert 动作零状态变更（前后世界 digest 全等）且不落事实事件；
/// 6. dock 深度恒 ≤ MAX_DOCK_DEPTH。
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
        require(handler.dockDepthViolationCount() == 0, "chaos: dock depth exceeded MAX_DOCK_DEPTH");
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
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.14");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,uint256 deadline)"
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
    bytes32 private constant DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V2");
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
    uint256 private constant SUBMITTER_PRIVATE_KEY = 0xa11ce;
    uint256 private constant FINISHER_A_PRIVATE_KEY = 0xB1;
    uint256 private constant FINISHER_B_PRIVATE_KEY = 0xB2;
    uint256 private constant ROGUE_PRIVATE_KEY = 0xBAD5;

    uint256 private constant BASE_ORDER_COUNT = 2;
    uint256 private constant MILL_ORDER_COUNT = 3;
    uint256 private constant PLANT_TARGET_COUNT = 3;
    uint256 private constant FORK_CHILD_CAPACITY = 8;
    uint256 private constant FORK_PAYLOAD_COUNT = 4;
    uint256 private constant ALT_PLAN_COUNT = 3;

    uint256 private constant BASE_SIGNAL_COUNT = 8;
    uint256 private constant MILL_SIGNAL_COUNT = 4;
    uint256 private constant PLANT_SIGNAL_COUNT = 3;
    uint256 private constant BASE_HOOK_COUNT = 6;
    uint256 private constant MILL_HOOK_COUNT = 2;
    uint256 private constant PLANT_HOOK_COUNT = 3;

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
    bytes32 private attachRouteHash;
    bytes32 private openEntranceBinding;
    bytes32 private attachInputBinding;
    bytes32 private garmentOutBinding;
    bytes32 private progressOutBinding;
    bytes32[MILL_ORDER_COUNT] private openInstanceIds;
    bytes32[MILL_ORDER_COUNT] private dockChildIds;
    bool[MILL_ORDER_COUNT] private dockChildLive;
    bytes32[MILL_ORDER_COUNT * PLANT_TARGET_COUNT] private attachInstanceIds;
    bool[MILL_ORDER_COUNT * PLANT_TARGET_COUNT] private attachLive;
    bytes32 private plantInputsRoot;
    bytes32 private plantOutputsRoot;
    bytes32 private fabricInLeaf;
    bytes32 private auditInLeaf;
    bytes32 private garmentOutLeaf;
    bytes32 private progressOutLeaf;
    bytes32 private plantInterfaceLeaf;
    bytes32[] private routeTreeLeaves;

    bool[ALT_PLAN_COUNT] private altPlanCommitted;

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
        keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)");

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
        machine.setLens(address(0x1234));
        machine.freezeModules();

        runtimeDomain = keccak256(abi.encode(DOMAIN_RUNTIME_EIP155, block.chainid, address(machine)));

        plantPlanId = _registerPlantPlan();
        millPlanId = _registerMillPlan();
        basePlanId = _registerBasePlan();

        for (uint256 i = 0; i < BASE_ORDER_COUNT; i++) {
            baseOrders[i] = _birthBaseOrder(i);
        }
        // plant 目标单先出生：mill 出生时绑定 attach 实例 id 需要它们。
        for (uint256 i = 0; i < PLANT_TARGET_COUNT; i++) {
            plantTargets[i] = _birthPlantTarget(i);
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

    /// 直接事实提交：三计划全订单池 × 各自信号池。
    function submitSignal(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        bytes32 planId;
        bytes32 orderId;
        bytes32 sourceId;
        bytes32 signalId;
        uint256 pick = seed % 14;
        if (pick < 8) {
            planId = basePlanId;
            orderId = _basePool(pick);
            (sourceId, signalId) = _baseSignalAt((seed >> 8) % BASE_SIGNAL_COUNT);
        } else if (pick < 11) {
            planId = millPlanId;
            orderId = millOrders[(seed >> 8) % MILL_ORDER_COUNT];
            (sourceId, signalId) = _millSignalAt((seed >> 12) % MILL_SIGNAL_COUNT);
        } else {
            planId = plantPlanId;
            orderId = _plantPool((seed >> 8) % (PLANT_TARGET_COUNT + _liveDockChildren()));
            (sourceId, signalId) = _plantSignalAt((seed >> 12) % PLANT_SIGNAL_COUNT);
        }
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
            orderId = _basePool(pick);
            hookId = _baseHookAt((seed >> 8) % BASE_HOOK_COUNT);
        } else if (pick < 11) {
            planId = millPlanId;
            orderId = millOrders[(seed >> 8) % MILL_ORDER_COUNT];
            hookId = _millHookAt((seed >> 12) % MILL_HOOK_COUNT);
        } else {
            planId = plantPlanId;
            orderId = _plantPool((seed >> 8) % (PLANT_TARGET_COUNT + _liveDockChildren()));
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

    /// existing 模式挂接（不铸子单，同意门走目标单 creator 腿）。
    function attachDock(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        _guardedAttach(seed % MILL_ORDER_COUNT, (seed >> 4) % PLANT_TARGET_COUNT);
        _afterAction();
    }

    /// 挂接后的 input 交付（permissionless，幂等）。
    function submitDockedInput(uint256 seed) external {
        require(bootstrapped, "chaos: not bootstrapped");
        uint256 idx = seed % (MILL_ORDER_COUNT * PLANT_TARGET_COUNT);
        _guarded(
            abi.encodeCall(
                docking.submitDockedInput,
                (
                    attachInstanceIds[idx],
                    HOOK_SHIPPED,
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

    /// 治理分叉：裁决信号存在即分叉，同载荷重放幂等拒绝。
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
        if (machine.orderExists(basePlanId, child) && forkChildren.length < FORK_CHILD_CAPACITY) {
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
                machine.finalizePlan(candidate);
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
        if (success) {
            attachLive[i * PLANT_TARGET_COUNT + j] = true;
        }
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
            if (logs[i].topics.length > 0 && logs[i].topics[0] == SIGNAL_SUBMITTED_TOPIC0) {
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
        uint8 maxDepth = docking.MAX_DOCK_DEPTH();
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (docking.dockDepthOfOrder(plantPlanId, dockChildIds[i]) > maxDepth) {
                dockDepthViolationCount += 1;
            }
        }
        for (uint256 j = 0; j < PLANT_TARGET_COUNT; j++) {
            if (docking.dockDepthOfOrder(plantPlanId, plantTargets[j]) > maxDepth) {
                dockDepthViolationCount += 1;
            }
        }
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (docking.dockDepthOfOrder(millPlanId, millOrders[i]) > maxDepth) {
                dockDepthViolationCount += 1;
            }
        }
    }

    // ------------------------------------------------------------------
    // 世界 digest（revert 零状态变更断言的真值源）
    // ------------------------------------------------------------------

    function _worldDigest() private view returns (bytes32 digest) {
        // 滚动折叠：钩子运行态（status/dueAt/readyEmitted）+ 信号槽
        //（exists/payload/submitter）+ 后整理在任执行者 + dock 深度。
        bytes32[] memory baseOrderList = _baseOrderList();
        bytes32[] memory baseHooks = _baseHookIds();
        bytes32[] memory baseSources = _baseSignalSources();
        bytes32[] memory baseSignals = _baseSignalIds();
        for (uint256 o = 0; o < baseOrderList.length; o++) {
            if (baseOrderList[o] == bytes32(0)) {
                continue;
            }
            for (uint256 h = 0; h < baseHooks.length; h++) {
                try machine.getHookStatus(basePlanId, baseOrderList[o], baseHooks[h]) returns (
                    UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted
                ) {
                    digest = keccak256(abi.encode(digest, baseHooks[h], uint8(status), dueAt, readyEmitted));
                } catch {}
            }
            for (uint256 s = 0; s < baseSignals.length; s++) {
                try machine.getSignal(basePlanId, baseOrderList[o], baseSources[s], baseSignals[s]) returns (
                    bool exists,
                    bytes32 payloadHash,
                    bytes32,
                    uint64,
                    address submitter
                ) {
                    digest = keccak256(abi.encode(digest, baseSignals[s], exists, payloadHash, submitter));
                } catch {}
            }
            digest = keccak256(
                abi.encode(
                    digest,
                    "finishing-executor",
                    machine.activeStageExecutor(basePlanId, baseOrderList[o], STAGE_FINISHING)
                )
            );
        }
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            digest = keccak256(abi.encode(digest, "mill-depth", docking.dockDepthOfOrder(millPlanId, millOrders[i])));
        }
        bytes32[] memory plantOrderList = _plantOrderList();
        for (uint256 o = 0; o < plantOrderList.length; o++) {
            if (plantOrderList[o] == bytes32(0)) {
                continue;
            }
            digest = keccak256(
                abi.encode(digest, "plant-depth", docking.dockDepthOfOrder(plantPlanId, plantOrderList[o]))
            );
        }
        digest = keccak256(abi.encode(digest, forkChildren.length));
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
        orders = new bytes32[](PLANT_TARGET_COUNT + _liveDockChildren());
        for (uint256 i = 0; i < PLANT_TARGET_COUNT; i++) {
            orders[i] = plantTargets[i];
        }
        uint256 cursor = PLANT_TARGET_COUNT;
        for (uint256 i = 0; i < MILL_ORDER_COUNT; i++) {
            if (dockChildLive[i]) {
                orders[cursor++] = dockChildIds[i];
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

        // 发射适格窗（flag=8 槽位）：sew.finished 须 qc.passed 已在案且
        // 返工后 60s 窗口外。
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
        _computeDockStaticParts();
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
            hooks, capabilities, PLANT_PUBLISHER_PRIVATE_KEY, DockMerkle.root(_single(plantInterfaceLeaf))
        );
    }

    function _computeDockStaticParts() private {
        openRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, millDefinitionRef, STAGE_DISPATCH));
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
                openRouteId,
                INTERFACE_NAME_ID,
                HOOK_SHIPPED,
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
        bytes32 inputsRoot = DockMerkle.root(_single(openEntranceBinding));
        bytes32 attachInputsRoot = DockMerkle.root(_single(attachInputBinding));
        bytes32 outputsRoot = DockMerkle.root(_two(garmentOutBinding, progressOutBinding));

        openRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE, millDefinitionRef, plantDefinitionRef, INTERFACE_NAME_ID, uint256(0), inputsRoot, outputsRoot
            )
        );
        attachRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                millDefinitionRef,
                plantDefinitionRef,
                INTERFACE_NAME_ID,
                uint256(1),
                attachInputsRoot,
                outputsRoot
            )
        );
        routeTreeLeaves = _two(openRouteHash, attachRouteHash);

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
                    openRouteId,
                    attachRouteHash,
                    uint256(1),
                    INTERFACE_NAME_ID,
                    plantPlanId,
                    plantTargets[j]
                )
            );
        }
    }

    // ------------------------------------------------------------------
    // dock 动作构造
    // ------------------------------------------------------------------

    function _tryOpen(uint256 i) private returns (bool success, bytes memory returnData) {
        UVPDockingModule.DockInterfaceProofV2 memory proof = UVPDockingModule.DockInterfaceProofV2({
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
                    request,
                    _routeProof(openRouteHash),
                    proof,
                    inputs,
                    outputs,
                    _permitEmpty(),
                    outputAttributions,
                    _coreAttribution(_attributionFor(plantPlanId, SOURCE_DYE, SIG_LOT_ARRIVED))
                )
            )
        );
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
            localStageId: STAGE_DISPATCH,
            localDefinitionRefHash: millDefinitionRef,
            routeId: openRouteId,
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
            localHookId: HOOK_SHIPPED,
            portKey: PORT_AUDIT_IN,
            targetSourceId: SOURCE_AUDIT,
            targetSignalId: SIG_PLANT_AMENDED,
            bindingHash: attachInputBinding,
            targetHookId: HOOK_PLANT_RECEIVE,
            portProof: _array1(fabricInLeaf)
        });
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _openOutputs();
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

    function _routeProof(bytes32 routeHash) private view returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = routeHash == openRouteHash ? attachRouteHash : openRouteHash;
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
        bytes32 salt = keccak256(abi.encode("chaos.alt", variant));
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(
            keccak256(abi.encode(salt, "birth")),
            keccak256(abi.encode(salt, "cutting")),
            FLAG_MINT | FLAG_EMIT_READY,
            SOURCE_BRAND,
            keccak256(abi.encode(salt, "order.placed"))
        );
        UVPStateMachine.Instruction[] memory delayInstrs = new UVPStateMachine.Instruction[](2);
        delayInstrs[0] = _sig(SOURCE_SHOP, SIG_QC_PASSED);
        delayInstrs[1] = _delay(variant == 0 ? 5 : (variant == 1 ? 30 : 300));
        hooks[1] = _hookWithFlags(
            keccak256(abi.encode(salt, "qc")),
            keccak256(abi.encode(salt, "sewing")),
            FLAG_EMIT_READY,
            delayInstrs,
            _deps(SOURCE_SHOP, SIG_QC_PASSED)
        );
        hooks[2] = _signalHook(
            keccak256(abi.encode(salt, "watch")),
            keccak256(abi.encode(salt, "sewing")),
            FLAG_EMIT_READY,
            SOURCE_SHOP,
            keccak256(abi.encode(salt, "sew.finished"))
        );
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
        bytes32 dockInterfaceRoot
    ) private returns (bytes32) {
        bytes32[] memory leaves = _capabilityLeaves(new StageSelectorBinding[](0), capabilities);
        UVPStateMachine.PlanCommit memory commit = _planCommitTemplate(hooks, publisherKey);
        commit.capabilitiesRoot = DockMerkle.root(leaves);
        commit.dockInterfaceRoot = dockInterfaceRoot;
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
