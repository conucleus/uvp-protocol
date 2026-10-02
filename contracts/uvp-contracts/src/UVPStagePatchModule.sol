// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";

interface IUVPPlanMetadataModuleForStagePatch {
    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool);
}

// 执行者候选集叶域（UB-36②③）：与 UVPStateMachineConstants 的
// _EXECUTOR_CANDIDATE_LEAF_DOMAIN 同值（模块侧重导出为 public 常量，
// 供链下构造 proof 的消费方对拍）。叶 = keccak256(abi.encodePacked(
// EXECUTOR_CANDIDATE_LEAF_DOMAIN, stageId, executor))。
bytes32 constant _EXECUTOR_CANDIDATE_LEAF_DOMAIN = keccak256("UVP_EXECUTOR_CANDIDATE_V1");

contract UVPStagePatchModule {
    /// executor patch 请求（UB-36①④/UB-39 形态）：
    /// - 模式词表为 assign/handoff 闭集；非协作换人不在 patch 面——
    ///   forkOrder 车道以裁决信号绑定承接。
    /// - authorizationsHash（UB-36①）：patch 生效时对新城执行者写入的
    ///   显式订单级授权集哈希（stateMachine.signalAuthorizationsHash 公式），
    ///   进 EIP-712 digest——授权来源 = selector 的 patch 签名（签名覆盖
    ///   授权集，provenance 可审计）。
    struct StageExecutorPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 mode;
        address previousExecutor;
        bytes32 authorizationsHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
    }

    struct StageResourcePatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        bytes32 resourceKey;
        bytes32 manifestHash;
        bytes32 policyHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string manifestURI;
    }

    struct ActiveStageExecutorPatch {
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string metadataURI;
        bool exists;
    }

    struct ActiveStageResourcePatch {
        bytes32 manifestHash;
        bytes32 policyHash;
        bytes32 patchHash;
        uint256 patchNonce;
        string manifestURI;
        bool exists;
    }

    error ExpiredStageExecutorPatchSignature(uint256 deadline);
    error ExpiredStageResourcePatchSignature(uint256 deadline);
    error InvalidStageExecutorPatchMode(bytes32 mode);
    error InvalidStageExecutorPatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageExecutorPatchSignatureLength(uint256 length);
    error InvalidStageResourcePatchSignature(address expectedSigner, address recoveredSigner);
    error InvalidStageResourcePatchSignatureLength(uint256 length);
    error StageAlreadyHasSignal(bytes32 orderId, bytes32 targetStageId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error StageExecutorPatchPreviousExecutorMismatch(
        bytes32 orderId, bytes32 targetStageId, address expectedExecutor, address previousExecutor
    );
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    /// 出生（mint/dock）阶段的执行者终生不可变（云侧已强制，合约同口径守门）：
    /// 逐单 executor patch 在合约侧读 plan hook flags 补门。
    /// 资源补丁不受此门——资源可替换。
    error StageExecutorPatchForbiddenOnBirthStage(bytes32 orderId, bytes32 targetStageId);
    /// 同秒平局 fail-closed：最高 submittedAt 并列且提交者不同时，
    /// "上一执行者"没有确定序——拒绝而不是静默取值（判定材料改读合约
    /// 原生 per-stage 计数的 ambiguity 标记，UB-2）。
    error StagePreviousExecutorAmbiguous(bytes32 orderId, bytes32 targetStageId, uint64 submittedAt);
    error StageResourcePatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey, uint256 previousNonce, uint256 patchNonce
    );
    /// 候选集闸（UB-36②③）：(targetStageId, patch.executor) 不在 plan 承诺
    /// 的执行者候选集内，或 plan 未承诺候选集（root==EMPTY_ROOT——无候选
    /// 集的计划没有逐单换人面，patch 恒拒，fail-closed）。两类拒绝同报此
    /// 错：对调用方而言都是"目标不是候选集成员"。
    error StageExecutorNotCandidate(bytes32 planId, bytes32 orderId, bytes32 targetStageId, address executor);
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error UnauthorizedStageExecutorPatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnauthorizedStageResourcePatchSelector(bytes32 orderId, bytes32 selectorStageId, address selector);
    error UnknownOrder();
    error ZeroManifestHash();
    error ZeroPatchHash();
    error ZeroPolicyHash();
    error ZeroResourceKey();
    error ZeroSelector();
    error ZeroSelectorStageId();
    error ZeroStageExecutor();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    bytes32 public constant EXECUTOR_PATCH_SIGNAL_ID =
        0xbbb1770c9313f4029a89e03f4719037cdad52864ab4da5f623bc7c8a0c489e97;
    bytes32 public constant RESOURCE_PATCH_SIGNAL_ID =
        0x6dff331f2bb7b785cbcd99a911e6d30dc8714f43b3b9ba80c658215445ddd0ba;
    bytes32 public constant EXECUTOR_PATCH_MODE_ASSIGN = bytes32("assign");
    bytes32 public constant EXECUTOR_PATCH_MODE_HANDOFF = bytes32("handoff");
    /// 候选集叶域（UB-36②③）：commitPlan 建树与 patch 验叶同一公式。
    bytes32 public constant EXECUTOR_CANDIDATE_LEAF_DOMAIN = _EXECUTOR_CANDIDATE_LEAF_DOMAIN;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStagePatchModule");
    // 0.1 → 0.2（UB-36①④ 破坏性批）：StageExecutorPatch 结构变化
    //（approval 字段删除、authorizationsHash 新增），digest 面整体换血。
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.2");
    // patch 签名绑定订单的
    // (planId, orderId) 复合身份。
    bytes32 private constant _STAGE_EXECUTOR_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 authorizationsHash,bytes32 patchHash,uint256 patchNonce,string metadataURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_RESOURCE_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageResourcePatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC = keccak256(
        "StageExecutorPatchApplied(bytes32,bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,uint256,string)"
    );

    // patch 存储按 (planId, orderId) 复合键寻址。
    mapping(
        bytes32 planId => mapping(bytes32 orderId => mapping(bytes32 targetStageId => ActiveStageExecutorPatch patch))
    ) private _activeStageExecutorPatches;
    mapping(
        bytes32 planId
            => mapping(
            bytes32 orderId
                => mapping(bytes32 targetStageId => mapping(bytes32 resourceKey => ActiveStageResourcePatch patch))
        )
    ) private _activeStageResourcePatches;

    event StageExecutorPatchApplied(
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 indexed targetStageId,
        bytes32 planId,
        address selector,
        address executor,
        bytes32 role,
        bytes32 executorMetadataHash,
        bytes32 mode,
        address previousExecutor,
        // UB-36①：授权集哈希随事件广播（授权明细经
        // SignalSubmitterAuthorized 事件流可完整重建）。
        bytes32 authorizationsHash,
        bytes32 patchHash,
        uint256 patchNonce,
        string metadataURI
    );
    event StageResourcePatchApplied(
        // 与同合约 ExecutorPatchApplied 对齐携带
        // planId——两 plan 同号订单的事件字节级不同。
        bytes32 indexed orderId,
        bytes32 indexed selectorStageId,
        bytes32 indexed targetStageId,
        bytes32 planId,
        address selector,
        bytes32 resourceKey,
        bytes32 manifestHash,
        bytes32 policyHash,
        bytes32 patchHash,
        uint256 patchNonce,
        string manifestURI
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function applyStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) external {
        _applyStageExecutorPatch(
            planId, orderId, patch, msg.sender, address(0), bindingProof, candidateProof, executorAuthorizations
        );
    }

    function applyStageExecutorPatchFor(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        bytes calldata previousExecutorSignature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageExecutorPatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        bytes32 digest = stageExecutorPatchDigest(planId, orderId, patch, selector, deadline);
        address recoveredSigner = _recoverStageExecutorPatchSigner(digest, selectorSignature);
        if (recoveredSigner != selector) {
            revert InvalidStageExecutorPatchSignature(selector, recoveredSigner);
        }

        address recoveredPreviousExecutor;
        if (previousExecutorSignature.length != 0) {
            recoveredPreviousExecutor = _recoverStageExecutorPatchSigner(digest, previousExecutorSignature);
        }

        _applyStageExecutorPatch(
            planId,
            orderId,
            patch,
            selector,
            recoveredPreviousExecutor,
            bindingProof,
            candidateProof,
            executorAuthorizations
        );
    }

    function applyStageResourcePatch(
        bytes32 planId,
        bytes32 orderId,
        StageResourcePatch calldata patch,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) external {
        _applyStageResourcePatch(planId, orderId, patch, msg.sender, bindingProof);
    }

    function applyStageResourcePatchFor(
        bytes32 planId,
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata signature,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredStageResourcePatchSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        address recoveredSigner = _recoverStageResourcePatchSelector(
            stageResourcePatchDigest(planId, orderId, patch, selector, deadline), signature
        );
        if (recoveredSigner != selector) {
            revert InvalidStageResourcePatchSignature(selector, recoveredSigner);
        }

        _applyStageResourcePatch(planId, orderId, patch, selector, bindingProof);
    }

    function activeStageExecutor(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (address)
    {
        return _activeStageExecutorPatches[planId][orderId][targetStageId].executor;
    }

    function orderStageExecutorPatchNonce(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (uint256)
    {
        return _activeStageExecutorPatches[planId][orderId][targetStageId].patchNonce;
    }

    function getActiveStageExecutorPatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId)
        external
        view
        returns (
            bool exists,
            address executor,
            bytes32 role,
            bytes32 executorMetadataHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory metadataURI
        )
    {
        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][targetStageId];
        return (
            activePatch.exists,
            activePatch.executor,
            activePatch.role,
            activePatch.executorMetadataHash,
            activePatch.patchHash,
            activePatch.patchNonce,
            activePatch.metadataURI
        );
    }

    function orderStageResourcePatchNonce(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (uint256)
    {
        return _activeStageResourcePatches[planId][orderId][targetStageId][resourceKey].patchNonce;
    }

    function getActiveStageResourcePatch(bytes32 planId, bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey)
        external
        view
        returns (
            bool exists,
            bytes32 manifestHash,
            bytes32 policyHash,
            bytes32 patchHash,
            uint256 patchNonce,
            string memory manifestURI
        )
    {
        ActiveStageResourcePatch storage activePatch =
            _activeStageResourcePatches[planId][orderId][targetStageId][resourceKey];
        return (
            activePatch.exists,
            activePatch.manifestHash,
            activePatch.policyHash,
            activePatch.patchHash,
            activePatch.patchNonce,
            activePatch.manifestURI
        );
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function stageExecutorPatchDigest(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                _stageExecutorPatchStructHash(planId, orderId, patch, selector, deadline)
            )
        );
    }

    function stageResourcePatchDigest(
        bytes32 planId,
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _STAGE_RESOURCE_PATCH_TYPEHASH,
                planId,
                orderId,
                patch.selectorStageId,
                patch.targetStageId,
                patch.resourceKey,
                patch.manifestHash,
                patch.policyHash,
                patch.patchHash,
                patch.patchNonce,
                keccak256(bytes(patch.manifestURI)),
                selector,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _applyStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        address previousExecutorSigner,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof,
        IUVPStateMachineCore.SignalAuthorization[] calldata executorAuthorizations
    ) private {
        _validateStageExecutorPatch(planId, orderId, patch, selector, bindingProof, candidateProof);

        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][patch.targetStageId];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, patch.targetStageId, activePatch.patchNonce, patch.patchNonce
            );
        }
        _validateStageExecutorPatchMode(planId, orderId, patch, activePatch, previousExecutorSigner);
        // 授权集一致性（UB-36①）：digest 承诺的 authorizationsHash 必须与
        // 实际写入的授权集一致——selector 签名覆盖的就是这份集，中途换集
        /// 等于伪造授权来源。
        if (stateMachine.signalAuthorizationsHash(executorAuthorizations) != patch.authorizationsHash) {
            revert InvalidStageExecutorPatchSignature(selector, address(0));
        }

        activePatch.executor = patch.executor;
        activePatch.role = patch.role;
        activePatch.executorMetadataHash = patch.executorMetadataHash;
        activePatch.patchHash = patch.patchHash;
        activePatch.patchNonce = patch.patchNonce;
        activePatch.metadataURI = patch.metadataURI;
        activePatch.exists = true;

        _emitStageExecutorPatchApplied(planId, orderId, patch, selector);
        stateMachine.activateStageExecutorFromModule(
            planId,
            orderId,
            patch.targetStageId,
            patch.executor,
            patch.role,
            patch.executorMetadataHash,
            patch.patchHash,
            patch.patchNonce,
            patch.metadataURI
        );
        // 委托通道的替代（UB-36①）：patch 生效时对新城执行者写入显式订单
        // 级授权（经 stateMachine 同口径入口——零字键/重复授权等注册期
        // 校验与事件广播全部复用）。授权来源 = selector 的 patch 签名。
        stateMachine.authorizeSignalSubmittersFromModule(planId, orderId, executorAuthorizations);
    }

    function _validateStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof,
        bytes32[] calldata candidateProof
    ) private view {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.executor == address(0)) {
            revert ZeroStageExecutor();
        }
        if (patch.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        if (!_isStageExecutorPatchMode(patch.mode)) {
            revert InvalidStageExecutorPatchMode(patch.mode);
        }
        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }
        // 出生阶段守门：目标阶段挂有 mint/dock trigger hook 时
        // 拒绝逐单 executor patch——云侧已强制"订阅/出生阶段终生不可变"，
        // 合约读 flags 补门封死绕行。fileResources-only 资源补丁不经过本
        // 函数（_applyStageResourcePatch），资源可替换已裁决。
        if (stateMachine.stageHasOrderTriggerHook(planId, patch.targetStageId)) {
            revert StageExecutorPatchForbiddenOnBirthStage(orderId, patch.targetStageId);
        }
        // 候选集闸（UB-36②③）：所有模式的 executor patch 都必须证明
        // (targetStageId, patch.executor) ∈ plan 承诺的候选集——无候选集
        //（EMPTY_ROOT）恒拒（不开候选集的计划没有逐单换人面），有候选集
        // 验不过 Merkle proof 恒拒。creator/selector 的 patch 权不变，但
        // 目标必须命中候选集：候选集外没有任何人（包括 creator 指定）
        // 可以成为逐单执行者。
        {
            bytes32 candidatesRoot = stateMachine.planExecutorCandidatesRoot(planId);
            bytes32 leaf =
                keccak256(abi.encodePacked(EXECUTOR_CANDIDATE_LEAF_DOMAIN, patch.targetStageId, patch.executor));
            if (candidatesRoot == DockMerkle.EMPTY_ROOT || !DockMerkle.verify(candidatesRoot, leaf, candidateProof)) {
                revert StageExecutorNotCandidate(planId, orderId, patch.targetStageId, patch.executor);
            }
        }
        // 绑定成员资格按"字段重算叶 + 携 proof"验证（叶子不自报）；证明
        // 携带的 selector 必须与 patch 声明一致。
        if (
            bindingProof.selectorStageId != patch.selectorStageId
                || !_planMetadata()
                    .verifyStageSelectorBinding(planId, patch.selectorStageId, patch.targetStageId, bindingProof.proof)
        ) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        // selector 权：显式 EXECUTOR_PATCH_SIGNAL 授权，或订单 creator 自身。
        // docked 订单 creator = 目标 plan publisher（DockingModule 派生），
        // 引导权随订单创建派生，keeper 不经此获得任何权利。
        if (
            !stateMachine.hasExplicitSignalAuthorization(
                    planId, orderId, patch.selectorStageId, EXECUTOR_PATCH_SIGNAL_ID, selector
                ) && selector != stateMachine.orderCreator(planId, orderId)
        ) {
            revert UnauthorizedStageExecutorPatchSelector(orderId, patch.selectorStageId, selector);
        }
    }

    function _validateStageExecutorPatchMode(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        ActiveStageExecutorPatch storage activePatch,
        address previousExecutorSigner
    ) private view {
        // previousExecutorSignature 只在 HANDOFF 是授权材料（上一执行者对
        // 同一 digest 的会签）。ASSIGN 携带非空签名时静默丢弃
        // 会让调用方误以为签名参与了授权——API 语义一致化：附带即拒绝
        //（expected=0：该模式下没有任何被期待的上一执行者签名）。
        if (patch.mode != EXECUTOR_PATCH_MODE_HANDOFF && previousExecutorSigner != address(0)) {
            revert InvalidStageExecutorPatchSignature(address(0), previousExecutorSigner);
        }
        // 时序闸改读合约原生 per-stage 计数（UB-2 封口）：计数在
        // _recordSignal 内按统一归属口径维护（携证属主优先，零词表回退
        // source==stage），不再依赖调用方携证供表——省证提交无法绕过。
        (uint256 signalCount, address latestSignalSubmitter, uint64 latestSubmittedAt, bool latestAmbiguous) =
            stateMachine.stageSignalState(planId, orderId, patch.targetStageId);
        if (patch.mode == EXECUTOR_PATCH_MODE_ASSIGN) {
            if (patch.previousExecutor != address(0)) {
                revert StageExecutorPatchPreviousExecutorMismatch(
                    orderId, patch.targetStageId, address(0), patch.previousExecutor
                );
            }
            if (signalCount != 0) {
                revert StageAlreadyHasSignal(orderId, patch.targetStageId);
            }
            return;
        }

        if (signalCount == 0) {
            revert StageHasNoSignal(orderId, patch.targetStageId);
        }

        address expectedPreviousExecutor = activePatch.exists ? activePatch.executor : latestSignalSubmitter;
        // 同秒平局 fail-closed：回退到"最近提交者"判定且
        // 最高 submittedAt 并列不同提交者时，没有确定序——拒绝。active
        // patch 存在时不回退（patch executor 是权威上一执行者），无歧义。
        if (!activePatch.exists && latestAmbiguous) {
            revert StagePreviousExecutorAmbiguous(orderId, patch.targetStageId, latestSubmittedAt);
        }
        if (patch.previousExecutor != expectedPreviousExecutor) {
            revert StageExecutorPatchPreviousExecutorMismatch(
                orderId, patch.targetStageId, expectedPreviousExecutor, patch.previousExecutor
            );
        }

        // HANDOFF：上一执行者对同一 digest 的会签是唯一授权材料。
        if (previousExecutorSigner != patch.previousExecutor) {
            revert InvalidStageExecutorPatchSignature(patch.previousExecutor, previousExecutorSigner);
        }
    }

    function _applyStageResourcePatch(
        bytes32 planId,
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        IUVPStateMachineCore.SelectorBindingProof calldata bindingProof
    ) private {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (patch.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (patch.targetStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (patch.resourceKey == bytes32(0)) {
            revert ZeroResourceKey();
        }
        if (patch.manifestHash == bytes32(0)) {
            revert ZeroManifestHash();
        }
        if (patch.policyHash == bytes32(0)) {
            revert ZeroPolicyHash();
        }
        if (patch.patchHash == bytes32(0)) {
            revert ZeroPatchHash();
        }
        if (!stateMachine.orderExists(planId, orderId)) {
            revert UnknownOrder();
        }

        if (
            bindingProof.selectorStageId != patch.selectorStageId
                || !_planMetadata()
                    .verifyStageSelectorBinding(planId, patch.selectorStageId, patch.targetStageId, bindingProof.proof)
        ) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!stateMachine.hasExplicitSignalAuthorization(
                planId, orderId, patch.selectorStageId, RESOURCE_PATCH_SIGNAL_ID, selector
            )) {
            revert UnauthorizedStageResourcePatchSelector(orderId, patch.selectorStageId, selector);
        }
        // 资源补丁时序闸同读合约原生 per-stage 计数（UB-2）：目标阶段收到
        // 首个信号（任何归属口径）即永久关闭资源窗口。
        (uint256 signalCount,,,) = stateMachine.stageSignalState(planId, orderId, patch.targetStageId);
        if (signalCount != 0) {
            revert StageAlreadyHasSignal(orderId, patch.targetStageId);
        }

        ActiveStageResourcePatch storage activePatch =
            _activeStageResourcePatches[planId][orderId][patch.targetStageId][patch.resourceKey];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageResourcePatchNonceNotIncreasing(
                orderId, patch.targetStageId, patch.resourceKey, activePatch.patchNonce, patch.patchNonce
            );
        }

        activePatch.manifestHash = patch.manifestHash;
        activePatch.policyHash = patch.policyHash;
        activePatch.patchHash = patch.patchHash;
        activePatch.patchNonce = patch.patchNonce;
        activePatch.manifestURI = patch.manifestURI;
        activePatch.exists = true;

        emit StageResourcePatchApplied(
            orderId,
            patch.selectorStageId,
            patch.targetStageId,
            planId,
            selector,
            patch.resourceKey,
            patch.manifestHash,
            patch.policyHash,
            patch.patchHash,
            patch.patchNonce,
            patch.manifestURI
        );
    }

    function _isStageExecutorPatchMode(bytes32 mode) private pure returns (bool) {
        return mode == EXECUTOR_PATCH_MODE_ASSIGN || mode == EXECUTOR_PATCH_MODE_HANDOFF;
    }

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForStagePatch) {
        return IUVPPlanMetadataModuleForStagePatch(stateMachine.planMetadataModule());
    }

    function _stageExecutorPatchStructHash(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline
    ) private pure returns (bytes32) {
        // 手写偏移布局与 _STAGE_EXECUTOR_PATCH_TYPEHASH 字段序逐字对齐
        //（16 词 = 0x200）：typehash, planId, orderId, selectorStageId,
        // targetStageId, executor, role, executorMetadataHash, mode,
        // previousExecutor, authorizationsHash, patchHash, patchNonce,
        // keccak(metadataURI), selector, deadline。
        bytes memory encoded = new bytes(0x200);
        _writeWord(encoded, 0x00, _STAGE_EXECUTOR_PATCH_TYPEHASH);
        _writeWord(encoded, 0x20, planId);
        _writeWord(encoded, 0x40, orderId);
        _writeWord(encoded, 0x60, patch.selectorStageId);
        _writeWord(encoded, 0x80, patch.targetStageId);
        _writeAddress(encoded, 0xa0, patch.executor);
        _writeWord(encoded, 0xc0, patch.role);
        _writeWord(encoded, 0xe0, patch.executorMetadataHash);
        _writeWord(encoded, 0x100, patch.mode);
        _writeAddress(encoded, 0x120, patch.previousExecutor);
        _writeWord(encoded, 0x140, patch.authorizationsHash);
        _writeWord(encoded, 0x160, patch.patchHash);
        _writeWord(encoded, 0x180, bytes32(patch.patchNonce));
        _writeWord(encoded, 0x1a0, keccak256(bytes(patch.metadataURI)));
        _writeAddress(encoded, 0x1c0, selector);
        _writeWord(encoded, 0x1e0, bytes32(deadline));
        return keccak256(encoded);
    }

    function _emitStageExecutorPatchApplied(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector
    ) private {
        // 非 indexed 数据布局：10 个静态词（0x140）+ string 头偏移词（指向
        // 0x160）+ 长度词 + 变长 URI 数据。planId, selector, executor, role,
        // executorMetadataHash, mode, previousExecutor, authorizationsHash,
        // patchHash, patchNonce。
        bytes memory metadataURI = bytes(patch.metadataURI);
        bytes memory eventData = new bytes(0x180 + _paddedLength(metadataURI.length));
        _writeWord(eventData, 0x00, planId);
        _writeAddress(eventData, 0x20, selector);
        _writeAddress(eventData, 0x40, patch.executor);
        _writeWord(eventData, 0x60, patch.role);
        _writeWord(eventData, 0x80, patch.executorMetadataHash);
        _writeWord(eventData, 0xa0, patch.mode);
        _writeAddress(eventData, 0xc0, patch.previousExecutor);
        _writeWord(eventData, 0xe0, patch.authorizationsHash);
        _writeWord(eventData, 0x100, patch.patchHash);
        _writeWord(eventData, 0x120, bytes32(patch.patchNonce));
        _writeWord(eventData, 0x140, bytes32(uint256(0x160)));
        _writeWord(eventData, 0x160, bytes32(metadataURI.length));
        _copyBytes(eventData, 0x180, metadataURI);

        bytes32 selectorStageId = patch.selectorStageId;
        bytes32 targetStageId = patch.targetStageId;
        bytes32 topic = _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC;
        assembly {
            log4(add(eventData, 0x20), mload(eventData), topic, orderId, selectorStageId, targetStageId)
        }
    }

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }

    function _copyBytes(bytes memory target, uint256 offset, bytes memory source) private pure {
        for (uint256 i = 0; i < source.length; i++) {
            target[offset + i] = source[i];
        }
    }

    function _paddedLength(uint256 length) private pure returns (uint256) {
        return (length + 31) & ~uint256(31);
    }

    function _recoverStageExecutorPatchSigner(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidStageExecutorPatchSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }

    function _recoverStageResourcePatchSelector(bytes32 digest, bytes calldata signature)
        private
        pure
        returns (address)
    {
        if (signature.length != 65) {
            revert InvalidStageResourcePatchSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }
}
