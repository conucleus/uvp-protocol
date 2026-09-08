// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";
import {ECDSA} from "../src/libraries/ECDSA.sol";
import {IUVPPlanMetadataModule} from "../src/interfaces/IUVPPlanMetadataModule.sol";

/// @title Zhixu Dock committed-route 测试（preimage v2，链轨仅 new 模式）
/// @dev 覆盖：happy path（open→callback）、身份确定性、错误 proof 拒绝、
///      原子性/幂等、碰撞隔离、permissionless liveness、深度上限、
///      permit V2 签名/错签者拒绝、existing 模式哈希拒绝、接口 new 位拒绝、
///      terminal 移除后的输出交付账本（A14）。
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

    // preimage v2 域（与 PRD100_102_DESIGN.md §8 / Rust dock.rs 逐字节一致）。
    bytes32 private constant DOMAIN_DEFINITION_REF = keccak256("UVP_DEFINITION_REF_V1");
    bytes32 private constant DOMAIN_INTERFACE = keccak256("UVP_DOCK_INTERFACE_V2");
    bytes32 private constant DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V2");
    bytes32 private constant DOMAIN_INTERFACE_OUTPUT = keccak256("UVP_DOCK_INTERFACE_OUTPUT_V2");
    bytes32 private constant DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V2");
    bytes32 private constant DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V2");
    bytes32 private constant DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V2");
    bytes32 private constant DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V2");
    bytes32 private constant DOMAIN_DOCK_ORDER = keccak256("UVP_DOCK_ORDER_V1");
    bytes32 private constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant PARENT_START_HOOK = keccak256("parent.start#START");
    bytes32 private constant PARENT_STAGE = keccak256("parent.start");
    bytes32 private constant PARENT_EXEC_HOOK = keccak256("parent.exec#EXECUTE");
    bytes32 private constant PARENT_EXEC_STAGE = keccak256("parent.exec");
    bytes32 private constant SIGNAL_START = keccak256("start");
    bytes32 private constant SIGNAL_EXEC = keccak256("exec");
    // 兄弟 hook 监听、测试内永不喂入的信号（保持兄弟 hook 未就绪）。
    bytes32 private constant SIGNAL_SIBLING = keccak256("sibling");

    // 目标定义身份：uidId = keccak("zx-<32hex>")，definitionRefHash 由其派生。
    bytes32 private constant TARGET_UID_ID = keccak256("zx-a11ce00c0ffee0ddba5e5eed1c0deb0a");
    bytes32 private constant INTERFACE_NAME_ID = keccak256("production");

    bytes32 private constant TARGET_ENTRANCE_HOOK = keccak256("pay.init#DOCK_EXECUTE");
    bytes32 private constant TARGET_MINT_HOOK = keccak256("pay.init#MINT");
    bytes32 private constant TARGET_STAGE = keccak256("pay.init");
    bytes32 private constant TARGET_HOOK_NAME = keccak256("DOCK_EXECUTE");
    bytes32 private constant TARGET_SOURCE = keccak256("payment");
    bytes32 private constant TARGET_SIGNAL = keccak256("pay.init.execute");
    // outside 触发出生事实（MINT 词表用，与 entrance 事实分离）。
    bytes32 private constant TARGET_OUT_SOURCE = keccak256("payment");
    bytes32 private constant TARGET_OUT_SIGNAL = keccak256("pay.init.done");
    bytes32 private constant TARGET_OUT_STAGE = keccak256("pay.out");
    // 输出绑定回调的本地映射事实。
    bytes32 private constant LOCAL_MAPPED_SOURCE = keccak256("buyer");
    bytes32 private constant LOCAL_MAPPED_SIGNAL = keccak256("parent.exec.str");
    bytes32 private constant LOCAL_PROGRESS_SOURCE = keccak256("buyer");
    bytes32 private constant LOCAL_PROGRESS_SIGNAL = keccak256("parent.exec.progress");
    // 尚未成立的远端事实（DockOutputNotReady 拒绝路径）。
    bytes32 private constant TARGET_PENDING_SIGNAL = keccak256("pay.control.settle");

    bytes32 private constant ENTRANCE_PORT = keccak256("execute");
    bytes32 private constant DONE_PORT = keccak256("done");
    bytes32 private constant PROGRESS_OUT_PORT = keccak256("progress");
    bytes32 private constant SETTLE_PORT = keccak256("settle");
    // 接口 output 端口叶的 canonical 信号 word（叶内容只经 outputsRoot
    // membership 背书；与绑定侧事实键分属不同派生域）。
    bytes32 private constant OUT_WORD_DONE = keccak256("canonical.done");
    bytes32 private constant OUT_WORD_PROGRESS = keccak256("canonical.progress");
    bytes32 private constant OUT_WORD_SETTLE = keccak256("canonical.settle");
    // 目标接口从未宣告的端口/信号 word（F056 拒绝路径）。
    bytes32 private constant ROGUE_PORT = keccak256("rogue_port");
    bytes32 private constant ROGUE_OUT_WORD = keccak256("canonical.rogue");
    // 同阶段的兄弟 hook（EMIT_READY，但从未就绪）——F053 冒名开仓路径。
    bytes32 private constant PARENT_SIBLING_HOOK = keccak256("parent.exec#SIBLING");
    bytes32 private constant PAYLOAD = bytes32(uint256(0xBEEF));

    uint256 private constant PARENT_PUBLISHER_KEY = 0xA11CE;
    uint256 private constant SUBMITTER_KEY = 0x51;
    uint256 private constant TARGET_PUBLISHER_KEY = 0xB0B;
    address private constant ORDER_CREATOR = address(0xC0C0);
    address private constant KEEPER = address(0x5EED1);
    // 一事一单：outside 触发订单 id 由合约按出生事实派生；父 plan 注册后
    // 在 setUp 里镜像同一公式（dockInstanceId preimage 依赖父订单 id）。
    bytes32 private PARENT_ORDER_ID;

    UVPStateMachine private machine;
    UVPDockingModule private docking;
    bytes32 private localDefinitionRef = keccak256("parent-definition-ref");
    bytes32 private targetDefinitionRef = keccak256(abi.encode(DOMAIN_DEFINITION_REF, TARGET_UID_ID));

    bytes32 private parentPlanId;
    bytes32 private targetPlanId;
    bytes32 private runtimeDomain;

    // open 路由派生量
    bytes32 private routeId;
    bytes32 private entranceBinding;
    bytes32 private outputBinding;
    bytes32 private progressOutBinding;
    bytes32 private settleBinding;
    bytes32 private inputsRoot;
    bytes32 private outputsRoot;
    bytes32 private openRouteHash;
    // existing 模式哈希（同绑定、modeWord=1）：作为第二片 route 叶提交，
    // 供"链轨拒绝 existing 路由"用例锚定。
    bytes32 private existingRouteHash;
    bytes32 private dockInstanceId;
    bytes32 private linkedOrderId;
    bytes32 private openPortLeaf;
    bytes32 private interfaceLeaf;
    // 目标接口宣告的 output 端口叶（三叶树）与各绑定的 membership proof。
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
        // 父 plan 的 dockRoutesRoot 必须提交 routeHash（new + existing 两叶）。
        parentPlanId = _registerParentPlan();
        PARENT_ORDER_ID = machine.triggerOrderIdFor(parentPlanId, PARENT_STAGE, SIGNAL_START, PAYLOAD);
        // dockInstanceId 的身份域包含 localPlanId，只有父 plan 注册后才能
        // 计算最终的实例 ID。
        _rebindDockInstanceId();
        _spawnParentOrder();
    }

    // ------------------------------------------------------------------
    // happy path
    // ------------------------------------------------------------------

    function testOpenCreatesIndependentChildAtomically() public {
        assertTrue(_open());
        (, bytes32 localOrder,,,,,, bytes32 viewedInterfaceName,, bool exists) = docking.getActiveDock(dockInstanceId);
        assertTrue(exists);
        assertEq(localOrder, PARENT_ORDER_ID);
        assertEq(viewedInterfaceName, INTERFACE_NAME_ID);
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
        // UVP-08：open 即 entrance input 的一次交付——投递账本必须与链上
        // 事实一致（否则事后重放 submitDockedInput(entrance) 只会撞
        // mailbox 既有事实 DockInputConflict，账本却显示未交付）。
        assertTrue(_open());
        assertTrue(docking.dockInputDelivered(dockInstanceId, entranceBinding));
        assertFalse(docking.submitDockedInput(dockInstanceId, PARENT_EXEC_HOOK, entranceBinding));
    }

    function testSubmitDockedInputRejectsUnknownBinding() public {
        assertTrue(_open());
        vm.expectRevert(
            abi.encodeWithSelector(UVPDockingModule.DockInputNotFound.selector, dockInstanceId, bytes32(uint256(0xBAD)))
        );
        docking.submitDockedInput(dockInstanceId, PARENT_EXEC_HOOK, bytes32(uint256(0xBAD)));
    }

    function testPermissionlessCallbackWritesParentMappedFact() public {
        assertTrue(_open());
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, outputBinding));
        (bool mapped,,,,) = machine.getSignal(parentPlanId, PARENT_ORDER_ID, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        assertTrue(mapped);
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(dockInstanceId, outputBinding));
    }

    /// terminal 语义移除后没有跨输出终态闸：任意两条输出绑定各自按
    /// 交付账本独立幂等（A14：一条绑定一个事实槽位，不得复用/覆盖）。
    function testOutputDeliveriesArePerBindingIdempotentWithoutTerminalGate() public {
        assertTrue(_open());
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, outputBinding));
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(dockInstanceId, outputBinding));
        // 另一条输出绑定读同一远端事实、写不同本地事实：仍可交付。
        vm.prank(KEEPER);
        assertTrue(docking.submitDockedSignal(dockInstanceId, progressOutBinding));
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedSignal(dockInstanceId, progressOutBinding));
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
        docking.submitDockedSignal(dockInstanceId, settleBinding);
    }

    // ------------------------------------------------------------------
    // 拒绝路径
    // ------------------------------------------------------------------

    function testRejectsWrongRouteProof() public {
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = bytes32(uint256(0xBAD));
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, openRouteHash, bytes32(0)));
        _openWith(badProof, _interfaceProof());
    }

    /// preimage word 篡改在绑定重算处即失配（接口名进每条绑定哈希）。
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

    /// 自洽重哈希的输出篡改也会换掉 outputsRoot——routeHash 重算失配。
    function testRejectsSelfHashedOutputTamper() public {
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
        bytes32[] memory outputLeaves = new bytes32[](3);
        outputLeaves[0] = outputs[0].bindingHash;
        outputLeaves[1] = outputs[1].bindingHash;
        outputLeaves[2] = outputs[2].bindingHash;
        bytes32 tamperedRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
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
            _openRequest(0), _openRouteProof(), _interfaceProof(), _inputs(), outputs, _permitEmpty()
        );
    }

    /// 链轨只支持 new：existing 模式（modeWord=1）的 routeHash 无法通过
    /// 重算（重算钉 modeWord=0），显式失配拒绝（A05）。
    function testRejectsExistingModeRoute() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        request.routeHash = existingRouteHash;
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, existingRouteHash, openRouteHash)
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
                UVPDockingModule.DockRouteLeafMismatch.selector, bytes32(uint256(0xE711)), recomputedLinked
            )
        );
        _openRaw(request);
    }

    /// 接口承诺按 keccak(uid) 寻址、route 按 definitionRefHash 寻址——
    /// 两者必须同源：uid 换绑会让 child 开进另一身份的接口树。
    function testRejectsTargetIdentityMismatch() public {
        UVPDockingModule.OpenDockRequestV2 memory request = _openRequest(0);
        bytes32 rogueUid = keccak256("zx-0000000000000000000000000000dead");
        request.targetUidId = rogueUid;
        bytes32 derivedFromRogue = keccak256(abi.encode(DOMAIN_DEFINITION_REF, rogueUid));
        _expect(
            abi.encodeWithSelector(
                UVPDockingModule.DockTargetIdentityMismatch.selector, targetDefinitionRef, derivedFromRogue
            )
        );
        _openRaw(request);
    }

    /// new 路由要求目标接口宣告 new（orderModesWord bit0）。
    function testRejectsInterfaceWithoutNewMode() public {
        UVPDockingModule.DockInterfaceProofV2 memory proof = _interfaceProof();
        proof.commitment.orderModesWord = 2; // existing-only
        _expect(abi.encodeWithSelector(UVPDockingModule.DockInterfaceModeUnsupported.selector, 2));
        _openWith(_openRouteProof(), proof);
    }

    /// new 模式恰一条 input 绑定（出生锚）：两条即拒绝。
    function testRejectsMultipleInputBindings() public {
        UVPDockingModule.DockInputBindingArg[] memory inputs = new UVPDockingModule.DockInputBindingArg[](2);
        inputs[0] = _inputs()[0];
        inputs[1] = inputs[0];
        _expect(abi.encodeWithSelector(UVPDockingModule.DockBindingCountInvalid.selector, 2, 1));
        docking.openDockedOrder(
            _openRequest(0), _openRouteProof(), _interfaceProof(), inputs, _outputs(), _permitEmpty()
        );
    }

    function testRejectsEntrancePortLeafMismatch() public {
        UVPDockingModule.DockInterfacePortLeafV2 memory leaf = _openLeafData();
        leaf.hookKey = keccak256("pay.init#OTHER_HOOK");
        bytes32 recomputedLeaf =
            keccak256(abi.encode(DOMAIN_INTERFACE_INPUT, TARGET_UID_ID, INTERFACE_NAME_ID, leaf.portKey, leaf.hookKey));
        _expect(
            abi.encodeWithSelector(UVPDockingModule.DockInterfaceLeafMismatch.selector, openPortLeaf, recomputedLeaf)
        );
        UVPDockingModule.DockInterfaceProofV2 memory proof = _interfaceProof();
        proof.entranceLeaf = leaf;
        _openWith(_openRouteProof(), proof);
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
        // 篡改 child ID 尝试开第二单：身份推导先失败。
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

    // ------------------------------------------------------------------
    // 审计修复轮回归（F053/F054/F056/F061/F062/F064）
    // ------------------------------------------------------------------

    /// F053：就绪门只看调用方自报 request.localHookId 时，已提交 route 的
    /// 出生锚可绑兄弟 hook，冒名者借就绪 hook 提前开仓——恒等校验拒绝。
    function testOpenRejectsEntranceHookImpersonation() public {
        RogueRoute memory route =
            _registerRogueRouteParent(PARENT_SIBLING_HOOK, TARGET_SOURCE, TARGET_SIGNAL, _outputs());
        UVPDockingModule.OpenDockRequestV2 memory request = _rogueOpenRequest(route);
        // 冒名：请求声明就绪的 EXEC hook，出生锚实际绑未就绪的兄弟 hook。
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
        docking.openDockedOrder(request, route.routeProof, _interfaceProof(), inputs, _outputs(), _permitEmpty());
    }

    /// F054：出生锚事实键不在目标 mailbox hook 的 SIGNAL 依赖声明内（首事实
    /// 键先到先得注入）——一致性闸拒绝。
    function testOpenRejectsEntranceFactNotDeclaredByTargetHook() public {
        // TARGET_PENDING_SIGNAL 不是目标 plan 任何 hook 的依赖原子。
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
        docking.openDockedOrder(request, route.routeProof, _interfaceProof(), inputs, _outputs(), _permitEmpty());
    }

    /// F056：output 绑定指向目标接口从未宣告的端口——outputsRoot membership
    /// 拒绝（此前只重算绑定哈希入 routeHash，不构成目标侧承诺）。
    function testOpenRejectsUndeclaredOutputPort() public {
        UVPDockingModule.DockOutputBindingArg[] memory outputs = _outputs();
        outputs[2].portKey = ROGUE_PORT;
        outputs[2].portSignalWord = ROGUE_OUT_WORD;
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
                _outputPortLeaf(ROGUE_PORT, ROGUE_OUT_WORD),
                interfaceOutputsRoot
            )
        );
        docking.openDockedOrder(
            _rogueOpenRequest(route), route.routeProof, _interfaceProof(), _rogueInputs(route), outputs, _permitEmpty()
        );
    }

    /// F061：targetPlanId 进 dockInstanceId preimage——换目标 plan 即换实例
    /// 身份；接口承诺 word 可被复制，plan 身份不可冒名。
    function testDockInstancePreimageBindsTargetPlan() public {
        bytes32 otherPlanInstance = keccak256(
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
                keccak256("other-target-plan")
            )
        );
        assertFalse(otherPlanInstance == dockInstanceId);
    }

    /// F064：dock 事实提交者记目标 plan publisher（creator），keeper 只落
    /// relayer/opener——基础设施地址不进业务归因。
    function testOpenRecordsPublisherAsEntranceFactSubmitter() public {
        assertTrue(_open());
        (,,,, address entranceSubmitter) = machine.getSignal(targetPlanId, linkedOrderId, TARGET_SOURCE, TARGET_SIGNAL);
        assertTrue(entranceSubmitter == vm.addr(TARGET_PUBLISHER_KEY));
    }

    /// F062：permit 验签 v 值严格 {27,28}（与其余 EIP-712 入口同口径），
    /// 原始 0/1 不做归一化。
    function testPermitRejectsRawVValue() public {
        UVPDockingModule.EntrancePermitV2 memory permit = _permitSigned(1);
        permit.signature[64] = bytes1(uint8(0));
        _expect(abi.encodeWithSelector(ECDSA.InvalidSignatureV.selector, uint8(0)));
        _openWithPermit(_interfaceProof(), permit);
    }

    // ------------------------------------------------------------------
    // permit V2
    // ------------------------------------------------------------------

    function testPermitHappyPath() public {
        UVPDockingModule.EntrancePermitV2 memory permit = _permitSigned(1);
        assertTrue(_openWithPermit(_interfaceProof(), permit));
        assertTrue(machine.orderExists(targetPlanId, linkedOrderId));
        assertEq(docking.usedEntrancePermitNonce(dockInstanceId), 1);
    }

    function testPermitDigestMatchesEip712Formula() public {
        // 合约 digest 与 EIP-712 规范公式（version "4"、typehash V2 含
        // interfaceNameId）逐字一致；数值 golden 对拍在 DockManifestParity。
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

        // The idempotent path is checked before permit nonce validation. A
        // replay therefore returns false instead of reverting on the consumed
        // nonce.
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

    // ------------------------------------------------------------------
    // 碰撞隔离 + gas
    // ------------------------------------------------------------------

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
        // new 模式恰一条 input 绑定：entrance 即出生锚。
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

        openRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                INTERFACE_NAME_ID,
                uint256(0), // modeWord new
                inputsRoot,
                outputsRoot
            )
        );
        existingRouteHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                INTERFACE_NAME_ID,
                uint256(1), // existing：链轨不支持，仅作为已提交叶参与拒绝用例
                inputsRoot,
                outputsRoot
            )
        );

        // entrance 端口叶 → 接口 inputsRoot（单叶）→ interfaceLeaf → 目标
        // plan 的 dockInterfaceRoot（单叶）。
        openPortLeaf = keccak256(
            abi.encode(DOMAIN_INTERFACE_INPUT, TARGET_UID_ID, INTERFACE_NAME_ID, ENTRANCE_PORT, TARGET_ENTRANCE_HOOK)
        );
        // output 端口叶（三叶）：全部宣告进接口 outputsRoot——每条 output
        // 绑定在 open 时必须给出各自端口的 membership proof。
        donePortLeaf = _outputPortLeaf(DONE_PORT, OUT_WORD_DONE);
        progressPortLeaf = _outputPortLeaf(PROGRESS_OUT_PORT, OUT_WORD_PROGRESS);
        settlePortLeaf = _outputPortLeaf(SETTLE_PORT, OUT_WORD_SETTLE);
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

    function _outputPortLeaf(bytes32 portKey, bytes32 canonicalWord) private pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_INTERFACE_OUTPUT, TARGET_UID_ID, INTERFACE_NAME_ID, portKey, canonicalWord));
    }

    /// 三叶树（排序去重后 [p0,p1,p2]：上层 = [H(p0,p1), p2]）的三个
    /// membership proof——按叶在排序后的位置给兄弟节点，DockMerkle.pair
    /// 内部自排序。
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
        // Keep a MINT trigger in the target plan so the namespace regression
        // test exercises the real permissionless front-run surface.
        // 词表内事实（TARGET_OUT_SOURCE::TARGET_OUT_SIGNAL，relation 0）：
        // outside 触发的出生事实必须在 plan capability 词表内。
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
            op: uint8(UVPStateMachine.InstructionOp.Signal), sourceId: sourceId, signalId: signalId, arity: 0, delaySeconds: 0
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

    // 自建第二份父 plan（route 叶全由调用方给定）。EXEC hook 就绪、同阶段
    // 兄弟 hook（监听 SIGNAL_SIBLING，永不喂入）保持未就绪——F053/F054/
    // F056 拒绝路径共用。
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
                INTERFACE_NAME_ID,
                uint256(0), // modeWord new
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
            new IUVPPlanMetadataModule.StageSelectorBinding[](0),
            new IUVPPlanMetadataModule.SignalCapability[](0)
        );

        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](2);
        auths[0] = _auth(PARENT_STAGE, SIGNAL_START, address(this));
        auths[1] = _auth(PARENT_STAGE, SIGNAL_EXEC, address(this));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = _outsideTrigger(SIGNAL_START);
        trigger.planId = route.planId;
        machine.triggerOrderFromOutsideFor(trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)));
        route.orderId = machine.triggerOrderIdFor(route.planId, PARENT_STAGE, SIGNAL_START, PAYLOAD);
        machine.submitSignal(route.planId, route.orderId, PARENT_STAGE, SIGNAL_EXEC, PAYLOAD, bytes32(uint256(0x78)));

        route.dockInstanceId = keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                runtimeDomain,
                route.planId,
                localDefinitionRef,
                route.orderId,
                routeId,
                route.routeHash,
                uint256(0), // modeWord new
                INTERFACE_NAME_ID,
                targetPlanId
            )
        );
        route.linkedOrderId = bytes32(
            uint256(keccak256(abi.encode(DOMAIN_DOCK_ORDER, route.dockInstanceId, targetDefinitionRef)))
                | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
        route.routeProof = new bytes32[](0); // 单叶树
        return route;
    }

    function _rogueOpenRequest(RogueRoute memory route)
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
                uint256(0), // modeWord new
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
        machine.triggerOrderFromOutsideFor(trigger, auths, _sign(SUBMITTER_KEY, _outsideDigestFor(trigger, auths)));
        machine.submitSignal(parentPlanId, PARENT_ORDER_ID, PARENT_STAGE, SIGNAL_EXEC, PAYLOAD, bytes32(uint256(0x77)));
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

    function _open() private returns (bool) {
        return _openWith(_openRouteProof(), _interfaceProof());
    }

    function _openWith(bytes32[] memory routeProof, UVPDockingModule.DockInterfaceProofV2 memory interfaceProof)
        private
        returns (bool)
    {
        return docking.openDockedOrder(
            _openRequest(0), routeProof, interfaceProof, _inputs(), _outputs(), _permitEmpty()
        );
    }

    function _openWithPermit(
        UVPDockingModule.DockInterfaceProofV2 memory interfaceProof,
        UVPDockingModule.EntrancePermitV2 memory permit
    ) private returns (bool) {
        return docking.openDockedOrder(
            _openRequest(0), _openRouteProof(), interfaceProof, _inputs(), _outputs(), permit
        );
    }

    function _openRaw(UVPDockingModule.OpenDockRequestV2 memory request) private returns (bool) {
        return _openRawWithProof(request, _openRouteProof());
    }

    function _openRawWithProof(UVPDockingModule.OpenDockRequestV2 memory request, bytes32[] memory routeProof)
        private
        returns (bool)
    {
        return docking.openDockedOrder(request, routeProof, _interfaceProof(), _inputs(), _outputs(), _permitEmpty());
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
            orderModesWord: 1, // [new]
            inputsRoot: openPortLeaf, // 单端口叶树
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
            portSignalWord: OUT_WORD_DONE,
            bindingHash: outputBinding,
            portProof: donePortProof
        });
        outputs[1] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_PROGRESS_SOURCE,
            localSignalId: LOCAL_PROGRESS_SIGNAL,
            portKey: PROGRESS_OUT_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_SIGNAL,
            portSignalWord: OUT_WORD_PROGRESS,
            bindingHash: progressOutBinding,
            portProof: progressPortProof
        });
        outputs[2] = UVPDockingModule.DockOutputBindingArg({
            localSourceId: LOCAL_MAPPED_SOURCE,
            localSignalId: LOCAL_MAPPED_SIGNAL,
            portKey: SETTLE_PORT,
            targetSourceId: TARGET_SOURCE,
            targetSignalId: TARGET_PENDING_SIGNAL,
            portSignalWord: OUT_WORD_SETTLE,
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
        return _siblingProof(existingRouteHash);
    }

    function _existingRouteProof() private view returns (bytes32[] memory) {
        return _siblingProof(openRouteHash);
    }

    function _openPortProof() private pure returns (bytes32[] memory) {
        return new bytes32[](0); // 单叶树
    }

    function _openInterfaceProof() private pure returns (bytes32[] memory) {
        return new bytes32[](0); // 单叶树
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
