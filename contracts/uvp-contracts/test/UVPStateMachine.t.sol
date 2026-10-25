// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
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
    bytes32 private constant SIGNAL_FALLBACK = bytes32(uint256(0x4010));
    bytes32 private constant SIGNAL_ALT_BIRTH = bytes32(uint256(0x4007));
    bytes32 private constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;
    bytes32 private constant RESOURCE_PATCH_SIGNAL_ID =
        0x6dff331f2bb7b785cbcd99a911e6d30dc8714f43b3b9ba80c658215445ddd0ba;
    bytes32 private constant DOCKED_ORDER_LINK_SIGNAL_ID = keccak256("uvp.docked_order_link.v1");
    bytes32 private constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");
    bytes32 private constant EXECUTOR_PATCH_MODE_HANDOFF = bytes32("handoff");
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_AUDIT = bytes32(uint256(0x5002));
    bytes32 private constant STAGE_ROLLBACK = bytes32(uint256(0x5003));
    bytes32 private constant STAGE_ALT = bytes32(uint256(0x5004));
    bytes32 private constant PRODUCTION_SOURCE = keccak256("payment");
    bytes32 private constant PRODUCTION_SIGNAL = keccak256("payment.ready");
    bytes32 private constant HOOK_ORDER_START = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_INIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_AUDIT = bytes32(uint256(0x6002));
    bytes32 private constant HOOK_TIMEOUT = bytes32(uint256(0x6003));
    bytes32 private constant HOOK_ROLLBACK = bytes32(uint256(0x6004));
    bytes32 private constant HOOK_NON_TRIGGER = bytes32(uint256(0x6005));
    bytes32 private constant HOOK_ALT_MINT = bytes32(uint256(0x6006));
    bytes32 private constant HOOK_ADMISSION_DEPTH = bytes32(uint256(0x6b00));
    bytes32 private constant HOOK_WATCHER_DEPTH = bytes32(uint256(0x6b01));
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
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.15");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_ORDER_TRIGGER_DOCK = 2;
    uint8 private constant FLAG_EMIT_READY = 4;
    uint8 private constant FLAG_ADMISSION = 8;
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");
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
            machine, _positiveHookPlan(HOOK_INIT, true), new StageSelectorBinding[](0), new SignalCapability[](0)
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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
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
        machine.triggerOrderFromOutsideFor(
            duplicateTrigger,
            duplicateAuthorizations,
            duplicateSignature,
            _factAttribution(machine, duplicateTrigger.planId, duplicateTrigger.sourceId, duplicateTrigger.signalId)
        );
    }

    function testSubmittedSignalMakesHookReady() public {
        UVPStateMachine machine = _registeredMachine(_emitReadyPositiveHookPlan(HOOK_INIT));

        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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

        bytes32 bindingLeaf = keccak256(abi.encode(SELECTOR_BINDING_LEAF_DOMAIN, STAGE_INIT, STAGE_AUDIT));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = bindingLeaf;
        require(_planMetadata(machine).capabilitiesRoot(PLAN_ID) == DockMerkle.root(leaves), "bad capabilities root");
        require(_planMetadata(machine).hasCapabilityVocabulary(PLAN_ID), "vocabulary missing");
        bytes32[] memory proof = _merkleProofFor(_capabilityTables[address(machine)][PLAN_ID].sortedLeaves, bindingLeaf);
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
            _planMetadata(machine)
                .verifySignalCapability(
                    PLAN_ID,
                    STAGE_AUDIT,
                    SOURCE_BOOTSTRAP,
                    SIGNAL_VERIFY_FAIL,
                    1,
                    _merkleProofFor(sortedLeaves, leaves[1])
                ),
            "capability missing"
        );
        require(
            _planMetadata(machine)
                .verifySignalCapability(
                    PLAN_ID,
                    STAGE_INIT,
                    SOURCE_BOOTSTRAP,
                    SIGNAL_ORDER_START,
                    0,
                    _merkleProofFor(sortedLeaves, leaves[2])
                ),
            "birth capability missing"
        );
        require(
            !_planMetadata(machine)
                .verifySignalCapability(
                    PLAN_ID,
                    STAGE_AUDIT,
                    SOURCE_BOOTSTRAP,
                    SIGNAL_VERIFY_FAIL,
                    0,
                    _merkleProofFor(sortedLeaves, leaves[1])
                ),
            "unexpected relation"
        );
    }

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
            _planMetadata(machine)
                .verifyStageSelectorBinding(
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

        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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
        UVPStateMachine.SignalAuthorization[] memory originAuths = _defaultAuthorizations(address(this));
        UVPStateMachine.SignalAuthorization[] memory originWithDerived =
            new UVPStateMachine.SignalAuthorization[](originAuths.length + 1);
        for (uint256 i = 0; i < originAuths.length; i++) {
            originWithDerived[i] = originAuths[i];
        }
        originWithDerived[originAuths.length] = _authorization(SIGNAL_VERIFY_FAIL, SUBMITTER_A);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, originWithDerived);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest1 = _derivedSignalRequest(
            LINKED_ORDER_ID,
            STAGE_AUDIT,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(3))
        );
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
                    "DerivedSignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,uint8)"
                )
            ) == 1,
            "derived signal event count"
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest2 = _derivedSignalRequest(
            LINKED_ORDER_ID,
            STAGE_AUDIT,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(4))
        );
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

        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            PRODUCTION_SOURCE,
            PRODUCTION_SIGNAL,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL)
        );

        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(2)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            PRODUCTION_SOURCE,
            PRODUCTION_SIGNAL,
            PAYLOAD_HASH,
            bytes32(uint256(3)),
            _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL)
        );
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            "production source signal missing"
        );
    }

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

        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL
            )
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution()
        );
        require(
            !machine.hasSignal(PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            "unproven production fact was recorded"
        );

        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(2)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));

        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL
            )
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, PAYLOAD_HASH, bytes32(uint256(3)), _noAttribution()
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            PRODUCTION_SOURCE,
            PRODUCTION_SIGNAL,
            PAYLOAD_HASH,
            bytes32(uint256(4)),
            _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL)
        );
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL),
            "attributed production fact missing after materialization"
        );
    }

    function testDerivedRelationOneFromExecutorAcceptedAtStateMachine() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine,
            _withOrderStart(_patchableSequentialPlan()),
            _selectorBindings(),
            _derivedActiveSignalCapabilities()
        );

        UVPStateMachine.SignalAuthorization[] memory originAuthorizations = new UVPStateMachine.SignalAuthorization[](3);
        originAuthorizations[0] = _authorization(SIGNAL_TRIGGER, address(this));
        originAuthorizations[1] = _authorization(SIGNAL_INIT_CMP, address(this));
        originAuthorizations[2] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, originAuthorizations);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH));

        UVPStateMachine.SignalAuthorization[] memory childAuths = new UVPStateMachine.SignalAuthorization[](3);
        childAuths[0] = _authorization(SIGNAL_TRIGGER, SUBMITTER_A);
        childAuths[1] = _authorization(SIGNAL_VERIFY_FAIL, SUBMITTER_A);
        childAuths[2] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        _triggerOrderFromSignalRequest(
            machine, _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))), childAuths
        );
        _applyExecutorPatch(machine, PLAN_ID, LINKED_ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest3 = _derivedSignalRequest(
            LINKED_ORDER_ID,
            STAGE_AUDIT,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(3))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs3 = _derivedProofs(machine, derivedRequest3);
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest3, SUBMITTER_A, derivedProofs3);
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL),
            "relation-1 from-executor write missing on origin order"
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest3b = _derivedSignalRequest(
            LINKED_ORDER_ID,
            STAGE_AUDIT,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0x9103))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs3b = _derivedProofs(machine, derivedRequest3b);
        vm.prank(SUBMITTER_B);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPDerivedSignalModule.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                SOURCE_BOOTSTRAP,
                SIGNAL_VERIFY_FAIL,
                SUBMITTER_B
            )
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest3b, SUBMITTER_B, derivedProofs3b);
    }

    function testDerivedSignalRejectsMissingPlanCapability() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest4 = _derivedSignalRequest(
            LINKED_ORDER_ID,
            STAGE_AUDIT,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(3))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs4 = _derivedProofs(machine, derivedRequest4);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPDerivedSignalModule.InvalidSignalCapability.selector);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest4, SUBMITTER_A, derivedProofs4);
    }

    function testApplyStageExecutorPatchStoresActiveOverlayAndEmitsEvents() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);

        vm.recordLogs();
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            _countTopic(
                logs,
                keccak256(
                    "StageExecutorPatchApplied(bytes32,bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,uint256,string)"
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
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        require(machine.hasSourceSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT), "target source signal not marked");
        require(machine.sourceSignalCount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 1, "target signal count not tracked");
        require(
            machine.lastSignalSubmitter(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "last submitter not tracked"
        );
    }

    function testApplyStageExecutorPatchRejectsUnauthorizedSelector() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _birthSignalCapabilities()
        );
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _targetSignalAuthorizations(SUBMITTER_A, SUBMITTER_B)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageExecutorPatchSelector.selector, ORDER_ID, STAGE_INIT, address(this)
            )
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
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
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
    }

    function testApplyStageExecutorPatchRejectsNonIncreasingNonce() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH));

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchNonceNotIncreasing.selector, ORDER_ID, STAGE_AUDIT, 2, 2
            )
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_A, PATCH_HASH_2));
    }

    function testExecutorPatchSucceedsWithoutCurrentOrderCapabilities() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _birthSignalCapabilities()
        );
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _stagePatchSelectorAuthorizations(address(this))
        );

        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));

        (bool exists, address executor,,,,,) =
            _stagePatch(machine).getActiveStageExecutorPatch(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(exists, "patch missing");
        require(executor == SUBMITTER_A, "bad executor");
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "overlay not active");
    }

    function testAssignModeRejectsStrayPreviousExecutorSignature() public {
        UVPStateMachine machine = _newMachine();
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        _registerPlan(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _birthSignalCapabilities()
        );
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _stagePatchSelectorAuthorizations(selector));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        patch.authorizationsHash = _authsHashLocal(
            _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
        );
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        address straySigner = vm.addr(SUBMITTER_PRIVATE_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, address(0), straySigner
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(v, r, s),
                _packedSignature(v, r, s),
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
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
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
    }

    function testAssignRejectedAfterFallbackStageFact() public {
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
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_FALLBACK)
        );
        require(machine.sourceSignalCount(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 1, "fallback fact not recorded");

        vm.prank(selector);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(2, SUBMITTER_B, PATCH_HASH_2));
    }

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
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_FALLBACK)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, executor);
        uint256 deadline = block.timestamp + 1 hours;
        patch.authorizationsHash = _authsHashLocal(
            _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
        );
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 selectorV, bytes32 selectorR, bytes32 selectorS) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        (uint8 previousV, bytes32 previousR, bytes32 previousS) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(selectorV, selectorR, selectorS),
                _packedSignature(previousV, previousR, previousS),
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff not applied");
    }

    function _fallbackFactMachine(address selector, address executor) private returns (UVPStateMachine machine) {
        machine = _newMachine();
        SignalCapability[] memory overlay = _overlaySignalCapabilities();
        SignalCapability[] memory capabilities = new SignalCapability[](overlay.length + 1);
        for (uint256 i = 0; i < overlay.length; i++) {
            capabilities[i] = overlay[i];
        }
        capabilities[overlay.length] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_FALLBACK, targetOrderRelation: 0
        });
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), capabilities);
        UVPStateMachine.SignalAuthorization[] memory base = _overlayAuthorizations(selector, executor, SUBMITTER_B);
        UVPStateMachine.SignalAuthorization[] memory authorizations =
            new UVPStateMachine.SignalAuthorization[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            authorizations[i] = base[i];
        }
        authorizations[base.length] = _stageAuthorization(STAGE_AUDIT, SIGNAL_FALLBACK, executor);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);
        vm.prank(selector);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(0x9130)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );
        _activateInitialStageExecutor(machine, selector, executor);
    }

    function testApplyStageExecutorPatchAssignRejectsUnexpectedGovernanceFields() public {
        UVPStateMachine machine = _registeredOverlayMachine(vm.addr(SUBMITTER_PRIVATE_KEY), SUBMITTER_A);
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);

        UVPStagePatchModule.StageExecutorPatch memory previousPatch =
            _stageExecutorPatchWithMode(1, SUBMITTER_A, PATCH_HASH, EXECUTOR_PATCH_MODE_ASSIGN, SUBMITTER_B);
        vm.prank(selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchPreviousExecutorMismatch.selector,
                ORDER_ID,
                STAGE_AUDIT,
                address(0),
                SUBMITTER_B
            )
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, previousPatch);

        UVPStagePatchModule.StageExecutorPatch memory straySignature = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        straySignature.authorizationsHash =
            _authsHashLocal(_executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_A));
        bytes32 digest =
            _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, straySignature, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, address(0), selector
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                straySignature,
                selector,
                deadline,
                _packedSignature(v, r, s),
                _packedSignature(v, r, s),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, SUBMITTER_A),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_A)
            );
    }

    function testApplyStageExecutorPatchRejectsZeroExecutorAndPatchHash() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        vm.expectRevert(UVPStagePatchModule.ZeroStageExecutor.selector);
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, address(0), PATCH_HASH));

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
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
        patch.authorizationsHash = _authsHashLocal(
            _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
        );
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.prank(UNAUTHORIZED_SUBMITTER);
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(v, r, s),
                "",
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );

        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_A, "relayed patch not applied");
    }

    function testRelayedStageExecutorPatchRejectsWrongSigner() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address wrongSigner = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp + 1 hours;
        patch.authorizationsHash = _authsHashLocal(
            _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
        );
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, selector, wrongSigner
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(v, r, s),
                "",
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
    }

    function testRelayedStageExecutorPatchRejectsExpiredSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        uint256 deadline = block.timestamp - 1;
        patch.authorizationsHash = _authsHashLocal(
            _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
        );
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.ExpiredStageExecutorPatchSignature.selector, deadline)
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(v, r, s),
                "",
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
    }

    function testHandoffStageExecutorPatchSucceedsWithPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor);
        {
            uint256 deadline = block.timestamp + 1 hours;
            patch.authorizationsHash = _authsHashLocal(
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
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
                .applyStageExecutorPatchFor(
                    PLAN_ID,
                    ORDER_ID,
                    patch,
                    selector,
                    deadline,
                    selectorSignature,
                    previousSignature,
                    _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                    _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                    _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
                );
        }

        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == SUBMITTER_B, "handoff executor not active"
        );
        (,,,, address originalSubmitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(originalSubmitter == previousExecutor, "prior signal attribution changed");

        vm.prank(previousExecutor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(2)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
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
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor);
        {
            uint256 deadline = block.timestamp + 1 hours;
            patch.authorizationsHash = _authsHashLocal(
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
            bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);

            vm.expectRevert(
                abi.encodeWithSelector(
                    UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
                )
            );
            _stagePatch(machine)
                .applyStageExecutorPatchFor(
                    PLAN_ID,
                    ORDER_ID,
                    patch,
                    selector,
                    deadline,
                    _packedSignature(v, r, s),
                    "",
                    _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                    _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                    _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
                );
        }

        vm.prank(selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
            )
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
    }

    function testHandoffStageExecutorPatchFailsWithWrongPreviousExecutorSignature() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory selectorSignature;
        bytes memory wrongSignature;
        {
            patch.authorizationsHash = _authsHashLocal(
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
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
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                selectorSignature,
                wrongSignature,
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
    }

    function testHandoffStageExecutorPatchRejectsTamperedAuthorizationsHash() public {
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(address(this), previousExecutor);
        _activateInitialStageExecutor(machine, address(this), previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor);
        patch.authorizationsHash = _authsHashLocal(new IUVPStateMachineCore.SignalAuthorization[](0));
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, previousExecutor, address(0)
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID,
                ORDER_ID,
                patch,
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, SUBMITTER_B),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_B)
            );
    }

    function testReplacementModeIsRetired() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, bytes32("replacement"), SUBMITTER_A);
        patch.authorizationsHash =
            _authsHashLocal(_executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_B));
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.InvalidStageExecutorPatchMode.selector, bytes32("replacement"))
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID,
                ORDER_ID,
                patch,
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, SUBMITTER_B),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_B)
            );
    }

    function testHandoffWritesExplicitAuthorizationsForNewExecutor() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address previousExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, previousExecutor);
        _activateInitialStageExecutor(machine, selector, previousExecutor);

        vm.prank(previousExecutor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, previousExecutor);
        _applyExecutorPatchRelayed(machine, patch, selector, SUBMITTER_PRIVATE_KEY, WRONG_SUBMITTER_PRIVATE_KEY);

        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, SUBMITTER_B),
            "handoff did not write explicit authorizations for new executor"
        );
        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(3)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
    }

    function _applyExecutorPatchRelayed(
        UVPStateMachine machine,
        UVPStagePatchModule.StageExecutorPatch memory patch,
        address selector,
        uint256 selectorKey,
        uint256 previousKey
    ) private {
        uint256 deadline = block.timestamp + 1 hours;
        patch.authorizationsHash = _authsHashLocal(
            _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
        );
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, selector, deadline);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(selectorKey, digest);
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(previousKey, digest);
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(sv, sr, ss),
                _packedSignature(pv, pr, ps),
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
    }

    function testStageExecutorPatchRejectsPreviousExecutorMismatch() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, SUBMITTER_B, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, SUBMITTER_B);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchPreviousExecutorMismatch.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SUBMITTER_A,
                SUBMITTER_B
            )
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
    }

    function testActiveStageExecutorPatchPreservesExplicitOrderAuthorization() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));

        address outsider = address(0xBAD);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, outsider
            )
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
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
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        (bool exists,,,,) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(!exists, "prematerialized stage signal was stored");

        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(2)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(3)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
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
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(0x9201)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH));
        require(
            machine.isSignalSubmitterAuthorized(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, SUBMITTER_A),
            "patched executor was not dynamically authorized"
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
    }

    function testApplyStageResourcePatchStoresOverlayAndEmitsEvent() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);

        vm.recordLogs();
        _stagePatch(machine)
            .applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId));
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

        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _stageResourcePatch(2, RESOURCE_PATCH_HASH),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT)
            );

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
        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _stageResourcePatch(2, RESOURCE_PATCH_HASH_2),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT)
            );

        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _stageResourcePatchWithKey(RESOURCE_KEY_2, 1, RESOURCE_PATCH_HASH_2),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT)
            );
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
        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _stageResourcePatch(1, RESOURCE_PATCH_HASH),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT)
            );
    }

    function testApplyStageResourcePatchRejectsAfterTargetStageSignal() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        _activateInitialStageExecutor(machine, address(this), SUBMITTER_A);

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _stageResourcePatch(1, RESOURCE_PATCH_HASH),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT)
            );
    }

    function testApplyStageResourcePatchRejectsZeroFields() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);

        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.resourceKey = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroResourceKey.selector);
        _stagePatch(machine)
            .applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId));

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.manifestHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroManifestHash.selector);
        _stagePatch(machine)
            .applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId));

        patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.policyHash = bytes32(0);
        vm.expectRevert(UVPStagePatchModule.ZeroPolicyHash.selector);
        _stagePatch(machine)
            .applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId));

        patch = _stageResourcePatch(1, bytes32(0));
        vm.expectRevert(UVPStagePatchModule.ZeroPatchHash.selector);
        _stagePatch(machine)
            .applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId));
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
            .applyStageResourcePatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(v, r, s),
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId)
            );

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
            .applyStageResourcePatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                selector,
                deadline,
                _packedSignature(v, r, s),
                _moduleBindingFor(machine, PLAN_ID, patch.targetStageId)
            );
    }

    function testPositiveSignalMakesHookReady() public {
        UVPStateMachine machine = _registeredMachine(_emitReadyPositiveHookPlan(HOOK_INIT));

        vm.recordLogs();
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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

    function testSharedSignalSkipsOrderTriggerHookAndEvaluatesWatcher() public {
        UVPStateMachine machine = _registeredMachine(_sharedDependencyPlanWithNonTriggerFirst());

        vm.recordLogs();
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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

    function testForeignBirthFactDoesNotMaterializeBirthStage() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory altLine = new UVPStateMachine.CompactHook[](1);
        altLine[0] = _signalHook(HOOK_ALT_MINT, STAGE_ALT, HOOK_NAME_ORDER_START, true, SIGNAL_ALT_BIRTH);
        _registerPlan(machine, _withOrderStart(altLine));

        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_ALT_BIRTH, address(this)));
        (UVPStateMachine.HookStatus birthStatus,, bool birthReady) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_ORDER_START);
        require(birthStatus == UVPStateMachine.HookStatus.Ready, "birth hook not ready");
        require(birthReady, "birth ready marker missing");

        vm.recordLogs();
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_ALT_BIRTH,
            PAYLOAD_HASH,
            bytes32(uint256(0x9132)),
            _noAttribution()
        );
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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testSubmitSignalRejectsZeroSourceId() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, address(this)));

        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, bytes32(0), SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
    }

    function testDockingFromModuleEntriesRejectZeroFactKeys() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, address(this)));
        UVPStateMachine.SignalAuthorization[] memory noAuths = new UVPStateMachine.SignalAuthorization[](0);
        address dockingModule = address(_docking(machine));

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.createDockedOrderFromModule(
            _dockEntranceRequest(
                PLAN_ID,
                bytes32(uint256(1) << 255),
                ORDER_CREATOR,
                HOOK_INIT,
                STAGE_INIT,
                bytes32(0),
                SIGNAL_TRIGGER,
                noAuths
            )
        );

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.recordDockedInputFromModule(
            _dockInputFact(PLAN_ID, ORDER_ID, bytes32(0), SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(this))
        );

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSourceId.selector);
        machine.submitSignalFromModule(
            PLAN_ID,
            ORDER_ID,
            bytes32(0),
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            address(this),
            _noAttribution()
        );

        vm.prank(dockingModule);
        vm.expectRevert(UVPStateMachine.ZeroSignalId.selector);
        machine.submitSignalFromModule(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            bytes32(0),
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            address(this),
            _noAttribution()
        );
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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        require(
            !machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "unauthorized signal was written"
        );
    }

    function testAuthorizedSubmitterCanAdvanceHook() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_emitReadyPositiveHookPlan(HOOK_INIT)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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
            _packedSignature(v, r, s),
            _noAttribution()
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
            _packedSignature(v, r, s),
            _noAttribution()
        );
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
            _packedSignature(v, r, s),
            _noAttribution()
        );
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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution()
        );

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution()
        );

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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution()
        );
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution()
        );
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)), _noAttribution()
        );

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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution()
        );

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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution()
        );

        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(3)), _noAttribution()
        );

        (UVPStateMachine.HookStatus initStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_INIT);
        (UVPStateMachine.HookStatus auditStatus,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_AUDIT);
        require(initStatus == UVPStateMachine.HookStatus.Ready, "init not ready");
        require(auditStatus == UVPStateMachine.HookStatus.Ready, "audit not ready");
    }

    function testSequentialUpdateFlowHooksBecomeReady() public {
        UVPStateMachine machine = _registeredMachine(_watcherSequentialPlan());

        vm.recordLogs();
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, bytes32(uint256(1)), _noAttribution()
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(2)), _noAttribution()
        );
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS, PAYLOAD_HASH, bytes32(uint256(3)), _noAttribution()
        );

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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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
            machine, _timerHookPlan(HOOK_TIMEOUT, 30 days + 1), new StageSelectorBinding[](0), new SignalCapability[](0)
        );
    }

    function testCommitPlanAcceptsOneSecondDelay() public {
        UVPStateMachine machine = _registeredMachine(_timerHookPlan(HOOK_TIMEOUT, 1));

        vm.warp(100);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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

        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "hook not cancelled");
        require(dueAt == 0, "cancelled hook has due");
        require(!readyEmitted, "cancelled hook emitted ready");
    }

    function testDecayingVetoPassesWhileNegatedSignalAbsent() public {
        UVPStateMachine machine = _registeredMachine(_decayingVetoHookPlan(HOOK_TIMEOUT, 5));

        vm.warp(100);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "decaying veto hook not ready");
        require(dueAt == 0, "absent-signal ready has no expiry to persist");
        require(readyEmitted, "ready marker missing");
    }

    function testDecayingVetoPassesInWindowAndCancelsAtMaturity() public {
        UVPStateMachine machine = _registeredMachine(_decayingVetoHookPlan(HOOK_TIMEOUT, 5));

        vm.warp(100);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        (UVPStateMachine.HookStatus status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Init, "veto alone must not settle the gate");

        vm.warp(104);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            bytes32(uint256(0x9002)),
            _noAttribution()
        );

        (UVPStateMachine.HookStatus windowStatus,, bool windowReady) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        status = windowStatus;
        require(status == UVPStateMachine.HookStatus.Ready, "immature veto must pass");
        require(windowReady, "ready marker missing");

        UVPStateMachine machineLate = _registeredMachine(_decayingVetoHookPlan(HOOK_TIMEOUT, 5));

        vm.warp(100);
        machineLate.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        vm.warp(105);
        machineLate.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            bytes32(uint256(0x9002)),
            _noAttribution()
        );

        (UVPStateMachine.HookStatus lateStatus, uint64 lateDueAt, bool lateReady) =
            machineLate.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(lateStatus == UVPStateMachine.HookStatus.Cancelled, "matured veto must cancel");
        require(lateDueAt == 0, "cancelled hook has due");
        require(!lateReady, "cancelled hook emitted ready");
    }

    function testDecayingVetoExpiryDoesNotExtendWaitDeadline() public {
        UVPStateMachine machine = _registeredMachine(_liveVetoWaitHookPlan(HOOK_TIMEOUT));

        vm.warp(100);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0x9002)),
            _noAttribution()
        );

        (UVPStateMachine.HookStatus status, uint64 dueAt, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "hook not waiting");
        require(dueAt == 105, "veto expiry leaked into the wait deadline");
        require(!readyEmitted, "early ready marker");

        vm.warp(105);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);

        (status,, readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "hook not ready at positive-branch due");
        require(readyEmitted, "ready marker missing");
    }

    function testDecayingVetoAtRootIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _delay(5);
        instructions[2] = _not();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT, STAGE_INIT, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, instructions, _deps(SIGNAL_VERIFY_FAIL)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testDecayingVetoUnderOrBranchIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[2] = _delay(5);
        instructions[3] = _not();
        instructions[4] = _or(2);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_TRIGGER, SIGNAL_VERIFY_FAIL)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testDoublyNegatedDecayingVetoIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](6);
        instructions[0] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[1] = _delay(5);
        instructions[2] = _not();
        instructions[3] = _not();
        instructions[4] = _signal(SIGNAL_TRIGGER);
        instructions[5] = _and(2);
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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testDecayingVetoInsideDelayOperandIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory direct = new UVPStateMachine.Instruction[](4);
        direct[0] = _signal(SIGNAL_VERIFY_FAIL);
        direct[1] = _delay(5);
        direct[2] = _not();
        direct[3] = _delay(10);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT, STAGE_INIT, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, direct, _deps(SIGNAL_VERIFY_FAIL)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));

        UVPStateMachine.Instruction[] memory nested = new UVPStateMachine.Instruction[](6);
        nested[0] = _signal(SIGNAL_TRIGGER);
        nested[1] = _signal(SIGNAL_VERIFY_FAIL);
        nested[2] = _delay(5);
        nested[3] = _not();
        nested[4] = _and(2);
        nested[5] = _delay(10);
        UVPStateMachine.CompactHook[] memory wrapped = new UVPStateMachine.CompactHook[](1);
        wrapped[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            nested,
            _deps2(SIGNAL_TRIGGER, SIGNAL_VERIFY_FAIL)
        );

        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(machine, wrapped, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testDecayingVetoUnderAndInsideOrRegisters() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory ordered = new UVPStateMachine.Instruction[](7);
        ordered[0] = _signal(SIGNAL_TRIGGER);
        ordered[1] = _signal(SIGNAL_VERIFY_FAIL);
        ordered[2] = _delay(5);
        ordered[3] = _not();
        ordered[4] = _and(2);
        ordered[5] = _signal(SIGNAL_INIT_CMP);
        ordered[6] = _or(2);
        UVPStateMachine.CompactHook[] memory orWrapped = new UVPStateMachine.CompactHook[](1);
        orWrapped[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            ordered,
            _deps3(SIGNAL_TRIGGER, SIGNAL_VERIFY_FAIL, SIGNAL_INIT_CMP)
        );

        bytes32 planId = _registerPlan(machine, orWrapped);
        require(machine.planExists(planId), "and-inside-or veto plan not registered");
    }

    function testDecayingVetoEvaluationGasIsConstantIncrement() public {
        UVPStateMachine plainMachine = _registeredMachine(_negativeHookPlan(HOOK_TIMEOUT));
        vm.warp(100);
        uint256 gasBefore = gasleft();
        plainMachine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        uint256 plainSpent = gasBefore - gasleft();

        UVPStateMachine machine = _registeredMachine(_decayingVetoHookPlan(HOOK_TIMEOUT, 5));
        vm.warp(100);
        gasBefore = gasleft();
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        uint256 vetoSpent = gasBefore - gasleft();

        UVPStateMachine machineHour = _registeredMachine(_decayingVetoHookPlan(HOOK_TIMEOUT, 1 hours));
        vm.warp(100);
        gasBefore = gasleft();
        machineHour.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        uint256 hourSpent = gasBefore - gasleft();

        require(vetoSpent > plainSpent, "decaying veto must cost more than plain negation");
        require(vetoSpent - plainSpent <= 2_000, "decaying veto delta exceeds the constant budget");
        uint256 durationWobble = vetoSpent > hourSpent ? vetoSpent - hourSpent : hourSpent - vetoSpent;
        require(durationWobble <= 100, "evaluation gas must not scale with the window duration");
    }

    function testOrBranchTriggersRollback() public {
        UVPStateMachine machine = _registeredMachine(_orRollbackPlan());

        vm.recordLogs();
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        (UVPStateMachine.HookStatus status,, bool readyEmitted) =
            machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_ROLLBACK);
        require(status == UVPStateMachine.HookStatus.Ready, "rollback not ready");
        require(readyEmitted, "rollback ready marker missing");
        require(_countHookReady(vm.getRecordedLogs()) == 1, "rollback ready event");
    }

    function testDuplicateExternalSignalIsAbsorbedFirstWin() public {
        UVPStateMachine machine = _registeredMachine(_positiveHookPlan(HOOK_INIT, true));

        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            bytes32(uint256(0x8002)),
            bytes32(uint256(0x9002)),
            _noAttribution()
        );

        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER);
        require(submitter == address(this), "absorbed retry changed the first writer");
    }

    function testStageWithoutMaterializingHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _positiveHookPlan(HOOK_NON_TRIGGER, false);

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.StageNotMaterializable.selector, STAGE_INIT));
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testSilentMintTriggerHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_ORDER_TRIGGER_MINT, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SilentOrderTriggerHook.selector, HOOK_INIT));
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testSilentDockTriggerHookIsRejectedAtCommit() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_ORDER_TRIGGER_DOCK, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SilentOrderTriggerHook.selector, HOOK_INIT));
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testFinalizePlanTwiceRevertsPlanAlreadyFinalized() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));

        vm.expectRevert(UVPStateMachine.PlanAlreadyFinalized.selector);
        machine.finalizePlan(planId);
    }

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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
    }

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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
    }

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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
    }

    function testCreateDockedOrderFromModuleRejectsZeroSubmitter() public {
        UVPStateMachine machine = _newMachine();

        vm.prank(address(_dockingModules[address(machine)]));
        vm.expectRevert(UVPStateMachine.ZeroSubmitter.selector);
        UVPStateMachine.DockEntranceRequest memory request = _dockEntranceRequest(
            PLAN_ID,
            bytes32(uint256(1) << 255),
            ORDER_CREATOR,
            HOOK_INIT,
            STAGE_INIT,
            SOURCE_BOOTSTRAP,
            SIGNAL_ORDER_START,
            new UVPStateMachine.SignalAuthorization[](0)
        );
        request.submitter = address(0);
        machine.createDockedOrderFromModule(request);
    }

    function testRecordDockedInputFromModuleRejectsZeroSubmitter() public {
        UVPStateMachine machine = _newMachine();

        vm.prank(address(_dockingModules[address(machine)]));
        vm.expectRevert(UVPStateMachine.ZeroSubmitter.selector);
        UVPStateMachine.DockInputFact memory fact = _dockInputFact(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, address(0)
        );
        machine.recordDockedInputFromModule(fact);
    }

    function testCommitPlanRejectsOrUnanchoredBranchUnderAnd() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_STAGE_DONE);
        instructions[1] = _signal(SIGNAL_STAGE_REVIEW);
        instructions[2] = _not();
        instructions[3] = _or(2);
        instructions[4] = _and(2);
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_AUDIT,
            stageId: STAGE_AUDIT,
            hookName: HOOK_NAME_INIT_DONE,
            flags: FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: _deps2(SIGNAL_STAGE_DONE, SIGNAL_STAGE_REVIEW)
        });
        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testStageSignalStateTracksAttributedFactsNatively() public {
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
            bytes32(uint256(0x9501)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        (uint256 preCount,,,) = machine.stageSignalState(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(preCount == 0, "rejected submission must leave no state");

        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH));
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9501)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        (uint256 count, address lastSubmitter, uint64 lastAt, bool ambiguous) =
            machine.stageSignalState(PLAN_ID, ORDER_ID, STAGE_AUDIT);
        require(count == 1, "native stage count");
        require(lastSubmitter == SUBMITTER_A, "native stage last submitter");
        require(lastAt == uint64(block.timestamp), "native stage last at");
        require(!ambiguous, "native stage not ambiguous");

        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(2, SUBMITTER_B, PATCH_HASH_2);
        vm.prank(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
    }

    function testForkOrderReplaysParentHistoryAndMatchesSequentialSubmission() public {
        UVPStateMachine machine = _forkPlanMachine();
        bytes32 parentOrderId = ORDER_ID;

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        vm.warp(block.timestamp + 100);
        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xF002)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW)
        );
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0xF003)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL)
        );

        _submitTriggerOrderFromOutsideWithPayload(
            machine, PLAN_ID, ORDER_CREATOR, bytes32(uint256(0xF900)), _forkAuthorizations(), SUBMITTER_PRIVATE_KEY
        );
        bytes32 controlOrderId = ORDER_ID;
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            controlOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            controlOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xF002)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW)
        );
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            controlOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0xF003)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL)
        );

        vm.recordLogs();
        vm.prank(SUBMITTER_B);
        bytes32 forkedOrderId = machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            _forkBirthFactsWithTrigger(),
            new UVPStateMachine.SignalAuthorization[](0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(
            _countTopic(logs, keccak256("OrderForked(bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32,bytes32[])")) == 1,
            "fork lineage event"
        );
        require(machine.orderParent(PLAN_ID, forkedOrderId) == parentOrderId, "fork parent lineage");
        require(machine.orderCreator(PLAN_ID, forkedOrderId) == ORDER_CREATOR, "fork creator inherits parent");
        require(machine.orderExists(PLAN_ID, forkedOrderId), "fork order exists");
        require(
            forkedOrderId == machine.forkOrderIdFor(PLAN_ID, parentOrderId, bytes32(uint256(0xF100))),
            "fork id derivation"
        );

        (bool e, bytes32 ph,, uint64 at, address sub) =
            machine.getSignal(PLAN_ID, forkedOrderId, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW);
        require(e && ph == PAYLOAD_HASH && sub == SUBMITTER_B, "fork fact attribution preserved");
        at;

        bytes32[2] memory hookIds = [HOOK_ORDER_START, HOOK_INIT];
        for (uint256 i = 0; i < hookIds.length; i++) {
            (UVPStateMachine.HookStatus forkStatus, uint64 forkDue, bool forkReady) =
                machine.getHookStatus(PLAN_ID, forkedOrderId, hookIds[i]);
            (UVPStateMachine.HookStatus controlStatus, uint64 controlDue, bool controlReady) =
                machine.getHookStatus(PLAN_ID, controlOrderId, hookIds[i]);
            require(forkStatus == controlStatus, "fork hook status parity");
            require(forkDue == controlDue, "fork hook due parity");
            require(forkReady == controlReady, "fork hook ready parity");
        }
    }

    function testB03EventSelfContainmentFields() public {
        vm.recordLogs();
        UVPStateMachine machine = _forkPlanMachine();
        Vm.Log[] memory commitLogs = vm.getRecordedLogs();
        bytes32 parentOrderId = ORDER_ID;

        Vm.Log memory commitLog = _firstLogWithTopic(
            commitLogs,
            keccak256(
                "PlanCommitted(bytes32,bytes32,address,bytes32,bytes32,uint256,bytes32,bytes32,bytes32,address)"
            )
        );
        (,,,,, bytes32 commitCandidatesRoot, address commitBirthAuthorizer) =
            abi.decode(commitLog.data, (bytes32, bytes32, uint256, bytes32, bytes32, bytes32, address));
        require(commitCandidatesRoot != bytes32(0), "candidates root");
        require(commitBirthAuthorizer == vm.addr(SUBMITTER_PRIVATE_KEY), "birth authorizer tail field");

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xF002)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW)
        );
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0xF003)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL)
        );

        vm.recordLogs();
        vm.prank(SUBMITTER_B);
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            _forkBirthFactsWithTrigger(),
            new UVPStateMachine.SignalAuthorization[](0)
        );
        Vm.Log[] memory forkLogs = vm.getRecordedLogs();

        Vm.Log memory forkLog = _firstLogWithTopic(
            forkLogs,
            keccak256("OrderForked(bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32,bytes32[])")
        );
        (bytes32 forkApprovalSourceId, bytes32 forkApprovalSignalId, address forkInitiator, bytes32 forkPayload, bytes32[] memory replayedKeys)
            = abi.decode(forkLog.data, (bytes32, bytes32, address, bytes32, bytes32[]));
        require(forkApprovalSourceId == SOURCE_BOOTSTRAP && forkApprovalSignalId == SIGNAL_STAGE_REVIEW, "fork approval");
        require(forkInitiator == SUBMITTER_B, "fork initiator");
        require(forkPayload == bytes32(uint256(0xF100)), "fork payload hash tail field");
        require(replayedKeys.length == 4, "replayed fact key count");
        require(
            replayedKeys[0] == keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_ORDER_START)),
            "replayed fact key = signalKey"
        );

        Vm.Log memory signalLog = _firstLogWithTopic(
            forkLogs,
            keccak256("SignalSubmitted(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32)")
        );
        (bytes32 signalIdArg, bytes32 signalPayload, bytes32 signalIdem, address signalSubmitter, bytes32 signalFactStage)
            = abi.decode(signalLog.data, (bytes32, bytes32, bytes32, address, bytes32));
        require(signalPayload == PAYLOAD_HASH && signalIdem == IDEMPOTENCY_KEY, "signal payload");
        require(signalSubmitter == vm.addr(SUBMITTER_PRIVATE_KEY), "replayed fact submitter inherits parent");
        require(signalIdArg == SIGNAL_ORDER_START, "replayed birth fact key");
        require(signalFactStage == bytes32(0), "fact stage tail field (off-vocabulary fact)");
    }

    function testForkReplayEmitsNoHookReadyForPureWatcher() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        UVPStateMachine.Instruction[] memory start = new UVPStateMachine.Instruction[](1);
        start[0] = _signal(SIGNAL_ORDER_START);
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: HOOK_ORDER_START,
            stageId: STAGE_INIT,
            hookName: HOOK_NAME_ORDER_START,
            flags: FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            instructions: start,
            dependencyKeys: _deps(SIGNAL_ORDER_START)
        });
        UVPStateMachine.Instruction[] memory combo = new UVPStateMachine.Instruction[](5);
        combo[0] = _signal(SIGNAL_STAGE_DONE);
        combo[1] = _signal(SIGNAL_STAGE_REVIEW);
        combo[2] = _and(2);
        combo[3] = _signal(SIGNAL_VERIFY_FAIL);
        combo[4] = _or(2);
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_INIT,
            stageId: STAGE_AUDIT,
            hookName: HOOK_NAME_INIT_DONE,
            flags: FLAG_EMIT_READY,
            instructions: combo,
            dependencyKeys: _deps3(SIGNAL_STAGE_DONE, SIGNAL_STAGE_REVIEW, SIGNAL_VERIFY_FAIL)
        });
        hooks[2] = UVPStateMachine.CompactHook({
            hookId: HOOK_NON_TRIGGER,
            stageId: STAGE_AUDIT,
            hookName: HOOK_NAME_TRIGGER,
            flags: uint8(0),
            instructions: _signalInstructions(SIGNAL_VERIFY_FAIL),
            dependencyKeys: _deps(SIGNAL_VERIFY_FAIL)
        });
        _registerPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _forkAuthorizations());
        bytes32 parentOrderId = ORDER_ID;

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xF002)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW)
        );
        vm.recordLogs();
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0xF003)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL)
        );
        Vm.Log[] memory sequentialLogs = vm.getRecordedLogs();
        require(!_hasHookReadyFor(sequentialLogs, HOOK_NON_TRIGGER), "sequential watcher must not emit HookReady");
        (UVPStateMachine.HookStatus watcherStatus,, bool watcherEmitted) =
            machine.getHookStatus(PLAN_ID, parentOrderId, HOOK_NON_TRIGGER);
        require(watcherStatus == UVPStateMachine.HookStatus.Ready, "sequential watcher must judge Ready");
        require(!watcherEmitted, "sequential watcher must not mark readyEmitted");

        vm.recordLogs();
        vm.prank(SUBMITTER_B);
        bytes32 forkedOrderId = machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            _forkBirthFactsWithTrigger(),
            new UVPStateMachine.SignalAuthorization[](0)
        );
        Vm.Log[] memory forkLogs = vm.getRecordedLogs();
        require(
            _countTopic(forkLogs, keccak256("OrderForked(bytes32,bytes32,bytes32,bytes32,bytes32,address,bytes32,bytes32[])")) == 1,
            "fork lineage event"
        );
        require(_hasHookReadyFor(forkLogs, HOOK_ORDER_START), "fork must keep emitting HookReady for mint birth line");
        require(!_hasHookReadyFor(forkLogs, HOOK_NON_TRIGGER), "fork replay must not emit phantom watcher HookReady");
        (watcherStatus,, watcherEmitted) = machine.getHookStatus(PLAN_ID, forkedOrderId, HOOK_NON_TRIGGER);
        require(watcherStatus == UVPStateMachine.HookStatus.Ready, "fork watcher must judge Ready");
        require(!watcherEmitted, "fork watcher must not mark readyEmitted");
    }

    function testForkOrderIsIdempotentForSameParameters() public {
        UVPStateMachine machine = _forkPlanMachine();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        UVPStateMachine.ForkBirthFact[] memory facts = new UVPStateMachine.ForkBirthFact[](1);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_STAGE_DONE,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(0xF001))
        });
        vm.prank(SUBMITTER_A);
        bytes32 first = machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            facts,
            new UVPStateMachine.SignalAuthorization[](0)
        );
        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            facts,
            new UVPStateMachine.SignalAuthorization[](0)
        );
        require(first == machine.forkOrderIdFor(PLAN_ID, parentOrderId, bytes32(uint256(0xF100))), "stable id");
    }

    function testForkOrderRejectsForgedBirthFact() public {
        UVPStateMachine machine = _forkPlanMachine();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        UVPStateMachine.ForkBirthFact[] memory facts = new UVPStateMachine.ForkBirthFact[](1);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_STAGE_DONE,
            payloadHash: bytes32(uint256(0xDEAD)),
            idempotencyKey: bytes32(uint256(0xF001))
        });
        vm.prank(ORDER_CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidForkBirthFact.selector, parentOrderId, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE
            )
        );
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            facts,
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    function testForkOrderRejectsUnauthorizedInitiator() public {
        UVPStateMachine machine = _forkPlanMachine();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedOrderFork.selector, PLAN_ID, parentOrderId, UNAUTHORIZED_SUBMITTER
            )
        );
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            _forkBirthFacts(),
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    function testForkOrderRejectsUnknownApprovalSignal() public {
        UVPStateMachine machine = _forkPlanMachine();
        bytes32 parentOrderId = ORDER_ID;
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.ForkApprovalSignalUnknown.selector,
                PLAN_ID,
                parentOrderId,
                SOURCE_BOOTSTRAP,
                SIGNAL_STAGE_DONE
            )
        );
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            new UVPStateMachine.ForkBirthFact[](0),
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    function testForkOrderRejectsTooManyBirthFacts() public {
        UVPStateMachine machine = _forkPlanMachine();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
        UVPStateMachine.ForkBirthFact[] memory facts = new UVPStateMachine.ForkBirthFact[](257);
        for (uint256 i = 0; i < facts.length; i++) {
            facts[i] = UVPStateMachine.ForkBirthFact({
                sourceId: SOURCE_BOOTSTRAP,
                signalId: SIGNAL_STAGE_DONE,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: bytes32(uint256(0xF001))
            });
        }
        vm.prank(ORDER_CREATOR);
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.TooManyForkBirthFacts.selector, 257));
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            facts,
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    function _forkPlanMachine() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory start = new UVPStateMachine.Instruction[](1);
        start[0] = _signal(SIGNAL_ORDER_START);
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: HOOK_ORDER_START,
            stageId: STAGE_INIT,
            hookName: HOOK_NAME_ORDER_START,
            flags: FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY,
            instructions: start,
            dependencyKeys: _deps(SIGNAL_ORDER_START)
        });
        UVPStateMachine.Instruction[] memory combo = new UVPStateMachine.Instruction[](6);
        combo[0] = _signal(SIGNAL_STAGE_DONE);
        combo[1] = _signal(SIGNAL_STAGE_REVIEW);
        combo[2] = _and(2);
        combo[3] = _signal(SIGNAL_VERIFY_FAIL);
        combo[4] = _or(2);
        combo[5] = _delay(10);
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_INIT,
            stageId: STAGE_AUDIT,
            hookName: HOOK_NAME_INIT_DONE,
            flags: FLAG_EMIT_READY,
            instructions: combo,
            dependencyKeys: _deps3(SIGNAL_STAGE_DONE, SIGNAL_STAGE_REVIEW, SIGNAL_VERIFY_FAIL)
        });
        _registerPlan(machine, hooks);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _forkAuthorizations());
    }

    function _forkAuthorizations() private pure returns (UVPStateMachine.SignalAuthorization[] memory auths) {
        auths = new UVPStateMachine.SignalAuthorization[](3);
        auths[0] = _authorization(SIGNAL_STAGE_DONE, SUBMITTER_A);
        auths[1] = _authorization(SIGNAL_STAGE_REVIEW, SUBMITTER_B);
        auths[2] = _authorization(SIGNAL_VERIFY_FAIL, SUBMITTER_A);
    }

    function _forkBirthFactsWithTrigger() private pure returns (UVPStateMachine.ForkBirthFact[] memory facts) {
        UVPStateMachine.ForkBirthFact[] memory base = _forkBirthFacts();
        facts = new UVPStateMachine.ForkBirthFact[](base.length + 1);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY
        });
        for (uint256 i = 0; i < base.length; i++) {
            facts[i + 1] = base[i];
        }
    }

    function _forkBirthFacts() private pure returns (UVPStateMachine.ForkBirthFact[] memory facts) {
        facts = new UVPStateMachine.ForkBirthFact[](3);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_STAGE_DONE,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(0xF001))
        });
        facts[1] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_STAGE_REVIEW,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(0xF002))
        });
        facts[2] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_VERIFY_FAIL,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(0xF003))
        });
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testMintFanOutMayShareBirthChannelKey() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, SIGNAL_TRIGGER);
        hooks[1] = _signalHook(HOOK_ALT_MINT, STAGE_ALT, HOOK_NAME_ORDER_START, true, SIGNAL_TRIGGER);

        bytes32 planId = _registerPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
        require(machine.planExists(planId), "mint fan-out plan not registered");
    }

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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testCommitPlanRejectsBirthChannelKeyHiddenByLeadingWatcher() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testWatcherMayShareBirthChannelKey() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _emitReadySignalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, SIGNAL_ORDER_START);

        bytes32 planId = _registerPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
        require(machine.planExists(planId), "plan not registered");
    }

    function testCommitPlanRejectsDependencyKeyWithoutSignalAtom() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(SIGNAL_AUDIT_PASS);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.HookDependencyKeyMismatch.selector, HOOK_INIT));
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function testCommitPlanRejectsSignalAtomMissingFromDependencyKeys() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_AUDIT_PASS);
        instructions[2] = _or(2);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER)
        );

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.HookDependencyKeyMismatch.selector, HOOK_INIT));
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

    function _signalInstructions(bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.Instruction[] memory instructions)
    {
        instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = _signal(signalId);
    }

    function testDockBirthDoesNotOverwriteCancelledEntranceHook() public {
        UVPStateMachine machine = _newMachine();
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
        _registerPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));

        bytes32 dockedOrderId = bytes32(uint256(1) << 255 | uint256(0x0DD1));
        vm.prank(address(_docking(machine)));
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidTriggerHook.selector, HOOK_ALT_MINT));
        machine.createDockedOrderFromModule(
            _dockEntranceRequest(
                PLAN_ID,
                dockedOrderId,
                ORDER_CREATOR,
                HOOK_ALT_MINT,
                STAGE_ALT,
                SOURCE_BOOTSTRAP,
                SIGNAL_TRIGGER,
                new UVPStateMachine.SignalAuthorization[](0)
            )
        );
        require(!machine.orderExists(PLAN_ID, dockedOrderId), "birth must roll back atomically");
    }

    function testDockBirthDoesNotOverwriteUnreadyEntranceHook() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_AUDIT_PASS);
        instructions[2] = _and(2);
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _hookWithFlags(
            HOOK_ALT_MINT,
            STAGE_ALT,
            HOOK_NAME_TRIGGER,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            instructions,
            _deps2(SIGNAL_TRIGGER, SIGNAL_AUDIT_PASS)
        );
        _registerPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));

        bytes32 dockedOrderId = bytes32(uint256(1) << 255 | uint256(0x0DD5));
        vm.prank(address(_docking(machine)));
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.InvalidTriggerHook.selector, HOOK_ALT_MINT));
        machine.createDockedOrderFromModule(
            _dockEntranceRequest(
                PLAN_ID,
                dockedOrderId,
                ORDER_CREATOR,
                HOOK_ALT_MINT,
                STAGE_ALT,
                SOURCE_BOOTSTRAP,
                SIGNAL_TRIGGER,
                new UVPStateMachine.SignalAuthorization[](0)
            )
        );
        require(!machine.orderExists(PLAN_ID, dockedOrderId), "partial delivery must roll back atomically");
    }

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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
    }

    function testFinalizePlanRejectsUnknownPlan() public {
        UVPStateMachine machine = _newMachine();

        vm.expectRevert(UVPStateMachine.PlanNotCommitted.selector);
        machine.finalizePlan(bytes32(uint256(0xBAAD)));
    }

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
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
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
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
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
        machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), _packedSignature(v, r, s));
    }

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
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: deadline
        });

        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.ExpiredPlanSignature.selector, deadline));
        machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), new bytes(65));
    }

    function testPlanMetadataAndHooksHashMismatchAreRejected() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(_sequentialPlan())),
            capabilitiesRoot: DockMerkle.root(new bytes32[](0)),
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
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
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
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
        machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), _packedSignature(v, r, s));
    }

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
            new bytes(64),
            _noAttribution()
        );
    }

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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
    }

    function testTriggerOrderFromOutsideRejectsUnauthorizedBirthSubmitter() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));

        UVPStateMachine.SignalAuthorization[] memory authorizations = _auths1(SIGNAL_TRIGGER, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_ORDER_START, SIGNAL_ORDER_START);
        trigger.submitter = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        bytes memory signature =
            _triggerOrderFromOutsideSignature(machine, trigger, authorizations, ATTACKER_SUBMITTER_PRIVATE_KEY);

        bytes32 expectedOrderId = machine.triggerOrderIdFor(
            trigger.planId, trigger.sourceId, trigger.signalId, trigger.payloadHash
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedBirthSubmitter.selector, vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY)
            )
        );
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
        require(!machine.orderExists(trigger.planId, expectedOrderId), "unauthorized birth must not mint order");
    }

    function testZeroBirthAuthorizerClosesOnlyOutsideChannel() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _hookWithFlags(
            HOOK_ALT_MINT,
            STAGE_ALT,
            HOOK_NAME_INIT_DONE,
            uint8(FLAG_ORDER_TRIGGER_DOCK | FLAG_EMIT_READY),
            _signalInstructions(SIGNAL_TRIGGER),
            _deps(SIGNAL_TRIGGER)
        );
        address publisher = vm.addr(PUBLISHER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(new bytes32[](0)),
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: address(0),
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
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        bytes32 planId =
            machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), _packedSignature(v, r, s));
        machine.finalizePlan(planId);
        PLAN_ID = planId;

        UVPStateMachine.SignalAuthorization[] memory outsideAuths = _auths1(SIGNAL_ORDER_START, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger =
            _outsideTriggerRequest(HOOK_INIT, SIGNAL_ORDER_START);
        trigger.planId = planId;
        bytes memory outsideSignature =
            _triggerOrderFromOutsideSignature(machine, trigger, outsideAuths, SUBMITTER_PRIVATE_KEY);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnauthorizedBirthSubmitter.selector, trigger.submitter)
        );
        machine.triggerOrderFromOutsideFor(
            trigger,
            outsideAuths,
            outsideSignature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
        bytes32 outsideOrderId =
            machine.triggerOrderIdFor(planId, trigger.sourceId, trigger.signalId, trigger.payloadHash);
        require(!machine.orderExists(planId, outsideOrderId), "closed outside channel must not mint");

        bytes32 dockedOrderId = bytes32(uint256(1) << 255 | uint256(0x0DD2));
        UVPStateMachine.SignalAuthorization[] memory dockAuths =
            new UVPStateMachine.SignalAuthorization[](2);
        dockAuths[0] = _authorization(SIGNAL_TRIGGER, address(this));
        dockAuths[1] = _authorization(SIGNAL_ORDER_START, vm.addr(SUBMITTER_PRIVATE_KEY));
        vm.prank(address(_docking(machine)));
        machine.createDockedOrderFromModule(
            _dockEntranceRequest(
                planId, dockedOrderId, vm.addr(SUBMITTER_PRIVATE_KEY), HOOK_ALT_MINT, STAGE_ALT, SOURCE_BOOTSTRAP,
                SIGNAL_TRIGGER, dockAuths
            )
        );
        require(machine.orderExists(planId, dockedOrderId), "dock birth must ignore birthAuthorizer gate");
        (UVPStateMachine.HookStatus dockStatus,, bool dockReady) = machine.getHookStatus(planId, dockedOrderId, HOOK_ALT_MINT);
        require(dockStatus == UVPStateMachine.HookStatus.Ready && dockReady, "dock entrance hook must be ready");

        vm.prank(vm.addr(SUBMITTER_PRIVATE_KEY));
        machine.submitSignal(
            planId,
            dockedOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_ORDER_START,
            PAYLOAD_HASH,
            bytes32(uint256(0x0DD3)),
            _noAttribution()
        );
        bytes32 linkedOrderId = machine.orderLinkOrderIdFor(
            planId, planId, dockedOrderId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH
        );
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory link = IUVPStateMachineCore.TriggerOrderFromSignalRequest({
                orderId: linkedOrderId,
                planId: planId,
                creator: ORDER_CREATOR,
                triggerOriginOrderId: dockedOrderId,
                originPlanId: planId,
                triggerHookId: HOOK_INIT,
                triggerStageId: STAGE_INIT,
                originSourceId: SOURCE_BOOTSTRAP,
                originSignalId: SIGNAL_ORDER_START,
                payloadHash: PAYLOAD_HASH,
                idempotencyKey: bytes32(uint256(0x0DD4)),
                submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
                deadline: block.timestamp + 1 hours
            });
        IUVPStateMachineCore.SignalAuthorization[] memory linkAuths =
            _moduleAuthorizations(_auths1(SIGNAL_ORDER_START, address(this)));
        bytes memory linkSignature =
            _triggerOrderFromSignalSignature(machine, link, linkAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        _orderLink(machine).triggerOrderFromSignalFor(
            link, linkAuths, linkSignature, new IUVPStateMachineCore.FactAttribution[](0)
        );
        require(machine.orderExists(planId, linkedOrderId), "order-link birth must ignore birthAuthorizer gate");
        (UVPStateMachine.HookStatus linkStatus,, bool linkReady) = machine.getHookStatus(planId, linkedOrderId, HOOK_INIT);
        require(linkStatus == UVPStateMachine.HookStatus.Ready && linkReady, "link trigger hook must be ready");
    }

    function testCancelledHookStatusIsTerminal() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_negativeHookPlan(HOOK_TIMEOUT)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));

        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        (UVPStateMachine.HookStatus status,, bool readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "hook not cancelled");

        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        (status,, readyEmitted) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Cancelled, "cancelled hook resurrected");
        require(!readyEmitted, "cancelled hook emitted ready");

        vm.expectRevert(UVPStateMachine.TimerNotWaiting.selector);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
    }

    function testStageHandoffRejectsAmbiguousPreviousExecutor() public {
        UVPStateMachine machine;
        DockInputWriter writer;
        (machine, writer) = _newMachineWithDockingWriter();
        SignalCapability[] memory overlay = _overlaySignalCapabilities();
        SignalCapability[] memory capabilities = new SignalCapability[](overlay.length + 1);
        for (uint256 i = 0; i < overlay.length; i++) {
            capabilities[i] = overlay[i];
        }
        capabilities[overlay.length] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_FALLBACK, targetOrderRelation: 0
        });
        _registerPlan(machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), capabilities);
        _submitTriggerOrderFromOutside(
            machine, PLAN_ID, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(0x9140)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );

        writer.write(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            bytes32(uint256(0x9141)),
            SUBMITTER_A,
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        writer.write(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_FALLBACK,
            bytes32(uint256(0x9142)),
            SUBMITTER_B,
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_FALLBACK)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(1, SUBMITTER_B, PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StagePreviousExecutorAmbiguous.selector,
                ORDER_ID,
                STAGE_AUDIT,
                uint64(block.timestamp)
            )
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
    }

    function _newMachineWithDockingWriter() private returns (UVPStateMachine machine, DockInputWriter writer) {
        machine = _newUnfrozenMachine();
        writer = new DockInputWriter(machine);
        machine.setDockingModule(address(writer));
        machine.freezeModules();
        _currentMachine = machine;
    }

    function testUnmaterializedStageWatcherIsSkippedNotBricked() public {
        UVPStateMachine machine = _newMachine();
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

        vm.prank(address(_docking(machine)));
        machine.submitSignalFromModule(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            address(this),
            _noAttribution()
        );

        require(machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER), "fact missing");
    }

    function testExplicitAuthorizationExemptsExecutorPatchOnBothPaths() public {
        UVPStateMachine machine = _newMachine();
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
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        capabilities[3] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_AUDIT_PASS, targetOrderRelation: 0
        });
        _registerPlan(machine, hooks, bindings, capabilities);

        UVPStateMachine.SignalAuthorization[] memory authorizations = new UVPStateMachine.SignalAuthorization[](5);
        authorizations[0] = _authorization(SIGNAL_ORDER_START, address(this));
        authorizations[1] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, address(this));
        authorizations[2] = _stageAuthorization(PRODUCTION_SOURCE, PRODUCTION_SIGNAL, SUBMITTER_A);
        authorizations[3] = _authorization(SIGNAL_STAGE_DONE, SUBMITTER_A);
        authorizations[4] = _authorization(SIGNAL_AUDIT_PASS, address(this));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, authorizations);

        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_AUDIT_PASS,
            PAYLOAD_HASH,
            bytes32(uint256(0x9104)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS)
        );

        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH));

        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            PRODUCTION_SOURCE,
            PRODUCTION_SIGNAL,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, PRODUCTION_SOURCE, PRODUCTION_SIGNAL)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest5 = _derivedSignalRequestWithPlans(
            ORDER_ID,
            STAGE_AUDIT,
            PLAN_ID,
            ORDER_ID,
            PLAN_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9102))
        );
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

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest6 = _derivedSignalRequestWithPlans(
            ORDER_ID,
            STAGE_AUDIT,
            PLAN_ID,
            ORDER_ID,
            PLAN_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9110))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs6 = _derivedProofs(machine, derivedRequest6);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(UVPStateMachine.UnknownHook.selector);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest6, SUBMITTER_A, derivedProofs6);

        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_AUDIT_PASS,
            PAYLOAD_HASH,
            bytes32(uint256(0x9111)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_AUDIT_PASS)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest7 = _derivedSignalRequestWithPlans(
            ORDER_ID,
            STAGE_AUDIT,
            PLAN_ID,
            ORDER_ID,
            PLAN_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9112))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs7 = _derivedProofs(machine, derivedRequest7);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest7, SUBMITTER_A, derivedProofs7);

        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH));
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest8 = _derivedSignalRequestWithPlans(
            ORDER_ID,
            STAGE_AUDIT,
            PLAN_ID,
            ORDER_ID,
            PLAN_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9113))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs8 = _derivedProofs(machine, derivedRequest8);
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest8, SUBMITTER_A, derivedProofs8);
        require(
            machine.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE),
            "relation-0 derived signal missing after assign"
        );
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine).submitDerivedSignal(derivedRequest8, SUBMITTER_A, derivedProofs8);
    }

    function testCommitPlanRejectsSwappedExecutorCandidates() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.ExecutorCandidate[] memory candidates = _defaultExecutorCandidates(hooks);
        bytes32[] memory leaves = _executorCandidateLeaves(candidates);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: vm.addr(PUBLISHER_PRIVATE_KEY),
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(new bytes32[](0)),
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: DockMerkle.root(leaves),
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
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
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);

        UVPStateMachine.ExecutorCandidate[] memory swapped =
            new UVPStateMachine.ExecutorCandidate[](candidates.length + 1);
        for (uint256 i = 0; i < candidates.length; i++) {
            swapped[i] = candidates[i];
        }
        swapped[candidates.length] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_INIT, executor: address(0xbeef)});
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.ExecutorCandidatesRootMismatch.selector,
                DockMerkle.root(leaves),
                DockMerkle.root(_executorCandidateLeaves(swapped))
            )
        );
        machine.commitPlan(commit, hooks, swapped, _packedSignature(v, r, s));
    }

    function testAdmissionInstructionDepthCap() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_deepAdmissionHookArray(120)));
        UVPStateMachine machine2 = _newMachine();
        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine2, _withOrderStart(_deepAdmissionHookArray(121)), new StageSelectorBinding[](0), new SignalCapability[](0)
        );
    }

    function testHookInstructionDepthCap() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_deepWatcherHookArray(120)));
        UVPStateMachine machine2 = _newMachine();
        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(
            machine2, _withOrderStart(_deepWatcherHookArray(121)), new StageSelectorBinding[](0), new SignalCapability[](0)
        );
    }

    function testDependencyKeyHookFanoutCap() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_watchersOnSharedTriggerKey(16)));
        UVPStateMachine machine2 = _newMachine();
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.TooManyHooksPerDependencyKey.selector,
                keccak256(abi.encode(SOURCE_BOOTSTRAP, SIGNAL_TRIGGER))
            )
        );
        _commitPlan(
            machine2, _withOrderStart(_watchersOnSharedTriggerKey(17)), new StageSelectorBinding[](0), new SignalCapability[](0)
        );
    }

    function testSetModuleRejectsEOATarget() public {
        UVPStateMachine machine = _newUnfrozenMachine();
        vm.expectRevert(UVPStateMachine.InvalidModuleAddress.selector);
        machine.setLens(address(0x9999));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
        machine.freezeModules();
    }

    function testDockingModuleSignalVocabularyGate() public {
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory capabilities = new SignalCapability[](2);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        _registerPlan(
            machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)), _emptySelectorBindings(), capabilities
        );
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));

        address docking = address(_docking(machine));
        vm.prank(docking);
        machine.submitSignalFromModule(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9120)),
            address(this),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE)
        );
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
            address(this),
            _noAttribution()
        );
    }

    function testFinalizePlanReentrantCallSeesFinalized() public {
        UVPStateMachine machine = new UVPStateMachine();
        ReenteringMetadataModule attacker = new ReenteringMetadataModule(machine);
        machine.setStagePatchModule(address(new UVPStagePatchModule(address(machine))));
        machine.setDerivedSignalModule(address(new UVPDerivedSignalModule(address(machine))));
        machine.setDockingModule(address(new UVPDockingModule(address(machine), address(attacker))));
        machine.setPlanMetadataModule(address(attacker));
        machine.setOrderLinkModule(address(new UVPOrderLinkModule(address(machine))));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
        machine.freezeModules();

        StageSelectorBinding[] memory bindings = new StageSelectorBinding[](0);
        SignalCapability[] memory capabilities = new SignalCapability[](0);
        bytes32 planId =
            _commitPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)), bindings, capabilities);

        vm.expectRevert(UVPStateMachine.PlanAlreadyFinalized.selector);
        machine.finalizePlan(planId);
    }

    function testDerivedSignalFromSideExplicitAuthorizationDoesNotExempt() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(
            machine,
            _withOrderStart(_patchableSequentialPlan()),
            _selectorBindings(),
            _derivedActiveSignalCapabilities()
        );
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        _triggerOrderFromSignalRequest(
            machine,
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest9 = _derivedSignalRequest(
            LINKED_ORDER_ID,
            STAGE_AUDIT,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0x9103))
        );
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
        machine2.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine2, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );
        _triggerOrderFromSignalRequest(
            machine2,
            _signalTriggerRequest(machine2, ORDER_ID, bytes32(uint256(2))),
            _triggeredDerivedSignalAuths(SUBMITTER_A)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest10 = _derivedSignalRequest(
            LINKED_ORDER_ID,
            STAGE_AUDIT,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(0x9103))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs10 = _derivedProofs(machine2, derivedRequest10);
        vm.prank(SUBMITTER_A);
        _derivedSignal(machine2).submitDerivedSignal(derivedRequest10, SUBMITTER_A, derivedProofs10);
        require(
            machine2.hasSignal(PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL),
            "target-side explicit authorization must pass with the business source key"
        );
    }

    function testTriggerOrderFromOutsideRejectsForeignFact() public {
        UVPStateMachine machine = _newMachine();
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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
    }

    function testDuplicateCurrentOrderFactCapabilityAcrossStagesIsRejected() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_sequentialPlan());
        StageSelectorBinding[] memory bindings = new StageSelectorBinding[](0);
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
        bytes32 initLeaf = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_INIT, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, uint256(0))
        );
        bytes32 auditLeaf = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_AUDIT, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, uint256(0))
        );
        require(
            _planMetadata(machine)
                .verifySignalCapability(
                    planId, STAGE_INIT, PRODUCTION_SOURCE, PRODUCTION_SIGNAL, 0, _merkleProofFor(sortedLeaves, initLeaf)
                ),
            "init owner leaf must verify"
        );
        require(
            _planMetadata(machine)
                .verifySignalCapability(
                    planId,
                    STAGE_AUDIT,
                    PRODUCTION_SOURCE,
                    PRODUCTION_SIGNAL,
                    0,
                    _merkleProofFor(sortedLeaves, auditLeaf)
                ),
            "audit owner leaf must verify"
        );
    }

    function testGetSignalAuthorizationReturnsEmptyForDelegatedExecutorMismatch() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_positiveHookPlan(HOOK_INIT, true)));
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
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
        return _registerPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
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
            machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0), publisherPrivateKey
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
        UVPStateMachine.ExecutorCandidate[] memory candidates = _defaultExecutorCandidates(hooks);
        return _commitPlanWithCandidates(
            machine, hooks, selectorBindings, signalCapabilities, publisherPrivateKey, candidates
        );
    }

    function _commitPlanWithoutCandidates(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities
    ) private returns (bytes32 planId) {
        return _commitPlanWithCandidates(
            machine,
            hooks,
            selectorBindings,
            signalCapabilities,
            PUBLISHER_PRIVATE_KEY,
            new UVPStateMachine.ExecutorCandidate[](0)
        );
    }

    function _commitPlanWithCandidates(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        uint256 publisherPrivateKey,
        UVPStateMachine.ExecutorCandidate[] memory executorCandidates
    ) private returns (bytes32 planId) {
        address publisher = vm.addr(publisherPrivateKey);
        address birthAuthorizer = publisherPrivateKey == ATTACKER_PUBLISHER_PRIVATE_KEY
            ? vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY)
            : vm.addr(SUBMITTER_PRIVATE_KEY);
        bytes32[] memory leaves = _capabilityLeaves(selectorBindings, signalCapabilities);
        bytes32[] memory candidateLeaves = _executorCandidateLeaves(executorCandidates);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(leaves),
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: DockMerkle.root(candidateLeaves),
            birthAuthorizer: birthAuthorizer,
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
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _stateMachineDomainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherPrivateKey, digest);
        planId = machine.commitPlan(commit, hooks, executorCandidates, _packedSignature(v, r, s));
        PLAN_ID = planId;
        _planIds[address(machine)] = planId;
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        tables.bindings = selectorBindings;
        tables.capabilities = signalCapabilities;
        tables.sortedLeaves = _sortedUnique(leaves);
        tables.candidateLeaves = _sortedUnique(candidateLeaves);
    }

    function _defaultExecutorCandidates(UVPStateMachine.CompactHook[] memory hooks)
        private
        returns (UVPStateMachine.ExecutorCandidate[] memory candidates)
    {
        bytes32[] memory stages = new bytes32[](hooks.length);
        uint256 stageCount;
        for (uint256 i = 0; i < hooks.length; i++) {
            bool seen = false;
            for (uint256 j = 0; j < stageCount; j++) {
                if (stages[j] == hooks[i].stageId) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                stages[stageCount++] = hooks[i].stageId;
            }
        }
        address[6] memory executors = [
            SUBMITTER_A,
            SUBMITTER_B,
            vm.addr(SUBMITTER_PRIVATE_KEY),
            vm.addr(WRONG_SUBMITTER_PRIVATE_KEY),
            NEW_OWNER,
            address(0xcc)
        ];
        candidates = new UVPStateMachine.ExecutorCandidate[](stageCount * executors.length);
        uint256 count;
        for (uint256 i = 0; i < stageCount; i++) {
            for (uint256 j = 0; j < executors.length; j++) {
                candidates[count++] = UVPStateMachine.ExecutorCandidate({stageId: stages[i], executor: executors[j]});
            }
        }
    }

    function _executorCandidateLeaves(UVPStateMachine.ExecutorCandidate[] memory candidates)
        private
        pure
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](candidates.length);
        for (uint256 i = 0; i < candidates.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, candidates[i].stageId, candidates[i].executor)
            );
        }
    }

    struct CapabilityTables {
        StageSelectorBinding[] bindings;
        SignalCapability[] capabilities;
        bytes32[] sortedLeaves;
        bytes32[] candidateLeaves;
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
                    SELECTOR_BINDING_LEAF_DOMAIN, selectorBindings[i].selectorStageId, selectorBindings[i].targetStageId
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
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
    }

    function _dockEntranceRequest(
        bytes32 planId,
        bytes32 linkedOrderId,
        address creator,
        bytes32 entranceHookId,
        bytes32 entranceStageId,
        bytes32 sourceId,
        bytes32 signalId,
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private view returns (UVPStateMachine.DockEntranceRequest memory) {
        return UVPStateMachine.DockEntranceRequest({
            targetPlanId: planId,
            linkedOrderId: linkedOrderId,
            creator: creator,
            relayer: address(this),
            entranceHookId: entranceHookId,
            entranceStageId: entranceStageId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: address(this),
            authorizations: authorizations,
            entranceAttribution: UVPStateMachine.FactAttribution({
                sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
            })
        });
    }

    function _dockInputFact(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) private pure returns (UVPStateMachine.DockInputFact memory) {
        return UVPStateMachine.DockInputFact({
            planId: planId,
            orderId: orderId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: payloadHash,
            idempotencyKey: idempotencyKey,
            submitter: submitter,
            attribution: UVPStateMachine.FactAttribution({
                sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
            })
        });
    }

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

    function _moduleBindingFor(UVPStateMachine machine, bytes32 planId, bytes32 targetStageId)
        private
        view
        returns (IUVPStateMachineCore.SelectorBindingProof memory bindingProof)
    {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        for (uint256 i = 0; i < tables.bindings.length; i++) {
            if (tables.bindings[i].targetStageId == targetStageId) {
                bytes32 leaf = keccak256(
                    abi.encode(
                        SELECTOR_BINDING_LEAF_DOMAIN,
                        tables.bindings[i].selectorStageId,
                        tables.bindings[i].targetStageId
                    )
                );
                return IUVPStateMachineCore.SelectorBindingProof({
                    selectorStageId: tables.bindings[i].selectorStageId,
                    proof: _merkleProofFor(tables.sortedLeaves, leaf)
                });
            }
        }
        return IUVPStateMachineCore.SelectorBindingProof({selectorStageId: bytes32(0), proof: new bytes32[](0)});
    }

    function _candidateProofFor(UVPStateMachine machine, bytes32 planId, bytes32 stageId, address executor)
        private
        view
        returns (bytes32[] memory proof)
    {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        bytes32 leaf = keccak256(abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, stageId, executor));
        bytes32[] memory sorted = tables.candidateLeaves;
        for (uint256 i = 0; i < sorted.length; i++) {
            if (sorted[i] == leaf) {
                return _merkleProofFor(sorted, leaf);
            }
        }
        proof = new bytes32[](0);
    }

    function _authsHashLocal(IUVPStateMachineCore.SignalAuthorization[] memory authorizations)
        private
        pure
        returns (bytes32 rollingHash)
    {
        rollingHash = keccak256(abi.encode(authorizations.length));
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
    }

    function _applyExecutorPatch(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        UVPStagePatchModule.StageExecutorPatch memory patch
    ) private {
        IUVPStateMachineCore.SignalAuthorization[] memory authorizations =
            _executorAuthorizationsFor(machine, planId, ORDER_ID, patch.targetStageId, patch.executor);
        patch.authorizationsHash = _authsHashLocal(authorizations);
        _stagePatch(machine)
            .applyStageExecutorPatch(
                planId,
                orderId,
                patch,
                _moduleBindingFor(machine, planId, patch.targetStageId),
                _candidateProofFor(machine, planId, patch.targetStageId, patch.executor),
                authorizations
            );
    }

    function _executorAuthorizationsFor(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId,
        address executor
    ) private view returns (IUVPStateMachineCore.SignalAuthorization[] memory authorizations) {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        IUVPStateMachineCore.SignalAuthorization[] memory buffer =
            new IUVPStateMachineCore.SignalAuthorization[](tables.capabilities.length);
        uint256 count;
        for (uint256 i = 0; i < tables.capabilities.length; i++) {
            SignalCapability storage capability = tables.capabilities[i];
            if (capability.stageId != stageId || capability.targetOrderRelation != 0) {
                continue;
            }
            buffer[count++] = IUVPStateMachineCore.SignalAuthorization({
                sourceId: capability.targetSourceId,
                signalId: capability.signalId,
                submitter: executor,
                role: ROLE_EXECUTOR,
                metadataHash: EXECUTOR_METADATA_HASH
            });
        }
        authorizations = new IUVPStateMachineCore.SignalAuthorization[](count);
        for (uint256 i = 0; i < count; i++) {
            authorizations[i] = buffer[i];
        }
    }

    function _toMachineAuths(IUVPStateMachineCore.SignalAuthorization[] memory core)
        private
        pure
        returns (UVPStateMachine.SignalAuthorization[] memory converted)
    {
        converted = new UVPStateMachine.SignalAuthorization[](core.length);
        for (uint256 i = 0; i < core.length; i++) {
            converted[i] = UVPStateMachine.SignalAuthorization({
                sourceId: core[i].sourceId,
                signalId: core[i].signalId,
                submitter: core[i].submitter,
                role: core[i].role,
                metadataHash: core[i].metadataHash
            });
        }
    }

    function _birthSignalCapabilities() private pure returns (SignalCapability[] memory capabilities) {
        capabilities = new SignalCapability[](1);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
    }

    function _capabilityProofFor(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 stageId,
        bytes32 sourceId,
        bytes32 signalId,
        uint8 relation
    ) private view returns (bytes32[] memory proof) {
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        bytes32 leaf =
            keccak256(abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, stageId, sourceId, signalId, uint256(relation)));
        for (uint256 i = 0; i < tables.sortedLeaves.length; i++) {
            if (tables.sortedLeaves[i] == leaf) {
                return _merkleProofFor(tables.sortedLeaves, leaf);
            }
        }
        return new bytes32[](0);
    }

    function _derivedProofs(UVPStateMachine machine, UVPDerivedSignalModule.DerivedSignalRequest memory request)
        private
        view
        returns (UVPDerivedSignalModule.DerivedSignalProofs memory proofs)
    {
        uint8 relation = 0;
        if (!(request.fromPlanId == request.targetPlanId && request.fromOrderId == request.targetOrderId)) {
            try _orderLink(machine)
                .targetOrderRelation(
                    request.fromPlanId, request.fromOrderId, request.targetPlanId, request.targetOrderId
                ) returns (
                uint8 linkedRelation
            ) {
                relation = linkedRelation;
            } catch {
                relation = 1;
            }
        }
        proofs.fromCapabilityProof = _capabilityProofFor(
            machine, request.fromPlanId, request.fromStageId, request.targetSourceId, request.signalId, relation
        );
        if (relation != 0) {
            proofs.targetCapabilityProof = _capabilityProofFor(
                machine, request.targetPlanId, request.fromStageId, request.targetSourceId, request.signalId, relation
            );
        }
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
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(0x9101)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );
    }

    function _activateInitialStageExecutor(UVPStateMachine machine, address selector, address executor) private {
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, executor, PATCH_HASH);
        if (selector == address(this)) {
            _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
            return;
        }
        vm.prank(selector);
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
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
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
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
        return _stageExecutorPatchWithMode(patchNonce, executor, patchHash, EXECUTOR_PATCH_MODE_ASSIGN, address(0));
    }

    function _stageExecutorPatchWithMode(
        uint256 patchNonce,
        address executor,
        bytes32 patchHash,
        bytes32 mode,
        address previousExecutor
    ) private pure returns (UVPStagePatchModule.StageExecutorPatch memory) {
        return UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: STAGE_INIT,
            targetStageId: STAGE_AUDIT,
            executor: executor,
            role: ROLE_EXECUTOR,
            executorMetadataHash: EXECUTOR_METADATA_HASH,
            mode: mode,
            previousExecutor: previousExecutor,
            authorizationsHash: bytes32(0),
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
        machine.triggerOrderFromOutsideFor(
            trigger,
            authorizations,
            signature,
            _factAttribution(machine, trigger.planId, trigger.sourceId, trigger.signalId)
        );
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
        _orderLink(machine)
            .triggerOrderFromSignalFor(
                trigger, moduleAuthorizations, signature, _originFactAttributions(machine, trigger)
            );
    }

    function _originFactAttributions(
        UVPStateMachine machine,
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger
    ) private view returns (IUVPStateMachineCore.FactAttribution[] memory attributions) {
        UVPStateMachine.FactAttribution memory owner =
            _factAttribution(machine, trigger.originPlanId, trigger.originSourceId, trigger.originSignalId);
        attributions = new IUVPStateMachineCore.FactAttribution[](1);
        attributions[0] = IUVPStateMachineCore.FactAttribution({
            sourceId: owner.sourceId,
            signalId: owner.signalId,
            stageId: owner.stageId,
            capabilityProof: owner.capabilityProof
        });
    }

    function _triggerOrderFromSignalForKey(
        UVPStateMachine machine,
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory trigger,
        IUVPStateMachineCore.SignalAuthorization[] memory moduleAuthorizations,
        uint256 submitterPrivateKey
    ) private {
        bytes memory signature =
            _triggerOrderFromSignalSignature(machine, trigger, moduleAuthorizations, submitterPrivateKey);
        _orderLink(machine)
            .triggerOrderFromSignalFor(
                trigger, moduleAuthorizations, signature, new IUVPStateMachineCore.FactAttribution[](0)
            );
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

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] =
            _hookWithFlags(hookId, STAGE_INIT, HOOK_NAME_TIMEOUT, FLAG_EMIT_READY, instructions, _deps(SIGNAL_TRIGGER));
    }

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

    function _decayingVetoHookPlan(bytes32 hookId, uint64 delaySeconds)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](5);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[2] = _delay(delaySeconds);
        instructions[3] = _not();
        instructions[4] = _and(2);

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            hookId,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_TRIGGER, SIGNAL_VERIFY_FAIL)
        );
    }

    function _liveVetoWaitHookPlan(bytes32 hookId) private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](6);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _delay(5);
        instructions[2] = _signal(SIGNAL_VERIFY_FAIL);
        instructions[3] = _delay(10);
        instructions[4] = _not();
        instructions[5] = _and(2);

        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            hookId,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps2(SIGNAL_TRIGGER, SIGNAL_VERIFY_FAIL)
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

    function _watcherSequentialPlan() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _emitReadySignalHook(HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, SIGNAL_TRIGGER);
        hooks[1] = _emitReadySignalHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_INIT_CMP);
        hooks[2] = _emitReadySignalHook(HOOK_TIMEOUT, STAGE_AUDIT, HOOK_NAME_TIMEOUT, SIGNAL_AUDIT_PASS);
    }

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

    function _deepAdmissionHookArray(uint256 depth_)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2 * depth_ + 1);
        for (uint256 i = 0; i <= depth_; i++) {
            instructions[i] = _signal(SIGNAL_STAGE_DONE);
        }
        for (uint256 i = 0; i < depth_; i++) {
            instructions[depth_ + 1 + i] = _and(2);
        }
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_ADMISSION_DEPTH,
            STAGE_INIT,
            HOOK_NAME_INIT_DONE,
            FLAG_ADMISSION,
            instructions,
            _deps(SIGNAL_STAGE_DONE)
        );
    }

    function _deepWatcherHookArray(uint256 depth_)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](2 * depth_ + 1);
        for (uint256 i = 0; i <= depth_; i++) {
            instructions[i] = _signal(SIGNAL_STAGE_DONE);
        }
        for (uint256 i = 0; i < depth_; i++) {
            instructions[depth_ + 1 + i] = _and(2);
        }
        hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_WATCHER_DEPTH,
            STAGE_INIT,
            HOOK_NAME_INIT_DONE,
            FLAG_EMIT_READY,
            instructions,
            _deps(SIGNAL_STAGE_DONE)
        );
    }

    function _watchersOnSharedTriggerKey(uint256 count)
        private
        pure
        returns (UVPStateMachine.CompactHook[] memory hooks)
    {
        hooks = new UVPStateMachine.CompactHook[](count);
        for (uint256 i = 0; i < count; i++) {
            hooks[i] =
                _emitReadySignalHook(bytes32(uint256(0x6100) + i), STAGE_INIT, HOOK_NAME_INIT_DONE, SIGNAL_TRIGGER);
        }
    }

    function _selectorBindings() private pure returns (StageSelectorBinding[] memory selectorBindings) {
        selectorBindings = new StageSelectorBinding[](1);
        selectorBindings[0] = StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
    }

    function _signalCapabilities() private pure returns (SignalCapability[] memory capabilities) {
        capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_VERIFY_FAIL, targetOrderRelation: 1
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_TRIGGER, targetOrderRelation: 0
        });
    }

    function _overlaySignalCapabilities() private pure returns (SignalCapability[] memory capabilities) {
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
        capabilities[3] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_INIT_CMP, targetOrderRelation: 0
        });
        capabilities[4] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: STAGE_INIT, signalId: SIGNAL_AUDIT_PASS, targetOrderRelation: 0
        });
    }

    function _productionOverlaySignalCapabilities() private pure returns (SignalCapability[] memory capabilities) {
        capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: PRODUCTION_SOURCE, signalId: PRODUCTION_SIGNAL, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_INIT_CMP, targetOrderRelation: 0
        });
    }

    function _derivedActiveSignalCapabilities() private pure returns (SignalCapability[] memory capabilities) {
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
        capabilities[3] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_TRIGGER, targetOrderRelation: 0
        });
    }

    function _emptySignalCapabilities() private pure returns (SignalCapability[] memory capabilities) {
        capabilities = new SignalCapability[](0);
    }

    function _duplicateSelectorBindings() private pure returns (StageSelectorBinding[] memory selectorBindings) {
        selectorBindings = new StageSelectorBinding[](2);
        selectorBindings[0] = StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
        selectorBindings[1] = StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
    }

    function _emptySelectorBindings() private pure returns (StageSelectorBinding[] memory selectorBindings) {
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

    function _hasHookReadyFor(Vm.Log[] memory logs, bytes32 hookId) private pure returns (bool) {
        bytes32 topic = keccak256("HookReady(bytes32,bytes32,bytes32,bytes32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 4 && logs[i].topics[0] == topic && logs[i].topics[3] == hookId) {
                return true;
            }
        }
        return false;
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

    function _firstLogWithTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (Vm.Log memory found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                return logs[i];
            }
        }
        revert("log topic not found");
    }

    function testOrDelayAnchorsOnEarliestReceivedSignal() public {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](4);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(bytes32(uint256(0x4002)));
        instructions[2] = _or(2);
        instructions[3] = _delay(5);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
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
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            bytes32(uint256(0x4002)),
            PAYLOAD_HASH,
            bytes32(uint256(0x4003)),
            _noAttribution()
        );
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "late branch must not regress ready");
    }

    function testOrCompositeDelayAnchorsOnEarliestMaturingBranch() public {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](6);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_INIT_CMP);
        instructions[2] = _and(2);
        instructions[3] = _signal(SIGNAL_AUDIT_PASS);
        instructions[4] = _or(2);
        instructions[5] = _delay(10);

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _hookWithFlags(
            HOOK_TIMEOUT,
            STAGE_INIT,
            HOOK_NAME_TIMEOUT,
            FLAG_EMIT_READY,
            instructions,
            _deps3(SIGNAL_TRIGGER, SIGNAL_INIT_CMP, SIGNAL_AUDIT_PASS)
        );

        UVPStateMachine machine = _registeredMachine(hooks);

        vm.warp(10);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        (UVPStateMachine.HookStatus status, uint64 dueAt,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Init, "no mature branch before C arrives");
        require(dueAt == 0, "no due date before any branch matures");

        vm.warp(40);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_AUDIT_PASS,
            PAYLOAD_HASH,
            bytes32(uint256(0x4005)),
            _noAttribution()
        );
        (status, dueAt,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Wait, "must wait on C maturity + delay");
        require(dueAt == 50, "delay must anchor on C maturity: 40+10");

        vm.warp(45);
        vm.expectRevert(UVPStateMachine.TimerNotDue.selector);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);

        vm.warp(50);
        machine.pokeTimer(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "ready at C maturity + delay");

        vm.warp(60);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(0x4004)),
            _noAttribution()
        );
        (status,,) = machine.getHookStatus(PLAN_ID, ORDER_ID, HOOK_TIMEOUT);
        require(status == UVPStateMachine.HookStatus.Ready, "late AND maturity must not regress ready");
    }

    function testChainedDelayAnchorsOnMaturityMoment() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_positiveHookPlan(HOOK_INIT, true));
        UVPStateMachine.Instruction[] memory chain = new UVPStateMachine.Instruction[](3);
        chain[0] = _signal(SIGNAL_STAGE_DONE);
        chain[1] = _delay(1);
        chain[2] = _delay(5);
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: HOOK_AUDIT,
            stageId: STAGE_AUDIT,
            hookName: HOOK_NAME_INIT_DONE,
            flags: FLAG_EMIT_READY,
            instructions: chain,
            dependencyKeys: _deps(SIGNAL_STAGE_DONE)
        });
        vm.expectRevert(UVPStateMachine.InvalidInstruction.selector);
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
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
        _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
    }

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

        bytes32 planId = _commitPlan(machine, hooks, new StageSelectorBinding[](0), new SignalCapability[](0));
        require(machine.planCommitted(planId), "plan should commit");
    }

    function testCrossPlanOrderIdSquattingIsIsolated() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_emitReadyPositiveHookPlan(HOOK_INIT));

        bytes32 attackerPlanId = _registerPlanWithKey(machine, hooks, ATTACKER_PUBLISHER_PRIVATE_KEY);
        bytes32 victimPlanId = _registerPlanWithKey(machine, hooks, PUBLISHER_PRIVATE_KEY);
        require(attackerPlanId != victimPlanId, "plan ids must differ");

        bytes32 attackerOrderId =
            machine.triggerOrderIdFor(attackerPlanId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH);
        bytes32 victimOrderId =
            machine.triggerOrderIdFor(victimPlanId, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH);
        require(attackerOrderId != victimOrderId, "plan-scoped derivation must differ");

        address attackerSubmitter = vm.addr(ATTACKER_SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine,
            attackerPlanId,
            attackerSubmitter,
            _auths1(SIGNAL_TRIGGER, attackerSubmitter),
            ATTACKER_SUBMITTER_PRIVATE_KEY
        );
        require(machine.orderExists(attackerPlanId, attackerOrderId), "attacker order missing");

        address victimSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, victimPlanId, victimSubmitter, _auths1(SIGNAL_TRIGGER, victimSubmitter), SUBMITTER_PRIVATE_KEY
        );
        require(machine.orderExists(victimPlanId, victimOrderId), "victim order blocked by squatting");
        require(!machine.orderExists(victimPlanId, attackerOrderId), "attacker id leaked into victim plan");
        require(!machine.orderExists(attackerPlanId, victimOrderId), "victim id leaked into attacker plan");

        vm.prank(victimSubmitter);
        machine.submitSignal(
            victimPlanId,
            victimOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _noAttribution()
        );
        (UVPStateMachine.HookStatus victimStatus,, bool victimReady) =
            machine.getHookStatus(victimPlanId, victimOrderId, HOOK_INIT);
        (UVPStateMachine.HookStatus attackerStatus,, bool attackerReady) =
            machine.getHookStatus(attackerPlanId, attackerOrderId, HOOK_INIT);
        require(victimStatus == UVPStateMachine.HookStatus.Ready, "victim hook not ready");
        require(victimReady, "victim ready marker missing");
        require(attackerStatus == UVPStateMachine.HookStatus.Init, "attacker order contaminated");
        require(!attackerReady, "attacker ready marker set");

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
            attackerPlanId,
            attackerOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _noAttribution()
        );

        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        _submitTriggerOrderFromOutsideWithKey(
            machine, victimPlanId, victimSubmitter, _auths1(SIGNAL_TRIGGER, victimSubmitter), SUBMITTER_PRIVATE_KEY
        );
    }

    function testTriggerOrderIdForMatchesPinnedMirrorVector() public {
        UVPStateMachine machine = _newMachine();

        require(
            machine.triggerOrderIdFor(
                    bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), bytes32(uint256(4))
                ) == 0x392791df626408017a264f53fde61065d5a93a32b60171df9d8a46afdf82992d,
            "V1 mirror vector drifted"
        );

        require(
            machine.triggerOrderIdFor(
                0x23ed4d6a785e89846f63d29858367b8fe694fb73179a0c2bc540e0687079c161,
                0x1fab0c92eaead7da02fe29795732249e0861c98d6738709e6be992a170920770,
                0x69a75a88c14fab0bfb411e1062f0e56850184f83a4737b3b14440b08947b43da,
                0xebc84cbd75ba5516bf45e7024a9e12bc3c5c880f73e3a5beca7ebba52b2867a7
            ) == 0x5ea3f67d172d893746b323173444e0dff190f5a4d4d91db58776692ad483009a,
            "V2 mirror vector drifted"
        );

        require(
            machine.triggerOrderIdFor(
                0x23ed4d6a785e89846f63d29858367b8fe694fb73179a0c2bc540e0687079c161,
                0x1fab0c92eaead7da02fe29795732249e0861c98d6738709e6be992a170920770,
                0x69a75a88c14fab0bfb411e1062f0e56850184f83a4737b3b14440b08947b43da,
                0x7ddb57e56bc008d7f232156ac0c4a9be3da0582cbda6ae545fb75e0b912ee6fa
            ) == 0x7adbfa9eb5e66f4bda59ce36fa07abdf9979eb14222e023ed9480d0adb8d2c0a,
            "V3 mask vector drifted"
        );

        require(
            machine.triggerOrderIdFor(bytes32(0), bytes32(0), bytes32(0), bytes32(0))
                == 0x012893657d8eb2efad4de0a91bcd0e39ad9837745dec3ea923737ea803fc8e3d,
            "V4 zero vector drifted"
        );
    }

    function testCrossPlanCapabilityMirrorIsRejected() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = _withOrderStart(_sequentialPlan());
        SignalCapability[] memory capabilities = _signalCapabilities();
        StageSelectorBinding[] memory noSelectorBindings = new StageSelectorBinding[](0);

        bytes32 victimPlanId =
            _commitPlanWithKey(machine, hooks, noSelectorBindings, capabilities, PUBLISHER_PRIVATE_KEY);
        machine.finalizePlan(victimPlanId);
        bytes32 attackerPlanId =
            _commitPlanWithKey(machine, hooks, noSelectorBindings, capabilities, ATTACKER_PUBLISHER_PRIVATE_KEY);
        machine.finalizePlan(attackerPlanId);

        bytes32[] memory mirrorLeaves = _capabilityTables[address(machine)][attackerPlanId].sortedLeaves;
        bytes32 mirroredLeaf = keccak256(
            abi.encode(SIGNAL_CAPABILITY_LEAF_DOMAIN, STAGE_AUDIT, SOURCE_BOOTSTRAP, SIGNAL_VERIFY_FAIL, uint256(1))
        );
        require(
            _planMetadata(machine)
                .verifySignalCapability(
                    attackerPlanId,
                    STAGE_AUDIT,
                    SOURCE_BOOTSTRAP,
                    SIGNAL_VERIFY_FAIL,
                    1,
                    _merkleProofFor(mirrorLeaves, mirroredLeaf)
                ),
            "mirror capability missing"
        );

        address victimSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, victimPlanId, victimSubmitter, _auths1(SIGNAL_TRIGGER, victimSubmitter), SUBMITTER_PRIVATE_KEY
        );
        bytes32 victimOrderId = ORDER_ID;
        vm.prank(victimSubmitter);
        machine.submitSignal(
            victimPlanId,
            victimOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, victimPlanId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );

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
        bytes memory mirroredSignature =
            _triggerOrderFromSignalSignature(machine, mirrored, noAuthorizations, ATTACKER_SUBMITTER_PRIVATE_KEY);
        IUVPStateMachineCore.FactAttribution[] memory mirroredAttributions = _originFactAttributions(machine, mirrored);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedTriggerOrigin.selector, victimPlanId, victimOrderId, attacker
            )
        );
        _orderLink(machine)
            .triggerOrderFromSignalFor(mirrored, noAuthorizations, mirroredSignature, mirroredAttributions);

        (bool linked,,,,,) = _orderLink(machine).getTriggerOriginLink(attackerPlanId, mirroredOrderId);
        require(!linked, "mirror link was registered");
        require(!machine.orderExists(attackerPlanId, mirroredOrderId), "mirror order minted");

        _submitTriggerOrderFromOutsideWithKey(
            machine, attackerPlanId, attacker, _auths1(SIGNAL_TRIGGER, attacker), ATTACKER_SUBMITTER_PRIVATE_KEY
        );
        bytes32 attackerOrderId = ORDER_ID;
        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest11 = _derivedSignalRequestWithPlans(
            attackerOrderId,
            STAGE_AUDIT,
            attackerPlanId,
            victimOrderId,
            victimPlanId,
            SOURCE_BOOTSTRAP,
            SIGNAL_VERIFY_FAIL,
            PAYLOAD_HASH,
            bytes32(uint256(3))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs11 = _derivedProofs(machine, derivedRequest11);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UVPOrderLinkModule.UnknownOrderTriggerLink.selector, attackerOrderId));
        _derivedSignal(machine).submitDerivedSignal(derivedRequest11, attacker, derivedProofs11);
    }

    function testTriggerLinkOriginConsentPaths() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        address triggerSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);

        _submitTriggerOrderFromOutsideWithKey(
            machine, planId, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, triggerSubmitter), SUBMITTER_PRIVATE_KEY
        );
        vm.prank(triggerSubmitter);
        machine.submitSignal(
            planId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));

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
        _orderLink(machine)
            .triggerOrderFromSignalFor(
                attackerRequest, childAuths, attackerSignature, new IUVPStateMachineCore.FactAttribution[](0)
            );

        bytes memory requestSignature =
            _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        _orderLink(machine)
            .triggerOrderFromSignalFor(
                request, childAuths, requestSignature, new IUVPStateMachineCore.FactAttribution[](0)
            );
        (bool relayerLinked,,,,,) = _orderLink(machine).getTriggerOriginLink(planId, LINKED_ORDER_ID);
        require(relayerLinked, "authorized relayer link missing");

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
            planId,
            secondOriginOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _noAttribution()
        );

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

    function testOrderLinkConsentRequiresAttributionOnVocabularyPlan() public {
        UVPStateMachine machine = _newMachine();
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), _selectorBindings(), _signalCapabilities());
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, _defaultAuthorizations(address(this)));
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_TRIGGER,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
            )
        );
        machine.hasTriggerOriginConsent(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, address(this), _noAttribution()
        );

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));
        bytes memory signature = _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidSignalCapability.selector, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER
            )
        );
        _orderLink(machine)
            .triggerOrderFromSignalFor(request, childAuths, signature, new IUVPStateMachineCore.FactAttribution[](0));
        require(!machine.orderExists(PLAN_ID, LINKED_ORDER_ID), "unproven order link minted");

        _orderLink(machine)
            .triggerOrderFromSignalFor(request, childAuths, signature, _originFactAttributions(machine, request));
        (bool linked,,,,,) = _orderLink(machine).getTriggerOriginLink(PLAN_ID, LINKED_ORDER_ID);
        require(linked, "attributed order link missing");

        UVPStateMachine manual = _newMachine();
        bytes32 manualPlanId = _registerPlan(manual, _withOrderStart(_sequentialPlan()));
        _submitTriggerOrderFromOutside(
            manual, manualPlanId, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, vm.addr(SUBMITTER_PRIVATE_KEY))
        );
        vm.prank(vm.addr(SUBMITTER_PRIVATE_KEY));
        manual.submitSignal(
            manualPlanId, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory manualRequest =
            _signalTriggerRequest(manual, ORDER_ID, bytes32(uint256(2)));
        IUVPStateMachineCore.SignalAuthorization[] memory manualChildAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));
        bytes memory manualSignature =
            _triggerOrderFromSignalSignature(manual, manualRequest, manualChildAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        _orderLink(manual)
            .triggerOrderFromSignalFor(
                manualRequest, manualChildAuths, manualSignature, new IUVPStateMachineCore.FactAttribution[](0)
            );
        (bool manualLinked,,,,,) = _orderLink(manual).getTriggerOriginLink(manualPlanId, LINKED_ORDER_ID);
        require(manualLinked, "zero-vocabulary fallback link missing");
    }

    function testOrderLinkOrderIdMustMatchDerivation() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        address triggerSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, planId, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, triggerSubmitter), SUBMITTER_PRIVATE_KEY
        );
        vm.prank(triggerSubmitter);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

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
        _orderLink(machine)
            .triggerOrderFromSignalFor(request, childAuths, signature, new IUVPStateMachineCore.FactAttribution[](0));
    }

    function testOrderLinkDerivedIdCannotSquatOutsideTriggerNamespace() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _registerPlan(machine, _withOrderStart(_sequentialPlan()));
        address triggerSubmitter = vm.addr(SUBMITTER_PRIVATE_KEY);
        _submitTriggerOrderFromOutsideWithKey(
            machine, planId, ORDER_CREATOR, _auths1(SIGNAL_TRIGGER, triggerSubmitter), SUBMITTER_PRIVATE_KEY
        );
        vm.prank(triggerSubmitter);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );

        bytes32 victimOrderId =
            machine.triggerOrderIdFor(planId, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, bytes32(uint256(0x9999)));
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
        _orderLink(machine)
            .triggerOrderFromSignalFor(request, childAuths, signature, new IUVPStateMachineCore.FactAttribution[](0));
        require(!machine.orderExists(planId, victimOrderId), "victim derived id was squatted");
    }

    function testTriggerLinkConsentCoversEveryConsumedSignalInstruction() public {
        UVPStateMachine machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](3);
        instructions[0] = _signal(SIGNAL_TRIGGER);
        instructions[1] = _signal(SIGNAL_INIT_CMP);
        instructions[2] = _and(2);
        hooks[0] = _hook(
            HOOK_INIT, STAGE_INIT, HOOK_NAME_TRIGGER, true, instructions, _deps2(SIGNAL_TRIGGER, SIGNAL_INIT_CMP)
        );
        bytes32 planId =
            _registerPlan(machine, _withOrderStart(hooks), new StageSelectorBinding[](0), new SignalCapability[](0));

        UVPStateMachine.SignalAuthorization[] memory originAuths = new UVPStateMachine.SignalAuthorization[](2);
        originAuths[0] = _authorization(SIGNAL_ORDER_START, address(this));
        originAuths[1] = _authorization(SIGNAL_TRIGGER, vm.addr(SUBMITTER_PRIVATE_KEY));
        UVPStateMachine.SignalAuthorization[] memory outsideAuths = new UVPStateMachine.SignalAuthorization[](3);
        outsideAuths[0] = originAuths[0];
        outsideAuths[1] = originAuths[1];
        outsideAuths[2] = _authorization(SIGNAL_INIT_CMP, SUBMITTER_A);
        _submitTriggerOrderFromOutsideWithKey(machine, PLAN_ID, ORDER_CREATOR, outsideAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(vm.addr(SUBMITTER_PRIVATE_KEY));
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_TRIGGER, PAYLOAD_HASH, IDEMPOTENCY_KEY, _noAttribution()
        );
        vm.prank(SUBMITTER_A);
        machine.submitSignal(
            PLAN_ID, ORDER_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, PAYLOAD_HASH, bytes32(uint256(0x11)), _noAttribution()
        );

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory request =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(2)));
        IUVPStateMachineCore.SignalAuthorization[] memory childAuths =
            _moduleAuthorizations(_auths1(SIGNAL_TRIGGER, SUBMITTER_A));

        bytes memory signature = _triggerOrderFromSignalSignature(machine, request, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(UNAUTHORIZED_SUBMITTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedTriggerOrigin.selector, planId, ORDER_ID, vm.addr(SUBMITTER_PRIVATE_KEY)
            )
        );
        _orderLink(machine)
            .triggerOrderFromSignalFor(request, childAuths, signature, new IUVPStateMachineCore.FactAttribution[](0));

        IUVPStateMachineCore.TriggerOrderFromSignalRequest memory coveredRequest =
            _signalTriggerRequest(machine, ORDER_ID, bytes32(uint256(3)));
        bytes memory coveredSignature =
            _triggerOrderFromSignalSignature(machine, coveredRequest, childAuths, SUBMITTER_PRIVATE_KEY);
        vm.prank(SUBMITTER_A);
        _orderLink(machine)
            .triggerOrderFromSignalFor(
                coveredRequest, childAuths, coveredSignature, new IUVPStateMachineCore.FactAttribution[](0)
            );
        require(machine.orderExists(planId, LINKED_ORDER_ID), "consent-covered link missing");
    }

    function testStageExecutorPatchForbiddenOnBirthStage() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        patch.targetStageId = STAGE_INIT;
        patch.selectorStageId = STAGE_INIT;
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchForbiddenOnBirthStage.selector, ORDER_ID, STAGE_INIT
            )
        );
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, patch);
    }

    function testStageResourcePatchAllowedOnBirthStage() public {
        UVPStateMachine machine = _newMachine();
        StageSelectorBinding[] memory bindings = new StageSelectorBinding[](2);
        bindings[0] = StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
        bindings[1] = StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_INIT});
        UVPStateMachine.SignalAuthorization[] memory originAuthorizations = new UVPStateMachine.SignalAuthorization[](2);
        originAuthorizations[0] = _stageAuthorization(STAGE_INIT, RESOURCE_PATCH_SIGNAL_ID, address(this));
        originAuthorizations[1] = _authorization(SIGNAL_ORDER_START, address(this));
        SignalCapability[] memory capabilities = new SignalCapability[](1);
        capabilities[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        _registerPlan(machine, _withOrderStart(_sequentialPlan()), bindings, capabilities);
        _submitTriggerOrderFromOutside(machine, PLAN_ID, ORDER_CREATOR, originAuthorizations);

        UVPStagePatchModule.StageResourcePatch memory patch = _stageResourcePatch(1, RESOURCE_PATCH_HASH);
        patch.targetStageId = STAGE_INIT;
        patch.selectorStageId = STAGE_INIT;
        _stagePatch(machine)
            .applyStageResourcePatch(PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, patch.targetStageId));
        (bool exists,,,,,) =
            _stagePatch(machine).getActiveStageResourcePatch(PLAN_ID, ORDER_ID, STAGE_INIT, RESOURCE_KEY);
        require(exists, "birth-stage resource patch missing");
    }

    function testSameSecondDifferentSubmittersFailsClosedOnPreviousExecutor() public {
        address initialExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);
        _activateInitialStageExecutor(machine, vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);

        vm.prank(initialExecutor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(2)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, address(0xcc), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, initialExecutor);
        {
            uint256 deadline = block.timestamp + 1 hours;
            patch.authorizationsHash = _authsHashLocal(
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
            bytes32 digest = _stagePatch(machine)
                .stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, vm.addr(SUBMITTER_PRIVATE_KEY), deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            bytes memory selectorSignature = _packedSignature(v, r, s);
            (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);
            bytes memory previousSignature = _packedSignature(pv, pr, ps);
            vm.prank(UNAUTHORIZED_SUBMITTER);
            _stagePatch(machine)
                .applyStageExecutorPatchFor(
                    PLAN_ID,
                    ORDER_ID,
                    patch,
                    vm.addr(SUBMITTER_PRIVATE_KEY),
                    deadline,
                    selectorSignature,
                    previousSignature,
                    _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                    _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                    _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
                );
        }
        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == address(0xcc),
            "same-second handoff must stay deterministic via active patch executor"
        );
    }

    function testSameSecondFallbackShapeIsClosedAtAssignGate() public {
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
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(0x77)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );

        UVPDerivedSignalModule.DerivedSignalRequest memory derivedRequest12 = _derivedSignalRequestWithPlans(
            ORDER_ID,
            STAGE_AUDIT,
            PLAN_ID,
            ORDER_ID,
            PLAN_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1))
        );
        UVPDerivedSignalModule.DerivedSignalProofs memory derivedProofs12 = _derivedProofs(machine, derivedRequest12);
        vm.prank(SUBMITTER_A);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        _derivedSignal(machine).submitDerivedSignal(derivedRequest12, SUBMITTER_A, derivedProofs12);
    }

    function testDistinctSecondsKeepDeterministicPreviousExecutor() public {
        address initialExecutor = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);
        _activateInitialStageExecutor(machine, vm.addr(SUBMITTER_PRIVATE_KEY), initialExecutor);

        vm.prank(initialExecutor);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(1)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        vm.warp(block.timestamp + 10);
        vm.prank(SUBMITTER_B);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(2)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );

        UVPStagePatchModule.StageExecutorPatch memory patch =
            _stageExecutorPatchWithMode(2, address(0xcc), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, initialExecutor);
        {
            uint256 deadline = block.timestamp + 1 hours;
            patch.authorizationsHash = _authsHashLocal(
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
            );
            bytes32 digest = _stagePatch(machine)
                .stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, vm.addr(SUBMITTER_PRIVATE_KEY), deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            bytes memory selectorSignature = _packedSignature(v, r, s);
            (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);
            bytes memory previousSignature = _packedSignature(pv, pr, ps);
            vm.prank(UNAUTHORIZED_SUBMITTER);
            _stagePatch(machine)
                .applyStageExecutorPatchFor(
                    PLAN_ID,
                    ORDER_ID,
                    patch,
                    vm.addr(SUBMITTER_PRIVATE_KEY),
                    deadline,
                    selectorSignature,
                    previousSignature,
                    _moduleBindingFor(machine, PLAN_ID, patch.targetStageId),
                    _candidateProofFor(machine, PLAN_ID, patch.targetStageId, patch.executor),
                    _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, patch.targetStageId, patch.executor)
                );
        }
        require(
            machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == address(0xcc), "handoff executor missing"
        );
    }

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
            PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY, attribution
        );
    }

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
            PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, PAYLOAD_HASH, IDEMPOTENCY_KEY, attribution
        );
    }

    function testExecutorPatchRotationKeepsPriorExplicitAuthorizations() public {
        address selector = vm.addr(SUBMITTER_PRIVATE_KEY);
        address executorB = vm.addr(WRONG_SUBMITTER_PRIVATE_KEY);
        UVPStateMachine machine = _registeredOverlayMachine(selector, SUBMITTER_A);

        vm.prank(selector);
        _applyExecutorPatch(machine, PLAN_ID, ORDER_ID, _stageExecutorPatch(1, executorB, PATCH_HASH));
        vm.prank(executorB);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9102)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );

        UVPStagePatchModule.StageExecutorPatch memory rotation =
            _stageExecutorPatchWithMode(2, SUBMITTER_A, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, executorB);
        {
            uint256 deadline = block.timestamp + 1 hours;
            rotation.authorizationsHash = _authsHashLocal(
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, rotation.targetStageId, rotation.executor)
            );
            bytes32 digest =
                _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, rotation, selector, deadline);
            (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SUBMITTER_PRIVATE_KEY, digest);
            (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(WRONG_SUBMITTER_PRIVATE_KEY, digest);
            _stagePatch(machine)
                .applyStageExecutorPatchFor(
                    PLAN_ID,
                    ORDER_ID,
                    rotation,
                    selector,
                    deadline,
                    _packedSignature(sv, sr, ss),
                    _packedSignature(pv, pr, ps),
                    _moduleBindingFor(machine, PLAN_ID, rotation.targetStageId),
                    _candidateProofFor(machine, PLAN_ID, rotation.targetStageId, rotation.executor),
                    _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, rotation.targetStageId, rotation.executor)
                );
        }

        vm.prank(executorB);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            IDEMPOTENCY_KEY,
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
    }

    function testStageExecutorPatchRejectsNonCandidateExecutor() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, UNAUTHORIZED_SUBMITTER, PATCH_HASH);
        patch.authorizationsHash = _authsHashLocal(
            _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, UNAUTHORIZED_SUBMITTER)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector,
                PLAN_ID,
                ORDER_ID,
                STAGE_AUDIT,
                UNAUTHORIZED_SUBMITTER
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID,
                ORDER_ID,
                patch,
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, UNAUTHORIZED_SUBMITTER),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, UNAUTHORIZED_SUBMITTER)
            );
    }

    function testStageExecutorPatchRejectedWithoutCandidateSet() public {
        UVPStateMachine machine = _newMachine();
        bytes32 planId = _commitPlanWithoutCandidates(
            machine, _withOrderStart(_patchableSequentialPlan()), _selectorBindings(), _overlaySignalCapabilities()
        );
        machine.finalizePlan(planId);
        _submitTriggerOrderFromOutside(
            machine, planId, ORDER_CREATOR, _overlayAuthorizations(address(this), SUBMITTER_A, SUBMITTER_B)
        );
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_A, PATCH_HASH);
        patch.authorizationsHash = _authsHashLocal(new IUVPStateMachineCore.SignalAuthorization[](0));
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, planId, ORDER_ID, STAGE_AUDIT, SUBMITTER_A
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                planId,
                ORDER_ID,
                patch,
                _moduleBindingFor(machine, planId, STAGE_AUDIT),
                new bytes32[](0),
                new IUVPStateMachineCore.SignalAuthorization[](0)
            );
    }

    function testStageExecutorPatchRejectsCandidateProofForWrongStage() public {
        UVPStateMachine machine = _registeredOverlayMachine(address(this), SUBMITTER_A);
        UVPStagePatchModule.StageExecutorPatch memory patch = _stageExecutorPatch(1, SUBMITTER_B, PATCH_HASH);
        patch.authorizationsHash =
            _authsHashLocal(_executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_B));
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_B
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID,
                ORDER_ID,
                patch,
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_ROLLBACK, SUBMITTER_B),
                _executorAuthorizationsFor(machine, PLAN_ID, ORDER_ID, STAGE_AUDIT, SUBMITTER_B)
            );
    }
}

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

    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x7001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
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
            UVPPlanMetadataModule(_lastMetadata)
                .verifySignalCapability(
                    planId, bytes32(uint256(0x22)), bytes32(uint256(0x8000) + 399), bytes32(uint256(0x4005)), 0, proof
                ),
            "deep leaf must verify"
        );
    }

    function _minimalHook() private pure returns (UVPStateMachine.CompactHook memory) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: 0, sourceId: bytes32(uint256(0x3001)), signalId: bytes32(uint256(0x4000)), arity: 0, delaySeconds: 0
        });
        bytes32[] memory dependencyKeys = new bytes32[](1);
        dependencyKeys[0] = keccak256(abi.encode(bytes32(uint256(0x3001)), bytes32(uint256(0x4000))));
        return UVPStateMachine.CompactHook({
            hookId: bytes32(uint256(0x6001)),
            stageId: bytes32(uint256(0x11)),
            hookName: bytes32("hook"),
            flags: 4,
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
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
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
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256("UVPStateMachine"),
                        keccak256("0.15"),
                        block.chainid,
                        address(machine)
                    )
                ),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        planId = machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), signature);
    }

    function _deployModules(UVPStateMachine machine)
        private
        returns (UVPStagePatchModule stagePatch, address metadata)
    {
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
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
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
        address submitter,
        UVPStateMachine.FactAttribution memory attribution
    ) external {
        UVPStateMachine.DockInputFact memory fact = UVPStateMachine.DockInputFact({
            planId: planId,
            orderId: orderId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: bytes32(uint256(0xA001)),
            idempotencyKey: idempotencyKey,
            submitter: submitter,
            attribution: attribution
        });
        _machine.recordDockedInputFromModule(fact);
    }
}

