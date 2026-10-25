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

contract SemanticsReplayCorpusTest {
    CorpusVm private constant vm = CorpusVm(address(uint160(uint256(keccak256("hevm cheat code")))));

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

    struct RawInstr {
        uint8 op;
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
        uint8 flags;
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
        bytes32 birthHookId;
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

    function testReplayCorpusCaseCountIsPinned() public {
        _loadCorpus();
        for (uint256 i = 0; i < REPLAY_CASE_COUNT; i++) {
            (bool ok,) = _tryString(corpusJson, _casePath(i, ".name"));
            require(ok, "replay corpus case missing");
        }
        (bool beyond,) = _tryString(corpusJson, _casePath(REPLAY_CASE_COUNT, ".name"));
        require(!beyond, "replay corpus grew; extend the per-case entrypoints");
    }

    function _runReplayCase(uint256 caseIdx) private {
        _loadCorpus();
        _resetCase();
        string memory json = corpusJson;

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

        for (uint256 i = 0; i < eventCount; i++) {
            _absorbEvent(caseIdx, i);
        }
        require(planCount > 0, "corpus case has no plans");
        (bool hasMismatchReason, string memory mismatchReason) =
            _tryString(json, _casePath(caseIdx, ".expect.mismatchDetails[0].reason"));
        if (hasMismatchReason) {
            mismatchReasonHash = keccak256(bytes(mismatchReason));
        }

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
                    _birthOrderLink(caseIdx, orderIdx);
                    order.born = true;
                } else if (plan.hasDock) {
                    _birthDockOrder(caseIdx, orderIdx, firstSignal);
                    order.born = true;
                } else if (!_birthOutside(caseIdx, orderIdx)) {
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
                    continue;
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

        CorpusVm.Log[] memory logs = vm.getRecordedLogs();
        if (gateBlocked) {
            require(mismatchReasonHash == 0, "gate-blocked corpus case is not a poison-stream case");
        } else if (mismatchReasonHash == keccak256("missing-observed")) {
            _assertDockBirthAtomic(logs);
        } else {
            (bool hasErrorContains,) = _tryString(json, _casePath(caseIdx, ".expect.errorContains"));
            if (!hasErrorContains) {
                _assertObservableFace(caseIdx, logs);
            }
            _assertWaitDueAt(caseIdx, logs);
            _assertFinalHookStatuses(caseIdx);
            _assertStateOrderKeys(caseIdx);
        }
        _assertFirstWriteStays();
    }

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
            cursor += 1;
        }
        if (variant) {
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

    function _birthOutside(uint256 caseIdx, uint256 orderIdx) private returns (bool) {
        OrderRow storage order = orders[orderIdx];
        RawPlan storage plan = _planByCorpusId(order.planId);
        bytes32 triggerHookId = plan.hasMint ? _mintHookOf(plan) : plan.birthHookId;
        bytes32 triggerStageId = plan.hasMint ? _hookStage(plan, _mintHookOf(plan)) : plan.birthStageId;
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

    function _replayPoke(uint256 pokeIdx) private {
        PokeRow storage poke = pokes[pokeIdx];
        OrderRow storage order = _orderByCorpus(poke.planId, poke.orderId);
        if (poke.hasPokedAt) {
            vm.warp(poke.pokedAt);
            machine.pokeTimer(order.chainPlanId, order.chainOrderId, poke.hookId);
            return;
        }
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
            return;
        }
        sig.written = true;
    }

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

    function _assertFirstWriteStays() private {
        for (uint256 s = 0; s < signalCount; s++) {
            SignalRow storage sig = signals[s];
            if (!sig.written) {
                continue;
            }
            if (!_isEarliestRowOfKey(s)) {
                continue;
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

    bytes32 private constant FILTER_FORM_A =
        keccak256("buyer::execute.locked & ~(execute.approved +5s) & ~execute.confirm_transfer");
    bytes32 private constant FILTER_FORM_B = keccak256("buyer::(~a.cmp)+5s");
    bytes32 private constant FILTER_FORM_C = keccak256("buyer::(~a.cmp | b.cmp)+5s");
    bytes32 private constant FILTER_FORM_D = keccak256("buyer::(~a.cmp | ~b.cmp)+5s");
    bytes32 private constant FILTER_FORM_E =
        keccak256("buyer::execute.locked & ~(execute.approved +5s) & ~(execute.reviewed +10s)");

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
            admissionInstrs = new UVPStateMachine.Instruction[](3);
            admissionInstrs[0] = _instruction(
                uint8(UVPStateMachine.InstructionOp.Signal), _filterSource(), _filterSignal("a.cmp"), 0, 0
            );
            admissionInstrs[1] = _instruction(uint8(UVPStateMachine.InstructionOp.Not), bytes32(0), bytes32(0), 0, 0);
            admissionInstrs[2] = _instruction(uint8(UVPStateMachine.InstructionOp.Delay), bytes32(0), bytes32(0), 0, 5);
            _expectAdmissionCommitRevert(admissionInstrs, birthSource, birthSignal, emitSource, emitSignal, birthStage);
            return;
        } else if (form == FILTER_FORM_D) {
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

    function _loadCorpus() private {
        if (bytes(corpusJson).length != 0) {
            return;
        }
        corpusJson = vm.readFile(string.concat(vm.projectRoot(), "/../../../uvp-core/fixtures/hook/semantics.v1.json"));
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
