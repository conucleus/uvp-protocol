// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";
import {ECDSA} from "../src/libraries/ECDSA.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";

interface DockVm {
    struct NoArgs {
        uint256 placeholder;
    }

    function addr(uint256 privateKey) external returns (address keyAddr);
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function store(address account, bytes32 slot, bytes32 value) external;
    function warp(uint256 newTimestamp) external;
}

contract UVPDockingModuleTest {
    DockVm private constant vm = DockVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition) internal pure {
        if (!condition) {
            revert("assertTrue failed");
        }
    }

    function assertFalse(bool condition) internal pure {
        if (condition) {
            revert("assertFalse failed");
        }
    }

    function assertEq(bytes32 left, bytes32 right) internal pure {
        if (left != right) {
            revert("assertEq(bytes32) failed");
        }
    }

    function assertEq(uint256 left, uint256 right) internal pure {
        if (left != right) {
            revert("assertEq(uint256) failed");
        }
    }

    function _expect(bytes memory data) internal {
        vm.expectRevert(data);
    }
    uint8 private constant FLAG_MINT = 1;
    uint8 private constant FLAG_DOCK = 2;
    uint8 private constant FLAG_EMIT_READY = 4;

    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant TRIGGER_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

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
    bytes32 private constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant PARENT_START_HOOK = keccak256("start#START");
    bytes32 private constant PARENT_STAGE = keccak256("start");
    bytes32 private constant PARENT_EXEC_HOOK = keccak256("exec#EXECUTE");
    bytes32 private constant PARENT_EXEC_STAGE = keccak256("exec");
    bytes32 private constant SIGNAL_START = keccak256("start");
    bytes32 private constant SIGNAL_EXEC = keccak256("exec");
    bytes32 private constant SIGNAL_SIBLING = keccak256("sibling");

    bytes32 private constant TARGET_UID_ID = keccak256("zx-a11ce00c0ffee0ddba5e5eed1c0deb0a");
    bytes32 private constant INTERFACE_NAME_ID = keccak256("production");

    bytes32 private constant TARGET_ENTRANCE_HOOK = keccak256("init#DOCK_EXECUTE");
    bytes32 private constant TARGET_MINT_HOOK = keccak256("init#MINT");
    bytes32 private constant TARGET_STAGE = keccak256("init");
    bytes32 private constant TARGET_HOOK_NAME = keccak256("DOCK_EXECUTE");
    bytes32 private constant TARGET_SOURCE = keccak256("payment");
    bytes32 private constant TARGET_SIGNAL = keccak256("init.execute");
    bytes32 private constant TARGET_INTAKE_SOURCE = keccak256("supply");
    bytes32 private constant TARGET_INTAKE_SIGNAL = keccak256("intake.demand_accepted");
    bytes32 private constant TARGET_OUT_SOURCE = keccak256("payment");
    bytes32 private constant TARGET_OUT_SIGNAL = keccak256("init.done");
    bytes32 private constant TARGET_OUT_STAGE = keccak256("out");
    bytes32 private constant LOCAL_MAPPED_SOURCE = keccak256("buyer");
    bytes32 private constant LOCAL_MAPPED_SIGNAL = keccak256("exec.str");
    bytes32 private constant LOCAL_PROGRESS_SOURCE = keccak256("buyer");
    bytes32 private constant LOCAL_PROGRESS_SIGNAL = keccak256("exec.progress");
    bytes32 private constant TARGET_PENDING_SIGNAL = keccak256("control.settle");

    bytes32 private constant ENTRANCE_PORT = keccak256("execute");
    bytes32 private constant DONE_PORT = keccak256("done");
    bytes32 private constant PROGRESS_OUT_PORT = keccak256("progress");
    bytes32 private constant SETTLE_PORT = keccak256("settle");
    bytes32 private constant ROGUE_PORT = keccak256("rogue_port");
    bytes32 private constant ROGUE_FACT_SOURCE = keccak256("source");
    bytes32 private constant ROGUE_FACT_SIGNAL = keccak256("signal");
    bytes32 private constant PARENT_SIBLING_HOOK = keccak256("exec#SIBLING");
    bytes32 private constant PAYLOAD = bytes32(uint256(0xBEEF));

    uint256 private constant PARENT_PUBLISHER_KEY = 0xA11CE;
    uint256 private constant SUBMITTER_KEY = 0x51;
    uint256 private constant TARGET_PUBLISHER_KEY = 0xB0B;
    address private constant ORDER_CREATOR = address(0xC0C0);
    address private constant KEEPER = address(0x5EED1);
    bytes32 private PARENT_ORDER_ID;

    UVPStateMachine private machine;
    UVPDockingModule private docking;
    bytes32 private localDefinitionRef = keccak256("parent-definition-ref");
    bytes32 private targetDefinitionRef = keccak256(abi.encode(DOMAIN_DEFINITION_REF, TARGET_UID_ID));

    bytes32 private parentPlanId;
    bytes32 private targetPlanId;
    bytes32 private runtimeDomain;

    bytes32 private routeId;
    bytes32 private entranceBinding;
    bytes32 private outputBinding;
    bytes32 private progressOutBinding;
    bytes32 private settleBinding;
    bytes32 private inputsRoot;
    bytes32 private outputsRoot;
    bytes32 private openRouteHash;
    bytes32 private existingRouteHash;
    bytes32 private dockInstanceId;
    bytes32 private linkedOrderId;
    bytes32 private openPortLeaf;
    bytes32 private interfaceLeaf;
    bytes32 private interfaceOutputsRoot;
    bytes32 private donePortLeaf;
    bytes32 private progressPortLeaf;
    bytes32 private settlePortLeaf;
    bytes32[] private donePortProof;
    bytes32[] private progressPortProof;
    bytes32[] private settlePortProof;

    function setUp() public {
        machine = _newMachine();
        docking = _docking();
        runtimeDomain = keccak256(abi.encode(DOMAIN_RUNTIME_EIP155, block.chainid, address(machine)));
        _computeStaticRouteParts();
        targetPlanId = _registerTargetPlan();
        _computeRouteHashes();
        parentPlanId = _registerParentPlan();
        PARENT_ORDER_ID = machine.triggerOrderIdFor(parentPlanId, PARENT_STAGE, SIGNAL_START, PAYLOAD);
        _rebindDockInstanceId();
        _spawnParentOrder();
    }

    function testOpenCreatesIndependentChildAtomically() public {
        assertTrue(_open());
        (, bytes32 localOrder,,,,,, bytes32 viewedInterfaceName,, bool exists) = docking.getActiveDock(dockInstanceId);
        assertTrue(exists);
        assertEq(localOrder, PARENT_ORDER_ID);
        assertEq(viewedInterfaceName, INTERFACE_NAME_ID);
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
        assertFalse(linkedOrderId == PARENT_ORDER_ID);
        (bool signalExists,,,,) = machine.getSignal(targetPlanId, linkedOrderId, TARGET_SOURCE, TARGET_SIGNAL);
        assertTrue(signalExists);
        UVPStateMachine.HookStatus status;
        bool readyEmitted;
        (status,, readyEmitted) = machine.getHookStatus(targetPlanId, linkedOrderId, TARGET_ENTRANCE_HOOK);
        assertEq(uint256(status), uint256(UVPStateMachine.HookStatus.Ready));
        assertTrue(readyEmitted);
    }

    function testTargetPublisherAuthorizesDockedOrderSignals() public {
        assertTrue(_open());
        address publisher = vm.addr(TARGET_PUBLISHER_KEY);
        address executor = address(0xE7EC);
        UVPStateMachine.SignalAuthorization[] memory machineAuths = new UVPStateMachine.SignalAuthorization[](1);
        machineAuths[0] = _auth(TARGET_INTAKE_SOURCE, TARGET_INTAKE_SIGNAL, executor);
        IUVPStateMachineCore.SignalAuthorization[] memory authorizations =
            new IUVPStateMachineCore.SignalAuthorization[](1);
        authorizations[0] = _coreAuth(TARGET_INTAKE_SOURCE, TARGET_INTAKE_SIGNAL, executor);
        bytes32 authorizationHash = machine.signalAuthorizationsHash(machineAuths);

        vm.expectEmit(true, true, true, true, address(docking));
        emit UVPDockingModule.DockOrderSignalsAuthorized(
            dockInstanceId, targetPlanId, linkedOrderId, 1, authorizationHash
        );
        vm.prank(publisher);
        docking.authorizeDockedOrderSignals(dockInstanceId, authorizations);

        assertTrue(
            machine.hasExplicitSignalAuthorization(
                targetPlanId, linkedOrderId, TARGET_INTAKE_SOURCE, TARGET_INTAKE_SIGNAL, executor
            )
        );
        vm.prank(executor);
        machine.submitSignal(
            targetPlanId,
            linkedOrderId,
            TARGET_INTAKE_SOURCE,
            TARGET_INTAKE_SIGNAL,
            PAYLOAD,
            keccak256("intake.demand_accepted"),
            _factAttributionFor(targetPlanId, TARGET_INTAKE_SOURCE, TARGET_INTAKE_SIGNAL)
        );
        (bool exists,,,,) = machine.getSignal(targetPlanId, linkedOrderId, TARGET_INTAKE_SOURCE, TARGET_INTAKE_SIGNAL);
        assertTrue(exists);

        _expect(
            abi.encodeWithSelector(
                UVPStateMachine.SignalSubmitterAlreadyAuthorized.selector,
                linkedOrderId,
                TARGET_INTAKE_SOURCE,
                TARGET_INTAKE_SIGNAL,
                executor
            )
        );
        vm.prank(publisher);
        docking.authorizeDockedOrderSignals(dockInstanceId, authorizations);
    }

    function testAuthorizeDockedOrderSignalsRejectsNonPublisher() public {
        assertTrue(_open());
        IUVPStateMachineCore.SignalAuthorization[] memory authorizations =
            new IUVPStateMachineCore.SignalAuthorization[](1);
        authorizations[0] = _coreAuth(TARGET_INTAKE_SOURCE, TARGET_INTAKE_SIGNAL, address(0xE7EC));
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.UnauthorizedDockSignalsAuthorizer.selector,
                KEEPER,
                vm.addr(TARGET_PUBLISHER_KEY)
            )
        );
        vm.prank(KEEPER);
        docking.authorizeDockedOrderSignals(dockInstanceId, authorizations);
    }

    function testOpenEmitsDockOpenedAndEntranceInputSubmitted() public {
        vm.expectEmit(true, true, true, true, address(docking));
        emit UVPDockingModule.DockOpened(
            dockInstanceId,
            PARENT_ORDER_ID,
            linkedOrderId,
            INTERFACE_NAME_ID,
            parentPlanId,
            targetPlanId,
            routeId,
            openRouteHash,
            1,
            address(this)
        );
        vm.expectEmit(true, true, true, false, address(docking));
        emit UVPDockingModule.DockInputSubmitted(
            dockInstanceId,
            linkedOrderId,
            entranceBinding,
            parentPlanId,
            PARENT_ORDER_ID,
            targetPlanId,
            TARGET_SIGNAL,
            bytes32(0),
            address(0)
        );
        assertTrue(_open());
    }

    function testOpenRejectsMissingTargetConsent() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockOpenConsentRequired.selector, request.dockInstanceId, address(this)
            )
        );
        docking.openDockedOrder(
            _openCall(
                request,
                _openRouteProof(),
                _interfaceProof(),
                _inputs(),
                _outputs(),
                _openAuth(_permitEmpty(), _consentEmpty()),
                _outputAttributionsFor(targetPlanId, _outputs()),
                _coreEntranceFactAttribution()
            )
        );
    }

    function testOpenRejectsWrongConsentSigner() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        UVPDockingModule.DockTargetConsentV1 memory consent = _consentFor(request);
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(PARENT_PUBLISHER_KEY, _consentDigestFor(request, consent));
        consent.signature = abi.encodePacked(r, sv, v);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockPermitInvalidSigner.selector,
                vm.addr(TARGET_PUBLISHER_KEY),
                vm.addr(PARENT_PUBLISHER_KEY)
            )
        );
        docking.openDockedOrder(
            _openCall(
                request,
                _openRouteProof(),
                _interfaceProof(),
                _inputs(),
                _outputs(),
                _openAuth(_permitEmpty(), consent),
                _outputAttributionsFor(targetPlanId, _outputs()),
                _coreEntranceFactAttribution()
            )
        );
    }

    function testOpenAllowsPublisherAsOpenerWithoutSignature() public {
        vm.prank(vm.addr(TARGET_PUBLISHER_KEY));
        assertTrue(
            docking.openDockedOrder(
                _openCall(
                    _openRequest(0),
                    _openRouteProof(),
                    _interfaceProof(),
                    _inputs(),
                    _outputs(),
                    _openAuth(_permitEmpty(), _consentEmpty()),
                    _outputAttributionsFor(targetPlanId, _outputs()),
                    _coreEntranceFactAttribution()
                )
            )
        );
    }

    function testOpenRejectsMirrorPlanDespiteConsent() public {
        bytes32 variantPlan = _registerTargetPlanWithoutPendingCapability();
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _outputs();
        RogueRoute memory route = _registerRogueRouteParentTo(
            targetPlanId, PARENT_EXEC_HOOK, TARGET_SOURCE, TARGET_SIGNAL, outputs
        );
        UVPDockingModule.OpenDockRequestV2 memory request = _rogueOpenRequestTo(route, variantPlan);
        bytes32[] memory outputLeaves = new bytes32[](outputs.length);
        for (uint256 i = 0; i < outputs.length; i++) {
            outputLeaves[i] = outputs[i].bindingHash;
        }
        bytes32 recomputed = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                variantPlan,
                INTERFACE_NAME_ID,
                uint256(0),
                DockMerkle.root(_single(route.entranceBindingHash)),
                DockMerkle.root(outputLeaves)
            )
        );
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, route.routeHash, recomputed)
        );
        docking.openDockedOrder(
            _openCall(
                request,
                route.routeProof,
                _interfaceProof(),
                _rogueInputs(route),
                outputs,
                _openAuth(_permitEmpty(), _consentFor(request)),
                _outputAttributionsFor(variantPlan, outputs),
                _coreEntranceFactAttribution()
            )
        );
    }

    function testRejectsOpenAtMaxDockEdges() public {
        uint8 maxEdges = docking.MAX_DOCK_EDGES();
        bytes32 innerSlot = keccak256(abi.encode(parentPlanId, uint256(7)));
        bytes32 edgeSlot = keccak256(abi.encode(PARENT_ORDER_ID, innerSlot));
        vm.store(address(docking), edgeSlot, bytes32(uint256(uint256(maxEdges))));
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthExceeded.selector, maxEdges, maxEdges));
        _openRaw(_openRequest(maxEdges));
    }

    function testLinkedOrderNamespaceCannotBeSquatted() public {
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(TARGET_OUT_SIGNAL);
        trigger.planId = targetPlanId;
        trigger.creator = vm.addr(TARGET_PUBLISHER_KEY);
        trigger.triggerHookId = TARGET_MINT_HOOK;
        trigger.triggerStageId = TARGET_STAGE;
        trigger.sourceId = TARGET_OUT_SOURCE;
        trigger.idempotencyKey = keccak256("squat-attempt");

        bytes32 mintedOrderId =
            machine.triggerOrderIdFor(targetPlanId, TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL, trigger.payloadHash);
        assertFalse(mintedOrderId == linkedOrderId);

        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](1);
        auths[0] = _auth(TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL, trigger.submitter);
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)), _birthAttribution(trigger)
        );
        assertTrue(machine.orderExists(targetPlanId, mintedOrderId));
        assertFalse(machine.orderExists(targetPlanId, linkedOrderId));

        _expect(abi.encodeWithSelector(UVPStateMachine.OrderAlreadyRegistered.selector));
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)), _birthAttribution(trigger)
        );

        assertTrue(_open());
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
    }

    function testOpenIsIdempotentForSameInstance() public {
        assertTrue(_open());
        assertFalse(_open());
        bytes32 key = keccak256(abi.encode(targetPlanId, linkedOrderId));
        assertEq(docking.dockByTargetOrder(key), dockInstanceId);
    }

    function testOpenMarksEntranceInputDelivered() public {
        assertTrue(_open());
        assertTrue(docking.dockInputDelivered(dockInstanceId, entranceBinding));
        assertFalse(
            docking.submitDockedInput(dockInstanceId, PARENT_EXEC_HOOK, entranceBinding, _coreEntranceFactAttribution())
        );
    }

    function testSubmitDockedInputRejectsUnknownBinding() public {
        assertTrue(_open());
        vm.expectRevert(
            abi.encodeWithSelector(UVPDockingModule.DockInputNotFound.selector, dockInstanceId, bytes32(uint256(0xBAD)))
        );
        docking.submitDockedInput(dockInstanceId, PARENT_EXEC_HOOK, bytes32(uint256(0xBAD)), _coreNoAttribution());
    }

    function testPermissionlessCallbackWritesParentMappedFact() public {
        assertTrue(_open());
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, outputBinding, _coreNoAttribution()));
        (bool mapped,,,,) = machine.getSignal(parentPlanId, PARENT_ORDER_ID, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        assertTrue(mapped);
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(dockInstanceId, outputBinding, _coreNoAttribution()));
    }

    function testOutputDeliveriesArePerBindingIdempotentWithoutTerminalGate() public {
        assertTrue(_open());
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, outputBinding, _coreNoAttribution()));
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(dockInstanceId, outputBinding, _coreNoAttribution()));
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, progressOutBinding, _coreNoAttribution()));
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(dockInstanceId, progressOutBinding, _coreNoAttribution()));
        (bool mappedDone,,,,) =
            machine.getSignal(parentPlanId, PARENT_ORDER_ID, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        (bool mappedProgress,,,,) =
            machine.getSignal(parentPlanId, PARENT_ORDER_ID, LOCAL_PROGRESS_SOURCE, LOCAL_PROGRESS_SIGNAL);
        assertTrue(mappedDone);
        assertTrue(mappedProgress);
    }

    function testCallbackBeforeTargetFactReverts() public {
        assertTrue(_open());
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockOutputNotReady.selector, dockInstanceId, settleBinding));
        docking.submitDockedSignal(dockInstanceId, settleBinding, _coreNoAttribution());
    }

    function testSiblingOutputBindingOnSameLocalKeyIsAbsorbed() public {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = new UVPDockingModule.DockOutputBindingArg[](2);
        bytes32 doneBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                DONE_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        bytes32 progressBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                PROGRESS_OUT_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: DONE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: doneBinding,
            portProof: donePortProof
        });
        outputs[1] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: PROGRESS_OUT_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: progressBinding,
            portProof: progressPortProof
        });
        RogueRoute memory route = _registerRogueRouteParent(PARENT_EXEC_HOOK, TARGET_SOURCE, TARGET_SIGNAL, outputs);

        assertTrue(
            docking.openDockedOrder(
                _openCall(
                    _rogueOpenRequest(route),
                    route.routeProof,
                    _interfaceProof(),
                    _rogueInputs(route),
                    outputs,
                    _openAuth(_permitEmpty(), _consentFor(_rogueOpenRequest(route))),
                    _outputAttributionsFor(targetPlanId, outputs),
                    _coreEntranceFactAttribution()
                )
            )
        );

        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(route.dockInstanceId, doneBinding, _coreNoAttribution()));
        (, bytes32 targetPayload,,, address targetFactSubmitter) =
            machine.getSignal(targetPlanId, route.linkedOrderId, TARGET_SOURCE, TARGET_SIGNAL);
        vm.prank(KEEPER);
        vm.expectEmit(true, true, true, true, address(docking));
        emit UVPDockingModule.DockOutputSatisfied(
            route.dockInstanceId,
            route.linkedOrderId,
            progressBinding,
            route.planId,
            route.orderId,
            targetPlanId,
            TARGET_SIGNAL,
            LOCAL_MAPPED_SIGNAL,
            targetPayload,
            targetFactSubmitter
        );
        assertTrue(docking.submitDockedSignal(route.dockInstanceId, progressBinding, _coreNoAttribution()));
        assertTrue(docking.dockOutputDelivered(route.dockInstanceId, progressBinding));
        assertTrue(docking.dockOutputDelivered(route.dockInstanceId, doneBinding));
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(route.dockInstanceId, progressBinding, _coreNoAttribution()));
        (bool mapped,,,,) = machine.getSignal(route.planId, route.orderId, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        assertTrue(mapped);
    }

    function testRejectsWrongRouteProof() public {
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(0xBAD));
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, openRouteHash, bytes32(0)));
        _openWith(badProof, _interfaceProof());
    }

    function testRejectsTamperedInterfaceNameInBindings() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        request.interfaceNameId = keccak256("other_interface");
        bytes32 recomputedEntrance = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                routeId,
                request.interfaceNameId,
                PARENT_EXEC_HOOK,
                ENTRANCE_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, entranceBinding, recomputedEntrance)
        );
        _openRaw(request);
    }

    function testRejectsSelfHashedOutputTamper() public {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _outputs();
        outputs[0].localSignalId = TARGET_PENDING_SIGNAL;
        outputs[0].bindingHash = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                outputs[0].localSourceId,
                outputs[0].localSignalId,
                outputs[0].portKey,
                outputs[0].targetSourceId,
                outputs[0].targetSignalId
            )
        );
        bytes32[] memory outputLeaves = new bytes32[](3);
        outputLeaves[0] = outputs[0].bindingHash;
        outputLeaves[1] = outputs[1].bindingHash;
        outputLeaves[2] = outputs[2].bindingHash;
        bytes32 tamperedRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                targetPlanId,
                INTERFACE_NAME_ID,
                uint256(0),
                inputsRoot,
                DockMerkle.root(outputLeaves)
            )
        );
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, openRouteHash, tamperedRouteHash)
        );
        docking.openDockedOrder(
            _openCall(
                _openRequest(0),
                _openRouteProof(),
                _interfaceProof(),
                _inputs(),
                outputs,
                _openAuth(_permitEmpty(), _consentFor(_openRequest(0))),
                _outputAttributionsFor(targetPlanId, outputs),
                _coreNoAttribution()
            )
        );
    }

    function testRejectsExistingModeRoute() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        request.routeHash = existingRouteHash;
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector,
                existingRouteHash,
                openRouteHash)
        );
        _openRawWithProof(request, _existingRouteProof());
    }

    function testRejectsTamperedChildId() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        request.linkedOrderId = bytes32(uint256(0xE711));
        bytes32 recomputedLinked = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockRouteLeafMismatch.selector,
                bytes32(uint256(0xE711)),
                recomputedLinked
            )
        );
        _openRaw(request);
    }

    function testRejectsTargetIdentityMismatch() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        bytes32 rogueUid = keccak256("zx-0000000000000000000000000000dead");
        request.targetUidId = rogueUid;
        bytes32 derivedFromRogue = keccak256(abi.encode(DOMAIN_DEFINITION_REF,
                rogueUid));
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockTargetIdentityMismatch.selector,
                targetDefinitionRef,
                derivedFromRogue
            )
        );
        _openRaw(request);
    }

    function testRejectsInterfaceWithoutNewMode() public {
        UVPDockingModule.DockInterfaceProofV2 memory proof = _interfaceProof();
        proof.commitment.orderModesWord = 2;
        _expect(abi.encodeWithSelector(UVPDockingModule.DockInterfaceModeUnsupported.selector,
                2));
        _openWith(_openRouteProof(), proof);
    }

    function testRejectsMultipleInputBindings() public {
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](2);
        inputs[0] = _inputs()[0];
        inputs[1] = inputs[0];
        _expect(abi.encodeWithSelector(UVPDockingModule.DockBindingCountInvalid.selector,
                2,
                1));
        docking.openDockedOrder(
            _openCall(
                _openRequest(0),
                _openRouteProof(),
                _interfaceProof(),
                inputs,
                _outputs(),
                _openAuth(_permitEmpty(), _consentFor(_openRequest(0))),
                _outputAttributionsFor(targetPlanId, _outputs()),
                _coreEntranceFactAttribution()
            )
        );
    }

    function testRejectsEntrancePortLeafMismatch() public {
        UVPDockingModule.DockInterfacePortLeafV2 memory leaf = _openLeafData();
        leaf.hookKey = keccak256("init#OTHER_HOOK");
        bytes32 recomputedLeaf =
            keccak256(abi.encode(DOMAIN_INTERFACE_INPUT, TARGET_UID_ID, INTERFACE_NAME_ID, leaf.portKey, leaf.hookKey));
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockInterfaceLeafMismatch.selector, openPortLeaf, recomputedLeaf)
        );
        UVPDockingModule.DockInterfaceProofV2 memory proof = _interfaceProof();
        proof.entranceLeaf = leaf;
        _openWith(_openRouteProof(),
                proof);
    }

    function testRejectsDepthBeyondLimit() public {
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthMismatch.selector, 8, 0));
        _openRaw(_openRequest(8));
    }

    function testRejectsParentDepthMismatch() public {
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthMismatch.selector, 3, 0));
        _openRaw(_openRequest(3));
    }

    function testRejectsSecondChildForSameRouteInstance() public {
        assertTrue(_open());
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        request.dockInstanceId = bytes32(uint256(0x0DD0));
        bytes32 runtimeDomainLocal = keccak256(abi.encode(DOMAIN_RUNTIME_EIP155, block.chainid, address(machine)));
        bytes32 recomputedInstance = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomainLocal,
                parentPlanId,
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                openRouteHash,
                uint256(0),
                INTERFACE_NAME_ID,
                targetPlanId
            )
        );
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockRouteLeafMismatch.selector, bytes32(uint256(0x0DD0)), recomputedInstance
            )
        );
        _openRaw(request);
    }

    function testOpenRejectsEntranceHookImpersonation() public {
        RogueRoute memory route =
            _registerRogueRouteParent(PARENT_SIBLING_HOOK,
                TARGET_SOURCE,
                TARGET_SIGNAL,
                _outputs());
        UVPDockingModule.OpenDockRequestV2 memory request = _rogueOpenRequest(route);
        request.localHookId = PARENT_EXEC_HOOK;
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](1);
        inputs[0] = UVPDockingModule.DockInputBindingArg({
            localHookId: PARENT_SIBLING_HOOK,
                portKey: ENTRANCE_PORT,
                targetSourceId: TARGET_SOURCE,
                targetSignalId: TARGET_SIGNAL,
                bindingHash: route.entranceBindingHash
        });
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockHookNotInputBound.selector, route.planId, route.orderId, PARENT_EXEC_HOOK
            )
        );
        docking.openDockedOrder(
            _openCall(
                request,
                route.routeProof,
                _interfaceProof(),
                inputs,
                _outputs(),
                _openAuth(_permitEmpty(), _consentFor(request)),
                _outputAttributionsFor(targetPlanId, _outputs()),
                _coreEntranceFactAttribution()
            )
        );
    }

    function testOpenRejectsEntranceFactNotDeclaredByTargetHook() public {
        RogueRoute memory route =
            _registerRogueRouteParent(PARENT_EXEC_HOOK, TARGET_SOURCE, TARGET_PENDING_SIGNAL, _outputs());
        UVPDockingModule.OpenDockRequestV2 memory request = _rogueOpenRequest(route);
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](1);
        inputs[0] = UVPDockingModule.DockInputBindingArg({
            localHookId: PARENT_EXEC_HOOK,
            portKey: ENTRANCE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_PENDING_SIGNAL,
            bindingHash: route.entranceBindingHash
        });
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockEntranceFactNotDeclared.selector,
                TARGET_ENTRANCE_HOOK,
                TARGET_SOURCE,
                TARGET_PENDING_SIGNAL
            )
        );
        docking.openDockedOrder(
            _openCall(
                request,
                route.routeProof,
                _interfaceProof(),
                inputs,
                _outputs(),
                _openAuth(_permitEmpty(), _consentFor(request)),
                _outputAttributionsFor(targetPlanId, _outputs()),
                _coreEntranceFactAttribution()
            )
        );
    }

    function testOpenRejectsUndeclaredOutputPort() public {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _outputs();
        outputs[2].portKey = ROGUE_PORT;
        outputs[2].bindingHash = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                outputs[2].localSourceId,
                outputs[2].localSignalId,
                ROGUE_PORT,
                outputs[2].targetSourceId,
                outputs[2].targetSignalId
            )
        );
        RogueRoute memory route = _registerRogueRouteParent(PARENT_EXEC_HOOK, TARGET_SOURCE, TARGET_SIGNAL, outputs);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockInterfaceLeafMismatch.selector,
                _outputPortLeaf(ROGUE_PORT, TARGET_SOURCE, TARGET_PENDING_SIGNAL),
                interfaceOutputsRoot
            )
        );
        docking.openDockedOrder(
            _openCall(
                _rogueOpenRequest(route),
                route.routeProof,
                _interfaceProof(),
                _rogueInputs(route),
                outputs,
                _openAuth(_permitEmpty(), _consentFor(_rogueOpenRequest(route))),
                _outputAttributionsFor(targetPlanId, outputs),
                _coreNoAttribution()
            )
        );
    }

    function testOpenRejectsOutputFactNotDeclaredByTargetPlan() public {
        bytes32 variantPlan = _registerTargetPlanWithoutPendingCapability();
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _outputs();
        RogueRoute memory route =
            _registerRogueRouteParentTo(variantPlan, PARENT_EXEC_HOOK, TARGET_SOURCE, TARGET_SIGNAL, outputs);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockOutputFactNotDeclared.selector, variantPlan, TARGET_SOURCE, TARGET_PENDING_SIGNAL
            )
        );
        docking.openDockedOrder(
            _openCall(
                _rogueOpenRequestTo(route, variantPlan),
                route.routeProof,
                _interfaceProof(),
                _rogueInputs(route),
                outputs,
                _openAuth(_permitEmpty(), _consentFor(_rogueOpenRequestTo(route, variantPlan))),
                _outputAttributionsFor(variantPlan, outputs),
                _coreNoAttribution()
            )
        );
    }

    function testOpenRejectsOutputBoundToDifferentDeclaredFact() public {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _outputs();
        outputs[0].targetSignalId = TARGET_PENDING_SIGNAL;
        outputs[0].bindingHash = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                outputs[0].localSourceId,
                outputs[0].localSignalId,
                outputs[0].portKey,
                outputs[0].targetSourceId,
                outputs[0].targetSignalId
            )
        );
        RogueRoute memory route = _registerRogueRouteParent(PARENT_EXEC_HOOK, TARGET_SOURCE, TARGET_SIGNAL, outputs);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockInterfaceLeafMismatch.selector,
                _outputPortLeaf(DONE_PORT, TARGET_SOURCE, TARGET_PENDING_SIGNAL),
                interfaceOutputsRoot
            )
        );
        docking.openDockedOrder(
            _openCall(
                _rogueOpenRequest(route),
                route.routeProof,
                _interfaceProof(),
                _rogueInputs(route),
                outputs,
                _openAuth(_permitEmpty(), _consentFor(_rogueOpenRequest(route))),
                _outputAttributionsFor(targetPlanId, outputs),
                _coreNoAttribution()
            )
        );
    }

    function testSubmitDockedSignalRecordsParentCreatorAsParentFactSubmitter() public {
        assertTrue(_open());
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, outputBinding, _coreNoAttribution()));
        (,,,, address parentFactSubmitter) =
            machine.getSignal(parentPlanId, PARENT_ORDER_ID, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        require(parentFactSubmitter == ORDER_CREATOR, "mirrored fact must be booked to the parent order creator");
        require(
            machine.lastSignalSubmitter(parentPlanId, PARENT_ORDER_ID, LOCAL_MAPPED_SOURCE) == ORDER_CREATOR,
            "parent lastSignalSubmitter must stay on the parent consent chain"
        );
        require(
            parentFactSubmitter != machine.lastSignalSubmitter(targetPlanId, linkedOrderId, TARGET_SOURCE),
            "child-side submitter must not leak into the parent bookkeeping"
        );
    }

    function testOpenRecordsPublisherAsEntranceFactSubmitter() public {
        assertTrue(_open());
        (,,,, address entranceSubmitter) = machine.getSignal(targetPlanId, linkedOrderId, TARGET_SOURCE, TARGET_SIGNAL);
        assertTrue(entranceSubmitter == vm.addr(TARGET_PUBLISHER_KEY));
    }

    function testPermitRejectsRawVValue() public {
        UVPDockingModule.EntrancePermitV2 memory permit = _permitSigned(1);
        permit.signature[64] = bytes1(uint8(0));
        _expect(abi.encodeWithSelector(ECDSA.InvalidSignatureV.selector, uint8(0)));
        _openWithPermit(_interfaceProof(), permit);
    }

    function testPermitHappyPath() public {
        UVPDockingModule.EntrancePermitV2 memory permit = _permitSigned(1);
        assertTrue(_openWithPermit(_interfaceProof(), permit));
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
        assertEq(docking.usedEntrancePermitNonce(dockInstanceId), 1);
    }

    function testPermitDigestMatchesEip712Formula() public {
        bytes32 digest = docking.entrancePermitDigest(
            targetPlanId,
            ENTRANCE_PORT,
            INTERFACE_NAME_ID,
            parentPlanId,
            openRouteHash,
            dockInstanceId,
            linkedOrderId,
            1,
            2000000000
        );
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                targetPlanId,
                ENTRANCE_PORT,
                INTERFACE_NAME_ID,
                parentPlanId,
                openRouteHash,
                dockInstanceId,
                linkedOrderId,
                uint256(0),
                uint256(1),
                uint256(2000000000)
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("UVPDockingModule"),
                keccak256("4"),
                block.chainid,
                address(docking)
            )
        );
        assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    }

    function testPermitReplayReturnsFalseAfterDockExists() public {
        UVPDockingModule.EntrancePermitV2 memory permit = _permitSigned(1);
        assertTrue(_openWithPermit(_interfaceProof(), permit));

        assertFalse(_openWithPermit(_interfaceProof(), permit));
        assertEq(docking.usedEntrancePermitNonce(dockInstanceId), 1);
    }

    function testPermitWrongSignerRejected() public {
        UVPDockingModule.EntrancePermitV2 memory permit = _permitSigned(1);
        bytes32 digest = _permitDigestOnModule(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        permit.signature = abi.encodePacked(r, s, v);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockPermitInvalidSigner.selector, vm.addr(TARGET_PUBLISHER_KEY), vm.addr(0xDEAD)
            )
        );
        _openWithPermit(_interfaceProof(), permit);
    }

    function testPermitExpiredRejected() public {
        UVPDockingModule.EntrancePermitV2 memory permit = _permitSigned(1);
        vm.warp(block.timestamp + 2 hours);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockPermitExpired.selector, permit.deadline));
        _openWithPermit(_interfaceProof(), permit);
    }

    function testCrossPlanBareOrderIdCollisionIsolated() public {
        assertTrue(_open());
        assertTrue(machine.orderExists(parentPlanId, PARENT_ORDER_ID));
        assertFalse(machine.orderExists(targetPlanId, PARENT_ORDER_ID));
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
    }

    function testGasOpenDockedOrder() public {
        _open();
    }

    function testGasSubmitDockedSignal() public {
        assertTrue(_open());
        vm.prank(KEEPER);
        docking.submitDockedSignal(dockInstanceId, outputBinding, _coreNoAttribution());
    }

    UVPDockingModule private _dockingModule;
    UVPPlanMetadataModule private _metadataModule;
    UVPStagePatchModule private _stagePatchModule;

    function _newMachine() private returns (UVPStateMachine) {
        UVPStateMachine sm = new UVPStateMachine();
        UVPStagePatchModule stagePatch = new UVPStagePatchModule(address(sm));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(sm));
        UVPPlanMetadataModule metadata = new UVPPlanMetadataModule(address(sm));
        UVPDockingModule dock = new UVPDockingModule(address(sm), address(metadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(sm));
        sm.setStagePatchModule(address(stagePatch));
        sm.setDerivedSignalModule(address(derivedSignal));
        sm.setDockingModule(address(dock));
        sm.setPlanMetadataModule(address(metadata));
        sm.setOrderLinkModule(address(orderLink));
        sm.setLens(address(new UVPStateMachineLens(address(sm))));
        sm.freezeModules();
        _dockingModule = dock;
        _metadataModule = metadata;
        _stagePatchModule = stagePatch;
        return sm;
    }

    function _docking() private view returns (UVPDockingModule) {
        return _dockingModule;
    }

    function _computeStaticRouteParts() private {
        routeId = keccak256(abi.encode(DOMAIN_ROUTE_ID, localDefinitionRef, PARENT_EXEC_STAGE));
        entranceBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                PARENT_EXEC_HOOK,
                ENTRANCE_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        outputBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                DONE_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        progressOutBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                LOCAL_PROGRESS_SOURCE,
                LOCAL_PROGRESS_SIGNAL,
                PROGRESS_OUT_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        settleBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                SETTLE_PORT,
                TARGET_SOURCE,
                TARGET_PENDING_SIGNAL
            )
        );
        bytes32[] memory inputLeaves = new bytes32[](1);
        inputLeaves[0] = entranceBinding;
        inputsRoot = DockMerkle.root(inputLeaves);
        bytes32[] memory outputLeaves = new bytes32[](3);
        outputLeaves[0] = outputBinding;
        outputLeaves[1] = progressOutBinding;
        outputLeaves[2] = settleBinding;
        outputsRoot = DockMerkle.root(outputLeaves);

        openPortLeaf = keccak256(
            abi.encode(DOMAIN_INTERFACE_INPUT, TARGET_UID_ID, INTERFACE_NAME_ID, ENTRANCE_PORT, TARGET_ENTRANCE_HOOK)
        );
        donePortLeaf = _outputPortLeaf(DONE_PORT, TARGET_SOURCE, TARGET_SIGNAL);
        progressPortLeaf = _outputPortLeaf(PROGRESS_OUT_PORT, TARGET_SOURCE, TARGET_SIGNAL);
        settlePortLeaf = _outputPortLeaf(SETTLE_PORT, TARGET_SOURCE, TARGET_PENDING_SIGNAL);
        bytes32[] memory portLeaves = new bytes32[](3);
        portLeaves[0] = donePortLeaf;
        portLeaves[1] = progressPortLeaf;
        portLeaves[2] = settlePortLeaf;
        interfaceOutputsRoot = DockMerkle.root(portLeaves);
        (donePortProof, progressPortProof, settlePortProof) =
            _threeLeafProofs(donePortLeaf, progressPortLeaf, settlePortLeaf);
        interfaceLeaf = keccak256(
            abi.encode(
                DOMAIN_INTERFACE, TARGET_UID_ID, INTERFACE_NAME_ID, uint256(1), openPortLeaf, interfaceOutputsRoot
            )
        );
    }

    function _computeRouteHashes() private {
        openRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                targetPlanId,
                INTERFACE_NAME_ID,
                uint256(0),
                inputsRoot,
                outputsRoot
            )
        );
        existingRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                targetPlanId,
                INTERFACE_NAME_ID,
                uint256(1),
                inputsRoot,
                outputsRoot
            )
        );
    }

    function _outputPortLeaf(bytes32 portKey, bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_INTERFACE_OUTPUT, TARGET_UID_ID, INTERFACE_NAME_ID, portKey, sourceId, signalId)
            );
    }

    function _threeLeafProofs(bytes32 la, bytes32 lb, bytes32 lc)
        private
        pure
        returns (bytes32[] memory proofA, bytes32[] memory proofB, bytes32[] memory proofC)
    {
        bytes32[3] memory ordered = _sort3(la, lb, lc);
        bytes32 top = DockMerkle.pair(ordered[0], ordered[1]);
        proofA = _proofAt(ordered, la, top);
        proofB = _proofAt(ordered, lb, top);
        proofC = _proofAt(ordered, lc, top);
    }

    function _proofAt(bytes32[3] memory ordered, bytes32 leaf, bytes32 top)
        private
        pure
        returns (bytes32[] memory proof)
    {
        if (leaf == ordered[2]) {
            proof = new bytes32[](1);
            proof[0] = top;
            return proof;
        }
        proof = new bytes32[](2);
        if (leaf == ordered[0]) {
            proof[0] = ordered[1];
        } else {
            proof[0] = ordered[0];
        }
        proof[1] = ordered[2];
    }

    function _sort3(bytes32 v0, bytes32 v1, bytes32 v2) private pure returns (bytes32[3] memory ordered) {
        ordered[0] = v0;
        ordered[1] = v1;
        ordered[2] = v2;
        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && ordered[j] < ordered[j - 1]; j--) {
                bytes32 tmp = ordered[j];
                ordered[j] = ordered[j - 1];
                ordered[j - 1] = tmp;
            }
        }
    }

    function _registerTargetPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: TARGET_SOURCE,
            signalId: TARGET_SIGNAL,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(TARGET_SOURCE, TARGET_SIGNAL));
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: TARGET_ENTRANCE_HOOK,
            stageId: TARGET_STAGE,
            hookName: TARGET_HOOK_NAME,
            flags: FLAG_DOCK | FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: deps
        });
        UVPStateMachine.Instruction[] memory mintInstructions = new UVPStateMachine.Instruction[](1);
        mintInstructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: TARGET_OUT_SOURCE,
            signalId: TARGET_OUT_SIGNAL,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory mintDeps = new bytes32[](1);
        mintDeps[0] = keccak256(abi.encode(TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL));
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: TARGET_MINT_HOOK,
            stageId: TARGET_STAGE,
            hookName: bytes32("MINT"),
            flags: FLAG_MINT | FLAG_EMIT_READY,
            instructions: mintInstructions,
            dependencyKeys: mintDeps
        });
        StageSelectorBinding[] memory bindings = new StageSelectorBinding[](1);
        bindings[0] = StageSelectorBinding({selectorStageId: TARGET_STAGE, targetStageId: TARGET_STAGE});
        SignalCapability[] memory capabilities = new SignalCapability[](4);
        capabilities[0] = SignalCapability({
            stageId: TARGET_STAGE,
            targetSourceId: TARGET_OUT_SOURCE,
            signalId: TARGET_OUT_SIGNAL,
            targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: TARGET_STAGE, targetSourceId: TARGET_SOURCE, signalId: TARGET_SIGNAL, targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: TARGET_STAGE,
            targetSourceId: TARGET_SOURCE,
            signalId: TARGET_PENDING_SIGNAL,
            targetOrderRelation: 0
        });
        capabilities[3] = SignalCapability({
            stageId: TARGET_STAGE,
            targetSourceId: TARGET_INTAKE_SOURCE,
            signalId: TARGET_INTAKE_SIGNAL,
            targetOrderRelation: 0
        });
        return _commitAndFinalize(
            hooks,
            EMPTY_DOCK_ROOT,
            DockMerkle.root(_single(interfaceLeaf)),
            TARGET_PUBLISHER_KEY,
            bindings,
            capabilities
        );
    }

    function _registerTargetPlanWithoutPendingCapability() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: TARGET_SOURCE,
            signalId: TARGET_SIGNAL,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(TARGET_SOURCE, TARGET_SIGNAL));
        hooks[0] = UVPStateMachine.CompactHook({
            hookId: TARGET_ENTRANCE_HOOK,
            stageId: TARGET_STAGE,
            hookName: TARGET_HOOK_NAME,
            flags: FLAG_DOCK | FLAG_EMIT_READY,
            instructions: instructions,
            dependencyKeys: deps
        });
        UVPStateMachine.Instruction[] memory mintInstructions = new UVPStateMachine.Instruction[](1);
        mintInstructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: TARGET_OUT_SOURCE,
            signalId: TARGET_OUT_SIGNAL,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory mintDeps = new bytes32[](1);
        mintDeps[0] = keccak256(abi.encode(TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL));
        hooks[1] = UVPStateMachine.CompactHook({
            hookId: TARGET_MINT_HOOK,
            stageId: TARGET_STAGE,
            hookName: bytes32("MINT"),
            flags: FLAG_MINT | FLAG_EMIT_READY,
            instructions: mintInstructions,
            dependencyKeys: mintDeps
        });
        StageSelectorBinding[] memory bindings = new StageSelectorBinding[](1);
        bindings[0] = StageSelectorBinding({selectorStageId: TARGET_STAGE, targetStageId: TARGET_STAGE});
        SignalCapability[] memory capabilities = new SignalCapability[](2);
        capabilities[0] = SignalCapability({
            stageId: TARGET_STAGE,
            targetSourceId: TARGET_OUT_SOURCE,
            signalId: TARGET_OUT_SIGNAL,
            targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: TARGET_STAGE, targetSourceId: TARGET_SOURCE, signalId: TARGET_SIGNAL, targetOrderRelation: 0
        });
        return _commitAndFinalize(
            hooks,
            EMPTY_DOCK_ROOT,
            DockMerkle.root(_single(interfaceLeaf)),
            TARGET_PUBLISHER_KEY,
            bindings,
            capabilities
        );
    }

    function _registerParentPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _parentHook(
            PARENT_START_HOOK, PARENT_STAGE, keccak256("START"), FLAG_MINT | FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_START
        );
        hooks[1] = _parentHook(
            PARENT_EXEC_HOOK, PARENT_EXEC_STAGE, keccak256("EXECUTE"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_EXEC
        );
        bytes32[] memory routeLeaves = new bytes32[](2);
        routeLeaves[0] = openRouteHash;
        routeLeaves[1] = existingRouteHash;
        return _commitAndFinalize(
            hooks,
            DockMerkle.root(routeLeaves),
            EMPTY_DOCK_ROOT,
            PARENT_PUBLISHER_KEY,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    function _parentHook(
        bytes32 hookId,
        bytes32 stageId,
        bytes32 hookName,
        uint8 flags,
        bytes32 sourceId,
        bytes32 signalId
    ) private pure returns (UVPStateMachine.CompactHook memory) {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: sourceId,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(sourceId, signalId));
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: hookName,
            flags: flags,
            instructions: instructions,
            dependencyKeys: deps
        });
    }

    struct RogueRoute {
        bytes32 planId;
        bytes32 orderId;
        bytes32 routeHash;
        bytes32 dockInstanceId;
        bytes32 linkedOrderId;
        bytes32 entranceBindingHash;
        bytes32[] routeProof;
    }

    function _registerRogueRouteParent(
        bytes32 entranceHook,
        bytes32 entranceSource,
        bytes32 entranceSignal,
        UVPDockingModule.DockOutputBindingArg[] memory outputs
    ) private returns (RogueRoute memory route) {
        return _registerRogueRouteParentTo(targetPlanId, entranceHook, entranceSource, entranceSignal, outputs);
    }

    function _registerRogueRouteParentTo(
        bytes32 targetPlan,
        bytes32 entranceHook,
        bytes32 entranceSource,
        bytes32 entranceSignal,
        UVPDockingModule.DockOutputBindingArg[] memory outputs
    ) private returns (RogueRoute memory route) {
        route.entranceBindingHash = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                routeId,
                INTERFACE_NAME_ID,
                entranceHook,
                ENTRANCE_PORT,
                entranceSource,
                entranceSignal
            )
        );
        bytes32[] memory inputLeaves = new bytes32[](1);
        inputLeaves[0] = route.entranceBindingHash;
        bytes32[] memory outputLeaves = new bytes32[](outputs.length);
        for (uint256 i = 0; i < outputs.length; i++) {
            outputLeaves[i] = outputs[i].bindingHash;
        }
        route.routeHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                targetPlan,
                INTERFACE_NAME_ID,
                uint256(0),
                DockMerkle.root(inputLeaves),
                DockMerkle.root(outputLeaves)
            )
        );

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _parentHook(
            PARENT_START_HOOK, PARENT_STAGE, keccak256("START"), FLAG_MINT | FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_START
        );
        hooks[1] = _parentHook(
            PARENT_EXEC_HOOK, PARENT_EXEC_STAGE, keccak256("EXECUTE"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_EXEC
        );
        hooks[2] = _parentHook(
            PARENT_SIBLING_HOOK, PARENT_EXEC_STAGE, keccak256("SIBLING"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_SIBLING
        );
        bytes32[] memory routeLeaves = new bytes32[](1);
        routeLeaves[0] = route.routeHash;
        route.planId = _commitAndFinalize(
            hooks,
            DockMerkle.root(routeLeaves),
            EMPTY_DOCK_ROOT,
            PARENT_PUBLISHER_KEY,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );

        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](2);
        auths[0] = _auth(PARENT_STAGE, SIGNAL_START, address(this));
        auths[1] = _auth(PARENT_STAGE, SIGNAL_EXEC, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(SIGNAL_START);
        trigger.planId = route.planId;
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)), _noAttribution()
        );
        route.orderId = machine.triggerOrderIdFor(route.planId, PARENT_STAGE, SIGNAL_START, PAYLOAD);
        machine.submitSignal(
            route.planId, route.orderId, PARENT_STAGE, SIGNAL_EXEC, PAYLOAD, bytes32(uint256(0x78)), _noAttribution()
        );

        route.dockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                route.planId,
                localDefinitionRef,
                route.orderId,
                routeId,
                route.routeHash,
                uint256(0),
                INTERFACE_NAME_ID,
                targetPlan
            )
        );
        route.linkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, route.dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        route.routeProof = new bytes32[](0);
        return route;
    }

    function _rogueOpenRequest(RogueRoute memory route)
        private
        view
        returns (UVPDockingModule.OpenDockRequestV2 memory)
    {
        return _rogueOpenRequestTo(route, targetPlanId);
    }

    function _rogueOpenRequestTo(RogueRoute memory route, bytes32 targetPlan)
        private
        view
        returns (UVPDockingModule.OpenDockRequestV2 memory)
    {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        request.dockInstanceId = route.dockInstanceId;
        request.localPlanId = route.planId;
        request.localOrderId = route.orderId;
        request.routeHash = route.routeHash;
        request.linkedOrderId = route.linkedOrderId;
        request.targetPlanId = targetPlan;
        return request;
    }

    function _rogueInputs(RogueRoute memory route)
        private
        view
        returns (UVPDockingModule.DockInputBindingArg[] memory)
    {
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](1);
        inputs[0] = UVPDockingModule.DockInputBindingArg({
            localHookId: PARENT_EXEC_HOOK,
            portKey: ENTRANCE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: route.entranceBindingHash
        });
        return inputs;
    }

    function _rebindDockInstanceId() private {
        dockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                parentPlanId,
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                openRouteHash,
                uint256(0),
                INTERFACE_NAME_ID,
                targetPlanId
            )
        );
        linkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function _spawnParentOrder() private {
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](2);
        auths[0] = _auth(PARENT_STAGE, SIGNAL_START, address(this));
        auths[1] = _auth(PARENT_STAGE, SIGNAL_EXEC, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(SIGNAL_START);
        trigger.planId = parentPlanId;
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)), _noAttribution()
        );
        machine.submitSignal(
            parentPlanId, PARENT_ORDER_ID, PARENT_STAGE, SIGNAL_EXEC, PAYLOAD, bytes32(uint256(0x77)), _noAttribution()
        );
    }

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
        StageSelectorBinding[] bindings;
        SignalCapability[] capabilities;
        bytes32[] sortedLeaves;
    }

    mapping(bytes32 planId => CapabilityTables tables) private _capabilityTables;

    function _commitAndFinalize(
        UVPStateMachine.CompactHook[] memory hooks,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot,
        uint256 publisherKey,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities
    ) private returns (bytes32) {
        address publisher = vm.addr(publisherKey);
        bytes32[] memory leaves = _capabilityLeaves(selectorBindings, signalCapabilities);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(leaves),
            dockRoutesRoot: dockRoutesRoot,
            dockInterfaceRoot: dockInterfaceRoot,
            executorCandidatesRoot: DockMerkle.EMPTY_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_KEY),
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherKey, digest);
        bytes32 planId =
            machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), abi.encodePacked(r, s, v));
        CapabilityTables storage tables = _capabilityTables[planId];
        tables.bindings = selectorBindings;
        tables.capabilities = signalCapabilities;
        tables.sortedLeaves = _sortedUnique(leaves);
        machine.finalizePlan(planId);
        return planId;
    }

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

    function _coreFactAttributionFor(bytes32 planId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (IUVPStateMachineCore.FactAttribution memory)
    {
        UVPStateMachine.FactAttribution memory attribution = _factAttributionFor(planId, sourceId, signalId);
        return IUVPStateMachineCore.FactAttribution({
            sourceId: attribution.sourceId,
            signalId: attribution.signalId,
            stageId: attribution.stageId,
            capabilityProof: attribution.capabilityProof
        });
    }

    function _coreEntranceFactAttribution() private view returns (IUVPStateMachineCore.FactAttribution memory) {
        return _coreFactAttributionFor(targetPlanId, TARGET_SOURCE, TARGET_SIGNAL);
    }

    function _coreNoAttribution() private pure returns (IUVPStateMachineCore.FactAttribution memory) {
        return IUVPStateMachineCore.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
    }

    function _coreNoBinding() private pure returns (IUVPStateMachineCore.SelectorBindingProof memory) {
        return IUVPStateMachineCore.SelectorBindingProof({selectorStageId: bytes32(0), proof: new bytes32[](0)});
    }

    function _factAttributionFor(bytes32 planId, bytes32 sourceId, bytes32 signalId)
        private
        view
        returns (UVPStateMachine.FactAttribution memory attribution)
    {
        CapabilityTables storage tables = _capabilityTables[planId];
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

    function _birthAttribution(UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger)
        private
        view
        returns (UVPStateMachine.FactAttribution memory)
    {
        return _factAttributionFor(trigger.planId, trigger.sourceId, trigger.signalId);
    }

    function _outputAttributionsFor(bytes32 planId, UVPDockingModule.DockOutputBindingArg[] memory outputs)
        private
        view
        returns (IUVPStateMachineCore.FactAttribution[] memory attributions)
    {
        CapabilityTables storage tables = _capabilityTables[planId];
        attributions = new IUVPStateMachineCore.FactAttribution[](outputs.length);
        for (uint256 i = 0; i < outputs.length; i++) {
            IUVPStateMachineCore.FactAttribution memory attribution = _coreNoAttribution();
            for (uint256 j = 0; j < tables.capabilities.length; j++) {
                SignalCapability storage capability = tables.capabilities[j];
                if (
                    capability.targetOrderRelation == 0 && capability.targetSourceId == outputs[i].targetSourceId
                        && capability.signalId == outputs[i].targetSignalId
                ) {
                    bytes32 leaf = keccak256(
                        abi.encode(
                            SIGNAL_CAPABILITY_LEAF_DOMAIN,
                            capability.stageId,
                            outputs[i].targetSourceId,
                            outputs[i].targetSignalId,
                            uint256(0)
                        )
                    );
                    attribution = IUVPStateMachineCore.FactAttribution({
                        sourceId: outputs[i].targetSourceId,
                        signalId: outputs[i].targetSignalId,
                        stageId: capability.stageId,
                        capabilityProof: _merkleProofFor(tables.sortedLeaves, leaf)
                    });
                    break;
                }
            }
            attributions[i] = attribution;
        }
    }

    function _open() private returns (bool) {
        return _openWith(_openRouteProof(), _interfaceProof());
    }

    function _openWith(bytes32[] memory routeProof, UVPDockingModule.DockInterfaceProofV2 memory interfaceProof)
        private
        returns (bool)
    {
        return docking.openDockedOrder(
            _openCall(
                _openRequest(0),
                routeProof,
                interfaceProof,
                _inputs(),
                _outputs(),
                _openAuth(_permitEmpty(), _consentFor(_openRequest(0))),
                _outputAttributionsFor(targetPlanId, _outputs()),
                _coreEntranceFactAttribution()
            )
        );
    }

    function _openWithPermit(
        UVPDockingModule.DockInterfaceProofV2 memory interfaceProof,
        UVPDockingModule.EntrancePermitV2 memory permit
    ) private returns (bool) {
        return docking.openDockedOrder(
            _openCall(
                _openRequest(0),
                _openRouteProof(),
                interfaceProof,
                _inputs(),
                _outputs(),
                _openAuth(permit, _consentFor(_openRequest(0))),
                _outputAttributionsFor(targetPlanId, _outputs()),
                _coreEntranceFactAttribution()
            )
        );
    }

    function _openRaw(UVPDockingModule.OpenDockRequestV2 memory request) private returns (bool) {
        return _openRawWithProof(request, _openRouteProof());
    }

    function _openRawWithProof(UVPDockingModule.OpenDockRequestV2 memory request, bytes32[] memory routeProof)
        private
        returns (bool)
    {
        return docking.openDockedOrder(
            _openCall(
                request,
                routeProof,
                _interfaceProof(),
                _inputs(),
                _outputs(),
                _openAuth(_permitEmpty(), _consentFor(request)),
                _outputAttributionsFor(request.targetPlanId, _outputs()),
                _coreNoAttribution()
            )
        );
    }

    function _interfaceProof() private view returns (UVPDockingModule.DockInterfaceProofV2 memory) {
        return UVPDockingModule.DockInterfaceProofV2({
            entranceLeaf: _openLeafData(),
            portProof: _openPortProof(),
            commitment: _openInterfaceCommitment(),
            interfaceProof: _openInterfaceProof()
        });
    }

    function _openRequest(uint8 parentDepth) private view returns (UVPDockingModule.OpenDockRequestV2 memory) {
        return UVPDockingModule.OpenDockRequestV2({
            dockInstanceId: dockInstanceId,
            localPlanId: parentPlanId,
            localOrderId: PARENT_ORDER_ID,
            localStageId: PARENT_EXEC_STAGE,
            localHookId: PARENT_EXEC_HOOK,
            localDefinitionRefHash: localDefinitionRef,
            routeId: routeId,
            routeHash: openRouteHash,
            interfaceNameId: INTERFACE_NAME_ID,
            targetUidId: TARGET_UID_ID,
            targetDefinitionRefHash: targetDefinitionRef,
            targetPlanId: targetPlanId,
            linkedOrderId: linkedOrderId,
            targetStageId: TARGET_STAGE,
            targetHookId: TARGET_ENTRANCE_HOOK,
            parentDepth: parentDepth
        });
    }

    function _openLeafData() private view returns (UVPDockingModule.DockInterfacePortLeafV2 memory) {
        return UVPDockingModule.DockInterfacePortLeafV2({
            leafHash: openPortLeaf, portKey: ENTRANCE_PORT, hookKey: TARGET_ENTRANCE_HOOK
        });
    }

    function _openInterfaceCommitment() private view returns (UVPDockingModule.DockInterfaceCommitmentV2 memory) {
        return UVPDockingModule.DockInterfaceCommitmentV2({
            orderModesWord: 1,
            inputsRoot: openPortLeaf,
            outputsRoot: interfaceOutputsRoot
        });
    }

    function _inputs() private view returns (UVPDockingModule.DockInputBindingArg[] memory) {
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](1);
        inputs[0] = UVPDockingModule.DockInputBindingArg({
            localHookId: PARENT_EXEC_HOOK,
            portKey: ENTRANCE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: entranceBinding
        });
        return inputs;
    }

    function _outputs() private view returns (UVPDockingModule.DockOutputBindingArg[] memory) {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = new UVPDockingModule.DockOutputBindingArg[](3);
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: DONE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: outputBinding,
            portProof: donePortProof
        });
        outputs[1] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_PROGRESS_SOURCE,
            localSignalId: LOCAL_PROGRESS_SIGNAL,
            portKey: PROGRESS_OUT_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: progressOutBinding,
            portProof: progressPortProof
        });
        outputs[2] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: SETTLE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_PENDING_SIGNAL,
            bindingHash: settleBinding,
            portProof: settlePortProof
        });
        return outputs;
    }

    function _permitEmpty() private pure returns (UVPDockingModule.EntrancePermitV2 memory) {
        return UVPDockingModule.EntrancePermitV2({nonce: 0, deadline: 0, signature: ""});
    }

    function _permitSigned(uint256 nonce) private returns (UVPDockingModule.EntrancePermitV2 memory) {
        UVPDockingModule.EntrancePermitV2 memory permit;
        permit.nonce = nonce;
        permit.deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigestOnModule(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TARGET_PUBLISHER_KEY, digest);
        permit.signature = abi.encodePacked(r, s, v);
        return permit;
    }

    bytes32 private constant OPEN_CONSENT_TYPEHASH = keccak256(
        "UVPDockOpenConsentV1(bytes32 targetPlanId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 localOrderId,bytes32 routeId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 nonce,uint256 deadline)"
    );

    function _consentFor(UVPDockingModule.OpenDockRequestV2 memory request)
        private
        returns (UVPDockingModule.DockTargetConsentV1 memory)
    {
        UVPDockingModule.DockTargetConsentV1 memory consent;
        consent.nonce = 1;
        consent.deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                OPEN_CONSENT_TYPEHASH,
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
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256("UVPDockingModule"),
                        keccak256("4"),
                        block.chainid,
                        address(docking)
                    )
                ),
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(TARGET_PUBLISHER_KEY, digest);
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

    function _consentDigestFor(
        UVPDockingModule.OpenDockRequestV2 memory request,
        UVPDockingModule.DockTargetConsentV1 memory consent
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                OPEN_CONSENT_TYPEHASH,
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
            )
        );
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                        keccak256("UVPDockingModule"),
                        keccak256("4"),
                        block.chainid,
                        address(docking)
                    )
                ),
                structHash
            )
        );
    }

    function _consentEmpty() private pure returns (UVPDockingModule.DockTargetConsentV1 memory) {
        return UVPDockingModule.DockTargetConsentV1({nonce: 0, deadline: 0, signature: ""});
    }

    function _permitDigestOnModule(UVPDockingModule.EntrancePermitV2 memory permit) private view returns (bytes32) {
        return docking.entrancePermitDigest(
            targetPlanId,
            ENTRANCE_PORT,
            INTERFACE_NAME_ID,
            parentPlanId,
            openRouteHash,
            dockInstanceId,
            linkedOrderId,
            permit.nonce,
            permit.deadline
        );
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
            role: keccak256("bootstrap"),
            metadataHash: bytes32(0)
        });
    }

    function _coreAuth(bytes32 sourceId, bytes32 signalId, address submitter)
        private
        pure
        returns (IUVPStateMachineCore.SignalAuthorization memory)
    {
        return IUVPStateMachineCore.SignalAuthorization({
            sourceId: sourceId,
            signalId: signalId,
            submitter: submitter,
            role: keccak256("bootstrap"),
            metadataHash: bytes32(0)
        });
    }

    function _outsideTrigger(bytes32 signalId) private returns (UVPStateMachine.TriggerOrderFromOutsideRequest memory) {
        return UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: bytes32(0),
            creator: ORDER_CREATOR,
            triggerHookId: PARENT_START_HOOK,
            triggerStageId: PARENT_STAGE,
            sourceId: PARENT_STAGE,
            signalId: signalId,
            payloadHash: PAYLOAD,
            idempotencyKey: keccak256("birth"),
            submitter: vm.addr(SUBMITTER_KEY),
            deadline: block.timestamp + 1 hours
        });
    }

    function _outsideDigestFor(
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory auths
    ) private view returns (bytes32) {
        bytes32 authorizationsHash = _authorizationsHash(auths);
        bytes32 structHash = keccak256(
            abi.encode(
                TRIGGER_OUTSIDE_TYPEHASH,
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
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _authorizationsHash(UVPStateMachine.SignalAuthorization[] memory auths) private pure returns (bytes32) {
        bytes32 rolling = keccak256(abi.encode(auths.length));
        for (uint256 i = 0; i < auths.length; i++) {
            rolling = keccak256(
                abi.encode(
                    rolling,
                    auths[i].sourceId,
                    auths[i].signalId,
                    auths[i].submitter,
                    auths[i].role,
                    auths[i].metadataHash
                )
            );
        }
        return rolling;
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("UVPStateMachine"),
                keccak256("0.15"),
                block.chainid,
                address(machine)
            )
        );
    }

    function _sign(uint256 key, bytes32 digest) private returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openRouteProof() private view returns (bytes32[] memory) {
        return _siblingProof(existingRouteHash);
    }

    function _existingRouteProof() private view returns (bytes32[] memory) {
        return _siblingProof(openRouteHash);
    }

    function _openPortProof() private pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _openInterfaceProof() private pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _siblingProof(bytes32 sibling) private pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        return proof;
    }

    function _single(bytes32 leaf) private pure returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        return leaves;
    }
}
