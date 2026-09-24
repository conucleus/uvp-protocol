// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function addr(uint256 privateKey) external returns (address keyAddr);
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address msgSender) external;
    function recordLogs() external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

/// 整批原子性载体：一笔交易内连续两发射——第二个发射不适格时整笔回滚
/// （EVM 原生原子性，接受为设计，spec §3.4）。
contract BatchSubmitter {
    function submitTwo(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        bytes32 firstSourceId,
        bytes32 firstSignalId,
        bytes32 secondSourceId,
        bytes32 secondSignalId
    ) external {
        machine.submitSignal(
            planId, orderId, firstSourceId, firstSignalId, bytes32(uint256(0x8001)), bytes32(uint256(0x9001)),
            UVPStateMachine.FactAttribution({
                sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
            }),
            UVPStateMachine.SelectorBindingProof({selectorStageId: bytes32(0), proof: new bytes32[](0)})
        );
        machine.submitSignal(
            planId, orderId, secondSourceId, secondSignalId, bytes32(uint256(0x8002)), bytes32(uint256(0x9002)),
            UVPStateMachine.FactAttribution({
                sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
            }),
            UVPStateMachine.SelectorBindingProof({selectorStageId: bytes32(0), proof: new bytes32[](0)})
        );
    }
}

/// 发射适格面（admission，CompactHook flag=8）测试：注册门（_validateAdmission
/// 过滤档）、提交卡点三态、窗口边界、幂等吸收、内部生产者豁免与 gas 钉。
/// 每个测试断言一条语义规则；基建镜像 UVPStateMachine.t.sol 的最小子集。
contract UVPAdmissionTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_uint(string key, uint256 val);

    mapping(address machine => UVPDockingModule docking) private _dockingModules;

    bytes32 private constant SOURCE_BOOTSTRAP = bytes32(uint256(0x3001));
    bytes32 private constant SIGNAL_ORDER_START = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_TRIGGER = bytes32(uint256(0x4002));
    /// 适格表达式的正锚信号（在案即放行腿）。
    bytes32 private constant SIGNAL_ANCHOR = bytes32(uint256(0x4008));
    /// 适格表达式的否决信号（在案 + 窗口内即拒绝腿）。
    bytes32 private constant SIGNAL_CANCEL = bytes32(uint256(0x4009));
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant HOOK_ORDER_START = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_INIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_NAME_TRIGGER = bytes32(uint256(0x7001));
    bytes32 private constant HOOK_NAME_ORDER_START = bytes32(uint256(0x7005));
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant ROLE_BOOTSTRAP = bytes32(uint256(0xa001));
    bytes32 private constant AUTH_METADATA_HASH = bytes32(uint256(0xa002));
    address private constant ORDER_CREATOR = address(uint160(0xc0de));
    uint256 private constant SUBMITTER_PRIVATE_KEY = 0xa11ce;
    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.12");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_ADMISSION = 8;
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");

    bytes32 private PLAN_ID;
    bytes32 private ORDER_ID;

    // ------------------------------------------------------------------
    // 注册门
    // ------------------------------------------------------------------

    /// 合法适格面注册：hook 档同形的 anchor & ~(cancel+5s) 以 flag=8 槽位
    /// 进 plan.admissions，plan 注册成功。
    function testValidAdmissionPlanRegisters() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _admissionPlan(5, true));
        require(machine.planExists(planId), "admission plan not registered");
    }

    /// 过滤档放行钩子档非法形态之一：裸衰减根（hook 档在根位双闸拒绝，
    /// 适格一拍求值下任何位置的瞬时值都良定义）。
    function testBareDecayingRootAdmissionRegisters() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_CANCEL);
        instructions[1] = _delay(5);
        instructions[2] = _not();

        bytes32 planId = _registerPlan(machine, _withOrderStart(_admissionOnly(instructions)));
        require(machine.planExists(planId), "bare decaying root plan not registered");
    }

    /// 过滤档放行钩子档非法形态之二：Or 分支下的衰减否决位。
    function testDecayingVetoUnderOrAdmissionRegisters() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _or(2);

        bytes32 planId = _registerPlan(machine, _withOrderStart(_admissionOnly(instructions)));
        require(machine.planExists(planId), "veto-under-or plan not registered");
    }

    /// 过滤档放行钩子档非法形态之三：延时操作数内的否决位（hook 档拒绝
    /// ——否决位会衰减而延时成熟是永久的；适格无调度不构成该风险）。
    function testDecayingVetoInsideDelayOperandAdmissionRegisters() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](6);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _and(2);
        instructions[5] = _delay(10);

        bytes32 planId = _registerPlan(machine, _withOrderStart(_admissionOnly(instructions)));
        require(machine.planExists(planId), "veto-inside-delay plan not registered");
    }

    /// 过滤档保留闸：NOT 操作数词表（裸 SIGNAL 或 DELAY 产出）——双重
    /// 否定的第二层 NOT 吃组合操作数，注册边界拒绝。
    function testDoubleNegationAdmissionIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_CANCEL);
        instructions[1] = _delay(5);
        instructions[2] = _not();
        instructions[3] = _not();

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitOnly(machine, _withOrderStart(_admissionOnly(instructions)));
    }

    /// 过滤档保留闸：延时界限 (0, 30d]——零时长与超上限都在注册边界拒绝。
    function testAdmissionDelayBoundsAreRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory zero = new UVPStateMachine.Instruction[](2);
        zero[0] = _signal(SIGNAL_CANCEL);
        zero[1] = _delay(0);
        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitOnly(machine, _withOrderStart(_admissionOnly(zero)));

        UVPStateMachine.Instruction[] memory over = new UVPStateMachine.Instruction[](2);
        over[0] = _signal(SIGNAL_CANCEL);
        over[1] = _delay(30 days + 1 seconds);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.HookDelayTooLong.selector, 30 days + 1 seconds));
        _commitOnly(machine, _withOrderStart(_admissionOnly(over)));
    }

    /// 过滤档保留闸：结束栈上恰一值（多结果拒绝）。
    function testAdmissionRootNotSingleIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory two = new UVPStateMachine.Instruction[](2);
        two[0] = _signal(SIGNAL_ANCHOR);
        two[1] = _signal(SIGNAL_CANCEL);
        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitOnly(machine, _withOrderStart(_admissionOnly(two)));
    }

    /// 过滤档保留闸：dependencyKeys 与 SIGNAL 原子键逐点一致（多声明的
    /// 死索引键与缺声明的键同样拒绝）。
    function testAdmissionDependencyKeyMismatchIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _and(2);

        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_admissionOnly(instructions));
        hooks[1].dependencyKeys = _deps3(SIGNAL_ANCHOR, SIGNAL_CANCEL, SIGNAL_TRIGGER);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.HookDependencyKeyMismatch.selector, hooks[1].hookId));
        _commitOnly(machine, hooks);
    }

    /// chimera flags 拒绝：适格位与出生/就绪位共用一个 word 会让同一槽位
    /// 同时寻址 hooks 与 admissions 两个人口。
    function testAdmissionChimeraFlagsAreRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_ANCHOR);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _admissionHook(SIGNAL_TRIGGER, instructions);
        hooks[1].flags = uint8(FLAG_ADMISSION | FLAG_EMIT_READY);

        vm.expectRevert(UVPStateMachine.InvalidHook.selector);
        _commitOnly(machine, hooks);
    }

    /// 同一 (stageId, signalKey) 适格面重复声明：注册边界拒绝（编译器
    /// D031 的链上镜像）。
    function testDuplicateAdmissionIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _and(2);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _admissionHook(SIGNAL_TRIGGER, instructions);
        hooks[2] = _admissionHook(SIGNAL_TRIGGER, instructions);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.AdmissionAlreadyRegistered.selector, hooks[1].hookId)
        );
        _commitOnly(machine, hooks);
    }

    /// 仅适格、无物化 hook 的阶段不可注册：适格挂在永不物化的阶段上是
    /// 死承诺（阶段物化扫描对 flag=8 槽位一视同仁）。
    function testAdmissionOnlyStageIsRejectedAsNotMaterializable() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_ANCHOR);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] =
            _signalHook(HOOK_ORDER_START, bytes32(uint256(0x5f01)), HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _admissionHook(SIGNAL_TRIGGER, instructions);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.StageNotMaterializable.selector, STAGE_INIT));
        _commitOnly(machine, hooks);
    }

    // ------------------------------------------------------------------
    // 提交卡点
    // ------------------------------------------------------------------

    /// 适格三态之 Ready：事实落库 + 依赖钩子照常求值（watcher 走到 Ready）。
    function testAdmittedSignalRecordsFactAndRunsHooks() public {
        UVPStateMachine machine = _gatedMachine(5);
        vm.warp(100);

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (bool exists,,,, ) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(exists, "admitted fact missing");
        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "dependent hook not ready");
        require(readyEmitted, "ready marker missing");
    }

    /// 适格三态之非 Ready（NeedsMore：正锚缺席）：类型化 revert，事实流
    /// 零落库、钩子零推进、零事件。
    function testNonReadyAdmissionRevertsAndRecordsNothing() public {
        UVPStateMachine machine = _gatedMachine(5);
        vm.warp(100);

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (bool exists,,,, ) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(!exists, "rejected emission must not record a fact");
        (UVPStateMachine.HookStatus status,, ) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Init, "rejected emission must not advance hooks");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(
            _countTopic(logs, keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)")) == 0,
            "rejected emission emitted events"
        );
    }

    /// 窗口边界：恰到期（block.timestamp == dueAt）延时成熟 → NOT 翻转
    /// cancel → 拒绝；前一秒仍放行（严格 < 边界镜像 _delayValue）。两腿各
    /// 用独立订单——首腿放行即落库，重复提交会先进幂等吸收、测不到适格。
    function testWindowBoundaryExactlyAtExpiryRejects() public {
        UVPStateMachine before = _gatedMachine(5);
        vm.warp(100);
        before.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        before.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_CANCEL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        vm.warp(104);
        before.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        UVPStateMachine atExpiry = _gatedMachine(5);
        vm.warp(100);
        atExpiry.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        atExpiry.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_CANCEL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        vm.warp(105);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        atExpiry.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
    }

    /// 幂等吸收先于适格：已落库的重复提交在窗口过期后重试不 revert、
    /// 不再过适格（at-least-once 重试不得被过期窗拒绝）。
    function testDuplicateAbsorbsAfterWindowExpiry() public {
        UVPStateMachine machine = _gatedMachine(5);
        vm.warp(100);

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_CANCEL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        vm.warp(1000);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, bytes32(uint256(0x8004)), IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (, bytes32 payloadHash,,, ) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(payloadHash == PAYLOAD_HASH, "absorbed retry overwrote the first write");
    }

    /// 内部生产者（dock output 镜像通道）不经适格面：目标信号声明了会
    /// 拒绝的适格，模块写入照常落库。
    function testInternalProducerBypassesAdmission() public {
        UVPStateMachine machine = _gatedMachine(5);
        vm.warp(100);

        vm.prank(address(_dockingModules[address(machine)]));
        machine.submitSignalFromModule(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this),
            _noAttribution(), _noBinding()
        );

        (bool exists,,,, ) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(exists, "internal producer write missing");
    }

    /// 无单外部出生过筛：出生事实自身的适格在空 pre-state 上裁决——正
    /// 锚缺席即拒绝，封死「gated 信号绕窗铸单」的口子。
    function testOutsideBirthIsScreenedByAdmission() public {
        UVPStateMachine machine = _newMachine();

        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, false, SIGNAL_TRIGGER);
        hooks[2] = _admissionHook(SIGNAL_ORDER_START, instructions);
        bytes32 planId = _registerPlan(machine, hooks);
        PLAN_ID = planId;

        UVPStateMachine.SignalAuthorization[] memory authorizations = _authorizationsFor(address(this), address(0));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTriggerRequest();
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START)
        );
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _noAttribution());
    }

    /// 整批原子性：一笔交易多发射，一个不适格整批回滚——先落库的合格
    /// 发射也一并消失。
    function testMultiSignalTxWithIneligibleEmissionRevertsEntirely() public {
        BatchSubmitter submitter = new BatchSubmitter();
        UVPStateMachine machine = _gatedMachineFor(5, address(submitter), false);
        vm.warp(100);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.SignalAdmissionRejected.selector, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        submitter.submitTwo(
            machine, PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_CANCEL, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
        );

        (bool cancelRecorded,,,, ) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_CANCEL);
        require(!cancelRecorded, "atomic rollback must erase the earlier eligible emission");
    }

    // ------------------------------------------------------------------
    // gas 钉
    // ------------------------------------------------------------------

    /// 无适格面的 plan：提交成本增量有界（≤ 常数预算）——增量构成是幂等
    /// 吸收检查的一次 signalKey 派生 + 信号槽/订单布尔槽的暖读，全部
    /// O(1)、不随 plan 形态缩放。基线 128_082 是适格面引入前同形态提交
    /// 路径的实测值（实测增量 1_024）。
    function testNoAdmissionPlanSubmitCostDeltaIsBounded() public {
        UVPStateMachine machine = _plainMachine();

        vm.warp(100);
        uint256 gasBefore = gasleft();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        uint256 spent = gasBefore - gasleft();

        require(spent <= 128_082 + 1_500, "no-admission submit overhead exceeds the constant budget");
    }

    /// 带适格面的提交成本是常数增量（适格存储冷读 + 指令分派）且不随
    /// 窗口时长缩放（镜像衰减负门 gas 先例的钉法：5s 与 1h 求值路径逐
    /// 指令相同）。两侧机器同形（mint-trigger watcher，普通提交不推进）
    /// 且先落同一锚事实，暖冷读基线一致。
    function testAdmissionSubmitGasIsConstantIncrement() public {
        UVPStateMachine plain = _plainMachine();
        vm.warp(100);
        plain.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        uint256 gasBefore = gasleft();
        plain.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        uint256 plainSpent = gasBefore - gasleft();

        UVPStateMachine machine = _gatedTriggerMachine(5);
        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        gasBefore = gasleft();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        uint256 admissionSpent = gasBefore - gasleft();

        UVPStateMachine machineHour = _gatedTriggerMachine(1 hours);
        vm.warp(100);
        machineHour.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ANCHOR, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        gasBefore = gasleft();
        machineHour.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        uint256 hourSpent = gasBefore - gasleft();

        require(admissionSpent > plainSpent, "admission face must cost more than the ungated path");
        // 增量构成：适格槽一次冷读 + 逐指令的存储读取（本形态 5 条指令，
        // 实测 13_683）——随指令数线性、不随窗口时长/plan 规模缩放。
        require(admissionSpent - plainSpent <= 15_000, "admission submit delta exceeds the constant budget");
        uint256 durationWobble = admissionSpent > hourSpent ? admissionSpent - hourSpent : hourSpent - admissionSpent;
        require(durationWobble <= 100, "admission gas must not scale with the window duration");
    }

    // ------------------------------------------------------------------
    // 基建
    // ------------------------------------------------------------------

    function _newMachine() private returns (UVPStateMachine machine) {
        machine = new UVPStateMachine();
        UVPStagePatchModule stagePatch = new UVPStagePatchModule(address(machine));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(machine));
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(machine));
        UVPDockingModule docking = new UVPDockingModule(address(machine), address(planMetadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(machine));
        _dockingModules[address(machine)] = docking;
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(derivedSignal));
        machine.setDockingModule(address(docking));
        machine.setPlanMetadataModule(address(planMetadata));
        machine.setOrderLinkModule(address(orderLink));
        machine.setLens(address(0x1234));
        machine.freezeModules();
    }

    /// 带适格面的已注册机（出生单已开；HOOK_INIT 是 EMIT_READY watcher，
    /// 提交语义测试借它断言"钩子照常求值"）。SIGNAL_TRIGGER 的适格 =
    /// 正锚在案 且 否决信号缺席/未熟（窗口 delaySeconds）。
    function _gatedMachine(uint64 delaySeconds) private returns (UVPStateMachine machine) {
        return _gatedMachineFor(delaySeconds, address(0), false);
    }

    /// gas 对照用的同形适格机（mint-trigger watcher，普通提交不推进）。
    function _gatedTriggerMachine(uint64 delaySeconds) private returns (UVPStateMachine machine) {
        return _gatedMachineFor(delaySeconds, address(0), true);
    }

    function _gatedMachineFor(uint64 delaySeconds, address extraSubmitter, bool watcherIsTrigger)
        private
        returns (UVPStateMachine machine)
    {
        machine = _newMachine();
        _registerPlan(machine, _admissionPlan(delaySeconds, watcherIsTrigger));
        _submitTriggerOrderFromOutside(machine, extraSubmitter);
    }

    /// 无适格对照机（gas 基线用；HOOK_INIT 与基线同形——mint trigger，
    /// 普通提交不推进它）。
    function _plainMachine() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlan(machine, _basePlan(true));
        _submitTriggerOrderFromOutside(machine, address(0));
    }

    /// 出生单 + SIGNAL_TRIGGER watcher + 适格面（anchor & ~(cancel+delay)）。
    function _admissionPlan(uint64 delaySeconds, bool watcherIsTrigger)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_ANCHOR);
        instructions[1] = _signal(SIGNAL_CANCEL);
        instructions[2] = _delay(delaySeconds);
        instructions[3] = _not();
        instructions[4] = _and(2);

        UVPStateMachine.CompactHook[] memory base = _basePlan(watcherIsTrigger);
        hooks = new UVPStateMachine.CompactHook[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            hooks[i] = base[i];
        }
        hooks[base.length] = _admissionHook(SIGNAL_TRIGGER, instructions);
    }

    /// 出生单 + SIGNAL_TRIGGER 槽（watcher 形态可切换）。
    function _basePlan(bool watcherIsTrigger)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, watcherIsTrigger, SIGNAL_TRIGGER);
    }

    /// 单条适格槽（挂在 SIGNAL_TRIGGER 的事实键上），调用方自行前置
    /// 出生单（_withOrderStart）。
    function _admissionOnly(UVPStateMachine.Instruction[] memory instructions)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _admissionHook(SIGNAL_TRIGGER, instructions);
    }

    /// 适格槽构造：hookId = signalKey（提交路径按事实键寻址），hookName
    /// 槽 = signalId（word 布局的信号身份位）。
    function _admissionHook(bytes32 signalId, UVPStateMachine.Instruction[] memory instructions)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        return UVPStateMachine.CompactHook({
            hookId: keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId)),
            stageId: STAGE_INIT,
            hookName: keccak256(abi.encode(signalId)),
            flags: FLAG_ADMISSION,
            instructions: instructions,
            dependencyKeys: _declaredKeys(instructions)
        });
    }

    /// dependencyKeys = 指令集 SIGNAL 原子键（注册门对拍口径）。
    function _declaredKeys(UVPStateMachine.Instruction[] memory instructions)
        private
        pure
        returns (bytes32[] memory keys)
    {
        bytes32[] memory scratch = new bytes32[](instructions.length);
        uint256 count;
        for (uint256 i = 0; i < instructions.length; i++) {
            if (instructions[i].op != uint8(UVPStateMachine.InstructionOp.Signal)) {
                continue;
            }
            bytes32 key = keccak256(abi.encode(instructions[i].sourceId, instructions[i].signalId));
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
        keys = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            keys[i] = scratch[i];
        }
    }

    function _withOrderStart(UVPStateMachine.CompactHook[] memory tail)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory wrapped)
    {
        wrapped = new UVPStateMachine.CompactHook[](tail.length + 1);
        wrapped[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        for (uint256 i = 0; i < tail.length; i++) {
            wrapped[i + 1] = tail[i];
        }
    }

    function _signalHook(bytes32 hookId, bytes32 stageId, bytes32 hookName, bool isTrigger, bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(signalId);
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: hookName,
            flags: isTrigger ? uint8(FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY) : FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: _deps(signalId)
        });
    }

    function _signal(bytes32 signalId) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE_BOOTSTRAP,
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

    function _deps(bytes32 signalId) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId));
    }

    function _deps3(bytes32 a, bytes32 b, bytes32 c) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](3);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, a));
        deps[1] = keccak256(abi.encode(SOURCE_BOOTSTRAP, b));
        deps[2] = keccak256(abi.encode(SOURCE_BOOTSTRAP, c));
    }

    function _registerPlan(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (bytes32 planId)
    {
        address publisher = vm.addr(PUBLISHER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: EMPTY_DOCK_ROOT,
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            deadline: block.timestamp + 1 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.capabilitiesRoot,
                commit.dockRoutesRoot,
                commit.dockInterfaceRoot,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        planId = machine.commitPlan(commit, hooks, _packedSignature(v, r, s));
        machine.finalizePlan(planId);
        PLAN_ID = planId;
    }

    /// 只跑 commitPlan（注册面负例用）：拒绝面在 commit 边界即止，不触发
    /// finalizePlan 对零值 planId 的二次报错。
    function _commitOnly(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks) private {
        address publisher = vm.addr(PUBLISHER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: EMPTY_DOCK_ROOT,
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            deadline: block.timestamp + 1 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.capabilitiesRoot,
                commit.dockRoutesRoot,
                commit.dockInterfaceRoot,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        machine.commitPlan(commit, hooks, _packedSignature(v, r, s));
    }

    function _submitTriggerOrderFromOutside(UVPStateMachine machine, address extraSubmitter) private {
        UVPStateMachine.SignalAuthorization[] memory authorizations = _authorizationsFor(address(this), extraSubmitter);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTriggerRequest();
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _noAttribution());
    }

    function _outsideTriggerRequest() private returns (UVPStateMachine.TriggerOrderFromOutsideRequest memory) {
        ORDER_ID = bytes32(
            uint256(keccak256(abi.encode(PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH)))
                & ~uint256(1 << 255)
        );
        return UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: PLAN_ID,
            creator: ORDER_CREATOR,
            triggerHookId: HOOK_ORDER_START,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: block.timestamp + 1 hours
        });
    }

    /// 出生授权覆盖本文件全部可提交信号（出生事实/触发/锚/否决）；零地址
    /// 的 extraSubmitter 跳过（不产生重复授权条目）。
    function _authorizationsFor(address submitter, address extra)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        bytes32[4] memory signalIds = [SIGNAL_ORDER_START, SIGNAL_TRIGGER, SIGNAL_ANCHOR, SIGNAL_CANCEL];
        uint256 perSubmitter = 4;
        uint256 count = extra == address(0) ? perSubmitter : perSubmitter * 2;
        authorizations = new UVPStateMachine.SignalAuthorization[](count);
        for (uint256 i = 0; i < perSubmitter; i++) {
            authorizations[i] = _authorization(signalIds[i], submitter);
        }
        if (extra != address(0)) {
            for (uint256 i = 0; i < perSubmitter; i++) {
                authorizations[perSubmitter + i] = _authorization(signalIds[i], extra);
            }
        }
    }

    function _authorization(bytes32 signalId, address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization memory)
    {
        return UVPStateMachine.SignalAuthorization({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: signalId,
            submitter: submitter,
            role: ROLE_BOOTSTRAP,
            metadataHash: AUTH_METADATA_HASH
        });
    }

    function _triggerOrderFromOutsideSignature(
        UVPStateMachine machine,
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory authorizations,
        uint256 submitterPrivateKey
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(submitterPrivateKey, digest);
        return _packedSignature(v, r, s);
    }

    function _stateMachineDomainSeparator(UVPStateMachine machine) private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, STATE_MACHINE_NAME_HASH, STATE_MACHINE_VERSION_HASH, block.chainid, address(machine))
        );
    }

    function _packedSignature(uint8 v, bytes32 r, bytes32 s) private pure returns (bytes memory) {
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0),
            signalId: bytes32(0),
            stageId: bytes32(0),
            capabilityProof: new bytes32[](0)
        });
    }

    function _noBinding() private pure returns (UVPStateMachine.SelectorBindingProof memory) {
        return UVPStateMachine.SelectorBindingProof({selectorStageId: bytes32(0), proof: new bytes32[](0)});
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count += 1;
            }
        }
    }
}
