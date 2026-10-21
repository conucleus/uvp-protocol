// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";

/// 测试侧窄 Vm 接口（不 vendor forge-std，与 CapabilitiesRootParity 同口径）
/// 外加语料回放需要的 cheatcode：warp/recordLogs/prank/sign/addr。
interface CorpusVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function projectRoot() external view returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function parseJsonString(string calldata json, string calldata key) external view returns (string memory);
    function parseJsonBytes32(string calldata json, string calldata key) external view returns (bytes32);
    function parseJsonUint(string calldata json, string calldata key) external view returns (uint256);
    function parseJsonBool(string calldata json, string calldata key) external view returns (bool);
    function addr(uint256 privateKey) external returns (address keyAddr);
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address msgSender) external;
    function recordLogs() external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

/// 共享语义语料（uvp-core/fixtures/hook/semantics.v1.json）的 forge 消费线：
/// replayCases（26 例链指令形态）逐例在 UVPStateMachine 上按语料时间线
/// 重演——plan 注册（含发射适格面 flag=8 槽位）、订单出生（outside 出生 /
/// order-link 派生 / dock entrance）、信号提交与 pokeTimer——再把钩子观察
/// 面（wait/cxl 的 HookStatusChanged + HookReady）与语料期望
/// （observedEvents/observedCount/finalHookStatuses/waitDueAt/stateOrderKeys）
/// 逐点对拍。TS 线（packages/statemachine semantics-corpus.test.ts）喂
/// native 回放 oracle；本线喂真实合约求值器：同一份语料，两条消费路径。
///
/// 链轨适配（消费即断言，不做兼容垫层）：
/// - 语料 signalKey 是抽象路由身份（native 按字符串路由，链上按
///   keccak(sourceId, signalId) 重算）。SIGNAL 指令身份解析：同例内存在同
///   signalKey 的 SignalSubmitted 事件 → 用事件 (sourceId, signalId)；否则
///   保留指令自带对；再否则（适格面指令只携带 signalKey）用
///   (signalKey, signalKey) 合成对。cases 6/7/8 的 BIRTH/ENTER 钩子由此
///   路由到出生事实的真实身份。
/// - 无 mint/dock 钩子的 plan 补一枚合成 order-start 出生钩（独立合成阶
///   段），出生事实 = 该订单首个语料信号（镜像 native birth_channel 规
///   则）；合成钩事件按语料 hookId 过滤出观察面。
/// - 毒流形态（伪造 ready / 声错 dueAt / 缺 pokedAt / 无出生事实的 dock
///   ready）链上按构造不可产生，消费为链自己的闸门断言：missing-observed
///   断 entrance 事实与 HookReady 同事务原子；缺时钟 poke 断未到期
///   TimerNotDue 响亮 + 到期拍放行；声错 dueAt 对照 expect.waitDueAt（native
///   侧裁掉毒值所用的同一推导值）。
/// - 出生闸挡住的形态（出生拍求值判 cxl → InvalidTriggerHook 整笔回滚，
///   订单不可存在）与注册闸挡住的形态（纯 flags=0 watcher 阶段不可物化 →
///   StageNotMaterializable）按语料期望断言拒绝，后者另在可注册变体（同
///   阶段补一枚永不出线的 EMIT_READY 物化钩）上钉同一求值语义（skip 不
///   brick、零观察）。
/// - 发射适格面（filter 档 evalCases，8 格）单独消费：DSL 串钉住五形态
///   （漂移即响亮失败），信号集/时刻/期望态从语料读取。锚定格都在消费集
///   内：无锚延时 → 链轨注册闸拒绝（求值侧永不放行的死代码）；真空 OR
///   臂让位 → now 拒绝 + readyAt 放行两腿；双真空 OR 平票 → 注册闸同款
///   拒绝（无锚分支永不出线，§5.4）；双活否决最紧期 → 语料 expiresAt
///   拍拒绝 + now 拍放行两腿。
contract SemanticsReplayCorpusTest {
    CorpusVm private constant vm = CorpusVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ----------------------------------------------------------------------
    // 容量上限（语料漂移哨兵：超限响亮失败而不是静默截断）
    // ----------------------------------------------------------------------

    uint256 private constant MAX_EVENTS = 12;
    uint256 private constant MAX_PLANS = 2;
    uint256 private constant MAX_HOOKS = 4;
    uint256 private constant MAX_INSTR = 10;
    uint256 private constant MAX_ADMISSIONS = 1;
    uint256 private constant MAX_ORDERS = 2;
    uint256 private constant MAX_SIGNALS = 8;
    uint256 private constant MAX_POKES = 2;
    uint256 private constant REPLAY_CASE_COUNT = 26;
    uint256 private constant FILTER_CASE_COUNT = 8;

    // ----------------------------------------------------------------------
    // 语料行（storage：via_ir 深栈 + 跨 helper 共享）
    // ----------------------------------------------------------------------

    struct RawInstr {
        uint8 op; // 链上 InstructionOp 编码：0 SIGNAL,1 NOT,2 AND,3 OR,4 DELAY
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 signalKey;
        uint16 arity;
        uint64 delaySeconds;
    }

    struct RawHook {
        bytes32 hookId;
        bytes32 stageId;
        bytes32 hookNameWord;
        string hookIdHex;
        uint8 flags; // 链上 flags（mint=1/dock=2/emit=4）
        RawInstr[] instrs;
        bool exists;
    }

    struct RawPlan {
        bytes32 corpusPlanId;
        string corpusPlanIdHex;
        RawHook[] hooks;
        RawHook[] admissions;
        bool hasMint;
        bool hasDock;
        bytes32 chainPlanId;
        bytes32 birthHookId; // 合成 order-start 出生钩（无 mint/dock 钩时）
        bytes32 birthStageId;
        bool exists;
    }

    struct SignalRow {
        bytes32 planId;
        string orderId;
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 signalKey;
        uint64 submittedAt;
        uint256 slot;
        bytes32 payload;
        bool written;
        bool exists;
    }

    struct OrderRow {
        bytes32 planId;
        string orderId;
        string corpusPlanIdHex;
        uint64 registeredAt;
        bytes32 chainPlanId;
        bytes32 chainOrderId;
        bool born;
        bool exists;
    }

    struct PokeRow {
        bytes32 planId;
        string orderId;
        bytes32 hookId;
        uint64 pokedAt;
        bool hasPokedAt;
        uint256 slot;
        bool exists;
    }

    struct EventRow {
        uint256 blockNumber;
        uint256 logIndex;
        bytes32 nameHash;
        uint256 slot;
        bool exists;
    }

    UVPStateMachine private machine;
    UVPDockingModule private docking;
    UVPOrderLinkModule private orderLink;
    string private corpusJson;

    EventRow[MAX_EVENTS] private events;
    uint256 private eventCount;
    RawPlan[MAX_PLANS] private plans;
    uint256 private planCount;
    SignalRow[MAX_SIGNALS] private signals;
    uint256 private signalCount;
    OrderRow[MAX_ORDERS] private orders;
    uint256 private orderCount;
    PokeRow[MAX_POKES] private pokes;
    uint256 private pokeCount;
    // OrderTriggered 行（order-link 派生单）：(planId, orderId, 源事实)。
    bytes32[MAX_ORDERS] private triggeredPlanIds;
    string[MAX_ORDERS] private triggeredOrderIds;
    bytes32[MAX_ORDERS] private triggeredSourceIds;
    bytes32[MAX_ORDERS] private triggeredSignalIds;
    uint256 private triggeredCount;
    uint64 private declaredWaitDueAt;
    bool private hasDeclaredWaitDueAt;
    bytes32 private mismatchReasonHash;
    bytes32[8] private markedHookIds;
    uint256 private markedHookCount;

    mapping(bytes32 hookId => bool) private corpusHookIds;

    // ----------------------------------------------------------------------
    // 常量
    // ----------------------------------------------------------------------

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant SUBMITTER_PRIVATE_KEY = 0xa11ce;
    bytes32 private constant ROLE_BOOTSTRAP = bytes32(uint256(0xa001));
    bytes32 private constant AUTH_METADATA_HASH = bytes32(uint256(0xa002));
    address private constant ORDER_CREATOR = address(uint160(0xc0de));
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_ORDER_TRIGGER_DOCK = 2;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_ADMISSION = 8;
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
    bytes32 private constant TOPIC_SIGNAL_SUBMITTED =
        keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32)");
    bytes32 private constant TOPIC_HOOK_STATUS_CHANGED =
        keccak256("HookStatusChanged(bytes32,bytes32,bytes32,uint8,uint8,uint64)");
    bytes32 private constant TOPIC_HOOK_READY = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)");

    bytes32 private constant NAME_SIGNAL_SUBMITTED = keccak256("SignalSubmitted");
    bytes32 private constant NAME_TIMER_POKED = keccak256("TimerPoked");
    bytes32 private constant NAME_ORDER_TRIGGERED = keccak256("OrderTriggered");

    // ======================================================================
    // 测试入口：26 例逐例独立测试函数（失败定位到例；解析成本每例独立）
    // ======================================================================

    function testReplayCase00() public {
        _runReplayCase(0);
    }

    function testReplayCase01() public {
        _runReplayCase(1);
    }

    function testReplayCase02() public {
        _runReplayCase(2);
    }

    function testReplayCase03() public {
        _runReplayCase(3);
    }

    function testReplayCase04() public {
        _runReplayCase(4);
    }

    function testReplayCase05() public {
        _runReplayCase(5);
    }

    function testReplayCase06() public {
        _runReplayCase(6);
    }

    function testReplayCase07() public {
        _runReplayCase(7);
    }

    function testReplayCase08() public {
        _runReplayCase(8);
    }

    function testReplayCase09() public {
        _runReplayCase(9);
    }

    function testReplayCase10() public {
        _runReplayCase(10);
    }

    function testReplayCase11() public {
        _runReplayCase(11);
    }

    function testReplayCase12() public {
        _runReplayCase(12);
    }

    function testReplayCase13() public {
        _runReplayCase(13);
    }

    function testReplayCase14() public {
        _runReplayCase(14);
    }

    function testReplayCase15() public {
        _runReplayCase(15);
    }

    function testReplayCase16() public {
        _runReplayCase(16);
    }

    function testReplayCase17() public {
        _runReplayCase(17);
    }

    function testReplayCase18() public {
        _runReplayCase(18);
    }

    function testReplayCase19() public {
        _runReplayCase(19);
    }

    function testReplayCase20() public {
        _runReplayCase(20);
    }

    function testReplayCase21() public {
        _runReplayCase(21);
    }

    function testReplayCase22() public {
        _runReplayCase(22);
    }

    function testReplayCase23() public {
        _runReplayCase(23);
    }

    function testReplayCase24() public {
        _runReplayCase(24);
    }

    function testReplayCase25() public {
        _runReplayCase(25);
    }

    /// 消费覆盖哨兵：语料 replayCases 恰为 26 例（索引 0..25）——新增/删除
    /// 语料例时这里先响亮失败，入口函数集必须同批增删。
    function testReplayCorpusCaseCountIsPinned() public {
        _loadCorpus();
        for (uint256 i = 0; i < REPLAY_CASE_COUNT; i++) {
            (bool ok,) = _tryString(corpusJson, _casePath(i, ".name"));
            require(ok, "replay corpus case missing");
        }
        (bool beyond,) = _tryString(corpusJson, _casePath(REPLAY_CASE_COUNT, ".name"));
        require(!beyond, "replay corpus grew; extend the per-case entrypoints");
    }

    // ======================================================================
    // 主驱动
    // ======================================================================

    function _runReplayCase(uint256 caseIdx) private {
        _loadCorpus();
        _resetCase();
        string memory json = corpusJson;

        // ---- 阶段 1：逐事件读排序键与名称，按 (blockNumber, logIndex) 排成
        // 规范序（镜像 native replay 的排序键；case 9 的乱序流由此归位）。
        for (uint256 i = 0; i < MAX_EVENTS; i++) {
            (bool ok, string memory name) =
                _tryString(json, _casePath(caseIdx, string.concat(".events[", _toString(i), "].eventName")));
            if (!ok) {
                break;
            }
            require(eventCount < MAX_EVENTS, "corpus event overflow");
            EventRow storage row = events[eventCount];
            row.blockNumber =
                vm.parseJsonUint(json, _casePath(caseIdx, string.concat(".events[", _toString(i), "].blockNumber")));
            row.logIndex =
                vm.parseJsonUint(json, _casePath(caseIdx, string.concat(".events[", _toString(i), "].logIndex")));
            row.nameHash = keccak256(bytes(name));
            row.slot = i;
            row.exists = true;
            eventCount += 1;
        }
        require(eventCount > 0, "corpus case has no events");
        _sortEventsByCanonicalOrder();

        // ---- 阶段 2：按规范序收集类型化行。 ----
        for (uint256 i = 0; i < eventCount; i++) {
            _absorbEvent(caseIdx, i);
        }
        require(planCount > 0, "corpus case has no plans");
        (bool hasMismatchReason, string memory mismatchReason) =
            _tryString(json, _casePath(caseIdx, ".expect.mismatchDetails[0].reason"));
        if (hasMismatchReason) {
            mismatchReasonHash = keccak256(bytes(mismatchReason));
        }

        // ---- 阶段 3：装配机器 + 注册 plan（含注册闸适配）。 ----
        machine = _newCaseMachine();
        bool commitRejected = false;
        bytes4 rejectSelector;
        for (uint256 p = 0; p < planCount; p++) {
            (commitRejected, rejectSelector) = _commitCorpusPlan(caseIdx, p, false);
            if (commitRejected) {
                break;
            }
        }
        bool gateBlocked = false;
        if (commitRejected) {
            // 注册闸挡住的形态：纯 flags=0 watcher 的阶段不可物化 → 链轨注
            // 册边界拒绝（语料求值侧结论 = 该钩子被跳过、零观察）。随后在
            // 可注册变体（同阶段补一枚永不出线的 EMIT_READY 物化钩）上钉
            // 同一求值语义。
            require(
                rejectSelector == UVPStateMachine.StageNotMaterializable.selector, "unexpected corpus commit rejection"
            );
            require(_caseObservedCount(caseIdx) == 0, "materialization-gated case must expect zero observations");
            machine = _newCaseMachine();
            for (uint256 p = 0; p < planCount; p++) {
                (commitRejected, rejectSelector) = _commitCorpusPlan(caseIdx, p, true);
                require(!commitRejected, "variant plan must register");
            }
        }

        vm.recordLogs();

        // ---- 阶段 4：按规范序惰性重演——OrderRegistered 拍出生该单（出生
        // 事实可能尚未在流内到达：outside 出生的事实与创建同事务，warp 直
        // 接跳到事实时刻），SignalSubmitted 拍落库（出生事实已写则吸收），
        // TimerPoked 拍 poke。 ----
        uint256 signalCursor;
        uint256 pokeCursor;
        uint256 orderCursor;
        for (uint256 i = 0; i < eventCount; i++) {
            bytes32 name = events[i].nameHash;
            if (name == keccak256("OrderRegistered")) {
                uint256 orderIdx = orderCursor;
                orderCursor += 1;
                OrderRow storage order = orders[orderIdx];
                if (order.born) {
                    continue;
                }
                RawPlan storage plan = _planByCorpusId(order.planId);
                order.chainPlanId = plan.chainPlanId;
                uint256 firstSignal = _firstSignalOf(order.planId, order.orderId);
                if (_orderHasTriggeredRow(order.planId, order.orderId) && firstSignal == type(uint256).max) {
                    // order-link 派生单：子单无自身信号，readiness 由链接
                    // 事务从 origin 事实派生（case 6）。
                    _birthOrderLink(caseIdx, orderIdx);
                    order.born = true;
                } else if (plan.hasDock) {
                    _birthDockOrder(caseIdx, orderIdx, firstSignal);
                    order.born = true;
                } else if (!_birthOutside(caseIdx, orderIdx)) {
                    // 出生闸挡住的形态：出生拍求值判 cxl → InvalidTriggerHook
                    // 整笔回滚，订单不可存在（native oracle 对同一求值产生
                    // cxl 观察；链上出生通道 fail-closed，该时间线不可产生）。
                    gateBlocked = true;
                    require(
                        !machine.orderExists(order.chainPlanId, order.chainOrderId),
                        "cancelled-at-birth order must not exist"
                    );
                    break;
                } else {
                    order.born = true;
                }
            } else if (name == NAME_SIGNAL_SUBMITTED) {
                uint256 signalIdx = signalCursor;
                signalCursor += 1;
                SignalRow storage sig = signals[signalIdx];
                if (sig.written) {
                    continue; // 出生事实已随出生事务落库
                }
                OrderRow storage order = _orderByCorpus(sig.planId, sig.orderId);
                vm.warp(sig.submittedAt);
                machine.submitSignal(
                    order.chainPlanId,
                    order.chainOrderId,
                    sig.sourceId,
                    sig.signalId,
                    sig.payload,
                    keccak256(abi.encode(caseIdx, signalIdx)),
                    _noAttribution()
                );
                _markWritten(signalIdx);
            } else if (name == NAME_TIMER_POKED) {
                _replayPoke(pokeCursor);
                pokeCursor += 1;
            }
        }

        // ---- 阶段 5：对拍语料期望。 ----
        CorpusVm.Log[] memory logs = vm.getRecordedLogs();
        if (gateBlocked) {
            // 出生闸消费：语料的 cxl 观察在链上表现为订单不可出生。
            require(mismatchReasonHash == 0, "gate-blocked corpus case is not a poison-stream case");
        } else if (mismatchReasonHash == keccak256("missing-observed")) {
            // 毒格（dock ready 无出生事实）：链上该流不可产生——断言诚实
            // dock 出生中 entrance 事实与 HookReady 同事务原子出现。
            _assertDockBirthAtomic(logs);
        } else {
            (bool hasErrorContains,) = _tryString(json, _casePath(caseIdx, ".expect.errorContains"));
            if (!hasErrorContains) {
                // 毒格（整场响亮失败）只钉链上的响亮闸（_replayPoke 的
                // TimerNotDue 腿），不比对观察面。
                _assertObservableFace(caseIdx, logs);
            }
            _assertWaitDueAt(caseIdx, logs);
            _assertFinalHookStatuses(caseIdx);
            _assertStateOrderKeys(caseIdx);
        }
        _assertFirstWriteStays();
    }

    // ======================================================================
    // 事件收集
    // ======================================================================

    function _absorbEvent(uint256 caseIdx, uint256 sortedIdx) private {
        string memory json = corpusJson;
        EventRow storage ev = events[sortedIdx];
        string memory base = _casePath(caseIdx, string.concat(".events[", _toString(ev.slot), "]"));
        bytes32 name = ev.nameHash;
        if (name == keccak256("PlanRegistered")) {
            _collectPlan(json, string.concat(base, ".plan"));
        } else if (name == keccak256("OrderRegistered")) {
            bytes32 planId = vm.parseJsonBytes32(json, string.concat(base, ".planId"));
            string memory orderId = vm.parseJsonString(json, string.concat(base, ".orderId"));
            (, uint64 registeredAt) = _requireTimestamp(vm.parseJsonString(json, string.concat(base, ".registeredAt")));
            require(orderCount < MAX_ORDERS, "corpus order overflow");
            if (_orderByCorpusOrNull(planId, orderId) == type(uint256).max) {
                OrderRow storage order = orders[orderCount];
                order.planId = planId;
                order.orderId = orderId;
                order.corpusPlanIdHex = _planByCorpusId(planId).corpusPlanIdHex;
                order.registeredAt = registeredAt;
                order.exists = true;
                orderCount += 1;
            }
        } else if (name == NAME_SIGNAL_SUBMITTED) {
            require(signalCount < MAX_SIGNALS, "corpus signal overflow");
            SignalRow storage sig = signals[signalCount];
            sig.planId = vm.parseJsonBytes32(json, string.concat(base, ".planId"));
            sig.orderId = vm.parseJsonString(json, string.concat(base, ".orderId"));
            sig.sourceId = vm.parseJsonBytes32(json, string.concat(base, ".sourceId"));
            sig.signalId = vm.parseJsonBytes32(json, string.concat(base, ".signalId"));
            sig.signalKey = vm.parseJsonBytes32(json, string.concat(base, ".signalKey"));
            (, uint64 submittedAt) = _requireTimestamp(vm.parseJsonString(json, string.concat(base, ".submittedAt")));
            sig.submittedAt = submittedAt;
            sig.slot = ev.slot;
            sig.payload = keccak256(abi.encode(caseIdx, "signal", ev.slot));
            sig.exists = true;
            signalCount += 1;
        } else if (name == NAME_TIMER_POKED) {
            require(pokeCount < MAX_POKES, "corpus poke overflow");
            PokeRow storage poke = pokes[pokeCount];
            poke.planId = vm.parseJsonBytes32(json, string.concat(base, ".planId"));
            poke.orderId = vm.parseJsonString(json, string.concat(base, ".orderId"));
            poke.hookId = vm.parseJsonBytes32(json, string.concat(base, ".hookId"));
            (bool hasPokedAt, string memory pokedAtRaw) = _tryString(json, string.concat(base, ".pokedAt"));
            poke.hasPokedAt = hasPokedAt;
            if (hasPokedAt) {
                (, uint64 pokedAt) = _requireTimestamp(pokedAtRaw);
                poke.pokedAt = pokedAt;
            }
            poke.slot = ev.slot;
            poke.exists = true;
            pokeCount += 1;
        } else if (name == NAME_ORDER_TRIGGERED) {
            require(triggeredCount < MAX_ORDERS, "corpus triggered overflow");
            triggeredPlanIds[triggeredCount] = vm.parseJsonBytes32(json, string.concat(base, ".planId"));
            triggeredOrderIds[triggeredCount] = vm.parseJsonString(json, string.concat(base, ".orderId"));
            triggeredSourceIds[triggeredCount] = vm.parseJsonBytes32(json, string.concat(base, ".sourceId"));
            triggeredSignalIds[triggeredCount] = vm.parseJsonBytes32(json, string.concat(base, ".signalId"));
            triggeredCount += 1;
        } else if (name == keccak256("HookStatusChanged")) {
            (bool hasStatus, string memory status) = _tryString(json, string.concat(base, ".status"));
            if (hasStatus && keccak256(bytes(status)) == keccak256("wait")) {
                (bool hasDue, string memory dueRaw) = _tryString(json, string.concat(base, ".dueAt"));
                if (hasDue) {
                    (, declaredWaitDueAt) = _requireTimestamp(dueRaw);
                    hasDeclaredWaitDueAt = true;
                }
            }
        }
    }

    function _collectPlan(string memory json, string memory planBase) private {
        require(planCount < MAX_PLANS, "corpus plan overflow");
        bytes32 planId = vm.parseJsonBytes32(json, string.concat(planBase, ".planId"));
        require(_planIndexByCorpusId(planId) == type(uint256).max, "duplicate corpus plan");
        RawPlan storage plan = plans[planCount];
        plan.corpusPlanId = planId;
        plan.corpusPlanIdHex = vm.parseJsonString(json, string.concat(planBase, ".planId"));
        for (uint256 h = 0; h < MAX_HOOKS; h++) {
            string memory hookBase = string.concat(planBase, ".compiledHooks[", _toString(h), "]");
            (bool ok,) = _tryString(json, string.concat(hookBase, ".hookId"));
            if (!ok) {
                break;
            }
            require(plan.hooks.length < MAX_HOOKS, "corpus hook overflow");
            plan.hooks.push();
            _collectHook(json, hookBase, plan.hooks[plan.hooks.length - 1]);
            uint8 flags = plan.hooks[plan.hooks.length - 1].flags;
            if (flags & FLAG_ORDER_TRIGGER_MINT != 0) {
                plan.hasMint = true;
            }
            if (flags & FLAG_ORDER_TRIGGER_DOCK != 0) {
                plan.hasDock = true;
            }
        }
        for (uint256 a = 0; a < MAX_ADMISSIONS; a++) {
            string memory admBase = string.concat(planBase, ".admissions[", _toString(a), "]");
            (bool ok,) = _tryString(json, string.concat(admBase, ".admissionId"));
            if (!ok) {
                break;
            }
            require(plan.admissions.length < MAX_ADMISSIONS, "corpus admission overflow");
            plan.admissions.push();
            _collectAdmission(json, admBase, plan.admissions[plan.admissions.length - 1]);
        }
        plan.exists = true;
        planCount += 1;
    }

    function _collectHook(string memory json, string memory hookBase, RawHook storage hook) private {
        hook.hookId = vm.parseJsonBytes32(json, string.concat(hookBase, ".hookId"));
        hook.hookIdHex = vm.parseJsonString(json, string.concat(hookBase, ".hookId"));
        hook.stageId = vm.parseJsonBytes32(json, string.concat(hookBase, ".stageId"));
        string memory hookName = vm.parseJsonString(json, string.concat(hookBase, ".hookName"));
        require(bytes(hookName).length <= 31, "corpus hookName too long");
        hook.hookNameWord = bytes32(bytes(hookName));
        string memory triggerKind = vm.parseJsonString(json, string.concat(hookBase, ".orderTriggerKind"));
        if (keccak256(bytes(triggerKind)) == keccak256("mint")) {
            hook.flags |= FLAG_ORDER_TRIGGER_MINT;
        } else if (keccak256(bytes(triggerKind)) == keccak256("dock")) {
            hook.flags |= FLAG_ORDER_TRIGGER_DOCK;
        }
        if (vm.parseJsonBool(json, string.concat(hookBase, ".emitReady"))) {
            hook.flags |= FLAG_EMIT_READY;
        }
        _collectInstrs(json, hookBase, hook.instrs, true);
        hook.exists = true;
    }

    /// 适格面条目：指令只携带 signalKey（被发射事实的寻址在 flag=8 槽位
    /// 之外，由调用侧决定——本驱动挂到订单首个信号的真实发射面上）。
    function _collectAdmission(string memory json, string memory admBase, RawHook storage admission) private {
        _collectInstrs(json, admBase, admission.instrs, false);
        admission.exists = true;
    }

    function _collectInstrs(string memory json, string memory base, RawInstr[] storage instrs, bool requireIdentity)
        private
    {
        for (uint256 i = 0; i < MAX_INSTR; i++) {
            string memory instrBase = string.concat(base, ".instructions[", _toString(i), "]");
            (bool ok, string memory op) = _tryString(json, string.concat(instrBase, ".op"));
            if (!ok) {
                break;
            }
            require(instrs.length < MAX_INSTR, "corpus instruction overflow");
            instrs.push();
            RawInstr storage instr = instrs[instrs.length - 1];
            bytes32 opHash = keccak256(bytes(op));
            if (opHash == keccak256("SIGNAL")) {
                instr.op = uint8(UVPStateMachine.InstructionOp.Signal);
                (bool hasSource, bytes32 sourceId) = _tryBytes32(json, string.concat(instrBase, ".sourceId"));
                (bool hasSignal, bytes32 signalId) = _tryBytes32(json, string.concat(instrBase, ".signalId"));
                if (requireIdentity) {
                    require(hasSource && hasSignal, "corpus SIGNAL instruction missing identity");
                }
                instr.sourceId = sourceId;
                instr.signalId = signalId;
                instr.signalKey = vm.parseJsonBytes32(json, string.concat(instrBase, ".signalKey"));
            } else if (opHash == keccak256("NOT")) {
                instr.op = uint8(UVPStateMachine.InstructionOp.Not);
            } else if (opHash == keccak256("AND")) {
                instr.op = uint8(UVPStateMachine.InstructionOp.And);
                instr.arity = uint16(vm.parseJsonUint(json, string.concat(instrBase, ".arity")));
            } else if (opHash == keccak256("OR")) {
                instr.op = uint8(UVPStateMachine.InstructionOp.Or);
                instr.arity = uint16(vm.parseJsonUint(json, string.concat(instrBase, ".arity")));
            } else if (opHash == keccak256("DELAY")) {
                instr.op = uint8(UVPStateMachine.InstructionOp.Delay);
                instr.delaySeconds = uint64(vm.parseJsonUint(json, string.concat(instrBase, ".delaySeconds")));
            } else {
                revert("unknown corpus instruction op");
            }
        }
    }

    // ======================================================================
    // plan 装配与注册
    // ======================================================================

    /// 链上 CompactHook 数组 = 语料钩子（指令身份按 signalKey 解析）+
    /// 适格面（flag=8）+（无 mint/dock 钩且有订单时）合成 order-start 出生
    /// 钩。变体模式追加同阶段 EMIT_READY 物化钩（永不出线信号）。
    function _commitCorpusPlan(uint256 caseIdx, uint256 planIdx, bool variant)
        private
        returns (bool rejected, bytes4 selector)
    {
        RawPlan storage plan = plans[planIdx];
        bool needsBirthHook = !plan.hasMint && !plan.hasDock && _orderCountOnPlan(plan.corpusPlanId) > 0;
        uint256 total = plan.hooks.length + plan.admissions.length + (needsBirthHook ? 1 : 0) + (variant ? 1 : 0);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](total);
        uint256 cursor;
        for (uint256 h = 0; h < plan.hooks.length; h++) {
            hooks[cursor] = _resolveHook(plan.hooks[h]);
            _markCorpusHook(plan.hooks[h].hookId);
            cursor += 1;
        }
        for (uint256 a = 0; a < plan.admissions.length; a++) {
            hooks[cursor] = _resolveAdmissionHook(plan.admissions[a], planIdx, caseIdx);
            cursor += 1;
        }
        if (needsBirthHook) {
            plan.birthHookId = keccak256(abi.encode("corpus.birth.hook", caseIdx, planIdx));
            plan.birthStageId = keccak256(abi.encode("corpus.birth.stage", caseIdx, planIdx));
            hooks[cursor] = _syntheticBirthHook(plan, caseIdx, planIdx);
            // 合成出生钩不进观察面过滤集（链轨出生机器，非语料语义）。
            cursor += 1;
        }
        if (variant) {
            // 注册闸变体：首个语料钩子所在阶段补一枚 EMIT_READY 物化钩，
            // 信号为永不提交的合成键——阶段可物化，语料钩子的 skip 语义
            // （未物化阶段 flags=0 watcher 不求值）保持原样。
            RawHook storage target = plan.hooks[0];
            UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](1);
            instrs[0] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal),
                keccak256(abi.encode("corpus.variant.signal", caseIdx, planIdx)),
                keccak256(abi.encode("corpus.variant.signal.id", caseIdx, planIdx)),
                0,
                0
            );
            hooks[cursor] = UVPStateMachine.CompactHook({
                hookId: keccak256(abi.encode("corpus.variant.hook", caseIdx, planIdx)),
                stageId: target.stageId,
                hookName: keccak256(abi.encode("corpus.variant.hookname", caseIdx, planIdx)),
                flags: FLAG_EMIT_READY,
                instructions: instrs,
                dependencyKeys: _depsOf(instrs)
            });
            cursor += 1;
        }
        (bytes32 planId, bytes4 revertSelector) = _commitHooks(hooks);
        if (planId == bytes32(0)) {
            return (true, revertSelector);
        }
        plans[planIdx].chainPlanId = planId;
        return (false, 0);
    }

    /// SIGNAL 指令身份解析：优先同例同 signalKey 的 SignalSubmitted 事件对
    /// （cases 6/7/8 的出生钩由此路由到真实出生事实），否则保留指令对，
    /// 再否则以 (signalKey, signalKey) 合成（适格面指令无事件对）。
    function _resolveHook(RawHook storage hook) private returns (UVPStateMachine.CompactHook memory) {
        UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](hook.instrs.length);
        for (uint256 i = 0; i < hook.instrs.length; i++) {
            RawInstr storage raw = hook.instrs[i];
            bytes32 sourceId = raw.sourceId;
            bytes32 signalId = raw.signalId;
            if (raw.op == uint8(UVPStateMachine.InstructionOp.Signal)) {
                uint256 eventIdx = _signalByKey(raw.signalKey);
                if (eventIdx != type(uint256).max) {
                    sourceId = signals[eventIdx].sourceId;
                    signalId = signals[eventIdx].signalId;
                } else if (sourceId == bytes32(0)) {
                    sourceId = raw.signalKey;
                    signalId = raw.signalKey;
                }
            }
            instrs[i] = _instruction(raw.op, sourceId, signalId, raw.arity, raw.delaySeconds);
        }
        return UVPStateMachine.CompactHook({
            hookId: hook.hookId,
            stageId: hook.stageId,
            hookName: hook.hookNameWord,
            flags: hook.flags,
            instructions: instrs,
            dependencyKeys: _depsOf(instrs)
        });
    }

    /// 适格面 flag=8 槽位：hookId = 被发射事实的 signalKey（挂订单首个信
    /// 号——适格面在真实发射面上即刻可观测），hookName 槽 = 信号身份位，
    /// stageId 取首钩子阶段（可物化，过注册扫描）。
    function _resolveAdmissionHook(RawHook storage admission, uint256 planIdx, uint256 caseIdx)
        private
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](admission.instrs.length);
        for (uint256 i = 0; i < admission.instrs.length; i++) {
            RawInstr storage raw = admission.instrs[i];
            bytes32 sourceId = raw.sourceId;
            bytes32 signalId = raw.signalId;
            if (raw.op == uint8(UVPStateMachine.InstructionOp.Signal)) {
                uint256 eventIdx = _signalByKey(raw.signalKey);
                if (eventIdx != type(uint256).max) {
                    sourceId = signals[eventIdx].sourceId;
                    signalId = signals[eventIdx].signalId;
                } else {
                    sourceId = raw.signalKey;
                    signalId = raw.signalKey;
                }
            }
            instrs[i] = _instruction(raw.op, sourceId, signalId, raw.arity, raw.delaySeconds);
        }
        SignalRow storage emitted = signals[_firstSignalOnPlan(plans[planIdx].corpusPlanId)];
        return UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(emitted.sourceId, emitted.signalId)),
            stageId: plans[planIdx].hooks[0].stageId,
            hookName: keccak256(abi.encode("corpus.admission", caseIdx)),
            flags: FLAG_ADMISSION,
            instructions: instrs,
            dependencyKeys: _depsOf(instrs)
        });
    }

    /// 合成 order-start 出生钩：独立合成阶段 + 合成出生信号（与语料钩子
    /// 无共享依赖键、无跨阶段依赖；语料钩子的阶段/求值路径不被出生事务
    /// 触碰）。
    function _syntheticBirthHook(RawPlan storage plan, uint256 caseIdx, uint256 planIdx)
        private
        view
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](1);
        instrs[0] = _instruction(
            uint8(UVPStateMachine.InstructionOp.Signal),
            keccak256(abi.encode("corpus.birth.source", caseIdx, plans[planIdx].corpusPlanId)),
            keccak256(abi.encode("corpus.birth.signal", caseIdx, plans[planIdx].corpusPlanId)),
            0,
            0
        );
        return UVPStateMachine.CompactHook({
            hookId: plan.birthHookId,
            stageId: plan.birthStageId,
            hookName: keccak256(abi.encode("corpus.birth.hookname", caseIdx, planIdx)),
            flags: FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            instructions: instrs,
            dependencyKeys: _depsOf(instrs)
        });
    }

    function _commitHooks(UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (bytes32 planId, bytes4 revertSelector)
    {
        address publisher = vm.addr(PUBLISHER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: EMPTY_DOCK_ROOT,
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        try machine.commitPlan(
            commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), _packedSignature(v, r, s)
        ) returns (
            bytes32 committed
        ) {
            machine.finalizePlan(committed);
            return (committed, 0);
        } catch (bytes memory reason) {
            require(reason.length >= 4, "commit reverted without selector");
            return (bytes32(0), bytes4(reason));
        }
    }

    // ======================================================================
    // 出生通道
    // ======================================================================

    function _birthOutside(uint256 caseIdx, uint256 orderIdx) private returns (bool) {
        OrderRow storage order = orders[orderIdx];
        RawPlan storage plan = _planByCorpusId(order.planId);
        bytes32 triggerHookId = plan.hasMint ? _mintHookOf(plan) : plan.birthHookId;
        bytes32 triggerStageId = plan.hasMint ? _hookStage(plan, _mintHookOf(plan)) : plan.birthStageId;
        // 出生事实：有语料 mint 钩的 plan 用订单首个语料信号（出生即求值
        // mint 钩，cases 0/2/7）；无 mint/dock 钩的 plan 用合成出生信号
        // （独立键：与语料钩子不共享依赖键，避免跨阶段依赖闸，且语料首信
        // 号保持普通提交路径——观察面语义与语料流逐点一致）。
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payload;
        uint256 birthSignalIdx = type(uint256).max;
        if (plan.hasMint) {
            birthSignalIdx = _firstSignalOf(order.planId, order.orderId);
            require(birthSignalIdx != type(uint256).max, "mint-birth order has no birth fact");
            SignalRow storage birth = signals[birthSignalIdx];
            sourceId = birth.sourceId;
            signalId = birth.signalId;
            payload = birth.payload;
            vm.warp(birth.submittedAt);
        } else {
            sourceId = keccak256(abi.encode("corpus.birth.source", caseIdx, order.planId));
            signalId = keccak256(abi.encode("corpus.birth.signal", caseIdx, order.planId));
            payload = keccak256(abi.encode(caseIdx, "synthetic-birth", orderIdx));
            vm.warp(order.registeredAt);
        }
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: order.chainPlanId,
            creator: ORDER_CREATOR,
            triggerHookId: triggerHookId,
            triggerStageId: triggerStageId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: payload,
            idempotencyKey: keccak256(abi.encode(caseIdx, "birth", orderIdx)),
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        UVPStateMachine.SignalAuthorization[] memory authorizations = _authorizationsForOrder(orderIdx);
        bytes memory signature = _outsideTriggerSignature(trigger, authorizations);
        try machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _noAttribution()) {
            order.chainOrderId = machine.triggerOrderIdFor(order.chainPlanId, sourceId, signalId, payload);
            if (birthSignalIdx != type(uint256).max) {
                _markWritten(birthSignalIdx);
            }
            return true;
        } catch (bytes memory reason) {
            require(reason.length >= 4, "birth reverted without selector");
            require(bytes4(reason) == UVPStateMachine.InvalidTriggerHook.selector, "unexpected corpus birth rejection");
            return false;
        }
    }

    /// dock 出生：出生事实 = 订单首个语料信号（case 8 的 entrance 事实）；
    /// 无信号订单（case 17 毒格）用 entrance 钩子指令自带身份对。
    function _birthDockOrder(uint256 caseIdx, uint256 orderIdx, uint256 signalIdx) private {
        OrderRow storage order = orders[orderIdx];
        RawPlan storage plan = _planByCorpusId(order.planId);
        RawHook storage entrance = _dockHookOf(plan);
        bytes32 sourceId;
        bytes32 signalId;
        bytes32 payload;
        if (signalIdx != type(uint256).max) {
            SignalRow storage entranceFact = signals[signalIdx];
            sourceId = entranceFact.sourceId;
            signalId = entranceFact.signalId;
            payload = entranceFact.payload;
        } else {
            sourceId = entrance.instrs[0].sourceId;
            signalId = entrance.instrs[0].signalId;
            payload = keccak256(abi.encode(caseIdx, "dock-entrance"));
        }
        bytes32 linkedOrderId = bytes32(uint256(keccak256(bytes(order.orderId))) | (uint256(1) << 255));
        UVPStateMachine.DockEntranceRequest memory request = UVPStateMachine.DockEntranceRequest({
            targetPlanId: order.chainPlanId,
            linkedOrderId: linkedOrderId,
            creator: ORDER_CREATOR,
            relayer: address(this),
            entranceHookId: entrance.hookId,
            entranceStageId: entrance.stageId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: payload,
            idempotencyKey: keccak256(abi.encode(caseIdx, "dock", orderIdx)),
            submitter: address(this),
            authorizations: _authorizationsForOrder(orderIdx),
            entranceAttribution: _noAttribution()
        });
        vm.warp(order.registeredAt);
        vm.prank(address(docking));
        machine.createDockedOrderFromModule(request);
        order.chainOrderId = linkedOrderId;
        if (signalIdx != type(uint256).max) {
            _markWritten(signalIdx);
        }
    }

    /// order-link 派生出生（case 6）：origin 订单持有被消费事实，子单出生
    /// 不写子单信号——派生 readiness 由链接事务直接落 HookReady + 物化。
    function _birthOrderLink(uint256 caseIdx, uint256 orderIdx) private {
        OrderRow storage child = orders[orderIdx];
        uint256 triggeredIdx = _triggeredRowOf(child.planId, child.orderId);
        bytes32 originSourceId = triggeredSourceIds[triggeredIdx];
        bytes32 originSignalId = triggeredSignalIds[triggeredIdx];
        uint256 originSignalIdx = _signalByFact(originSourceId, originSignalId);
        require(originSignalIdx != type(uint256).max, "order-link origin fact missing");
        SignalRow storage originFact = signals[originSignalIdx];
        OrderRow storage origin = _orderByCorpus(originFact.planId, originFact.orderId);
        require(origin.born, "order-link origin must be born first");
        RawPlan storage childPlan = _planByCorpusId(child.planId);
        bytes32 payload = keccak256(abi.encode(caseIdx, "link", orderIdx));
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger =
            IUVPStateMachineCore.TriggerOrderFromSignalRequest({
                orderId: machine.orderLinkOrderIdFor(
                    child.chainPlanId, origin.chainPlanId, origin.chainOrderId, originSourceId, originSignalId, payload
                ),
                planId: child.chainPlanId,
                creator: ORDER_CREATOR,
                triggerOriginOrderId: origin.chainOrderId,
                originPlanId: origin.chainPlanId,
                triggerHookId: _mintHookOf(childPlan),
                triggerStageId: _hookStage(childPlan, _mintHookOf(childPlan)),
                originSourceId: originSourceId,
                originSignalId: originSignalId,
                payloadHash: payload,
                idempotencyKey: keccak256(abi.encode(caseIdx, "link-idem", orderIdx)),
                submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
                deadline: type(uint256).max
            });
        IUVPStateMachineCore.SignalAuthorization[] memory noAuths = new IUVPStateMachineCore.SignalAuthorization[](0);
        bytes32 digest = orderLink.triggerOrderFromSignalDigest(trigger, orderLink.signalAuthorizationsHash(noAuths));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        vm.warp(child.registeredAt);
        orderLink.triggerOrderFromSignalFor(
            trigger, noAuths, _packedSignature(v, r, s), new IUVPStateMachineCore.FactAttribution[](0)
        );
        child.chainOrderId = trigger.orderId;
    }

    // ======================================================================
    // 信号 / poke 重演
    // ======================================================================

    function _replayPoke(uint256 pokeIdx) private {
        PokeRow storage poke = pokes[pokeIdx];
        OrderRow storage order = _orderByCorpus(poke.planId, poke.orderId);
        if (poke.hasPokedAt) {
            vm.warp(poke.pokedAt);
            machine.pokeTimer(order.chainPlanId, order.chainOrderId, poke.hookId);
            return;
        }
        // 毒格（poke 缺求值时钟）：链上时钟恒在（block.timestamp），不可能
        // 产生无时钟 poke——消费为链自己的响亮闸：未到期 poke TimerNotDue，
        // 到期拍正常放行。
        require(hasDeclaredWaitDueAt, "clock-less poke case must declare a wait dueAt");
        vm.warp(declaredWaitDueAt - 1);
        vm.expectRevert(UVPStateMachine.TimerNotDue.selector);
        machine.pokeTimer(order.chainPlanId, order.chainOrderId, poke.hookId);
        vm.warp(declaredWaitDueAt);
        machine.pokeTimer(order.chainPlanId, order.chainOrderId, poke.hookId);
    }

    function _markWritten(uint256 signalIdx) private {
        SignalRow storage sig = signals[signalIdx];
        if (sig.written) {
            return; // 首写已定（first-win：后续重复提交不得改写）
        }
        sig.written = true;
    }

    // ======================================================================
    // 对拍断言
    // ======================================================================

    function _assertObservableFace(uint256 caseIdx, CorpusVm.Log[] memory logs) private {
        string memory json = corpusJson;
        bytes32[MAX_EVENTS] memory observed;
        uint256 produced = _collectObservable(logs, observed);
        uint256 declared;
        for (uint256 i = 0; i < MAX_EVENTS; i++) {
            (bool ok, string memory name) =
                _tryString(json, _casePath(caseIdx, string.concat(".expect.observedEvents[", _toString(i), "]")));
            if (!ok) {
                break;
            }
            require(i < produced, "corpus expects more observable events than produced");
            require(observed[i] == keccak256(bytes(name)), "observable event sequence mismatch");
            declared += 1;
        }
        if (declared == 0) {
            require(produced == _caseObservedCount(caseIdx), "observable observation count mismatch");
        } else {
            require(produced == declared, "observable event count mismatch");
        }
    }

    /// 收集观察面（镜像 oracle 的 observable face）：语料钩子范围内
    /// wait/cxl 的 HookStatusChanged + HookReady，按日志序。
    function _collectObservable(CorpusVm.Log[] memory logs, bytes32[MAX_EVENTS] memory out)
        private
        view
        returns (uint256)
    {
        uint256 count;
        for (uint256 i = 0; i < logs.length && count < MAX_EVENTS; i++) {
            CorpusVm.Log memory log = logs[i];
            if (log.topics.length < 4) {
                continue;
            }
            if (log.topics[0] == TOPIC_HOOK_READY) {
                if (corpusHookIds[log.topics[3]]) {
                    out[count] = keccak256("HookReady");
                    count += 1;
                }
            } else if (log.topics[0] == TOPIC_HOOK_STATUS_CHANGED) {
                if (corpusHookIds[log.topics[3]]) {
                    (, uint8 newStatus,) = abi.decode(log.data, (uint8, uint8, uint64));
                    if (
                        newStatus == uint8(UVPStateMachine.HookStatus.Wait)
                            || newStatus == uint8(UVPStateMachine.HookStatus.Cancelled)
                    ) {
                        out[count] = keccak256("HookStatusChanged");
                        count += 1;
                    }
                }
            }
        }
        return count;
    }

    function _assertWaitDueAt(uint256 caseIdx, CorpusVm.Log[] memory logs) private {
        string memory json = corpusJson;
        (bool hasDue, string memory dueRaw) = _tryString(json, _casePath(caseIdx, ".expect.waitDueAt"));
        if (!hasDue) {
            return;
        }
        (, uint64 expected) = _requireTimestamp(dueRaw);
        uint64 maxWaitDue;
        for (uint256 i = 0; i < logs.length; i++) {
            CorpusVm.Log memory log = logs[i];
            if (log.topics.length < 4 || log.topics[0] != TOPIC_HOOK_STATUS_CHANGED || !corpusHookIds[log.topics[3]]) {
                continue;
            }
            (, uint8 newStatus, uint64 dueAt) = abi.decode(log.data, (uint8, uint8, uint64));
            if (newStatus == uint8(UVPStateMachine.HookStatus.Wait) && dueAt > maxWaitDue) {
                maxWaitDue = dueAt;
            }
        }
        require(maxWaitDue == expected, "wait dueAt mismatch");
    }

    function _assertFinalHookStatuses(uint256 caseIdx) private {
        string memory json = corpusJson;
        for (uint256 o = 0; o < orderCount; o++) {
            OrderRow storage order = orders[o];
            if (!order.born) {
                continue;
            }
            RawPlan storage plan = _planByCorpusId(order.planId);
            for (uint256 h = 0; h < plan.hooks.length; h++) {
                RawHook storage hook = plan.hooks[h];
                string memory statusPath = _casePath(
                    caseIdx,
                    string.concat(
                        ".expect.finalHookStatuses[\"",
                        string.concat(order.corpusPlanIdHex, "::", order.orderId, "\"][\"", hook.hookIdHex, "\"]")
                    )
                );
                (bool ok, string memory status) = _tryString(json, statusPath);
                if (!ok) {
                    continue;
                }
                (UVPStateMachine.HookStatus chainStatus,,) =
                    machine.getHookStatus(order.chainPlanId, order.chainOrderId, hook.hookId);
                require(chainStatus == _statusOf(status), "final hook status mismatch");
            }
        }
    }

    function _assertStateOrderKeys(uint256 caseIdx) private {
        string memory json = corpusJson;
        for (uint256 i = 0; i < MAX_ORDERS; i++) {
            (bool ok, string memory orderKey) =
                _tryString(json, _casePath(caseIdx, string.concat(".expect.stateOrderKeys[", _toString(i), "]")));
            if (!ok) {
                break;
            }
            (bytes32 planId, string memory orderId) = _splitOrderKey(orderKey);
            OrderRow storage order = _orderByCorpus(planId, orderId);
            require(
                machine.orderExists(order.chainPlanId, order.chainOrderId), "corpus state order key missing on chain"
            );
        }
    }

    /// first-win：同一订单同一信号槽，链上落库载荷必须保持首写值（重复
    /// 提交被吸收；语料 senderId/eventId 的链上对应物即首写身份）。
    function _assertFirstWriteStays() private {
        for (uint256 s = 0; s < signalCount; s++) {
            SignalRow storage sig = signals[s];
            if (!sig.written) {
                continue;
            }
            if (!_isEarliestRowOfKey(s)) {
                continue; // 重复行：以首行为准
            }
            OrderRow storage order = _orderByCorpus(sig.planId, sig.orderId);
            if (!order.born) {
                continue;
            }
            (bool exists, bytes32 payloadHash,,,) =
                machine.getSignal(order.chainPlanId, order.chainOrderId, sig.sourceId, sig.signalId);
            require(exists, "written corpus signal missing");
            require(payloadHash == sig.payload, "first-write payload was overwritten");
        }
    }

    function _assertDockBirthAtomic(CorpusVm.Log[] memory logs) private {
        // missing-observed 毒格：dock ready 无出生事实在链上不可产生——诚实
        // dock 出生中 SignalSubmitted(entrance) 与 HookReady 同事务出现。
        bool sawSubmitted;
        bool sawReady;
        for (uint256 i = 0; i < logs.length; i++) {
            CorpusVm.Log memory log = logs[i];
            if (log.topics.length == 0) {
                continue;
            }
            if (log.topics[0] == TOPIC_SIGNAL_SUBMITTED) {
                sawSubmitted = true;
            }
            if (log.topics[0] == TOPIC_HOOK_READY && log.topics.length > 3 && corpusHookIds[log.topics[3]]) {
                sawReady = true;
            }
        }
        require(sawSubmitted && sawReady, "dock entrance fact and HookReady must be atomic");
    }

    // ======================================================================
    // 发射适格面（filter 档 evalCases）消费
    // ======================================================================

    bytes32 private constant FILTER_FORM_A =
        keccak256("buyer::execute.locked & ~(execute.approved +5s) & ~execute.confirm_transfer");
    bytes32 private constant FILTER_FORM_B = keccak256("buyer::(~a.cmp)+5s");
    bytes32 private constant FILTER_FORM_C = keccak256("buyer::(~a.cmp | b.cmp)+5s");
    bytes32 private constant FILTER_FORM_D = keccak256("buyer::(~a.cmp | ~b.cmp)+5s");
    /// 双活否决最紧期族：两个负延时臂（approved+5s / reviewed+10s）同时
    /// 在线，放行窗口由更早成熟的否决臂封顶（语料 expiresAt = min 两臂）。
    bytes32 private constant FILTER_FORM_E =
        keccak256("buyer::execute.locked & ~(execute.approved +5s) & ~(execute.reviewed +10s)");

    /// filter 档 evalCases 全消费：DSL 串钉五形态（漂移即响亮失败），信
    /// 号集/时刻/期望态从语料读取。锚定格都在消费集内：无锚延时（33）→
    /// 链轨注册闸拒绝；真空 OR 臂让位（34）→ now 拒绝 + readyAt 放行两腿；
    /// 双活否决最紧期（39）→ expiresAt 拍拒绝 + now 拍放行两腿。
    /// DSL→指令的形态镜像是静态的（链轨无 DSL 解析器；编译器在 TS 侧）。
    function testFilterAdmissionEvalCorpus() public {
        _loadCorpus();
        string memory json = corpusJson;
        uint256 consumed;
        uint256 caseIdx;
        for (;;) {
            (bool hasCase,) = _tryString(json, string.concat(".evalCases[", _toString(caseIdx), "].name"));
            if (!hasCase) {
                break;
            }
            (bool hasGate, string memory gate) =
                _tryString(json, string.concat(".evalCases[", _toString(caseIdx), "].gate"));
            if (hasGate && keccak256(bytes(gate)) == keccak256("filter")) {
                _runFilterCase(caseIdx);
                consumed += 1;
            }
            caseIdx += 1;
        }
        require(consumed == FILTER_CASE_COUNT, "filter corpus case count drifted");
    }

    function _runFilterCase(uint256 caseIdx) private {
        string memory json = corpusJson;
        string memory base = string.concat(".evalCases[", _toString(caseIdx), "]");
        bytes32 form = keccak256(bytes(vm.parseJsonString(json, string.concat(base, ".hook"))));
        (, uint64 nowSec) = _requireTimestamp(vm.parseJsonString(json, string.concat(base, ".now")));
        string memory state = vm.parseJsonString(json, string.concat(base, ".expect.state"));
        bytes32 stateHash = keccak256(bytes(state));

        machine = _newCaseMachine();
        bytes32 birthSource = keccak256("corpus.filter.birth.source");
        bytes32 birthSignal = keccak256("corpus.filter.birth.signal");
        bytes32 birthStage = keccak256(abi.encode("corpus.filter.stage", caseIdx));

        // 前置信号名集（先读后用：授权面需要覆盖它们）。
        string[MAX_SIGNALS] memory signalNames;
        uint256 signalNameCount;
        for (uint256 i = 0; i < MAX_SIGNALS; i++) {
            (bool ok, string memory signalName) =
                _tryString(json, string.concat(base, ".signals[", _toString(i), "].signalName"));
            if (!ok) {
                break;
            }
            signalNames[i] = signalName;
            signalNameCount += 1;
        }

        bytes32 emitSource = keccak256("corpus.filter.emit.source");
        bytes32 emitSignal = keccak256("corpus.filter.emit.signal");
        UVPStateMachine.Instruction[] memory admissionInstrs;
        if (form == FILTER_FORM_A) {
            admissionInstrs = new UVPStateMachine.Instruction[](7);
            admissionInstrs[0] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("execute.locked"), 0, 0
            );
            admissionInstrs[1] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("execute.approved"), 0, 0
            );
            admissionInstrs[2] = _instruction(uint8(UVPStateMachine.InstructionOp.Delay), bytes32(0), bytes32(0), 0, 5);
            admissionInstrs[3] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[4] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal),
                _filterSource(),
                _filterSignal("execute.confirm_transfer"),
                0,
                0
            );
            admissionInstrs[5] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[6] = _instruction(uint8(UVPStateMachine.InstructionOp.And), bytes32(0), bytes32(0), 3, 0);
        } else if (form == FILTER_FORM_B) {
            // 无锚延时：链轨注册闸即拒（求值侧永不放行的死代码）——语料期
            // 望 needs_more，链上先在 commit 边界拒绝。
            admissionInstrs = new UVPStateMachine.Instruction[](3);
            admissionInstrs[0] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("a.cmp"), 0, 0
            );
            admissionInstrs[1] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[2] = _instruction(uint8(UVPStateMachine.InstructionOp.Delay), bytes32(0), bytes32(0), 0, 5);
            _expectAdmissionCommitRevert(admissionInstrs, birthSource, birthSignal, emitSource, emitSignal, birthStage);
            return;
        } else if (form == FILTER_FORM_D) {
            // 双真空 OR 平票（(0,0) 格）：两臂皆无锚 → OR 结果无正锚，外层
            // 延时注册即拒（§5.4 无锚分支永不出线；求值侧期望 needs_more，
            // 链上先在 commit 边界拒绝——与 FORM_B 同款死代码闸）。
            admissionInstrs = new UVPStateMachine.Instruction[](6);
            admissionInstrs[0] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("a.cmp"), 0, 0
            );
            admissionInstrs[1] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[2] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("b.cmp"), 0, 0
            );
            admissionInstrs[3] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[4] = _instruction(uint8(UVPStateMachine.InstructionOp.Or), bytes32(0), bytes32(0), 2, 0);
            admissionInstrs[5] = _instruction(uint8(UVPStateMachine.InstructionOp.Delay), bytes32(0), bytes32(0), 0, 5);
            _expectAdmissionCommitRevert(admissionInstrs, birthSource, birthSignal, emitSource, emitSignal, birthStage);
            return;
        } else if (form == FILTER_FORM_C) {
            admissionInstrs = new UVPStateMachine.Instruction[](5);
            admissionInstrs[0] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("a.cmp"), 0, 0
            );
            admissionInstrs[1] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[2] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("b.cmp"), 0, 0
            );
            admissionInstrs[3] = _instruction(uint8(UVPStateMachine.InstructionOp.Or), bytes32(0), bytes32(0), 2, 0);
            admissionInstrs[4] = _instruction(uint8(UVPStateMachine.InstructionOp.Delay), bytes32(0), bytes32(0), 0, 5);
        } else if (form == FILTER_FORM_E) {
            // 双活否决最紧期：FORM_A 的第二裸否决臂换成 reviewed+10s 延时
            // 否决臂——AND 的放行窗口由更早成熟的 approved+5s 封顶（语料
            // expiresAt = 05s 拍，见 ready 腿的到期探针）。
            admissionInstrs = new UVPStateMachine.Instruction[](8);
            admissionInstrs[0] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("execute.locked"), 0, 0
            );
            admissionInstrs[1] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("execute.approved"), 0, 0
            );
            admissionInstrs[2] = _instruction(uint8(UVPStateMachine.InstructionOp.Delay), bytes32(0), bytes32(0), 0, 5);
            admissionInstrs[3] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[4] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("execute.reviewed"), 0, 0
            );
            admissionInstrs[5] = _instruction(uint8(UVPStateMachine.InstructionOp.Delay), bytes32(0), bytes32(0), 0, 10);
            admissionInstrs[6] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[7] = _instruction(uint8(UVPStateMachine.InstructionOp.And), bytes32(0), bytes32(0), 3, 0);
        } else {
            revert("unknown filter corpus form");
        }

        // 机器：合成出生钩 + 适格面（挂被发射事实），订单出生后按语料时刻
        // 落前置信号，再在 now 拍尝试发射。
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory birthInstrs = new UVPStateMachine.Instruction[](1);
        birthInstrs[0] = _instruction(uint8(UVPStateMachine.InstructionOp.Signal), birthSource, birthSignal, 0, 0);
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode("corpus.filter.birth.hook", caseIdx)),
            stageId: birthStage,
            hookName: keccak256(abi.encode("corpus.filter.birth.hookname", caseIdx)),
            flags: FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            instructions: birthInstrs,
            dependencyKeys: _depsOf(birthInstrs)
        });
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(emitSource, emitSignal)),
            stageId: birthStage,
            hookName: keccak256(abi.encode("corpus.filter.admission", caseIdx)),
            flags: FLAG_ADMISSION,
            instructions: admissionInstrs,
            dependencyKeys: _depsOf(admissionInstrs)
        });
        (bytes32 planId, bytes4 planRevert) = _commitHooks(hooks);
        require(planId != bytes32(0) && planRevert == 0, "filter corpus plan must register");

        UVPStateMachine.SignalAuthorization[] memory authorizations =
            new UVPStateMachine.SignalAuthorization[](signalNameCount + 2);
        authorizations[0] = _authorization(birthSource, birthSignal, address(this));
        authorizations[1] = _authorization(emitSource, emitSignal, address(this));
        for (uint256 i = 0; i < signalNameCount; i++) {
            authorizations[2 + i] = _authorization(_filterSource(), _filterSignal(signalNames[i]), address(this));
        }
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: planId,
            creator: ORDER_CREATOR,
            triggerHookId: hooks[0].hookId,
            triggerStageId: birthStage,
            sourceId: birthSource,
            signalId: birthSignal,
            payloadHash: keccak256(abi.encode(caseIdx, "filter-birth")),
            idempotencyKey: keccak256(abi.encode(caseIdx, "filter-birth-idem")),
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        bytes memory signature = _outsideTriggerSignature(trigger, authorizations);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _noAttribution());
        bytes32 orderId = machine.triggerOrderIdFor(planId, birthSource, birthSignal, trigger.payloadHash);

        // 前置信号按语料时刻落库。
        for (uint256 i = 0; i < signalNameCount; i++) {
            (, uint64 receivedAt) = _requireTimestamp(
                vm.parseJsonString(json, string.concat(base, ".signals[", _toString(i), "].receivedAt"))
            );
            vm.warp(receivedAt);
            machine.submitSignal(
                planId,
                orderId,
                _filterSource(),
                _filterSignal(signalNames[i]),
                keccak256(abi.encode(caseIdx, "filter-signal", i)),
                keccak256(abi.encode(caseIdx, "filter-signal-idem", i)),
                _noAttribution()
            );
        }

        vm.warp(nowSec);
        bytes32 emitPayload = keccak256(abi.encode(caseIdx, "emit"));
        if (stateHash == keccak256("ready")) {
            // 否决窗口到期拍探针（语料 expiresAt 非空时）：Rust 语义在窗口
            // 关闭拍判 negated condition exists → 发射必须响亮拒绝；双活
            // 否决形态（FORM_E）由此钉住"窗口由更早成熟的否决臂封顶"——
            // 若实现错误锚定在更晚成熟的臂上，到期拍发射会错误落地。先探
            // 后放：first-win 吸收在适格门之前，成功发射后的重复提交会被
            // 吸收而非拒绝，到期拍必须在成功发射前探测。
            (bool hasExpiresAt, string memory expiresAtRaw) =
                _tryString(json, string.concat(base, ".expect.expiresAt"));
            if (hasExpiresAt && keccak256(bytes(expiresAtRaw)) != keccak256("null")) {
                (, uint64 expiresAt) = _requireTimestamp(expiresAtRaw);
                vm.warp(expiresAt);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        UVPStateMachine.SignalAdmissionRejected.selector, orderId, emitSource, emitSignal
                    )
                );
                machine.submitSignal(
                    planId, orderId, emitSource, emitSignal, emitPayload, bytes32(uint256(1)), _noAttribution()
                );
                vm.warp(nowSec);
            }
            machine.submitSignal(
                planId, orderId, emitSource, emitSignal, emitPayload, bytes32(uint256(1)), _noAttribution()
            );
            (bool exists, bytes32 payloadHash,,,) = machine.getSignal(planId, orderId, emitSource, emitSignal);
            require(exists && payloadHash == emitPayload, "admitted emission missing");
        } else if (stateHash == keccak256("wait")) {
            // 真空 OR 臂让位：now 拍延时未熟 → 拒绝；readyAt 拍放行。
            vm.expectRevert(
                abi.encodeWithSelector(
                    UVPStateMachine.SignalAdmissionRejected.selector, orderId, emitSource, emitSignal
                )
            );
            machine.submitSignal(
                planId, orderId, emitSource, emitSignal, emitPayload, bytes32(uint256(1)), _noAttribution()
            );
            (bool hasReadyAt, string memory readyAtRaw) = _tryString(json, string.concat(base, ".expect.readyAt"));
            require(hasReadyAt, "wait-state corpus case must pin readyAt");
            (, uint64 readyAt) = _requireTimestamp(readyAtRaw);
            vm.warp(readyAt);
            machine.submitSignal(
                planId, orderId, emitSource, emitSignal, emitPayload, bytes32(uint256(1)), _noAttribution()
            );
            (bool exists,,,,) = machine.getSignal(planId, orderId, emitSource, emitSignal);
            require(exists, "emission must land at corpus readyAt");
        } else if (stateHash == keccak256("needs_more") || stateHash == keccak256("impossible")) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    UVPStateMachine.SignalAdmissionRejected.selector, orderId, emitSource, emitSignal
                )
            );
            machine.submitSignal(
                planId, orderId, emitSource, emitSignal, emitPayload, bytes32(uint256(1)), _noAttribution()
            );
            (bool exists,,,,) = machine.getSignal(planId, orderId, emitSource, emitSignal);
            require(!exists, "rejected emission must not record a fact");
        } else {
            revert("unknown filter corpus expect state");
        }
    }

    function _expectAdmissionCommitRevert(
        UVPStateMachine.Instruction[] memory admissionInstrs,
        bytes32 birthSource,
        bytes32 birthSignal,
        bytes32 emitSource,
        bytes32 emitSignal,
        bytes32 birthStage
    ) private {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory birthInstrs = new UVPStateMachine.Instruction[](1);
        birthInstrs[0] = _instruction(uint8(UVPStateMachine.InstructionOp.Signal), birthSource, birthSignal, 0, 0);
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(birthSource, birthSignal)),
            stageId: birthStage,
            hookName: keccak256("corpus.filter.birth.hookname"),
            flags: FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            instructions: birthInstrs,
            dependencyKeys: _depsOf(birthInstrs)
        });
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(emitSource, emitSignal)),
            stageId: birthStage,
            hookName: keccak256("corpus.filter.admission"),
            flags: FLAG_ADMISSION,
            instructions: admissionInstrs,
            dependencyKeys: _depsOf(admissionInstrs)
        });
        address publisher = vm.addr(PUBLISHER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: EMPTY_DOCK_ROOT,
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), _packedSignature(v, r, s));
    }

    function _filterSource() private pure returns (bytes32) {
        return keccak256("buyer");
    }

    function _filterSignal(string memory signalName) private pure returns (bytes32) {
        return keccak256(bytes(signalName));
    }

    // ======================================================================
    // 机器装配
    // ======================================================================

    function _newCaseMachine() private returns (UVPStateMachine newMachine) {
        newMachine = new UVPStateMachine();
        UVPStagePatchModule stagePatch = new UVPStagePatchModule(address(newMachine));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(newMachine));
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(newMachine));
        docking = new UVPDockingModule(address(newMachine), address(planMetadata));
        orderLink = new UVPOrderLinkModule(address(newMachine));
        newMachine.setStagePatchModule(address(stagePatch));
        newMachine.setDerivedSignalModule(address(derivedSignal));
        newMachine.setDockingModule(address(docking));
        newMachine.setPlanMetadataModule(address(planMetadata));
        newMachine.setOrderLinkModule(address(orderLink));
        newMachine.setLens(address(new UVPStateMachineLens(address(newMachine))));
        newMachine.freezeModules();
    }

    // ======================================================================
    // 基建 helper
    // ======================================================================

    function _loadCorpus() private {
        if (bytes(corpusJson).length != 0) {
            return;
        }
        corpusJson = vm.readFile(string.concat(vm.projectRoot(), "/../../../uvp-core/fixtures/hook/semantics.v1.json"));
        // meta sha 钉（Rust/TS 同款三线钉）：语料内容与 uvp-core 声明的
        // contentSha256 用 SHA256 预编译逐字节比对，不等即响亮失败——本仓
        // 不落语料副本，钉住的是对岸文件内容本身。
        string memory metaJson =
            vm.readFile(string.concat(vm.projectRoot(), "/../../../uvp-core/fixtures/hook/semantics.v1.meta.json"));
        require(
            _eq(vm.parseJsonString(metaJson, ".algorithm"), "sha256"),
            "corpus meta algorithm drifted; only sha256 is implemented"
        );
        bytes32 declared = _hexToBytes32(string.concat("0x", vm.parseJsonString(metaJson, ".contentSha256")));
        require(
            _sha256(bytes(corpusJson)) == declared,
            "semantic corpus content diverged from semantics.v1.meta.json contentSha256; recompute and update the meta in the same change"
        );
    }

    function _sha256(bytes memory input) private view returns (bytes32 digest) {
        bool ok;
        assembly {
            let out := mload(0x40)
            ok := staticcall(gas(), 2, add(input, 32), mload(input), out, 32)
            digest := mload(out)
        }
        require(ok, "sha256 precompile failed");
    }

    function _resetCase() private {
        for (uint256 i = 0; i < eventCount; i++) {
            events[i].exists = false;
        }
        for (uint256 p = 0; p < planCount; p++) {
            delete plans[p].hooks;
            delete plans[p].admissions;
            plans[p].exists = false;
            plans[p].hasMint = false;
            plans[p].hasDock = false;
            plans[p].chainPlanId = bytes32(0);
            plans[p].birthHookId = bytes32(0);
            plans[p].birthStageId = bytes32(0);
        }
        for (uint256 s = 0; s < signalCount; s++) {
            signals[s].exists = false;
            signals[s].written = false;
        }
        for (uint256 o = 0; o < orderCount; o++) {
            orders[o].exists = false;
            orders[o].born = false;
        }
        for (uint256 k = 0; k < pokeCount; k++) {
            pokes[k].exists = false;
        }
        for (uint256 m = 0; m < markedHookCount; m++) {
            corpusHookIds[markedHookIds[m]] = false;
        }
        eventCount = 0;
        planCount = 0;
        signalCount = 0;
        orderCount = 0;
        pokeCount = 0;
        triggeredCount = 0;
        markedHookCount = 0;
        declaredWaitDueAt = 0;
        hasDeclaredWaitDueAt = false;
        mismatchReasonHash = 0;
    }

    function _markCorpusHook(bytes32 hookId) private {
        if (corpusHookIds[hookId]) {
            return;
        }
        require(markedHookCount < markedHookIds.length, "corpus hook mark overflow");
        corpusHookIds[hookId] = true;
        markedHookIds[markedHookCount] = hookId;
        markedHookCount += 1;
    }

    function _casePath(uint256 caseIdx, string memory suffix) private pure returns (string memory) {
        return string.concat(".replayCases[", _toString(caseIdx), "]", suffix);
    }

    function _caseObservedCount(uint256 caseIdx) private returns (uint256) {
        return vm.parseJsonUint(corpusJson, _casePath(caseIdx, ".expect.observedCount"));
    }

    function _sortEventsByCanonicalOrder() private {
        for (uint256 i = 1; i < eventCount; i++) {
            EventRow memory key = events[i];
            uint256 j = i;
            while (j > 0 && _eventLess(key, events[j - 1])) {
                events[j] = events[j - 1];
                j -= 1;
            }
            events[j] = key;
        }
    }

    function _eventLess(EventRow memory a, EventRow memory b) private pure returns (bool) {
        if (a.blockNumber != b.blockNumber) {
            return a.blockNumber < b.blockNumber;
        }
        return a.logIndex < b.logIndex;
    }

    function _tryString(string memory json, string memory path) private returns (bool ok, string memory value) {
        try vm.parseJsonString(json, path) returns (string memory parsed) {
            return (true, parsed);
        } catch {
            return (false, "");
        }
    }

    function _tryBytes32(string memory json, string memory path) private returns (bool ok, bytes32 value) {
        try vm.parseJsonBytes32(json, path) returns (bytes32 parsed) {
            return (true, parsed);
        } catch {
            return (false, bytes32(0));
        }
    }

    /// 语料时间戳形态（chrono 严格 RFC3339 的实际使用子集）：
    /// YYYY-MM-DDTHH:MM:SS.mmmZ——亚秒丢弃（native timestamp() 只取整秒）。
    function _requireTimestamp(string memory raw) private pure returns (bool, uint64) {
        bytes memory b = bytes(raw);
        require(b.length == 24, "corpus timestamp shape");
        require(
            b[4] == "-" && b[7] == "-" && b[10] == "T" && b[13] == ":" && b[16] == ":" && b[19] == "." && b[23] == "Z",
            "corpus timestamp shape"
        );
        uint256 year = _digits(b, 0, 4);
        uint256 month = _digits(b, 5, 2);
        uint256 day = _digits(b, 8, 2);
        uint256 hour = _digits(b, 11, 2);
        uint256 minute = _digits(b, 14, 2);
        uint256 second = _digits(b, 17, 2);
        require(month >= 1 && month <= 12, "corpus timestamp month");
        require(day >= 1 && day <= _daysInMonth(year, month), "corpus timestamp day");
        require(hour <= 23 && minute <= 59 && second <= 59, "corpus timestamp time");
        return (true, uint64(_daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second));
    }

    function _digits(bytes memory b, uint256 start, uint256 len) private pure returns (uint256) {
        uint256 value;
        for (uint256 i = start; i < start + len; i++) {
            uint8 char = uint8(b[i]);
            require(char >= 48 && char <= 57, "corpus timestamp digit");
            value = value * 10 + (char - 48);
        }
        return value;
    }

    function _isLeap(uint256 year) private pure returns (bool) {
        return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    }

    function _daysInMonth(uint256 year, uint256 month) private pure returns (uint256) {
        if (month == 2) {
            return _isLeap(year) ? 29 : 28;
        }
        if (month == 4 || month == 6 || month == 9 || month == 11) {
            return 30;
        }
        return 31;
    }

    /// proleptic Gregorian civil 日期 → epoch 天数（chrono NaiveDate 同历
    /// 法；packages/statemachine chain.ts 的整数实现同款移植）。
    function _daysFromCivil(uint256 year, uint256 month, uint256 day) private pure returns (uint256) {
        uint256 shiftedYear = year - (month <= 2 ? 1 : 0);
        uint256 era = shiftedYear / 400;
        uint256 yearOfEra = shiftedYear - era * 400;
        uint256 shiftedMonth = month > 2 ? month - 3 : month + 9;
        uint256 dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1;
        uint256 dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
        return era * 146097 + dayOfEra - 719468;
    }

    function _instruction(uint8 op, bytes32 sourceId, bytes32 signalId, uint16 arity, uint64 delaySeconds)
        private
        pure
        returns (UVPStateMachine.Instruction memory)
    {
        return UVPStateMachine.Instruction({
            op: op, sourceId: sourceId, signalId: signalId, arity: arity, delaySeconds: delaySeconds
        });
    }

    function _depsOf(UVPStateMachine.Instruction[] memory instrs) private pure returns (bytes32[] memory deps) {
        bytes32[] memory scratch = new bytes32[](instrs.length);
        uint256 count;
        for (uint256 i = 0; i < instrs.length; i++) {
            if (instrs[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            bytes32 key = keccak256(abi.encode(instrs[i].sourceId, instrs[i].signalId));
            bool seen;
            for (uint256 j = 0; j < count; j++) {
                if (scratch[j] == key) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                scratch[count] = key;
                count += 1;
            }
        }
        deps = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            deps[i] = scratch[i];
        }
    }

    function _authorization(bytes32 sourceId, bytes32 signalId, address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization memory)
    {
        return UVPStateMachine.SignalAuthorization({
            sourceId: sourceId,
            signalId: signalId,
            submitter: submitter,
            role: ROLE_BOOTSTRAP,
            metadataHash: AUTH_METADATA_HASH
        });
    }

    function _authorizationsForOrder(uint256 orderIdx)
        private
        view
        returns (UVPStateMachine.SignalAuthorization[] memory)
    {
        OrderRow storage order = orders[orderIdx];
        UVPStateMachine.SignalAuthorization[] memory scratch = new UVPStateMachine.SignalAuthorization[](signalCount);
        uint256 distinct;
        for (uint256 s = 0; s < signalCount; s++) {
            SignalRow storage sig = signals[s];
            if (!sig.exists || sig.planId != order.planId || !_eq(sig.orderId, order.orderId)) {
                continue;
            }
            bool seen;
            for (uint256 j = 0; j < distinct; j++) {
                if (scratch[j].sourceId == sig.sourceId && scratch[j].signalId == sig.signalId) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                scratch[distinct] = _authorization(sig.sourceId, sig.signalId, address(this));
                distinct += 1;
            }
        }
        UVPStateMachine.SignalAuthorization[] memory authorizations =
            new UVPStateMachine.SignalAuthorization[](distinct);
        for (uint256 i = 0; i < distinct; i++) {
            authorizations[i] = scratch[i];
        }
        return authorizations;
    }

    function _outsideTriggerSignature(
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private returns (bytes memory) {
        bytes32 rollingHash = keccak256(abi.encode(authorizations.length));
        for (uint256 i = 0; i < authorizations.length; i++) {
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    authorizations[i].sourceId,
                    authorizations[i].signalId,
                    authorizations[i].submitter,
                    authorizations[i].role,
                    authorizations[i].metadataHash
                )
            );
        }
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
                rollingHash,
                trigger.submitter,
                trigger.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        return _packedSignature(v, r, s);
    }

    function _stateMachineDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                STATE_MACHINE_NAME_HASH,
                STATE_MACHINE_VERSION_HASH,
                block.chainid,
                address(machine)
            )
        );
    }

    function _packedSignature(uint8 v, bytes32 r, bytes32 s) private pure returns (bytes memory) {
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
    }

    // ----------------------------------------------------------------------
    // 行查找
    // ----------------------------------------------------------------------

    function _planIndexByCorpusId(bytes32 planId) private view returns (uint256) {
        for (uint256 p = 0; p < planCount; p++) {
            if (plans[p].corpusPlanId == planId) {
                return p;
            }
        }
        return type(uint256).max;
    }

    function _planByCorpusId(bytes32 planId) private view returns (RawPlan storage) {
        uint256 idx = _planIndexByCorpusId(planId);
        require(idx != type(uint256).max, "unknown corpus plan");
        return plans[idx];
    }

    function _orderByCorpusOrNull(bytes32 planId, string memory orderId) private view returns (uint256) {
        for (uint256 o = 0; o < orderCount; o++) {
            if (orders[o].planId == planId && _eq(orders[o].orderId, orderId)) {
                return o;
            }
        }
        return type(uint256).max;
    }

    function _orderByCorpus(bytes32 planId, string memory orderId) private view returns (OrderRow storage) {
        uint256 idx = _orderByCorpusOrNull(planId, orderId);
        require(idx != type(uint256).max, "unknown corpus order");
        return orders[idx];
    }

    function _signalByKey(bytes32 signalKey) private view returns (uint256) {
        for (uint256 s = 0; s < signalCount; s++) {
            if (signals[s].signalKey == signalKey) {
                return s;
            }
        }
        return type(uint256).max;
    }

    function _signalByFact(bytes32 sourceId, bytes32 signalId) private view returns (uint256) {
        for (uint256 s = 0; s < signalCount; s++) {
            if (signals[s].sourceId == sourceId && signals[s].signalId == signalId) {
                return s;
            }
        }
        return type(uint256).max;
    }

    function _isEarliestRowOfKey(uint256 rowIdx) private view returns (bool) {
        SignalRow storage sig = signals[rowIdx];
        for (uint256 s = 0; s < rowIdx; s++) {
            SignalRow storage other = signals[s];
            if (
                other.planId == sig.planId && _eq(other.orderId, sig.orderId) && other.sourceId == sig.sourceId
                    && other.signalId == sig.signalId
            ) {
                return false;
            }
        }
        return true;
    }

    function _firstSignalOf(bytes32 planId, string memory orderId) private view returns (uint256) {
        uint256 best = type(uint256).max;
        for (uint256 s = 0; s < signalCount; s++) {
            SignalRow storage sig = signals[s];
            if (sig.planId != planId || !_eq(sig.orderId, orderId)) {
                continue;
            }
            if (best == type(uint256).max || sig.submittedAt < signals[best].submittedAt) {
                best = s;
            }
        }
        return best;
    }

    function _firstSignalOnPlan(bytes32 planId) private view returns (uint256) {
        uint256 best = type(uint256).max;
        for (uint256 s = 0; s < signalCount; s++) {
            if (signals[s].planId != planId) {
                continue;
            }
            if (best == type(uint256).max || signals[s].submittedAt < signals[best].submittedAt) {
                best = s;
            }
        }
        return best;
    }

    function _orderCountOnPlan(bytes32 planId) private view returns (uint256) {
        uint256 count;
        for (uint256 o = 0; o < orderCount; o++) {
            if (orders[o].planId == planId) {
                count += 1;
            }
        }
        return count;
    }

    function _triggeredRowOf(bytes32 planId, string memory orderId) private view returns (uint256) {
        for (uint256 t = 0; t < triggeredCount; t++) {
            if (triggeredPlanIds[t] == planId && _eq(triggeredOrderIds[t], orderId)) {
                return t;
            }
        }
        return type(uint256).max;
    }

    function _orderHasTriggeredRow(bytes32 planId, string memory orderId) private view returns (bool) {
        return _triggeredRowOf(planId, orderId) != type(uint256).max;
    }

    function _mintHookOf(RawPlan storage plan) private view returns (bytes32) {
        for (uint256 h = 0; h < plan.hooks.length; h++) {
            if (plan.hooks[h].flags & FLAG_ORDER_TRIGGER_MINT != 0) {
                return plan.hooks[h].hookId;
            }
        }
        revert("plan has no mint hook");
    }

    function _dockHookOf(RawPlan storage plan) private view returns (RawHook storage) {
        for (uint256 h = 0; h < plan.hooks.length; h++) {
            if (plan.hooks[h].flags & FLAG_ORDER_TRIGGER_DOCK != 0) {
                return plan.hooks[h];
            }
        }
        revert("plan has no dock hook");
    }

    function _hookStage(RawPlan storage plan, bytes32 hookId) private view returns (bytes32) {
        for (uint256 h = 0; h < plan.hooks.length; h++) {
            if (plan.hooks[h].hookId == hookId) {
                return plan.hooks[h].stageId;
            }
        }
        revert("unknown hook");
    }

    function _statusOf(string memory status) private pure returns (UVPStateMachine.HookStatus) {
        bytes32 hash = keccak256(bytes(status));
        if (hash == keccak256("init")) {
            return UVPStateMachine.HookStatus.Init;
        }
        if (hash == keccak256("wait")) {
            return UVPStateMachine.HookStatus.Wait;
        }
        if (hash == keccak256("ready")) {
            return UVPStateMachine.HookStatus.Ready;
        }
        if (hash == keccak256("cxl")) {
            return UVPStateMachine.HookStatus.Cancelled;
        }
        revert("unknown corpus hook status");
    }

    function _splitOrderKey(string memory orderKey) private pure returns (bytes32 planId, string memory orderId) {
        bytes memory b = bytes(orderKey);
        uint256 sep;
        bool found;
        for (uint256 i = 0; i + 1 < b.length; i++) {
            if (b[i] == ":" && b[i + 1] == ":") {
                sep = i;
                found = true;
                break;
            }
        }
        require(found, "corpus orderKey separator");
        bytes memory hexPart = new bytes(sep);
        for (uint256 i = 0; i < sep; i++) {
            hexPart[i] = b[i];
        }
        bytes memory idPart = new bytes(b.length - sep - 2);
        for (uint256 i = 0; i < idPart.length; i++) {
            idPart[i] = b[sep + 2 + i];
        }
        return (_hexToBytes32(string(hexPart)), string(idPart));
    }

    function _hexToBytes32(string memory hexStr) private pure returns (bytes32) {
        bytes memory b = bytes(hexStr);
        require(b.length == 66 && b[0] == "0" && b[1] == "x", "corpus hex word");
        bytes32 result;
        for (uint256 i = 2; i < 66; i += 2) {
            result = (result << 8) | bytes32(uint256(_hexNibble(b[i])) << 4 | uint256(_hexNibble(b[i + 1])));
        }
        return result;
    }

    function _hexNibble(bytes1 char) private pure returns (uint8) {
        uint8 value = uint8(char);
        if (value >= 48 && value <= 57) {
            return value - 48;
        }
        if (value >= 97 && value <= 102) {
            return value - 87;
        }
        revert("corpus hex nibble");
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 buffer = value;
        uint256 digits;
        while (buffer != 0) {
            digits++;
            buffer /= 10;
        }
        bytes memory result = new bytes(digits);
        uint256 index = digits;
        buffer = value;
        while (buffer != 0) {
            index--;
            result[index] = bytes1(uint8(48 + (buffer % 10)));
            buffer /= 10;
        }
        return string(result);
    }
}
