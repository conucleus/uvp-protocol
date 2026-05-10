// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
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

    bytes32 private constant PLAN_ID = bytes32(uint256(0x1001));
    bytes32 private constant PLAN_HASH = bytes32(uint256(0x1002));
    bytes32 private constant PLAN_ID_2 = bytes32(uint256(0x1007));
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
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.7");
    bytes32 private constant SIGNAL_SUBMISSION_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 orderId,bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    function testConstructorSetsOwnerWithoutRegistryBinding() public {
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
        machine.setPlanPublisher(NON_OWNER, true);
    }

    function testOnlyOwnerCanSetPublisherAndRegistrar() public {
        UVPStateMachine machine = new UVPStateMachine();

        vm.prank(NON_OWNER);
        vm.expectRevert(UVPStateMachine.NotOwner.selector);
        machine.setPlanPublisher(SUBMITTER_A, true);

        vm.prank(NON_OWNER);
        vm.expectRevert(UVPStateMachine.NotOwner.selector);
        machine.setOrderRegistrar(SUBMITTER_B, true);

        vm.recordLogs();
        machine.setPlanPublisher(SUBMITTER_A, true);
        machine.setOrderRegistrar(SUBMITTER_B, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.planPublishers(SUBMITTER_A), "publisher not set");
        require(machine.orderRegistrars(SUBMITTER_B), "registrar not set");
        require(_countTopic(logs, keccak256("PlanPublisherSet(address,bool)")) == 1, "publisher event count");
        require(_countTopic(logs, keccak256("OrderRegistrarSet(address,bool)")) == 1, "registrar event count");
    }

    function testUnauthorizedRegisterPlanReverts() public {
        UVPStateMachine machine = new UVPStateMachine();

        vm.expectRevert(UVPStateMachine.UnauthorizedPlanPublisher.selector);
        machine.registerPlan(PLAN_ID, PLAN_HASH, _positiveHookPlan(HOOK_INIT, true));
    }

    function testUnauthorizedTriggerOrderReverts() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));

        UVPStateMachine.SignalAuthorization[] memory authorizations = _defaultAuthorizations(address(this));
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        uint256 deadline = block.timestamp + 1 hours;
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            orderId: ORDER_ID,
            planId: PLAN_ID,
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
        vm.expectRevert(UVPStateMachine.UnauthorizedOrderRegistrar.selector);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature);
    }

    function testDuplicatePlanAndOrderStillRevert() public {
        UVPStateMachine machine = _newMachine();

        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        vm.expectRevert(UVPStateMachine.PlanAlreadyRegistered.selector);
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));

        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        UVPStateMachine.SignalAuthorization[] memory duplicateAuthorizations = _defaultAuthorizations(address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory duplicateTrigger =
            _outsideTriggerRequest(ORDER_ID, HOOK_ORDER_START, SIGNAL_ORDER_START);
        bytes memory duplicateSignature =
            _triggerOrderFromOutsideSignature(machine, duplicateTrigger, duplicateAuthorizations, SUBMITTER_PRIVATE_KEY);
        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        machine.triggerOrderFromOutsideFor(duplicateTrigger, duplicateAuthorizations, duplicateSignature);
    }

    function testRemovedPublisherAndRegistrarCannotRegisterNewFacts() public {
        UVPStateMachine machine = _newMachine();

        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        machine.setPlanPublisher(address(this), false);
        vm.expectRevert(UVPStateMachine.UnauthorizedPlanPublisher.selector);
        machine.registerPlan(PLAN_ID_2, PLAN_HASH, _positiveHookPlan(HOOK_NON_TRIGGER, true));

        machine.setOrderRegistrar(address(this), false);
        UVPStateMachine.SignalAuthorization[] memory authorizations = _defaultAuthorizations(address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(ORDER_ID_2, HOOK_ORDER_START, SIGNAL_ORDER_START);
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);
        vm.expectRevert(UVPStateMachine.UnauthorizedOrderRegistrar.selector);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature);
    }

    function testRemovedPublisherAndRegistrarDoNotBreakExistingOrderSignals() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        machine.setPlanPublisher(address(this), false);
        machine.setOrderRegistrar(address(this), false);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "old order not ready");
        require(readyEmitted, "old order ready marker missing");
    }

    function testRegisterPlanDoesNotRequireTrustRegistryAttestation() public {
        UVPStateMachine machine = _newMachine();

        machine.registerPlan(PLAN_ID, PLAN_HASH, _positiveHookPlan(HOOK_INIT, true));
        require(machine.planExists(PLAN_ID), "plan not registered");
    }

    function testRegistryAgnosticMachineKeepsExistingOrderSignals() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "old order not ready");
        require(readyEmitted, "old order ready marker missing");
    }

    function testRegisterPlanAndOrder() public {
        UVPStateMachine machine = _newMachine();

        vm.recordLogs();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.planExists(PLAN_ID), "plan not registered");
        require(machine.orderExists(ORDER_ID), "order not registered");
        require(machine.orderPlanId(ORDER_ID) == PLAN_ID, "bad order plan");
        require(machine.planPublisher(PLAN_ID) == address(this), "bad plan publisher");
        require(machine.orderRegistrar(ORDER_ID) == address(this), "bad order registrar");
        require(machine.orderCreator(ORDER_ID) == ORDER_CREATOR, "bad order creator");
        require(_countTopic(logs, keccak256("PlanPublisherRecorded(bytes32,address)")) == 1, "publisher record count");
        require(
            _countTopic(logs, keccak256("OrderRegistrarRecorded(bytes32,address,address)")) == 1,
            "registrar record count"
        );
        require(_countSignalSubmitterAuthorized(logs) == 4, "authorization event count");
        require(
            machine.isSignalSubmitterAuthorized(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, address(this)),
            "submitter not authorized"
        );
        require(
            !machine.isSignalSubmitterAuthorized(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, SUBMITTER_A),
            "unexpected submitter auth"
        );
        (bool authExists, bytes32 role, bytes32 metadataHash) =
            machine.getSignalAuthorization(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, address(this));
        require(authExists, "authorization missing");
        require(role == ROLE_BOOTSTRAP, "bad authorization role");
        require(metadataHash == AUTH_METADATA_HASH, "bad authorization metadata");

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Init, "hook not init");
        require(dueAt == 0, "unexpected due");
        require(!readyEmitted, "unexpected ready marker");
    }

    function testRegisterPlanStoresStageSelectorBindings() public {
        UVPStateMachine machine = _newMachine();

        vm.recordLogs();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _sequentialPlan());
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _emptySignalCapabilities());
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
        machine.registerPlan(PLAN_ID, PLAN_HASH, _sequentialPlan());
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _signalCapabilities());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(_planMetadata(machine).planSignalCapabilityCount(PLAN_ID) == 1, "bad capability count");
        require(
            _planMetadata(machine).isSignalCapabilityRegistered(
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

        machine.registerPlan(PLAN_ID, PLAN_HASH, _sequentialPlan());
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPPlanMetadataModule.StageSelectorBindingAlreadyRegistered.selector, PLAN_ID, STAGE_INIT, STAGE_AUDIT
            )
        );
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _duplicateSelectorBindings(), _emptySignalCapabilities());
    }

    function testTriggerOrderFromOutsideCreatesAndMaterializesOrder() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _sequentialPlan());

        vm.recordLogs();
        _submitTriggerOrderFromOutsideRequest(
            machine,
            _outsideTriggerRequest(ORDER_ID, HOOK_INIT, SIGNAL_TRIGGER),
            _auths1(SIGNAL_TRIGGER, SUBMITTER_A),
            SUBMITTER_PRIVATE_KEY
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.orderExists(ORDER_ID), "order missing");
        require(machine.hasSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "trigger signal missing");
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

        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

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
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        ) = _orderLink(machine).getTriggerOriginLink(ORDER_ID_2);
        require(exists, "link missing");
        require(triggerOriginOrderId == ORDER_ID, "bad trigger origin");
        require(originSourceId == SOURCE_BOOTSTRAP, "bad origin source");
        require(originSignalId == SIGNAL_TRIGGER, "bad origin signal");
        require(triggerStageId == STAGE_INIT, "bad trigger stage");
        require(!machine.hasSignal(ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "origin signal copied to triggered");
        require(
            _countTopic(logs, keccak256("OrderLinked(bytes32,bytes32,bytes32,bytes32,bytes32)")) == 1,
            "link event count"
        );
    }

    function testDerivedSignalUsesPlanCapabilityToWriteBackToTriggerOrigin() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _signalCapabilities());
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(ORDER_ID_2, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(
            ORDER_ID_2, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(3))
        );

        require(
            machine.hasSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL),
            "derived signal missing on trigger origin"
        );
    }

    function testDerivedSignalRejectsMissingPlanCapability() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(ORDER_ID_2, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPDerivedSignalModule.InvalidSignalCapability.selector);
        _derivedSignal(machine).submitDerivedSignal(
            ORDER_ID_2, STAGE_AUDIT, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(3))
        );
    }

    function testApplyStageExecutorPatchStoresActiveOverlayAndEmitsEvents() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);

        vm.recordLogs();
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, patch);
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
            _countTopic(logs, keccak256("StageExecutorActivated(bytes32,bytes32,address,bytes32,bytes32,uint256)")) == 1,
            "executor event count"
        );
        require(machine.activeStageExecutor(ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "bad active executor");
        require(_stagePatch(machine).orderStageExecutorPatchNonce(ORDER_ID, STAGE_AUDIT) == 1, "bad patch nonce");
        require(
            machine.isSignalSubmitterAuthorized(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_B),
            "explicit signal auth should survive active executor patch"
        );

        (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        ) = _stagePatch(machine).getActiveStageExecutorPatch(ORDER_ID, STAGE_AUDIT);
        require(exists, "active patch missing");
        require(executor == SUBMITTER_A, "bad executor");
        require(role == ROLE_EXECUTOR, "bad role");
        require(executorMetadataHash == EXECUTOR_METADATA_HASH, "bad executor metadata");
        require(patchHash == PATCH_HASH, "bad patch hash");
        require(patchNonce == 1, "bad stored nonce");
        require(keccak256(bytes(metadataURI)) == keccak256(bytes("uvp-eth://executor-patch")), "bad metadata uri");

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY);
        require(machine.hasSourceSignal(ORDER_ID, STAGE_AUDIT), "target source signal not marked");
        require(machine.sourceSignalCount(ORDER_ID, STAGE_AUDIT) == 1, "target signal count not tracked");
        require(machine.lastSignalSubmitter(ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "last submitter not tracked");
    }

    function testApplyStageExecutorPatchRejectsUnauthorizedSelector() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _targetSignalAuthorizations(SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageExecutorPatchSelector.selector, ORDER_ID, STAGE_INIT, address(this)
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
    }

    function testApplyStageExecutorPatchRejectsMissingSelectorBinding() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageSelectorBindingNotFound.selector, PLAN_ID, STAGE_INIT, STAGE_AUDIT
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
    }

    function testApplyStageExecutorPatchRejectsNonIncreasingNonce() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH));

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchNonceNotIncreasing.selector, ORDER_ID, STAGE_AUDIT, 2, 2
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH_2));
    }

    function testApplyStageExecutorPatchAssignRejectsAfterTargetStageSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
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
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, previousPatch);

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
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, approvalPatch);
    }

    function testApplyStageExecutorPatchRejectsZeroExecutorAndPatchHash() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.expectRevert(UVPStagePatchModule.ZeroStageExecutor.selector);
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, address(0), PATCH_HASH));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, patch);
    }

    function testApplyStageExecutorPatchDoesNotRequireTrustRegistryAttestation() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
        require(machine.activeStageExecutor(ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "patch not applied");
    }

    function testRelayerCanApplyStageExecutorPatchWithSelectorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine).applyStageExecutorPatchFor(
            ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), ""
        );

        require(machine.activeStageExecutor(ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "relayed patch not applied");
    }

    function testRelayedStageExecutorPatchRejectsWrongSigner() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address wrongSigner = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, selector, wrongSigner
            )
        );
        _stagePatch(machine).applyStageExecutorPatchFor(
            ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), ""
        );
    }

    function testRelayedStageExecutorPatchRejectsExpiredSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp - 1;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.ExpiredStageExecutorPatchSignature.selector, deadline)
        );
        _stagePatch(machine).applyStageExecutorPatchFor(
            ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), ""
        );
    }

    function testHandoffStageExecutorPatchSucceedsWithPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, bytes32(0), bytes32(0)
        );
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(ORDER_ID, patch, selector, deadline);
            (uint8 selectorV, bytes32 selectorR, bytes32 selectorS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            (uint8 previousV, bytes32 previousR, bytes32 previousS) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

            vm.prank(UNAUTHORIZED_SUBMITTER);
            _stagePatch(machine).applyStageExecutorPatchFor(
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(selectorV, selectorR, selectorS),
                _packedSignature(previousV, previousR, previousS)
            );
        }

        require(machine.activeStageExecutor(ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff executor not active");
        (,,,, address originalSubmitter) = machine.getSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(originalSubmitter == previousExecutor, "prior signal attribution changed");

        vm.prank(previousExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_AUDIT, previousExecutor, SUBMITTER_B
            )
        );
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(2)));

        vm.prank(SUBMITTER_B);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(2)));
        require(machine.sourceSignalCount(ORDER_ID, STAGE_AUDIT) == 2, "handoff signal count not tracked");
        require(machine.lastSignalSubmitter(ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff last submitter not tracked");
    }

    function testHandoffStageExecutorPatchFailsWithoutPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, bytes32(0), bytes32(0)
        );
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(ORDER_ID, patch, selector, deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

            vm.expectRevert(
                abi.encodeWithSelector(
                    UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
                )
            );
            _stagePatch(machine).applyStageExecutorPatchFor(
                ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s), ""
            );
        }

        vm.prank(selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, patch);
    }

    function testHandoffStageExecutorPatchFailsWithWrongPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, bytes32(0), bytes32(0)
        );
        {
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(ORDER_ID, patch, selector, deadline);
            (uint8 selectorV, bytes32 selectorR, bytes32 selectorS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            (uint8 wrongV, bytes32 wrongR, bytes32 wrongS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

            vm.expectRevert(
                abi.encodeWithSelector(
                    UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, selector
                )
            );
            _stagePatch(machine).applyStageExecutorPatchFor(
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(selectorV, selectorR, selectorS),
                _packedSignature(wrongV, wrongR, wrongS)
            );
        }
    }

    function testHandoffStageExecutorPatchRejectsApprovalFields() public {
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(address(this), previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        machine.submitSignal(ORDER_ID, STAGE_INIT, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(2)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor, STAGE_INIT, SIGNAL_AUDIT_PASS
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchApprovalSignalMissing.selector,
                ORDER_ID,
                STAGE_INIT,
                SIGNAL_AUDIT_PASS
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, patch);
    }

    function testReplacementStageExecutorPatchSucceedsWithApprovalSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));
        machine.submitSignal(ORDER_ID, STAGE_INIT, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(2)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_REPLACEMENT, SUBMITTER_A, STAGE_INIT, SIGNAL_AUDIT_PASS
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, patch);

        require(machine.activeStageExecutor(ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "replacement executor not active");
        (,,,, address originalSubmitter) = machine.getSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(originalSubmitter == SUBMITTER_A, "replacement rewrote prior submitter");

        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_AUDIT, SUBMITTER_A, SUBMITTER_B
            )
        );
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(3)));

        vm.prank(SUBMITTER_B);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, PAYLOAD_HASH, bytes32(uint256(3)));
    }

    function testReplacementStageExecutorPatchFailsWithoutApprovalSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_REPLACEMENT, SUBMITTER_A, STAGE_INIT, SIGNAL_AUDIT_PASS
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchApprovalSignalMissing.selector,
                ORDER_ID,
                STAGE_INIT,
                SIGNAL_AUDIT_PASS
            )
        );
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, patch);
    }

    function testStageExecutorPatchRejectsPreviousExecutorMismatch() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatchWithMode(
            1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_REPLACEMENT, SUBMITTER_B, STAGE_INIT, SIGNAL_AUDIT_PASS
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
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, patch);
    }

    function testActiveStageExecutorPatchBlocksExplicitButInactiveSubmitter() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));

        vm.prank(SUBMITTER_B);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedStageExecutor.selector, ORDER_ID, STAGE_AUDIT, SUBMITTER_B, SUBMITTER_A
            )
        );
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));
        (,,,, address submitter) = machine.getSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(submitter == SUBMITTER_A, "active executor not recorded");
    }

    function testStageSignalRequiresSourceStageMaterialization() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));

        (bool exists,,,,) = machine.getSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(!exists, "prematerialized stage signal was stored");

        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(3)));
        (exists,,,,) = machine.getSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(exists, "materialized stage signal missing");
    }

    function testActiveStageExecutorIsNotImplicitSignalAuthorization() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _stagePatchSelectorAuthorizations(address(this))
        );

        (bool staticAuthorization,,) =
            machine.getSignalAuthorization(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A);
        require(!staticAuthorization, "active executor unexpectedly pre-authorized");

        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SIGNAL_STAGE_DONE,
                SUBMITTER_A
            )
        );
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, bytes32(uint256(1)));
    }

    function testApplyStageResourcePatchStoresOverlayAndEmitsEvent() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);

        vm.recordLogs();
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, patch);
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
            _stagePatch(machine).orderStageResourcePatchNonce(ORDER_ID, STAGE_AUDIT, RESOURCE_KEY) == 1,
            "bad resource patch nonce"
        );
        require(machine.activeStageExecutor(ORDER_ID, STAGE_AUDIT) == address(0), "resource patch changed executor");

        (
            bool exists,
            bytes32 manifestHash,
            bytes32 policyHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory manifestURI
        ) = _stagePatch(machine).getActiveStageResourcePatch(ORDER_ID, STAGE_AUDIT, RESOURCE_KEY);
        require(exists, "resource patch missing");
        require(manifestHash == MANIFEST_HASH, "bad manifest hash");
        require(policyHash == RESOURCE_POLICY_HASH, "bad policy hash");
        require(patchHash == RESOURCE_PATCH_HASH, "bad resource patch hash");
        require(patchNonce == 1, "bad stored resource nonce");
        require(keccak256(bytes(manifestURI)) == keccak256(bytes("ipfs://resource-manifest")), "bad manifest uri");
    }

    function testApplyStageResourcePatchRejectsNonIncreasingNonceAndIsolatesResourceKeys() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, _stageResourcePatch(2, RESOURCE_PATCH_HASH));

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
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, _stageResourcePatch(2, RESOURCE_PATCH_HASH_2));

        _stagePatch(machine).applyStageResourcePatch(
            ORDER_ID, _stageResourcePatchWithKey(RESOURCE_KEY_2, 1, RESOURCE_PATCH_HASH_2)
        );
        require(
            _stagePatch(machine).orderStageResourcePatchNonce(ORDER_ID, STAGE_AUDIT, RESOURCE_KEY_2) == 1,
            "resource key nonce not isolated"
        );
    }

    function testApplyStageResourcePatchRejectsUnauthorizedSelector() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _targetSignalAuthorizations(SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageResourcePatchSelector.selector, ORDER_ID, STAGE_INIT, address(this)
            )
        );
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, _stageResourcePatch(1, RESOURCE_PATCH_HASH));
    }

    function testApplyStageResourcePatchRejectsAfterTargetStageSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, _stageResourcePatch(1, RESOURCE_PATCH_HASH));
    }

    function testApplyStageResourcePatchRejectsZeroFields() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.resourceKey = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroResourceKey.selector);
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, patch);

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.manifestHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroManifestHash.selector);
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, patch);

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.policyHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroPolicyHash.selector);
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, patch);

        patch = _stageResourcePatch(1, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _stagePatch(machine).applyStageResourcePatch(ORDER_ID, patch);
    }

    function testRelayerCanApplyStageResourcePatchWithSelectorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageResourcePatchDigest(ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine).applyStageResourcePatchFor(ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s));

        require(
            _stagePatch(machine).orderStageResourcePatchNonce(ORDER_ID, STAGE_AUDIT, RESOURCE_KEY) == 1,
            "relayed resource patch not applied"
        );
    }

    function testRelayedStageResourcePatchRejectsWrongSigner() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address wrongSigner = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageResourcePatchDigest(ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageResourcePatchSignature.selector, selector, wrongSigner
            )
        );
        _stagePatch(machine).applyStageResourcePatchFor(ORDER_ID, patch, selector, deadline, _packedSignature(v, r, s));
    }

    function testPositiveSignalMakesHookReady() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        vm.recordLogs();
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(dueAt == 0, "ready hook has due");
        require(readyEmitted, "ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "ready event count");

        (bool exists, bytes32 payloadHash, bytes32 idempotencyKey, uint64 submittedAt, address submitter) =
            machine.getSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(exists, "signal missing");
        require(payloadHash == PAYLOAD_HASH, "bad payload hash");
        require(idempotencyKey == IDEMPOTENCY_KEY, "bad idempotency key");
        require(submittedAt == uint64(block.timestamp), "bad submitted at");
        require(submitter == address(this), "bad submitter");
    }

    function testSharedSignalEvaluatesTriggerBeforeNonTriggerHooks() public {
        UVPStateMachine machine = _registeredMachine(_sharedDependencyPlanWithNonTriggerFirst());

        vm.recordLogs();
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus triggerStatus,, bool triggerReadyEmitted) =
            machine.getHookStatus(ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus nonTriggerStatus,, bool nonTriggerReadyEmitted) =
            machine.getHookStatus(ORDER_ID, HOOK_NON_TRIGGER);
        require(triggerStatus == UVPStateMachine.HookStatus.Ready, "trigger not ready");
        require(triggerReadyEmitted, "trigger ready marker missing");
        require(nonTriggerStatus == UVPStateMachine.HookStatus.Ready, "non-trigger not evaluated");
        require(!nonTriggerReadyEmitted, "non-trigger emitted ready");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "ready event count");
    }

    function testUnauthorizedSubmitterRevertsBeforeFirstWrite() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        require(
            !machine.isSignalSubmitterAuthorized(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER),
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
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        require(!machine.hasSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "unauthorized signal was written");
    }

    function testAuthorizedSubmitterCanAdvanceHook() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");

        (,,,, address submitter) = machine.getSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(submitter == SUBMITTER_A, "bad submitter");
    }

    function testRelayerCanSubmitAuthorizedSignalWithSubmitterSignature() public {
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, submitter, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        machine.submitSignalFor(
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            submitter,
            deadline,
            _packedSignature(v, r, s)
        );

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready");
        require(readyEmitted, "ready marker missing");

        (,,,, address recordedSubmitter) = machine.getSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(recordedSubmitter == submitter, "relayer became submitter");
    }

    function testRelayedSignalRejectsWrongSigner() public {
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        address wrongSigner = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _signalSubmissionDigest(
            machine, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, submitter, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidSignalSignature.selector, submitter, wrongSigner));
        machine.submitSignalFor(
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
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, submitter));

        uint256 deadline = block.timestamp - 1;
        bytes32 digest = _signalSubmissionDigest(
            machine, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, submitter, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredSignalSignature.selector, deadline));
        machine.submitSignalFor(
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
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths2SameSignal(SIGNAL_TRIGGER, SUBMITTER_A, SUBMITTER_B)
        );

        require(
            machine.isSignalSubmitterAuthorized(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, SUBMITTER_A),
            "submitter A not authorized"
        );
        require(
            machine.isSignalSubmitterAuthorized(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, SUBMITTER_B),
            "submitter B not authorized"
        );

        vm.prank(SUBMITTER_B);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.SignalAlreadyExists.selector);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(2)));

        (,,,, address submitter) = machine.getSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(submitter == SUBMITTER_B, "first writer changed");
    }

    function testSameWalletCanBeAuthorizedForMultipleSignals() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine,
            ORDER_ID,
            PLAN_ID,
            ORDER_CREATOR,
            _auths3ForSubmitter(SIGNAL_TRIGGER, SIGNAL_INIT_CMP, SIGNAL_AUDIT_PASS, SUBMITTER_A)
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));
        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));
        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)));

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_AUDIT);
        (UVPStateMachine.HookStatus timeoutStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_TIMEOUT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
        require(timeoutStatus == UVPStateMachine.HookStatus.Ready, "timeout not ready");
    }

    function testDifferentSignalsCanUseDifferentSubmitters() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(
            machine,
            ORDER_ID,
            PLAN_ID,
            ORDER_CREATOR,
            _splitSignalAuths(SIGNAL_TRIGGER, SUBMITTER_A, SIGNAL_INIT_CMP, SUBMITTER_B)
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));

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
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));

        vm.prank(SUBMITTER_B);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(3)));

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_AUDIT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
    }

    function testSequentialUpdateFlowHooksBecomeReady() public {
        UVPStateMachine machine = _registeredMachine(_sequentialPlan());

        vm.recordLogs();
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)));
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)));
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)));

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_AUDIT);
        (UVPStateMachine.HookStatus timeoutStatus,,) = machine.getHookStatus(ORDER_ID, HOOK_TIMEOUT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
        require(timeoutStatus == UVPStateMachine.HookStatus.Ready, "timeout not ready");
        require(_countHookReady(vm.getRecordedLogs()) == 3, "ready event count");
    }

    function testTimerWaitsUntilDueThenReady() public {
        UVPStateMachine machine = _registeredMachine(_timerHookPlan(HOOK_TIMEOUT, 60));

        vm.warp(100);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "hook not waiting");
        require(dueAt == 160, "bad dueAt");
        require(!readyEmitted, "early ready marker");

        vm.warp(159);
        vm.expectRevert(UVPStateMachine.TimerNotDue.selector);
        machine.pokeTimer(ORDER_ID, HOOK_TIMEOUT);

        vm.warp(160);
        vm.recordLogs();
        machine.pokeTimer(ORDER_ID, HOOK_TIMEOUT);

        (status, dueAt, readyEmitted) = machine.getHookStatus(ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "timer hook not ready");
        require(dueAt == 0, "timer ready has due");
        require(readyEmitted, "timer ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "timer ready event count");
    }

    function testNegativeSignalCancelsHook() public {
        UVPStateMachine machine = _registeredMachine(_negativeHookPlan(HOOK_TIMEOUT));

        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "hook not cancelled");
        require(dueAt == 0, "cancelled hook has due");
        require(!readyEmitted, "cancelled hook emitted ready");
    }

    function testOrBranchTriggersRollback() public {
        UVPStateMachine machine = _registeredMachine(_orRollbackPlan());

        vm.recordLogs();
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(ORDER_ID, HOOK_ROLLBACK);
        require(status == UVPStateMachine.HookStatus.Ready, "rollback not ready");
        require(readyEmitted, "rollback ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "rollback ready event");
    }

    function testDuplicateSignalReverts() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        vm.expectRevert(UVPStateMachine.SignalAlreadyExists.selector);
        machine.submitSignal(
            ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, bytes32(uint256(0x8002)), bytes32(uint256(0x9002))
        );
    }

    function testGasAttackerSubmitLinkedSignalForDocking() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _dockingGasMachine();

        vm.resumeGasMetering();
        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9002)));
        vm.pauseGasMetering();
    }

    function testGasLinkDockedOrderForOneSignalBinding() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _dockingGasMachineBeforeLink();

        vm.resumeGasMetering();
        uint256 linkBefore = gasleft();
        _docking(machine).linkDockedOrder(ORDER_ID, _dockedOrderLink());
        uint256 linkGas = linkBefore - gasleft();
        emit log_named_uint("link_docked_order_gas", linkGas);
        vm.pauseGasMetering();
    }

    function testGasApplyStageExecutorPatchAssignForDockSetup() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.resumeGasMetering();
        uint256 patchBefore = gasleft();
        _stagePatch(machine).applyStageExecutorPatch(ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
        uint256 patchGas = patchBefore - gasleft();
        emit log_named_uint("stage_executor_patch_assign_gas", patchGas);
        vm.pauseGasMetering();
    }

    function testGasRelaySubmitDockedSignal() public {
        vm.pauseGasMetering();
        UVPStateMachine machine = _dockingGasMachine();
        vm.prank(SUBMITTER_A);
        machine.submitSignal(ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9002)));

        vm.resumeGasMetering();
        _docking(machine).submitDockedSignal(
            ORDER_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, bytes32(uint256(0x9003))
        );
        vm.pauseGasMetering();
    }

    function testGasDockedSignalRelayRatioMeasurement() public {
        UVPStateMachine machine = _dockingGasMachine();

        vm.prank(SUBMITTER_A);
        uint256 attackerBefore = gasleft();
        machine.submitSignal(ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, bytes32(uint256(0x9002)));
        uint256 attackerGas = attackerBefore - gasleft();

        uint256 relayBefore = gasleft();
        _docking(machine).submitDockedSignal(
            ORDER_ID, ORDER_ID_2, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, bytes32(uint256(0x9003))
        );
        uint256 relayGas = relayBefore - gasleft();

        emit log_named_uint("attacker_linked_signal_gas", attackerGas);
        emit log_named_uint("relay_docked_signal_gas", relayGas);
        emit log_named_uint("relay_per_100_attacker", (relayGas * 100) / attackerGas);

        require(relayGas < attackerGas * 2, "relay gas ratio too high");
    }

    function testNonTriggerHookCannotMaterializeStageEntry() public {
        UVPStateMachine machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _positiveHookPlan(HOOK_NON_TRIGGER, false));

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

    function testStateMachineDoesNotDependOnEscrow() public {
        UVPStateMachine machine = _newMachine();

        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, address(this))
        );
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);

        (UVPStateMachine.HookStatus status,,) = machine.getHookStatus(ORDER_ID, HOOK_INIT);
        require(status == UVPStateMachine.HookStatus.Ready, "state machine required escrow");
    }

    function testTriggerOrderWithoutAuthorizationsDoesNotOpenSignalSubmission() public {
        UVPStateMachine machine = _newMachine();

        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, new UVPStateMachine.SignalAuthorization[](0)
        );

        require(
            !machine.isSignalSubmitterAuthorized(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER),
            "order unexpectedly open"
        );
        (bool authExists,,) =
            machine.getSignalAuthorization(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, UNAUTHORIZED_SUBMITTER);
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
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY);
    }

    function _registeredMachine(UVPStateMachine.CompactHook[] memory hooks) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(hooks));
        _submitTriggerOrderFromOutside(machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
    }

    function _registeredOverlayMachine(address selector, address executor) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_sequentialPlan()));
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(selector, executor, SUBMITTER_B)
        );
        vm.prank(selector);
        machine.submitSignal(ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x9101)));
    }

    function _dockingGasMachine() private returns (UVPStateMachine machine) {
        machine = _dockingGasMachineBeforeLink();
        _docking(machine).linkDockedOrder(ORDER_ID, _dockedOrderLink());
    }

    function _dockingGasMachineBeforeLink() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        machine.registerPlan(PLAN_ID, PLAN_HASH, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _planMetadata(machine).registerPlanMetadata(PLAN_ID, _selectorBindings(), _emptySignalCapabilities());
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID, PLAN_ID, ORDER_CREATOR, _dockedLocalAuthorizations(address(this))
        );
        _submitTriggerOrderFromOutside(
            machine, ORDER_ID_2, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_VERIFY_FAIL, SUBMITTER_A)
        );
    }

    function _newMachine() private returns (UVPStateMachine) {
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
        machine.setPlanPublisher(address(this), true);
        machine.setOrderRegistrar(address(this), true);
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

    function _dockedOrderLink() private pure returns (UVPDockingModule.DockedOrderLink memory) {
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
        address submitter = vm.addr(SUBMITTER_PRIVATE_KEY);
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
        _submitTriggerOrderFromOutsideRequest(machine, trigger, authorizations, SUBMITTER_PRIVATE_KEY);
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

    function _signalTriggerRequest(bytes32 orderId, bytes32 triggerOriginOrderId, bytes32 idempotencyKey)
        private
        returns (IUVPStateMachineCore.TriggerOrderFromSignalRequest memory)
    {
        return IUVPStateMachineCore.TriggerOrderFromSignalRequest({
            orderId: orderId,
            planId: PLAN_ID,
            creator: ORDER_CREATOR,
            triggerOriginOrderId: triggerOriginOrderId,
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
        hooks[0] =
            _hook(hookId, STAGE_INIT, HOOK_NAME_TIMEOUT, true, instructions, _deps2(SIGNAL_VERIFY_FAIL, SIGNAL_TRIGGER));
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
        returns (UVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings)
    {
        selectorBindings = new UVPPlanMetadataModule.StageSelectorBinding[](1);
        selectorBindings[0] =
            UVPPlanMetadataModule.StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
    }

    function _signalCapabilities()
        private
        pure
        returns (UVPPlanMetadataModule.SignalCapability[] memory capabilities)
    {
        capabilities = new UVPPlanMetadataModule.SignalCapability[](1);
        capabilities[0] = UVPPlanMetadataModule.SignalCapability({
            stageId: STAGE_AUDIT,
            targetSourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_VERIFY_FAIL,
            targetOrderRelation: 1
        });
    }

    function _emptySignalCapabilities()
        private
        pure
        returns (UVPPlanMetadataModule.SignalCapability[] memory capabilities)
    {
        capabilities = new UVPPlanMetadataModule.SignalCapability[](0);
    }

    function _duplicateSelectorBindings()
        private
        pure
        returns (UVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings)
    {
        selectorBindings = new UVPPlanMetadataModule.StageSelectorBinding[](2);
        selectorBindings[0] =
            UVPPlanMetadataModule.StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
        selectorBindings[1] =
            UVPPlanMetadataModule.StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
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
            op: UVPStateMachine.InstructionOp.Not,
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
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
}
