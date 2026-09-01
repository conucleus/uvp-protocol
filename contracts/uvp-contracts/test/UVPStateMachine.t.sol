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
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event log_named_uint(string key, uint256 val);

    mapping(address => UVPStagePatchModule) private _stagePatchModules;
    mapping(address => UVPDerivedSignalModule) private _derivedSignalModules;
    mapping(address => UVPDockingModule) private _dockingModules;
    mapping(address => UVPPlanMetadataModule) private _planMetadataModules;
    mapping(address => UVPOrderLinkModule) private _orderLinkModules;
    bytes32 private PLAN_ID;

    bytes32 private constant ORDER_ID = bytes32(uint256(0x2001));
    bytes32 private constant ORDER_ID_2 = bytes32(uint256(0x2002));
    bytes32 private constant SOURCE_BOOTSTRAP = bytes32(uint256(0x3001));
    bytes32 private constant SIGNAL_ORDER_START = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_TRIGGER = bytes32(uint256(0x4001));
    bytes32 private constant SIGNAL_INIT_CMP = bytes32(uint256(0x4002));
    bytes32 private constant SIGNAL_AUDIT_PASS = bytes32(uint256(0x4003));
    bytes32 private constant SIGNAL_VERIFY_FAIL = bytes32(uint256(0x4004));
    bytes32 private constant SIGNAL_STAGE_DONE = bytes32(uint256(0x4005));
    bytes32 private constant SIGNAL_STAGE_REVIEW = bytes32(uint256(0x4006));
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
    bytes32 private constant HOOK_ORDER_START = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_INIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_AUDIT = bytes32(uint256(0x6002));
    bytes32 private constant HOOK_TIMEOUT = bytes32(uint256(0x6003));
    bytes32 private constant HOOK_ROLLBACK = bytes32(uint256(0x6004));
    bytes32 private constant HOOK_NON_TRIGGER = bytes32(uint256(0x6005));
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
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.8");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 metadataHash,uint256 deadline)"
    );

    mapping(address machine => bytes32 planId) private _planIds;
    UVPStateMachine private _currentMachine;
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 orderId,bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
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
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0)
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
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            orderId: ORDER_ID,
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
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature);
        require(machine.orderRelayer(PLAN_ID, ORDER_ID) == NON_OWNER, "relayer not recorded");
    }

    function testDuplicatePlanAndOrderStillRevert() public {
        UVPStateMachine machine = _newMachine();

        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        vm.expectRevert(UVPStateMachine.PlanAlreadyRegistered.selector);
        _commitPlan(
            machine,
            _withOrderStart(_positiveHookPlan(HOOK_INIT, true)),
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0)
        );
        PLAN_ID = planId;

        _submitTriggerOrderFromOutside(machine, ORDER_ID, planId, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        UVPStateMachine.SignalAuthorization[] memory duplicateAuthorizations = _defaultAuthorizations(address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory duplicateTrigger =
            _outsideTriggerRequest(ORDER_ID, HOOK_ORDER_START, SIGNAL_ORDER_START);
        bytes memory duplicateSignature = _triggerOrderFromOutsideSignature(
            machine, duplicateTrigger, duplicateAuthorizations, SUBMITTER_PRIVATE_KEY
        );
        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        machine.triggerOrderFromOutsideFor(duplicateTrigger, duplicateAuthorizations, duplicateSignature);
    }

    function testSubmittedSignalMakesHookReady() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");
    }

    function testRegisterPlanAndOrder() public {
        UVPStateMachine machine = _newMachine();

        vm.recordLogs();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.planExists(planId), "plan not registered");
        require(machine.orderExists(PLAN_ID, ORDER_ID), "order not registered");
        // 审计 #10：订单身份即 (planId, orderId)，plan 归属由寻址键保证。
        require(machine.planPublisher(planId) == vm.addr(PUBLISHER_PRIVATE_KEY), "bad plan publisher");
        require(machine.orderRelayer(PLAN_ID, ORDER_ID) == address(this), "bad order relayer");
        require(machine.orderCreator(PLAN_ID, ORDER_ID) == ORDER_CREATOR, "bad order creator");
        require(_countTopic(logs, keccak256("PlanPublisherRecorded(bytes32,address)")) == 1, "publisher record count");
        require(
            _countTopic(logs, keccak256("OrderRelayerRecorded(bytes32,address,address)")) == 1, "relayer record count"
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

        vm.recordLogs();
        _registerPlan(machine, _sequentialPlan(), _selectorBindings(), _emptySignalCapabilities());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(_planMetadata(machine).planSelectorBindingCount(PLAN_ID) == 1, "bad binding count");
        (bytes32 selectorStageId, bytes32 targetStageId) = _planMetadata(machine).planSelectorBindingAt(PLAN_ID, 0);
        require(selectorStageId == STAGE_INIT, "bad selector stage");
        require(targetStageId == STAGE_AUDIT, "bad target stage");
        require(_planMetadata(machine).isStageSelectorBound(PLAN_ID, STAGE_INIT, STAGE_AUDIT), "binding missing");
        require(!_planMetadata(machine).isStageSelectorBound(PLAN_ID, STAGE_AUDIT, STAGE_INIT), "unexpected binding");
        require(
            _countTopic(logs, keccak256("StageSelectorBindingRegistered(bytes32,bytes32,bytes32)")) == 1,
            "binding event count"
        );
    }

    function testRegisterPlanStoresSignalCapabilities() public {
        UVPStateMachine machine = _newMachine();

        vm.recordLogs();
        _registerPlan(machine, _sequentialPlan(), _selectorBindings(), _signalCapabilities());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(_planMetadata(machine).planSignalCapabilityCount(PLAN_ID) == 1, "bad capability count");
        require(
            _planMetadata(machine)
                .isSignalCapabilityRegistered(
                    PLAN_ID,
                    STAGE_AUDIT,
                    SOURCE_BOOTSTRAP,
                    SIGNAL_VERIFY_FAIL,
                    _planMetadata(machine).SIGNAL_TARGET_TRIGGER_ORIGIN()
                ),
            "capability missing"
        );
        require(
            _countTopic(logs, keccak256("SignalCapabilityRegistered(bytes32,bytes32,bytes32,bytes32,uint8)")) == 1,
            "capability event count"
        );
    }

    function testRegisterPlanRejectsDuplicateStageSelectorBinding() public {
        UVPStateMachine machine = _newMachine();

        bytes32 planId =
            _commitPlan(machine, _sequentialPlan(), _duplicateSelectorBindings(), _emptySignalCapabilities());
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPPlanMetadataModule.StageSelectorBindingAlreadyRegistered.selector, planId, STAGE_INIT, STAGE_AUDIT
            )
        );
        machine.finalizePlan(planId, _duplicateSelectorBindings(), _emptySignalCapabilities());
    }

    function testTriggerOrderFromOutsideCreatesAndMaterializesOrder() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _sequentialPlan());

        vm.recordLogs();
        _submitTriggerOrderFromOutsideRequest(
            machine,
            _outsideTriggerRequest(ORDER_ID, HOOK_INIT, SIGNAL_TRIGGER),
            _auths1(SIGNAL_TRIGGER, SUBMITTER_A),
            SUBMITTER_PRIVATE_KEY
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.orderExists(PLAN_ID, ORDER_ID), "order missing");
        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "trigger signal missing");
        require(
            _countTopic(logs, keccak256("OrderTriggered(bytes32,bytes32,bytes32,bytes32,bytes32,address)")) == 1,
            "trigger event count"
        );
        require(
            _countTopic(logs, keccak256("OrderMaterialized(bytes32,bytes32,bytes32)")) == 1, "materialized event count"
        );
    }

    function testTriggerOrderFromSignalCreatesTriggerOriginLinkAndMaterializesOrder() public {
        UVPStateMachine machine = _registeredMachine(_sequentialPlan());

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        vm.recordLogs();
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(ORDER_ID_2, ORDER_ID, bytes32(uint256(2))),
            _auths1(SIGNAL_TRIGGER, SUBMITTER_A)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (
            bool exists,
            bytes32 triggerOriginOrderId,
            bytes32 triggerOriginPlanId,
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        ) = _orderLink(machine).getTriggerOriginLink(PLAN_ID, ORDER_ID_2);
        require(exists, "link missing");
        require(triggerOriginOrderId == ORDER_ID, "bad trigger origin");
        require(triggerOriginPlanId == PLAN_ID, "bad trigger origin plan");
        require(originSourceId == SOURCE_BOOTSTRAP, "bad origin source");
        require(originSignalId == SIGNAL_TRIGGER, "bad origin signal");
        require(triggerStageId == STAGE_INIT, "bad trigger stage");
        require(!machine.hasSignal(PLAN_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "origin signal copied to triggered");
        require(
            _countTopic(logs, keccak256("OrderLinked(bytes32,bytes32,bytes32,bytes32,bytes32)")) == 1,
            "link event count"
        );
    }

    function testDerivedSignalUsesPlanCapabilityToWriteBackToTriggerOrigin() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _signalCapabilities());
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(ORDER_ID_2, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        vm.recordLogs();
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(
            _derivedSignalRequest(
                ORDER_ID_2,
                STAGE_AUDIT,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_VERIFY_FAIL,
                PAYLOAD_HASH,
                bytes32(uint256(3))
            ),
            SUBMITTER_A
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL),
            "derived signal missing on trigger origin"
        );
        require(
            _countTopic(
                logs,
                keccak256("DerivedSignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address)")
            ) == 1,
            "derived signal event count"
        );
    }

    function testDerivedSignalRejectsMissingPlanCapability() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(ORDER_ID_2, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPDerivedSignalModule.InvalidSignalCapability.selector);
        _derivedSignal(machine).submitDerivedSignal(
            _derivedSignalRequest(
                ORDER_ID_2,
                STAGE_AUDIT,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_VERIFY_FAIL,
                PAYLOAD_HASH,
                bytes32(uint256(3))
            ),
            SUBMITTER_A
        );
    }

    function testApplyStageExecutorPatchStoresActiveOverlayAndEmitsEvents() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);

        vm.recordLogs();
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            _countTopic(
                logs,
                keccak256(
                    "StageExecutorPatchApplied(bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,bytes32,uint256,string)"
                )
            ) == 1,
            "patch event count"
        );
        require(
            _countTopic(
                    logs, keccak256("StageExecutorActivated(bytes32,bytes32,address,bytes32,bytes32,uint256,string)")
                ) == 1,
            "executor event count"
        );
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "bad active executor");
        require(_stagePatch(machine).orderStageExecutorPatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 1, "bad patch nonce");
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A),
            "patched executor should receive signal authority"
        );
        require(
            !machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_B),
            "patched executor should replace the prior signal authority"
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
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        require(machine.hasSourceSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT), "target source signal not marked");
        require(machine.sourceSignalCount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 1, "target signal count not tracked");
        require(machine.lastSignalSubmitter(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "last submitter not tracked");
    }

    function testApplyStageExecutorPatchRejectsUnauthorizedSelector() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _targetSignalAuthorizations(SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageExecutorPatchSelector.selector, ORDER_ID, STAGE_INIT, address(this)
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
    }

    function testApplyStageExecutorPatchRejectsMissingSelectorBinding() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageSelectorBindingNotFound.selector, PLAN_ID, STAGE_INIT, STAGE_AUDIT
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
    }

    function testApplyStageExecutorPatchRejectsNonIncreasingNonce() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH));

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchNonceNotIncreasing.selector, ORDER_ID, STAGE_AUDIT, 2, 2
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH_2));
    }

    function testSelectorTargetStageRejectsSignalBeforeExecutorAssigned() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY);
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
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, previousPatch);

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
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, approvalPatch);
    }

    function testApplyStageExecutorPatchRejectsZeroExecutorAndPatchHash() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.expectRevert(UVPStagePatchModule.ZeroStageExecutor.selector);
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, address(0), PATCH_HASH));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
    }

    function testActivateStageExecutorFromModuleRejectsForeignStage() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        vm.prank(address(_stagePatch(machine)));
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.activateStageExecutorFromModule(PLAN_ID, ORDER_ID, STAGE_ROLLBACK, SUBMITTER_A, ROLE_EXECUTOR, EXECUTOR_METADATA_HASH, PATCH_HASH, 1, ""
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
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "");

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
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "");
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
            .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "");
    }

    function testHandoffStageExecutorPatchSucceedsWithPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

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
            _stagePatch(machine).applyStageExecutorPatchFor(
                PLAN_ID, ORDER_ID, patch, selector, deadline, selectorSignature, previousSignature
            );
        }

        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff executor not active");
        (,,,, address originalSubmitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(originalSubmitter == previousExecutor, "prior signal attribution changed");

        vm.prank(previousExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SIGNAL_STAGE_REVIEW,
                previousExecutor
            )
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(2)));

        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(2)));
        require(machine.sourceSignalCount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 2, "handoff signal count not tracked");
        require(machine.lastSignalSubmitter(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff last submitter not tracked");
    }

    function testHandoffStageExecutorPatchFailsWithoutPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

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
                .applyStageExecutorPatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), "");
        }

        vm.prank(selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
    }

    function testHandoffStageExecutorPatchFailsWithWrongPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

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
        _stagePatch(machine).applyStageExecutorPatchFor(
            PLAN_ID, ORDER_ID, patch, selector, deadline, selectorSignature, wrongSignature
        );
    }

    function testHandoffStageExecutorPatchRejectsApprovalFields() public {
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(address(this), previousExecutor);
        _activateInitialStageExecutor(machine, address(this), previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_INIT, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(2)));

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
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
    }

    function testReplacementStageExecutorPatchSucceedsWithApprovalSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_INIT, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(2)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_REPLACEMENT, SUBMITTER_A, STAGE_INIT, SIGNAL_AUDIT_PASS
        );
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);

        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "replacement executor not active");
        (,,,, address originalSubmitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(originalSubmitter == SUBMITTER_A, "replacement rewrote prior submitter");

        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SIGNAL_STAGE_REVIEW,
                SUBMITTER_A
            )
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(3)));

        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(3)));
    }

    function testReplacementStageExecutorPatchFailsWithoutApprovalSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

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
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
    }

    function testStageExecutorPatchRejectsPreviousExecutorMismatch() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

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
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
    }

    function testActiveStageExecutorPatchBlocksExplicitButInactiveSubmitter() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));

        vm.prank(SUBMITTER_B);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SIGNAL_STAGE_DONE,
                SUBMITTER_B
            )
        );
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));
        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(submitter == SUBMITTER_A, "active executor not recorded");
    }

    function testStageSignalRequiresSourceStageMaterialization() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _overlaySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        (bool exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(!exists, "prematerialized stage signal was stored");

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(3)));
        (exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(exists, "materialized stage signal missing");
    }

    function testActiveStageExecutorReceivesPlanScopedSignalAuthorization() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _overlaySignalCapabilities());
        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        authorizations[1] = _authorization(SIGNAL_INIT_CMP, address(this));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, authorizations);

        (bool staticAuthorization,,) =
            machine.getSignalAuthorization(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A);
        require(!staticAuthorization, "active executor unexpectedly pre-authorized");

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x9201)));
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A),
            "patched executor was not dynamically authorized"
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));
    }

    function testApplyStageResourcePatchStoresOverlayAndEmitsEvent() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);

        vm.recordLogs();
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            _countTopic(
                logs,
                keccak256(
                    "StageResourcePatchApplied(bytes32,bytes32,bytes32,address,bytes32,bytes32,bytes32,bytes32,uint256,string)"
                )
            ) == 1,
            "resource patch event count"
        );
        require(
            _stagePatch(machine).orderStageResourcePatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT, RESOURCE_KEY) == 1,
            "bad resource patch nonce"
        );
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == address(0), "resource patch changed executor");

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

        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(2, RESOURCE_PATCH_HASH));

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
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(2, RESOURCE_PATCH_HASH_2));

        _stagePatch(machine)
            .applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatchWithKey(RESOURCE_KEY_2, 1, RESOURCE_PATCH_HASH_2));
        require(
            _stagePatch(machine).orderStageResourcePatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT, RESOURCE_KEY_2) == 1,
            "resource key nonce not isolated"
        );
    }

    function testApplyStageResourcePatchRejectsUnauthorizedSelector() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _targetSignalAuthorizations(SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageResourcePatchSelector.selector, ORDER_ID, STAGE_INIT, address(this)
            )
        );
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(1, RESOURCE_PATCH_HASH));
    }

    function testApplyStageResourcePatchRejectsAfterTargetStageSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, _stageResourcePatch(1, RESOURCE_PATCH_HASH));
    }

    function testApplyStageResourcePatchRejectsZeroFields() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.resourceKey = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroResourceKey.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch);

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.manifestHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroManifestHash.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch);

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.policyHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroPolicyHash.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch);

        patch = _stageResourcePatch(1, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _stagePatch(machine).applyStageResourcePatch(PLAN_ID, ORDER_ID, patch);
    }

    function testRelayerCanApplyStageResourcePatchWithSelectorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageResourcePatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine).applyStageResourcePatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s));

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
        _stagePatch(machine).applyStageResourcePatchFor(PLAN_ID, ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s));
    }

    function testPositiveSignalMakesHookReady() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

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

    function testSharedSignalEvaluatesTriggerBeforeNonTriggerHooks() public {
        UVPStateMachine machine = _registeredMachine(_sharedDependencyPlanWithNonTriggerFirst());

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus triggerStatus,, bool triggerReadyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus nonTriggerStatus,, bool nonTriggerReadyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_NON_TRIGGER);
        require(triggerStatus == UVPStateMachine.HookStatus.Ready, "trigger not ready");
        require(triggerReadyEmitted, "trigger ready marker missing");
        require(nonTriggerStatus == UVPStateMachine.HookStatus.Ready, "non-trigger not evaluated");
        require(!nonTriggerReadyEmitted, "non-trigger emitted ready");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "ready event count");
    }

    function testUnauthorizedSubmitterRevertsBeforeFirstWrite() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        require(
            !machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER),
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
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        require(!machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "unauthorized signal was written");
    }

    function testAuthorizedSubmitterCanAdvanceHook() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");

        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(submitter == SUBMITTER_A, "bad submitter");
    }

    function testRelayerCanSubmitAuthorizedSignalWithSubmitterSignature() public {
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine, PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, submitter, deadline
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
        );

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
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine, PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, submitter, deadline
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
        );
    }

    function testRelayedSignalRejectsExpiredSignature() public {
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp - 1;
        bytes32 digest = _signalSubmissionDigest(
            machine, PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, submitter, deadline
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
        );
    }

    function testMultipleSubmittersForSameSignalFirstWriterWins() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths2SameSignal(SIGNAL_TRIGGER, SUBMITTER_A, SUBMITTER_B)
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
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.SignalAlreadyExists.selector);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(2)));

        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(submitter == SUBMITTER_B, "first writer changed");
    }

    function testSameWalletCanBeAuthorizedForMultipleSignals() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine,
            ORDER_ID,
            PLAN_ID,
            ORDER_CREATOR,
            _auths3ForSubmitter(SIGNAL_TRIGGER, SIGNAL_INIT_CMP, SIGNAL_AUDIT_PASS, SUBMITTER_A)
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)));

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_AUDIT);
        (UVPStateMachine.HookStatus timeoutStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
        require(timeoutStatus == UVPStateMachine.HookStatus.Ready, "timeout not ready");
    }

    function testDifferentSignalsCanUseDifferentSubmitters() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine,
            ORDER_ID,
            PLAN_ID,
            ORDER_CREATOR,
            _splitSignalAuths(SIGNAL_TRIGGER, SUBMITTER_A, SIGNAL_INIT_CMP, SUBMITTER_B)
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));

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
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));

        vm.prank(SUBMITTER_B);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(3)));

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_AUDIT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
    }

    function testSequentialUpdateFlowHooksBecomeReady() public {
        UVPStateMachine machine = _registeredMachine(_sequentialPlan());

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)));

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
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

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
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

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
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0)
        );
    }

    function testCommitPlanAcceptsOneSecondDelay() public {
        UVPStateMachine machine = _registeredMachine(_timerHookPlan(HOOK_TIMEOUT, 1));

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

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

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "hook not cancelled");
        require(dueAt == 0, "cancelled hook has due");
        require(!readyEmitted, "cancelled hook emitted ready");
    }

    function testOrBranchTriggersRollback() public {
        UVPStateMachine machine = _registeredMachine(_orRollbackPlan());

        vm.recordLogs();
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_ROLLBACK);
        require(status == UVPStateMachine.HookStatus.Ready, "rollback not ready");
        require(readyEmitted, "rollback ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "rollback ready event");
    }

    function testDuplicateSignalReverts() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        vm.expectRevert(UVPStateMachine.SignalAlreadyExists.selector);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, bytes32(uint256(0x8002)), bytes32(uint256(0x9002))
        );
    }

    function testGasAttackerSubmitLinkedSignalForDocking() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _dockingGasMachine();

        vm.resumeGasMetering();
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9002)));
        vm.pauseGasMetering();
    }

    function testGasLinkDockedOrderForOneSignalBinding() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _dockingGasMachineBeforeLink();

        vm.resumeGasMetering();
        uint256 linkBefore = gasleft();
        _docking(machine).linkDockedOrder(PLAN_ID, ORDER_ID, _dockedOrderLink());
        uint256 linkGas = linkBefore - gasleft();
        emit log_named_uint("link_docked_order_gas", linkGas);
        vm.pauseGasMetering();
    }

    function testGasApplyStageExecutorPatchAssignForDockSetup() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.resumeGasMetering();
        uint256 patchBefore = gasleft();
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
        uint256 patchGas = patchBefore - gasleft();
        emit log_named_uint("stage_executor_patch_assign_gas", patchGas);
        vm.pauseGasMetering();
    }

    function testGasRelaySubmitDockedSignal() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _dockingGasMachine();
        vm.prank(SUBMITTER_A);
        machine.submitSignal(PLAN_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9002)));

        vm.resumeGasMetering();
        _docking(machine)
            .submitDockedSignal(PLAN_ID, ORDER_ID, PLAN_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, bytes32(uint256(0x9003)));
        vm.pauseGasMetering();
    }

    function testGasDockedSignalRelayRatioMeasurement() public {
        UVPStateMachine machine = _dockingGasMachine();

        vm.prank(SUBMITTER_A);
        uint256 attackerBefore = gasleft();
        machine.submitSignal(PLAN_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9002)));
        uint256 attackerGas = attackerBefore - gasleft();

        uint256 relayBefore = gasleft();
        _docking(machine)
            .submitDockedSignal(PLAN_ID, ORDER_ID, PLAN_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, bytes32(uint256(0x9003)));
        uint256 relayGas = relayBefore - gasleft();

        emit log_named_uint("attacker_linked_signal_gas", attackerGas);
        emit log_named_uint("relay_docked_signal_gas", relayGas);
        emit log_named_uint("relay_per_100_attacker", (relayGas * 100) / attackerGas);

        require(relayGas < attackerGas * 2, "relay gas ratio too high");
    }

    function testNonTriggerHookCannotMaterializeStageEntry() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _positiveHookPlan(HOOK_NON_TRIGGER, false));

        UVPStateMachine.SignalAuthorization[] memory authorizations = _auths1(SIGNAL_TRIGGER, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(ORDER_ID, HOOK_NON_TRIGGER, SIGNAL_TRIGGER);
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);
        vm.recordLogs();
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature);

        require(_countHookReady(vm.getRecordedLogs()) == 0, "non-trigger emitted ready");
    }

    function testTriggerOrderWithoutAuthorizationsDoesNotOpenSignalSubmission() public {
        UVPStateMachine machine = _newMachine();

        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, new UVPStateMachine.SignalAuthorization[](0)
        );

        require(
            !machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER),
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
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
    }

    function _registeredMachine(UVPStateMachine.CompactHook[] memory hooks) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlan(machine, _withOrderStart(hooks));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
    }

    function _registerPlan(UVPStateMachine machine, UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (bytes32 planId)
    {
        return _registerPlan(
            machine,
            hooks,
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0)
        );
    }

    function _registerPlan(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        IUVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings,
        IUVPPlanMetadataModule.SignalCapability[] memory signalCapabilities
    ) private returns (bytes32 planId) {
        planId = _commitPlan(machine, hooks, selectorBindings, signalCapabilities);
        machine.finalizePlan(planId, selectorBindings, signalCapabilities);
    }

    function _commitPlan(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        IUVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings,
        IUVPPlanMetadataModule.SignalCapability[] memory signalCapabilities
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
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0),
            publisherPrivateKey
        );
        machine.finalizePlan(
            planId,
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0)
        );
    }

    function _commitPlanWithKey(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        IUVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings,
        IUVPPlanMetadataModule.SignalCapability[] memory signalCapabilities,
        uint256 publisherPrivateKey
    ) private returns (bytes32 planId) {
        address publisher = vm.addr(publisherPrivateKey);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            metadataHash: keccak256(abi.encode(selectorBindings, signalCapabilities)),
            deadline: block.timestamp + 1 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(PLAN_COMMIT_TYPEHASH, commit.publisher, commit.hooksHash, commit.metadataHash, commit.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherPrivateKey, digest);
        planId = machine.commitPlan(commit, hooks, _packedSignature(v, r, s));
        PLAN_ID = planId;
        _planIds[address(machine)] = planId;
    }

    function _registeredOverlayMachine(address selector, address executor) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _overlaySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(selector, executor, SUBMITTER_B)
        );
        vm.prank(selector);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x9101)));
    }

    function _activateInitialStageExecutor(UVPStateMachine machine, address selector, address executor) private {
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, executor, PATCH_HASH);
        if (selector == address(this)) {
            _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
            return;
        }
        vm.prank(selector);
        _stagePatch(machine).applyStageExecutorPatch(PLAN_ID, ORDER_ID, patch);
    }

    function _dockingGasMachine() private returns (UVPStateMachine machine) {
        machine = _dockingGasMachineBeforeLink();
        _docking(machine).linkDockedOrder(PLAN_ID, ORDER_ID, _dockedOrderLink());
    }

    function _dockingGasMachineBeforeLink() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlan(
            machine,
            _withOrderStart(_positiveHookPlan(HOOK_INIT, true)),
            _selectorBindings(),
            _emptySignalCapabilities()
        );
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _dockedLocalAuthorizations(address(this))
        );
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID_2, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_VERIFY_FAIL, SUBMITTER_A)
        );
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
        UVPDockingModule docking = new UVPDockingModule(address(machine));
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(machine));
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
        authorizations[1] = _stageAuthorization(STAGE_AUDIT, SIGNAL_VERIFY_FAIL, submitter);
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

    function _dockedOrderLink() private view returns (UVPDockingModule.DockedOrderLink memory) {
        UVPDockingModule.DockedSignalBinding[] memory signalBindings = new UVPDockingModule.DockedSignalBinding[](1);
        signalBindings[0] = UVPDockingModule.DockedSignalBinding({
            localSourceId: SOURCE_BOOTSTRAP,
            localSignalId: SIGNAL_TRIGGER,
            linkedSourceId: SOURCE_BOOTSTRAP,
            linkedSignalId: SIGNAL_VERIFY_FAIL
        });
        return UVPDockingModule.DockedOrderLink({
            selectorStageId: STAGE_INIT,
            localSourceId: STAGE_AUDIT,
            linkedOrderId: ORDER_ID_2,
            linkedPlanId: PLAN_ID,
            linkHash: PATCH_HASH,
            linkNonce: 1,
            metadataURI: "ipfs://docked-link",
            signalBindings: signalBindings
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
        bytes32 orderId,
        bytes32 planId,
        address creator,
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private {
        _submitTriggerOrderFromOutsideWithKey(machine, planId, orderId, creator, authorizations, SUBMITTER_PRIVATE_KEY);
    }

    function _submitTriggerOrderFromOutsideWithKey(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        address creator,
        UVPStateMachine.SignalAuthorization[] memory authorizations,
        uint256 submitterPrivateKey
    ) private {
        address submitter = vm.addr(submitterPrivateKey);
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            orderId: orderId,
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

    function _outsideTriggerRequest(bytes32 orderId, bytes32 triggerHookId, bytes32 signalId)
        private
        returns (UVPStateMachine.TriggerOrderFromOutsideRequest memory)
    {
        return UVPStateMachine.TriggerOrderFromOutsideRequest({
            orderId: orderId,
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
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature);
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
        return _derivedSignalRequestWithPlans(fromOrderId, fromStageId, PLAN_ID, targetOrderId, PLAN_ID, targetSourceId, signalId, payloadHash, idempotencyKey);
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

    function _signalTriggerRequest(bytes32 orderId, bytes32 triggerOriginOrderId, bytes32 idempotencyKey)
        private
        returns (IUVPStateMachineCore.TriggerOrderFromSignalRequest memory)
    {
        return IUVPStateMachineCore.TriggerOrderFromSignalRequest({
            orderId: orderId,
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
        _orderLink(machine).triggerOrderFromSignalFor(trigger, moduleAuthorizations, signature);
    }

    function _triggerOrderFromSignalForKey(
        UVPStateMachine machine,
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger,
        IUVPStateMachineCore.SignalAuthorization[] memory moduleAuthorizations,
        uint256 submitterPrivateKey
    ) private {
        bytes memory signature =
            _triggerOrderFromSignalSignature(machine, trigger, moduleAuthorizations, submitterPrivateKey);
        _orderLink(machine).triggerOrderFromSignalFor(trigger, moduleAuthorizations, signature);
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
                trigger.orderId,
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

    function _timerHookPlan(bytes32 hookId, uint64 delaySeconds)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(delaySeconds);

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hook(hookId, STAGE_INIT, HOOK_NAME_TIMEOUT, true, instructions, _deps(SIGNAL_TRIGGER));
    }

    function _negativeHookPlan(bytes32 hookId) private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _not();
        instructions[2] = _signal(SIGNAL_TRIGGER);
        instructions[3] = _and(2);

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hook(
            hookId, STAGE_INIT, HOOK_NAME_TIMEOUT, true, instructions, _deps2(SIGNAL_VERIFY_FAIL, SIGNAL_TRIGGER)
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

    function _orRollbackPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _signal(SIGNAL_INIT_CMP);
        instructions[2] = _or(2);

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hook(
            HOOK_ROLLBACK,
            STAGE_ROLLBACK,
            HOOK_NAME_FAILURE,
            true,
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

    function _selectorBindings()
        private
        pure
        returns (IUVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings)
    {
        selectorBindings = new IUVPPlanMetadataModule.StageSelectorBinding[](1);
        selectorBindings[0] =
            IUVPPlanMetadataModule.StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
    }

    function _signalCapabilities()
        private
        pure
        returns (IUVPPlanMetadataModule.SignalCapability[] memory capabilities)
    {
        capabilities = new IUVPPlanMetadataModule.SignalCapability[](1);
        capabilities[0] = IUVPPlanMetadataModule.SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_VERIFY_FAIL, targetOrderRelation: 1
        });
    }

    function _overlaySignalCapabilities()
        private
        pure
        returns (IUVPPlanMetadataModule.SignalCapability[] memory capabilities)
    {
        capabilities = new IUVPPlanMetadataModule.SignalCapability[](2);
        capabilities[0] = IUVPPlanMetadataModule.SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        capabilities[1] = IUVPPlanMetadataModule.SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_REVIEW, targetOrderRelation: 0
        });
    }

    function _emptySignalCapabilities()
        private
        pure
        returns (IUVPPlanMetadataModule.SignalCapability[] memory capabilities)
    {
        capabilities = new IUVPPlanMetadataModule.SignalCapability[](0);
    }

    function _duplicateSelectorBindings()
        private
        pure
        returns (IUVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings)
    {
        selectorBindings = new IUVPPlanMetadataModule.StageSelectorBinding[](2);
        selectorBindings[0] =
            IUVPPlanMetadataModule.StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
        selectorBindings[1] =
            IUVPPlanMetadataModule.StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
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
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: hookName,
            isTrigger: isTrigger,
            instructions: instructions,
            dependencyKeys: dependencyKeys
        });
    }

    function _signal(bytes32 signalId) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.Signal,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
    }

    function _not() private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.Not, sourceId: bytes32(0), signalId: bytes32(0), arity: 0, delaySeconds: 0
        });
    }

    function _or(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.Or,
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _and(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.And,
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _delay(uint64 delaySeconds) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.Delay,
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

    function _countHookReady(Vm.Log[] memory logs) private pure returns (uint256 count) {
        bytes32 topic = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                count++;
            }
        }
    }

    function _countSignalSubmitterAuthorized(Vm.Log[] memory logs) private pure returns (uint256 count) {
        bytes32 topic = keccak256("SignalSubmitterAuthorized(bytes32,bytes32,bytes32,address,bytes32,bytes32)");
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
        hooks[0] = _hook(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            true,
            instructions,
            _deps2(SIGNAL_TRIGGER, bytes32(uint256(0x4002)))
        );

        UVPStateMachine machine = _registeredMachine(hooks);

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

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
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, bytes32(uint256(0x4002)), PAYLOAD_HASH, bytes32(uint256(0x4003))
        );
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "late branch must not regress ready");
    }

    function testChainedDelayAnchorsOnMaturityMoment() public {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(1);
        instructions[2] = _delay(5);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hook(HOOK_TIMEOUT, STAGE_INIT, HOOK_NAME_TIMEOUT, true, instructions, _deps(SIGNAL_TRIGGER));

        UVPStateMachine machine = _registeredMachine(hooks);

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

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

    function testMergeDeliversOnFirstContributingSignal() public {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(bytes32(uint256(0x5002)));
        instructions[2] = UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.Merge,
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 2,
            delaySeconds: 0
        });

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hook(
            HOOK_INIT,
            STAGE_INIT,
            HOOK_NAME_TRIGGER,
            true,
            instructions,
            _deps2(SIGNAL_TRIGGER, bytes32(uint256(0x5002)))
        );

        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(hooks));
        UVPStateMachine.SignalAuthorization[] memory authorizations =
            new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _authorization(SIGNAL_TRIGGER, address(this));
        authorizations[1] = _authorization(bytes32(uint256(0x5002)), address(this));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, authorizations);

        vm.warp(100);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        (UVPStateMachine.HookStatus status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "merge delivers on first arrival");

        vm.warp(200);
        machine.submitSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, bytes32(uint256(0x5002)), PAYLOAD_HASH, bytes32(uint256(0x5003))
        );
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "late branch must not regress ready");
    }

    function testCommitPlanRejectsCrossStageSharedDependencyKey() public {
        UVPStateMachine machine = _newUnfrozenMachine();
        machine.freezeModules();

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] =
            _signalHook(bytes32(uint256(0x9002)), STAGE_AUDIT, bytes32("WATCHER"), false, SIGNAL_TRIGGER);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.CrossStageDependency.selector,
                keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TRIGGER))
            )
        );
        _commitPlan(machine, hooks, new IUVPPlanMetadataModule.StageSelectorBinding[](0), new IUVPPlanMetadataModule.SignalCapability[](0));
    }

    function testCommitPlanAcceptsSameStageSharedDependencyKey() public {
        UVPStateMachine machine = _newUnfrozenMachine();
        machine.freezeModules();

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] =
            _signalHook(bytes32(uint256(0x9003)), STAGE_INIT, bytes32("PEER_WATCHER"), false, SIGNAL_TRIGGER);

        bytes32 planId = _commitPlan(machine, hooks, new IUVPPlanMetadataModule.StageSelectorBinding[](0), new IUVPPlanMetadataModule.SignalCapability[](0));
        require(machine.planCommitted(planId), "plan should commit");
    }

    // ------------------------------------------------------------------
    // 审计 #10 / #1 残余：跨 plan 攻击负例。每个用例先复现攻击前提，
    // 再断言隔离或 revert。
    // ------------------------------------------------------------------

    /// 审计 #10 抢注场景：攻击者先在自己的 plan 下注册受害方将要派生的
    /// orderId。修复前全局 `_orders[orderId]` 会让受害方的合法铸单永久
    /// OrderAlreadyRegistered（DoS + 身份伪装）；修复后 (planId, orderId)
    /// 复合寻址使两个订单共存且互不可见。
    function testCrossPlanOrderIdSquattingIsIsolated() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));

        // 攻击者与受害方各自提交 hooks 相同、publisher 不同的 plan。
        bytes32 attackerPlanId = _registerPlanWithKey(machine, hooks, ATTACKER_PUBLISHER_PRIVATE_KEY);
        bytes32 victimPlanId = _registerPlanWithKey(machine, hooks, PUBLISHER_PRIVATE_KEY);
        require(attackerPlanId != victimPlanId, "plan ids must differ");

        // 攻击者抢先用受害方将使用的 orderId 在自己的 plan 下铸单。
        address attackerSubmitter = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine,
            attackerPlanId,
            ORDER_ID,
            attackerSubmitter,
            _auths1(SIGNAL_TRIGGER, attackerSubmitter),
            ATTACKER_SUBMITTER_PRIVATE_KEY
        );
        require(machine.orderExists(attackerPlanId, ORDER_ID), "attacker order missing");

        // 复现点：受害方随后铸造同一 orderId——修复前此处必然
        // OrderAlreadyRegistered，现在必须成功。
        address victimSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine,
            victimPlanId,
            ORDER_ID,
            victimSubmitter,
            _auths1(SIGNAL_TRIGGER, victimSubmitter),
            SUBMITTER_PRIVATE_KEY
        );
        require(machine.orderExists(victimPlanId, ORDER_ID), "victim order blocked by squatting");

        // 身份隔离：受害方在其 plan 内正常推进 hook，攻击者订单不受影响。
        vm.prank(victimSubmitter);
        machine.submitSignal(victimPlanId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        (UVPStateMachine.HookStatus victimStatus,, bool victimReady) =
            machine.getHookStatus(victimPlanId, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus attackerStatus,, bool attackerReady) =
            machine.getHookStatus(attackerPlanId, ORDER_ID, HOOK_INIT);
        require(victimStatus == UVPStateMachine.HookStatus.Ready, "victim hook not ready");
        require(victimReady, "victim ready marker missing");
        require(attackerStatus == UVPStateMachine.HookStatus.Init, "attacker order contaminated");
        require(!attackerReady, "attacker ready marker set");

        // 跨 plan 不可寻址：受害方提交者无法给攻击者订单提交信号。
        vm.prank(victimSubmitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_TRIGGER,
                victimSubmitter
            )
        );
        machine.submitSignal(attackerPlanId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        // 同 plan 重放幂等保持不变。
        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        _submitTriggerOrderFromOutsideWithKey(
            machine,
            victimPlanId,
            ORDER_ID,
            victimSubmitter,
            _auths1(SIGNAL_TRIGGER, victimSubmitter),
            SUBMITTER_PRIVATE_KEY
        );
    }

    /// 审计 #1 残余 capability 镜像场景：攻击者 plan 完整镜像受害方 plan
    /// 的公开 trigger hook 与 capability 声明后，仍不得把受害方订单当作
    /// trigger-origin 建链（origin 侧同意缺失）。
    function testCrossPlanCapabilityMirrorIsRejected() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_sequentialPlan());
        IUVPPlanMetadataModule.SignalCapability[] memory capabilities = _signalCapabilities();
        IUVPPlanMetadataModule.StageSelectorBinding[] memory noSelectorBindings =
            new IUVPPlanMetadataModule.StageSelectorBinding[](0);

        bytes32 victimPlanId = _commitPlanWithKey(machine, hooks, noSelectorBindings, capabilities, PUBLISHER_PRIVATE_KEY);
        machine.finalizePlan(victimPlanId, noSelectorBindings, capabilities);
        bytes32 attackerPlanId =
            _commitPlanWithKey(machine, hooks, noSelectorBindings, capabilities, ATTACKER_PUBLISHER_PRIVATE_KEY);
        machine.finalizePlan(attackerPlanId, noSelectorBindings, capabilities);

        // 攻击前提成立：镜像 plan 的 capability 声明与受害方 plan 完全一致。
        require(
            _planMetadata(machine).isSignalCapabilityRegistered(
                attackerPlanId,
                STAGE_AUDIT,
                SOURCE_BOOTSTRAP,
                SIGNAL_VERIFY_FAIL,
                _planMetadata(machine).SIGNAL_TARGET_TRIGGER_ORIGIN()
            ),
            "mirror capability missing"
        );

        // 受害方订单与 origin 事实。
        address victimSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine,
            victimPlanId,
            ORDER_ID,
            victimSubmitter,
            _auths1(SIGNAL_TRIGGER, victimSubmitter),
            SUBMITTER_PRIVATE_KEY
        );
        vm.prank(victimSubmitter);
        machine.submitSignal(victimPlanId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        // 攻击者（无 origin 侧任何身份）尝试把自己的派生单挂到受害方订单上。
        address attacker = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory mirrored = IUVPStateMachineCore
            .TriggerOrderFromSignalRequest({
            orderId: ORDER_ID_2,
            planId: attackerPlanId,
            creator: attacker,
            triggerOriginOrderId: ORDER_ID,
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
            abi.encodeWithSelector(UVPStateMachine.UnauthorizedTriggerOrigin.selector, victimPlanId, ORDER_ID, attacker)
        );
        _orderLink(machine).triggerOrderFromSignalFor(mirrored, noAuthorizations, mirroredSignature);

        // 链接未建立、派生单未铸造。
        (bool linked,,,,,) = _orderLink(machine).getTriggerOriginLink(attackerPlanId, ORDER_ID_2);
        require(!linked, "mirror link was registered");
        require(!machine.orderExists(attackerPlanId, ORDER_ID_2), "mirror order minted");

        // 即便攻击者另行铸造无链接订单，跨 plan 派生仍被 relation 查找拒绝。
        _submitTriggerOrderFromOutsideWithKey(
            machine,
            attackerPlanId,
            ORDER_ID_2,
            attacker,
            _auths1(SIGNAL_TRIGGER, attacker),
            ATTACKER_SUBMITTER_PRIVATE_KEY
        );
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UVPOrderLinkModule.UnknownOrderTriggerLink.selector, ORDER_ID_2));
        _derivedSignal(machine).submitDerivedSignal(
            _derivedSignalRequestWithPlans(
                ORDER_ID_2,
                STAGE_AUDIT,
                attackerPlanId,
                ORDER_ID,
                victimPlanId,
                SOURCE_BOOTSTRAP,
                SIGNAL_VERIFY_FAIL,
                PAYLOAD_HASH,
                bytes32(uint256(3))
            ),
            attacker
        );
    }

    /// 审计 #1 残余 origin 同意的正向面：origin 事实授权的提交者、origin
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
            machine,
            planId,
            ORDER_ID,
            ORDER_CREATOR,
            _auths1(SIGNAL_TRIGGER, triggerSubmitter),
            SUBMITTER_PRIVATE_KEY
        );
        vm.prank(triggerSubmitter);
        machine.submitSignal(planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(ORDER_ID_2, ORDER_ID, bytes32(uint256(2)));
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths = _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        // 攻击者自签自提：无任何 origin 身份 → UnauthorizedTriggerOrigin。
        address attacker = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory attackerRequest = _signalTriggerRequest(
            ORDER_ID_2, ORDER_ID, bytes32(uint256(2))
        );
        attackerRequest.submitter = attacker;
        attackerRequest.creator = attacker;
        bytes memory attackerSignature =
            _triggerOrderFromSignalSignature(machine, attackerRequest, childAuths, ATTACKER_SUBMITTER_PRIVATE_KEY);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnauthorizedTriggerOrigin.selector, planId, ORDER_ID, attacker)
        );
        _orderLink(machine).triggerOrderFromSignalFor(attackerRequest, childAuths, attackerSignature);

        // 授权 submitter 执行：relayer 是无关方也允许（submitter 有事实授权）。
        bytes memory requestSignature =
            _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        _orderLink(machine).triggerOrderFromSignalFor(request, childAuths, requestSignature);
        (bool relayerLinked,,,,,) = _orderLink(machine).getTriggerOriginLink(planId, ORDER_ID_2);
        require(relayerLinked, "authorized relayer link missing");

        // (2) origin 订单创建者身份：该订单只授权他人提交 origin 事实，
        // 创建者本人未获任何授权，仍可作为 submitter 触发其派生单。
        bytes32 secondOriginOrderId = bytes32(uint256(0x2004));
        _submitTriggerOrderFromOutsideWithKey(
            machine, planId, secondOriginOrderId, triggerSubmitter, _auths1(SIGNAL_TRIGGER, SUBMITTER_A), SUBMITTER_PRIVATE_KEY
        );
        vm.prank(SUBMITTER_A);
        machine.submitSignal(planId, secondOriginOrderId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory creatorTrigger = IUVPStateMachineCore
            .TriggerOrderFromSignalRequest({
            orderId: bytes32(uint256(0x2003)),
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
        (bool creatorLinked,,,,,) = _orderLink(machine).getTriggerOriginLink(planId, bytes32(uint256(0x2003)));
        require(creatorLinked, "creator consent link missing");
    }

}
