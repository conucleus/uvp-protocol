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
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";

interface AttachVm {
    function addr(uint256 privateKey) external returns (address keyAddr);
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function store(address account, bytes32 slot, bytes32 value) external;
    function warp(uint256 newTimestamp) external;
}

contract UVPDockingModuleAttachTest {
    AttachVm private constant vm = AttachVm(address(uint160(uint256(keccak256("hevm cheat code")))));

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

    function assertEqAddress(address left, address right) internal pure {
        if (left != right) {
            revert("assertEq(address) failed");
        }
    }

    function _expect(bytes memory data) internal {
        vm.expectRevert(data);
    }

    uint8 private constant FLAG_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;

    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");
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
    bytes32 private constant DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant DOMAIN_DOCK_CANDIDATE = keccak256("UVP_DOCK_CANDIDATE_V2");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    bytes32 private constant OTHER_CANDIDATE_PLAN_ID = keccak256("other-candidate-plan");
    bytes32 private constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");

    bytes32 private constant PARENT_START_HOOK = keccak256("start#START");
    bytes32 private constant PARENT_STAGE = keccak256("start");
    bytes32 private constant SIGNAL_START = keccak256("start");
    bytes32 private constant PARENT_EXEC_HOOK = keccak256("exec#EXECUTE");
    bytes32 private constant PARENT_EXEC_STAGE = keccak256("exec");
    bytes32 private constant SIGNAL_EXEC = keccak256("exec");
    bytes32 private constant PARENT_DYN_HOOK = keccak256("dyn#SELECT");
    bytes32 private constant PARENT_DYN_STAGE = keccak256("dyn");
    bytes32 private constant SIGNAL_DYN = keccak256("select");

    bytes32 private constant TARGET_UID_ID = keccak256("zx-b0ba5e11e77a2c0ffee0dd5eed1c0deb0a");
    bytes32 private constant INTERFACE_NAME_ID = keccak256("evidence");
    bytes32 private constant TARGET_BIRTH_HOOK = keccak256("pay#MINT");
    bytes32 private constant TARGET_STAGE = keccak256("pay");
    bytes32 private constant TARGET_BIRTH_SOURCE = keccak256("observe");
    bytes32 private constant TARGET_BIRTH_SIGNAL = keccak256("pay.born");
    bytes32 private constant TARGET_SOURCE = keccak256("payroll");
    bytes32 private constant TARGET_SIGNAL = keccak256("pay.paid");
    bytes32 private constant TARGET_INPUT_SOURCE = keccak256("audit");
    bytes32 private constant TARGET_INPUT_SIGNAL = keccak256("pay.amend");
    bytes32 private constant TARGET_RECEIVE_HOOK = keccak256("pay#RECEIVE");
    bytes32 private constant TARGET_CONTROL_STAGE = keccak256("control");
    bytes32 private constant TARGET_CONTROL_HOOK = keccak256("control#WATCH");
    bytes32 private constant TARGET_CONTROL_SOURCE = keccak256("control");
    bytes32 private constant TARGET_CONTROL_SIGNAL = keccak256("control.tick");
    bytes32 private constant LOCAL_MAPPED_SOURCE = keccak256("recycler");
    bytes32 private constant LOCAL_MAPPED_SIGNAL = keccak256("exec.paid");
    bytes32 private constant LOCAL_PROGRESS_SOURCE = keccak256("recycler");
    bytes32 private constant LOCAL_PROGRESS_SIGNAL = keccak256("exec.progress");

    bytes32 private constant AMEND_PORT = keccak256("amend");
    bytes32 private constant DONE_PORT = keccak256("done");
    bytes32 private constant PROGRESS_PORT = keccak256("progress");

    bytes32 private constant PAYLOAD = bytes32(uint256(0xBEEF));
    bytes32 private constant TARGET_FACT_PAYLOAD = bytes32(uint256(0xFACE));

    uint256 private constant PARENT_PUBLISHER_KEY = 0xA11CE;
    uint256 private constant SUBMITTER_KEY = 0x51;
    uint256 private constant TARGET_PUBLISHER_KEY = 0xB0B;
    address private constant FOREIGN_CREATOR = address(0xC0C0);
    address private constant KEEPER = address(0x5EED1);
    address private constant EXECUTOR_CONSENTER = address(0xE0E0);
    bytes32 private constant OTHER_CANDIDATE_DEF_REF = keccak256("other-candidate-definition-ref");

    UVPStateMachine private machine;
    UVPDockingModule private docking;
    UVPStagePatchModule private stagePatch;
    bytes32 private localDefinitionRef = keccak256("attach-parent-definition-ref");
    bytes32 private targetDefinitionRef = keccak256(abi.encode(DOMAIN_DEFINITION_REF, TARGET_UID_ID));

    bytes32 private parentPlanId;
    bytes32 private targetPlanId;
    bytes32 private runtimeDomain;

    bytes32 private execRouteId;
    bytes32 private amendInputBinding;
    bytes32 private doneOutputBinding;
    bytes32 private progressOutputBinding;
    bytes32 private attachRouteHash;
    bytes32 private dynRouteId;
    bytes32 private candidatesRoot;
    bytes32 private targetCandidateLeaf;
    bytes32 private otherCandidateLeaf;
    bytes32 private dynRouteHash;
    bytes32 private evidenceInterfaceLeaf;
    bytes32 private evidenceInputsRoot;
    bytes32 private evidenceOutputsRoot;
    bytes32 private amendPortLeaf;
    bytes32[] private amendPortProof;
    bytes32 private donePortLeaf;
    bytes32 private progressPortLeaf;
    bytes32[] private donePortProof;
    bytes32[] private progressPortProof;

    uint256 private _spawnNonce;

    function setUp() public {
        machine = _newMachine();
        docking = _docking();
        stagePatch = _stagePatchModule;
        runtimeDomain = keccak256(abi.encode(DOMAIN_RUNTIME_EIP155, block.chainid, address(machine)));
        _computeRouteParts();
        targetPlanId = _registerTargetPlan();
        _computeRouteHashes();
        parentPlanId = _registerParentPlan();
    }

    function testAttachRecordsDockWithoutMintingChild() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        address creatorBefore = machine.orderCreator(targetPlanId, targetOrder);

        assertTrue(_attach(execRoute(), parentOrder, targetOrder));

        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        (,,,,,, bytes32 linked,,, bool exists) = docking.getActiveDock(instance);
        assertTrue(exists);
        assertEq(linked, targetOrder);
        assertEqAddress(machine.orderCreator(targetPlanId, targetOrder), creatorBefore);
        assertEq(docking.dockByTargetOrder(keccak256(abi.encode(targetPlanId, targetOrder))), bytes32(0));
    }

    function testAttachEmitsDockAttached() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        vm.expectEmit(true, true, true, true, address(docking));
        emit UVPDockingModule.DockAttached(
            instance,
            parentOrder,
            targetOrder,
            INTERFACE_NAME_ID,
            parentPlanId,
            targetPlanId,
            execRouteId,
            attachRouteHash,
            1,
            address(this)
        );
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
    }

    function testAttachIsIdempotentForSameInstance() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        vm.prank(KEEPER);
        assertFalse(_attach(execRoute(), parentOrder, targetOrder));
    }

    function testAttachGasIndependentOfExistingDocks() public {
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 firstParent = _spawnParentOrder(SIGNAL_EXEC);
        uint256 gasBase = gasleft();
        assertTrue(_attach(execRoute(), firstParent, targetOrder));
        uint256 spent1 = gasBase - gasleft();

        for (uint256 i = 0; i < 5; i++) {
            bytes32 parent = _spawnParentOrder(SIGNAL_EXEC);
            assertTrue(_attach(execRoute(), parent, targetOrder));
        }

        bytes32 lastParent = _spawnParentOrder(SIGNAL_EXEC);
        uint256 gasAgain = gasleft();
        assertTrue(_attach(execRoute(), lastParent, targetOrder));
        uint256 spent2 = gasAgain - gasleft();
        assertTrue(spent2 <= spent1 + 2000);
        assertTrue(spent1 < 850000);
    }

    function testAttachRejectsWithoutConsent() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockAttachConsentRequired.selector, instance, KEEPER));
        _attach(execRoute(), parentOrder, targetOrder);
    }

    function testAttachAllowsTargetOrderCreator() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrderBy(PAYLOAD, FOREIGN_CREATOR);
        vm.prank(FOREIGN_CREATOR);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        bytes32 otherParent = _spawnParentOrder(SIGNAL_EXEC);
        vm.prank(KEEPER);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockAttachConsentRequired.selector,
                _attachInstanceId(otherParent, attachRouteHash, targetOrder),
                KEEPER
            )
        );
        _attach(execRoute(), otherParent, targetOrder);
    }

    function testAttachAllowsActiveStageExecutor() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        _assignControlExecutor(targetOrder, EXECUTOR_CONSENTER);
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        request.targetStageId = TARGET_CONTROL_STAGE;
        vm.prank(EXECUTOR_CONSENTER);
        assertTrue(_attachWithArgs(request, _attachInterfaceProof(), _permitEmpty()));
    }

    function testAttachRejectsExecutorAnchoredToWrongStage() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        _assignControlExecutor(targetOrder, EXECUTOR_CONSENTER);
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        request.targetStageId = TARGET_STAGE;
        bytes32 instance = _instanceIdOf(dynRouteId, dynRouteHash, parentOrder, targetOrder);
        vm.prank(EXECUTOR_CONSENTER);
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockAttachConsentRequired.selector, instance, EXECUTOR_CONSENTER)
        );
        _attachWithArgs(request, _attachInterfaceProof(), _permitEmpty());
    }

    function testAttachRejectsExecutorOfDifferentOrder() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 otherOrder = _spawnTargetOrder(PAYLOAD);
        _assignControlExecutor(otherOrder, EXECUTOR_CONSENTER);
        bytes32 targetOrder = _spawnTargetOrder(bytes32(uint256(0xB3)));
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        request.targetStageId = TARGET_CONTROL_STAGE;
        bytes32 instance = _instanceIdOf(dynRouteId, dynRouteHash, parentOrder, targetOrder);
        vm.prank(EXECUTOR_CONSENTER);
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockAttachConsentRequired.selector, instance, EXECUTOR_CONSENTER)
        );
        _attachWithArgs(request, _attachInterfaceProof(), _permitEmpty());
    }

    function testAttachAllowsPublisherPermit() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        UVPDockingModule.EntrancePermitV2 memory permit = _attachPermitSigned(instance, parentOrder, targetOrder, 1);
        vm.prank(KEEPER);
        assertTrue(_attachWithPermit(execRoute(), parentOrder, targetOrder, permit));
        assertEq(docking.usedEntrancePermitNonce(instance), 1);
    }

    function testAttachPermitWrongSignerRejected() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        UVPDockingModule.EntrancePermitV2 memory permit = _attachPermitSigned(instance, parentOrder, targetOrder, 1);
        bytes32 digest = docking.attachPermitDigest(
            targetPlanId,
            targetOrder,
            INTERFACE_NAME_ID,
            parentPlanId,
            attachRouteHash,
            instance,
            permit.nonce,
            permit.deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        permit.signature = abi.encodePacked(r, s, v);
        vm.prank(KEEPER);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockPermitInvalidSigner.selector, vm.addr(TARGET_PUBLISHER_KEY), vm.addr(0xDEAD)
            )
        );
        _attachWithPermit(execRoute(), parentOrder, targetOrder, permit);
    }

    function testAttachPermitExpiredRejected() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        UVPDockingModule.EntrancePermitV2 memory permit = _attachPermitSigned(instance, parentOrder, targetOrder, 1);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockPermitExpired.selector, permit.deadline));
        _attachWithPermit(execRoute(), parentOrder, targetOrder, permit);
    }

    function testAttachRejectsSelfAttach() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        UVPDockingModule.AttachDockRequestV1 memory request =
            _baseRequest(execRouteId, attachRouteHash, PARENT_EXEC_STAGE, parentOrder, parentOrder);
        request.targetPlanId = parentPlanId;
        request.linkedOrderId = parentOrder;
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockSelfAttach.selector, parentPlanId, parentOrder));
        _attachRaw(request);
    }

    function testAttachCrossPlanSameUidIsNotSelfAttach() public {
        bytes32 aliasDefRef = targetDefinitionRef;
        bytes32 aliasRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, aliasDefRef, PARENT_EXEC_STAGE));
        bytes32 aliasAmendBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                aliasRouteId,
                INTERFACE_NAME_ID,
                PARENT_EXEC_HOOK,
                AMEND_PORT,
                TARGET_INPUT_SOURCE,
                TARGET_INPUT_SIGNAL
            )
        );
        bytes32 aliasDoneBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                aliasRouteId,
                INTERFACE_NAME_ID,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                DONE_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        bytes32 aliasProgressBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                aliasRouteId,
                INTERFACE_NAME_ID,
                LOCAL_PROGRESS_SOURCE,
                LOCAL_PROGRESS_SIGNAL,
                PROGRESS_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        bytes32[] memory aliasOutputBindings = new bytes32[](2);
        aliasOutputBindings[0] = aliasDoneBinding;
        aliasOutputBindings[1] = aliasProgressBinding;
        bytes32 aliasRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                aliasDefRef,
                targetDefinitionRef,
                targetPlanId,
                INTERFACE_NAME_ID,
                uint256(1),
                DockMerkle.root(_single(aliasAmendBinding)),
                DockMerkle.root(aliasOutputBindings)
            )
        );

        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _compactHook(
            PARENT_START_HOOK, PARENT_STAGE, keccak256("START"), FLAG_MINT | FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_START
        );
        hooks[1] = _compactHook(
            PARENT_EXEC_HOOK, PARENT_EXEC_STAGE, keccak256("EXECUTE"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_EXEC
        );
        hooks[2] = _compactHook(
            PARENT_DYN_HOOK, PARENT_DYN_STAGE, keccak256("SELECT"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_DYN
        );
        bytes32 aliasPlanId = _commitAndFinalize(
            hooks,
            DockMerkle.root(_single(aliasRouteHash)),
            EMPTY_DOCK_ROOT,
            PARENT_PUBLISHER_KEY,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
        require(aliasPlanId != targetPlanId, "alias plan must not collide with the target plan");
        require(aliasPlanId != parentPlanId, "alias plan must not collide with the parent plan");

        bytes32 payload = keccak256("alias-parent-order");
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](2);
        auths[0] = _auth(PARENT_STAGE, SIGNAL_START, address(this));
        auths[1] = _auth(PARENT_STAGE, SIGNAL_EXEC, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(SIGNAL_START);
        trigger.planId = aliasPlanId;
        trigger.payloadHash = payload;
        trigger.idempotencyKey = keccak256(abi.encode("alias-birth", payload));
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)), _noAttribution()
        );
        bytes32 aliasOrder = machine.triggerOrderIdFor(aliasPlanId, PARENT_STAGE, SIGNAL_START, payload);

        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);

        bytes32 instance = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                aliasPlanId,
                aliasDefRef,
                aliasOrder,
                aliasRouteId,
                aliasRouteHash,
                uint256(1),
                INTERFACE_NAME_ID,
                targetPlanId,
                targetOrder
            )
        );
        UVPDockingModule.AttachDockRequestV1 memory request = UVPDockingModule.AttachDockRequestV1({
            dockInstanceId: instance,
            localPlanId: aliasPlanId,
            localOrderId: aliasOrder,
            localStageId: PARENT_EXEC_STAGE,
            localDefinitionRefHash: aliasDefRef,
            routeId: aliasRouteId,
            routeHash: aliasRouteHash,
            interfaceNameId: INTERFACE_NAME_ID,
            targetUidId: TARGET_UID_ID,
            targetDefinitionRefHash: targetDefinitionRef,
            targetPlanId: targetPlanId,
            linkedOrderId: targetOrder,
            targetStageId: TARGET_STAGE,
            parentDepth: 0,
            targetCandidatesRoot: bytes32(0)
        });
        UVPDockingModule.AttachInputBindingArg[] memory inputs = new UVPDockingModule.AttachInputBindingArg[](1);
        inputs[0] = UVPDockingModule.AttachInputBindingArg({
            localHookId: PARENT_EXEC_HOOK,
            portKey: AMEND_PORT,
            targetSourceId: TARGET_INPUT_SOURCE,
            targetSignalId: TARGET_INPUT_SIGNAL,
            bindingHash: aliasAmendBinding,
            targetHookId: TARGET_RECEIVE_HOOK,
            portProof: amendPortProof
        });
        UVPDockingModule.DockOutputBindingArg[] memory outputs = new UVPDockingModule.DockOutputBindingArg[](2);
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: DONE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: aliasDoneBinding,
            portProof: donePortProof
        });
        outputs[1] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_PROGRESS_SOURCE,
            localSignalId: LOCAL_PROGRESS_SIGNAL,
            portKey: PROGRESS_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: aliasProgressBinding,
            portProof: progressPortProof
        });

        assertTrue(
            docking.attachDockedOrder(
                request,
                new bytes32[](0),
                _attachInterfaceProof(),
                inputs,
                outputs,
                _permitEmpty(),
                _outputAttributionsFor(outputs)
            )
        );
        (,,,,,, bytes32 linked,,, bool exists) = docking.getActiveDock(instance);
        assertTrue(exists);
        assertEq(linked, targetOrder);
    }

    function testAttachPermitReplayReturnsFalseAfterDockExists() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        UVPDockingModule.EntrancePermitV2 memory permit = _attachPermitSigned(instance, parentOrder, targetOrder, 1);
        vm.prank(KEEPER);
        assertTrue(_attachWithPermit(execRoute(), parentOrder, targetOrder, permit));
        vm.prank(KEEPER);
        assertFalse(_attachWithPermit(execRoute(), parentOrder, targetOrder, permit));
    }

    function testMultipleParentsAttachSameTargetOrder() public {
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 parentA = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 parentB = _spawnParentOrder(SIGNAL_EXEC);
        assertTrue(_attach(execRoute(), parentA, targetOrder));
        assertTrue(_attach(execRoute(), parentB, targetOrder));
        bytes32 instanceA = _attachInstanceId(parentA, attachRouteHash, targetOrder);
        bytes32 instanceB = _attachInstanceId(parentB, attachRouteHash, targetOrder);
        assertFalse(instanceA == instanceB);
        (,,,,,, bytes32 linkedA,,, bool existsA) = docking.getActiveDock(instanceA);
        (,,,,,, bytes32 linkedB,,, bool existsB) = docking.getActiveDock(instanceB);
        assertTrue(existsA && existsB);
        assertEq(linkedA, targetOrder);
        assertEq(linkedB, targetOrder);
        assertEq(docking.dockByTargetOrder(keccak256(abi.encode(targetPlanId, targetOrder))), bytes32(0));
    }

    function testBackfillMirrorsEstablishedOutputToEachParent() public {
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        _establishTargetFact(targetOrder);
        bytes32 parentA = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 parentB = _spawnParentOrder(SIGNAL_EXEC);
        assertTrue(_attach(execRoute(), parentA, targetOrder));
        assertTrue(_attach(execRoute(), parentB, targetOrder));

        vm.prank(KEEPER);
        assertTrue(
            docking.submitDockedSignal(
                _attachInstanceId(parentA, attachRouteHash, targetOrder), doneOutputBinding, _coreNoAttribution()
            )
        );
        vm.prank(KEEPER);
        assertTrue(
            docking.submitDockedSignal(
                _attachInstanceId(parentB, attachRouteHash, targetOrder), doneOutputBinding, _coreNoAttribution()
            )
        );
        (bool mappedA, bytes32 payloadA,,,) =
            machine.getSignal(parentPlanId, parentA, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        (bool mappedB, bytes32 payloadB,,,) =
            machine.getSignal(parentPlanId, parentB, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        assertTrue(mappedA && mappedB);
        assertEq(payloadA, TARGET_FACT_PAYLOAD);
        assertEq(payloadB, TARGET_FACT_PAYLOAD);
        vm.prank(KEEPER);
        assertTrue(
            docking.submitDockedSignal(
                _attachInstanceId(parentA, attachRouteHash, targetOrder), progressOutputBinding, _coreNoAttribution()
            )
        );
        vm.prank(KEEPER);
        assertFalse(
            docking.submitDockedSignal(
                _attachInstanceId(parentA, attachRouteHash, targetOrder), progressOutputBinding, _coreNoAttribution()
            )
        );
    }

    function testAttachInputDeliveredExactlyOnceThenIdempotent() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        assertFalse(docking.dockInputDelivered(instance, amendInputBinding));

        vm.prank(KEEPER);
        assertTrue(docking.submitDockedInput(instance, PARENT_EXEC_HOOK, amendInputBinding, _amendInputAttribution()));
        (bool delivered,,,,) = machine.getSignal(targetPlanId, targetOrder, TARGET_INPUT_SOURCE, TARGET_INPUT_SIGNAL);
        assertTrue(delivered);
        assertTrue(docking.dockInputDelivered(instance, amendInputBinding));
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedInput(instance, PARENT_EXEC_HOOK, amendInputBinding, _amendInputAttribution()));
    }

    function testSubmitDockedInputConflictsWithPreexistingFact() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        machine.submitSignal(
            targetPlanId,
            targetOrder,
            TARGET_INPUT_SOURCE,
            TARGET_INPUT_SIGNAL,
            bytes32(uint256(0xA11)),
            bytes32(uint256(0x1)),
            _factAttributionFor(targetPlanId, TARGET_INPUT_SOURCE, TARGET_INPUT_SIGNAL)
        );
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockInputConflict.selector, instance, amendInputBinding));
        docking.submitDockedInput(instance, PARENT_EXEC_HOOK, amendInputBinding, _amendInputAttribution());
        assertFalse(docking.dockInputDelivered(instance, amendInputBinding));
    }

    function testAttachRejectsDuplicateTargetFactKeyInputs() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        UVPDockingModule.AttachInputBindingArg[] memory inputs = _attachInputs(PARENT_EXEC_HOOK);
        UVPDockingModule.AttachInputBindingArg[] memory duplicated = new UVPDockingModule.AttachInputBindingArg[](2);
        duplicated[0] = inputs[0];
        duplicated[1] = inputs[0];
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _attachOutputs();
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockInputConflict.selector, request.dockInstanceId, amendInputBinding)
        );
        docking.attachDockedOrder(
            request,
            _routeProofFor(request.routeHash),
            _attachInterfaceProof(),
            duplicated,
            outputs,
            _permitEmpty(),
            _outputAttributionsFor(outputs)
        );
    }

    function testAttachSelectsCandidateFromCommittedSet() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        assertTrue(_attach(dynRoute(), parentOrder, targetOrder));
        (,,,,,, bytes32 linked,,, bool exists) =
            docking.getActiveDock(_attachInstanceId(parentOrder, dynRouteHash, targetOrder));
        assertTrue(exists);
        assertEq(linked, targetOrder);
    }

    function testAttachRejectsForgedCandidateProof() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = _attachInterfaceProof();
        proof.candidateProof[0] = bytes32(uint256(0xBAD));
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockCandidateLeafMismatch.selector, targetCandidateLeaf, candidatesRoot
            )
        );
        _attachWithProof(dynRoute(), parentOrder, targetOrder, proof);
    }

    function testAttachRejectsProofOfUnselectedCandidate() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = _attachInterfaceProof();
        proof.candidateProof = _merkleProofForLeaves(otherCandidateLeaf);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockCandidateLeafMismatch.selector, targetCandidateLeaf, candidatesRoot
            )
        );
        _attachWithProof(dynRoute(), parentOrder, targetOrder, proof);
    }

    function testAttachRejectsForeignCandidateRoot() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        bytes32 foreignRoot = DockMerkle.root(_single(targetCandidateLeaf));
        request.targetCandidatesRoot = foreignRoot;
        bytes32 recomputed = _routeHash(foreignRoot, bytes32(0), EMPTY_DOCK_ROOT, EMPTY_DOCK_ROOT);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, dynRouteHash, recomputed));
        _attachRaw(request);
    }

    function testAttachSelectionIsPinnedToTargetOrder() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetA = _spawnTargetOrder(PAYLOAD);
        bytes32 targetB = _spawnTargetOrder(bytes32(uint256(0xB2)));
        assertTrue(_attach(dynRoute(), parentOrder, targetA));
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetB);
        bytes32 localRouteInstanceKey = keccak256(abi.encode(parentPlanId, parentOrder, PARENT_DYN_STAGE, dynRouteId));
        _expect(abi.encodeWithSelector(UVPDockingModule.DockEndpointOccupied.selector, localRouteInstanceKey));
        _attachRaw(request);
    }

    function testAttachRejectsDynamicRouteCarryingBindings() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = _attachInterfaceProof();
        UVPDockingModule.EntrancePermitV2 memory permit = _permitEmpty();

        bytes32 dynAmendBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                dynRouteId,
                INTERFACE_NAME_ID,
                PARENT_DYN_HOOK,
                AMEND_PORT,
                TARGET_INPUT_SOURCE,
                TARGET_INPUT_SIGNAL
            )
        );
        UVPDockingModule.AttachInputBindingArg[] memory inputs = new UVPDockingModule.AttachInputBindingArg[](1);
        inputs[0] = UVPDockingModule.AttachInputBindingArg({
            localHookId: PARENT_DYN_HOOK,
            portKey: AMEND_PORT,
            targetSourceId: TARGET_INPUT_SOURCE,
            targetSignalId: TARGET_INPUT_SIGNAL,
            bindingHash: dynAmendBinding,
            targetHookId: TARGET_RECEIVE_HOOK,
            portProof: amendPortProof
        });
        bytes32 withInputs = _routeHash(candidatesRoot, bytes32(0), dynAmendBinding, EMPTY_DOCK_ROOT);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, dynRouteHash, withInputs));
        docking.attachDockedOrder(
            request,
            _routeProofFor(dynRouteHash),
            proof,
            inputs,
            new UVPDockingModule.DockOutputBindingArg[](0),
            permit,
            new IUVPStateMachineCore.FactAttribution[](0)
        );

        bytes32 dynDoneBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                dynRouteId,
                INTERFACE_NAME_ID,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                DONE_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        UVPDockingModule.DockOutputBindingArg[] memory outputs = new UVPDockingModule.DockOutputBindingArg[](1);
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: DONE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: dynDoneBinding,
            portProof: donePortProof
        });
        bytes32 withOutputs = _routeHash(candidatesRoot, bytes32(0), EMPTY_DOCK_ROOT, dynDoneBinding);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, dynRouteHash, withOutputs));
        docking.attachDockedOrder(
            request,
            _routeProofFor(dynRouteHash),
            proof,
            new UVPDockingModule.AttachInputBindingArg[](0),
            outputs,
            permit,
            _outputAttributionsFor(outputs)
        );
    }

    function testAttachRejectsInterfaceWithoutExistingMode() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = _attachInterfaceProof();
        proof.commitment.orderModesWord = 1;
        _expect(abi.encodeWithSelector(UVPDockingModule.DockInterfaceModeUnsupported.selector, 1));
        _attachWithProof(execRoute(), parentOrder, targetOrder, proof);
    }

    function testAttachRejectsUnknownTargetOrder() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockUnknownTargetOrder.selector, targetPlanId, keccak256("ghost-order")
            )
        );
        _attach(execRoute(), parentOrder, keccak256("ghost-order"));
    }

    function testAttachRejectsNewModeRouteHash() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        request.routeHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                targetPlanId,
                INTERFACE_NAME_ID,
                uint256(0),
                DockMerkle.root(_single(amendInputBinding)),
                _outputsRootOf()
            )
        );
        bytes32 recomputed = _routeHash(bytes32(0), bytes32(0), DockMerkle.root(_single(amendInputBinding)), _outputsRootOf());
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, request.routeHash, recomputed));
        _attachRaw(request);
    }

    function testAttachRejectsDepthMismatch() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        request.parentDepth = 3;
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthMismatch.selector, 3, 0));
        _attachRaw(request);
    }

    function testAttachRejectsAncestorCycle() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 ancestorDockId = keccak256("ancestor-dock");
        _plantDock(ancestorDockId, targetPlanId, targetOrder);
        bytes32 fatherSlot =
            keccak256(abi.encode(parentOrder, keccak256(abi.encode(parentPlanId, uint256(8)))));
        vm.store(address(docking), fatherSlot, ancestorDockId);

        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockAncestorCycle.selector, targetPlanId, targetOrder));
        _attachRaw(request);
    }

    function testAttachRejectsTransitiveAncestorCycle() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 midOrder = keccak256("ancestor-mid");
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 midDockId = keccak256("ancestor-mid-dock");
        bytes32 targetDockId = keccak256("ancestor-target-dock");
        _plantDock(midDockId, parentPlanId, midOrder);
        _plantDock(targetDockId, targetPlanId, targetOrder);
        vm.store(
            address(docking),
            keccak256(abi.encode(parentOrder, keccak256(abi.encode(parentPlanId, uint256(8))))),
            midDockId
        );
        vm.store(
            address(docking),
            keccak256(abi.encode(midOrder, keccak256(abi.encode(parentPlanId, uint256(8))))),
            targetDockId
        );

        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockAncestorCycle.selector, targetPlanId, targetOrder));
        _attachRaw(request);
    }

    function _plantDock(bytes32 dockId, bytes32 localPlanId, bytes32 localOrderId) private {
        bytes32 dockBase = keccak256(abi.encode(dockId, uint256(0)));
        vm.store(address(docking), dockBase, localPlanId);
        vm.store(address(docking), bytes32(uint256(dockBase) + 1), localOrderId);
        vm.store(address(docking), bytes32(uint256(dockBase) + 8), bytes32(uint256(1) << 8));
    }

    function testAttachRaisesTargetDepthAndEnforcesMax() public {
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 depthSlot = keccak256(abi.encode(parentOrder, keccak256(abi.encode(parentPlanId, uint256(7)))));
        vm.store(address(docking), depthSlot, bytes32(uint256(uint256(3))));
        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        request.parentDepth = 3;
        assertTrue(_attachWithArgs(request, _attachInterfaceProof(), _permitEmpty()));
        assertEq(docking.dockEdgeCountOfOrder(targetPlanId, targetOrder), 4);

        bytes32 deepParent = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 deepSlot = keccak256(abi.encode(deepParent, keccak256(abi.encode(parentPlanId, uint256(7)))));
        vm.store(address(docking), deepSlot, bytes32(uint256(uint256(8))));
        UVPDockingModule.AttachDockRequestV1 memory deepRequest = _execRequest(deepParent, targetOrder);
        deepRequest.parentDepth = 8;
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthExceeded.selector, 8, 8));
        _attachWithArgs(deepRequest, _attachInterfaceProof(), _permitEmpty());
    }

    function testAttachKeepsDeeperTargetDepth() public {
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 targetDepthSlot = keccak256(abi.encode(targetOrder, keccak256(abi.encode(targetPlanId, uint256(7)))));
        vm.store(address(docking), targetDepthSlot, bytes32(uint256(5)));
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        assertEq(docking.dockEdgeCountOfOrder(targetPlanId, targetOrder), 5);
    }

    UVPDockingModule private _dockingModule;
    UVPStagePatchModule private _stagePatchModule;

    function _newMachine() private returns (UVPStateMachine) {
        UVPStateMachine sm = new UVPStateMachine();
        UVPStagePatchModule patch = new UVPStagePatchModule(address(sm));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(sm));
        UVPPlanMetadataModule metadata = new UVPPlanMetadataModule(address(sm));
        UVPDockingModule dock = new UVPDockingModule(address(sm), address(metadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(sm));
        sm.setStagePatchModule(address(patch));
        sm.setDerivedSignalModule(address(derivedSignal));
        sm.setDockingModule(address(dock));
        sm.setPlanMetadataModule(address(metadata));
        sm.setOrderLinkModule(address(orderLink));
        sm.setLens(address(new UVPStateMachineLens(address(sm))));
        sm.freezeModules();
        _dockingModule = dock;
        _stagePatchModule = patch;
        return sm;
    }

    function _docking() private view returns (UVPDockingModule) {
        return _dockingModule;
    }

    function _computeRouteParts() private {
        execRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, localDefinitionRef, PARENT_EXEC_STAGE));
        amendInputBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                execRouteId,
                INTERFACE_NAME_ID,
                PARENT_EXEC_HOOK,
                AMEND_PORT,
                TARGET_INPUT_SOURCE,
                TARGET_INPUT_SIGNAL
            )
        );
        doneOutputBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                execRouteId,
                INTERFACE_NAME_ID,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                DONE_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        progressOutputBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                execRouteId,
                INTERFACE_NAME_ID,
                LOCAL_PROGRESS_SOURCE,
                LOCAL_PROGRESS_SIGNAL,
                PROGRESS_PORT,
                TARGET_SOURCE,
                TARGET_SIGNAL
            )
        );
        amendPortLeaf = keccak256(
            abi.encode(DOMAIN_INTERFACE_INPUT, TARGET_UID_ID, INTERFACE_NAME_ID, AMEND_PORT, TARGET_RECEIVE_HOOK)
        );
        evidenceInputsRoot = DockMerkle.root(_single(amendPortLeaf));
        amendPortProof = new bytes32[](0);
        donePortLeaf = _outputPortLeaf(DONE_PORT, TARGET_SOURCE, TARGET_SIGNAL);
        progressPortLeaf = _outputPortLeaf(PROGRESS_PORT, TARGET_SOURCE, TARGET_SIGNAL);
        bytes32[] memory portLeaves = new bytes32[](2);
        portLeaves[0] = donePortLeaf;
        portLeaves[1] = progressPortLeaf;
        evidenceOutputsRoot = DockMerkle.root(portLeaves);
        (donePortProof, progressPortProof) = _twoLeafProofs(donePortLeaf, progressPortLeaf);
        evidenceInterfaceLeaf = keccak256(
            abi.encode(
                DOMAIN_INTERFACE, TARGET_UID_ID, INTERFACE_NAME_ID, uint256(2), evidenceInputsRoot, evidenceOutputsRoot
            )
        );
    }

    function _computeRouteHashes() private {
        attachRouteHash =
            _routeHash(targetDefinitionRef, targetPlanId, DockMerkle.root(_single(amendInputBinding)), _outputsRootOf());

        dynRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, localDefinitionRef, PARENT_DYN_STAGE));
        targetCandidateLeaf = keccak256(
            abi.encode(DOMAIN_DOCK_CANDIDATE, dynRouteId, targetDefinitionRef, targetPlanId, INTERFACE_NAME_ID)
        );
        otherCandidateLeaf = keccak256(
            abi.encode(
                DOMAIN_DOCK_CANDIDATE, dynRouteId, OTHER_CANDIDATE_DEF_REF, OTHER_CANDIDATE_PLAN_ID, INTERFACE_NAME_ID
            )
        );
        bytes32[] memory candidateLeaves = new bytes32[](2);
        candidateLeaves[0] = targetCandidateLeaf;
        candidateLeaves[1] = otherCandidateLeaf;
        candidatesRoot = DockMerkle.root(candidateLeaves);
        dynRouteHash = _routeHash(candidatesRoot, bytes32(0), EMPTY_DOCK_ROOT, EMPTY_DOCK_ROOT);
    }

    function _outputPortLeaf(bytes32 portKey, bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_INTERFACE_OUTPUT, TARGET_UID_ID, INTERFACE_NAME_ID, portKey, sourceId, signalId)
            );
    }

    function _routeHash(bytes32 targetSlot, bytes32 targetPlanIdWord, bytes32 inputsRoot, bytes32 outputsRoot)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetSlot,
                targetPlanIdWord,
                INTERFACE_NAME_ID,
                uint256(1),
                inputsRoot,
                outputsRoot
            )
        );
    }

    function _outputsRootOf() private view returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = doneOutputBinding;
        leaves[1] = progressOutputBinding;
        return DockMerkle.root(leaves);
    }

    function _twoLeafProofs(bytes32 la, bytes32 lb)
        private
        pure
        returns (bytes32[] memory proofA, bytes32[] memory proofB)
    {
        proofA = new bytes32[](1);
        proofA[0] = lb;
        proofB = new bytes32[](1);
        proofB[0] = la;
    }

    function _merkleProofForLeaves(bytes32 leaf) private view returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = leaf == targetCandidateLeaf ? otherCandidateLeaf : targetCandidateLeaf;
    }

    function _registerTargetPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _compactHook(
            TARGET_BIRTH_HOOK,
            TARGET_STAGE,
            bytes32("MINT"),
            FLAG_MINT | FLAG_EMIT_READY,
            TARGET_BIRTH_SOURCE,
            TARGET_BIRTH_SIGNAL
        );
        hooks[1] = _compactHook(
            TARGET_RECEIVE_HOOK,
            TARGET_STAGE,
            bytes32("RECEIVE"),
            FLAG_EMIT_READY,
            TARGET_INPUT_SOURCE,
            TARGET_INPUT_SIGNAL
        );
        hooks[2] = _compactHook(
            TARGET_CONTROL_HOOK,
            TARGET_CONTROL_STAGE,
            bytes32("WATCH"),
            FLAG_EMIT_READY,
            TARGET_CONTROL_SOURCE,
            TARGET_CONTROL_SIGNAL
        );
        StageSelectorBinding[] memory bindings = new StageSelectorBinding[](1);
        bindings[0] = StageSelectorBinding({selectorStageId: TARGET_CONTROL_STAGE, targetStageId: TARGET_CONTROL_STAGE});
        SignalCapability[] memory capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: TARGET_STAGE,
            targetSourceId: TARGET_BIRTH_SOURCE,
            signalId: TARGET_BIRTH_SIGNAL,
            targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: TARGET_STAGE, targetSourceId: TARGET_SOURCE, signalId: TARGET_SIGNAL, targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: TARGET_STAGE,
            targetSourceId: TARGET_INPUT_SOURCE,
            signalId: TARGET_INPUT_SIGNAL,
            targetOrderRelation: 0
        });
        return _commitAndFinalize(
            hooks,
            EMPTY_DOCK_ROOT,
            DockMerkle.root(_single(evidenceInterfaceLeaf)),
            TARGET_PUBLISHER_KEY,
            bindings,
            capabilities
        );
    }

    function _registerParentPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _compactHook(
            PARENT_START_HOOK, PARENT_STAGE, keccak256("START"), FLAG_MINT | FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_START
        );
        hooks[1] = _compactHook(
            PARENT_EXEC_HOOK, PARENT_EXEC_STAGE, keccak256("EXECUTE"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_EXEC
        );
        hooks[2] = _compactHook(
            PARENT_DYN_HOOK, PARENT_DYN_STAGE, keccak256("SELECT"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_DYN
        );
        bytes32[] memory routeLeaves = new bytes32[](2);
        routeLeaves[0] = attachRouteHash;
        routeLeaves[1] = dynRouteHash;
        return _commitAndFinalize(
            hooks,
            DockMerkle.root(routeLeaves),
            EMPTY_DOCK_ROOT,
            PARENT_PUBLISHER_KEY,
            new StageSelectorBinding[](0),
            new SignalCapability[](0)
        );
    }

    function _compactHook(
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

    function _spawnParentOrder(bytes32 readySignal) private returns (bytes32) {
        _spawnNonce += 1;
        bytes32 payload = keccak256(abi.encode("parent-order", _spawnNonce));
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](2);
        auths[0] = _auth(PARENT_STAGE, SIGNAL_START, address(this));
        auths[1] = _auth(PARENT_STAGE, readySignal, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(SIGNAL_START);
        trigger.planId = parentPlanId;
        trigger.payloadHash = payload;
        trigger.idempotencyKey = keccak256(abi.encode("parent-birth", payload));
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)), _noAttribution()
        );
        bytes32 orderId = machine.triggerOrderIdFor(parentPlanId, PARENT_STAGE, SIGNAL_START, payload);
        machine.submitSignal(
            parentPlanId,
            orderId,
            PARENT_STAGE,
            readySignal,
            PAYLOAD,
            bytes32(uint256(0x100 + _spawnNonce)),
            _noAttribution()
        );
        return orderId;
    }

    function _spawnTargetOrder(bytes32 payload) private returns (bytes32) {
        return _spawnTargetOrderBy(payload, address(this));
    }

    function _spawnTargetOrderBy(bytes32 payload, address creator) private returns (bytes32) {
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](3);
        auths[0] = _auth(TARGET_BIRTH_SOURCE, TARGET_BIRTH_SIGNAL, address(this));
        auths[1] = _auth(TARGET_SOURCE, TARGET_SIGNAL, address(this));
        auths[2] = _auth(TARGET_INPUT_SOURCE, TARGET_INPUT_SIGNAL, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(TARGET_BIRTH_SIGNAL);
        trigger.planId = targetPlanId;
        trigger.creator = creator;
        trigger.triggerHookId = TARGET_BIRTH_HOOK;
        trigger.triggerStageId = TARGET_STAGE;
        trigger.sourceId = TARGET_BIRTH_SOURCE;
        trigger.payloadHash = payload;
        trigger.idempotencyKey = keccak256(abi.encode("target-order", payload));
        machine.triggerOrderFromOutsideFor(
            trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)), _birthAttribution(trigger)
        );
        return machine.triggerOrderIdFor(targetPlanId, TARGET_BIRTH_SOURCE, TARGET_BIRTH_SIGNAL, payload);
    }

    function _establishTargetFact(bytes32 targetOrder) private {
        machine.submitSignal(
            targetPlanId,
            targetOrder,
            TARGET_SOURCE,
            TARGET_SIGNAL,
            TARGET_FACT_PAYLOAD,
            bytes32(uint256(0x99)),
            _factAttributionFor(targetPlanId, TARGET_SOURCE, TARGET_SIGNAL)
        );
    }

    function _assignControlExecutor(bytes32 targetOrder, address executor) private {
        UVPStagePatchModule.StageExecutorPatch memory patch = UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: TARGET_CONTROL_STAGE,
            targetStageId: TARGET_CONTROL_STAGE,
            executor: executor,
            role: keccak256("executor"),
            executorMetadataHash: bytes32(uint256(0xE1)),
            mode: EXECUTOR_PATCH_MODE_ASSIGN,
            previousExecutor: address(0),
            authorizationsHash: _authsHashLocal(new IUVPStateMachineCore.SignalAuthorization[](0)),
            patchHash: keccak256("control-executor-patch"),
            patchNonce: 1,
            metadataURI: "uvp-eth://attach-test-patch"
        });
        stagePatch.applyStageExecutorPatch(
            targetPlanId,
            targetOrder,
            patch,
            _selectorBindingProof(targetPlanId, TARGET_CONTROL_STAGE),
            _executorCandidateProof(targetPlanId, TARGET_CONTROL_STAGE, patch.executor),
            new IUVPStateMachineCore.SignalAuthorization[](0)
        );
    }

    struct AttachRoute {
        bytes32 routeId;
        bytes32 routeHash;
        bytes32 localStageId;
        bytes32 localHookId;
        bytes32 targetCandidatesRoot;
    }

    function execRoute() private view returns (AttachRoute memory) {
        return AttachRoute({
            routeId: execRouteId,
            routeHash: attachRouteHash,
            localStageId: PARENT_EXEC_STAGE,
            localHookId: PARENT_EXEC_HOOK,
            targetCandidatesRoot: bytes32(0)
        });
    }

    function dynRoute() private view returns (AttachRoute memory) {
        return AttachRoute({
            routeId: dynRouteId,
            routeHash: dynRouteHash,
            localStageId: PARENT_DYN_STAGE,
            localHookId: PARENT_DYN_HOOK,
            targetCandidatesRoot: candidatesRoot
        });
    }

    function _attach(AttachRoute memory route, bytes32 parentOrder, bytes32 targetOrder) private returns (bool) {
        return _attachWithProof(route, parentOrder, targetOrder, _attachInterfaceProof());
    }

    function _attachWithPermit(
        AttachRoute memory route,
        bytes32 parentOrder,
        bytes32 targetOrder,
        UVPDockingModule.EntrancePermitV2 memory permit
    ) private returns (bool) {
        return _attachWithArgs(_requestFor(route, parentOrder, targetOrder), _attachInterfaceProof(), permit);
    }

    function _attachWithProof(
        AttachRoute memory route,
        bytes32 parentOrder,
        bytes32 targetOrder,
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof
    ) private returns (bool) {
        return _attachWithArgs(_requestFor(route, parentOrder, targetOrder), proof, _permitEmpty());
    }

    function _attachRaw(UVPDockingModule.AttachDockRequestV1 memory request) private returns (bool) {
        return _attachWithArgs(request, _attachInterfaceProof(), _permitEmpty());
    }

    function _attachWithArgs(
        UVPDockingModule.AttachDockRequestV1 memory request,
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof,
        UVPDockingModule.EntrancePermitV2 memory permit
    ) private returns (bool) {
        UVPDockingModule.AttachInputBindingArg[] memory inputs;
        UVPDockingModule.DockOutputBindingArg[] memory outputs;
        if (request.targetCandidatesRoot != bytes32(0)) {
            inputs = new UVPDockingModule.AttachInputBindingArg[](0);
            outputs = new UVPDockingModule.DockOutputBindingArg[](0);
        } else {
            inputs = _attachInputs(PARENT_EXEC_HOOK);
            outputs = _attachOutputs();
        }
        return docking.attachDockedOrder(
            request, _routeProofFor(request.routeHash), proof, inputs, outputs, permit, _outputAttributionsFor(outputs)
        );
    }

    function _requestFor(AttachRoute memory route, bytes32 parentOrder, bytes32 targetOrder)
        private
        view
        returns (UVPDockingModule.AttachDockRequestV1 memory)
    {
        UVPDockingModule.AttachDockRequestV1 memory request =
            _baseRequest(route.routeId, route.routeHash, route.localStageId, parentOrder, targetOrder);
        request.targetCandidatesRoot = route.targetCandidatesRoot;
        return request;
    }

    function _execRequest(bytes32 parentOrder, bytes32 targetOrder)
        private
        view
        returns (UVPDockingModule.AttachDockRequestV1 memory)
    {
        return _baseRequest(execRouteId, attachRouteHash, PARENT_EXEC_STAGE, parentOrder, targetOrder);
    }

    function _dynRequest(bytes32 parentOrder, bytes32 targetOrder)
        private
        view
        returns (UVPDockingModule.AttachDockRequestV1 memory)
    {
        UVPDockingModule.AttachDockRequestV1 memory request =
            _baseRequest(dynRouteId, dynRouteHash, PARENT_DYN_STAGE, parentOrder, targetOrder);
        request.targetCandidatesRoot = candidatesRoot;
        return request;
    }

    function _baseRequest(
        bytes32 routeIdWord,
        bytes32 routeHash,
        bytes32 stageId,
        bytes32 parentOrder,
        bytes32 targetOrder
    ) private view returns (UVPDockingModule.AttachDockRequestV1 memory) {
        return UVPDockingModule.AttachDockRequestV1({
            dockInstanceId: _instanceIdOf(routeIdWord, routeHash, parentOrder, targetOrder),
            localPlanId: parentPlanId,
            localOrderId: parentOrder,
            localStageId: stageId,
            localDefinitionRefHash: localDefinitionRef,
            routeId: routeIdWord,
            routeHash: routeHash,
            interfaceNameId: INTERFACE_NAME_ID,
            targetUidId: TARGET_UID_ID,
            targetDefinitionRefHash: targetDefinitionRef,
            targetPlanId: targetPlanId,
            linkedOrderId: targetOrder,
            targetStageId: TARGET_STAGE,
            parentDepth: 0,
            targetCandidatesRoot: bytes32(0)
        });
    }

    function _instanceIdOf(bytes32 routeIdWord, bytes32 routeHash, bytes32 parentOrder, bytes32 targetOrder)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                parentPlanId,
                localDefinitionRef,
                parentOrder,
                routeIdWord,
                routeHash,
                uint256(1),
                INTERFACE_NAME_ID,
                targetPlanId,
                targetOrder
            )
        );
    }

    function _attachInstanceId(bytes32 parentOrder, bytes32 routeHash, bytes32 targetOrder)
        private
        view
        returns (bytes32)
    {
        bytes32 routeIdWord = routeHash == attachRouteHash ? execRouteId : dynRouteId;
        return _instanceIdOf(routeIdWord, routeHash, parentOrder, targetOrder);
    }

    function _attachInterfaceProof() private view returns (UVPDockingModule.DockAttachInterfaceProofV1 memory) {
        return UVPDockingModule.DockAttachInterfaceProofV1({
            commitment: UVPDockingModule.DockInterfaceCommitmentV2({
                orderModesWord: 2,
                inputsRoot: evidenceInputsRoot,
                outputsRoot: evidenceOutputsRoot
            }),
            interfaceProof: new bytes32[](0),
            candidateProof: _merkleProofForLeaves(targetCandidateLeaf)
        });
    }

    function _attachInputs(bytes32 localHookId) private view returns (UVPDockingModule.AttachInputBindingArg[] memory) {
        UVPDockingModule.AttachInputBindingArg[] memory inputs = new UVPDockingModule.AttachInputBindingArg[](1);
        inputs[0] = UVPDockingModule.AttachInputBindingArg({
            localHookId: localHookId,
            portKey: AMEND_PORT,
            targetSourceId: TARGET_INPUT_SOURCE,
            targetSignalId: TARGET_INPUT_SIGNAL,
            bindingHash: amendInputBinding,
            targetHookId: TARGET_RECEIVE_HOOK,
            portProof: amendPortProof
        });
        return inputs;
    }

    function _attachOutputs() private view returns (UVPDockingModule.DockOutputBindingArg[] memory) {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = new UVPDockingModule.DockOutputBindingArg[](2);
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: DONE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: doneOutputBinding,
            portProof: donePortProof
        });
        outputs[1] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_PROGRESS_SOURCE,
            localSignalId: LOCAL_PROGRESS_SIGNAL,
            portKey: PROGRESS_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            bindingHash: progressOutputBinding,
            portProof: progressPortProof
        });
        return outputs;
    }

    function _routeProofFor(bytes32 routeHash) private view returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = routeHash == attachRouteHash ? dynRouteHash : attachRouteHash;
        return proof;
    }

    function _permitEmpty() private pure returns (UVPDockingModule.EntrancePermitV2 memory) {
        return UVPDockingModule.EntrancePermitV2({nonce: 0, deadline: 0, signature: ""});
    }

    function _attachPermitSigned(bytes32 instance, bytes32 parentOrder, bytes32 targetOrder, uint256 nonce)
        private
        returns (UVPDockingModule.EntrancePermitV2 memory)
    {
        UVPDockingModule.EntrancePermitV2 memory permit;
        permit.nonce = nonce;
        permit.deadline = block.timestamp + 1 hours;
        bytes32 digest = docking.attachPermitDigest(
            targetPlanId,
            targetOrder,
            INTERFACE_NAME_ID,
            parentPlanId,
            attachRouteHash,
            instance,
            permit.nonce,
            permit.deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TARGET_PUBLISHER_KEY, digest);
        permit.signature = abi.encodePacked(r, s, v);
        return permit;
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
        bytes32[] candidateLeaves;
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
        UVPStateMachine.ExecutorCandidate[] memory candidates =
            new UVPStateMachine.ExecutorCandidate[](hooks.length * 2);
        uint256 candidateCount;
        for (uint256 i = 0; i < hooks.length; i++) {
            candidates[candidateCount++] =
                UVPStateMachine.ExecutorCandidate({stageId: hooks[i].stageId, executor: EXECUTOR_CONSENTER});
            candidates[candidateCount++] =
                UVPStateMachine.ExecutorCandidate({stageId: hooks[i].stageId, executor: address(this)});
        }
        bytes32[] memory candidateLeaves = new bytes32[](candidateCount);
        for (uint256 i = 0; i < candidateCount; i++) {
            candidateLeaves[i] = keccak256(
                abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, candidates[i].stageId, candidates[i].executor)
            );
        }
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(leaves),
            dockRoutesRoot: dockRoutesRoot,
            dockInterfaceRoot: dockInterfaceRoot,
            executorCandidatesRoot: DockMerkle.root(candidateLeaves),
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
        bytes32 planId = machine.commitPlan(commit, hooks, candidates, abi.encodePacked(r, s, v));
        CapabilityTables storage tables = _capabilityTables[planId];
        tables.bindings = selectorBindings;
        tables.capabilities = signalCapabilities;
        tables.sortedLeaves = _sortedUnique(leaves);
        tables.candidateLeaves = _sortedUnique(candidateLeaves);
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

    function _pairOf(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return left <= right ? keccak256(abi.encodePacked(left, right)) : keccak256(abi.encodePacked(right, left));
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

    function _amendInputAttribution() private view returns (IUVPStateMachineCore.FactAttribution memory) {
        return _coreFactAttributionFor(targetPlanId, TARGET_INPUT_SOURCE, TARGET_INPUT_SIGNAL);
    }

    function _executorCandidateProof(bytes32 planId, bytes32 stageId, address executor)
        private
        view
        returns (bytes32[] memory proof)
    {
        bytes32[] memory sorted = _capabilityTables[planId].candidateLeaves;
        bytes32 leaf = keccak256(abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, stageId, executor));
        proof = _merkleProofFor(sorted, leaf);
    }

    function _selectorBindingProof(bytes32 planId, bytes32 stageId)
        private
        view
        returns (IUVPStateMachineCore.SelectorBindingProof memory)
    {
        CapabilityTables storage tables = _capabilityTables[planId];
        bytes32 leaf = keccak256(abi.encode(SELECTOR_BINDING_LEAF_DOMAIN, stageId, stageId));
        return IUVPStateMachineCore.SelectorBindingProof({
            selectorStageId: stageId, proof: _merkleProofFor(tables.sortedLeaves, leaf)
        });
    }

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
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

    function _outputAttributionsFor(UVPDockingModule.DockOutputBindingArg[] memory outputs)
        private
        view
        returns (IUVPStateMachineCore.FactAttribution[] memory attributions)
    {
        CapabilityTables storage tables = _capabilityTables[targetPlanId];
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

    function _outsideTrigger(bytes32 signalId) private returns (UVPStateMachine.TriggerOrderFromOutsideRequest memory) {
        return UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: bytes32(0),
            creator: address(this),
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

    function _single(bytes32 leaf) private pure returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        return leaves;
    }
}
