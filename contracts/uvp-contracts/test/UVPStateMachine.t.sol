// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "../src/interfaces/IUVPPlanMetadataModule.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";

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
    function pauseGasMetering() external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function resumeGasMetering() external;
    function warp(uint256 newTimestamp) external;
}

contract UVPStateMachineTest {
    // 能力树测试登记表用的叶子描述类型（IUVPPlanMetadataModule 上无此
    // 结构体——测试本地镜像字段布局）。
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

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_uint(string key, uint256 val);

    mapping(address => UVPStagePatchModule) private _stagePatchModules;
    mapping(address => UVPDerivedSignalModule) private _derivedSignalModules;
    mapping(address => UVPDockingModule) private _dockingModules;
    mapping(address => UVPPlanMetadataModule) private _planMetadataModules;
    mapping(address => UVPOrderLinkModule) private _orderLinkModules;
    bytes32 private PLAN_ID;

    // 一事一单：outside 触发订单 id 由合约派生，测试在触发时刷新 ORDER_ID；
    // order-link 派生单 id 同理由合约派生，测试在建立链接时刷新
    // LINKED_ORDER_ID（0300 H-1：orderId 不可自报）。
    bytes32 private ORDER_ID;
    bytes32 private LINKED_ORDER_ID;
    bytes32 private constant SOURCE_BOOTSTRAP = bytes32(uint256(0x3001));
    bytes32 private constant SIGNAL_ORDER_START = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_TRIGGER = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_INIT_CMP = bytes32(uint256(0x4002));
    bytes32 private constant SIGNAL_AUDIT_PASS = bytes32(uint256(0x4003));
    bytes32 private constant SIGNAL_VERIFY_FAIL = bytes32(uint256(0x4004));
    bytes32 private constant SIGNAL_STAGE_DONE = bytes32(uint256(0x4005));
    bytes32 private constant SIGNAL_STAGE_REVIEW = bytes32(uint256(0x4006));
    /// 词表外的回退事实键（sourceId==stageId、无 capability 声明）——
    /// _recordSignal 的 source==stage 回退归属用它落事实。
    bytes32 private constant SIGNAL_FALLBACK = bytes32(uint256(0x4010));
    /// 另一条出生线的事实（§7.2 出生锚订单归属测试用）。
    bytes32 private constant SIGNAL_ALT_BIRTH = bytes32(uint256(0x4007));
    bytes32 private constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;
    bytes32 private constant RESOURCE_PATCH_SIGNAL_ID =
        0x6dff331f2bb7b785cbcd99a911e6d30dc8714f43b3b9ba80c658215445ddd0ba;
    bytes32 private constant DOCKED_ORDER_LINK_SIGNAL_ID = keccak256("uvp.docked_order_link.v1");
    bytes32 private constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");
    bytes32 private constant EXECUTOR_PATCH_MODE_HANDOFF = bytes32("handoff");
    bytes32 private constant EXECUTOR_PATCH_MODE_REPLACEMENT = bytes32("replacement");
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_AUDIT = bytes32(uint256(0x5002));
    bytes32 private constant STAGE_ROLLBACK = bytes32(uint256(0x5003));
    /// 另一条出生线的出生阶段（§7.2 出生锚订单归属测试用）。
    bytes32 private constant STAGE_ALT = bytes32(uint256(0x5004));
    // Production compiler artifacts intentionally keep stage identity and
    // business source identity in separate hash domains.
    bytes32 private constant PRODUCTION_SOURCE = keccak256("payment");
    bytes32 private constant PRODUCTION_SIGNAL = keccak256("payment.ready");
    bytes32 private constant HOOK_ORDER_START = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_INIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_AUDIT = bytes32(uint256(0x6002));
    bytes32 private constant HOOK_TIMEOUT = bytes32(uint256(0x6003));
    bytes32 private constant HOOK_ROLLBACK = bytes32(uint256(0x6004));
    bytes32 private constant HOOK_NON_TRIGGER = bytes32(uint256(0x6005));
    /// 另一条出生线的 mint 钩子（§7.2 出生锚订单归属测试用）。
    bytes32 private constant HOOK_ALT_MINT = bytes32(uint256(0x6006));
    bytes32 private constant HOOK_NAME_TRIGGER = bytes32(uint256(0x7001));
    bytes32 private constant HOOK_NAME_INIT_DONE = bytes32(uint256(0x7002));
    bytes32 private constant HOOK_NAME_TIMEOUT = bytes32(uint256(0x7003));
    bytes32 private constant HOOK_NAME_FAILURE = bytes32(uint256(0x7004));
    bytes32 private constant HOOK_NAME_ORDER_START = bytes32(uint256(0x7005));
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant ROLE_BOOTSTRAP = bytes32(uint256(0xa001));
    bytes32 private constant AUTH_METADATA_HASH = bytes32(uint256(0xa002));
    bytes32 private constant ROLE_EXECUTOR = bytes32(uint256(0xa003));
    bytes32 private constant EXECUTOR_METADATA_HASH = bytes32(uint256(0xa004));
    bytes32 private constant PATCH_HASH = bytes32(uint256(0xa006));
    bytes32 private constant PATCH_HASH_2 = bytes32(uint256(0xa007));
    bytes32 private constant RESOURCE_KEY = bytes32(uint256(0xa008));
    bytes32 private constant RESOURCE_KEY_2 = bytes32(uint256(0xa009));
    bytes32 private constant MANIFEST_HASH = bytes32(uint256(0xa00a));
    bytes32 private constant RESOURCE_POLICY_HASH = bytes32(uint256(0xa00b));
    bytes32 private constant RESOURCE_PATCH_HASH = bytes32(uint256(0xa00c));
    bytes32 private constant RESOURCE_PATCH_HASH_2 = bytes32(uint256(0xa00d));
    address private constant SUBMITTER_A = address(uint160(0xa11ce));
    address private constant SUBMITTER_B = address(uint160(0xb0b));
    address private constant UNAUTHORIZED_SUBMITTER = address(uint160(0xbad));
    address private constant NON_OWNER = address(uint160(0xf01));
    address private constant NEW_OWNER = address(uint160(0xf02));
    address private constant ORDER_CREATOR = address(uint160(0xc0de));
    uint256 private constant SUBMITTER_PRIVATE_KEY = 0xa11ce;
    uint256 private constant WRONG_SUBMITTER_PRIVATE_KEY = 0xb0b;
    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant ATTACKER_PUBLISHER_PRIVATE_KEY = 0xdeadbeef;
    uint256 private constant ATTACKER_SUBMITTER_PRIVATE_KEY = 0xdeadfa11;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.11");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_ORDER_TRIGGER_DOCK = 2;
    uint8 private constant FLAG_EMIT_READY = 4;
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");

    mapping(address machine => bytes32 planId) private _planIds;
    UVPStateMachine private _currentMachine;
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    function testConstructorSetsOwner() public {
        UVPStateMachine machine = new UVPStateMachine();

        require(machine.owner() == address(this), "bad owner");
    }

    function testOwnerCanTransferOwnership() public {
        UVPStateMachine machine = new UVPStateMachine();

        vm.recordLogs();
        machine.transferOwnership(NEW_OWNER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.owner() == NEW_OWNER, "owner not transferred");
        require(_countTopic(logs, keccak256("OwnershipTransferred(address,address)")) == 1, "owner event count");

        vm.prank(NON_OWNER);
        vm.expectRevert(UVPStateMachine.NotOwner.selector);
        machine.transferOwnership(NON_OWNER);
    }

    function testModulesMustBeCompleteAndFrozenBeforePlanRegistration() public {
        UVPStateMachine incomplete = new UVPStateMachine();
        vm.expectRevert(UVPStateMachine.IncompleteModuleConfiguration.selector);
        incomplete.freezeModules();

        UVPStateMachine machine = _newUnfrozenMachine();
        vm.expectRevert(UVPStateMachine.ModulesNotFrozen.selector);
        _commitPlan(
            machine,
            _positiveHookPlan(HOOK_INIT, true),
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );

        bytes32 expectedModuleSetHash = machine.moduleSetHash();
        vm.recordLogs();
        machine.freezeModules();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.modulesFrozen(), "modules not frozen");
        require(machine.moduleSetHash() == expectedModuleSetHash, "module set hash changed");
        require(_countTopic(logs, keccak256("StateMachineModulesFrozen(bytes32)")) == 1, "module freeze event count");
    }

    function testFrozenModulesCannotBeReconfigured() public {
        UVPStateMachine machine = _newMachine();
        UVPStagePatchModule replacement = new UVPStagePatchModule(address(machine));

        vm.expectRevert(UVPStateMachine.ModulesFrozen.selector);
        machine.setStagePatchModule(address(replacement));

        vm.expectRevert(UVPStateMachine.ModulesAlreadyFrozen.selector);
        machine.freezeModules();
    }

    function testArbitraryRelayerCanTriggerOrder() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));

        UVPStateMachine.SignalAuthorization[] memory authorizations = _defaultAuthorizations(address(this));
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        uint256 deadline = block.timestamp + 1 hours;
        // 一事一单：orderId 由合约按事实派生，本地镜像同一公式。
        ORDER_ID = bytes32(
            uint256(keccak256(abi.encode(planId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH)))
                & ~uint256(1 << 255)
        );
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: planId,
            creator: ORDER_CREATOR,
            triggerHookId: HOOK_ORDER_START,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: submitter,
            deadline: deadline
        });
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);

        vm.prank(NON_OWNER);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
        require(machine.orderRelayer(PLAN_ID, ORDER_ID) == NON_OWNER, "relayer not recorded");
    }

    function testDuplicatePlanAndOrderStillRevert() public {
        UVPStateMachine machine = _newMachine();

        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        vm.expectRevert(UVPStateMachine.PlanAlreadyRegistered.selector);
        _commitPlan(
            machine,
            _withOrderStart(_positiveHookPlan(HOOK_INIT, true)),
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
        PLAN_ID = planId;

        _submitTriggerOrderFromOutside(machine, planId, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        UVPStateMachine.SignalAuthorization[] memory duplicateAuthorizations = _defaultAuthorizations(address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory duplicateTrigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        bytes memory duplicateSignature = _triggerOrderFromOutsideSignature(
            machine, duplicateTrigger, duplicateAuthorizations, SUBMITTER_PRIVATE_KEY
        );
        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        machine.triggerOrderFromOutsideFor(duplicateTrigger, duplicateAuthorizations, duplicateSignature, _factAttribution(machine, duplicateTrigger.planId, duplicateTrigger.sourceId, duplicateTrigger.signalId));
    }

    function testSubmittedSignalMakesHookReady() public {
        UVPStateMachine machine = _registeredMachine(_emitReadyPositiveHookPlan(HOOK_INIT));

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");
    }

    function testRegisterPlanAndOrder() public {
        UVPStateMachine machine = _newMachine();

        vm.recordLogs();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.planExists(planId), "plan not registered");
        require(machine.orderExists(PLAN_ID, ORDER_ID), "order not registered");
        // 订单身份即 (planId, orderId)，plan 归属由寻址键保证。
        require(machine.planPublisher(planId) == vm.addr(PUBLISHER_PRIVATE_KEY), "bad plan publisher");
        require(machine.orderRelayer(PLAN_ID, ORDER_ID) == address(this), "bad order relayer");
        require(machine.orderCreator(PLAN_ID, ORDER_ID) == ORDER_CREATOR, "bad order creator");
        require(_countTopic(logs, keccak256("PlanPublisherRecorded(bytes32,address)")) == 1, "publisher record count");
        require(
            _countTopic(logs, keccak256("OrderRelayerRecorded(bytes32,bytes32,address,address)")) == 1,
            "relayer record count"
        );
        require(_countSignalSubmitterAuthorized(logs) == 4, "authorization event count");
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, address(this)),
            "submitter not authorized"
        );
        require(
            !machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, SUBMITTER_A),
            "unexpected submitter auth"
        );
        (bool authExists, bytes32 role, bytes32 metadataHash) =
            machine.getSignalAuthorization(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, address(this));
        require(authExists, "authorization missing");
        require(role == ROLE_BOOTSTRAP, "bad authorization role");
        require(metadataHash == AUTH_METADATA_HASH, "bad authorization metadata");

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Init, "hook not init");
        require(dueAt == 0, "unexpected due");
        require(!readyEmitted, "unexpected ready marker");
    }

    function testRegisterPlanStoresStageSelectorBindings() public {
        UVPStateMachine machine = _newMachine();

        _registerPlan(machine, _sequentialPlan(), _selectorBindings(), _emptySignalCapabilities());

        // 绑定表 Merkle 化：绑定叶与能力叶混编进同一棵 capabilitiesRoot，
        // 存在性断言由"重算叶 + 携 proof"的 verifyStageSelectorBinding 承载。
        bytes32 bindingLeaf = keccak256(abi.encode(SELECTOR_BINDING_LEAF_DOMAIN, STAGE_INIT, STAGE_AUDIT));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = bindingLeaf;
        require(_planMetadata(machine).capabilitiesRoot(PLAN_ID) == DockMerkle.root(leaves), "bad capabilities root");
        require(_planMetadata(machine).hasCapabilityVocabulary(PLAN_ID), "vocabulary missing");
        bytes32[] memory proof =
            _merkleProofFor(_capabilityTables[address(machine)][PLAN_ID].sortedLeaves, bindingLeaf);
        require(
            _planMetadata(machine).verifyStageSelectorBinding(PLAN_ID, STAGE_INIT, STAGE_AUDIT, proof),
            "binding missing"
        );
        require(
            !_planMetadata(machine).verifyStageSelectorBinding(PLAN_ID, STAGE_AUDIT, STAGE_INIT, proof),
            "unexpected binding"
        );
    }

    function testRegisterPlanStoresSignalCapabilities() public {
        UVPStateMachine machine = _newMachine();

        _registerPlan(machine, _sequentialPlan(), _selectorBindings(), _signalCapabilities());

        // 能力表 Merkle 化：commit 即承诺全部叶子（绑定叶 + 能力叶），
        // 逐叶 verify 断言，无计数/枚举查询面。
        bytes32[] memory sortedLeaves = _capabilityTables[address(machine)][PLAN_ID].sortedLeaves;
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256(abi.encode(SELECTOR_BINDING_LEAF_DOMAIN, STAGE_INIT, STAGE_AUDIT));
        leaves[1] = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_AUDIT, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, uint256(1))
        );
        leaves[2] = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, uint256(0))
        );
        leaves[3] = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, uint256(0))
        );
        require(_planMetadata(machine).capabilitiesRoot(PLAN_ID) == DockMerkle.root(leaves), "bad capabilities root");
        require(
            _planMetadata(machine).verifySignalCapability(
                PLAN_ID, STAGE_AUDIT, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, 1, _merkleProofFor(sortedLeaves, leaves[1])
            ),
            "capability missing"
        );
        require(
            _planMetadata(machine).verifySignalCapability(
                PLAN_ID, STAGE_INIT, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, 0, _merkleProofFor(sortedLeaves, leaves[2])
            ),
            "birth capability missing"
        );
        require(
            !_planMetadata(machine).verifySignalCapability(
                PLAN_ID, STAGE_AUDIT, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, 0, _merkleProofFor(sortedLeaves, leaves[1])
            ),
            "unexpected relation"
        );
    }

    /// Merkle 形态下重复的绑定声明在建树时去重（同叶折叠）：注册边界不再
    /// 有重复拒绝，成员资格仍按唯一叶验证。
    function testRegisterPlanRejectsDuplicateStageSelectorBinding() public {
        UVPStateMachine machine = _newMachine();

        bytes32 planId =
            _registerPlan(machine, _sequentialPlan(), _duplicateSelectorBindings(), _emptySignalCapabilities());
        bytes32 bindingLeaf = keccak256(abi.encode(SELECTOR_BINDING_LEAF_DOMAIN, STAGE_INIT, STAGE_AUDIT));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = bindingLeaf;
        require(
            _planMetadata(machine).capabilitiesRoot(planId) == DockMerkle.root(leaves), "duplicate leaves must collapse"
        );
        require(
            _planMetadata(machine).verifyStageSelectorBinding(
                planId,
                STAGE_INIT,
                STAGE_AUDIT,
                _merkleProofFor(_capabilityTables[address(machine)][planId].sortedLeaves, bindingLeaf)
            ),
            "binding missing"
        );
    }

    function testTriggerOrderFromOutsideCreatesAndMaterializesOrder() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _sequentialPlan());

        vm.recordLogs();
        _submitTriggerOrderFromOutsideRequest(
            machine,
            _outsideTriggerRequest(HOOK_INIT, SIGNAL_TRIGGER),
            _auths1(SIGNAL_TRIGGER, SUBMITTER_A),
            SUBMITTER_PRIVATE_KEY
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.orderExists(PLAN_ID, ORDER_ID), "order missing");
        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "trigger signal missing");
        {
            bytes32 triggerTopic = keccak256("OrderTriggered(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)");
            uint256 triggerCount;
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].topics.length == 0 || logs[i].topics[0] != triggerTopic) {
                    continue;
                }
                triggerCount += 1;
                (bytes32 emittedTriggerHookId,,,) = abi.decode(logs[i].data, (bytes32, bytes32, bytes32, address));
                require(emittedTriggerHookId == HOOK_INIT, "trigger event missing triggerHookId");
            }
            require(triggerCount == 1, "trigger event count");
        }
        require(
            _countTopic(logs, keccak256("OrderMaterialized(bytes32,bytes32,bytes32)")) == 1, "materialized event count"
        );
    }

    function testTriggerOrderFromSignalCreatesTriggerOriginLinkAndMaterializesOrder() public {
        UVPStateMachine machine = _registeredMachine(_sequentialPlan());

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        vm.recordLogs();
        _triggerOrderFromSignalRequest(
            machine, _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))), _auths1(SIGNAL_TRIGGER, SUBMITTER_A)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (
            bool exists,
            bytes32 triggerOriginOrderId,
            bytes32 triggerOriginPlanId,
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        ) = _orderLink(machine).getTriggerOriginLink(PLAN_ID, LINKED_ORDER_ID);
        require(exists, "link missing");
        require(triggerOriginOrderId == ORDER_ID, "bad trigger origin");
        require(triggerOriginPlanId == PLAN_ID, "bad trigger origin plan");
        require(originSourceId == SOURCE_BOOTSTRAP, "bad origin source");
        require(originSignalId == SIGNAL_TRIGGER, "bad origin signal");
        require(triggerStageId == STAGE_INIT, "bad trigger stage");
        require(
            !machine.hasSignal(PLAN_ID, LINKED_ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER),
            "origin signal copied to triggered"
        );
        require(
            _countTopic(logs, keccak256("OrderLinked(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)")) == 1,
            "link event count"
        );
    }

    function testDerivedSignalUsesPlanCapabilityToWriteBackToTriggerOrigin() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _signalCapabilities());
        // 父单（target 侧）显式授权 SUBMITTER_A 提交派生事实——豁免只认
        // target 侧授权，子单出生时的 from 侧授权不参与豁免。
        UVPStateMachine.SignalAuthorization[] memory originAuths = _defaultAuthorizations(address(this));
        UVPStateMachine.SignalAuthorization[] memory originWithDerived =
            new UVPStateMachine.SignalAuthorization[](originAuths.length + 1);
        for (uint256 i = 0; i < originAuths.length; i++) {
            originWithDerived[i] = originAuths[i];
        }
        originWithDerived[originAuths.length] = _authorization(SIGNAL_VERIFY_FAIL, SUBMITTER_A);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, originWithDerived);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), _noBinding());
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest1 =
            _derivedSignalRequest( LINKED_ORDER_ID, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(3)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs1 = _derivedProofs(machine, derivedRequest1);
        vm.recordLogs();
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest1, SUBMITTER_A, derivedProofs1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL),
            "derived signal missing on trigger origin"
        );
        require(
            _countTopic(
                logs,
                keccak256(
                    "DerivedSignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)"
                )
            ) == 1,
            "derived signal event count"
        );

        // Direct derived-signal calls bind the business submitter to the
        // caller. A relayer cannot name SUBMITTER_A while sending the direct
        // (non-signature) entrypoint as SUBMITTER_B.
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest2 =
            _derivedSignalRequest( LINKED_ORDER_ID, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(4)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs2 = _derivedProofs(machine, derivedRequest2);
        vm.prank(SUBMITTER_B);
        vm.expectRevert(
            abi.encodeWithSelector(UVPDerivedSignalModule.UnauthorizedSignalCaller.selector, SUBMITTER_A, SUBMITTER_B)
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest2, SUBMITTER_A, derivedProofs2);
    }

    function testProductionSourceStageMappingGatesSignalsAndPatches() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine,
            _withOrderStart(_patchableSequentialPlan()),
            _selectorBindings(),
            _productionOverlaySignalCapabilities()
        );

        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](3);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        authorizations[1] = _authorization(SIGNAL_INIT_CMP, address(this));
        authorizations[2] = _stageAuthorization(PRODUCTION_SOURCE, PRODUCTION_SIGNAL, SUBMITTER_A);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);

        // The production source id is intentionally different from its stage
        // id. Before the stage is materialized, the signal must still be
        // rejected by the stage gate.
        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            PRODUCTION_SOURCE,
            PRODUCTION_SIGNAL,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            _noBinding()
        );

        // SIGNAL_INIT_CMP makes the STAGE_AUDIT hook ready and materializes
        // that stage; it is not the production source signal itself.
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            PRODUCTION_SOURCE,
            PRODUCTION_SIGNAL,
            PAYLOAD_HASH,
            bytes32(uint256(3)),
            _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            _noBinding()
        );
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            "production source signal missing"
        );
    }

    /// 词表 plan 的普通提交镜像出生/dock output 词表闸：省略 attribution 的
    /// 生产事实不得按"词表外口径"免门落库——否则属主阶段未物化即可写入，
    /// 随后诚实 ASSIGN patch 永久 StageAlreadyHasSignal。属主阶段物化并
    /// assign 后，携证提交放行；省略 attribution 则无论阶段是否就绪一律
    /// 拒绝（成员资格只能由 attribution 携 proof 自证）。
    function testSubmitSignalOmittedAttributionOnVocabularyPlan() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine,
            _withOrderStart(_patchableSequentialPlan()),
            _selectorBindings(),
            _productionOverlaySignalCapabilities()
        );

        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](3);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        authorizations[1] = _authorization(SIGNAL_INIT_CMP, address(this));
        authorizations[2] = _stageAuthorization(PRODUCTION_SOURCE, PRODUCTION_SIGNAL, SUBMITTER_A);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);

        // 属主阶段（STAGE_AUDIT）未物化：省略 attribution 的词表生产事实
        // 直接被词表闸拒绝，不进入免门的词表外口径。
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL
            )
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, PAYLOAD_HASH, bytes32(uint256(1))
        , _noAttribution(), _noBinding());
        require(
            !machine.hasSignal(PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            "unproven production fact was recorded"
        );

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        // 属主阶段已物化并 assign：省略 attribution 仍拒绝——词表闸约束的
        // 是成员资格证明，不是阶段就绪状态。
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL
            )
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, PAYLOAD_HASH, bytes32(uint256(3))
        , _noAttribution(), _noBinding());

        // 携证同键提交放行。
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, PAYLOAD_HASH, bytes32(uint256(4))
        , _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL), _noBinding());
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            "attributed production fact missing after materialization"
        );
    }

    function testDerivedSignalHonorsActiveExecutorOnTargetStage() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine,
            _withOrderStart(_patchableSequentialPlan()),
            _selectorBindings(),
            _derivedActiveSignalCapabilities()
        );

        // The origin order intentionally has no explicit authorization for
        // the derived target signal. Its stage executor is the only origin
        // authority, and it is set to SUBMITTER_B below.
        UVPStateMachine.SignalAuthorization[] memory originAuthorizations = new UVPStateMachine.SignalAuthorization[](3);
        originAuthorizations[0] = _authorization(SIGNAL_TRIGGER, address(this));
        originAuthorizations[1] = _authorization(SIGNAL_INIT_CMP, address(this));
        originAuthorizations[2] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, originAuthorizations);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), _noBinding());
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        // 子单（from 侧）出生授权带上 executor patch 资格，随后把子单
        // STAGE_AUDIT 的在任执行者设为 SUBMITTER_A——from 侧执行者门放行，
        // 让用例聚焦目标侧执行者门的拒绝。
        UVPStateMachine.SignalAuthorization[] memory childAuths = new UVPStateMachine.SignalAuthorization[](3);
        childAuths[0] = _authorization(SIGNAL_TRIGGER, SUBMITTER_A);
        childAuths[1] = _authorization(SIGNAL_VERIFY_FAIL, SUBMITTER_A);
        childAuths[2] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        _triggerOrderFromSignalRequest(
            machine, _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))), childAuths
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(PLAN_ID, LINKED_ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest3 =
            _derivedSignalRequest( LINKED_ORDER_ID, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(3)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs3 = _derivedProofs(machine, derivedRequest3);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_AUDIT, SUBMITTER_A, SUBMITTER_B
            )
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest3, SUBMITTER_A, derivedProofs3);
    }

    function testDerivedSignalRejectsMissingPlanCapability() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), _noBinding());
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest4 =
            _derivedSignalRequest( LINKED_ORDER_ID, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(3)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs4 = _derivedProofs(machine, derivedRequest4);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPDerivedSignalModule.InvalidSignalCapability.selector);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest4, SUBMITTER_A, derivedProofs4);
    }

    function testApplyStageExecutorPatchStoresActiveOverlayAndEmitsEvents() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);

        vm.recordLogs();
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            _countTopic(
                logs,
                keccak256(
                    "StageExecutorPatchApplied(bytes32,bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,bytes32,uint256,string)"
                )
            ) == 1,
            "patch event count"
        );
        require(
            _countTopic(
                logs,
                keccak256("StageExecutorActivated(bytes32,bytes32,bytes32,address,bytes32,bytes32,uint256,string)")
            ) == 1,
            "executor event count"
        );
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "bad active executor");
        require(
            _stagePatch(machine).orderStageExecutorPatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 1, "bad patch nonce"
        );
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A),
            "patched executor should receive signal authority"
        );
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_B),
            "explicit order authorization must survive executor patch"
        );

        (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        ) = _stagePatch(machine).getActiveStageExecutorPatch(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(exists, "active patch missing");
        require(executor == SUBMITTER_A, "bad executor");
        require(role == ROLE_EXECUTOR, "bad role");
        require(executorMetadataHash == EXECUTOR_METADATA_HASH, "bad executor metadata");
        require(patchHash == PATCH_HASH, "bad patch hash");
        require(patchNonce == 1, "bad stored nonce");
        require(keccak256(bytes(metadataURI)) == keccak256(bytes("uvp-eth://executor-patch")), "bad metadata uri");

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE),
            _noBinding()
        );
        require(machine.hasSourceSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT), "target source signal not marked");
        require(machine.sourceSignalCount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 1, "target signal count not tracked");
        require(
            machine.lastSignalSubmitter(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "last submitter not tracked"
        );
    }

    function testApplyStageExecutorPatchRejectsUnauthorizedSelector() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _birthSignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _targetSignalAuthorizations(SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageExecutorPatchSelector.selector, ORDER_ID, STAGE_INIT, address(this)
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
    }

    function testApplyStageExecutorPatchRejectsMissingSelectorBinding() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageSelectorBindingNotFound.selector, PLAN_ID, STAGE_INIT, STAGE_AUDIT
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
    }

    function testApplyStageExecutorPatchRejectsNonIncreasingNonce() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchNonceNotIncreasing.selector, ORDER_ID, STAGE_AUDIT, 2, 2
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH_2), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
    }

    /// 出生阶段仅声明出生事实、目标阶段（STAGE_AUDIT）零 relation=0 能力的
    /// executor patch：无键可委托时跳过委托、照常写 overlay——与主合约的
    /// 零能力口径（source==stage 回退）同阶。
    function testExecutorPatchSucceedsWithoutCurrentOrderCapabilities() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _birthSignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _stagePatchSelectorAuthorizations(address(this))
        );

        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        (bool exists, address executor,,,,,) =
            _stagePatch(machine).getActiveStageExecutorPatch(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(exists, "patch missing");
        require(executor == SUBMITTER_A, "bad executor");
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "overlay not active");
    }

    /// 非 HANDOFF 模式附带 previousExecutorSignature 直接拒绝——静默丢弃
    /// 签名会让调用方误以为签名参与了授权（API 语义一致化）。
    function testAssignModeRejectsStrayPreviousExecutorSignature() public {
        UVPStateMachine machine = _newMachine();
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _birthSignalCapabilities());
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _stagePatchSelectorAuthorizations(selector));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        address straySigner = vm.addr(SUBMITTER_PRIVATE_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, address(0), straySigner
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), _packedSignature(v, r, s), _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testSelectorTargetStageRejectsSignalBeforeExecutorAssigned() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE),
            _selectorBindingFor(machine, PLAN_ID, STAGE_AUDIT)
        );
    }

    /// stage 键事实（sourceId==stageId）按 _recordSignal 的 source==stage
    /// 回退归属目标阶段——assign 时序闸必须同口径计数：否则第二次 assign
    /// 不触发 StageAlreadyHasSignal，在任执行者被无签名替换。
    function testAssignRejectedAfterFallbackStageFact() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address executor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _fallbackFactMachine(selector, executor);

        // stage 键事实：归属 STAGE_AUDIT，同时进入 stage patch 的 capability
        // 枚举与 source==stage 回退流。
        vm.prank(executor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_FALLBACK,
            PAYLOAD_HASH,
            bytes32(uint256(0x9131)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_FALLBACK),
            _noBinding()
        );
        require(machine.sourceSignalCount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 1, "fallback fact not recorded");

        vm.prank(selector);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_B, PATCH_HASH_2), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
    }

    /// stage 键事实计入后阶段不被顶死：handoff 以在任执行者签名正常换人
    /// （修复前 signalCount==0 会在同一场景误报 StageHasNoSignal）。
    function testHandoffSucceedsAfterFallbackStageFact() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address executor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _fallbackFactMachine(selector, executor);

        vm.prank(executor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_FALLBACK,
            PAYLOAD_HASH,
            bytes32(uint256(0x9131)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_FALLBACK),
            _noBinding()
        );

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, executor, bytes32(0), bytes32(0)
        );
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 selectorV, bytes32 selectorR, bytes32 selectorS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        (uint8 previousV, bytes32 previousR, bytes32 previousS) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine)
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(selectorV, selectorR, selectorS), _packedSignature(previousV, previousR, previousS), _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff not applied");
    }

    /// 回退事实机器：overlay 词表 + 出生附加 stage 键事实的显式提交权，
    /// assign #1 后待用。
    function _fallbackFactMachine(address selector, address executor) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        // 词表内 plan 的 stage 键事实同样携证提交；sourceId==stageId 的事
        // 实落库后仍走 _stageSignalState 的双流计数（capability 枚举 +
        // source==stage 回退流）。
        SignalCapability[] memory overlay = _overlaySignalCapabilities();
        SignalCapability[] memory capabilities = new SignalCapability[](overlay.length + 1);
        for (uint256 i = 0; i < overlay.length; i++) {
            capabilities[i] = overlay[i];
        }
        capabilities[overlay.length] =
            SignalCapability({stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_FALLBACK, targetOrderRelation: 0});
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), capabilities);
        UVPStateMachine.SignalAuthorization[] memory base = _overlayAuthorizations(selector, executor, SUBMITTER_B);
        UVPStateMachine.SignalAuthorization[] memory authorizations =
            new UVPStateMachine.SignalAuthorization[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            authorizations[i] = base[i];
        }
        authorizations[base.length] = _stageAuthorization(STAGE_AUDIT, SIGNAL_FALLBACK, executor);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);
        // SIGNAL_INIT_CMP 令 STAGE_AUDIT 的 EMIT_READY hook Ready 并物化该阶段。
        vm.prank(selector);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x9130))
        , _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());
        _activateInitialStageExecutor(machine, selector, executor);
    }

    function testApplyStageExecutorPatchAssignRejectsUnexpectedGovernanceFields() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        UVPStagePatchModule.StageExecutorPatch memory previousPatch = _stageExecutorPatchWithMode(
            1, SUBMITTER_A, PATCH_HASH, EXECUTOR_PATCH_MODE_ASSIGN, SUBMITTER_B, bytes32(0), bytes32(0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchPreviousExecutorMismatch.selector,
                ORDER_ID,
                STAGE_AUDIT,
                address(0),
                SUBMITTER_B
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, previousPatch, _moduleBindingFor(machine, PLAN_ID, previousPatch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, previousPatch.targetStageId));

        UVPStagePatchModule.StageExecutorPatch memory approvalPatch = _stageExecutorPatchWithMode(
            1, SUBMITTER_A, PATCH_HASH, EXECUTOR_PATCH_MODE_ASSIGN, address(0), STAGE_INIT, SIGNAL_AUDIT_PASS
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchApprovalSignalMissing.selector,
                ORDER_ID,
                STAGE_INIT,
                SIGNAL_AUDIT_PASS
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, approvalPatch, _moduleBindingFor(machine, PLAN_ID, approvalPatch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, approvalPatch.targetStageId));
    }

    function testApplyStageExecutorPatchRejectsZeroExecutorAndPatchHash() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.expectRevert(UVPStagePatchModule.ZeroStageExecutor.selector);
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, address(0), PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testActivateStageExecutorFromModuleRejectsForeignStage() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        vm.prank(address(_stagePatch(machine)));
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.activateStageExecutorFromModule(
            PLAN_ID, ORDER_ID, STAGE_ROLLBACK, SUBMITTER_A, ROLE_EXECUTOR, EXECUTOR_METADATA_HASH, PATCH_HASH, 1, ""
        );
    }

    function testRelayerCanApplyStageExecutorPatchWithSelectorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine)
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "", _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));

        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "relayed patch not applied");
    }

    function testRelayedStageExecutorPatchRejectsWrongSigner() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address wrongSigner = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, selector, wrongSigner
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "", _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testRelayedStageExecutorPatchRejectsExpiredSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp - 1;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.ExpiredStageExecutorPatchSignature.selector, deadline)
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "", _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testHandoffStageExecutorPatchSucceedsWithPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, bytes32(0), bytes32(0)
        );
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
            bytes memory selectorSignature;
            bytes memory previousSignature;
            {
                (uint8 selectorV, bytes32 selectorR, bytes32 selectorS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
                selectorSignature = _packedSignature(selectorV, selectorR, selectorS);
                (uint8 previousV, bytes32 previousR, bytes32 previousS) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);
                previousSignature = _packedSignature(previousV, previousR, previousS);
            }

            vm.prank(UNAUTHORIZED_SUBMITTER);
            _stagePatch(machine)
                .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, selectorSignature, previousSignature, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        }

        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff executor not active"
        );
        (,,,, address originalSubmitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(originalSubmitter == previousExecutor, "prior signal attribution changed");

        // The prior executor remains valid when it has an explicit
        // order-level authorization; a handoff only changes the implicit
        // stage-executor lane.
        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW), _noBinding());
        require(machine.sourceSignalCount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 2, "handoff signal count not tracked");
        require(
            machine.lastSignalSubmitter(PLAN_ID, ORDER_ID, STAGE_AUDIT) == previousExecutor,
            "explicit prior executor attribution not tracked"
        );
    }

    function testHandoffStageExecutorPatchFailsWithoutPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, bytes32(0), bytes32(0)
        );
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

            vm.expectRevert(
                abi.encodeWithSelector(
                    UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
                )
            );
            _stagePatch(machine)
                .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "", _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        }

        vm.prank(selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testHandoffStageExecutorPatchFailsWithWrongPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, bytes32(0), bytes32(0)
        );
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory selectorSignature;
        bytes memory wrongSignature;
        {
            bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
            (uint8 selectorV, bytes32 selectorR, bytes32 selectorS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            selectorSignature = _packedSignature(selectorV, selectorR, selectorS);
            (uint8 wrongV, bytes32 wrongR, bytes32 wrongS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            wrongSignature = _packedSignature(wrongV, wrongR, wrongS);
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, selector
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, selectorSignature, wrongSignature, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testHandoffStageExecutorPatchRejectsApprovalFields() public {
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(address(this), previousExecutor);
        _activateInitialStageExecutor(machine, address(this), previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_INIT, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, STAGE_INIT, SIGNAL_AUDIT_PASS), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, STAGE_INIT, SIGNAL_AUDIT_PASS
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchApprovalSignalMissing.selector,
                ORDER_ID,
                STAGE_INIT,
                SIGNAL_AUDIT_PASS
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testReplacementStageExecutorPatchSucceedsWithApprovalSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_INIT, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, STAGE_INIT, SIGNAL_AUDIT_PASS), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_REPLACEMENT, SUBMITTER_A, STAGE_INIT, SIGNAL_AUDIT_PASS
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));

        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B,
            "replacement executor not active"
        );
        (,,,, address originalSubmitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(originalSubmitter == SUBMITTER_A, "replacement rewrote prior submitter");

        // Replacement does not revoke an explicit order-level grant.
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(3)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW), _noBinding());
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, SUBMITTER_A),
            "replacement must preserve explicit prior executor authorization"
        );
    }

    function testReplacementStageExecutorPatchFailsWithoutApprovalSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_REPLACEMENT, SUBMITTER_A, STAGE_INIT, SIGNAL_AUDIT_PASS
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchApprovalSignalMissing.selector,
                ORDER_ID,
                STAGE_INIT,
                SIGNAL_AUDIT_PASS
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testStageExecutorPatchRejectsPreviousExecutorMismatch() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_REPLACEMENT, SUBMITTER_B, STAGE_INIT, SIGNAL_AUDIT_PASS
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchPreviousExecutorMismatch.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SUBMITTER_A,
                SUBMITTER_B
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testActiveStageExecutorPatchPreservesExplicitOrderAuthorization() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        address outsider = address(0xBAD);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, outsider
            )
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        // SUBMITTER_B has an explicit order-level authorization from order
        // creation. The active executor overlay must not revoke it.
        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());
        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(submitter == SUBMITTER_B, "explicit submitter was blocked");
    }

    function testStageSignalRequiresSourceStageMaterialization() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _overlaySignalCapabilities()
        );
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        (bool exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(!exists, "prematerialized stage signal was stored");

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(3)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());
        (exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(exists, "materialized stage signal missing");
    }

    function testActiveStageExecutorReceivesPlanScopedSignalAuthorization() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _overlaySignalCapabilities()
        );
        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        authorizations[1] = _authorization(SIGNAL_INIT_CMP, address(this));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);

        (bool staticAuthorization,,) =
            machine.getSignalAuthorization(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A);
        require(!staticAuthorization, "active executor unexpectedly pre-authorized");

        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x9201))
        , _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A),
            "patched executor was not dynamically authorized"
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());
    }

    function testApplyStageResourcePatchStoresOverlayAndEmitsEvent() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);

        vm.recordLogs();
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            _countTopic(
                logs,
                keccak256(
                    "StageResourcePatchApplied(bytes32,bytes32,bytes32,bytes32,address,bytes32,bytes32,bytes32,bytes32,uint256,string)"
                )
            ) == 1,
            "resource patch event count"
        );
        require(
            _stagePatch(machine).orderStageResourcePatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT, RESOURCE_KEY) == 1,
            "bad resource patch nonce"
        );
        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == address(0), "resource patch changed executor"
        );

        (
            bool exists,
            bytes32 manifestHash,
            bytes32 policyHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory manifestURI
        ) = _stagePatch(machine).getActiveStageResourcePatch(PLAN_ID, ORDER_ID, STAGE_AUDIT, RESOURCE_KEY);
        require(exists, "resource patch missing");
        require(manifestHash == MANIFEST_HASH, "bad manifest hash");
        require(policyHash == RESOURCE_POLICY_HASH, "bad policy hash");
        require(patchHash == RESOURCE_PATCH_HASH, "bad resource patch hash");
        require(patchNonce == 1, "bad stored resource nonce");
        require(keccak256(bytes(manifestURI)) == keccak256(bytes("ipfs://resource-manifest")), "bad manifest uri");
    }

    function testApplyStageResourcePatchRejectsNonIncreasingNonceAndIsolatesResourceKeys() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(2, RESOURCE_PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageResourcePatchNonceNotIncreasing.selector,
                ORDER_ID,
                STAGE_AUDIT,
                RESOURCE_KEY,
                2,
                2
            )
        );
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(2, RESOURCE_PATCH_HASH_2), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID, ORDER_ID, _stageResourcePatchWithKey(RESOURCE_KEY_2, 1, RESOURCE_PATCH_HASH_2)
            , _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
        require(
            _stagePatch(machine).orderStageResourcePatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT, RESOURCE_KEY_2) == 1,
            "resource key nonce not isolated"
        );
    }

    function testApplyStageResourcePatchRejectsUnauthorizedSelector() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _birthSignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _targetSignalAuthorizations(SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageResourcePatchSelector.selector, ORDER_ID, STAGE_INIT, address(this)
            )
        );
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(1, RESOURCE_PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
    }

    function testApplyStageResourcePatchRejectsAfterTargetStageSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY, _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(1, RESOURCE_PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
    }

    function testApplyStageResourcePatchRejectsZeroFields() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.resourceKey = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroResourceKey.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.manifestHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroManifestHash.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.policyHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroPolicyHash.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));

        patch = _stageResourcePatch(1, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testRelayerCanApplyStageResourcePatchWithSelectorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageResourcePatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine)
            .applyStageResourcePatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));

        require(
            _stagePatch(machine).orderStageResourcePatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT, RESOURCE_KEY) == 1,
            "relayed resource patch not applied"
        );
    }

    function testRelayedStageResourcePatchRejectsWrongSigner() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address wrongSigner = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageResourcePatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageResourcePatchSignature.selector, selector, wrongSigner
            )
        );
        _stagePatch(machine)
            .applyStageResourcePatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testPositiveSignalMakesHookReady() public {
        UVPStateMachine machine = _registeredMachine(_emitReadyPositiveHookPlan(HOOK_INIT));

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(dueAt == 0, "ready hook has due");
        require(readyEmitted, "ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "ready event count");

        (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter) =
            machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(exists, "signal missing");
        require(payloadHash == PAYLOAD_HASH, "bad payload hash");
        require(idempotencyKey == IDEMPOTENCY_KEY, "bad idempotency key");
        require(submittedAt == uint64(block.timestamp), "bad submitted at");
        require(submitter == address(this), "bad submitter");
    }

    /// 共享依赖键的求值口径（§7.2 出生锚订单归属）：普通信号提交只求值
    /// 非出生 hook——ORDER_TRIGGER_MINT hook 不被普通提交推 Ready（只由
    /// 出生通道驱动），EMIT_READY / 纯 watcher 照常求值。
    function testSharedSignalSkipsOrderTriggerHookAndEvaluatesWatcher() public {
        UVPStateMachine machine = _registeredMachine(_sharedDependencyPlanWithNonTriggerFirst());

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus triggerStatus,, bool triggerReadyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus nonTriggerStatus,, bool nonTriggerReadyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_NON_TRIGGER);
        require(triggerStatus == UVPStateMachine.HookStatus.Init, "mint hook evaluated by normal submission");
        require(!triggerReadyEmitted, "mint hook emitted ready");
        require(nonTriggerStatus == UVPStateMachine.HookStatus.Ready, "watcher not evaluated");
        require(!nonTriggerReadyEmitted, "watcher emitted ready");
        require(_countHookReady(vm.getRecordedLogs()) == 0, "unexpected ready event");
    }

    /// §7.2 出生锚订单归属：订单 Y（由事实 K2 铸出）内提交另一出生线事实
    /// K1（建单 authorizations 可自由携带 K1 提交权——正是攻击面）不得把
    /// Y 的 K1-mint 钩子推 Ready、不得物化 K1 的出生阶段；K1 仍可经自己的
    /// 出生通道铸出唯一新订单并在新订单上物化该阶段。
    function testForeignBirthFactDoesNotMaterializeBirthStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory altLine = new UVPStateMachine.CompactHook[](1);
        altLine[0] = _signalHook(HOOK_ALT_MINT, STAGE_ALT, HOOK_NAME_ORDER_START, true, SIGNAL_ALT_BIRTH);
        _registerPlan(machine, _withOrderStart(altLine));

        // 订单 Y 由 K2（SIGNAL_ORDER_START）铸出，authorizations 顺带携带
        // K1（SIGNAL_ALT_BIRTH）的提交权。
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_ALT_BIRTH, address(this)));
        (UVPStateMachine.HookStatus birthStatus,, bool birthReady) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_ORDER_START);
        require(birthStatus == UVPStateMachine.HookStatus.Ready, "birth hook not ready");
        require(birthReady, "birth ready marker missing");

        vm.recordLogs();
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ALT_BIRTH, PAYLOAD_HASH, bytes32(uint256(0x9132))
        , _noAttribution(), _noBinding());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_ALT_BIRTH),
            "foreign birth fact write itself must succeed"
        );
        (UVPStateMachine.HookStatus altStatus,, bool altReady) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_ALT_MINT);
        require(altStatus == UVPStateMachine.HookStatus.Init, "foreign mint hook evaluated");
        require(!altReady, "foreign mint hook emitted ready");
        require(_countHookReady(logs) == 0, "HookReady emitted for foreign birth line");
        require(
            _countTopic(logs, keccak256("StageMaterialized(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)")) == 0,
            "foreign birth stage materialized"
        );

        // K1 经自己的出生通道铸出唯一新订单：HOOK_ALT_MINT 在新订单上
        // Ready 并物化 STAGE_ALT——出生事实仍服务于铸造它自己的订单。
        UVPStateMachine.TriggerOrderFromOutsideRequest memory altTrigger =
            _outsideTriggerRequest(HOOK_ALT_MINT, SIGNAL_ALT_BIRTH);
        altTrigger.triggerStageId = STAGE_ALT;
        bytes32 altOrderId = ORDER_ID;
        _submitTriggerOrderFromOutsideRequest(
            machine, altTrigger, _auths1(SIGNAL_ALT_BIRTH, address(this)), SUBMITTER_PRIVATE_KEY
        );
        require(machine.orderExists(PLAN_ID, altOrderId), "alt birth order missing");
        (altStatus,, altReady) = machine.getHookStatus(PLAN_ID, altOrderId, HOOK_ALT_MINT);
        require(altStatus == UVPStateMachine.HookStatus.Ready, "alt birth hook not ready on its own order");
        require(altReady, "alt birth ready marker missing");
    }

    /// SIGNAL 指令 sourceId==0 在注册边界拒绝——与写入口零键闸同口径
    /// （sourceId==0 绕过 _signalStageId，是 stage 物化与 executor 门的
    /// 永久豁免键）。
    function testCommitPlanRejectsZeroSourceIdSignalInstruction() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: bytes32(0),
            signalId: SIGNAL_TRIGGER,
            arity: 0,
            delaySeconds: 0
        });
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 普通提交路径自拒零字 sourceId（对齐 triggerOrderFromOutsideFor /
    /// _authorizeSignalSubmitter 的零键闸）。
    function testSubmitSignalRejectsZeroSourceId() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, address(this)));

        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.submitSignal(PLAN_ID, ORDER_ID, bytes32(0), SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
    }

    /// FromModule 信号写入口的零字键兜底：dependencyKeys 是不透明哈希，
    /// 注册边界无法从键反查零字——入口必须自拒。
    function testDockingFromModuleEntriesRejectZeroFactKeys() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, address(this)));
        UVPStateMachine.SignalAuthorization[] memory noAuths = new UVPStateMachine.SignalAuthorization[](0);
        address dockingModule = address(_docking(machine));

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.createDockedOrderFromModule(
            PLAN_ID,
            bytes32(uint256(1) << 255),
            ORDER_CREATOR,
            address(this),
            HOOK_INIT,
            STAGE_INIT,
            bytes32(0),
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            address(this),
            noAuths
        );

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.recordDockedInputFromModule(
            PLAN_ID, ORDER_ID, bytes32(0), SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this)
        );

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.submitSignalFromModule(
            PLAN_ID, ORDER_ID, bytes32(0), SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this)
        , _noAttribution(), _noBinding());

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSignalId.selector);
        machine.submitSignalFromModule(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, bytes32(0), PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this)
        , _noAttribution(), _noBinding());
    }

    function testUnauthorizedSubmitterRevertsBeforeFirstWrite() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        require(
            !machine.isSignalSubmitterAuthorized(
                PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER
            ),
            "unexpected authorization"
        );

        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_TRIGGER,
                UNAUTHORIZED_SUBMITTER
            )
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        require(
            !machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "unauthorized signal was written"
        );
    }

    function testAuthorizedSubmitterCanAdvanceHook() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_emitReadyPositiveHookPlan(HOOK_INIT)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");

        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(submitter == SUBMITTER_A, "bad submitter");
    }

    function testRelayerCanSubmitAuthorizedSignalWithSubmitterSignature() public {
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_emitReadyPositiveHookPlan(HOOK_INIT)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine,
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            submitter,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        machine.submitSignalFor(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            submitter,
            deadline,
            _packedSignature(v, r, s)
        , _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");

        (,,,, address recordedSubmitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(recordedSubmitter == submitter, "relayer became submitter");
    }

    function testRelayedSignalRejectsWrongSigner() public {
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        address wrongSigner = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine,
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            submitter,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidSignalSignature.selector, submitter, wrongSigner));
        machine.submitSignalFor(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            submitter,
            deadline,
            _packedSignature(v, r, s)
        , _noAttribution(), _noBinding());
    }

    function testRelayedSignalRejectsExpiredSignature() public {
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp - 1;
        bytes32 digest = _signalSubmissionDigest(
            machine,
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            submitter,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredSignalSignature.selector, deadline));
        machine.submitSignalFor(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            submitter,
            deadline,
            _packedSignature(v, r, s)
        , _noAttribution(), _noBinding());
    }

    function testMultipleSubmittersForSameSignalFirstWriterWins() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _auths2SameSignal(SIGNAL_TRIGGER, SUBMITTER_A, SUBMITTER_B)
        );

        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, SUBMITTER_A),
            "submitter A not authorized"
        );
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, SUBMITTER_B),
            "submitter B not authorized"
        );

        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution(), _noBinding());

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.SignalAlreadyExists.selector);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution(), _noBinding());

        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(submitter == SUBMITTER_B, "first writer changed");
    }

    function testSameWalletCanBeAuthorizedForMultipleSignals() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_watcherSequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine,
            PLAN_ID,
            ORDER_CREATOR,
            _auths3ForSubmitter(SIGNAL_TRIGGER, SIGNAL_INIT_CMP, SIGNAL_AUDIT_PASS, SUBMITTER_A)
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution(), _noBinding());
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution(), _noBinding());
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)), _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_AUDIT);
        (UVPStateMachine.HookStatus timeoutStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
        require(timeoutStatus == UVPStateMachine.HookStatus.Ready, "timeout not ready");
    }

    function testDifferentSignalsCanUseDifferentSubmitters() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_watcherSequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine,
            PLAN_ID,
            ORDER_CREATOR,
            _splitSignalAuths(SIGNAL_TRIGGER, SUBMITTER_A, SIGNAL_INIT_CMP, SUBMITTER_B)
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution(), _noBinding());

        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_INIT_CMP,
                SUBMITTER_A
            )
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution(), _noBinding());

        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(3)), _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_AUDIT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
    }

    function testSequentialUpdateFlowHooksBecomeReady() public {
        UVPStateMachine machine = _registeredMachine(_watcherSequentialPlan());

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution(), _noBinding());
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution(), _noBinding());
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)), _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_AUDIT);
        (UVPStateMachine.HookStatus timeoutStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
        require(timeoutStatus == UVPStateMachine.HookStatus.Ready, "timeout not ready");
        require(_countHookReady(vm.getRecordedLogs()) == 3, "ready event count");
    }

    function testTimerWaitsUntilDueThenReady() public {
        UVPStateMachine machine = _registeredMachine(_timerHookPlan(HOOK_TIMEOUT, 60));

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "hook not waiting");
        require(dueAt == 160, "bad dueAt");
        require(!readyEmitted, "early ready marker");

        vm.warp(159);
        vm.expectRevert(UVPStateMachine.TimerNotDue.selector);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);

        vm.warp(160);
        vm.recordLogs();
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);

        (status, dueAt, readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "timer hook not ready");
        require(dueAt == 0, "timer ready has due");
        require(readyEmitted, "timer ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "timer ready event count");
    }

    function testCommitPlanAcceptsDelayAtThirtyDayBound() public {
        UVPStateMachine machine = _registeredMachine(_timerHookPlan(HOOK_TIMEOUT, 30 days));

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "hook not waiting");
        require(dueAt == 100 + machine.MAX_HOOK_DELAY_SECONDS(), "bad dueAt");
        require(!readyEmitted, "early ready marker");
    }

    function testCommitPlanRejectsDelayAboveThirtyDayBound() public {
        UVPStateMachine machine = _newMachine();

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.HookDelayTooLong.selector, uint256(30 days + 1)));
        _commitPlan(
            machine,
            _timerHookPlan(HOOK_TIMEOUT, 30 days + 1),
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    function testCommitPlanAcceptsOneSecondDelay() public {
        UVPStateMachine machine = _registeredMachine(_timerHookPlan(HOOK_TIMEOUT, 1));

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "hook not waiting");
        require(!readyEmitted, "early ready marker");

        vm.warp(101);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);

        (status,, readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");
    }

    function testNegativeSignalCancelsHook() public {
        UVPStateMachine machine = _registeredMachine(_negativeHookPlan(HOOK_TIMEOUT));

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "hook not cancelled");
        require(dueAt == 0, "cancelled hook has due");
        require(!readyEmitted, "cancelled hook emitted ready");
    }

    function testOrBranchTriggersRollback() public {
        UVPStateMachine machine = _registeredMachine(_orRollbackPlan());

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status,, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_ROLLBACK);
        require(status == UVPStateMachine.HookStatus.Ready, "rollback not ready");
        require(readyEmitted, "rollback ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "rollback ready event");
    }

    function testDuplicateSignalReverts() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        vm.expectRevert(UVPStateMachine.SignalAlreadyExists.selector);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, bytes32(uint256(0x8002)), bytes32(uint256(0x9002))
        , _noAttribution(), _noBinding());
    }

    /// 纯 flags=0 watcher 阶段在注册边界直接拒绝——该阶段永远无法
    /// 物化（物化只由本阶段 order-trigger / EMIT_READY hook Ready 触发）。
    function testStageWithoutMaterializingHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _positiveHookPlan(HOOK_NON_TRIGGER, false);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.StageNotMaterializable.selector, STAGE_INIT));
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// HookReady 三线口径统一：沉默 mint trigger（flags=1，缺 EMIT_READY）
    /// 在注册边界直接拒绝——编译器产物恒为 trigger|EMIT_READY，该形态链上
    /// 不可达。
    function testSilentMintTriggerHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_ORDER_TRIGGER_MINT, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SilentOrderTriggerHook.selector, HOOK_INIT));
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 沉默 dock trigger（flags=2，缺 EMIT_READY）同样拒绝。
    function testSilentDockTriggerHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_ORDER_TRIGGER_DOCK, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SilentOrderTriggerHook.selector, HOOK_INIT));
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 编译器同口径（mint=5 / dock=6）的 trigger hook 注册面放行。
    function testCompilerShapedTriggerHooksRegister() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory mintInstructions = new UVPStateMachine.Instruction[](1);
        mintInstructions[0] = _signal(SIGNAL_TRIGGER);
        hooks[0] = _hookWithFlags(
            HOOK_INIT,
            STAGE_INIT,
            HOOK_NAME_TRIGGER,
            uint8(FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY),
            mintInstructions,
            _deps(SIGNAL_TRIGGER)
        );
        UVPStateMachine.Instruction[] memory dockInstructions = new UVPStateMachine.Instruction[](1);
        dockInstructions[0] = _signal(SIGNAL_AUDIT_PASS);
        hooks[1] = _hookWithFlags(
            HOOK_AUDIT,
            STAGE_AUDIT,
            HOOK_NAME_INIT_DONE,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            dockInstructions,
            _deps(SIGNAL_AUDIT_PASS)
        );

        bytes32 planId = _registerPlan(machine, hooks);
        require(machine.planExists(planId), "compiler-shaped plan not registered");
    }

    /// order-trigger hook 内禁止 DELAY：outside
    /// 出生的事实与订单创建同笔交易（anchorAt=now），Delay(SIGNAL) 必得
    /// Wait，出生路径永久 InvalidTriggerHook——注册边界直接拒绝。
    function testDelayInMintTriggerHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(5);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT,
            STAGE_INIT,
            HOOK_NAME_TRIGGER,
            uint8(FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY),
            instructions,
            _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// dock trigger（entrance）hook 同口径拒绝 DELAY——entrance 由模块直接
    /// 标记 Ready，DELAY 在该 hook 内只是死代码。
    function testDelayInDockTriggerHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(5);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT,
            STAGE_INIT,
            HOOK_NAME_TRIGGER,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            instructions,
            _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 指令集收敛为 SIGNAL/NOT/AND/OR/DELAY——旧扇入操作码（数值 5，按
    /// uint8 数值拼装，不在词表内）携带进 plan 时，
    /// commitPlan 注册边界经 _validateHook 词表门显式 revert
    /// InvalidInstruction。
    function testCommitPlanRejectsRetiredFanInOpcode() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_INIT_CMP);
        instructions[2] = UVPStateMachine.Instruction({
            op: uint8(5), sourceId: bytes32(0), signalId: bytes32(0), arity: 2, delaySeconds: 0
        });
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_TRIGGER, SIGNAL_INIT_CMP)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 延时操作数须含正向信号锚点（对齐 uvp-hook-dsl validate_anchors）：
    /// 全否定操作数在 value=true 时 anchorAt=0，到期时刻恒在过去，Delay
    /// 沦为立即放行（非/~ 形态编译器已拒，这里是注册边界兜底）。
    function testDelayWithoutPositiveSignalAnchorIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _not();
        instructions[2] = _delay(5);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT, STAGE_INIT, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// Or 的缺席分支可单独就绪且锚点为 0：Delay 的操作数里每个 Or 分支
    /// 都须含正向锚点（镜像编译器 each-OR-branch 约束）。
    function testDelayOverOrWithUnanchoredBranchIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _not();
        instructions[2] = _signal(SIGNAL_INIT_CMP);
        instructions[3] = _or(2);
        instructions[4] = _delay(5);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_TRIGGER, SIGNAL_INIT_CMP)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// NOT 操作数必须裸 SIGNAL（uvp-hook-dsl validate_anchors 镜像
    /// 的编码层契约）——~(A&B) 组合否定在注册边界拒绝。
    function testCommitPlanRejectsNotOverCompositeOperand() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _signal(SIGNAL_TRIGGER);
        instructions[2] = _and(2);
        instructions[3] = _not();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_VERIFY_FAIL, SIGNAL_TRIGGER)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 整体至少一正锚（validate_anchors 镜像）——纯否定 hook（~A）在
    /// value=true 时 anchorAt=0，注册边界拒绝。
    function testCommitPlanRejectsPureNegativeHook() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _not();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT, STAGE_INIT, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, instructions, _deps(SIGNAL_VERIFY_FAIL)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// finalizePlan 二次调用专属错误：与 commitPlan 幂等重放
    /// （PlanAlreadyRegistered）区分拒绝点。
    function testFinalizePlanTwiceRevertsPlanAlreadyFinalized() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));

        vm.expectRevert(UVPStateMachine.PlanAlreadyFinalized.selector);
        machine.finalizePlan(planId);
    }

    /// sourceId==0 的 SIGNAL 授权会绕过 stage/executor 门
    /// （_signalStageId 对 sourceId==0 恒返回 0）——注册期拒绝。
    function testTriggerOrderAuthorizationRejectsZeroSourceId() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        PLAN_ID = planId;

        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](1);
        authorizations[0] = UVPStateMachine.SignalAuthorization({
            sourceId: bytes32(0),
            signalId: SIGNAL_ORDER_START,
            submitter: address(this),
            role: ROLE_BOOTSTRAP,
            metadataHash: AUTH_METADATA_HASH
        });
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);

        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
    }

    /// 零 capability 的手工 plan 不做词表闸——出生事实的零字事实键是
    /// 唯一放行入口（其余写入口均拒 0）。零字事实键绕过 _signalStageId
    /// （对 0 恒返回 0），是 stage 物化与 executor 门的永久豁免键。
    function testTriggerOrderFromOutsideRejectsZeroSourceId() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        PLAN_ID = planId;

        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        trigger.sourceId = bytes32(0);
        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](0);
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);

        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
    }

    /// 同上：signalId==0 的事实键同样绕过 _signalStageId，与其余写入口
    /// 的 ZeroSignalId 口径对齐。
    function testTriggerOrderFromOutsideRejectsZeroSignalId() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        PLAN_ID = planId;

        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        trigger.signalId = bytes32(0);
        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](0);
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);

        vm.expectRevert(UVPStateMachine.ZeroSignalId.selector);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
    }

    /// FromModule 信号写入口全量拒绝 submitter==0：lastSignalSubmitter=0
    /// 会污染 dock output 通道与 HANDOFF 签名门。
    function testCreateDockedOrderFromModuleRejectsZeroSubmitter() public {
        UVPStateMachine machine = _newMachine();

        vm.prank(address(_dockingModules[address(machine)]));
        vm.expectRevert(UVPStateMachine.ZeroSubmitter.selector);
        machine.createDockedOrderFromModule(
            PLAN_ID,
            bytes32(uint256(1) << 255),
            ORDER_CREATOR,
            address(this),
            HOOK_INIT,
            STAGE_INIT,
            SOURCE_BOOTSTRAP,
            SIGNAL_ORDER_START,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            address(0),
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    function testRecordDockedInputFromModuleRejectsZeroSubmitter() public {
        UVPStateMachine machine = _newMachine();

        vm.prank(address(_dockingModules[address(machine)]));
        vm.expectRevert(UVPStateMachine.ZeroSubmitter.selector);
        machine.recordDockedInputFromModule(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(0)
        );
    }

    // 规模上限测试（testFinalizePlanRejectsSignalCapabilitiesAboveLimit /
    // testFinalizePlanRejectsSelectorBindingsAboveLimit /
    // testFinalizePlanAcceptsSelectorBindingsAtLimitWithinGasBudget）随
    // Merkle 化作废：能力表/绑定表不再在 finalize 边界逐条写存储，规模闸
    // 无链上语义（替代测试由主控另行补充）。

    // ------------------------------------------------------------------
    // 出生通道键并集去重（U2）
    // ------------------------------------------------------------------

    /// mint 出生键与 dock entrance 键重合：一次出生事务会把两条出生线的
    /// order-trigger hook 同时推 Ready 并物化幻影阶段——注册边界拒绝。
    function testCommitPlanRejectsSharedBirthChannelKeyAcrossMintAndDock() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] = _hookWithFlags(
            HOOK_ALT_MINT,
            STAGE_ALT,
            HOOK_NAME_ORDER_START,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            _signalInstructions(SIGNAL_TRIGGER),
            _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.DuplicateBirthChannelKey.selector,
                keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TRIGGER))
            )
        );
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// mint∪mint 扇出（customs 基准 plan 形态：一事实同时出生两条 mint
    /// 出生线）在同一出生上下文内物化，不是幻影——放行。
    function testMintFanOutMayShareBirthChannelKey() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] = _signalHook(HOOK_ALT_MINT, STAGE_ALT, HOOK_NAME_ORDER_START, true, SIGNAL_TRIGGER);

        bytes32 planId = _registerPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
        require(machine.planExists(planId), "mint fan-out plan not registered");
    }

    /// dock∪dock：entrance 键按 route 钉死，两条 entrance 共享一键会让
    /// 任一 route 的子单物化另一 route 的阶段——拒绝。
    function testCommitPlanRejectsSharedBirthChannelKeyWithinDockChannel() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _hookWithFlags(
            HOOK_INIT,
            STAGE_INIT,
            HOOK_NAME_TRIGGER,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            _signalInstructions(SIGNAL_TRIGGER),
            _deps(SIGNAL_TRIGGER)
        );
        hooks[1] = _hookWithFlags(
            HOOK_ALT_MINT,
            STAGE_ALT,
            HOOK_NAME_ORDER_START,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            _signalInstructions(SIGNAL_TRIGGER),
            _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.DuplicateBirthChannelKey.selector,
                keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TRIGGER))
            )
        );
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 前导同阶段 watcher 遮蔽形态：dependents[0] 是非 trigger watcher 时，
    /// 排在其后的 trigger 依赖仍必须逐个过出生通道查重——跨阶段闸的
    /// trigger-only 折叠在首位 break，查重若与之共线即被跳过，一次出生
    /// 事务会同时推 mint 与 dock 两条出生线、物化幻影阶段。
    function testCommitPlanRejectsBirthChannelKeyHiddenByLeadingWatcher() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        // 同阶段 watcher 先注册：占据 dependents[0]，制造折叠早退的位置。
        hooks[0] = _hookWithFlags(
            HOOK_NON_TRIGGER,
            STAGE_INIT,
            HOOK_NAME_TRIGGER,
            uint8(0),
            _signalInstructions(SIGNAL_TRIGGER),
            _deps(SIGNAL_TRIGGER)
        );
        hooks[1] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_TRIGGER);
        hooks[2] = _hookWithFlags(
            HOOK_ALT_MINT,
            STAGE_INIT,
            HOOK_NAME_INIT_DONE,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            _signalInstructions(SIGNAL_TRIGGER),
            _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.DuplicateBirthChannelKey.selector,
                keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TRIGGER))
            )
        );
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// watcher 不是出生通道：mint 出生键与普通 watcher 共享合法（出生事实
    /// 到达只求值 watcher 的普通语义，不推第二条出生线）。
    function testWatcherMayShareBirthChannelKey() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        // watcher 与出生键同阶段共享（跨阶段非 trigger watcher 是另一道闸）。
        hooks[1] = _emitReadySignalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, SIGNAL_ORDER_START);

        bytes32 planId = _registerPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
        require(machine.planExists(planId), "plan not registered");
    }

    // ------------------------------------------------------------------
    // dependencyKeys 与 SIGNAL 原子键一致性
    // ------------------------------------------------------------------

    /// 声明了永不参与求值的键（SIGNAL 原子缺席）：该键提交不触发本 hook，
    /// hook 永久 Init 零告警——注册边界拒绝。
    function testCommitPlanRejectsDependencyKeyWithoutSignalAtom() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_AUDIT_PASS);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.HookDependencyKeyMismatch.selector, HOOK_INIT));
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 反向：SIGNAL 原子未声明进 dependencyKeys——事实到达不触发求值，
    /// 同样拒绝（幻影 watcher）。
    function testCommitPlanRejectsSignalAtomMissingFromDependencyKeys() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_AUDIT_PASS);
        instructions[2] = _or(2);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        // 只声明 SIGNAL_TRIGGER，漏掉 SIGNAL_AUDIT_PASS。
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.HookDependencyKeyMismatch.selector, HOOK_INIT));
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    // ------------------------------------------------------------------
    // 两步注册元数据交叉校验
    // ------------------------------------------------------------------

    // 链上 finalize 不做 UnknownPlanStage 交叉校验：capability 叶的悬空
    // 阶段引用由编译器在产物层强制（链上 finalize 只翻转 finalized 并落
    // roots）。

    // ------------------------------------------------------------------
    // 元数据规模面
    // ------------------------------------------------------------------

    // 绑定表无规模闸（AboveLimit / AtLimitWithinGasBudget 无对象）：
    // 绑定表不在 finalize 边界逐条写存储，_twelveStagePlan 无用途不设。

    function _signalInstructions(bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.Instruction[] memory instructions)
    {
        instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(signalId);
    }

    // ------------------------------------------------------------------
    // dock 出生终态守卫
    // ------------------------------------------------------------------

    /// 矛盾 entrance 条件（K & ~K）：出生事务内求值把 entrance hook 推到
    /// Cancelled，dock 出生不得覆写终态——镜像 outside 出生路径的就绪断言
    /// （InvalidTriggerHook），整笔出生回滚。
    function testDockBirthDoesNotOverwriteCancelledEntranceHook() public {
        UVPStateMachine machine = _newMachine();
        // entrance 条件：SIGNAL(K);SIGNAL(K);NOT;AND(2) —— K 在场恒 cancel。
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_TRIGGER);
        instructions[2] = _not();
        instructions[3] = _and(2);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _hookWithFlags(
            HOOK_ALT_MINT,
            STAGE_ALT,
            HOOK_NAME_TRIGGER,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            instructions,
            _deps(SIGNAL_TRIGGER)
        );
        _registerPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );

        bytes32 dockedOrderId = bytes32(uint256(1) << 255 | uint256(0x0DD1));
        vm.prank(address(_docking(machine)));
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidTriggerHook.selector, HOOK_ALT_MINT));
        machine.createDockedOrderFromModule(
            PLAN_ID,
            dockedOrderId,
            ORDER_CREATOR,
            address(this),
            HOOK_ALT_MINT,
            STAGE_ALT,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            address(this),
            new UVPStateMachine.SignalAuthorization[](0)
        );
        require(!machine.orderExists(PLAN_ID, dockedOrderId), "birth must roll back atomically");
    }

    // ------------------------------------------------------------------
    // 生命周期负例
    // ------------------------------------------------------------------

    /// 待定计划（committed 未 finalized）不能创建订单。外部入口最先触达
    /// metadata 模块的 UnknownPlan（planExists=finalized 口径）；_createOrder
    /// 的 PlanNotFinalized 是模块路径的防御纵深，外部不可达。
    function testBirthOnCommittedOnlyPlanIsRejected() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _commitPlan(
            machine,
            _withOrderStart(_positiveHookPlan(HOOK_INIT, true)),
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
        require(machine.planCommitted(planId) && !machine.planFinalized(planId), "plan must be pending");

        UVPStateMachine.SignalAuthorization[] memory authorizations = _auths1(SIGNAL_TRIGGER, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        trigger.planId = planId;
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);
        vm.expectRevert(UVPStateMachine.UnknownPlan.selector);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
    }

    /// 未知 plan 的 finalize 直接拒绝（两步注册第一步缺失）。
    function testFinalizePlanRejectsUnknownPlan() public {
        UVPStateMachine machine = _newMachine();

        vm.expectRevert(UVPStateMachine.PlanNotCommitted.selector);
        machine.finalizePlan(bytes32(uint256(0xBAAD)));
    }

    /// commit 签名不匹配发布者：恢复地址 != 声明发布者即拒绝。
    function testCommitPlanRejectsWrongPublisherSignature() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        address publisher = vm.addr(PUBLISHER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(new bytes32[](0)),
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidPlanSignature.selector, publisher, vm.addr(WRONG_SUBMITTER_PRIVATE_KEY)
            )
        );
        machine.commitPlan(commit, hooks, _packedSignature(v, r, s));
    }

    /// 过期 deadline 的 commit 签名拒绝（先于签名恢复）。
    function testCommitPlanRejectsExpiredSignature() public {
        UVPStateMachine machine = _newMachine();
        uint256 deadline = block.timestamp - 1;
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(new bytes32[](0)),
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            deadline: deadline
        });

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredPlanSignature.selector, deadline));
        machine.commitPlan(commit, hooks, new bytes(65));
    }

    /// commit 期 hooksHash 与实际 hooks 失配拒绝（finalize 元数据失配闸已随
    /// Merkle 化移除：capabilitiesRoot 在 commit 期一次承诺，finalize 不再
    /// 携带元数据）。
    function testPlanMetadataAndHooksHashMismatchAreRejected() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(_sequentialPlan())),
            capabilitiesRoot: DockMerkle.root(new bytes32[](0)),
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
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.HooksHashMismatch.selector, commit.hooksHash, keccak256(abi.encode(hooks))
            )
        );
        machine.commitPlan(commit, hooks, _packedSignature(v, r, s));
    }

    /// 非 65 字节的提交签名在长度闸拒绝（不进 ECDSA 恢复）。
    function testSubmitSignalForRejectsWrongSignatureLength() public {
        UVPStateMachine machine = _registeredMachine(_emitReadyPositiveHookPlan(HOOK_INIT));
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidSignalSignatureLength.selector, 64));
        machine.submitSignalFor(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline,
            new bytes(64)
        , _noAttribution(), _noBinding());
    }

    /// outside 出生签名不匹配声明的 submitter：拒绝。
    function testTriggerOrderFromOutsideRejectsWrongSigner() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));

        UVPStateMachine.SignalAuthorization[] memory authorizations = _auths1(SIGNAL_TRIGGER, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, WRONG_SUBMITTER_PRIVATE_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidTriggerOrderSignature.selector,
                trigger.submitter,
                vm.addr(WRONG_SUBMITTER_PRIVATE_KEY)
            )
        );
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
    }

    /// Cancelled 是终态：后续事实到达与 timer 路径都不得复活 hook。
    function testCancelledHookStatusIsTerminal() public {
        UVPStateMachine machine = _newMachine();
        // ~VERIFY_FAIL & TRIGGER：提交 VERIFY_FAIL 即 Cancelled。
        _registerPlan(machine, _withOrderStart(_negativeHookPlan(HOOK_TIMEOUT)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "hook not cancelled");

        // 到达正向信号（原条件另一分支）不复活。
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        (status,, readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "cancelled hook resurrected");
        require(!readyEmitted, "cancelled hook emitted ready");

        // timer 路径同口径拒绝（非 Wait）。
        vm.expectRevert(UVPStateMachine.TimerNotWaiting.selector);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
    }

    /// 同秒并列不同提交者（无在任 patch 的回退判定）fail-closed：
    /// HANDOFF 的"上一执行者"没有确定序，直接拒绝。事实经 dock 写入口
    /// 落地（模块通道不做 executor 指派门），复现无 patch 多提交者形态。
    function testStageHandoffRejectsAmbiguousPreviousExecutor() public {
        UVPStateMachine machine;
        DockInputWriter writer;
        (machine, writer) = _newMachineWithDockingWriter();
        _registerPlan(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _overlaySignalCapabilities()
        );
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );
        // STAGE_AUDIT 物化（SIGNAL_INIT_CMP 令其 EMIT_READY hook Ready）。
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x9140))
        , _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());

        // capability 流事实（SUBMITTER_A）+ 回退流事实（SUBMITTER_B）：
        // 两流末位提交者不一致 → latestAmbiguous。
        writer.write(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, bytes32(uint256(0x9141)), SUBMITTER_A);
        writer.write(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_FALLBACK, bytes32(uint256(0x9142)), SUBMITTER_B);

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, SUBMITTER_A, bytes32(0), bytes32(0)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StagePreviousExecutorAmbiguous.selector,
                ORDER_ID,
                STAGE_AUDIT,
                uint64(block.timestamp)
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    /// mock 占据 docking 模块位（freeze 前装配）：dock 写入口是特权面，
    /// 测试用它落"无 patch 多提交者"形态（真实 docking 模块同入口同权限）。
    function _newMachineWithDockingWriter() private returns (UVPStateMachine machine, DockInputWriter writer) {
        machine = _newUnfrozenMachine();
        writer = new DockInputWriter(machine);
        machine.setDockingModule(address(writer));
        machine.freezeModules();
        _currentMachine = machine;
    }

    /// flags=0 watcher 所在阶段未物化时，模块写事实路径不回滚——
    /// 求值循环跳过（与回放 oracle 对齐）。阶段挂一条 EMIT_READY
    /// hook（依赖另一未到达信号）满足注册守卫，但阶段尚未物化。
    function testUnmaterializedStageWatcherIsSkippedNotBricked() public {
        UVPStateMachine machine = _newMachine();
        // STAGE_AUDIT：EMIT_READY 观察 hook（依赖 SIGNAL_AUDIT_PASS，未到达）
        // + 纯 flags=0 watcher（依赖 SIGNAL_TRIGGER——模块写入的事实）。
        UVPStateMachine.Instruction[] memory auditInstructions = new UVPStateMachine.Instruction[](1);
        auditInstructions[0] = _signal(SIGNAL_AUDIT_PASS);
        UVPStateMachine.Instruction[] memory watcherInstructions = new UVPStateMachine.Instruction[](1);
        watcherInstructions[0] = _signal(SIGNAL_TRIGGER);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _withOrderStart(_positiveHookPlan(HOOK_INIT, true))[0];
        hooks[1] = _hookWithFlags(
            HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, FLAG_EMIT_READY, auditInstructions, _deps(SIGNAL_AUDIT_PASS)
        );
        hooks[2] = _hookWithFlags(
            HOOK_ROLLBACK, STAGE_AUDIT, HOOK_NAME_FAILURE, 0, watcherInstructions, _deps(SIGNAL_TRIGGER)
        );
        _registerPlan(machine, hooks);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));

        // 模块写事实路径（submitSignalFromModule）：SIGNAL_TRIGGER 的
        // watcher 位于未物化的 STAGE_AUDIT——未物化阶段的 flags=0 watcher
        // 不进求值（直接跳过，不整笔回滚 UnknownHook）。该入口仅
        // docking 模块可调，不放行 derived 模块。
        vm.prank(address(_docking(machine)));
        machine.submitSignalFromModule(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this)
        , _noAttribution(), _noBinding());

        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "fact missing");
        // 跳过的 watcher runtime 保持未初始化（不物化、不观察）——getHookStatus
        // 本身会 UnknownHook，这正是"跳过"而非"求值"的证据；交易成功即断言。
    }

    /// 显式授权与 active executor patch 两维度独立——同一事实经
    /// 普通 submitSignal 与派生 submitDerivedSignalFromModule 两条路径都
    /// 放行（两条入口对同一事实结论一致）。
    function testExplicitAuthorizationExemptsExecutorPatchOnBothPaths() public {
        UVPStateMachine machine = _newMachine();
        // STAGE_AUDIT 需要是 plan 阶段（executor patch 目标），并持有两个
        // relation-0 输出能力（普通路径与派生路径各写一条事实）。
        UVPStateMachine.CompactHook[] memory planHooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](planHooks.length + 1);
        for (uint256 i = 0; i < planHooks.length; i++) {
            hooks[i] = planHooks[i];
        }
        hooks[planHooks.length] = _emitReadySignalHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_AUDIT_PASS);
        StageSelectorBinding[] memory bindings = _selectorBindings();
        SignalCapability[] memory capabilities = new SignalCapability[](4);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: PRODUCTION_SOURCE, signalId: PRODUCTION_SIGNAL, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        // 出生事实在词表内（编译器产物口径）。
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // STAGE_AUDIT 的推进驱动事实由出生阶段携出。
        capabilities[3] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_AUDIT_PASS, targetOrderRelation: 0
        });
        _registerPlan(machine, hooks, bindings, capabilities);

        // 显式授权 SUBMITTER_A 两条事实；测试合约自授权出生 + 审计触发事实。
        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](5);
        authorizations[0] = _authorization(SIGNAL_ORDER_START, address(this));
        authorizations[1] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        authorizations[2] = _stageAuthorization(PRODUCTION_SOURCE, PRODUCTION_SIGNAL, SUBMITTER_A);
        authorizations[3] = _authorization(SIGNAL_STAGE_DONE, SUBMITTER_A);
        authorizations[4] = _authorization(SIGNAL_AUDIT_PASS, address(this));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);

        // STAGE_AUDIT 触发事实到达 → 阶段物化（后续事实的源阶段门放行）。
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(0x9104))
        , _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS), _noBinding());

        // 阶段挂上 active executor patch（执行者是 SUBMITTER_B，非 SUBMITTER_A）。
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));

        // 路径 1：普通 submitSignal——显式授权豁免 executor 检查。
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            PRODUCTION_SOURCE,
            PRODUCTION_SIGNAL,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            _noBinding()
        );

        // 路径 2：另一事实经派生信号模块回写本单——豁免同口径（修复点）。
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest5 =
            _derivedSignalRequestWithPlans( ORDER_ID, STAGE_AUDIT, PLAN_ID, ORDER_ID, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(0x9102)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs5 = _derivedProofs(machine, derivedRequest5);
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest5, SUBMITTER_A, derivedProofs5);
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL), "explicit auth path 1 missing"
        );
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE), "explicit auth path 2 missing"
        );
    }

    /// relation=0 派生生产事实与普通 submitSignal 同口径过物化门 +
    /// executor 存在门——阶段未物化先拒（UnknownHook），selector-target 阶段
    /// 未 assign 再拒（否则显式授权者提前写入，StageAlreadyHasSignal 把
    /// assign 永久顶死）；assign 后同路径放行。
    function testDerivedRelationZeroPassesMaterializationAndAssignGates() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory planHooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](planHooks.length + 1);
        for (uint256 i = 0; i < planHooks.length; i++) {
            hooks[i] = planHooks[i];
        }
        hooks[planHooks.length] = _emitReadySignalHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_AUDIT_PASS);
        SignalCapability[] memory capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // STAGE_AUDIT 的推进驱动事实由出生阶段携出。
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_AUDIT_PASS, targetOrderRelation: 0
        });
        _registerPlan(machine, hooks, _selectorBindings(), capabilities);

        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](4);
        authorizations[0] = _authorization(SIGNAL_ORDER_START, address(this));
        authorizations[1] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        authorizations[2] = _authorization(SIGNAL_STAGE_DONE, SUBMITTER_A);
        authorizations[3] = _authorization(SIGNAL_AUDIT_PASS, address(this));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);

        // STAGE_AUDIT 未物化：relation=0 生产事实先撞物化门。
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest6 =
            _derivedSignalRequestWithPlans( ORDER_ID, STAGE_AUDIT, PLAN_ID, ORDER_ID, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(0x9110)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs6 = _derivedProofs(machine, derivedRequest6);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest6, SUBMITTER_A, derivedProofs6);

        // 物化 STAGE_AUDIT（EMIT_READY hook 消费 SIGNAL_AUDIT_PASS）。
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(0x9111))
        , _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS), _noBinding());

        // selector-target 阶段（STAGE_AUDIT）未 assign executor：显式授权者
        // 也不得提前写入生产事实。
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest7 =
            _derivedSignalRequestWithPlans( ORDER_ID, STAGE_AUDIT, PLAN_ID, ORDER_ID, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(0x9112)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs7 = _derivedProofs(machine, derivedRequest7);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest7, SUBMITTER_A, derivedProofs7);

        // 正向对照：assign 后同一路径放行。
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH), _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT));
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest8 =
            _derivedSignalRequestWithPlans( ORDER_ID, STAGE_AUDIT, PLAN_ID, ORDER_ID, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(0x9113)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs8 = _derivedProofs(machine, derivedRequest8);
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest8, SUBMITTER_A, derivedProofs8);
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE),
            "relation-0 derived signal missing after assign"
        );
    }

    /// dock output 通道（submitSignalFromModule 的 docking 分支）镜像
    /// mint 词表闸——capability 词表外的事实键拒绝，词表内放行。
    function testDockingModuleSignalVocabularyGate() public {
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory capabilities = new SignalCapability[](2);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // 空绑定：本用例钉词表闸，不挂 selector binding（finalize 边界拒绝
        // 引用 hooks 外阶段的悬空元数据）。
        _registerPlan(
            machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)), _emptySelectorBindings(), capabilities
        );
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));

        address docking = address(_docking(machine));
        // 词表内（relation-0 capability，出生阶段已物化）——放行。
        vm.prank(docking);
        machine.submitSignalFromModule(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9120)),
            address(this),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE),
            _noBinding()
        );
        // 词表外（SIGNAL_STAGE_REVIEW 未声明）——InvalidSignalCapability。
        vm.prank(docking);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW
            )
        );
        machine.submitSignalFromModule(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9121)),
            address(this)
        , _noAttribution(), _noBinding());
    }

    /// finalized 位先于 planMetadata 外调落定（CEI）——模块在回调里
    /// 重入 finalizePlan 必须按 PlanAlreadyFinalized 拒绝，不得在外调窗口
    /// 二次过门。
    function testFinalizePlanReentrantCallSeesFinalized() public {
        UVPStateMachine machine = new UVPStateMachine();
        ReenteringMetadataModule attacker = new ReenteringMetadataModule(machine);
        machine.setStagePatchModule(address(0xE1));
        machine.setDerivedSignalModule(address(0xE2));
        machine.setDockingModule(address(0xE3));
        machine.setPlanMetadataModule(address(attacker));
        machine.setOrderLinkModule(address(0xE5));
        machine.setLens(address(0xE6));
        machine.freezeModules();

        StageSelectorBinding[] memory bindings =
            new StageSelectorBinding[](0);
        SignalCapability[] memory capabilities = new SignalCapability[](0);
        bytes32 planId =
            _commitPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)), bindings, capabilities);

        vm.expectRevert(UVPStateMachine.PlanAlreadyFinalized.selector);
        machine.finalizePlan(planId);
    }

    /// 派生信号提交者的在任执行者检查豁免仅限 target 侧：from 侧订单上的
    /// 显式授权（即使按正确的业务事实键 (targetSourceId, signalId) 授予）
    /// 不构成豁免；target 侧显式授权同键放行。
    function testDerivedSignalFromSideExplicitAuthorizationDoesNotExempt() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine,
            _withOrderStart(_patchableSequentialPlan()),
            _selectorBindings(),
            _derivedActiveSignalCapabilities()
        );
        // 父单出生时不给 SUBMITTER_A 任何授权（先证明 from 侧豁免已收掉）。
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), _noBinding());
        // 子单（from 侧）出生授权：按业务源键显式授权 SUBMITTER_A 提交
        // (SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL)——from 侧授权存在但不豁免。
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest9 =
            _derivedSignalRequest( LINKED_ORDER_ID, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9103)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs9 = _derivedProofs(machine, derivedRequest9);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_VERIFY_FAIL,
                SUBMITTER_A
            )
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest9, SUBMITTER_A, derivedProofs9);

        // target 侧（父单）按同一业务事实键显式授权后放行——授权键仍是
        // source id（source id ≠ stage id），不塞 stageId 进 sourceId 槽。
        UVPStateMachine machine2 = _newMachine();
        _registerPlan(
            machine2,
            _withOrderStart(_patchableSequentialPlan()),
            _selectorBindings(),
            _derivedActiveSignalCapabilities()
        );
        UVPStateMachine.SignalAuthorization[] memory defaultAuths = _defaultAuthorizations(address(this));
        UVPStateMachine.SignalAuthorization[] memory parentAuths =
            new UVPStateMachine.SignalAuthorization[](defaultAuths.length + 1);
        for (uint256 i = 0; i < defaultAuths.length; i++) {
            parentAuths[i] = defaultAuths[i];
        }
        parentAuths[defaultAuths.length] = _authorization(SIGNAL_VERIFY_FAIL, SUBMITTER_A);
        _submitTriggerOrderFromOutside(machine2, PLAN_ID, ORDER_CREATOR, parentAuths);
        machine2.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _factAttribution(machine2, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), _noBinding());
        _triggerOrderFromSignalRequest(
            machine2,
            _signalTriggerRequest(machine2, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest10 =
            _derivedSignalRequest( LINKED_ORDER_ID, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9103)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs10 = _derivedProofs(machine2, derivedRequest10);
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine2).submitDerivedSignal(derivedRequest10, SUBMITTER_A, derivedProofs10);
        require(
            machine2.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL),
            "target-side explicit authorization must pass with the business source key"
        );
    }

    /// 一事一单：事实不在本 plan capability 词表内时拒绝铸单。
    function testTriggerOrderFromOutsideRejectsForeignFact() public {
        UVPStateMachine machine = _newMachine();
        // _signalCapabilities 声明 STAGE_AUDIT 侧词表——plan 需挂该阶段
        // hook（finalize 边界拒绝引用 hooks 外阶段的悬空 capability）。
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _signalCapabilities());

        UVPStateMachine.SignalAuthorization[] memory authorizations = _defaultAuthorizations(address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        trigger.sourceId = keccak256("foreign-source");
        trigger.signalId = keccak256("foreign.signal");
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, trigger.sourceId, trigger.signalId
            )
        );
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
    }

    /// E16（同一 relation=0 键唯一属主）移至编译器层不变量：链上 Merkle 形态
    /// 不再拒绝同键跨阶段的重复属主声明——commit/finalize 照常完成，两条
    /// 能力叶都能携证 verify 通过。
    function testDuplicateCurrentOrderFactCapabilityAcrossStagesIsRejected() public {
        UVPStateMachine machine = _newMachine();
        // 双阶段 plan：重复声明需要两个真实阶段。
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_sequentialPlan());
        StageSelectorBinding[] memory bindings =
            new StageSelectorBinding[](0);
        SignalCapability[] memory capabilities = new SignalCapability[](2);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: PRODUCTION_SOURCE, signalId: PRODUCTION_SIGNAL, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: PRODUCTION_SOURCE, signalId: PRODUCTION_SIGNAL, targetOrderRelation: 0
        });

        bytes32 planId = _commitPlan(machine, hooks, bindings, capabilities);
        machine.finalizePlan(planId);
        require(machine.planExists(planId), "duplicate-owner tree must finalize");

        bytes32[] memory sortedLeaves = _capabilityTables[address(machine)][planId].sortedLeaves;
        bytes32 initLeaf =
            keccak256(abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_INIT, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, uint256(0)));
        bytes32 auditLeaf =
            keccak256(abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_AUDIT, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, uint256(0)));
        require(
            _planMetadata(machine).verifySignalCapability(
                planId, STAGE_INIT, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, 0, _merkleProofFor(sortedLeaves, initLeaf)
            ),
            "init owner leaf must verify"
        );
        require(
            _planMetadata(machine).verifySignalCapability(
                planId, STAGE_AUDIT, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, 0, _merkleProofFor(sortedLeaves, auditLeaf)
            ),
            "audit owner leaf must verify"
        );
    }

    /// 委托授权的 executor 与查询 submitter 不匹配时返回空值，
    /// 不回退到委托记录的 role/metadataHash。
    function testGetSignalAuthorizationReturnsEmptyForDelegatedExecutorMismatch() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        // 无任何授权存在时返回全空。
        (bool exists, bytes32 role, bytes32 metadataHash) =
            machine.getSignalAuthorization(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, SUBMITTER_A);
        require(!exists, "empty lookup must report missing");
        require(role == bytes32(0) && metadataHash == bytes32(0), "empty lookup must return zero values");
    }

    function testTriggerOrderWithoutAuthorizationsDoesNotOpenSignalSubmission() public {
        UVPStateMachine machine = _newMachine();

        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, new UVPStateMachine.SignalAuthorization[](0));

        require(
            !machine.isSignalSubmitterAuthorized(
                PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER
            ),
            "order unexpectedly open"
        );
        (bool authExists,,) =
            machine.getSignalAuthorization(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER);
        require(!authExists, "order created explicit authorization");

        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_TRIGGER,
                UNAUTHORIZED_SUBMITTER
            )
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
    }

    function _registeredMachine(UVPStateMachine.CompactHook[] memory hooks) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlan(machine, _withOrderStart(hooks));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
    }

    function _registerPlan(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (bytes32 planId)
    {
        return _registerPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    function _registerPlan(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities
    ) private returns (bytes32 planId) {
        planId = _commitPlan(machine, hooks, selectorBindings, signalCapabilities);
        machine.finalizePlan(planId);
    }

    function _commitPlan(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities
    ) private returns (bytes32 planId) {
        return _commitPlanWithKey(machine, hooks, selectorBindings, signalCapabilities, PUBLISHER_PRIVATE_KEY);
    }

    function _registerPlanWithKey(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        uint256 publisherPrivateKey
    ) private returns (bytes32 planId) {
        planId = _commitPlanWithKey(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0),
            publisherPrivateKey
        );
        machine.finalizePlan(planId);
    }

    function _commitPlanWithKey(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        uint256 publisherPrivateKey
    ) private returns (bytes32 planId) {
        address publisher = vm.addr(publisherPrivateKey);
        bytes32[] memory leaves = _capabilityLeaves(selectorBindings, signalCapabilities);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(leaves),
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherPrivateKey, digest);
        planId = machine.commitPlan(commit, hooks, _packedSignature(v, r, s));
        PLAN_ID = planId;
        _planIds[address(machine)] = planId;
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        tables.bindings = selectorBindings;
        tables.capabilities = signalCapabilities;
        tables.sortedLeaves = _sortedUnique(leaves);
    }

    // ------------------------------------------------------------------
    // 能力树测试基建：叶子/树/证明与属主解析（镜像 DockMerkle 与
    // UVPPlanMetadataModule 的叶子公式，供测试构造携证调用）。
    // ------------------------------------------------------------------

    struct CapabilityTables {
        StageSelectorBinding[] bindings;
        SignalCapability[] capabilities;
        bytes32[] sortedLeaves;
    }

    mapping(address machine => mapping(bytes32 planId => CapabilityTables tables)) private _capabilityTables;

    function _capabilityLeaves(
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities
    ) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](selectorBindings.length + signalCapabilities.length);
        for (uint256 i = 0; i < selectorBindings.length; i++) {
            leaves[i] = keccak256(
                abi.encode(
                    SELECTOR_BINDING_LEAF_DOMAIN,
                    selectorBindings[i].selectorStageId,
                    selectorBindings[i].targetStageId
                )
            );
        }
        for (uint256 i = 0; i < signalCapabilities.length; i++) {
            leaves[selectorBindings.length + i] = keccak256(
                abi.encode(
                    SIGNAL_CAPABILITY_LEAF_DOMAIN,
                    signalCapabilities[i].stageId,
                    signalCapabilities[i].targetSourceId,
                    signalCapabilities[i].signalId,
                    uint256(signalCapabilities[i].targetOrderRelation)
                )
            );
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
        require(index != type(uint256).max, "test: leaf not in tree");
        bytes32[] memory buffer = new bytes32[](256);
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

    /// 按测试登记的能力表构造 (sourceId, signalId) 的 relation=0 属主自证；
    /// 词表内无该键时返回零声明（词表外口径）。
    function _factAttribution(UVPStateMachine machine, bytes32 planId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (UVPStateMachine.FactAttribution memory attribution)
    {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        for (uint256 i = 0; i < tables.capabilities.length; i++) {
            SignalCapability storage capability = tables.capabilities[i];
            if (
                capability.targetOrderRelation == 0 && capability.targetSourceId == sourceId
                    && capability.signalId == signalId
            ) {
                bytes32 leaf = keccak256(
                    abi.encode(
                        SIGNAL_CAPABILITY_LEAF_DOMAIN,
                        capability.stageId,
                        capability.targetSourceId,
                        capability.signalId,
                        uint256(0)
                    )
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

    /// 任意一条指向 targetStageId 的绑定的成员资格证明；无绑定时返回零证。
    function _selectorBindingFor(UVPStateMachine machine, bytes32 planId, bytes32 targetStageId)
        private
        view
        returns (UVPStateMachine.SelectorBindingProof memory bindingProof)
    {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        for (uint256 i = 0; i < tables.bindings.length; i++) {
            if (tables.bindings[i].targetStageId == targetStageId) {
                bytes32 leaf = keccak256(
                    abi.encode(
                        SELECTOR_BINDING_LEAF_DOMAIN, tables.bindings[i].selectorStageId, tables.bindings[i].targetStageId
                    )
                );
                return UVPStateMachine.SelectorBindingProof({
                    selectorStageId: tables.bindings[i].selectorStageId,
                    proof: _merkleProofFor(tables.sortedLeaves, leaf)
                });
            }
        }
        return _noBinding();
    }

    /// patch/derived 模块入口按 IUVPStateMachineCore.SelectorBindingProof
    /// 收证（与主合约结构体字段同构、类型不同源）——包一层逐字段转换。
    function _moduleBindingFor(UVPStateMachine machine, bytes32 planId, bytes32 targetStageId)
        private
        view
        returns (IUVPStateMachineCore.SelectorBindingProof memory)
    {
        UVPStateMachine.SelectorBindingProof memory binding = _selectorBindingFor(machine, planId, targetStageId);
        return IUVPStateMachineCore.SelectorBindingProof({selectorStageId: binding.selectorStageId, proof: binding.proof});
    }

    /// 目标阶段全部 relation=0 能力事实的携证清单（patch 治理供表）。
    function _stageCapabilityFacts(UVPStateMachine machine, bytes32 planId, bytes32 stageId)
        private
        view
        returns (UVPStagePatchModule.StageCapabilityFact[] memory facts)
    {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        UVPStagePatchModule.StageCapabilityFact[] memory buffer =
            new UVPStagePatchModule.StageCapabilityFact[](tables.capabilities.length);
        uint256 count;
        for (uint256 i = 0; i < tables.capabilities.length; i++) {
            SignalCapability storage capability = tables.capabilities[i];
            if (capability.stageId != stageId || capability.targetOrderRelation != 0) {
                continue;
            }
            bytes32 leaf = keccak256(
                abi.encode(
                    SIGNAL_CAPABILITY_LEAF_DOMAIN, capability.stageId, capability.targetSourceId, capability.signalId, uint256(0)
                )
            );
            buffer[count++] = UVPStagePatchModule.StageCapabilityFact({
                sourceId: capability.targetSourceId,
                signalId: capability.signalId,
                capabilityProof: _merkleProofFor(tables.sortedLeaves, leaf)
            });
        }
        facts = new UVPStagePatchModule.StageCapabilityFact[](count);
        for (uint256 i = 0; i < count; i++) {
            facts[i] = buffer[i];
        }
    }

    /// 仅声明出生事实的最小词表：给挂了 selector binding（树非空 → 词表闸
    /// 生效）的 plan 用——出生事实按编译器口径声明为出生阶段的 relation=0
    /// capability，目标阶段（STAGE_AUDIT）保持零 relation-0 能力。
    function _birthSignalCapabilities() private pure returns (SignalCapability[] memory capabilities) {
        capabilities = new SignalCapability[](1);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            targetOrderRelation: 0
        });
    }

    /// 按测试登记表取任意能力叶的 membership proof；叶不在树内返回空数组
    /// （验证必败，供负例使用）。
    function _capabilityProofFor(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 stageId,
        bytes32 sourceId,
        bytes32 signalId,
        uint8 relation
    ) private view returns (bytes32[] memory proof) {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        bytes32 leaf = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, stageId, sourceId, signalId, uint256(relation))
        );
        for (uint256 i = 0; i < tables.sortedLeaves.length; i++) {
            if (tables.sortedLeaves[i] == leaf) {
                return _merkleProofFor(tables.sortedLeaves, leaf);
            }
        }
        return new bytes32[](0);
    }

    /// 派生信号提交的三份证明：relation 镜像模块判定（from==target 即 0，
    /// 否则查 order-link 关系；link 缺失按 1 造空证，让模块按
    /// UnknownOrderTriggerLink 拒绝）；from 侧能力叶恒需，relation!=0 时
    /// target 侧同款另需；selector 绑定证按 from 阶段取（relation=0 的
    /// assign 前置闸判定材料）。
    function _derivedProofs(UVPStateMachine machine, UVPDerivedSignalModule.DerivedSignalRequest memory request)
        private
        view
        returns (UVPDerivedSignalModule.DerivedSignalProofs memory proofs)
    {
        uint8 relation = 0;
        if (!(request.fromPlanId == request.targetPlanId && request.fromOrderId == request.targetOrderId)) {
            try _orderLink(machine).targetOrderRelation(
                request.fromPlanId, request.fromOrderId, request.targetPlanId, request.targetOrderId
            ) returns (uint8 linkedRelation) {
                relation = linkedRelation;
            } catch {
                relation = 1;
            }
        }
        proofs.fromCapabilityProof =
            _capabilityProofFor(machine, request.fromPlanId, request.fromStageId, request.targetSourceId, request.signalId, relation);
        if (relation != 0) {
            proofs.targetCapabilityProof = _capabilityProofFor(
                machine, request.targetPlanId, request.fromStageId, request.targetSourceId, request.signalId, relation
            );
        }
        UVPStateMachine.SelectorBindingProof memory fromBinding =
            _selectorBindingFor(machine, request.fromPlanId, request.fromStageId);
        proofs.selectorBinding =
            IUVPStateMachineCore.SelectorBindingProof({selectorStageId: fromBinding.selectorStageId, proof: fromBinding.proof});
    }

    function _registeredOverlayMachine(address selector, address executor) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlan(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _overlaySignalCapabilities()
        );
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(selector, executor, SUBMITTER_B)
        );
        vm.prank(selector);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x9101))
        , _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());
    }

    function _activateInitialStageExecutor(UVPStateMachine machine, address selector, address executor) private {
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, executor, PATCH_HASH);
        if (selector == address(this)) {
            _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
            return;
        }
        vm.prank(selector);
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function _newMachine() private returns (UVPStateMachine machine) {
        machine = _newUnfrozenMachine();
        machine.freezeModules();
        _currentMachine = machine;
    }

    function _newUnfrozenMachine() private returns (UVPStateMachine) {
        UVPStateMachine machine = new UVPStateMachine();
        UVPStagePatchModule stagePatch = new UVPStagePatchModule(address(machine));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(machine));
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(machine));
        UVPDockingModule docking = new UVPDockingModule(address(machine), address(planMetadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(machine));
        _stagePatchModules[address(machine)] = stagePatch;
        _derivedSignalModules[address(machine)] = derivedSignal;
        _dockingModules[address(machine)] = docking;
        _planMetadataModules[address(machine)] = planMetadata;
        _orderLinkModules[address(machine)] = orderLink;
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(derivedSignal));
        machine.setDockingModule(address(docking));
        machine.setPlanMetadataModule(address(planMetadata));
        machine.setOrderLinkModule(address(orderLink));
        machine.setLens(address(0x1234));
        return machine;
    }

    function _stagePatch(UVPStateMachine machine) private view returns (UVPStagePatchModule) {
        return _stagePatchModules[address(machine)];
    }

    function _derivedSignal(UVPStateMachine machine) private view returns (UVPDerivedSignalModule) {
        return _derivedSignalModules[address(machine)];
    }

    function _docking(UVPStateMachine machine) private view returns (UVPDockingModule) {
        return _dockingModules[address(machine)];
    }

    function _planMetadata(UVPStateMachine machine) private view returns (UVPPlanMetadataModule) {
        return _planMetadataModules[address(machine)];
    }

    function _orderLink(UVPStateMachine machine) private view returns (UVPOrderLinkModule) {
        return _orderLinkModules[address(machine)];
    }

    function _defaultAuthorizations(address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](4);
        authorizations[0] = _authorization(SIGNAL_TRIGGER, submitter);
        authorizations[1] = _authorization(SIGNAL_INIT_CMP, submitter);
        authorizations[2] = _authorization(SIGNAL_AUDIT_PASS, submitter);
        authorizations[3] = _authorization(SIGNAL_VERIFY_FAIL, submitter);
    }

    function _auths1(bytes32 signalId, address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](1);
        authorizations[0] = _authorization(signalId, submitter);
    }

    function _auths2SameSignal(bytes32 signalId, address submitterA, address submitterB)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _authorization(signalId, submitterA);
        authorizations[1] = _authorization(signalId, submitterB);
    }

    function _auths3ForSubmitter(
        bytes32 firstSignalId,
        bytes32 secondSignalId,
        bytes32 thirdSignalId,
        address submitter
    ) private pure returns (UVPStateMachine.SignalAuthorization[] memory authorizations) {
        authorizations = new UVPStateMachine.SignalAuthorization[](3);
        authorizations[0] = _authorization(firstSignalId, submitter);
        authorizations[1] = _authorization(secondSignalId, submitter);
        authorizations[2] = _authorization(thirdSignalId, submitter);
    }

    function _splitSignalAuths(
        bytes32 firstSignalId,
        address firstSubmitter,
        bytes32 secondSignalId,
        address secondSubmitter
    ) private pure returns (UVPStateMachine.SignalAuthorization[] memory authorizations) {
        authorizations = new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _authorization(firstSignalId, firstSubmitter);
        authorizations[1] = _authorization(secondSignalId, secondSubmitter);
    }

    function _overlayAuthorizations(address selector, address executor, address alternateExecutor)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](8);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, selector);
        authorizations[1] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, executor);
        authorizations[2] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, alternateExecutor);
        authorizations[3] = _stageAuthorization(STAGE_INIT, RESOURCE_PATCH_SIGNAL_ID, selector);
        authorizations[4] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_REVIEW, executor);
        authorizations[5] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_REVIEW, alternateExecutor);
        authorizations[6] = _stageAuthorization(STAGE_INIT, SIGNAL_AUDIT_PASS, selector);
        authorizations[7] = _authorization(SIGNAL_INIT_CMP, selector);
    }

    function _stagePatchSelectorAuthorizations(address selector)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](1);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, selector);
    }

    function _dockedLocalAuthorizations(address selector)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](1);
        authorizations[0] = _stageAuthorization(STAGE_INIT, DOCKED_ORDER_LINK_SIGNAL_ID, selector);
    }

    function _stageSignalAuths(bytes32 sourceId, bytes32 signalId, address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](1);
        authorizations[0] = _stageAuthorization(sourceId, signalId, submitter);
    }

    function _triggeredDerivedSignalAuths(address submitter)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _authorization(SIGNAL_TRIGGER, submitter);
        // C5：from 侧显式授权按业务事实键 (sourceId, signalId) 授予——显式
        // 授权一律以 source id 为键（source id ≠ stage id）。
        authorizations[1] = _authorization(SIGNAL_VERIFY_FAIL, submitter);
    }

    function _targetSignalAuthorizations(address executor, address alternateExecutor)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, executor);
        authorizations[1] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, alternateExecutor);
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

    function _stageAuthorization(bytes32 sourceId, bytes32 signalId, address submitter)
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

    function _stageExecutorPatch(uint256 patchNonce, address executor, bytes32 patchHash)
        private
        pure
        returns (UVPStagePatchModule.StageExecutorPatch memory)
    {
        return _stageExecutorPatchWithMode(
            patchNonce, executor, patchHash, EXECUTOR_PATCH_MODE_ASSIGN, address(0), bytes32(0), bytes32(0)
        );
    }

    function _stageExecutorPatchWithMode(
        uint256 patchNonce,
        address executor,
        bytes32 patchHash,
        bytes32 mode,
        address previousExecutor,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId
    ) private pure returns (UVPStagePatchModule.StageExecutorPatch memory) {
        return UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: STAGE_INIT,
            targetStageId: STAGE_AUDIT,
            executor: executor,
            role: ROLE_EXECUTOR,
            executorMetadataHash: EXECUTOR_METADATA_HASH,
            mode: mode,
            previousExecutor: previousExecutor,
            approvalSourceId: approvalSourceId,
            approvalSignalId: approvalSignalId,
            patchHash: patchHash,
            patchNonce: patchNonce,
            metadataURI: "uvp-eth://executor-patch"
        });
    }

    function _stageResourcePatch(uint256 patchNonce, bytes32 patchHash)
        private
        pure
        returns (UVPStagePatchModule.StageResourcePatch memory)
    {
        return _stageResourcePatchWithKey(RESOURCE_KEY, patchNonce, patchHash);
    }

    function _stageResourcePatchWithKey(bytes32 resourceKey, uint256 patchNonce, bytes32 patchHash)
        private
        pure
        returns (UVPStagePatchModule.StageResourcePatch memory)
    {
        return UVPStagePatchModule.StageResourcePatch({
            selectorStageId: STAGE_INIT,
            targetStageId: STAGE_AUDIT,
            resourceKey: resourceKey,
            manifestHash: MANIFEST_HASH,
            policyHash: RESOURCE_POLICY_HASH,
            patchHash: patchHash,
            patchNonce: patchNonce,
            manifestURI: "ipfs://resource-manifest"
        });
    }

    function _packedSignature(uint8 v, bytes32 r, bytes32 s) private pure returns (bytes memory) {
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _submitTriggerOrderFromOutside(
        UVPStateMachine machine,
        bytes32 planId,
        address creator,
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private {
        _submitTriggerOrderFromOutsideWithKey(machine, planId, creator, authorizations, SUBMITTER_PRIVATE_KEY);
    }

    function _submitTriggerOrderFromOutsideWithKey(
        UVPStateMachine machine,
        bytes32 planId,
        address creator,
        UVPStateMachine.SignalAuthorization[] memory authorizations,
        uint256 submitterPrivateKey
    ) private {
        address submitter = vm.addr(submitterPrivateKey);
        // 一事一单：orderId 由合约按事实派生，本地镜像同一公式刷新测试常量。
        ORDER_ID = bytes32(
            uint256(keccak256(abi.encode(planId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH)))
                & ~uint256(1 << 255)
        );
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: planId,
            creator: creator,
            triggerHookId: HOOK_ORDER_START,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: submitter,
            deadline: block.timestamp + 1 hours
        });
        _submitTriggerOrderFromOutsideRequest(machine, trigger, authorizations, submitterPrivateKey);
    }

    /// 一事一单变体：同一 plan 下第二个出生订单需要不同事实（不同
    /// payloadHash 即不同派生 id）。
    function _submitTriggerOrderFromOutsideWithPayload(
        UVPStateMachine machine,
        bytes32 planId,
        address creator,
        bytes32 payloadHash,
        UVPStateMachine.SignalAuthorization[] memory authorizations,
        uint256 submitterPrivateKey
    ) private {
        address submitter = vm.addr(submitterPrivateKey);
        ORDER_ID = bytes32(
            uint256(keccak256(abi.encode(planId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, payloadHash)))
                & ~uint256(1 << 255)
        );
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: planId,
            creator: creator,
            triggerHookId: HOOK_ORDER_START,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: payloadHash,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: submitter,
            deadline: block.timestamp + 1 hours
        });
        _submitTriggerOrderFromOutsideRequest(machine, trigger, authorizations, submitterPrivateKey);
    }

    function _outsideTriggerRequest(bytes32 triggerHookId, bytes32 signalId)
        private
        returns (UVPStateMachine.TriggerOrderFromOutsideRequest memory)
    {
        // 镜像 triggerOrderIdFor：出生单号恒清 dock 命名空间最高位。
        ORDER_ID = bytes32(
            uint256(keccak256(abi.encode(PLAN_ID, SOURCE_BOOTSTRAP, signalId, PAYLOAD_HASH))) & ~uint256(1 << 255)
        );
        return UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: PLAN_ID,
            creator: ORDER_CREATOR,
            triggerHookId: triggerHookId,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: signalId,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: block.timestamp + 1 hours
        });
    }

    function _submitTriggerOrderFromOutsideRequest(
        UVPStateMachine machine,
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory authorizations,
        uint256 submitterPrivateKey
    ) private {
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, submitterPrivateKey);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId));
    }

    function _triggerOrderFromOutsideSignature(
        UVPStateMachine machine,
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory authorizations,
        uint256 submitterPrivateKey
    ) private returns (bytes memory) {
        bytes32 authorizationsHash = _signalAuthorizationsHash(authorizations);
        bytes32 digest = _triggerOrderFromOutsideDigest(machine, trigger, authorizationsHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(submitterPrivateKey, digest);
        return _packedSignature(v, r, s);
    }

    function _derivedSignalRequest(
        bytes32 fromOrderId,
        bytes32 fromStageId,
        bytes32 targetOrderId,
        bytes32 targetSourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey
    ) private view returns (UVPDerivedSignalModule.DerivedSignalRequest memory) {
        return _derivedSignalRequestWithPlans(
            fromOrderId,
            fromStageId,
            PLAN_ID,
            targetOrderId,
            PLAN_ID,
            targetSourceId,
            signalId,
            payloadHash,
            idempotencyKey
        );
    }

    function _derivedSignalRequestWithPlans(
        bytes32 fromOrderId,
        bytes32 fromStageId,
        bytes32 fromPlanId,
        bytes32 targetOrderId,
        bytes32 targetPlanId,
        bytes32 targetSourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey
    ) private view returns (UVPDerivedSignalModule.DerivedSignalRequest memory) {
        return UVPDerivedSignalModule.DerivedSignalRequest({
            fromPlanId: fromPlanId,
            fromOrderId: fromOrderId,
            fromStageId: fromStageId,
            targetPlanId: targetPlanId,
            targetOrderId: targetOrderId,
            targetSourceId: targetSourceId,
            signalId: signalId,
            payloadHash: payloadHash,
            idempotencyKey: idempotencyKey
        });
    }

    function _signalTriggerRequest(UVPStateMachine machine, bytes32 triggerOriginOrderId, bytes32 idempotencyKey)
        private
        returns (IUVPStateMachineCore.TriggerOrderFromSignalRequest memory)
    {
        // orderId 由合约按 link 事实派生（0300 H-1），测试镜像同一公式。
        LINKED_ORDER_ID = machine.orderLinkOrderIdFor(
            PLAN_ID, PLAN_ID, triggerOriginOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH
        );
        return IUVPStateMachineCore.TriggerOrderFromSignalRequest({
            orderId: LINKED_ORDER_ID,
            planId: PLAN_ID,
            creator: ORDER_CREATOR,
            triggerOriginOrderId: triggerOriginOrderId,
            originPlanId: PLAN_ID,
            triggerHookId: HOOK_INIT,
            triggerStageId: STAGE_INIT,
            originSourceId: SOURCE_BOOTSTRAP,
            originSignalId: SIGNAL_TRIGGER,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: idempotencyKey,
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: block.timestamp + 1 hours
        });
    }

    function _triggerOrderFromSignalRequest(
        UVPStateMachine machine,
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private {
        IUVPStateMachineCore.SignalAuthorization[] memory moduleAuthorizations = _moduleAuthorizations(authorizations);
        bytes memory signature =
            _triggerOrderFromSignalSignature(machine, trigger, moduleAuthorizations, SUBMITTER_PRIVATE_KEY);
        _orderLink(machine).triggerOrderFromSignalFor(trigger, moduleAuthorizations, signature, new IUVPStateMachineCore.FactAttribution[](0));
    }

    function _triggerOrderFromSignalForKey(
        UVPStateMachine machine,
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger,
        IUVPStateMachineCore.SignalAuthorization[] memory moduleAuthorizations,
        uint256 submitterPrivateKey
    ) private {
        bytes memory signature =
            _triggerOrderFromSignalSignature(machine, trigger, moduleAuthorizations, submitterPrivateKey);
        _orderLink(machine).triggerOrderFromSignalFor(trigger, moduleAuthorizations, signature, new IUVPStateMachineCore.FactAttribution[](0));
    }

    function _triggerOrderFromSignalSignature(
        UVPStateMachine machine,
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger,
        IUVPStateMachineCore.SignalAuthorization[] memory authorizations,
        uint256 submitterPrivateKey
    ) private returns (bytes memory) {
        bytes32 authorizationsHash = _orderLink(machine).signalAuthorizationsHash(authorizations);
        bytes32 digest = _orderLink(machine).triggerOrderFromSignalDigest(trigger, authorizationsHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(submitterPrivateKey, digest);
        return _packedSignature(v, r, s);
    }

    function _signalSubmissionDigest(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNAL_SUBMISSION_TYPEHASH,
                planId,
                orderId,
                sourceId,
                signalId,
                payloadHash,
                idempotencyKey,
                submitter,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
    }

    function _signalAuthorizationsHash(UVPStateMachine.SignalAuthorization[] memory authorizations)
        private
        pure
        returns (bytes32)
    {
        bytes32 rollingHash = keccak256(abi.encode(authorizations.length));
        for (uint256 i = 0; i < authorizations.length; i++) {
            UVPStateMachine.SignalAuthorization memory authorization = authorizations[i];
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    authorization.sourceId,
                    authorization.signalId,
                    authorization.submitter,
                    authorization.role,
                    authorization.metadataHash
                )
            );
        }
        return rollingHash;
    }

    function _triggerOrderFromOutsideDigest(
        UVPStateMachine machine,
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        bytes32 authorizationsHash
    ) private view returns (bytes32) {
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
        return keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
    }

    function _stateMachineDomainSeparator(UVPStateMachine machine) private view returns (bytes32) {
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

    function _moduleAuthorizations(UVPStateMachine.SignalAuthorization[] memory authorizations)
        private
        pure
        returns (IUVPStateMachineCore.SignalAuthorization[] memory converted)
    {
        converted = new IUVPStateMachineCore.SignalAuthorization[](authorizations.length);
        for (uint256 i = 0; i < authorizations.length; i++) {
            converted[i] = IUVPStateMachineCore.SignalAuthorization({
                sourceId: authorizations[i].sourceId,
                signalId: authorizations[i].signalId,
                submitter: authorizations[i].submitter,
                role: authorizations[i].role,
                metadataHash: authorizations[i].metadataHash
            });
        }
    }

    function _withOrderStart(UVPStateMachine.CompactHook[] memory hooks)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory wrapped)
    {
        wrapped = new UVPStateMachine.CompactHook[](hooks.length + 1);
        wrapped[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        for (uint256 i = 0; i < hooks.length; i++) {
            wrapped[i + 1] = hooks[i];
        }
    }

    function _positiveHookPlan(bytes32 hookId, bool isTrigger)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _signalHook(hookId, STAGE_INIT, HOOK_NAME_TRIGGER, isTrigger, SIGNAL_TRIGGER);
    }

    /// EMIT_READY watcher 版本的单信号 hook——对齐编译器产物形态：mint
    /// 位只用于出生阶段（uvp-update-zhixu-v2.yaml：出生阶段 mint: per-fact，
    /// 其余阶段为普通订阅阶段）。普通信号提交只推进 watcher（§7.2 出生锚
    /// 订单归属：order-trigger hook 不再被普通提交求值）。
    function _emitReadyPositiveHookPlan(bytes32 hookId)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _emitReadySignalHook(hookId, STAGE_INIT, HOOK_NAME_TRIGGER, SIGNAL_TRIGGER);
    }

    function _timerHookPlan(bytes32 hookId, uint64 delaySeconds)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(delaySeconds);

        // 延时 hook 是下游执行 hook：order-trigger hook 内禁止 DELAY
        // （出生事实与创建同笔交易，Delay 必 Wait，出生路径永久 revert）。
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] =
            _hookWithFlags(hookId, STAGE_INIT, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER));
    }

    /// 否定取消语义用 EMIT_READY watcher 承载（mint 位只用于出生阶段）。
    function _negativeHookPlan(bytes32 hookId) private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _not();
        instructions[2] = _signal(SIGNAL_TRIGGER);
        instructions[3] = _and(2);

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            hookId,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_VERIFY_FAIL, SIGNAL_TRIGGER)
        );
    }

    function _sharedDependencyPlanWithNonTriggerFirst()
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_NON_TRIGGER, STAGE_INIT, HOOK_NAME_TIMEOUT, false, SIGNAL_TRIGGER);
        hooks[1] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
    }

    /// rollback 推进 hook 用 EMIT_READY watcher 承载（mint 位只用于出生
    /// 阶段；Ready 时物化 STAGE_ROLLBACK 的口径不变）。
    function _orRollbackPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _signal(SIGNAL_INIT_CMP);
        instructions[2] = _or(2);

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_ROLLBACK,
            STAGE_ROLLBACK,
            HOOK_NAME_FAILURE,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_VERIFY_FAIL, SIGNAL_INIT_CMP)
        );
    }

    function _sequentialPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] = _signalHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, true, SIGNAL_INIT_CMP);
        hooks[2] = _signalHook(HOOK_TIMEOUT, STAGE_AUDIT, HOOK_NAME_TIMEOUT, true, SIGNAL_AUDIT_PASS);
    }

    /// 同 _sequentialPlan 但全部为 EMIT_READY watcher——编译器产物里后续
    /// 阶段不是出生阶段，其推进 hook 不携带 mint 位；普通提交照常推进。
    function _watcherSequentialPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _emitReadySignalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, SIGNAL_TRIGGER);
        hooks[1] = _emitReadySignalHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_INIT_CMP);
        hooks[2] = _emitReadySignalHook(HOOK_TIMEOUT, STAGE_AUDIT, HOOK_NAME_TIMEOUT, SIGNAL_AUDIT_PASS);
    }

    /// patch 语义测试专用变体：STAGE_AUDIT 挂 EMIT_READY watcher（非出生
    /// 阶段），执行者可逐单 patch。出生阶段（挂 mint/dock trigger 的阶段）
    /// 的 executor patch 被合约拒绝（出生阶段执行者终生不可变），由
    /// testStageExecutorPatchForbiddenOnBirthStage 单独钉住。
    function _patchableSequentialPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] = _emitReadySignalHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_INIT_CMP);
        hooks[2] = _emitReadySignalHook(HOOK_TIMEOUT, STAGE_AUDIT, HOOK_NAME_TIMEOUT, SIGNAL_AUDIT_PASS);
    }

    function _emitReadySignalHook(bytes32 hookId, bytes32 stageId, bytes32 hookName, bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(signalId);
        return _hookWithFlags(hookId, stageId, hookName, FLAG_EMIT_READY, instructions, _deps(signalId));
    }

    function _selectorBindings()
        private
        pure
        returns (StageSelectorBinding[] memory selectorBindings)
    {
        selectorBindings = new StageSelectorBinding[](1);
        selectorBindings[0] =
            StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
    }

    function _signalCapabilities()
        private
        pure
        returns (SignalCapability[] memory capabilities)
    {
        capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_VERIFY_FAIL, targetOrderRelation: 1
        });
        // 出生事实在词表内（编译器产物中出生事实由发送阶段的 sendSignals
        // 声明为 relation=0 capability；镜像该口径）。
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // STAGE_INIT 推进 hook 的驱动事实由出生阶段携出。
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_TRIGGER, targetOrderRelation: 0
        });
    }

    function _overlaySignalCapabilities()
        private
        pure
        returns (SignalCapability[] memory capabilities)
    {
        capabilities = new SignalCapability[](5);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_REVIEW, targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // STAGE_AUDIT 的推进驱动事实由出生阶段携出（编译产物同口径：
        // 上游 sendSignals 声明为 relation=0 能力）。
        capabilities[3] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_INIT_CMP, targetOrderRelation: 0
        });
        // REPLACEMENT 批准事实：出生阶段 stage 键事实。
        capabilities[4] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: STAGE_INIT, signalId: SIGNAL_AUDIT_PASS, targetOrderRelation: 0
        });
    }

    function _productionOverlaySignalCapabilities()
        private
        pure
        returns (SignalCapability[] memory capabilities)
    {
        capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: PRODUCTION_SOURCE, signalId: PRODUCTION_SIGNAL, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // STAGE_AUDIT 的推进驱动事实由出生阶段携出。
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_INIT_CMP, targetOrderRelation: 0
        });
    }

    function _derivedActiveSignalCapabilities()
        private
        pure
        returns (SignalCapability[] memory capabilities)
    {
        capabilities = new SignalCapability[](4);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_VERIFY_FAIL, targetOrderRelation: 1
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: PRODUCTION_SOURCE, signalId: PRODUCTION_SIGNAL, targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // STAGE_INIT 推进 hook 的驱动事实由出生阶段携出。
        capabilities[3] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_TRIGGER, targetOrderRelation: 0
        });
    }

    function _emptySignalCapabilities()
        private
        pure
        returns (SignalCapability[] memory capabilities)
    {
        capabilities = new SignalCapability[](0);
    }

    function _duplicateSelectorBindings()
        private
        pure
        returns (StageSelectorBinding[] memory selectorBindings)
    {
        selectorBindings = new StageSelectorBinding[](2);
        selectorBindings[0] =
            StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
        selectorBindings[1] =
            StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
    }

    function _emptySelectorBindings()
        private
        pure
        returns (StageSelectorBinding[] memory selectorBindings)
    {
        selectorBindings = new StageSelectorBinding[](0);
    }

    function _signalHook(bytes32 hookId, bytes32 stageId, bytes32 hookName, bool isTrigger, bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(signalId);
        return _hook(hookId, stageId, hookName, isTrigger, instructions, _deps(signalId));
    }

    function _hook(
        bytes32 hookId,
        bytes32 stageId,
        bytes32 hookName,
        bool isTrigger,
        UVPStateMachine.Instruction[] memory instructions,
        bytes32[] memory dependencyKeys
    ) private pure returns (UVPStateMachine.CompactHook memory) {
        // 编译器同口径：order-trigger hook 恒携带 EMIT_READY（mint=5 /
        // dock=6）。畸形 flags 形态（如沉默 trigger）用 _hookWithFlags
        // 显式构造，不走本 helper。
        return _hookWithFlags(
            hookId,
            stageId,
            hookName,
            isTrigger ? uint8(FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY) : uint8(0),
            instructions,
            dependencyKeys
        );
    }

    function _hookWithFlags(
        bytes32 hookId,
        bytes32 stageId,
        bytes32 hookName,
        uint8 flags,
        UVPStateMachine.Instruction[] memory instructions,
        bytes32[] memory dependencyKeys
    ) private pure returns (UVPStateMachine.CompactHook memory) {
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: hookName,
            flags: flags,
            instructions: instructions,
            dependencyKeys: dependencyKeys
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

    function _or(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Or),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
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

    function _deps(bytes32 signalId) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId));
    }

    function _deps2(bytes32 left, bytes32 right) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](2);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, left));
        deps[1] = keccak256(abi.encode(SOURCE_BOOTSTRAP, right));
    }

    function _deps3(bytes32 a, bytes32 b, bytes32 c) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](3);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, a));
        deps[1] = keccak256(abi.encode(SOURCE_BOOTSTRAP, b));
        deps[2] = keccak256(abi.encode(SOURCE_BOOTSTRAP, c));
    }

    function _countHookReady(Vm.Log[] memory logs) private pure returns (uint256 count) {
        bytes32 topic = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count++;
            }
        }
    }

    function _countSignalSubmitterAuthorized(Vm.Log[] memory logs) private pure returns (uint256 count) {
        bytes32 topic = keccak256("SignalSubmitterAuthorized(bytes32,bytes32,bytes32,bytes32,address,bytes32,bytes32)");
        return _countTopic(logs, topic);
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count++;
            }
        }
    }

    function testOrDelayAnchorsOnEarliestReceivedSignal() public {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(bytes32(uint256(0x4002)));
        instructions[2] = _or(2);
        instructions[3] = _delay(5);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        // 延时 hook 用 EMIT_READY（非 order-trigger）——trigger hook 内禁止 DELAY。
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_TRIGGER, bytes32(uint256(0x4002)))
        );

        UVPStateMachine machine = _registeredMachine(hooks);

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status, uint64 dueAt,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "expected wait until due");
        require(dueAt == 105, "dueAt must anchor on earliest arrival: 100+5");

        vm.warp(104);
        vm.expectRevert(UVPStateMachine.TimerNotDue.selector);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);

        vm.warp(105);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "ready at earliest anchor + delay");

        vm.warp(200);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, bytes32(uint256(0x4002)), PAYLOAD_HASH, bytes32(uint256(0x4003))
        , _noAttribution(), _noBinding());
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "late branch must not regress ready");
    }

    function testOrCompositeDelayAnchorsOnEarliestMaturingBranch() public {
        // OR 分歧形态（对齐 uvp-core 单测
        // or_composite_delay_anchors_on_earliest_maturing_branch 与语料
        // evalCases）：`(A & B) | C` 且 min(A,B) 接收 < C 接收 ≤ max(A,B)
        // 接收时，AND 分支的成熟时刻 = max(A,B)，最早成熟的是 C 分支——外层
        // Delay 必须锚定 C 的成熟时刻（C 到达时刻）。若按"最早接收"选支，
        // 会选 A 所在的 AND 分支、以 max(A,B) 计时，给出更晚的 dueAt。
        //
        // 时序镜像 Rust 侧数值：A@10、C@40、B@60，+10s → dueAt=50，
        // 在 B 到来前（AND 分支最早 60 才成熟）就必须 ready。
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](6);
        instructions[0] = _signal(SIGNAL_TRIGGER); // A
        instructions[1] = _signal(SIGNAL_INIT_CMP); // B
        instructions[2] = _and(2);
        instructions[3] = _signal(SIGNAL_AUDIT_PASS); // C
        instructions[4] = _or(2);
        instructions[5] = _delay(10);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        // 延时 hook 用 EMIT_READY（非 order-trigger）——trigger hook 内禁止 DELAY。
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps3(SIGNAL_TRIGGER, SIGNAL_INIT_CMP, SIGNAL_AUDIT_PASS)
        );

        UVPStateMachine machine = _registeredMachine(hooks);

        // A（最早接收）先到：AND 分支未成熟（B 缺席），C 亦缺席——无锚点。
        vm.warp(10);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        (UVPStateMachine.HookStatus status, uint64 dueAt,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Init, "no mature branch before C arrives");
        require(dueAt == 0, "no due date before any branch matures");

        // C@40 到达：只有 C 分支成熟（AND 仍等 B），OR 取 C 的成熟时刻，
        // +10s → dueAt=50。若按"最早接收"选 A/AND 支，dueAt 最早也得
        // max(A,B)+10 ≥ 70——50 是分歧锚点。
        vm.warp(40);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(0x4005))
        , _noAttribution(), _noBinding());
        (status, dueAt,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "must wait on C maturity + delay");
        require(dueAt == 50, "delay must anchor on C maturity: 40+10");

        // 观察时刻 45（镜像 Rust 侧 00:00:45 的 Wait 断言）：未到 50 不放行。
        vm.warp(45);
        vm.expectRevert(UVPStateMachine.TimerNotDue.selector);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);

        // 50 就绪——早于 AND 分支任何可能的成熟时刻（B 60 才到）。
        vm.warp(50);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "ready at C maturity + delay");

        // B@60 迟到：AND 分支此刻成熟（max=60），但不得回归已就绪状态。
        vm.warp(60);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x4004))
        , _noAttribution(), _noBinding());
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "late AND maturity must not regress ready");
    }

    function testChainedDelayAnchorsOnMaturityMoment() public {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(1);
        instructions[2] = _delay(5);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        // 延时 hook 用 EMIT_READY（非 order-trigger）——trigger hook 内禁止 DELAY。
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT, STAGE_INIT, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER)
        );

        UVPStateMachine machine = _registeredMachine(hooks);

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        (UVPStateMachine.HookStatus status, uint64 dueAt,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "inner delay must wait first");
        require(dueAt == 101, "inner due at arrival+1");

        vm.warp(101);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        (status, dueAt,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "outer delay chains after maturity");
        require(dueAt == 106, "outer due at 101+5: anchor advanced to maturity moment");

        vm.warp(106);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "ready at chained total");
    }

    function testCommitPlanRejectsCrossStageSharedDependencyKey() public {
        UVPStateMachine machine = _newUnfrozenMachine();
        machine.freezeModules();

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] = _signalHook(bytes32(uint256(0x9002)), STAGE_AUDIT, bytes32("WATCHER"), false, SIGNAL_TRIGGER);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.CrossStageDependency.selector, keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TRIGGER))
            )
        );
        _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    /// 依赖键注册判重 O(n) 化（读已落库 dependencyIndex 判重取代 memory 全
    /// 表线性扫描）：大量互异 dependencyKeys 的 plan 在常规 gas 内可注册，
    /// 键按 hook 完整落库（planHookDependsOn 可查）。
    function testCommitPlanRegistersManyDistinctDependencyKeys() public {
        UVPStateMachine machine = _newMachine();
        uint256 hookCount = 32;
        uint256 keysPerHook = 8;
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](hookCount + 1);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        for (uint256 i = 0; i < hookCount; i++) {
            bytes32 hookId = bytes32(uint256(0x6100 + i));
            bytes32 stageId = bytes32(uint256(0x5100 + i));
            UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](keysPerHook + 1);
            bytes32[] memory deps = new bytes32[](keysPerHook);
            for (uint256 j = 0; j < keysPerHook; j++) {
                bytes32 signalId = bytes32(uint256(0x10000 + i * keysPerHook + j));
                instructions[j] = UVPStateMachine.Instruction({
                    op: uint8(UVPStateMachine.InstructionOp.Signal),
                    sourceId: SOURCE_BOOTSTRAP,
                    signalId: signalId,
                    arity: 0,
                    delaySeconds: 0
                });
                deps[j] = keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId));
            }
            instructions[keysPerHook] = UVPStateMachine.Instruction({
                op: uint8(UVPStateMachine.InstructionOp.And),
                sourceId: bytes32(0),
                signalId: bytes32(0),
                arity: uint16(keysPerHook),
                delaySeconds: 0
            });
            hooks[i + 1] = _hookWithFlags(hookId, stageId, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, instructions, deps);
        }

        bytes32 planId = _registerPlan(machine, hooks);
        require(machine.planExists(planId), "plan not finalized");
        require(
            machine.planHookDependsOn(planId, bytes32(uint256(0x6100)), SOURCE_BOOTSTRAP, bytes32(uint256(0x10000))),
            "first hook key missing"
        );
        require(
            machine.planHookDependsOn(
                planId,
                bytes32(uint256(0x6100 + hookCount - 1)),
                SOURCE_BOOTSTRAP,
                bytes32(uint256(0x10000 + (hookCount - 1) * keysPerHook + keysPerHook - 1))
            ),
            "last hook key missing"
        );
        require(
            !machine.planHookDependsOn(planId, bytes32(uint256(0x6100)), SOURCE_BOOTSTRAP, SIGNAL_TRIGGER),
            "unexpected dependency"
        );
    }

    function testCommitPlanAcceptsSameStageSharedDependencyKey() public {
        UVPStateMachine machine = _newUnfrozenMachine();
        machine.freezeModules();

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] = _signalHook(bytes32(uint256(0x9003)), STAGE_INIT, bytes32("PEER_WATCHER"), false, SIGNAL_TRIGGER);

        bytes32 planId = _commitPlan(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
        require(machine.planCommitted(planId), "plan should commit");
    }

    // ------------------------------------------------------------------
    // 跨 plan 攻击负例。每个用例先复现攻击前提，
    // 再断言隔离或 revert。
    // ------------------------------------------------------------------

    /// 跨 plan 抢单场景：攻击者先在自己的 plan 下注册受害方将要派生的
    /// orderId。(planId, orderId) 复合寻址使两个订单共存且互不可见，
    /// 受害方的合法铸单不受影响。
    function testCrossPlanOrderIdSquattingIsIsolated() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_emitReadyPositiveHookPlan(HOOK_INIT));

        // 攻击者与受害方各自提交 hooks 相同、publisher 不同的 plan。
        bytes32 attackerPlanId = _registerPlanWithKey(machine, hooks, ATTACKER_PUBLISHER_PRIVATE_KEY);
        bytes32 victimPlanId = _registerPlanWithKey(machine, hooks, PUBLISHER_PRIVATE_KEY);
        require(attackerPlanId != victimPlanId, "plan ids must differ");

        // 一事一单：订单 id 由合约按 (planId, 事实) 派生——攻击者没有任何
        // 字段能选择"受害方将要派生的 orderId"。同一事实在两个 plan 下派生
        // 出互不相干的两个 id，抢注受害单号在入口处结构性关闭。
        bytes32 attackerOrderId =
            machine.triggerOrderIdFor(attackerPlanId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH);
        bytes32 victimOrderId =
            machine.triggerOrderIdFor(victimPlanId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH);
        require(attackerOrderId != victimOrderId, "plan-scoped derivation must differ");

        // 攻击者先触发同一事实内容（自己的 plan 域）。
        address attackerSubmitter = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine,
            attackerPlanId,
            attackerSubmitter,
            _auths1(SIGNAL_TRIGGER, attackerSubmitter),
            ATTACKER_SUBMITTER_PRIVATE_KEY
        );
        require(machine.orderExists(attackerPlanId, attackerOrderId), "attacker order missing");

        // 复现点：受害方随后铸造同一事实——派生 id 不同，必须成功且互不可见。
        address victimSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, victimPlanId, victimSubmitter, _auths1(SIGNAL_TRIGGER, victimSubmitter), SUBMITTER_PRIVATE_KEY
        );
        require(machine.orderExists(victimPlanId, victimOrderId), "victim order blocked by squatting");
        require(!machine.orderExists(victimPlanId, attackerOrderId), "attacker id leaked into victim plan");
        require(!machine.orderExists(attackerPlanId, victimOrderId), "victim id leaked into attacker plan");

        vm.prank(victimSubmitter);
        machine.submitSignal(
            victimPlanId, victimOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY
        , _noAttribution(), _noBinding());
        (UVPStateMachine.HookStatus victimStatus,, bool victimReady) =
            machine.getHookStatus(victimPlanId, victimOrderId, HOOK_INIT);
        (UVPStateMachine.HookStatus attackerStatus,, bool attackerReady) =
            machine.getHookStatus(attackerPlanId, attackerOrderId, HOOK_INIT);
        require(victimStatus == UVPStateMachine.HookStatus.Ready, "victim hook not ready");
        require(victimReady, "victim ready marker missing");
        require(attackerStatus == UVPStateMachine.HookStatus.Init, "attacker order contaminated");
        require(!attackerReady, "attacker ready marker set");

        // 跨 plan 不可寻址：受害方提交者无法给攻击者订单提交信号。
        vm.prank(victimSubmitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                attackerOrderId,
                SOURCE_BOOTSTRAP,
                SIGNAL_TRIGGER,
                victimSubmitter
            )
        );
        machine.submitSignal(
            attackerPlanId, attackerOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY
        , _noAttribution(), _noBinding());

        // 同 plan 同事实重放幂等：派生同 id，OrderAlreadyRegistered。
        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        _submitTriggerOrderFromOutsideWithKey(
            machine, victimPlanId, victimSubmitter, _auths1(SIGNAL_TRIGGER, victimSubmitter), SUBMITTER_PRIVATE_KEY
        );
    }

    /// pinned 向量：合约 triggerOrderIdFor 与 TS 镜像
    /// deriveTriggerOrderId（protocol-bindings/src/index.ts）必须逐字节一致。
    /// 向量由 `cast keccak` 对 abi.encode(planId, sourceId, signalId,
    /// payloadHash)（四 bytes32 即原样拼接）生成，再按合约同口径清除 dock
    /// 子单命名空间保留位（最高位）；V3 的原始 digest 最高位为 1，专门钉住
    /// 清位语义；TS 侧单测钉同一组向量，两侧任一漂移即红。
    function testTriggerOrderIdForMatchesPinnedMirrorVector() public {
        UVPStateMachine machine = _newMachine();

        // V1：小词输入。
        require(
            machine.triggerOrderIdFor(
                    bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), bytes32(uint256(4))
                ) == 0x392791df626408017a264f53fde61065d5a93a32b60171df9d8a46afdf82992d,
            "V1 mirror vector drifted"
        );

        // V2：keccak 产物资（planId=keccak("plan")、sourceId=keccak("payment")、
        // signalId=keccak("payment.ready")、payloadHash=keccak("payload")）。
        require(
            machine.triggerOrderIdFor(
                0x23ed4d6a785e89846f63d29858367b8fe694fb73179a0c2bc540e0687079c161,
                0x1fab0c92eaead7da02fe29795732249e0861c98d6738709e6be992a170920770,
                0x69a75a88c14fab0bfb411e1062f0e56850184f83a4737b3b14440b08947b43da,
                0xebc84cbd75ba5516bf45e7024a9e12bc3c5c880f73e3a5beca7ebba52b2867a7
            ) == 0x5ea3f67d172d893746b323173444e0dff190f5a4d4d91db58776692ad483009a,
            "V2 mirror vector drifted"
        );

        // V3：同 V2 前三参，payloadHash=keccak("payload-3")——原始 digest
        // 0xfadbfa9e…最高位为 1，清位后首字节 0xfa→0x7a。
        require(
            machine.triggerOrderIdFor(
                0x23ed4d6a785e89846f63d29858367b8fe694fb73179a0c2bc540e0687079c161,
                0x1fab0c92eaead7da02fe29795732249e0861c98d6738709e6be992a170920770,
                0x69a75a88c14fab0bfb411e1062f0e56850184f83a4737b3b14440b08947b43da,
                0x7ddb57e56bc008d7f232156ac0c4a9be3da0582cbda6ae545fb75e0b912ee6fa
            ) == 0x7adbfa9eb5e66f4bda59ce36fa07abdf9979eb14222e023ed9480d0adb8d2c0a,
            "V3 mask vector drifted"
        );

        // V4：全零边界。
        require(
            machine.triggerOrderIdFor(bytes32(0), bytes32(0), bytes32(0), bytes32(0))
                == 0x012893657d8eb2efad4de0a91bcd0e39ad9837745dec3ea923737ea803fc8e3d,
            "V4 zero vector drifted"
        );
    }

    /// capability 镜像场景：攻击者 plan 完整镜像受害方 plan
    /// 的公开 trigger hook 与 capability 声明后，仍不得把受害方订单当作
    /// trigger-origin 建链（origin 侧同意缺失）。
    function testCrossPlanCapabilityMirrorIsRejected() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_sequentialPlan());
        SignalCapability[] memory capabilities = _signalCapabilities();
        StageSelectorBinding[] memory noSelectorBindings =
            new StageSelectorBinding[](0);

        bytes32 victimPlanId =
            _commitPlanWithKey(machine, hooks, noSelectorBindings, capabilities, PUBLISHER_PRIVATE_KEY);
        machine.finalizePlan(victimPlanId);
        bytes32 attackerPlanId =
            _commitPlanWithKey(machine, hooks, noSelectorBindings, capabilities, ATTACKER_PUBLISHER_PRIVATE_KEY);
        machine.finalizePlan(attackerPlanId);

        // 攻击前提成立：镜像 plan 的 capability 声明与受害方 plan 完全一致
        // （同型能力叶在镜像树上携证可验）。
        bytes32[] memory mirrorLeaves = _capabilityTables[address(machine)][attackerPlanId].sortedLeaves;
        bytes32 mirroredLeaf = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_AUDIT, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, uint256(1))
        );
        require(
            _planMetadata(machine).verifySignalCapability(
                attackerPlanId, STAGE_AUDIT, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, 1, _merkleProofFor(mirrorLeaves, mirroredLeaf)
            ),
            "mirror capability missing"
        );

        // 受害方订单与 origin 事实（订单 id 由合约派生）。
        address victimSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, victimPlanId, victimSubmitter, _auths1(SIGNAL_TRIGGER, victimSubmitter), SUBMITTER_PRIVATE_KEY
        );
        bytes32 victimOrderId = ORDER_ID;
        vm.prank(victimSubmitter);
        machine.submitSignal(
            victimPlanId, victimOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY
        , _factAttribution(machine, victimPlanId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), _noBinding());

        // 攻击者（无 origin 侧任何身份）尝试把自己的派生单挂到受害方订单上。
        address attacker = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        bytes32 mirroredOrderId = machine.orderLinkOrderIdFor(
            attackerPlanId, victimPlanId, victimOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH
        );
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory mirrored =
            IUVPStateMachineCore.TriggerOrderFromSignalRequest({
                orderId: mirroredOrderId,
                planId: attackerPlanId,
                creator: attacker,
                triggerOriginOrderId: victimOrderId,
                originPlanId: victimPlanId,
                triggerHookId: HOOK_INIT,
                triggerStageId: STAGE_INIT,
                originSourceId: SOURCE_BOOTSTRAP,
                originSignalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: bytes32(uint256(2)),
                submitter: attacker,
                deadline: block.timestamp + 1 hours
            });
        IUVPStateMachineCore.SignalAuthorization[] memory noAuthorizations =
            new IUVPStateMachineCore.SignalAuthorization[](0);
        // 先离线算好签名，expectRevert 只包住真正应回滚的外部调用。
        bytes memory mirroredSignature =
            _triggerOrderFromSignalSignature(machine, mirrored, noAuthorizations, ATTACKER_SUBMITTER_PRIVATE_KEY);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedTriggerOrigin.selector, victimPlanId, victimOrderId, attacker
            )
        );
        _orderLink(machine).triggerOrderFromSignalFor(mirrored, noAuthorizations, mirroredSignature, new IUVPStateMachineCore.FactAttribution[](0));

        // 链接未建立、派生单未铸造。
        (bool linked,,,,,) = _orderLink(machine).getTriggerOriginLink(attackerPlanId, mirroredOrderId);
        require(!linked, "mirror link was registered");
        require(!machine.orderExists(attackerPlanId, mirroredOrderId), "mirror order minted");

        // 即便攻击者另行铸造无链接订单（派生 id 在自己的 plan 域内），跨
        // plan 派生仍被 relation 查找拒绝。
        _submitTriggerOrderFromOutsideWithKey(
            machine, attackerPlanId, attacker, _auths1(SIGNAL_TRIGGER, attacker), ATTACKER_SUBMITTER_PRIVATE_KEY
        );
        bytes32 attackerOrderId = ORDER_ID;
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest11 =
            _derivedSignalRequestWithPlans( attackerOrderId, STAGE_AUDIT, attackerPlanId, victimOrderId, victimPlanId, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(3)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs11 = _derivedProofs(machine, derivedRequest11);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UVPOrderLinkModule.UnknownOrderTriggerLink.selector, attackerOrderId));
        _derivedSignal(machine).submitDerivedSignal(derivedRequest11, attacker, derivedProofs11);
    }

    /// origin 同意的正向面：origin 事实授权的提交者、origin
    /// 订单创建者、以及持有 origin 事实授权的执行 relayer 均可建立链接；
    /// 完全无身份的一方被拒绝。
    function testTriggerLinkOriginConsentPaths() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        address triggerSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);

        // (1) origin 事实授权路径：submitter 或 relayer 持有 origin 事实
        // 授权即可。先由无身份攻击者（submitter+relayer 均为攻击者）复现
        // 拒绝，再由授权 submitter 执行成功。
        _submitTriggerOrderFromOutsideWithKey(
            machine, planId, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, triggerSubmitter), SUBMITTER_PRIVATE_KEY
        );
        vm.prank(triggerSubmitter);
        machine.submitSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        // 攻击者自签自提：无任何 origin 身份 → UnauthorizedTriggerOrigin。
        address attacker = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory attackerRequest =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        attackerRequest.submitter = attacker;
        attackerRequest.creator = attacker;
        bytes memory attackerSignature =
            _triggerOrderFromSignalSignature(machine, attackerRequest, childAuths, ATTACKER_SUBMITTER_PRIVATE_KEY);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnauthorizedTriggerOrigin.selector, planId, ORDER_ID, attacker)
        );
        _orderLink(machine).triggerOrderFromSignalFor(attackerRequest, childAuths, attackerSignature, new IUVPStateMachineCore.FactAttribution[](0));

        // 授权 submitter 执行：relayer 是无关方也允许（submitter 有事实授权）。
        bytes memory requestSignature =
            _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        _orderLink(machine).triggerOrderFromSignalFor(request, childAuths, requestSignature, new IUVPStateMachineCore.FactAttribution[](0));
        (bool relayerLinked,,,,,) = _orderLink(machine).getTriggerOriginLink(planId, LINKED_ORDER_ID);
        require(relayerLinked, "authorized relayer link missing");

        // (2) origin 订单创建者身份：该订单只授权他人提交 origin 事实，
        // 创建者本人未获任何授权，仍可作为 submitter 触发其派生单。
        // 一事一单：第二个出生订单需要不同事实（不同 payloadHash）。
        bytes32 secondPayload = bytes32(uint256(0x8004));
        _submitTriggerOrderFromOutsideWithPayload(
            machine,
            planId,
            triggerSubmitter,
            secondPayload,
            _auths1(SIGNAL_TRIGGER, SUBMITTER_A),
            SUBMITTER_PRIVATE_KEY
        );
        bytes32 secondOriginOrderId = ORDER_ID;
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            planId, secondOriginOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY
        , _noAttribution(), _noBinding());

        bytes32 creatorChildOrderId = machine.orderLinkOrderIdFor(
            planId, planId, secondOriginOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH
        );
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory creatorTrigger =
            IUVPStateMachineCore.TriggerOrderFromSignalRequest({
                orderId: creatorChildOrderId,
                planId: planId,
                creator: triggerSubmitter,
                triggerOriginOrderId: secondOriginOrderId,
                originPlanId: planId,
                triggerHookId: HOOK_INIT,
                triggerStageId: STAGE_INIT,
                originSourceId: SOURCE_BOOTSTRAP,
                originSignalId: SIGNAL_TRIGGER,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: bytes32(uint256(4)),
                submitter: triggerSubmitter,
                deadline: block.timestamp + 1 hours
            });
        IUVPStateMachineCore.SignalAuthorization[] memory emptyChildAuths =
            new IUVPStateMachineCore.SignalAuthorization[](0);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        _triggerOrderFromSignalForKey(machine, creatorTrigger, emptyChildAuths, SUBMITTER_PRIVATE_KEY);
        (bool creatorLinked,,,,,) = _orderLink(machine).getTriggerOriginLink(planId, creatorChildOrderId);
        require(creatorLinked, "creator consent link missing");
    }

    // ------------------------------------------------------------------
    // 0300 H-1：order-link 派生单号独立命名空间
    // ------------------------------------------------------------------

    function testOrderLinkOrderIdMustMatchDerivation() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        address triggerSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, planId, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, triggerSubmitter), SUBMITTER_PRIVATE_KEY
        );
        vm.prank(triggerSubmitter);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        // 自报订单号与派生值不一致 → 拒绝。
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        request.orderId = bytes32(uint256(0xdead));
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));
        bytes memory signature = _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        bytes32 derived =
            machine.orderLinkOrderIdFor(PLAN_ID, PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.InvalidOrderLinkOrderId.selector, bytes32(uint256(0xdead)), derived)
        );
        _orderLink(machine).triggerOrderFromSignalFor(request, childAuths, signature, new IUVPStateMachineCore.FactAttribution[](0));
    }

    function testOrderLinkDerivedIdCannotSquatOutsideTriggerNamespace() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        address triggerSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, planId, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, triggerSubmitter), SUBMITTER_PRIVATE_KEY
        );
        vm.prank(triggerSubmitter);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());

        // 受害者未来的 outside 派生单号（高位清零命名空间，尚未创建）——
        // 攻击者试图用 order-link 自报单号先注该 id。
        bytes32 victimOrderId =
            machine.triggerOrderIdFor(planId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, bytes32(uint256(0x9999)));
        // link 派生域与 outside 派生域结构性分离。
        bytes32 derivedLinkId =
            machine.orderLinkOrderIdFor(PLAN_ID, PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH);
        require(victimOrderId != derivedLinkId, "link and outside derivation domains must be disjoint");

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        request.orderId = victimOrderId;
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));
        bytes memory signature = _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.InvalidOrderLinkOrderId.selector, victimOrderId, derivedLinkId)
        );
        _orderLink(machine).triggerOrderFromSignalFor(request, childAuths, signature, new IUVPStateMachineCore.FactAttribution[](0));
        require(!machine.orderExists(planId, victimOrderId), "victim derived id was squatted");
    }

    // ------------------------------------------------------------------
    // UVP-08：trigger hook 消费的每条 SIGNAL 指令独立过 origin 同意门
    // ------------------------------------------------------------------

    function testTriggerLinkConsentCoversEveryConsumedSignalInstruction() public {
        UVPStateMachine machine = _newMachine();
        // trigger hook 消费两条事实：TRIGGER AND INIT_CMP。
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_INIT_CMP);
        instructions[2] = _and(2);
        hooks[0] = _hook(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, instructions, _deps2(SIGNAL_TRIGGER, SIGNAL_INIT_CMP)
        );
        bytes32 planId = _registerPlan(
            machine,
            _withOrderStart(hooks),
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );

        // origin 订单：TRIGGER 由 triggerSubmitter 提交（显式授权），
        // INIT_CMP 由 SUBMITTER_A 提交（显式授权）——两人各持一条事实的同意。
        UVPStateMachine.SignalAuthorization[] memory originAuths = new UVPStateMachine.SignalAuthorization[](2);
        originAuths[0] = _authorization(SIGNAL_ORDER_START, address(this));
        originAuths[1] = _authorization(SIGNAL_TRIGGER, vm.addr(SUBMITTER_PRIVATE_KEY));
        UVPStateMachine.SignalAuthorization[] memory outsideAuths = new UVPStateMachine.SignalAuthorization[](3);
        outsideAuths[0] = originAuths[0];
        outsideAuths[1] = originAuths[1];
        outsideAuths[2] = _authorization(SIGNAL_INIT_CMP, SUBMITTER_A);
        _submitTriggerOrderFromOutsideWithKey(machine, PLAN_ID, ORDER_CREATOR, outsideAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(vm.addr(SUBMITTER_PRIVATE_KEY));
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution(), _noBinding());
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x11)), _noAttribution(), _noBinding());

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        // 声明事实（TRIGGER）有同意，消费的另一条事实（INIT_CMP）没有：
        // relayer 也是无关方 → 拒绝。
        bytes memory signature = _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedTriggerOrigin.selector, planId, ORDER_ID, vm.addr(SUBMITTER_PRIVATE_KEY)
            )
        );
        _orderLink(machine).triggerOrderFromSignalFor(request, childAuths, signature, new IUVPStateMachineCore.FactAttribution[](0));

        // submitter 持 TRIGGER 同意、relayer（SUBMITTER_A，持 INIT_CMP 同意）
        // 补齐另一条消费事实 → 并集覆盖全部指令，链接放行。
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory coveredRequest =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(3)));
        bytes memory coveredSignature =
            _triggerOrderFromSignalSignature(machine, coveredRequest, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(SUBMITTER_A);
        _orderLink(machine).triggerOrderFromSignalFor(coveredRequest, childAuths, coveredSignature, new IUVPStateMachineCore.FactAttribution[](0));
        require(machine.orderExists(planId, LINKED_ORDER_ID), "consent-covered link missing");
    }

    // ------------------------------------------------------------------
    // 出生阶段 patch 门 + 同秒平局 fail-closed
    // ------------------------------------------------------------------

    function testStageExecutorPatchForbiddenOnBirthStage() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        // STAGE_INIT 挂 order-trigger（出生阶段）：executor patch 拒绝。
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        patch.targetStageId = STAGE_INIT;
        patch.selectorStageId = STAGE_INIT;
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchForbiddenOnBirthStage.selector, ORDER_ID, STAGE_INIT
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
    }

    function testStageResourcePatchAllowedOnBirthStage() public {
        // 资源可替换已裁决：出生阶段只禁 executor patch，fileResources 补丁
        // 放行（选择器持 RESOURCE_PATCH_SIGNAL 显式授权）。
        UVPStateMachine machine = _newMachine();
        StageSelectorBinding[] memory bindings =
            new StageSelectorBinding[](2);
        bindings[0] =
            StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
        bindings[1] =
            StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_INIT});
        UVPStateMachine.SignalAuthorization[] memory originAuthorizations = new UVPStateMachine.SignalAuthorization[](2);
        originAuthorizations[0] = _stageAuthorization(STAGE_INIT, RESOURCE_PATCH_SIGNAL_ID, address(this));
        originAuthorizations[1] = _authorization(SIGNAL_ORDER_START, address(this));
        // 词表内出生事实：树非空（挂了绑定）即词表闸生效，出生事实必须声明
        // 为 relation=0 能力。声明在 STAGE_AUDIT 名下——若挂在出生阶段
        // STAGE_INIT 名下，_stageSignalState 会把已发生的出生事实计入
        // STAGE_AUDIT 之外的该阶段信号数，资源补丁被 StageAlreadyHasSignal
        // 顶死（见报告：出生事实计入 patch 目标阶段信号数的语义张力）。
        SignalCapability[] memory capabilities =
            new SignalCapability[](1);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), bindings, capabilities);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, originAuthorizations);

        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.targetStageId = STAGE_INIT;
        patch.selectorStageId = STAGE_INIT;
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        (bool exists,,,,,) =
            _stagePatch(machine).getActiveStageResourcePatch(PLAN_ID, ORDER_ID, STAGE_INIT, RESOURCE_KEY);
        require(exists, "birth-stage resource patch missing");
    }

    function testSameSecondDifferentSubmittersFailsClosedOnPreviousExecutor() public {
        // relation-0 事实收紧后，selector-target 阶段只能出现在
        // active patch 之后（派生/普通路径同过 assign 门）——"无 patch 的
        // 阶段事实"这一回退触发面在公链路径关闭，handoff 的上一执行者恒为
        // active patch executor。同一秒（同块）两个不同提交者各交一条阶段
        // 能力事实不再产生歧义：patch 权威序确定，handoff 由该执行者签名
        // 放行（回退歧义守卫保留为纵深，见 fixlog-L6）。
        address initialExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);
        _activateInitialStageExecutor(machine, vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);

        vm.prank(initialExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());
        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, address(0xcc), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, initialExecutor, bytes32(0), bytes32(0)
        );
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = _stagePatch(machine)
                .stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, vm.addr(SUBMITTER_PRIVATE_KEY), deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            bytes memory selectorSignature = _packedSignature(v, r, s);
            (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);
            bytes memory previousSignature = _packedSignature(pv, pr, ps);
            vm.prank(UNAUTHORIZED_SUBMITTER);
            _stagePatch(machine)
                .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, vm.addr(SUBMITTER_PRIVATE_KEY), deadline, selectorSignature, previousSignature, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        }
        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == address(0xcc),
            "same-second handoff must stay deterministic via active patch executor"
        );
    }

    function testSameSecondFallbackShapeIsClosedAtAssignGate() public {
        // "无 patch 的同秒双提交者阶段事实"构造入口（relation-0 派生
        // 写入）在 assign 门被拒，回退触发面前置关闭。
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory caps = new SignalCapability[](4);
        caps[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        caps[1] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_REVIEW, targetOrderRelation: 0
        });
        caps[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        // STAGE_AUDIT 的推进驱动事实由出生阶段携出。
        caps[3] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_INIT_CMP, targetOrderRelation: 0
        });
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), caps);
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](5);
        auths[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, vm.addr(SUBMITTER_PRIVATE_KEY));
        auths[1] = _authorization(SIGNAL_ORDER_START, address(this));
        auths[2] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A);
        auths[3] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_REVIEW, SUBMITTER_B);
        auths[4] = _authorization(SIGNAL_INIT_CMP, address(this));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, auths);
        // STAGE_AUDIT 物化（EMIT_READY hook 消费 SIGNAL_INIT_CMP）。
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x77)), _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP), _noBinding());

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest12 =
            _derivedSignalRequestWithPlans( ORDER_ID, STAGE_AUDIT, PLAN_ID, ORDER_ID, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)) );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs12 = _derivedProofs(machine, derivedRequest12);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest12, SUBMITTER_A, derivedProofs12);
    }

    function testDistinctSecondsKeepDeterministicPreviousExecutor() public {
        // active patch 的 executor 是权威"上一执行者"（不回退信号序）；
        // handoff 由该执行者签名放行。时间可分场景下信号回退序同样确定
        // （本测试走 patch 权威路径）。
        address initialExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);
        _activateInitialStageExecutor(machine, vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);

        vm.prank(initialExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE), _noBinding());
        vm.warp(block.timestamp + 10);
        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(2)), _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW), _noBinding());

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, address(0xcc), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, initialExecutor, bytes32(0), bytes32(0)
        );
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = _stagePatch(machine)
                .stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, vm.addr(SUBMITTER_PRIVATE_KEY), deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            bytes memory selectorSignature = _packedSignature(v, r, s);
            (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);
            bytes memory previousSignature = _packedSignature(pv, pr, ps);
            vm.prank(UNAUTHORIZED_SUBMITTER);
            _stagePatch(machine)
                .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, vm.addr(SUBMITTER_PRIVATE_KEY), deadline, selectorSignature, previousSignature, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId), _stageCapabilityFacts(machine, PLAN_ID, patch.targetStageId));
        }
        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == address(0xcc), "handoff executor missing"
        );
    }

    // ------------------------------------------------------------------
    // hooksHash 冻结向量（与 TS compiler 测试逐字节一致）
    // ------------------------------------------------------------------

    function testHooksHashFrozenVectorMatchesTSCompiler() public pure {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory a = new UVPStateMachine.Instruction[](3);
        a[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: bytes32(uint256(0x4001)),
            signalId: bytes32(uint256(0x5001)),
            arity: 0,
            delaySeconds: 0
        });
        a[1] = _not();
        a[2] = _delay(30);
        bytes32[] memory depsA = new bytes32[](1);
        depsA[0] = bytes32(uint256(0x6001));
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: bytes32(uint256(0x1001)),
            stageId: bytes32(uint256(0x2001)),
            hookName: bytes32(uint256(0x3001)),
            flags: 5,
            instructions: a,
            dependencyKeys: depsA
        });
        UVPStateMachine.Instruction[] memory b = new UVPStateMachine.Instruction[](4);
        b[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: bytes32(uint256(0x4002)),
            signalId: bytes32(uint256(0x5002)),
            arity: 0,
            delaySeconds: 0
        });
        b[1] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: bytes32(uint256(0x4001)),
            signalId: bytes32(uint256(0x5001)),
            arity: 0,
            delaySeconds: 0
        });
        b[2] = _and(2);
        b[3] = _or(2);
        bytes32[] memory depsB = new bytes32[](2);
        depsB[0] = bytes32(uint256(0x6002));
        depsB[1] = bytes32(uint256(0x6001));
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: bytes32(uint256(0x1002)),
            stageId: bytes32(uint256(0x2002)),
            hookName: bytes32(uint256(0x3002)),
            flags: 0,
            instructions: b,
            dependencyKeys: depsB
        });
        // 非 SIGNAL 指令的 sourceId/signalId 恒填 Solidity 零字——TS compiler
        // 与 uvp-deploy 驱动同口径；commitPlan 对提交 calldata 重算本哈希。
        require(
            keccak256(abi.encode(hooks)) == 0xe71cb5f3a4e16b4498c9d0ccd126cfcc63b6275039635cb94190bf5dcec486df,
            "hooksHash frozen vector drifted"
        );
    }

    // ------------------------------------------------------------------
    // 携证门与委托新鲜度
    // ------------------------------------------------------------------

    /// 声明属主即必须携有效证明：篡改证明响亮回滚，不静默降级为"无归属"。
    function testSubmitSignalRejectsTamperedFactAttribution() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStateMachine.FactAttribution memory attribution =
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        attribution.capabilityProof[0] = bytes32(uint256(attribution.capabilityProof[0]) ^ 1);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidFactAttribution.selector,
                PLAN_ID,
                STAGE_AUDIT,
                SIGNAL_STAGE_DONE,
                attribution.stageId
            )
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY, attribution, _noBinding()
        );
    }

    /// 证明与被提交的事实键错配：按 InvalidFactAttribution 拒绝。
    function testSubmitSignalRejectsMismatchedAttributionKey() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStateMachine.FactAttribution memory attribution =
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        attribution.signalId = SIGNAL_STAGE_REVIEW;
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidFactAttribution.selector,
                PLAN_ID,
                STAGE_AUDIT,
                SIGNAL_STAGE_DONE,
                attribution.stageId
            )
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY, attribution, _noBinding()
        );
    }

    /// 委托新鲜度按委托记录自带的目标阶段判定：轮换时供表漏项的键，旧
    /// 执行者的残留委托不得复用（active patch 已指向新执行者）。NEW_OWNER
    /// 不持任何显式授权，只能经委任提交——恰是委托路径的唯一持有人。
    function testOmittedStageFactDoesNotReviveStaleDelegation() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        // 在任期内的委托提交（正例）：DONE/REVIEW 全量委任给 NEW_OWNER。
        _stagePatch(machine).applyStageExecutorPatch(
            PLAN_ID,
            ORDER_ID,
            _stageExecutorPatch(1, NEW_OWNER, PATCH_HASH),
            _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
            _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT)
        );
        vm.prank(NEW_OWNER);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9102)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW),
            _noBinding()
        );

        // 轮换到 SUBMITTER_B（replacement），供表只带 SIGNAL_STAGE_DONE——
        // SIGNAL_STAGE_REVIEW 的委托保持指向 NEW_OWNER（残留）。
        UVPStagePatchModule.StageExecutorPatch memory rotation = _stageExecutorPatchWithMode(
            2,
            SUBMITTER_B,
            PATCH_HASH_2,
            EXECUTOR_PATCH_MODE_REPLACEMENT,
            NEW_OWNER,
            SOURCE_BOOTSTRAP,
            SIGNAL_ORDER_START
        );
        UVPStagePatchModule.StageCapabilityFact[] memory full = _stageCapabilityFacts(machine, PLAN_ID, STAGE_AUDIT);
        UVPStagePatchModule.StageCapabilityFact[] memory partialFacts =
            new UVPStagePatchModule.StageCapabilityFact[](1);
        for (uint256 i = 0; i < full.length; i++) {
            if (full[i].signalId == SIGNAL_STAGE_DONE) {
                partialFacts[0] = full[i];
            }
        }
        _stagePatch(machine).applyStageExecutorPatch(
            PLAN_ID, ORDER_ID, rotation, _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), partialFacts
        );

        // 残留委托不得复活：REVIEW 的委托未被轮换供表覆盖、仍指向
        // NEW_OWNER（授权腿通过），但委托阶段（STAGE_AUDIT）的 active patch
        // 已指向 SUBMITTER_B——按 UnauthorizedStageExecutor 拒绝。
        vm.prank(NEW_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_AUDIT, NEW_OWNER, SUBMITTER_B
            )
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW),
            _noBinding()
        );
    }

    /// patch 供表中的事实验不过（他阶段的能力键）→ 整笔拒绝。
    function testStageExecutorPatchRejectsForeignStageFact() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        UVPStagePatchModule.StageCapabilityFact[] memory foreign =
            new UVPStagePatchModule.StageCapabilityFact[](1);
        foreign[0] = UVPStagePatchModule.StageCapabilityFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            capabilityProof: new bytes32[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageCapabilityFactInvalid.selector,
                PLAN_ID,
                STAGE_AUDIT,
                SOURCE_BOOTSTRAP,
                SIGNAL_ORDER_START
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(
            PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), foreign
        );
    }
}

/// finalizePlanMetadata 回调里重入 finalizePlan 的假模块——重入必须
/// 看到 finalized=true 并按 PlanAlreadyFinalized 拒绝（finalized 位先于
/// 外调落定）。
contract ReenteringMetadataModule is IUVPPlanMetadataModule {
    UVPStateMachine private immutable _machine;

    constructor(UVPStateMachine machine) {
        _machine = machine;
    }

    function finalizePlanMetadata(bytes32 planId, bytes32, bytes32, bytes32) external {
        _machine.finalizePlan(planId);
    }

    function signalCapabilityLeaf(bytes32, bytes32, bytes32, uint8) external pure returns (bytes32) {
        revert("unused");
    }

    function selectorBindingLeaf(bytes32, bytes32) external pure returns (bytes32) {
        revert("unused");
    }

    function capabilitiesRoot(bytes32) external pure returns (bytes32) {
        revert("unused");
    }

    function dockRoutesRoot(bytes32) external pure returns (bytes32) {
        revert("unused");
    }

    function dockInterfaceRoot(bytes32) external pure returns (bytes32) {
        revert("unused");
    }

    function hasCapabilityVocabulary(bytes32) external pure returns (bool) {
        revert("unused");
    }

    function verifyDockRoute(bytes32, bytes32, bytes32[] calldata) external pure returns (bool) {
        revert("unused");
    }

    function verifyDockInterfacePort(bytes32, bytes32, bytes32, uint8, bytes32, bytes32, bytes32[] calldata)
        external
        pure
        returns (bool)
    {
        revert("unused");
    }

    function verifySignalCapability(bytes32, bytes32, bytes32, bytes32, uint8, bytes32[] calldata)
        external
        pure
        returns (bool)
    {
        revert("unused");
    }

    function verifyStageSelectorBinding(bytes32, bytes32, bytes32, bytes32[] calldata) external pure returns (bool) {
        revert("unused");
    }
}

contract UVPStateMachineCapabilityTreeTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_uint(string key, uint256 val);

    function assertTrue(bool condition, string memory reason) internal pure {
        if (!condition) {
            revert(reason);
        }
    }

    // 与 UVPStateMachineTest 同源的常量与夹具片段：该文件的主合约持有大量
    // 私有助手，能力树定向测试独立成合约以避免整文件重构。
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x7001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
    );
    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant SUBMITTER_PRIVATE_KEY = 0xa11ce;
    address private constant SUBMITTER_A = address(uint160(0xa11ce));
    address private constant SUBMITTER_B = address(uint160(0xb0b));

    struct LocalBinding {
        bytes32 selectorStageId;
        bytes32 targetStageId;
    }

    struct LocalCapability {
        bytes32 stageId;
        bytes32 targetSourceId;
        bytes32 signalId;
        uint8 targetOrderRelation;
    }

    struct LocalTables {
        bytes32[] sortedLeaves;
    }

    mapping(bytes32 planId => LocalTables tables) private _localTables;
    address private _lastMetadata;

    /// finalize 的 gas 与表规模脱钩：旧上限（256 能力/128 绑定）两倍量的
    /// 表在单笔内定稿，且深叶（第 400 项）证明可验证——表规模上限就此
    /// 消失，剩余边界只有 calldata 与链下产物本身。
    function testFinalizePlanGasIsIndependentOfTableSize() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _minimalHook();
        bytes32[] memory leaves = new bytes32[](800);
        for (uint256 i = 0; i < 400; i++) {
            leaves[i] = keccak256(
                abi.encode(keccak256("UVP_SELECTOR_BINDING_V1"), bytes32(uint256(0x11)), bytes32(uint256(0x9000) + i))
            );
        }
        for (uint256 i = 0; i < 400; i++) {
            leaves[400 + i] = keccak256(
                abi.encode(
                    keccak256("UVP_SIGNAL_CAPABILITY_V1"),
                    bytes32(uint256(0x22)),
                    bytes32(uint256(0x8000) + i),
                    bytes32(uint256(0x4005)),
                    uint256(0)
                )
            );
        }
        bytes32 planId = _commitWithRoot(machine, hooks, _rootOf(leaves));
        _localTables[planId].sortedLeaves = _sortedUnique(leaves);

        uint256 gasBefore = gasleft();
        machine.finalizePlan(planId);
        uint256 spent = gasBefore - gasleft();
        assertTrue(spent < 200_000, "finalize must stay independent of table size");

        bytes32 leaf = keccak256(
            abi.encode(
                keccak256("UVP_SIGNAL_CAPABILITY_V1"),
                bytes32(uint256(0x22)),
                bytes32(uint256(0x8000) + 399),
                bytes32(uint256(0x4005)),
                uint256(0)
            )
        );
        bytes32[] memory proof = _merkleProofFor(_localTables[planId].sortedLeaves, leaf);
        assertTrue(
            UVPPlanMetadataModule(_lastMetadata).verifySignalCapability(
                planId, bytes32(uint256(0x22)), bytes32(uint256(0x8000) + 399), bytes32(uint256(0x4005)), 0, proof
            ),
            "deep leaf must verify"
        );
    }

    // ---- 极简装配：单 hook 计划 + 直接提交指定 capabilitiesRoot ----

    function _minimalHook() private pure returns (UVPStateMachine.CompactHook memory) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: 0,
            sourceId: bytes32(uint256(0x3001)),
            signalId: bytes32(uint256(0x4000)),
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory dependencyKeys = new bytes32[](1);
        dependencyKeys[0] = keccak256(abi.encode(bytes32(uint256(0x3001)), bytes32(uint256(0x4000))));
        return UVPStateMachine.CompactHook({
            hookId: bytes32(uint256(0x6001)),
            stageId: bytes32(uint256(0x11)),
            hookName: bytes32("hook"),
            flags: 4, // EMIT_READY：物化自身阶段的最低配置
            instructions: instructions,
            dependencyKeys: dependencyKeys
        });
    }

    function _rootOf(bytes32[] memory leaves) private pure returns (bytes32) {
        return DockMerkle.root(leaves);
    }

    function _commitWithRoot(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        bytes32 capabilitiesRoot
    ) private returns (bytes32 planId) {
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: capabilitiesRoot,
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
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        keccak256(
                            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                        ),
                        keccak256("UVPStateMachine"),
                        keccak256("0.11"),
                        block.chainid,
                        address(machine)
                    )
                ),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        planId = machine.commitPlan(commit, hooks, signature);
    }

    function _deployModules(UVPStateMachine machine) private returns (UVPStagePatchModule stagePatch, address metadata) {
        // 返回值仅供单次装配读取；二次调用会撞 ModulesFrozen，地址经
        // _lastMetadata 复用。
        stagePatch = new UVPStagePatchModule(address(machine));
        UVPDerivedSignalModule derived = new UVPDerivedSignalModule(address(machine));
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(machine));
        UVPDockingModule docking = new UVPDockingModule(address(machine), address(planMetadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(machine));
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(derived));
        machine.setDockingModule(address(docking));
        machine.setPlanMetadataModule(address(planMetadata));
        machine.setOrderLinkModule(address(orderLink));
        machine.setLens(address(0x1234));
        machine.freezeModules();
        metadata = address(planMetadata);
        _lastMetadata = metadata;
    }

    function _newMachine() private returns (UVPStateMachine machine) {
        machine = new UVPStateMachine();
        _deployModules(machine);
    }

    function _sortedUnique(bytes32[] memory raw) private pure returns (bytes32[] memory) {
        bytes32[] memory sorted = new bytes32[](raw.length);
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

    function _merkleProofFor(bytes32[] memory sorted, bytes32 leaf) private pure returns (bytes32[] memory proof) {
        uint256 index = type(uint256).max;
        for (uint256 i = 0; i < sorted.length; i++) {
            if (sorted[i] == leaf) {
                index = i;
                break;
            }
        }
        require(index != type(uint256).max, "test: leaf not in tree");
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
                next[cursor++] = level[i] <= level[i + 1]
                    ? keccak256(abi.encodePacked(level[i], level[i + 1]))
                    : keccak256(abi.encodePacked(level[i + 1], level[i]));
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
}

/// dock 写入口 mock：占 docking 模块位（freeze 前装配），与真实模块同入
/// 口同权限地写 dock input 事实——StagePreviousExecutorAmbiguous 负例用
/// 它落"无在任 patch 的多提交者"形态（普通提交路径被指派门挡住，该形态
/// 只能经模块写入口复现）。
contract DockInputWriter {
    UVPStateMachine private immutable _machine;

    constructor(UVPStateMachine machine) {
        _machine = machine;
    }

    function write(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 idempotencyKey,
        address submitter
    ) external {
        _machine.recordDockedInputFromModule(
            planId, orderId, sourceId, signalId, bytes32(uint256(0xA001)), idempotencyKey, submitter
        );
    }
}
