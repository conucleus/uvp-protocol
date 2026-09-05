// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";
import {IUVPPlanMetadataModule} from "../src/interfaces/IUVPPlanMetadataModule.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";

/// @title Zhixu Dock committed-route 测试
/// @dev 覆盖：happy path（open→input→callback）、身份确定性、错误 proof
///      拒绝、原子性/幂等、碰撞隔离、permissionless liveness、深度上限、
///      permit 签名/错签者拒绝。
interface DockVm {
    struct NoArgs {
        uint256 placeholder;
    }

    function addr(uint256 privateKey) external returns (address keyAddr);
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
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

    // 该 forge 版本的 expectRevert(bytes4) 不匹配带参 custom error，
    // 统一走完整编码数据。
    function _expect(bytes memory data) internal {
        vm.expectRevert(data);
    }
    uint8 private constant FLAG_MINT = 1;
    uint8 private constant FLAG_DOCK = 2;
    uint8 private constant FLAG_EMIT_READY = 4;

    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 metadataHash,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_TYPEHASH = keccak256(
        "UVPStateMachineSignal(bytes32 planId,bytes32 orderId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );

    bytes32 private constant DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V1");
    bytes32 private constant DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V1");
    bytes32 private constant DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V1");
    bytes32 private constant DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V1");
    bytes32 private constant DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V1");
    bytes32 private constant DOMAIN_DOCK_ORDER = keccak256("UVP_DOCK_ORDER_V1");
    bytes32 private constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");

    bytes32 private constant PARENT_START_HOOK = keccak256("parent.start#START");
    bytes32 private constant PARENT_STAGE = keccak256("parent.start");
    bytes32 private constant PARENT_EXEC_HOOK = keccak256("parent.exec#EXECUTE");
    bytes32 private constant PARENT_EXEC_STAGE = keccak256("parent.exec");
    bytes32 private constant PARENT_CANCEL_HOOK = keccak256("parent.exec#CANCEL");
    bytes32 private constant SIGNAL_START = keccak256("start");
    bytes32 private constant SIGNAL_EXEC = keccak256("exec");

    bytes32 private constant TARGET_ENTRANCE_HOOK = keccak256("pay.init#DOCK_EXECUTE");
    bytes32 private constant TARGET_MINT_HOOK = keccak256("pay.init#MINT");
    bytes32 private constant TARGET_STAGE = keccak256("pay.init");
    bytes32 private constant TARGET_HOOK_NAME = keccak256("DOCK_EXECUTE");
    bytes32 private constant TARGET_SOURCE = keccak256("payment");
    bytes32 private constant TARGET_SIGNAL = keccak256("pay.init.execute");
    bytes32 private constant TARGET_CANCEL_SIGNAL = keccak256("pay.control.cancel");
    bytes32 private constant TARGET_OUT_SOURCE = keccak256("payment");
    bytes32 private constant TARGET_OUT_SIGNAL = keccak256("pay.init.done");
    bytes32 private constant LOCAL_MAPPED_SOURCE = keccak256("buyer");
    bytes32 private constant LOCAL_MAPPED_SIGNAL = keccak256("parent.exec.str");

    bytes32 private constant ENTRANCE_PORT = keccak256("execute");
    bytes32 private constant CANCEL_PORT = keccak256("cancel");
    bytes32 private constant DONE_PORT = keccak256("done");
    bytes32 private constant SOURCE_SEAM = keccak256("payment");
    bytes32 private constant TARGET_ARTIFACT = keccak256("target-artifact");
    bytes32 private constant PAYLOAD = bytes32(uint256(0xBEEF));
    bytes32 private constant SOURCE_FACT_SET = keccak256("fact-set");
    bytes32 private constant CANCEL_FACT_SET = keccak256("cancel-fact-set");

    uint256 private constant PARENT_PUBLISHER_KEY = 0xA11CE;
    uint256 private constant SUBMITTER_KEY = 0x51;
    uint256 private constant CHILD_KEY = 0xC41D;
    uint256 private constant TARGET_PUBLISHER_KEY = 0xB0B;
    address private constant ORDER_CREATOR = address(0xC0C0);
    address private constant KEEPER = address(0x5EED1);
    // 一事一单：outside 触发订单 id 由合约按出生事实派生；父 plan 注册后
    // 在 setUp 里镜像同一公式（dockInstanceId preimage 依赖父订单 id）。
    bytes32 private PARENT_ORDER_ID;

    UVPStateMachine private machine;
    UVPDockingModule private docking;
    address private childSubmitter;
    bytes32 private localDefinitionRef = keccak256("parent-definition-ref");
    bytes32 private targetDefinitionRef = keccak256("target-definition-ref");

    bytes32 private parentPlanId;
    bytes32 private targetPlanId;
    bytes32 private permitTargetPlanId;
    bytes32 private runtimeDomain;

    // open 路由派生量
    bytes32 private routeId;
    bytes32 private entranceBinding;
    bytes32 private cancelBinding;
    bytes32 private outputBinding;
    bytes32 private inputsRoot;
    bytes32 private outputsRoot;
    bytes32 private openRouteHash;
    bytes32 private dockInstanceId;
    bytes32 private linkedOrderId;
    bytes32 private openLeaf;
    bytes32 private openInterfaceRoot;
    bytes32 private permitLeaf;
    bytes32 private permitInterfaceRoot;
    bytes32 private permitRouteHash;
    bytes32 private permitDockInstanceId;
    bytes32 private permitLinkedOrderId;

    function setUp() public {
        childSubmitter = vm.addr(CHILD_KEY);
        machine = _newMachine();
        docking = _docking();
        runtimeDomain = keccak256(abi.encode(DOMAIN_RUNTIME_EIP155, block.chainid, address(machine)));
        _computeStaticRouteParts();
        targetPlanId = _registerTargetPlan(openInterfaceRoot);
        permitTargetPlanId = _registerTargetPlan(permitInterfaceRoot);
        _rebindRouteHashes();
        // 父 plan 的 dockRoutesRoot 必须提交重绑后的 routeHash。
        parentPlanId = _registerParentPlan();
        PARENT_ORDER_ID = machine.triggerOrderIdFor(parentPlanId, PARENT_STAGE, SIGNAL_START, PAYLOAD);
        // dockInstanceId 的身份域包含 localPlanId，只有父 plan 注册后才能
        // 计算最终的实例 ID。
        _rebindDockInstanceIds();
        _spawnParentOrder();
    }

    // ------------------------------------------------------------------
    // happy path
    // ------------------------------------------------------------------

    function testOpenCreatesIndependentChildAtomically() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        (, bytes32 localOrder,,,,,,,, bool exists) = docking.getActiveDock(dockInstanceId);
        assertTrue(exists);
        assertEq(localOrder, PARENT_ORDER_ID);
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
        // 独立子订单身份。
        assertFalse(linkedOrderId == PARENT_ORDER_ID);
        // entrance fact 写入 + 目标 dock 出生 hook Ready。
        (bool signalExists,,,,) = machine.getSignal(targetPlanId, linkedOrderId, TARGET_SOURCE, TARGET_SIGNAL);
        assertTrue(signalExists);
        UVPStateMachine.HookStatus status;
        bool readyEmitted;
        (status,, readyEmitted) = machine.getHookStatus(targetPlanId, linkedOrderId, TARGET_ENTRANCE_HOOK);
        assertEq(uint256(status), uint256(UVPStateMachine.HookStatus.Ready));
        assertTrue(readyEmitted);
    }

    /// A linkedOrderId is disclosed in the open calldata.  Outside trigger
    /// order ids are contract-derived from the fact (one-fact-one-order), so a
    /// permissionless MINT trigger physically cannot select the disclosed dock
    /// child id: squatting by id choice is closed at the derivation boundary.
    function testLinkedOrderNamespaceCannotBeSquatted() public {
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(TARGET_OUT_SIGNAL);
        trigger.planId = targetPlanId;
        trigger.creator = vm.addr(TARGET_PUBLISHER_KEY);
        trigger.triggerHookId = TARGET_MINT_HOOK;
        trigger.triggerStageId = TARGET_STAGE;
        trigger.sourceId = TARGET_OUT_SOURCE;
        trigger.idempotencyKey = keccak256("squat-attempt");

        // 派生 id 与披露的 dock 子单号不同——调用方没有任何字段能影响它。
        bytes32 mintedOrderId =
            machine.triggerOrderIdFor(targetPlanId, TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL, trigger.payloadHash);
        assertFalse(mintedOrderId == linkedOrderId);

        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](1);
        auths[0] = _auth(TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL, trigger.submitter);
        machine.triggerOrderFromOutsideFor(trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)));
        assertTrue(machine.orderExists(targetPlanId, mintedOrderId));
        assertFalse(machine.orderExists(targetPlanId, linkedOrderId));

        // Same fact replayed derives the same id and is idempotently rejected.
        _expect(abi.encodeWithSelector(UVPStateMachine.OrderAlreadyRegistered.selector));
        machine.triggerOrderFromOutsideFor(trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)));

        // The legitimate module path remains the only creator of a dock
        // namespace order and succeeds after the rejected front-run attempt.
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
    }

    function testOpenIsIdempotentForSameInstance() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        assertFalse(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        bytes32 key = keccak256(abi.encode(targetPlanId, linkedOrderId));
        assertEq(docking.dockByTargetOrder(key), dockInstanceId);
    }

    function testSignalInputDeliversCancelAndIsIdempotent() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        _makeCancelHookReady();
        assertTrue(docking.submitDockedInput(dockInstanceId, PARENT_CANCEL_HOOK, cancelBinding));
        (bool cancelWritten,,,,) = machine.getSignal(targetPlanId, linkedOrderId, TARGET_SOURCE, TARGET_CANCEL_SIGNAL);
        assertTrue(cancelWritten);
        assertTrue(docking.dockInputDelivered(dockInstanceId, cancelBinding));
        assertFalse(docking.submitDockedInput(dockInstanceId, PARENT_CANCEL_HOOK, cancelBinding));
    }

    function testPermissionlessCallbackWritesParentMappedFact() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        _submitTargetOutput();
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, outputBinding));
        (bool mapped,,,,) = machine.getSignal(parentPlanId, PARENT_ORDER_ID, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        assertTrue(mapped);
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(dockInstanceId, outputBinding));
    }

    function testCallbackBeforeTargetFactReverts() public {
        // noqa
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockOutputNotReady.selector, dockInstanceId, outputBinding));
        docking.submitDockedSignal(dockInstanceId, outputBinding);
    }

    // ------------------------------------------------------------------
    // 拒绝路径
    // ------------------------------------------------------------------

    function testRejectsWrongRouteProof() public {
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(0xBAD));
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, openRouteHash, bytes32(0)));
        docking.openDockedOrder(
            _openRequest(0), badProof, _openLeafData(), _openInterfaceProof(), _inputs(), _outputs(), _permitEmpty()
        );
    }

    function testRejectsTamperedRouteContent() public {
        UVPDockingModule.OpenDockRequestV1 memory request = _openRequest(0);
        request.sourceSeamId = keccak256("other-seam");
        bytes32 tamperedRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                routeId,
                targetDefinitionRef,
                TARGET_ARTIFACT,
                openInterfaceRoot,
                targetPlanId,
                uint256(0),
                keccak256("other-seam"),
                entranceBinding,
                uint256(0),
                inputsRoot,
                outputsRoot
            )
        );
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, openRouteHash, tamperedRouteHash)
        );
        docking.openDockedOrder(
            request, _openRouteProof(), _openLeafData(), _openInterfaceProof(), _inputs(), _outputs(), _permitEmpty()
        );
    }

    function testRejectsTamperedChildId() public {
        UVPDockingModule.OpenDockRequestV1 memory request = _openRequest(0);
        request.linkedOrderId = bytes32(uint256(0xE711));
        bytes32 recomputedLinked = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockRouteLeafMismatch.selector, bytes32(uint256(0xE711)), recomputedLinked
            )
        );
        docking.openDockedOrder(
            request, _openRouteProof(), _openLeafData(), _openInterfaceProof(), _inputs(), _outputs(), _permitEmpty()
        );
    }

    function testRejectsTargetPlanSubstitution() public {
        // targetPlanId 参与 routeHash preimage：keeper 把 child
        // 换挂到任何别的 plan（即使复制了同样的 interface root），routeHash
        // 重算立即失配——目标替换在 proof 层就被拒绝。
        UVPDockingModule.OpenDockRequestV1 memory request = _openRequest(0);
        request.targetPlanId = parentPlanId;
        bytes32 substitutedHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                routeId,
                targetDefinitionRef,
                TARGET_ARTIFACT,
                openInterfaceRoot,
                parentPlanId,
                uint256(0),
                SOURCE_SEAM,
                entranceBinding,
                uint256(0),
                inputsRoot,
                outputsRoot
            )
        );
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, openRouteHash, substitutedHash));
        docking.openDockedOrder(
            request, _openRouteProof(), _openLeafData(), _openInterfaceProof(), _inputs(), _outputs(), _permitEmpty()
        );
    }

    function testRejectsNonEntranceLeafKind() public {
        UVPDockingModule.DockInterfaceLeafV1 memory leaf = _openLeafData();
        leaf.kind = 0;
        bytes32 recomputedKindLeaf = keccak256(
            abi.encode(
                DOMAIN_INTERFACE_INPUT,
                targetDefinitionRef,
                leaf.portKey,
                uint256(0),
                leaf.hookKey,
                leaf.sourceId,
                leaf.signalId,
                uint256(0)
            )
        );
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockInterfaceLeafMismatch.selector, openLeaf, recomputedKindLeaf)
        );
        docking.openDockedOrder(
            _openRequest(0), _openRouteProof(), leaf, _openInterfaceProof(), _inputs(), _outputs(), _permitEmpty()
        );
    }

    function testRejectsDepthBeyondLimit() public {
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthMismatch.selector, 8, 0));
        docking.openDockedOrder(
            _openRequest(8),
            _openRouteProof(),
            _openLeafData(),
            _openInterfaceProof(),
            _inputs(),
            _outputs(),
            _permitEmpty()
        );
    }

    function testRejectsParentDepthMismatch() public {
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthMismatch.selector, 3, 0));
        docking.openDockedOrder(
            _openRequest(3),
            _openRouteProof(),
            _openLeafData(),
            _openInterfaceProof(),
            _inputs(),
            _outputs(),
            _permitEmpty()
        );
    }

    function testRejectsSecondChildForSameRouteInstance() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        // 篡改 child ID 尝试开第二单：身份推导先失败。
        UVPDockingModule.OpenDockRequestV1 memory request = _openRequest(0);
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
                openRouteHash
            )
        );
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockRouteLeafMismatch.selector, bytes32(uint256(0x0DD0)), recomputedInstance
            )
        );
        docking.openDockedOrder(
            request, _openRouteProof(), _openLeafData(), _openInterfaceProof(), _inputs(), _outputs(), _permitEmpty()
        );
    }

    // ------------------------------------------------------------------
    // permit
    // ------------------------------------------------------------------

    function testPermitHappyPath() public {
        UVPDockingModule.OpenDockRequestV1 memory request = _permitRequest();
        UVPDockingModule.DockInterfaceLeafV1 memory leaf = _permitLeafData();
        UVPDockingModule.EntrancePermitV1 memory permit = _permitSigned(1);
        assertTrue(
            docking.openDockedOrder(
                request, _permitRouteProof(), leaf, _permitInterfaceProof(), _inputs(), _outputs(), permit
            )
        );
        assertTrue(machine.orderExists(permitTargetPlanId, permitLinkedOrderId));
    }

    function testPermitReplayReturnsFalseAfterDockExists() public {
        UVPDockingModule.OpenDockRequestV1 memory request = _permitRequest();
        UVPDockingModule.EntrancePermitV1 memory permit = _permitSigned(1);
        assertTrue(
            docking.openDockedOrder(
                request, _permitRouteProof(), _permitLeafData(), _permitInterfaceProof(), _inputs(), _outputs(), permit
            )
        );

        // The idempotent path is checked before permit nonce validation. A
        // replay therefore returns false instead of reverting on the consumed
        // nonce.
        assertFalse(
            docking.openDockedOrder(
                request, _permitRouteProof(), _permitLeafData(), _permitInterfaceProof(), _inputs(), _outputs(), permit
            )
        );
        assertEq(docking.usedEntrancePermitNonce(request.dockInstanceId), 1);
    }

    function testPermitWrongSignerRejected() public {
        UVPDockingModule.OpenDockRequestV1 memory request = _permitRequest();
        UVPDockingModule.DockInterfaceLeafV1 memory leaf = _permitLeafData();
        UVPDockingModule.EntrancePermitV1 memory permit = _permitSigned(1);
        bytes32 digest = _permitDigestOnModule(request, permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        permit.signature = abi.encodePacked(r, s, v);
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockPermitInvalidSigner.selector, vm.addr(TARGET_PUBLISHER_KEY), vm.addr(0xDEAD)
            )
        );
        docking.openDockedOrder(
            request, _permitRouteProof(), leaf, _permitInterfaceProof(), _inputs(), _outputs(), permit
        );
    }

    function testPermitExpiredRejected() public {
        UVPDockingModule.OpenDockRequestV1 memory request = _permitRequest();
        UVPDockingModule.EntrancePermitV1 memory permit = _permitSigned(1);
        vm.warp(block.timestamp + 2 hours);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockPermitExpired.selector, permit.deadline));
        docking.openDockedOrder(
            request, _permitRouteProof(), _permitLeafData(), _permitInterfaceProof(), _inputs(), _outputs(), permit
        );
    }

    // ------------------------------------------------------------------
    // 碰撞隔离 + gas
    // ------------------------------------------------------------------

    function testCrossPlanBareOrderIdCollisionIsolated() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        assertTrue(machine.orderExists(parentPlanId, PARENT_ORDER_ID));
        assertFalse(machine.orderExists(targetPlanId, PARENT_ORDER_ID));
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
    }

    function testGasOpenDockedOrder() public {
        docking.openDockedOrder(
            _openRequest(0),
            _openRouteProof(),
            _openLeafData(),
            _openInterfaceProof(),
            _inputs(),
            _outputs(),
            _permitEmpty()
        );
    }

    function testGasSubmitDockedInput() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        _makeCancelHookReady();
        docking.submitDockedInput(dockInstanceId, PARENT_CANCEL_HOOK, cancelBinding);
    }

    function testGasSubmitDockedSignal() public {
        assertTrue(
            docking.openDockedOrder(
                _openRequest(0),
                _openRouteProof(),
                _openLeafData(),
                _openInterfaceProof(),
                _inputs(),
                _outputs(),
                _permitEmpty()
            )
        );
        _submitTargetOutput();
        docking.submitDockedSignal(dockInstanceId, outputBinding);
    }

    // ------------------------------------------------------------------
    // setup
    // ------------------------------------------------------------------

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
        sm.setLens(address(0x1234));
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
                DOMAIN_INPUT_BINDING, routeId, PARENT_EXEC_HOOK, ENTRANCE_PORT, TARGET_SOURCE, TARGET_SIGNAL, uint256(1)
            )
        );
        cancelBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                routeId,
                PARENT_CANCEL_HOOK,
                CANCEL_PORT,
                TARGET_SOURCE,
                TARGET_CANCEL_SIGNAL,
                uint256(0)
            )
        );
        outputBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeId,
                LOCAL_MAPPED_SOURCE,
                LOCAL_MAPPED_SIGNAL,
                DONE_PORT,
                TARGET_OUT_SOURCE,
                TARGET_OUT_SIGNAL,
                uint256(1)
            )
        );
        bytes32[] memory inputLeaves = new bytes32[](2);
        inputLeaves[0] = entranceBinding;
        inputLeaves[1] = cancelBinding;
        inputsRoot = DockMerkle.root(inputLeaves);
        outputsRoot = DockMerkle.root(_single(outputBinding));

        openLeaf = keccak256(
            abi.encode(
                DOMAIN_INTERFACE_INPUT,
                targetDefinitionRef,
                ENTRANCE_PORT,
                uint256(1),
                TARGET_ENTRANCE_HOOK,
                TARGET_SOURCE,
                TARGET_SIGNAL,
                uint256(0)
            )
        );
        permitLeaf = keccak256(
            abi.encode(
                DOMAIN_INTERFACE_INPUT,
                targetDefinitionRef,
                ENTRANCE_PORT,
                uint256(1),
                TARGET_ENTRANCE_HOOK,
                TARGET_SOURCE,
                TARGET_SIGNAL,
                uint256(1)
            )
        );
        openInterfaceRoot = DockMerkle.root(_single(openLeaf));
        permitInterfaceRoot = DockMerkle.root(_single(permitLeaf));

        openRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                routeId,
                targetDefinitionRef,
                TARGET_ARTIFACT,
                openInterfaceRoot,
                bytes32(0), // targetPlanId 占位：setUp 后回填真实 targetPlanId
                uint256(0),
                SOURCE_SEAM,
                entranceBinding,
                uint256(0),
                inputsRoot,
                outputsRoot
            )
        );
        permitRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                routeId,
                targetDefinitionRef,
                TARGET_ARTIFACT,
                permitInterfaceRoot,
                bytes32(0),
                uint256(0),
                SOURCE_SEAM,
                entranceBinding,
                uint256(1),
                inputsRoot,
                outputsRoot
            )
        );
        dockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                bytes32(0),
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                openRouteHash
            )
        );
        linkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        permitDockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                bytes32(0),
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                permitRouteHash
            )
        );
        permitLinkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, permitDockInstanceId, targetDefinitionRef)))
            | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function _registerTargetPlan(bytes32 interfaceRoot) private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.Signal,
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
        // Keep a MINT trigger in the target plan so the namespace regression
        // test exercises the real permissionless front-run surface.
        // 词表内事实（TARGET_OUT_SOURCE::TARGET_OUT_SIGNAL，relation 0）：
        // outside 触发的出生事实必须在 plan capability 词表内。
        UVPStateMachine.Instruction[] memory mintInstructions = new UVPStateMachine.Instruction[](1);
        mintInstructions[0] = UVPStateMachine.Instruction({
            op: UVPStateMachine.InstructionOp.Signal,
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
        // 目标定义自身治理：selector 自绑定 + 输出能力（子订单 executor
        // 经 executor patch 获得输出提交权，不经 open 注入授权）。
        IUVPPlanMetadataModule.StageSelectorBinding[] memory bindings =
            new IUVPPlanMetadataModule.StageSelectorBinding[](1);
        bindings[0] =
            IUVPPlanMetadataModule.StageSelectorBinding({selectorStageId: TARGET_STAGE, targetStageId: TARGET_STAGE});
        IUVPPlanMetadataModule.SignalCapability[] memory capabilities = new IUVPPlanMetadataModule.SignalCapability[](1);
        capabilities[0] = IUVPPlanMetadataModule.SignalCapability({
            stageId: TARGET_STAGE,
            targetSourceId: TARGET_OUT_SOURCE,
            signalId: TARGET_OUT_SIGNAL,
            targetOrderRelation: 0 // SIGNAL_TARGET_CURRENT_ORDER
        });
        return _commitAndFinalize(hooks, EMPTY_DOCK_ROOT, interfaceRoot, TARGET_PUBLISHER_KEY, bindings, capabilities);
    }

    function _registerParentPlan() private returns (bytes32) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _parentHook(
            PARENT_START_HOOK, PARENT_STAGE, keccak256("START"), FLAG_MINT | FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_START
        );
        hooks[1] = _parentHook(
            PARENT_EXEC_HOOK, PARENT_EXEC_STAGE, keccak256("EXECUTE"), FLAG_EMIT_READY, PARENT_STAGE, SIGNAL_EXEC
        );
        hooks[2] = _parentHook(
            PARENT_CANCEL_HOOK,
            PARENT_EXEC_STAGE,
            keccak256("CANCEL"),
            FLAG_EMIT_READY,
            PARENT_STAGE,
            keccak256("cancel")
        );
        bytes32[] memory routeLeaves = new bytes32[](2);
        routeLeaves[0] = openRouteHash;
        routeLeaves[1] = permitRouteHash;
        return _commitAndFinalize(
            hooks,
            DockMerkle.root(routeLeaves),
            EMPTY_DOCK_ROOT,
            PARENT_PUBLISHER_KEY,
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0)
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
            op: UVPStateMachine.InstructionOp.Signal, sourceId: sourceId, signalId: signalId, arity: 0, delaySeconds: 0
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

    /// targetPlanId 参与 routeHash preimage——注册出真实 plan id 后重算。
    function _rebindRouteHashes() private {
        openRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                routeId,
                targetDefinitionRef,
                TARGET_ARTIFACT,
                openInterfaceRoot,
                targetPlanId,
                uint256(0),
                SOURCE_SEAM,
                entranceBinding,
                uint256(0),
                inputsRoot,
                outputsRoot
            )
        );
        permitRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                routeId,
                targetDefinitionRef,
                TARGET_ARTIFACT,
                permitInterfaceRoot,
                permitTargetPlanId,
                uint256(0),
                SOURCE_SEAM,
                entranceBinding,
                uint256(1),
                inputsRoot,
                outputsRoot
            )
        );
        dockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                parentPlanId,
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                openRouteHash
            )
        );
        linkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        permitDockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                parentPlanId,
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                permitRouteHash
            )
        );
        permitLinkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, permitDockInstanceId, targetDefinitionRef)))
            | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function _rebindDockInstanceIds() private {
        dockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                parentPlanId,
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                openRouteHash
            )
        );
        linkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        permitDockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                parentPlanId,
                localDefinitionRef,
                PARENT_ORDER_ID,
                routeId,
                permitRouteHash
            )
        );
        permitLinkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, permitDockInstanceId, targetDefinitionRef)))
            | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function _spawnParentOrder() private {
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](3);
        auths[0] = _auth(PARENT_STAGE, SIGNAL_START, address(this));
        auths[1] = _auth(PARENT_STAGE, SIGNAL_EXEC, address(this));
        auths[2] = _auth(PARENT_STAGE, keccak256("cancel"), address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(SIGNAL_START);
        trigger.planId = parentPlanId;
        machine.triggerOrderFromOutsideFor(trigger, auths, _sign(SUBMITTER_KEY, _outsideDigest(auths)));
        machine.submitSignal(parentPlanId, PARENT_ORDER_ID, PARENT_STAGE, SIGNAL_EXEC, PAYLOAD, bytes32(uint256(0x77)));
    }

    function _makeCancelHookReady() private {
        machine.submitSignal(
            parentPlanId, PARENT_ORDER_ID, PARENT_STAGE, keccak256("cancel"), PAYLOAD, bytes32(uint256(0x99))
        );
    }

    function _submitTargetOutput() private {
        // 目标定义自身授权流：目标 plan publisher（= 子订单 creator）作为
        // selector 指派输出 executor，能力委托使 childSubmitter 获得
        // (TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL) 提交权。
        UVPStagePatchModule.StageExecutorPatch memory patch = UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: TARGET_STAGE,
            targetStageId: TARGET_STAGE,
            executor: childSubmitter,
            role: keccak256("child-executor"),
            executorMetadataHash: bytes32(0),
            mode: bytes32("assign"), // EXECUTOR_PATCH_MODE_ASSIGN
            previousExecutor: address(0),
            approvalSourceId: bytes32(0),
            approvalSignalId: bytes32(0),
            patchHash: keccak256("child-executor-patch"),
            patchNonce: 1,
            metadataURI: ""
        });
        UVPStagePatchModule stagePatch = _stagePatchModule;
        vm.prank(vm.addr(TARGET_PUBLISHER_KEY));
        stagePatch.applyStageExecutorPatch(targetPlanId, linkedOrderId, patch);

        bytes32 digest = _signalDigest(
            targetPlanId, linkedOrderId, TARGET_OUT_SOURCE, TARGET_OUT_SIGNAL, childSubmitter, bytes32(uint256(0x88))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CHILD_KEY, digest);
        machine.submitSignalFor(
            targetPlanId,
            linkedOrderId,
            TARGET_OUT_SOURCE,
            TARGET_OUT_SIGNAL,
            PAYLOAD,
            bytes32(uint256(0x88)),
            childSubmitter,
            block.timestamp + 1 hours,
            abi.encodePacked(r, s, v)
        );
    }

    function _commitAndFinalize(
        UVPStateMachine.CompactHook[] memory hooks,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot,
        uint256 publisherKey,
        IUVPPlanMetadataModule.StageSelectorBinding[] memory selectorBindings,
        IUVPPlanMetadataModule.SignalCapability[] memory signalCapabilities
    ) private returns (bytes32) {
        address publisher = vm.addr(publisherKey);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            metadataHash: keccak256(abi.encode(selectorBindings, signalCapabilities)),
            dockRoutesRoot: dockRoutesRoot,
            dockInterfaceRoot: dockInterfaceRoot,
            deadline: block.timestamp + 1 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.metadataHash,
                commit.dockRoutesRoot,
                commit.dockInterfaceRoot,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherKey, digest);
        bytes32 planId = machine.commitPlan(commit, hooks, abi.encodePacked(r, s, v));
        machine.finalizePlan(planId, selectorBindings, signalCapabilities);
        return planId;
    }

    // ------------------------------------------------------------------
    // calldata builders
    // ------------------------------------------------------------------

    function _openRequest(uint8 parentDepth) private view returns (UVPDockingModule.OpenDockRequestV1 memory) {
        return UVPDockingModule.OpenDockRequestV1({
            dockInstanceId: dockInstanceId,
            localPlanId: parentPlanId,
            localOrderId: PARENT_ORDER_ID,
            localStageId: PARENT_EXEC_STAGE,
            localHookId: PARENT_EXEC_HOOK,
            localDefinitionRefHash: localDefinitionRef,
            routeId: routeId,
            routeHash: openRouteHash,
            targetDefinitionRefHash: targetDefinitionRef,
            targetArtifactHash: TARGET_ARTIFACT,
            targetInterfaceRoot: openInterfaceRoot,
            sourceSeamId: SOURCE_SEAM,
            entrancePortKey: ENTRANCE_PORT,
            entranceBindingHash: entranceBinding,
            accessPolicy: 0,
            inputsRoot: inputsRoot,
            outputsRoot: outputsRoot,
            targetPlanId: targetPlanId,
            linkedOrderId: linkedOrderId,
            targetStageId: TARGET_STAGE,
            targetHookId: TARGET_ENTRANCE_HOOK,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            parentDepth: parentDepth
        });
    }

    function _permitRequest() private view returns (UVPDockingModule.OpenDockRequestV1 memory) {
        UVPDockingModule.OpenDockRequestV1 memory request = _openRequest(0);
        request.routeHash = permitRouteHash;
        request.targetInterfaceRoot = permitInterfaceRoot;
        request.accessPolicy = 1;
        request.dockInstanceId = permitDockInstanceId;
        request.linkedOrderId = permitLinkedOrderId;
        request.targetPlanId = permitTargetPlanId;
        return request;
    }

    function _openLeafData() private view returns (UVPDockingModule.DockInterfaceLeafV1 memory) {
        return UVPDockingModule.DockInterfaceLeafV1({
            leafHash: openLeaf,
            portKey: ENTRANCE_PORT,
            kind: 1,
            hookKey: TARGET_ENTRANCE_HOOK,
            sourceId: TARGET_SOURCE,
            signalId: TARGET_SIGNAL,
            accessPolicy: 0
        });
    }

    function _permitLeafData() private view returns (UVPDockingModule.DockInterfaceLeafV1 memory) {
        return UVPDockingModule.DockInterfaceLeafV1({
            leafHash: permitLeaf,
            portKey: ENTRANCE_PORT,
            kind: 1,
            hookKey: TARGET_ENTRANCE_HOOK,
            sourceId: TARGET_SOURCE,
            signalId: TARGET_SIGNAL,
            accessPolicy: 1
        });
    }

    function _inputs() private view returns (UVPDockingModule.DockInputBindingArg[] memory) {
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](2);
        inputs[0] = UVPDockingModule.DockInputBindingArg({
            localHookId: PARENT_EXEC_HOOK,
            portKey: ENTRANCE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            kind: 1,
            bindingHash: entranceBinding
        });
        inputs[1] = UVPDockingModule.DockInputBindingArg({
            localHookId: PARENT_CANCEL_HOOK,
            portKey: CANCEL_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_CANCEL_SIGNAL,
            kind: 0,
            bindingHash: cancelBinding
        });
        return inputs;
    }

    function _outputs() private view returns (UVPDockingModule.DockOutputBindingArg[] memory) {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = new UVPDockingModule.DockOutputBindingArg[](1);
        outputs[0] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: DONE_PORT,
            targetSourceId: TARGET_OUT_SOURCE,
            targetSignalId: TARGET_OUT_SIGNAL,
            terminal: 1,
            bindingHash: outputBinding
        });
        return outputs;
    }

    function _permitEmpty() private pure returns (UVPDockingModule.EntrancePermitV1 memory) {
        return UVPDockingModule.EntrancePermitV1({nonce: 0, deadline: 0, signature: ""});
    }

    function _permitSigned(uint256 nonce) private returns (UVPDockingModule.EntrancePermitV1 memory) {
        UVPDockingModule.OpenDockRequestV1 memory request = _permitRequest();
        UVPDockingModule.EntrancePermitV1 memory permit;
        permit.nonce = nonce;
        permit.deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigestOnModule(request, permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TARGET_PUBLISHER_KEY, digest);
        permit.signature = abi.encodePacked(r, s, v);
        return permit;
    }

    function _permitDigestOnModule(
        UVPDockingModule.OpenDockRequestV1 memory request,
        UVPDockingModule.EntrancePermitV1 memory permit
    ) private view returns (bytes32) {
        return docking.entrancePermitDigest(
            request.targetPlanId,
            request.entrancePortKey,
            request.localPlanId,
            request.routeHash,
            request.dockInstanceId,
            request.linkedOrderId,
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

    function _outsideTrigger(bytes32 signalId) private returns (UVPStateMachine.TriggerOrderFromOutsideRequest memory) {
        return UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: bytes32(0), // 由调用方覆盖
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

    function _outsideDigest(UVPStateMachine.SignalAuthorization[] memory auths) private returns (bytes32) {
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(SIGNAL_START);
        trigger.planId = parentPlanId;
        return _outsideDigestFor(trigger, auths);
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

    function _signalDigest(
        bytes32 planId,
        bytes32 orderId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter,
        bytes32 idempotencyKey
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNAL_TYPEHASH,
                planId,
                orderId,
                sourceId,
                signalId,
                PAYLOAD,
                idempotencyKey,
                submitter,
                block.timestamp + 1 hours
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("UVPStateMachine"),
                keccak256("0.10"),
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
        return _siblingProof(openRouteHash, permitRouteHash);
    }

    function _permitRouteProof() private view returns (bytes32[] memory) {
        return _siblingProof(permitRouteHash, openRouteHash);
    }

    function _openInterfaceProof() private view returns (bytes32[] memory) {
        return new bytes32[](0); // 单叶树
    }

    function _permitInterfaceProof() private view returns (bytes32[] memory) {
        return new bytes32[](0); // 单叶树
    }

    function _siblingProof(bytes32 leaf, bytes32 sibling) private pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        leaf;
        return proof;
    }

    function _single(bytes32 leaf) private pure returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        return leaves;
    }
}
