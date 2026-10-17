// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// 执行者换人面黑盒对抗测试（独立测试工程师视角，无实现背景）：
/// 只依据行为规格构造对抗场景——候选集边界、授权集一致性、fork 边界、
/// 时序与歧义、零字段/词表闭集等攻击面。造证方式与 UVPStateMachine.t.sol
/// 同款（叶重算 + Merkle proof + EIP-712 摘要签名）。

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {IUVPStateMachineCore} from "../src/interfaces/IUVPStateMachineCore.sol";
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
    function addr(uint256 privateKey) external view returns (address keyAddr);
    function getRecordedLogs() external returns (Log[] memory logs);
    function prank(address msgSender) external;
    function recordLogs() external;
    function sign(uint256 privateKey, bytes32 digest) external view returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

contract ExecutorChangeBlackBoxTest {
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

    /// relayed patch 的预备材料（摘要/签名先于 expectRevert 完成，保持
    /// vm.expectRevert 与目标调用的配对干净）。
    struct PreparedPatch {
        UVPStagePatchModule.StageExecutorPatch patch;
        address selector;
        uint256 deadline;
        bytes selectorSignature;
        bytes previousExecutorSignature;
        IUVPStateMachineCore.SelectorBindingProof bindingProof;
        bytes32[] candidateProof;
        IUVPStateMachineCore.SignalAuthorization[] authorizations;
    }

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    mapping(address machine => UVPStagePatchModule) private _stagePatchModules;
    bytes32 private PLAN_ID;
    bytes32 private ORDER_ID;

    bytes32 private constant SOURCE_BOOTSTRAP = bytes32(uint256(0x3001));
    bytes32 private constant SIGNAL_ORDER_START = bytes32(uint256(0x4000));
    bytes32 private constant SIGNAL_INIT_CMP = bytes32(uint256(0x4002));
    bytes32 private constant SIGNAL_STAGE_DONE = bytes32(uint256(0x4005));
    bytes32 private constant SIGNAL_STAGE_REVIEW = bytes32(uint256(0x4006));
    bytes32 private constant SIGNAL_AUDIT_PASS = bytes32(uint256(0x4003));
    bytes32 private constant SIGNAL_EXTRA = bytes32(uint256(0x4007));
    bytes32 private constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;
    bytes32 private constant RESOURCE_PATCH_SIGNAL_ID =
        0x6dff331f2bb7b785cbcd99a911e6d30dc8714f43b3b9ba80c658215445ddd0ba;
    bytes32 private constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");
    bytes32 private constant EXECUTOR_PATCH_MODE_HANDOFF = bytes32("handoff");
    bytes32 private constant STAGE_INIT = bytes32(uint256(0x5001));
    bytes32 private constant STAGE_AUDIT = bytes32(uint256(0x5002));
    bytes32 private constant HOOK_ORDER_START = bytes32(uint256(0x6000));
    bytes32 private constant HOOK_AUDIT = bytes32(uint256(0x6001));
    bytes32 private constant HOOK_NAME_ORDER_START = bytes32(uint256(0x7005));
    bytes32 private constant HOOK_NAME_INIT_DONE = bytes32(uint256(0x7002));
    bytes32 private constant PAYLOAD_HASH = bytes32(uint256(0x8001));
    bytes32 private constant IDEMPOTENCY_KEY = bytes32(uint256(0x9001));
    bytes32 private constant ROLE_EXECUTOR = bytes32(uint256(0xa003));
    bytes32 private constant EXECUTOR_METADATA_HASH = bytes32(uint256(0xa004));
    bytes32 private constant PATCH_HASH = bytes32(uint256(0xa006));
    bytes32 private constant PATCH_HASH_2 = bytes32(uint256(0xa007));
    bytes32 private constant RESOURCE_KEY = bytes32(uint256(0xa008));
    bytes32 private constant MANIFEST_HASH = bytes32(uint256(0xa00a));
    bytes32 private constant RESOURCE_POLICY_HASH = bytes32(uint256(0xa00b));
    address private constant CREATOR = address(uint160(0xc0de));
    address private constant STRANGER = address(uint160(0xbad));
    address private constant E3 = address(uint160(0x33));
    uint256 private constant SELECTOR_PRIVATE_KEY = 0xa11ce;
    uint256 private constant EXECUTOR1_PRIVATE_KEY = 0xb0b;
    uint256 private constant EXECUTOR2_PRIVATE_KEY = 0xb0c;
    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.15");
    bytes32 private constant EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");
    bytes32 private constant SIGNAL_CAPABILITY_LEAF_DOMAIN = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant SELECTOR_BINDING_LEAF_DOMAIN = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    struct CapabilityTables {
        StageSelectorBinding[] bindings;
        SignalCapability[] capabilities;
        bytes32[] sortedLeaves;
        bytes32[] candidateLeaves;
    }

    mapping(address machine => mapping(bytes32 planId => CapabilityTables tables)) private _capabilityTables;

    // ==================================================================
    // 候选集边界
    // ==================================================================

    /// 跨阶段混用 proof：用 STAGE_INIT 的合法候选叶/proof 提交 STAGE_AUDIT
    /// 的 patch——叶公式含 targetStageId，重算叶不在树内，必须拒绝。
    function testCandidateGateRejectsCrossStageProofMixing() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory auths =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E1());
        UVPStagePatchModule.StageExecutorPatch memory patch = _withAuthHash(_patch(1, E1(), PATCH_HASH), auths);
        // proof 是 (STAGE_INIT, E1) 叶的合法成员资格证明。
        bytes32[] memory initStageProof = _candidateProofFor(machine, PLAN_ID, STAGE_INIT, E1());
        require(initStageProof.length != 0, "test setup: init stage leaf missing");

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, PLAN_ID, ORDER_ID, STAGE_AUDIT, E1()
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), initStageProof, auths
            );
    }

    /// 候选集内地址只对本 stage 生效：E1 是 STAGE_INIT 的候选、不是
    /// STAGE_AUDIT 的候选——对 AUDIT 的 patch 恒拒。
    function testCandidateOfDifferentStageRejected() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory auths =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E1());
        UVPStagePatchModule.StageExecutorPatch memory patch = _withAuthHash(_patch(1, E1(), PATCH_HASH), auths);

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, PLAN_ID, ORDER_ID, STAGE_AUDIT, E1()
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID, ORDER_ID, patch, _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT), new bytes32[](0), auths
            );
    }

    /// 重复条目去重后的 root 等价：commitPlan 携重复候选条目注册成功，
    /// root 与去重集合一致；去重叶集构造的 proof 照常验过 patch。
    function testCandidateTreeDedupKeepsRootAndProofEquivalence() public {
        UVPStateMachine.ExecutorCandidate[] memory duplicates = new UVPStateMachine.ExecutorCandidate[](5);
        duplicates[0] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: E1()});
        duplicates[1] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: E1()});
        duplicates[2] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: E2()});
        duplicates[3] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: E2()});
        duplicates[4] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_INIT, executor: E1()});
        UVPStateMachine.ExecutorCandidate[] memory deduped = new UVPStateMachine.ExecutorCandidate[](3);
        deduped[0] = duplicates[0];
        deduped[1] = duplicates[2];
        deduped[2] = duplicates[4];

        bytes32 duplicateRoot = DockMerkle.root(_executorCandidateLeaves(duplicates));
        bytes32 dedupedRoot = DockMerkle.root(_executorCandidateLeaves(deduped));
        require(duplicateRoot == dedupedRoot, "duplicate entries changed candidate root");

        UVPStateMachine machine = _newMachine();
        _registerPlanWithCandidates(
            machine, _patchHooks(), _selectorBindings(), _patchCapabilities(), PUBLISHER_PRIVATE_KEY, duplicates
        );
        _submitBirth(machine, CREATOR, _overlayAuthorizations());
        _materializeAuditStage(machine, ORDER_ID);
        require(machine.planExecutorCandidatesRoot(PLAN_ID) == dedupedRoot, "committed root mismatch");

        // patch 用去重叶集的 proof——建树若未去重该 proof 必验不过。
        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E1(), "dedup proof patch failed");
    }

    /// 空候选集计划恒拒 patch：assign 与 handoff 全模式拒绝，creator 亲自
    /// 出面也一样（候选集外没有任何人可以成为逐单执行者）。
    function testEmptyCandidateSetRejectsAssignAndHandoffEvenForCreator() public {
        UVPStateMachine machine = _newMachine();
        _registerPlanWithCandidates(
            machine,
            _patchHooks(),
            _selectorBindings(),
            _patchCapabilities(),
            PUBLISHER_PRIVATE_KEY,
            new UVPStateMachine.ExecutorCandidate[](0)
        );
        require(machine.planExecutorCandidatesRoot(PLAN_ID) == DockMerkle.EMPTY_ROOT, "empty set must yield EMPTY_ROOT");
        _submitBirth(machine, CREATOR, _overlayAuthorizations());
        _materializeAuditStage(machine, ORDER_ID);

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, PLAN_ID, ORDER_ID, STAGE_AUDIT, E1()
            )
        );
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));

        // handoff 同拒：候选集闸先于模式闸。
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9101)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        PreparedPatch memory prepared = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E2(), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorNotCandidate.selector, PLAN_ID, ORDER_ID, STAGE_AUDIT, E2()
            )
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, prepared);
    }

    // ==================================================================
    // selector 权与签名面
    // ==================================================================

    /// 候选集内地址 + 真实 selector 私钥，但对另一份 patch 内容签名——
    /// 伪造 digest 必被拒（recover 出的不是 selector）。
    function testRelayedPatchRejectsSelectorSignatureOverDifferentPatch() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory auths =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E3);
        UVPStagePatchModule.StageExecutorPatch memory submittedPatch = _withAuthHash(_patch(1, E3, PATCH_HASH), auths);
        UVPStagePatchModule.StageExecutorPatch memory signedPatch = _withAuthHash(_patch(1, E2(), PATCH_HASH), auths);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 signedDigest =
            _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, signedPatch, _selector(), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELECTOR_PRIVATE_KEY, signedDigest);
        bytes32 submittedDigest =
            _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, submittedPatch, _selector(), deadline);
        address expectedRecovered = ecrecover(submittedDigest, v, r, s);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, _selector(), expectedRecovered
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                submittedPatch,
                _selector(),
                deadline,
                _packedSignature(v, r, s),
                "",
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, E3),
                auths
            );
    }

    /// 第三方直接出面（无 EXECUTOR_PATCH 授权、非 creator）：即使目标在
    /// 候选集内、proof 完整，也必须在 selector 权闸被拒。
    function testDirectPatchRejectsThirdPartyWithoutSelectorRights() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.UnauthorizedStageExecutorPatchSelector.selector, ORDER_ID, STAGE_INIT, STRANGER
            )
        );
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
    }

    /// selector 绑定证混用：selectorStageId 与 patch 声明不一致、或携空证
    /// 都必须在绑定闸响亮拒绝。
    function testSelectorBindingProofMixingRejected() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory auths =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E1());
        UVPStagePatchModule.StageExecutorPatch memory patch = _withAuthHash(_patch(1, E1(), PATCH_HASH), auths);

        // 绑定证声明属主 STAGE_AUDIT，与 patch.selectorStageId=STAGE_INIT 不一致。
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageSelectorBindingNotFound.selector, PLAN_ID, STAGE_INIT, STAGE_AUDIT
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID,
                ORDER_ID,
                patch,
                IUVPStateMachineCore.SelectorBindingProof({selectorStageId: STAGE_AUDIT, proof: new bytes32[](0)}),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, E1()),
                auths
            );

        // selectorStageId 一致但不携 proof：成员资格验不过，同拒。
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageSelectorBindingNotFound.selector, PLAN_ID, STAGE_INIT, STAGE_AUDIT
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatch(
                PLAN_ID,
                ORDER_ID,
                patch,
                IUVPStateMachineCore.SelectorBindingProof({selectorStageId: STAGE_INIT, proof: new bytes32[](0)}),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, E1()),
                auths
            );
    }

    // ==================================================================
    // 授权集一致性
    // ==================================================================

    /// digest 承诺的 authorizationsHash 与实参授权集不一致（签的是 E2 的
    /// 集、递的是 E3 的集）——中途换集必须 revert。
    function testPatchRejectsAuthorizationSetSwapAfterDigestSigning() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory swappedAuths =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E3);
        IUVPStateMachineCore.SignalAuthorization[] memory signedAuths =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E2());
        UVPStagePatchModule.StageExecutorPatch memory patch = _withAuthHash(_patch(1, E3, PATCH_HASH), signedAuths);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _stagePatch(machine).stageExecutorPatchDigest(PLAN_ID, ORDER_ID, patch, _selector(), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELECTOR_PRIVATE_KEY, digest);

        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, _selector(), address(0)
            )
        );
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                _selector(),
                deadline,
                _packedSignature(v, r, s),
                "",
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, E3),
                swappedAuths
            );
    }

    /// 授权集内重复条目：哈希按原始列表折叠，模块写入侧同键幂等吸收，
    /// patch 正常生效且新城执行者获得提交权。
    function testPatchAuthorizationSetWithDuplicateEntriesAbsorbed() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory base =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E3);
        IUVPStateMachineCore.SignalAuthorization[] memory auths = new IUVPStateMachineCore.SignalAuthorization[](3);
        auths[0] = base[0];
        auths[1] = base[0];
        auths[2] = base[1];

        vm.prank(CREATOR);
        _patchDirectWithAuths(machine, PLAN_ID, ORDER_ID, _withAuthHash(_patch(1, E3, PATCH_HASH), auths), auths);
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E3, "patch not applied");
        require(
            machine.hasExplicitSignalAuthorization(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, E3),
            "duplicate-entry auth set not written"
        );
        vm.prank(E3);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9102)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
    }

    /// patch 生效后新城执行者实际获得提交权，集外第三方仍被拒。
    function testPatchedExecutorCanSubmitStageSignalWhileStrangerCannot() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E3, PATCH_HASH));
        require(
            machine.hasExplicitSignalAuthorization(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, E3),
            "new executor not authorized"
        );
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, STRANGER
            )
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9103)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        vm.prank(E3);
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9104)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        (,,,, address submitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE);
        require(submitter == E3, "patched executor submission not recorded");
    }

    /// 显式订单级授权独立于执行者委任：handoff 后旧执行者的既有授权不被
    /// 撤销（仍可凭出生授权提交后续事实）；集外第三方始终被拒。
    function testExplicitAuthorizationsSurviveExecutorHandoff() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9105)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        PreparedPatch memory handoff = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E2(), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, handoff);
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E2(), "handoff not applied");

        // 旧执行者 E1 不再是 stage 委任执行者，但既有显式授权仍在——REVIEW
        // 照常落库且提交者归因不变。
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9106)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
        (,,,, address reviewSubmitter) = machine.getSignal(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW);
        require(reviewSubmitter == E1(), "old executor explicit auth not preserved");

        // 集外第三方（无任何授权）始终被拒。
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector,
                ORDER_ID,
                STAGE_AUDIT,
                SIGNAL_STAGE_REVIEW,
                STRANGER
            )
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9107)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
    }

    /// 空授权集 + 一致哈希：patch 生效写 overlay，但新城执行者没有提交权
    /// ——授权面与委任面分离的黑盒口径。
    function testPatchWithEmptyAuthorizationSetLeavesNoSubmitLane() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory emptyAuths = new IUVPStateMachineCore.SignalAuthorization[](0);

        // E3 无出生授权——空授权集 patch 后不得凭空获得提交权。
        vm.prank(CREATOR);
        _patchDirectWithAuths(
            machine, PLAN_ID, ORDER_ID, _withAuthHash(_patch(1, E3, PATCH_HASH), emptyAuths), emptyAuths
        );
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E3, "patch not applied");
        require(
            !machine.hasExplicitSignalAuthorization(PLAN_ID, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, E3),
            "unexpected auth from empty set"
        );
        vm.prank(E3);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector, ORDER_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE, E3
            )
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9108)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
    }

    // ==================================================================
    // 出生阶段守门 / 模式词表 / nonce / 零字段 / handoff 签名
    // =================================================================

    /// 出生（mint trigger）阶段终生不可变：候选集内执行者 + creator 出面
    /// 也拒；assign/handoff 两模式同拒。
    function testBirthStageExecutorPatchForbiddenEvenInsideCandidateSet() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchForbiddenOnBirthStage.selector, ORDER_ID, STAGE_INIT
            )
        );
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patchToStage(1, STAGE_INIT, E1(), PATCH_HASH));

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchForbiddenOnBirthStage.selector, ORDER_ID, STAGE_INIT
            )
        );
        _patchDirect(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(1, STAGE_INIT, E1(), PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, E2())
        );
    }

    /// 模式词表闭集：assign/handoff 之外的任何模式词（含零字）拒绝。
    function testPatchModeVocabularyIsClosedSet() public {
        UVPStateMachine machine = _patchMachineReady();
        bytes32 foreignMode = bytes32("replace");

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(UVPStagePatchModule.InvalidStageExecutorPatchMode.selector, foreignMode));
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patchWithMode(1, E1(), PATCH_HASH, foreignMode, address(0)));

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(UVPStagePatchModule.InvalidStageExecutorPatchMode.selector, bytes32(0)));
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patchWithMode(1, E1(), PATCH_HASH, bytes32(0), address(0)));
    }

    /// nonce 跨模式/跨执行者单调：assign → 信号 → handoff → handoff 链上
    /// nonce 必须严格递增；同值重放拒绝。
    function testPatchNonceMonotonicAcrossModesAndExecutors() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9109)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        PreparedPatch memory handoff1 = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E2(), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, handoff1);
        PreparedPatch memory handoff2 = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(3, E3, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E2()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR2_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, handoff2);
        require(
            _stagePatch(machine).orderStageExecutorPatchNonce(PLAN_ID, ORDER_ID, STAGE_AUDIT) == 3, "nonce not tracked"
        );

        // 同参重放（nonce 3 ≤ 3）拒绝——已生效 patch 不可重放。
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchNonceNotIncreasing.selector, ORDER_ID, STAGE_AUDIT, 3, 3
            )
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, handoff2);
    }

    /// 零字段与未知订单：零 selector、零 targetStageId、未知订单各自响亮
    /// 拒绝。
    function testPatchValidatesZeroFieldsAndUnknownOrder() public {
        UVPStateMachine machine = _patchMachineReady();
        IUVPStateMachineCore.SignalAuthorization[] memory auths =
            _executorAuthorizationsFor(machine, PLAN_ID, STAGE_AUDIT, E1());
        uint256 deadline = block.timestamp + 1 hours;
        UVPStagePatchModule.StageExecutorPatch memory patch = _withAuthHash(_patch(1, E1(), PATCH_HASH), auths);

        vm.expectRevert(UVPStagePatchModule.ZeroSelector.selector);
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                PLAN_ID,
                ORDER_ID,
                patch,
                address(0),
                deadline,
                new bytes(65),
                "",
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT),
                _candidateProofFor(machine, PLAN_ID, STAGE_AUDIT, E1()),
                auths
            );

        vm.prank(CREATOR);
        vm.expectRevert(UVPStagePatchModule.ZeroTargetStageId.selector);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patchToStage(1, bytes32(0), E1(), PATCH_HASH));

        UVPStagePatchModule.StageExecutorPatch memory foreignOrderPatch =
            _withAuthHash(_patch(1, E1(), PATCH_HASH), auths);
        vm.prank(CREATOR);
        vm.expectRevert(UVPStagePatchModule.UnknownOrder.selector);
        _patchDirect(machine, PLAN_ID, bytes32(uint256(0xdeadbeef)), foreignOrderPatch);
    }

    /// handoff 的上一执行者会签是唯一授权材料：直接路径（无签名材料）与
    /// 错误私钥会签都拒绝；正确会签放行。
    function testHandoffRequiresPreviousExecutorSignature() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9120)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        // 直接路径无会签材料（previousExecutorSigner 恒为 0）。
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, E1(), address(0))
        );
        _patchDirect(
            machine, PLAN_ID, ORDER_ID, _patchWithMode(2, E2(), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1())
        );

        // 会签私钥错误（E2 冒充 E1 签名）。
        PreparedPatch memory wrongSigner = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E2(), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR2_PRIVATE_KEY
        );
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.InvalidStageExecutorPatchSignature.selector, E1(), E2())
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, wrongSigner);

        // 正确会签放行。
        PreparedPatch memory correct = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E2(), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, correct);
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E2(), "handoff not applied");
    }

    // ==================================================================
    // 时序与歧义
    // ==================================================================

    /// 同秒并列两提交者（无 active patch）→ handoff fail-closed 拒绝；
    /// 同秒同提交者不歧义 → handoff 放行；有 active patch 时歧义标记不
    /// 参与判定（patch executor 是权威上一执行者）。
    /// assign 前置闸（B8a）后，"无 active patch + 有计数"只余 fork 重放一
    /// 条合法构造：场景 1/2 的歧义计数先在父单（已 assign）制造，再经
    /// fork 重放进子单（无 patch、计数承袭原始提交者）。
    function testHandoffFailClosedOnSameSecondAmbiguousSubmitters() public {
        UVPStateMachine machine = _patchMachineReady();

        // 场景 1：同秒不同提交者 → 子单计数歧义 → StagePreviousExecutorAmbiguous。
        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9110)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        vm.prank(E2());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9111)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
        vm.prank(CREATOR);
        bytes32 ambiguousChild = machine.forkOrder(
            PLAN_ID,
            ORDER_ID,
            bytes32(uint256(0xABA1)),
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            _twoFacts(
                STAGE_AUDIT,
                SIGNAL_STAGE_DONE,
                bytes32(uint256(0x9110)),
                STAGE_AUDIT,
                SIGNAL_STAGE_REVIEW,
                bytes32(uint256(0x9111))
            ),
            _forkChildAuthorizations()
        );
        (uint256 count,,, bool ambiguous) = machine.stageSignalState(PLAN_ID, ambiguousChild, STAGE_AUDIT);
        require(count == 2 && ambiguous, "ambiguity flag not raised");
        PreparedPatch memory ambiguousHandoff = _prepareRelayed(
            machine,
            PLAN_ID,
            ambiguousChild,
            _patchWithMode(1, E3, PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StagePreviousExecutorAmbiguous.selector,
                ambiguousChild,
                STAGE_AUDIT,
                uint64(block.timestamp)
            )
        );
        _sendRelayed(machine, PLAN_ID, ambiguousChild, ambiguousHandoff);

        // 场景 2：同秒同提交者 → 无歧义，handoff 放行。
        bytes32 secondOrder = _birthSecondOrder(machine, keccak256("ambiguous-test/second"));
        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, secondOrder, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            secondOrder,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9112)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            secondOrder,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9113)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
        vm.prank(CREATOR);
        bytes32 cleanChild = machine.forkOrder(
            PLAN_ID,
            secondOrder,
            bytes32(uint256(0xABA2)),
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            _twoFacts(
                STAGE_AUDIT,
                SIGNAL_STAGE_DONE,
                bytes32(uint256(0x9112)),
                STAGE_AUDIT,
                SIGNAL_STAGE_REVIEW,
                bytes32(uint256(0x9113))
            ),
            _forkChildAuthorizations()
        );
        (,,, bool secondAmbiguous) = machine.stageSignalState(PLAN_ID, cleanChild, STAGE_AUDIT);
        require(!secondAmbiguous, "same-submitter same-second must not be ambiguous");
        PreparedPatch memory cleanHandoff = _prepareRelayed(
            machine,
            PLAN_ID,
            cleanChild,
            _patchWithMode(1, E2(), PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, cleanChild, cleanHandoff);
        require(machine.activeStageExecutor(PLAN_ID, cleanChild, STAGE_AUDIT) == E2(), "clean handoff failed");

        // 场景 3：active patch 在场时歧义标记不参与——patch executor 权威。
        bytes32 thirdOrder = _birthSecondOrder(machine, keccak256("ambiguous-test/third"));
        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, thirdOrder, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            thirdOrder,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9114)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        vm.prank(E2());
        machine.submitSignal(
            PLAN_ID,
            thirdOrder,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9115)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
        (,,, bool thirdAmbiguous) = machine.stageSignalState(PLAN_ID, thirdOrder, STAGE_AUDIT);
        require(thirdAmbiguous, "setup: expected ambiguity");
        PreparedPatch memory patchedHandoff = _prepareRelayed(
            machine,
            PLAN_ID,
            thirdOrder,
            _patchWithMode(2, E3, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, thirdOrder, patchedHandoff);
        require(machine.activeStageExecutor(PLAN_ID, thirdOrder, STAGE_AUDIT) == E3, "patch-authoritative handoff");
    }

    /// 「上一执行者」优先级反向钉死：active patch 在场时权威上一执行者是
    /// patch executor——以"最近提交者"冒充上一执行者（即使其提交了最新
    /// 事实）必须拒绝；以 patch executor 会签才放行。
    function testHandoffPreviousExecutorPrecedencePinnedToPatchExecutor() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        // 最近提交者是 E2（非 patch 执行者）。
        vm.prank(E2());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9121)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        // 以最近提交者 E2 冒充上一执行者：拒绝（expected = patch executor E1）。
        PreparedPatch memory impostor = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E3, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E2()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR2_PRIVATE_KEY
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStagePatchModule.StageExecutorPatchPreviousExecutorMismatch.selector,
                ORDER_ID,
                STAGE_AUDIT,
                E1(),
                E2()
            )
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, impostor);

        // 以 patch executor E1 会签：放行。
        PreparedPatch memory authoritative = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E3, PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, authoritative);
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E3, "authoritative handoff failed");
    }

    /// assign → 信号 → handoff 生命周期；有信号后 assign 永久关闭
    ///（StageAlreadyHasSignal），handoff 后新城执行者承接提交权。
    function testAssignSignalHandoffLifecycleAndAssignBlockedAfterSignal() public {
        UVPStateMachine machine = _patchMachineReady();

        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9116)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        // 首信号之后 assign 永久顶死。
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(2, E2(), PATCH_HASH_2));

        PreparedPatch memory handoff = _prepareRelayed(
            machine,
            PLAN_ID,
            ORDER_ID,
            _patchWithMode(2, E2(), PATCH_HASH_2, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, ORDER_ID, handoff);
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E2(), "handoff not applied");

        // 新执行者承接提交权（patch 授权集）。
        vm.prank(E2());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0x9117)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
        (uint256 finalCount,,,,) = _stageStateAbi(machine, ORDER_ID);
        require(finalCount == 2, "stage count mismatch");
    }

    /// B8a：候选集覆盖阶段的 assign 前置闸不依赖调用方携证——显式授权的
    /// 携证业务事实在指派前同样拒收（旧形态落库后把 assign 恒顶死，时序
    /// DoS 面）；指派后同键事实正常落库并进 per-stage 计数，后续 assign
    /// 的零信号闸同口径关闭。
    function testAssignBlockedByProofAttributedBusinessFact() public {
        UVPStateMachine machine = _newMachine();
        SignalCapability[] memory extra = new SignalCapability[](1);
        extra[0] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_EXTRA, targetOrderRelation: 0
        });
        _registerPlanWithCandidates(
            machine,
            _patchHooks(),
            _selectorBindings(),
            _mergeCapabilities(_patchCapabilities(), extra),
            PUBLISHER_PRIVATE_KEY,
            _standardCandidates()
        );
        UVPStateMachine.SignalAuthorization[] memory auths =
            _append(_overlayAuthorizations(), _stageAuthorization(SOURCE_BOOTSTRAP, SIGNAL_EXTRA, E1()));
        _submitBirth(machine, CREATOR, auths);
        _materializeAuditStage(machine, ORDER_ID);

        vm.prank(E1());
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_EXTRA,
            PAYLOAD_HASH,
            bytes32(uint256(0x9118)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_EXTRA)
        );
        (uint256 preCount,,,,) = _stageStateAbi(machine, ORDER_ID);
        require(preCount == 0, "rejected pre-assign fact must leave no state");

        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        require(machine.activeStageExecutor(PLAN_ID, ORDER_ID, STAGE_AUDIT) == E1(), "assign must survive rejection");

        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            SOURCE_BOOTSTRAP,
            SIGNAL_EXTRA,
            PAYLOAD_HASH,
            bytes32(uint256(0x9118)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_EXTRA)
        );
        (uint256 count,,,,) = _stageStateAbi(machine, ORDER_ID);
        require(count == 1, "attributed business fact not counted");

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(2, E1(), PATCH_HASH_2));
    }

    // ==================================================================
    // resource patch 与 assign 共用零信号闸
    // ==================================================================

    /// resource patch 与 assign 共闸：目标阶段零信号时放行；首个信号后
    /// 永久关闭。出生阶段不受出生守门（资源可替换）——但出生事实计数
    /// 使零信号闸先行关闭（错误面是 StageAlreadyHasSignal 而非出生守门，
    /// 证明 resource 车道不经出生闸）。
    function testResourcePatchSharesZeroSignalGateWithAssign() public {
        UVPStateMachine machine = _newMachine();
        StageSelectorBinding[] memory extraBinding = new StageSelectorBinding[](1);
        extraBinding[0] = StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_INIT});
        _registerPlanWithCandidates(
            machine,
            _patchHooks(),
            _mergeBindings(_selectorBindings(), extraBinding),
            _patchCapabilities(),
            PUBLISHER_PRIVATE_KEY,
            _standardCandidates()
        );
        _submitBirth(machine, CREATOR, _overlayAuthorizations());
        _materializeAuditStage(machine, ORDER_ID);

        // 出生阶段（STAGE_INIT）目标：资源补丁不触出生守门——错在零信号闸
        //（出生事实已计数），不在 StageExecutorPatchForbiddenOnBirthStage。
        vm.prank(_selector());
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_INIT)
        );
        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _resourcePatchToStage(1, STAGE_INIT, RESOURCE_KEY, PATCH_HASH),
                _moduleBindingFor(machine, PLAN_ID, STAGE_INIT)
            );

        // 目标阶段零信号：放行。
        vm.prank(_selector());
        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _resourcePatchToStage(1, STAGE_AUDIT, RESOURCE_KEY, PATCH_HASH),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT)
            );
        (bool exists,,,,,) =
            _stagePatch(machine).getActiveStageResourcePatch(PLAN_ID, ORDER_ID, STAGE_AUDIT, RESOURCE_KEY);
        require(exists, "resource patch not applied");

        // B8a：资源补丁不是执行者指派——首个携证信号在 executor assign
        // 前仍被 assign 前置闸拒收。
        vm.prank(E1());
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.StageExecutorNotAssigned.selector, ORDER_ID, STAGE_AUDIT)
        );
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9119)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );

        // executor assign 后首个信号落地，资源补丁与其共用零信号闸关闭。
        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0x9119)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
        vm.prank(_selector());
        vm.expectRevert(
            abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, ORDER_ID, STAGE_AUDIT)
        );
        _stagePatch(machine)
            .applyStageResourcePatch(
                PLAN_ID,
                ORDER_ID,
                _resourcePatchToStage(2, STAGE_AUDIT, RESOURCE_KEY, PATCH_HASH_2),
                _moduleBindingFor(machine, PLAN_ID, STAGE_AUDIT)
            );
    }

    // ==================================================================
    // fork 边界
    // ==================================================================

    /// 裁决信号只存在于兄弟订单、不在父单 → ForkApprovalSignalUnknown。
    function testForkRejectsApprovalSignalAbsentOnParent() public {
        UVPStateMachine machine = _forkMachineReady();
        bytes32 parentOrderId = ORDER_ID;
        bytes32 siblingOrder = _birthSecondOrderFork(machine);
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            siblingOrder,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _noAttribution()
        );

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.ForkApprovalSignalUnknown.selector,
                PLAN_ID,
                parentOrderId,
                SOURCE_BOOTSTRAP,
                SIGNAL_STAGE_DONE
            )
        );
        _fork(
            machine,
            parentOrderId,
            bytes32(uint256(0xF300)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, bytes32(uint256(0xF001)))
        );
    }

    /// initiator 是父单其它信号的提交者（非裁决信号提交者、非 creator）
    /// → UnauthorizedOrderFork。
    function testForkRejectsInitiatorWhoSubmittedDifferentSignal() public {
        UVPStateMachine machine = _forkMachineReady();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _noAttribution()
        );
        vm.prank(E2());
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xF002)),
            _noAttribution()
        );

        // EXECUTOR1 提交过 DONE，但裁决信号是 REVIEW（提交者 EXECUTOR2）。
        vm.prank(E1());
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnauthorizedOrderFork.selector, PLAN_ID, parentOrderId, E1())
        );
        _fork(
            machine,
            parentOrderId,
            bytes32(uint256(0xF400)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW, bytes32(uint256(0xF002)))
        );
    }

    /// birthFact 的 idempotencyKey 与父单历史不符 → InvalidForkBirthFact。
    function testForkRejectsBirthFactWithForgedIdempotencyKey() public {
        UVPStateMachine machine = _forkMachineReady();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _noAttribution()
        );
        UVPStateMachine.ForkBirthFact[] memory facts = new UVPStateMachine.ForkBirthFact[](1);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_STAGE_DONE,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(0xF00D)) // 伪造：父单是 0xF001
        });

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidForkBirthFact.selector, parentOrderId, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE
            )
        );
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF500)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            facts,
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    /// birthFact 只存在于兄弟订单、不在父单 → InvalidForkBirthFact
    ///（重放输入只能来自父单真实历史）。
    function testForkRejectsBirthFactFromSiblingOrder() public {
        UVPStateMachine machine = _forkMachineReady();
        bytes32 parentOrderId = ORDER_ID;
        bytes32 siblingOrder = _birthSecondOrderFork(machine);
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            siblingOrder,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _noAttribution()
        );
        vm.prank(E2());
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xF002)),
            _noAttribution()
        );

        UVPStateMachine.ForkBirthFact[] memory facts = new UVPStateMachine.ForkBirthFact[](1);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_STAGE_DONE,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: bytes32(uint256(0xF001))
        });
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.InvalidForkBirthFact.selector, parentOrderId, SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE
            )
        );
        machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            bytes32(uint256(0xF600)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            facts,
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    /// 同参重试幂等（OrderAlreadyRegistered）+ 不同载荷派生不同单号。
    function testForkIdempotentReplayAndDistinctPayloads() public {
        UVPStateMachine machine = _forkMachineReady();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _noAttribution()
        );

        vm.prank(E1());
        bytes32 first = _fork(
            machine,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, bytes32(uint256(0xF001)))
        );
        vm.prank(E1());
        vm.expectRevert(UVPStateMachine.OrderAlreadyRegistered.selector);
        _fork(
            machine,
            parentOrderId,
            bytes32(uint256(0xF100)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, bytes32(uint256(0xF001)))
        );
        require(first == machine.forkOrderIdFor(PLAN_ID, parentOrderId, bytes32(uint256(0xF100))), "id derivation");

        vm.prank(CREATOR);
        bytes32 second = _fork(
            machine,
            parentOrderId,
            bytes32(uint256(0xF200)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, bytes32(uint256(0xF001)))
        );
        require(second != first, "distinct payloads must fork distinct orders");
        require(machine.orderExists(PLAN_ID, second), "second fork missing");
    }

    /// fork 单血缘：单号纯函数派生、creator 承袭父单、initiator 记为
    /// relayer、OrderForked 事件恰好一条。
    function testForkChildLineageCreatorInheritanceAndRelayerAttribution() public {
        UVPStateMachine machine = _forkMachineReady();
        bytes32 parentOrderId = ORDER_ID;
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            parentOrderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _noAttribution()
        );

        vm.recordLogs();
        vm.prank(E1());
        bytes32 child = _fork(
            machine,
            parentOrderId,
            bytes32(uint256(0xF700)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, bytes32(uint256(0xF001)))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(machine.orderParent(PLAN_ID, child) == parentOrderId, "fork lineage broken");
        require(machine.orderCreator(PLAN_ID, child) == CREATOR, "fork creator must inherit parent creator");
        require(machine.orderRelayer(PLAN_ID, child) == E1(), "initiator must be recorded as relayer");
        require(child == machine.forkOrderIdFor(PLAN_ID, parentOrderId, bytes32(uint256(0xF700))), "id derivation");
        require(
            _countTopic(logs, keccak256("OrderForked(bytes32,bytes32,bytes32,bytes32,bytes32,address)")) == 1,
            "OrderForked event count"
        );
    }

    /// fork of fork：裁决信号可用重放入子单的事实（提交者承袭），血缘链
    /// 逐级可溯；第三方对子单发起 fork 被拒。
    function testForkOfForkNestedLineage() public {
        UVPStateMachine machine = _forkMachineReady();
        bytes32 parent = ORDER_ID;
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            parent,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _noAttribution()
        );
        vm.prank(E2());
        machine.submitSignal(
            PLAN_ID,
            parent,
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xF002)),
            _noAttribution()
        );

        vm.prank(E1());
        bytes32 child1 = _fork(
            machine,
            parent,
            bytes32(uint256(0xF800)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_DONE,
            _twoFacts(
                SOURCE_BOOTSTRAP,
                SIGNAL_STAGE_DONE,
                bytes32(uint256(0xF001)),
                SOURCE_BOOTSTRAP,
                SIGNAL_STAGE_REVIEW,
                bytes32(uint256(0xF002))
            )
        );
        require(machine.orderParent(PLAN_ID, child1) == parent, "child1 lineage");

        // 子单上重放入的事实提交者承袭——REVIEW 的提交者仍是 EXECUTOR2。
        (,,,, address reviewSubmitter) = machine.getSignal(PLAN_ID, child1, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW);
        require(reviewSubmitter == E2(), "fork fact submitter attribution broken");

        // 第三方（非子单 creator、非子单裁决信号提交者）发起 fork 被拒。
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(UVPStateMachine.UnauthorizedOrderFork.selector, PLAN_ID, child1, STRANGER)
        );
        _fork(
            machine,
            child1,
            bytes32(uint256(0xF801)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW, bytes32(uint256(0xF002)))
        );

        // 裁决信号提交者（REVIEW → EXECUTOR2）在子单上二次 fork。
        vm.prank(E2());
        bytes32 child2 = _fork(
            machine,
            child1,
            bytes32(uint256(0xF900)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW, bytes32(uint256(0xF002)))
        );
        require(machine.orderParent(PLAN_ID, child2) == child1, "child2 lineage");
        require(machine.orderCreator(PLAN_ID, child2) == CREATOR, "nested creator inheritance");

        // creator 对 child2 三次 fork（深度嵌套链）。
        vm.prank(CREATOR);
        bytes32 child3 = _fork(
            machine,
            child2,
            bytes32(uint256(0xFA00)),
            SOURCE_BOOTSTRAP,
            SIGNAL_STAGE_REVIEW,
            _singleFact(SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW, bytes32(uint256(0xF002)))
        );
        require(machine.orderParent(PLAN_ID, child3) == child2, "child3 lineage");
        require(machine.hasSignal(PLAN_ID, child3, SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW), "nested replay missing");
    }

    /// fork 单上的换人面：重放的 stage 键事实进子单 per-stage 计数——
    /// assign 被顶死；handoff 以父单原始提交者为"上一执行者"（其会签是
    /// 唯一授权材料）；子单提交权只来自 fork 调用授权集。
    function testPatchAndHandoffOnForkedOrderWithReplayedStageCounts() public {
        UVPStateMachine machine = _stageFactForkMachineReady();
        bytes32 parent = ORDER_ID;

        vm.prank(CREATOR);
        bytes32 child = machine.forkOrder(
            PLAN_ID,
            parent,
            bytes32(uint256(0xFB00)),
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            _singleFact(STAGE_AUDIT, SIGNAL_STAGE_DONE, bytes32(uint256(0xF001))),
            _forkChildAuthorizations()
        );

        // 重放事实进子单计数（source==stage 回退口径）。
        (uint256 stageCount, address childLast,, bool childAmbiguous) =
            machine.stageSignalState(PLAN_ID, child, STAGE_AUDIT);
        require(stageCount == 1, "replayed stage fact not counted on child");
        require(childLast == E1(), "replayed submitter attribution");
        require(!childAmbiguous, "unexpected ambiguity");

        // assign 被重放计数顶死。
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(UVPStagePatchModule.StageAlreadyHasSignal.selector, child, STAGE_AUDIT));
        _patchDirect(machine, PLAN_ID, child, _patch(1, E2(), PATCH_HASH));

        // handoff：上一执行者 = 父单原始提交者 EXECUTOR1，其会签生效。
        PreparedPatch memory handoff = _prepareRelayed(
            machine,
            PLAN_ID,
            child,
            _patchWithMode(1, E2(), PATCH_HASH, EXECUTOR_PATCH_MODE_HANDOFF, E1()),
            SELECTOR_PRIVATE_KEY,
            EXECUTOR1_PRIVATE_KEY
        );
        _sendRelayed(machine, PLAN_ID, child, handoff);
        require(machine.activeStageExecutor(PLAN_ID, child, STAGE_AUDIT) == E2(), "fork child handoff failed");

        // 子单授权来自 fork 调用授权集：原始提交者在子单无提交权。
        vm.prank(E1());
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPStateMachine.UnauthorizedSignalSubmitter.selector, child, STAGE_AUDIT, SIGNAL_STAGE_REVIEW, E1()
            )
        );
        machine.submitSignal(
            PLAN_ID,
            child,
            STAGE_AUDIT,
            SIGNAL_STAGE_REVIEW,
            PAYLOAD_HASH,
            bytes32(uint256(0xFC00)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_REVIEW)
        );
    }

    // ==================================================================
    // 机器与造证工具（与 UVPStateMachine.t.sol 同风格）
    // ==================================================================

    function E1() private view returns (address) {
        return vm.addr(EXECUTOR1_PRIVATE_KEY);
    }

    function E2() private view returns (address) {
        return vm.addr(EXECUTOR2_PRIVATE_KEY);
    }

    function _selector() private view returns (address) {
        return vm.addr(SELECTOR_PRIVATE_KEY);
    }

    function _stagePatch(UVPStateMachine machine) private view returns (UVPStagePatchModule) {
        return _stagePatchModules[address(machine)];
    }

    function _newMachine() private returns (UVPStateMachine machine) {
        machine = new UVPStateMachine();
        UVPStagePatchModule stagePatch = new UVPStagePatchModule(address(machine));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(machine));
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(machine));
        UVPDockingModule docking = new UVPDockingModule(address(machine), address(planMetadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(machine));
        _stagePatchModules[address(machine)] = stagePatch;
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(derivedSignal));
        machine.setDockingModule(address(docking));
        machine.setPlanMetadataModule(address(planMetadata));
        machine.setOrderLinkModule(address(orderLink));
        machine.setLens(address(0x1234));
        machine.freezeModules();
    }

    function _patchHooks() private pure returns (UVPStateMachine.CompactHook[] memory hooks) {
        hooks = new UVPStateMachine.CompactHook[](3);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _emitReadyHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_INIT_CMP);
        // STAGE_AUDIT 的第二条推进线（默认不提交，保留事实键余量）。
        hooks[2] = _emitReadyHook(bytes32(uint256(0x6002)), STAGE_AUDIT, bytes32(uint256(0x7006)), SIGNAL_AUDIT_PASS);
    }

    function _selectorBindings() private pure returns (StageSelectorBinding[] memory bindings) {
        bindings = new StageSelectorBinding[](1);
        bindings[0] = StageSelectorBinding({selectorStageId: STAGE_INIT, targetStageId: STAGE_AUDIT});
    }

    function _patchCapabilities() private pure returns (SignalCapability[] memory capabilities) {
        capabilities = new SignalCapability[](4);
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
    }

    function _standardCandidates() private view returns (UVPStateMachine.ExecutorCandidate[] memory candidates) {
        candidates = new UVPStateMachine.ExecutorCandidate[](5);
        candidates[0] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: E1()});
        candidates[1] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: E2()});
        candidates[2] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_AUDIT, executor: E3});
        candidates[3] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_INIT, executor: E1()});
        candidates[4] = UVPStateMachine.ExecutorCandidate({stageId: STAGE_INIT, executor: E2()});
    }

    /// patch 面 StdA 机器：注册计划 → 出生 → 物化 STAGE_AUDIT。
    function _patchMachineReady() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        _registerPlanWithCandidates(
            machine,
            _patchHooks(),
            _selectorBindings(),
            _patchCapabilities(),
            PUBLISHER_PRIVATE_KEY,
            _standardCandidates()
        );
        _submitBirth(machine, CREATOR, _overlayAuthorizations());
        _materializeAuditStage(machine, ORDER_ID);
    }

    function _registerPlanWithCandidates(
        UVPStateMachine machine,
        UVPStateMachine.CompactHook[] memory hooks,
        StageSelectorBinding[] memory selectorBindings,
        SignalCapability[] memory signalCapabilities,
        uint256 publisherPrivateKey,
        UVPStateMachine.ExecutorCandidate[] memory executorCandidates
    ) private returns (bytes32 planId) {
        address publisher = vm.addr(publisherPrivateKey);
        bytes32[] memory leaves = _capabilityLeaves(selectorBindings, signalCapabilities);
        bytes32[] memory candidateLeaves = _executorCandidateLeaves(executorCandidates);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: DockMerkle.root(leaves),
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: DockMerkle.root(candidateLeaves),
            birthAuthorizer: vm.addr(SELECTOR_PRIVATE_KEY),
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(machine), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherPrivateKey, digest);
        planId = machine.commitPlan(commit, hooks, executorCandidates, _packedSignature(v, r, s));
        machine.finalizePlan(planId);
        PLAN_ID = planId;
        CapabilityTables storage tables = _capabilityTables[address(machine)][planId];
        tables.bindings = selectorBindings;
        tables.capabilities = signalCapabilities;
        tables.sortedLeaves = _sortedUnique(leaves);
        tables.candidateLeaves = _sortedUnique(candidateLeaves);
    }

    function _submitBirth(
        UVPStateMachine machine,
        address, // creator 固定 CREATOR，参数占位保持调用点对齐
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private {
        ORDER_ID = bytes32(
            uint256(keccak256(abi.encode(PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, PAYLOAD_HASH)))
                & ~uint256(1 << 255)
        );
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: PLAN_ID,
            creator: CREATOR,
            triggerHookId: HOOK_ORDER_START,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: PAYLOAD_HASH,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: _selector(),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _triggerSignature(machine, trigger, authorizations);
        machine.triggerOrderFromOutsideFor(
            trigger, authorizations, signature, _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START)
        );
    }

    /// 同 plan 第二个出生订单（不同 payloadHash → 不同派生单号），并物化
    /// 其 STAGE_AUDIT。
    function _birthSecondOrder(UVPStateMachine machine, bytes32 salt) private returns (bytes32 orderId) {
        bytes32 payload = keccak256(abi.encode("executor-change-blackbox/second-order", salt));
        orderId = bytes32(
            uint256(keccak256(abi.encode(PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, payload))) & ~uint256(1 << 255)
        );
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: PLAN_ID,
            creator: CREATOR,
            triggerHookId: HOOK_ORDER_START,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: payload,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: _selector(),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _triggerSignature(machine, trigger, _overlayAuthorizations());
        machine.triggerOrderFromOutsideFor(
            trigger,
            _overlayAuthorizations(),
            signature,
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START)
        );
        _materializeAuditStage(machine, orderId);
    }

    /// fork 机器（零词表）的兄弟出生订单：事实免证（零声明口径）。
    function _birthSecondOrderFork(UVPStateMachine machine) private returns (bytes32 orderId) {
        bytes32 payload = keccak256("executor-change-blackbox/fork-sibling");
        orderId = bytes32(
            uint256(keccak256(abi.encode(PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_ORDER_START, payload))) & ~uint256(1 << 255)
        );
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: PLAN_ID,
            creator: CREATOR,
            triggerHookId: HOOK_ORDER_START,
            triggerStageId: STAGE_INIT,
            sourceId: SOURCE_BOOTSTRAP,
            signalId: SIGNAL_ORDER_START,
            payloadHash: payload,
            idempotencyKey: IDEMPOTENCY_KEY,
            submitter: _selector(),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _triggerSignature(machine, trigger, _forkAuthorizations());
        machine.triggerOrderFromOutsideFor(trigger, _forkAuthorizations(), signature, _noAttribution());
    }

    function _triggerSignature(
        UVPStateMachine machine,
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private returns (bytes memory) {
        bytes32 authorizationsHash = _signalAuthorizationsHash(authorizations);
        bytes memory encoded = new bytes(0x180);
        _writeWord(encoded, 0x00, TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH);
        _writeWord(encoded, 0x20, trigger.planId);
        _writeAddress(encoded, 0x40, trigger.creator);
        _writeWord(encoded, 0x60, trigger.triggerHookId);
        _writeWord(encoded, 0x80, trigger.triggerStageId);
        _writeWord(encoded, 0xa0, trigger.sourceId);
        _writeWord(encoded, 0xc0, trigger.signalId);
        _writeWord(encoded, 0xe0, trigger.payloadHash);
        _writeWord(encoded, 0x100, trigger.idempotencyKey);
        _writeWord(encoded, 0x120, authorizationsHash);
        _writeAddress(encoded, 0x140, trigger.submitter);
        _writeWord(encoded, 0x160, bytes32(trigger.deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(machine), keccak256(encoded)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SELECTOR_PRIVATE_KEY, digest);
        return _packedSignature(v, r, s);
    }

    /// INIT_CMP 物化 STAGE_AUDIT（EMIT_READY hook Ready → 阶段物化）。
    function _materializeAuditStage(UVPStateMachine machine, bytes32 orderId) private {
        vm.prank(_selector());
        machine.submitSignal(
            PLAN_ID,
            orderId,
            SOURCE_BOOTSTRAP,
            SIGNAL_INIT_CMP,
            PAYLOAD_HASH,
            bytes32(uint256(0x9201)),
            _factAttribution(machine, PLAN_ID, SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP)
        );
    }

    // ---------------- patch 造证 ----------------

    function _patch(uint256 nonce, address executor, bytes32 patchHash)
        private
        pure
        returns (UVPStagePatchModule.StageExecutorPatch memory)
    {
        return _patchToStage(nonce, STAGE_AUDIT, executor, patchHash);
    }

    function _patchToStage(uint256 nonce, bytes32 targetStageId, address executor, bytes32 patchHash)
        private
        pure
        returns (UVPStagePatchModule.StageExecutorPatch memory)
    {
        return _patchWithMode(nonce, targetStageId, executor, patchHash, EXECUTOR_PATCH_MODE_ASSIGN, address(0));
    }

    function _patchWithMode(uint256 nonce, address executor, bytes32 patchHash, bytes32 mode, address previousExecutor)
        private
        pure
        returns (UVPStagePatchModule.StageExecutorPatch memory)
    {
        return _patchWithMode(nonce, STAGE_AUDIT, executor, patchHash, mode, previousExecutor);
    }

    function _patchWithMode(
        uint256 nonce,
        bytes32 targetStageId,
        address executor,
        bytes32 patchHash,
        bytes32 mode,
        address previousExecutor
    ) private pure returns (UVPStagePatchModule.StageExecutorPatch memory) {
        return UVPStagePatchModule.StageExecutorPatch({
            selectorStageId: STAGE_INIT,
            targetStageId: targetStageId,
            executor: executor,
            role: ROLE_EXECUTOR,
            executorMetadataHash: EXECUTOR_METADATA_HASH,
            mode: mode,
            previousExecutor: previousExecutor,
            authorizationsHash: bytes32(0),
            patchHash: patchHash,
            patchNonce: nonce,
            metadataURI: "uvp-eth://executor-patch"
        });
    }

    function _resourcePatchToStage(uint256 nonce, bytes32 targetStageId, bytes32 resourceKey, bytes32 patchHash)
        private
        pure
        returns (UVPStagePatchModule.StageResourcePatch memory)
    {
        return UVPStagePatchModule.StageResourcePatch({
            selectorStageId: STAGE_INIT,
            targetStageId: targetStageId,
            resourceKey: resourceKey,
            manifestHash: MANIFEST_HASH,
            policyHash: RESOURCE_POLICY_HASH,
            patchHash: patchHash,
            patchNonce: nonce,
            manifestURI: "ipfs://resource-manifest"
        });
    }

    function _withAuthHash(
        UVPStagePatchModule.StageExecutorPatch memory patch,
        IUVPStateMachineCore.SignalAuthorization[] memory authorizations
    ) private pure returns (UVPStagePatchModule.StageExecutorPatch memory) {
        patch.authorizationsHash = _authsHashLocal(authorizations);
        return patch;
    }

    /// 直接路径（msg.sender 即 selector），授权集按目标阶段能力表推导。
    function _patchDirect(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        UVPStagePatchModule.StageExecutorPatch memory patch
    ) private {
        IUVPStateMachineCore.SignalAuthorization[] memory auths =
            _executorAuthorizationsFor(machine, planId, patch.targetStageId, patch.executor);
        patch.authorizationsHash = _authsHashLocal(auths);
        _patchDirectWithAuths(machine, planId, orderId, patch, auths);
    }

    function _patchDirectWithAuths(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        UVPStagePatchModule.StageExecutorPatch memory patch,
        IUVPStateMachineCore.SignalAuthorization[] memory auths
    ) private {
        _stagePatch(machine)
            .applyStageExecutorPatch(
                planId,
                orderId,
                patch,
                _moduleBindingFor(machine, planId, patch.targetStageId),
                _candidateProofFor(machine, planId, patch.targetStageId, patch.executor),
                auths
            );
    }

    /// relayed 路径预备材料（签名在 expectRevert 之前完成）。
    /// previousExecutorPrivateKey = 0 表示不带会签。
    function _prepareRelayed(
        UVPStateMachine machine,
        bytes32 planId,
        bytes32 orderId,
        UVPStagePatchModule.StageExecutorPatch memory patch,
        uint256 selectorPrivateKey,
        uint256 previousExecutorPrivateKey
    ) private returns (PreparedPatch memory prepared) {
        prepared.patch = patch;
        prepared.selector = vm.addr(selectorPrivateKey);
        prepared.deadline = block.timestamp + 1 hours;
        prepared.authorizations = _executorAuthorizationsFor(machine, planId, patch.targetStageId, patch.executor);
        prepared.patch.authorizationsHash = _authsHashLocal(prepared.authorizations);
        bytes32 digest = _stagePatch(machine)
            .stageExecutorPatchDigest(planId, orderId, prepared.patch, prepared.selector, prepared.deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(selectorPrivateKey, digest);
        prepared.selectorSignature = _packedSignature(v, r, s);
        if (previousExecutorPrivateKey != 0) {
            (v, r, s) = vm.sign(previousExecutorPrivateKey, digest);
            prepared.previousExecutorSignature = _packedSignature(v, r, s);
        }
        prepared.bindingProof = _moduleBindingFor(machine, planId, patch.targetStageId);
        prepared.candidateProof = _candidateProofFor(machine, planId, patch.targetStageId, patch.executor);
    }

    function _sendRelayed(UVPStateMachine machine, bytes32 planId, bytes32 orderId, PreparedPatch memory prepared)
        private
    {
        _stagePatch(machine)
            .applyStageExecutorPatchFor(
                planId,
                orderId,
                prepared.patch,
                prepared.selector,
                prepared.deadline,
                prepared.selectorSignature,
                prepared.previousExecutorSignature,
                prepared.bindingProof,
                prepared.candidateProof,
                prepared.authorizations
            );
    }

    /// 出生授权集：patch/resource selector 车道 + INIT_CMP + 目标阶段双
    /// 执行者事实授权（E1/E2 全量）。
    function _overlayAuthorizations()
        private
        view
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](7);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, _selector());
        authorizations[1] = _stageAuthorization(STAGE_INIT, RESOURCE_PATCH_SIGNAL_ID, _selector());
        authorizations[2] = _stageAuthorization(SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, _selector());
        authorizations[3] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, E1());
        authorizations[4] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, E2());
        authorizations[5] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_REVIEW, E1());
        authorizations[6] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_REVIEW, E2());
    }

    function _forkChildAuthorizations()
        private
        view
        returns (UVPStateMachine.SignalAuthorization[] memory authorizations)
    {
        authorizations = new UVPStateMachine.SignalAuthorization[](1);
        authorizations[0] = _stageAuthorization(STAGE_INIT, EXECUTOR_PATCH_SIGNAL_ID, _selector());
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
            role: ROLE_EXECUTOR,
            metadataHash: EXECUTOR_METADATA_HASH
        });
    }

    /// patch 生效时写入的显式授权集：目标阶段全部 relation=0 能力键。
    function _executorAuthorizationsFor(UVPStateMachine machine, bytes32 planId, bytes32 stageId, address executor)
        private
        view
        returns (IUVPStateMachineCore.SignalAuthorization[] memory authorizations)
    {
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

    function _signalAuthorizationsHash(UVPStateMachine.SignalAuthorization[] memory authorizations)
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

    // ---------------- Merkle 造证 ----------------

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
        returns (IUVPStateMachineCore.SelectorBindingProof memory)
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

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
    }

    function _stageStateAbi(UVPStateMachine machine, bytes32 orderId)
        private
        view
        returns (uint256 count, address lastSubmitter, uint64 lastAt, bool ambiguous, bytes32 orderIdEcho)
    {
        (count, lastSubmitter, lastAt, ambiguous) = machine.stageSignalState(PLAN_ID, orderId, STAGE_AUDIT);
        orderIdEcho = orderId;
    }

    function _mergeBindings(StageSelectorBinding[] memory base, StageSelectorBinding[] memory extra)
        private
        pure
        returns (StageSelectorBinding[] memory merged)
    {
        merged = new StageSelectorBinding[](base.length + extra.length);
        for (uint256 i = 0; i < base.length; i++) {
            merged[i] = base[i];
        }
        for (uint256 i = 0; i < extra.length; i++) {
            merged[base.length + i] = extra[i];
        }
    }

    function _mergeCapabilities(SignalCapability[] memory base, SignalCapability[] memory extra)
        private
        pure
        returns (SignalCapability[] memory merged)
    {
        merged = new SignalCapability[](base.length + extra.length);
        for (uint256 i = 0; i < base.length; i++) {
            merged[i] = base[i];
        }
        for (uint256 i = 0; i < extra.length; i++) {
            merged[base.length + i] = extra[i];
        }
    }

    function _append(
        UVPStateMachine.SignalAuthorization[] memory base,
        UVPStateMachine.SignalAuthorization memory extra
    ) private pure returns (UVPStateMachine.SignalAuthorization[] memory merged) {
        merged = new UVPStateMachine.SignalAuthorization[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            merged[i] = base[i];
        }
        merged[base.length] = extra;
    }

    // ---------------- fork 机器（零词表手工 plan） ----------------

    function _forkMachineReady() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _emitReadyHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_STAGE_DONE);
        _registerPlanWithCandidates(
            machine,
            hooks,
            new StageSelectorBinding[](0),
            new SignalCapability[](0),
            PUBLISHER_PRIVATE_KEY,
            new UVPStateMachine.ExecutorCandidate[](0)
        );
        _submitBirth(machine, CREATOR, _forkAuthorizations());
    }

    function _forkAuthorizations() private view returns (UVPStateMachine.SignalAuthorization[] memory authorizations) {
        authorizations = new UVPStateMachine.SignalAuthorization[](2);
        authorizations[0] = _stageAuthorization(SOURCE_BOOTSTRAP, SIGNAL_STAGE_DONE, E1());
        authorizations[1] = _stageAuthorization(SOURCE_BOOTSTRAP, SIGNAL_STAGE_REVIEW, E2());
    }

    function _fork(
        UVPStateMachine machine,
        bytes32 parentOrderId,
        bytes32 forkPayloadHash,
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
        UVPStateMachine.ForkBirthFact[] memory facts
    ) private returns (bytes32) {
        return machine.forkOrder(
            PLAN_ID,
            parentOrderId,
            forkPayloadHash,
            approvalSourceId,
            approvalSignalId,
            facts,
            new UVPStateMachine.SignalAuthorization[](0)
        );
    }

    function _singleFact(bytes32 sourceId, bytes32 signalId, bytes32 idempotencyKey)
        private
        pure
        returns (UVPStateMachine.ForkBirthFact[] memory facts)
    {
        facts = new UVPStateMachine.ForkBirthFact[](1);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: sourceId, signalId: signalId, payloadHash: PAYLOAD_HASH, idempotencyKey: idempotencyKey
        });
    }

    function _twoFacts(bytes32 sourceA, bytes32 signalA, bytes32 idemA, bytes32 sourceB, bytes32 signalB, bytes32 idemB)
        private
        pure
        returns (UVPStateMachine.ForkBirthFact[] memory facts)
    {
        facts = new UVPStateMachine.ForkBirthFact[](2);
        facts[0] = UVPStateMachine.ForkBirthFact({
            sourceId: sourceA, signalId: signalA, payloadHash: PAYLOAD_HASH, idempotencyKey: idemA
        });
        facts[1] = UVPStateMachine.ForkBirthFact({
            sourceId: sourceB, signalId: signalB, payloadHash: PAYLOAD_HASH, idempotencyKey: idemB
        });
    }

    // ---------------- stage 键事实 fork 机器（带词表 + 绑定 + 候选集） ----------------

    function _stageFactForkMachineReady() private returns (UVPStateMachine machine) {
        machine = _newMachine();
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(HOOK_ORDER_START, STAGE_INIT, HOOK_NAME_ORDER_START, true, SIGNAL_ORDER_START);
        hooks[1] = _emitReadyHook(HOOK_AUDIT, STAGE_AUDIT, HOOK_NAME_INIT_DONE, SIGNAL_INIT_CMP);
        SignalCapability[] memory capabilities = new SignalCapability[](3);
        capabilities[0] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_ORDER_START, targetOrderRelation: 0
        });
        capabilities[1] = SignalCapability({
            stageId: STAGE_INIT, targetSourceId: SOURCE_BOOTSTRAP, signalId: SIGNAL_INIT_CMP, targetOrderRelation: 0
        });
        capabilities[2] = SignalCapability({
            stageId: STAGE_AUDIT, targetSourceId: STAGE_AUDIT, signalId: SIGNAL_STAGE_DONE, targetOrderRelation: 0
        });
        _registerPlanWithCandidates(
            machine, hooks, _selectorBindings(), capabilities, PUBLISHER_PRIVATE_KEY, _standardCandidates()
        );
        UVPStateMachine.SignalAuthorization[] memory auths = new UVPStateMachine.SignalAuthorization[](3);
        auths[0] = _stageAuthorization(SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, _selector());
        auths[1] = _stageAuthorization(STAGE_AUDIT, SIGNAL_STAGE_DONE, E1());
        auths[2] = _stageAuthorization(SOURCE_BOOTSTRAP, SIGNAL_INIT_CMP, CREATOR);
        _submitBirth(machine, CREATOR, auths);
        _materializeAuditStage(machine, ORDER_ID);

        // B8a：候选集覆盖 STAGE_AUDIT，父单 stage 键事实（fork 裁决信号 +
        // 计数源）须在 assign 后提交——EXECUTOR1 先被指派再提交。
        vm.prank(CREATOR);
        _patchDirect(machine, PLAN_ID, ORDER_ID, _patch(1, E1(), PATCH_HASH));
        vm.prank(E1());
        machine.submitSignal(
            PLAN_ID,
            ORDER_ID,
            STAGE_AUDIT,
            SIGNAL_STAGE_DONE,
            PAYLOAD_HASH,
            bytes32(uint256(0xF001)),
            _factAttribution(machine, PLAN_ID, STAGE_AUDIT, SIGNAL_STAGE_DONE)
        );
    }

    // ---------------- 杂项 ----------------

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
            flags: isTrigger ? uint8(FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY) : uint8(0),
            instructions: instructions,
            dependencyKeys: _deps(signalId)
        });
    }

    function _emitReadyHook(bytes32 hookId, bytes32 stageId, bytes32 hookName, bytes32 signalId)
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
            flags: FLAG_EMIT_READY,
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

    function _deps(bytes32 signalId) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(SOURCE_BOOTSTRAP, signalId));
    }

    function _packedSignature(uint8 v, bytes32 r, bytes32 s) private pure returns (bytes memory) {
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _domainSeparator(UVPStateMachine machine) private view returns (bytes32) {
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

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                count += 1;
            }
        }
    }
}
