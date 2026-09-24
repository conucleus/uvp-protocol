// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {DockMerkle} from "../src/libraries/DockMerkle.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";

/// @title Zhixu Dock existing 模式（attach）测试：对等挂接既有目标单
/// @dev 覆盖：同意矩阵（无授权拒 / creator / 在任执行者及其负例：锚错
///      阶段、跨单冒用 / publisher 预授权）、不铸子单 + gas 上界、N:1
///      多父挂同一目标单（dockByTargetOrder 保持 new 专属）、input 恰一次
///      + 重放幂等、attach 前已成立 output 的回填重放、target:null 动态
///      选择（合法/伪造/异叶/他路由候选集 proof、选定钉住、非空绑定
///      routeHash 失配拒）、接口 existing 位、深度账本 max 更新与不降。
///      默认目标单 creator = 测试合约（creator 同意腿天然成立）；不同意
///      腿用例以显式 creator/prank/permit 隔离。
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
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,uint256 deadline)"
    );
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant TRIGGER_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );
    bytes32 private constant ATTACH_PERMIT_TYPEHASH = keccak256(
        "UVPDockAttachPermitV1(bytes32 targetPlanId,bytes32 targetOrderId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
    );

    // preimage v2 域（与 packages/compiler/docs/dock-word-layout.md 逐字节一致）。
    bytes32 private constant DOMAIN_DEFINITION_REF = keccak256("UVP_DEFINITION_REF_V1");
    bytes32 private constant DOMAIN_INTERFACE = keccak256("UVP_DOCK_INTERFACE_V2");
    bytes32 private constant DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V2");
    bytes32 private constant DOMAIN_INTERFACE_OUTPUT = keccak256("UVP_DOCK_INTERFACE_OUTPUT_V3");
    bytes32 private constant DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V2");
    bytes32 private constant DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V2");
    bytes32 private constant DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V2");
    bytes32 private constant DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V2");
    bytes32 private constant DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant DOMAIN_DOCK_CANDIDATE = keccak256("UVP_DOCK_CANDIDATE_V1");
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    // 与 UVPStagePatchModule 同值的镜像常量（既有测试文件的惯例）。
    bytes32 private constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");

    // 父侧 stage/hook。
    bytes32 private constant PARENT_START_HOOK = keccak256("attach.parent.start#START");
    bytes32 private constant PARENT_STAGE = keccak256("attach.parent.start");
    bytes32 private constant SIGNAL_START = keccak256("start");
    bytes32 private constant PARENT_EXEC_HOOK = keccak256("attach.parent.exec#EXECUTE");
    bytes32 private constant PARENT_EXEC_STAGE = keccak256("attach.parent.exec");
    bytes32 private constant SIGNAL_EXEC = keccak256("exec");
    bytes32 private constant PARENT_DYN_HOOK = keccak256("attach.parent.dyn#SELECT");
    bytes32 private constant PARENT_DYN_STAGE = keccak256("attach.parent.dyn");
    bytes32 private constant SIGNAL_DYN = keccak256("select");

    // 目标定义身份与具名接口（existing-only：mask=2）。
    bytes32 private constant TARGET_UID_ID = keccak256("zx-b0ba5e11e77a2c0ffee0dd5eed1c0deb0a");
    bytes32 private constant INTERFACE_NAME_ID = keccak256("evidence");
    bytes32 private constant TARGET_BIRTH_HOOK = keccak256("observe.pay#MINT");
    bytes32 private constant TARGET_STAGE = keccak256("observe.pay");
    bytes32 private constant TARGET_BIRTH_SOURCE = keccak256("observe");
    bytes32 private constant TARGET_BIRTH_SIGNAL = keccak256("observe.pay.born");
    // output 事实（attach 前已成立→回填；接口经 done/progress 两端口暴露）。
    bytes32 private constant TARGET_SOURCE = keccak256("payroll");
    bytes32 private constant TARGET_SIGNAL = keccak256("observe.pay.paid");
    // input 交付事实（经 amend 端口写入既有单）。
    bytes32 private constant TARGET_INPUT_SOURCE = keccak256("audit");
    bytes32 private constant TARGET_INPUT_SIGNAL = keccak256("observe.pay.amend");
    bytes32 private constant TARGET_RECEIVE_HOOK = keccak256("observe.pay#RECEIVE");
    // executor 同意腿的可 patch 阶段（无 order-trigger hook）。
    bytes32 private constant TARGET_CONTROL_STAGE = keccak256("observe.control");
    bytes32 private constant TARGET_CONTROL_HOOK = keccak256("observe.control#WATCH");
    bytes32 private constant TARGET_CONTROL_SOURCE = keccak256("control");
    bytes32 private constant TARGET_CONTROL_SIGNAL = keccak256("observe.control.tick");
    // 输出镜像的本地事实键。
    bytes32 private constant LOCAL_MAPPED_SOURCE = keccak256("recycler");
    bytes32 private constant LOCAL_MAPPED_SIGNAL = keccak256("attach.parent.exec.paid");
    bytes32 private constant LOCAL_PROGRESS_SOURCE = keccak256("recycler");
    bytes32 private constant LOCAL_PROGRESS_SIGNAL = keccak256("attach.parent.exec.progress");

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
    // 动态选择的第二候选（不在本测试目标 plan 身份内，只进候选叶）。
    bytes32 private constant OTHER_CANDIDATE_DEF_REF = keccak256("other-candidate-definition-ref");

    UVPStateMachine private machine;
    UVPDockingModule private docking;
    UVPStagePatchModule private stagePatch;
    bytes32 private localDefinitionRef = keccak256("attach-parent-definition-ref");
    bytes32 private targetDefinitionRef = keccak256(abi.encode(DOMAIN_DEFINITION_REF, TARGET_UID_ID));

    bytes32 private parentPlanId;
    bytes32 private targetPlanId;
    bytes32 private runtimeDomain;

    // 静态 existing 路由（目标槽 = targetDefinitionRef）。
    bytes32 private execRouteId;
    bytes32 private amendInputBinding;
    bytes32 private doneOutputBinding;
    bytes32 private progressOutputBinding;
    bytes32 private attachRouteHash;
    // 动态选择路由（目标槽 = candidatesRoot，无 input/output 绑定）。
    bytes32 private dynRouteId;
    bytes32 private candidatesRoot;
    bytes32 private targetCandidateLeaf;
    bytes32 private otherCandidateLeaf;
    bytes32 private dynRouteHash;
    // 目标接口承诺（existing-only）。
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
        parentPlanId = _registerParentPlan();
    }

    // ------------------------------------------------------------------
    // 建立语义
    // ------------------------------------------------------------------

    /// 挂接建立：dock 记录就位、linkedOrderId = 既有目标单、不铸子单。
    /// 隐藏建单在本路径结构上不可达：attach 不携带任何可派生子单身份，
    /// 而 createDockedOrderFromModule 落在既有单上必撞 OrderAlreadyRegistered；
    /// 目标端点索引（new 模式出生键）也保持未被 existing 占用。
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

    /// 成功挂接的重放是 permissionless 幂等面：无同意面的 keeper 重放同一
    /// 请求 return false（幂等检查在同意门之前），不触碰 nonce/账本。
    function testAttachIsIdempotentForSameInstance() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        vm.prank(KEEPER);
        assertFalse(_attach(execRoute(), parentOrder, targetOrder));
    }

    /// gas 与存量 dock 数无关：先测基准，再积累 5 条既有 attach 后另挂
    /// 一条——attach 只做 O(1) 存储写，不铸单不遍历。2k 上界容纳深度
    /// 账本 max 更新与新鲜/既有槽的读写差异；绝对上界排除隐藏建单
    ///（铸子单本身 >200k gas）。
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
        // 绝对上界排除隐藏建单：铸一个子单（_createOrder + 出生事实 +
        // hook 求值）本身 >250k gas，含建单的 attach 必然越过本界。
        assertTrue(spent1 < 850000);
    }

    // ------------------------------------------------------------------
    // 同意矩阵
    // ------------------------------------------------------------------

    function testAttachRejectsWithoutConsent() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockAttachConsentRequired.selector, instance, KEEPER));
        _attach(execRoute(), parentOrder, targetOrder);
    }

    /// creator 腿：目标单 creator（非默认测试合约，隔离验证）可挂接；
    /// 另一父订单对同一目标单的 keeper 挂接（新实例，非幂等重放）仍无
    /// 同意面。
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

    /// 在任执行者腿：目标单 targetStageId 的 active executor patch 持有者
    /// 可挂接。经无 input 绑定的动态路由构造（executor 腿的阶段锚由请求
    /// 自报，不受 input 端口 hook 归属约束）；assign 模式 patch 由订单
    /// creator 作 selector 落地。
    function testAttachAllowsActiveStageExecutor() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        _assignControlExecutor(targetOrder, EXECUTOR_CONSENTER);
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        request.targetStageId = TARGET_CONTROL_STAGE;
        vm.prank(EXECUTOR_CONSENTER);
        assertTrue(_attachWithArgs(request, _attachInterfaceProof(), _permitEmpty()));
    }

    /// executor 腿负例（锚错阶段）：control 阶段持 patch 的执行者在请求
    /// 自报 targetStageId = 出生阶段时腿失效——阶段锚是 O(1) 寻址而非全阶
    /// 段枚举，锚错即回落到同意门（空 permit）拒绝。
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

    /// executor 腿负例（非本单执行者）：executor patch 按单落位——同
    /// plan 下另一订单同阶段的执行者对本单不成立，跨单冒用被拒。
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
        // permit 先离线签署（digest 视图调用不得吃掉 prank），keeper 中继。
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

    /// attach permit digest 与 EIP-712 规范公式逐字一致（域 version "4"，
    /// typehash V1 含 targetOrderId，feeLimit 固定 0）。
    function testAttachPermitDigestMatchesEip712Formula() public {
        bytes32 digest = docking.attachPermitDigest(
            targetPlanId,
            keccak256("some-order"),
            INTERFACE_NAME_ID,
            parentPlanId,
            attachRouteHash,
            bytes32(uint256(0x1)),
            1,
            2000000000
        );
        bytes32 structHash = keccak256(
            abi.encode(
                ATTACH_PERMIT_TYPEHASH,
                targetPlanId,
                keccak256("some-order"),
                INTERFACE_NAME_ID,
                parentPlanId,
                attachRouteHash,
                bytes32(uint256(0x1)),
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

    /// 重放在幂等检查之后：已成功的 dock 重放 return false，不因 nonce
    /// 已消费而回退（与 open 的 entrance permit 同口径）。
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

    // ------------------------------------------------------------------
    // N:1 与回填
    // ------------------------------------------------------------------

    /// 多父挂同一目标单：每父订单各成一条 dock 实例（spec §2.4 拼批
    /// 语义：每调用方按（本地订单, 本地阶段）各成一条），共享同一目标
    /// 端点；dockByTargetOrder 不承载 existing——目标侧投影由事件承载。
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
        // dockByTargetOrder 保持 new 专属（子单出生键）：existing 不落反向
        // 索引，目标侧"谁挂了我"的投影由 DockAttached 事件承载——多父
        // 挂接后该键仍为零，N:1 不会被单值索引伪造成 1:1。
        assertEq(docking.dockByTargetOrder(keccak256(abi.encode(targetPlanId, targetOrder))), bytes32(0));
    }

    /// 回填口径：attach 前已成立的目标输出，attach 后经 submitDockedSignal
    /// 按 output 绑定重放到每个父侧（permissionless，payload 读目标单存储，
    /// keeper 无法自选内容）。
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
                _attachInstanceId(parentA, attachRouteHash, targetOrder),
                doneOutputBinding,
                _coreNoAttribution(),
                _coreNoBinding()
            )
        );
        vm.prank(KEEPER);
        assertTrue(
            docking.submitDockedSignal(
                _attachInstanceId(parentB, attachRouteHash, targetOrder),
                doneOutputBinding,
                _coreNoAttribution(),
                _coreNoBinding()
            )
        );
        (bool mappedA, bytes32 payloadA,,,) =
            machine.getSignal(parentPlanId, parentA, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        (bool mappedB, bytes32 payloadB,,,) =
            machine.getSignal(parentPlanId, parentB, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL);
        assertTrue(mappedA && mappedB);
        assertEq(payloadA, TARGET_FACT_PAYLOAD);
        assertEq(payloadB, TARGET_FACT_PAYLOAD);
        // 兄弟 output 绑定（同目标事实、不同本地键/端口）独立交付且幂等。
        vm.prank(KEEPER);
        assertTrue(
            docking.submitDockedSignal(
                _attachInstanceId(parentA, attachRouteHash, targetOrder),
                progressOutputBinding,
                _coreNoAttribution(),
                _coreNoBinding()
            )
        );
        vm.prank(KEEPER);
        assertFalse(
            docking.submitDockedSignal(
                _attachInstanceId(parentA, attachRouteHash, targetOrder),
                progressOutputBinding,
                _coreNoAttribution(),
                _coreNoBinding()
            )
        );
    }

    // ------------------------------------------------------------------
    // input 交付（existing 是活路径）
    // ------------------------------------------------------------------

    /// 每端口恰一次：attach 登记未交付的 input 绑定，submitDockedInput
    /// 首次真实写入目标单（derived payload），此后幂等重放 return false。
    /// 与 new 模式不同，这里 submitDockedInput 是活的交付路径（无出生锚
    /// 在建立时被消费）。
    function testAttachInputDeliveredExactlyOnceThenIdempotent() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        assertFalse(docking.dockInputDelivered(instance, amendInputBinding));

        vm.prank(KEEPER);
        assertTrue(docking.submitDockedInput(instance, PARENT_EXEC_HOOK, amendInputBinding));
        (bool delivered,,,,) = machine.getSignal(targetPlanId, targetOrder, TARGET_INPUT_SOURCE, TARGET_INPUT_SIGNAL);
        assertTrue(delivered);
        assertTrue(docking.dockInputDelivered(instance, amendInputBinding));
        vm.prank(KEEPER);
        assertFalse(docking.submitDockedInput(instance, PARENT_EXEC_HOOK, amendInputBinding));
    }

    /// 目标事实槽位已有不同 provenance 的事实：交付 fail-closed（A14，
    /// 同一事实槽位不得复用表达新事实），账本保持未交付。
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
            _factAttributionFor(targetPlanId, TARGET_INPUT_SOURCE, TARGET_INPUT_SIGNAL),
            _noBinding()
        );
        bytes32 instance = _attachInstanceId(parentOrder, attachRouteHash, targetOrder);
        vm.prank(KEEPER);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockInputConflict.selector, instance, amendInputBinding));
        docking.submitDockedInput(instance, PARENT_EXEC_HOOK, amendInputBinding);
        assertFalse(docking.dockInputDelivered(instance, amendInputBinding));
    }

    // ------------------------------------------------------------------
    // target:null 动态选择
    // ------------------------------------------------------------------

    /// 候选集 root 占据动态路由的目标槽（随 dockRoutesRoot 在 finalize
    /// 冻结）；attach 携 (候选叶, membership proof) 选定，正常建立。
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

    /// 选定目标与所携证明不一致（证明的是另一候选叶）：membership 失配。
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

    /// 他路由/他 plan 的候选集 root 不在已提交 route 叶内：目标槽失配，
    /// routeHash 重算即拒（候选集承诺由父 plan 的 dockRoutesRoot 背书，
    /// 调用方无法自造槽 word）。
    function testAttachRejectsForeignCandidateRoot() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        bytes32 foreignRoot = DockMerkle.root(_single(targetCandidateLeaf));
        request.targetCandidatesRoot = foreignRoot;
        bytes32 recomputed = _routeHash(foreignRoot, EMPTY_DOCK_ROOT, EMPTY_DOCK_ROOT);
        _expect(abi.encodeWithSelector(UVPDockingModule.DockRouteLeafMismatch.selector, dynRouteHash, recomputed));
        _attachRaw(request);
    }

    /// 选定后钉住：同一父 route instance 已挂接目标 A 后，向目标 B 的
    /// 第二次挂接（不同 dockInstanceId、同 localRouteInstanceKey）被
    /// DockEndpointOccupied 拒绝——选定目标在 dockInstanceId preimage +
    /// 父 route 唯一键两层钉死，终身不可改。
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

    /// 动态路由的冻结形态 = 双空绑定根（4.4 口径）：携非空 inputs 或
    /// outputs 的挂接在 routeHash 重算处失配——非空绑定根换掉 preimage 的
    /// 绑定 word，静态槽与候选集槽两次重算都撞不上 committed 动态叶。
    /// 绑定材料逐项合法（叶重算/端口 membership 全过），失配只在承诺面
    /// 暴露——端口绑定/交付不在动态路径的 4.4 形态内，该边界由此钉死。
    function testAttachRejectsDynamicRouteCarryingBindings() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_DYN);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _dynRequest(parentOrder, targetOrder);
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = _attachInterfaceProof();
        UVPDockingModule.EntrancePermitV2 memory permit = _permitEmpty();

        // 非空 inputs：绑定哈希按 dynRouteId 重算自洽（逐项检查全过），
        // 单叶树根即叶自身。
        bytes32 dynAmendBinding = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING, dynRouteId, INTERFACE_NAME_ID, PARENT_DYN_HOOK, AMEND_PORT,
                TARGET_INPUT_SOURCE, TARGET_INPUT_SIGNAL
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
        bytes32 withInputs = _routeHash(candidatesRoot, dynAmendBinding, EMPTY_DOCK_ROOT);
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

        // 非空 outputs：同口径（output 绑定叶按 dynRouteId 重算自洽）。
        bytes32 dynDoneBinding = keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING, dynRouteId, INTERFACE_NAME_ID, LOCAL_MAPPED_SOURCE, LOCAL_MAPPED_SIGNAL,
                DONE_PORT, TARGET_SOURCE, TARGET_SIGNAL
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
        bytes32 withOutputs = _routeHash(candidatesRoot, EMPTY_DOCK_ROOT, dynDoneBinding);
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

    // ------------------------------------------------------------------
    // 拒绝路径（对称于 open）
    // ------------------------------------------------------------------

    /// attach 路由的接口承诺必须宣告 existing（bit1）；new-only 接口拒。
    function testAttachRejectsInterfaceWithoutExistingMode() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.DockAttachInterfaceProofV1 memory proof = _attachInterfaceProof();
        proof.commitment.orderModesWord = 1; // new-only
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

    /// modeWord 钉 existing：new 形状的 routeHash（同绑定根、modeWord=0）
    /// 无法通过 attach 的重算——两模式身份不可互冒（open 侧的反向拒绝见
    /// UVPDockingModuleTest.testRejectsExistingModeRoute）。
    function testAttachRejectsNewModeRouteHash() public {
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        request.routeHash = keccak256(
            abi.encode(
                DOMAIN_ROUTE,
                localDefinitionRef,
                targetDefinitionRef,
                INTERFACE_NAME_ID,
                uint256(0), // modeWord new
                DockMerkle.root(_single(amendInputBinding)),
                _outputsRootOf()
            )
        );
        // 重算先按静态目标槽（existing modeWord）→ 失配；再按候选集根
        // （=0 word）→ 仍失配，以第二次重算值回退。
        bytes32 recomputed = _routeHash(bytes32(0), DockMerkle.root(_single(amendInputBinding)), _outputsRootOf());
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

    /// 深度账本 max 更新：attach 计入 dock 链长——父深 3 挂接后目标单
    /// 深度抬到 4；父深 8 的挂接被 MAX 拒绝（长链/环路防护不被 attach
    /// 绕过）。dockDepthOfOrder 是模块第 8 个存储变量（slot 7）。
    function testAttachRaisesTargetDepthAndEnforcesMax() public {
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 depthSlot = keccak256(abi.encode(parentOrder, keccak256(abi.encode(parentPlanId, uint256(7)))));
        vm.store(address(docking), depthSlot, bytes32(uint256(uint256(3))));
        UVPDockingModule.AttachDockRequestV1 memory request = _execRequest(parentOrder, targetOrder);
        request.parentDepth = 3;
        assertTrue(_attachWithArgs(request, _attachInterfaceProof(), _permitEmpty()));
        assertEq(docking.dockDepthOfOrder(targetPlanId, targetOrder), 4);

        bytes32 deepParent = _spawnParentOrder(SIGNAL_EXEC);
        bytes32 deepSlot = keccak256(abi.encode(deepParent, keccak256(abi.encode(parentPlanId, uint256(7)))));
        vm.store(address(docking), deepSlot, bytes32(uint256(uint256(8))));
        UVPDockingModule.AttachDockRequestV1 memory deepRequest = _execRequest(deepParent, targetOrder);
        deepRequest.parentDepth = 8;
        _expect(abi.encodeWithSelector(UVPDockingModule.DockDepthExceeded.selector, 8, 8));
        _attachWithArgs(deepRequest, _attachInterfaceProof(), _permitEmpty());
    }

    /// 深度账本 max 的不降方向：目标单已更深时浅父挂接不覆盖——抬升只走
    /// max(现值, 父深+1)，既有深链账本（此前挂接积累）对后来者只读。
    function testAttachKeepsDeeperTargetDepth() public {
        bytes32 targetOrder = _spawnTargetOrder(PAYLOAD);
        bytes32 targetDepthSlot = keccak256(abi.encode(targetOrder, keccak256(abi.encode(targetPlanId, uint256(7)))));
        vm.store(address(docking), targetDepthSlot, bytes32(uint256(5)));
        bytes32 parentOrder = _spawnParentOrder(SIGNAL_EXEC);
        assertTrue(_attach(execRoute(), parentOrder, targetOrder));
        assertEq(docking.dockDepthOfOrder(targetPlanId, targetOrder), 5);
    }

    // ------------------------------------------------------------------
    // setup
    // ------------------------------------------------------------------

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
        sm.setLens(address(0x1234));
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
        attachRouteHash = _routeHash(targetDefinitionRef, DockMerkle.root(_single(amendInputBinding)), _outputsRootOf());

        dynRouteId = keccak256(abi.encode(DOMAIN_ROUTE_ID, localDefinitionRef, PARENT_DYN_STAGE));
        targetCandidateLeaf =
            keccak256(abi.encode(DOMAIN_DOCK_CANDIDATE, dynRouteId, targetDefinitionRef, INTERFACE_NAME_ID));
        otherCandidateLeaf =
            keccak256(abi.encode(DOMAIN_DOCK_CANDIDATE, dynRouteId, OTHER_CANDIDATE_DEF_REF, INTERFACE_NAME_ID));
        bytes32[] memory candidateLeaves = new bytes32[](2);
        candidateLeaves[0] = targetCandidateLeaf;
        candidateLeaves[1] = otherCandidateLeaf;
        candidatesRoot = DockMerkle.root(candidateLeaves);
        dynRouteHash = _routeHash(candidatesRoot, EMPTY_DOCK_ROOT, EMPTY_DOCK_ROOT);

        amendPortLeaf = keccak256(
            abi.encode(DOMAIN_INTERFACE_INPUT, TARGET_UID_ID, INTERFACE_NAME_ID, AMEND_PORT, TARGET_RECEIVE_HOOK)
        );
        evidenceInputsRoot = DockMerkle.root(_single(amendPortLeaf));
        amendPortProof = new bytes32[](0); // 单叶树
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

    function _outputPortLeaf(bytes32 portKey, bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_INTERFACE_OUTPUT, TARGET_UID_ID, INTERFACE_NAME_ID, portKey, sourceId, signalId)
            );
    }

    function _routeHash(bytes32 targetSlot, bytes32 inputsRoot, bytes32 outputsRoot) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_ROUTE, localDefinitionRef, targetSlot, INTERFACE_NAME_ID, uint256(1), inputsRoot, outputsRoot
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

    /// 两候选叶树上的 membership proof。
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
        // 词表：出生事实 + output 事实 + input 交付事实（后两者供公开信号
        // 面预写，构造回填与 DockInputConflict 路径）。
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

    // ------------------------------------------------------------------
    // 订单孵化
    // ------------------------------------------------------------------

    /// 父订单：outside 触发出生（每单独立 nonce 派生 payload/order id），
    /// 并喂入 readySignal 就绪对应本地 hook（attach 不要求就绪，就绪是
    /// submitDockedInput 的交付期门；喂入为 input 交付用例直接可用）。
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
            _noAttribution(),
            _noBinding()
        );
        return orderId;
    }

    /// 既有目标单（默认 creator = 测试合约：creator 同意腿天然成立）。
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

    /// attach 前已成立的目标输出（公开信号面写入，词表携证）。
    function _establishTargetFact(bytes32 targetOrder) private {
        machine.submitSignal(
            targetPlanId,
            targetOrder,
            TARGET_SOURCE,
            TARGET_SIGNAL,
            TARGET_FACT_PAYLOAD,
            bytes32(uint256(0x99)),
            _factAttributionFor(targetPlanId, TARGET_SOURCE, TARGET_SIGNAL),
            _noBinding()
        );
    }

    /// executor 同意腿材料：订单 creator 作 selector，对 control 阶段落
    /// assign 模式 patch（selector 绑定 control→control 在目标词表树内；
    /// control 阶段无 order-trigger hook，出生阶段守门不适用）。
    function _assignControlExecutor(bytes32 targetOrder, address executor) private {
        UVPStagePatchModule.StageExecutorPatch memory patch = UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: TARGET_CONTROL_STAGE,
            targetStageId: TARGET_CONTROL_STAGE,
            executor: executor,
            role: keccak256("executor"),
            executorMetadataHash: bytes32(uint256(0xE1)),
            mode: EXECUTOR_PATCH_MODE_ASSIGN,
            previousExecutor: address(0),
            approvalSourceId: bytes32(0),
            approvalSignalId: bytes32(0),
            patchHash: keccak256("control-executor-patch"),
            patchNonce: 1,
            metadataURI: "uvp-eth://attach-test-patch"
        });
        stagePatch.applyStageExecutorPatch(
            targetPlanId,
            targetOrder,
            patch,
            _selectorBindingProof(targetPlanId, TARGET_CONTROL_STAGE),
            new UVPStagePatchModule.StageCapabilityFact[](0)
        );
    }

    // ------------------------------------------------------------------
    // attach calldata builders
    // ------------------------------------------------------------------

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
        // 绑定数组随路由形态：动态路由无 input/output 绑定（route 叶的
        // 绑定根为 EMPTY），静态路由携带完整两集。
        UVPDockingModule.AttachInputBindingArg[] memory inputs;
        UVPDockingModule.DockOutputBindingArg[] memory outputs;
        if (request.targetCandidatesRoot != bytes32(0)) {
            inputs = new UVPDockingModule.AttachInputBindingArg[](0);
            outputs = new UVPDockingModule.DockOutputBindingArg[](0);
        } else {
            // 静态路由唯一形态：exec 舞台（本 fixture 只有一条静态路由）。
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

    /// existing 实例身份（10 word：尾 word = 既有目标单键原字入槽——与
    /// TS dockInstanceId(targetOrderRef) 的 word 形态槽一致）。
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
                orderModesWord: 2, // [existing]
                inputsRoot: evidenceInputsRoot,
                outputsRoot: evidenceOutputsRoot
            }),
            interfaceProof: new bytes32[](0), // 单接口叶树
            // 静态路由不读候选证明；动态路由按选定目标叶构造（测试内
            // 固定为 targetCandidateLeaf 的证明）。
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

    /// 父 plan 两叶 route 树（static + dynamic）的 membership proof。
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

    // ------------------------------------------------------------------
    // 能力表测试基建（与 UVPDockingModuleTest 同款镜像）
    // ------------------------------------------------------------------

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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherKey, digest);
        bytes32 planId = machine.commitPlan(commit, hooks, abi.encodePacked(r, s, v));
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

    /// 排序去重叶表上的 membership proof（奇数尾叶直接提升）。
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

    function _noBinding() private pure returns (UVPStateMachine.SelectorBindingProof memory) {
        return UVPStateMachine.SelectorBindingProof({selectorStageId: bytes32(0), proof: new bytes32[](0)});
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

    // ------------------------------------------------------------------
    // 触发订单基建
    // ------------------------------------------------------------------

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
                keccak256("0.12"),
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
