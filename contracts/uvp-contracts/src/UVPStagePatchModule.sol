// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

interface IUVPPlanMetadataModuleForStagePatch {
    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        external
        view
        returns (bool);
    function stageSignalCapabilityCount(bytes32 planId, bytes32 stageId) external view returns (uint256);
    function stageSignalCapabilityAt(bytes32 planId, bytes32 stageId, uint256 index)
        external
        view
        returns (bytes32 targetSourceId, bytes32 signalId, uint8 targetOrderRelation);
}

contract UVPStagePatchModule {
    struct StageExecutorPatch {
        bytes32 selectorStageId;
        bytes32 targetStageId;
        address executor;
        bytes32 role;
        bytes32 executorMetadataHash;
        bytes32 mode;
        address previousExecutor;
        bytes32 approvalSourceId;
        bytes32 approvalSignalId;
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
    error StageExecutorPatchApprovalSignalMissing(bytes32 orderId, bytes32 approvalSourceId, bytes32 approvalSignalId);
    error StageExecutorPatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, uint256 previousNonce, uint256 patchNonce
    );
    error StageExecutorPatchPreviousExecutorMismatch(
        bytes32 orderId, bytes32 targetStageId, address expectedExecutor, address previousExecutor
    );
    error StageHasNoSignal(bytes32 orderId, bytes32 targetStageId);
    /// 出生（mint/dock）阶段的执行者终生不可变（簇 I 裁决，云侧已强制）：
    /// 逐单 executor patch 在合约侧读 plan hook flags 补门（0212 P1-3）。
    /// 资源补丁不受此门——资源可替换已裁决。
    error StageExecutorPatchForbiddenOnBirthStage(bytes32 orderId, bytes32 targetStageId);
    /// 同秒平局 fail-closed（F7/O6/ETH-5）：最高 submittedAt 并列且提交者
    /// 不同时，"上一执行者"没有确定序——拒绝而不是按 capability 数组枚举
    /// 序静默取值。
    error StagePreviousExecutorAmbiguous(bytes32 orderId, bytes32 targetStageId, uint64 submittedAt);
    error StageSignalCapabilityMissing(bytes32 planId, bytes32 targetStageId);
    error StageResourcePatchNonceNotIncreasing(
        bytes32 orderId, bytes32 targetStageId, bytes32 resourceKey, uint256 previousNonce, uint256 patchNonce
    );
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
    bytes32 public constant EXECUTOR_PATCH_MODE_REPLACEMENT = bytes32("replacement");

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPStagePatchModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.1");
    // patch 签名绑定订单的
    // (planId, orderId) 复合身份。
    bytes32 private constant _STAGE_EXECUTOR_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageExecutorPatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,address executor,bytes32 role,bytes32 executorMetadataHash,bytes32 mode,address previousExecutor,bytes32 approvalSourceId,bytes32 approvalSignalId,bytes32 patchHash,uint256 patchNonce,string metadataURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_RESOURCE_PATCH_TYPEHASH = keccak256(
        "UVPStagePatchModuleStageResourcePatch(bytes32 planId,bytes32 orderId,bytes32 selectorStageId,bytes32 targetStageId,bytes32 resourceKey,bytes32 manifestHash,bytes32 policyHash,bytes32 patchHash,uint256 patchNonce,string manifestURI,address selector,uint256 deadline)"
    );
    bytes32 private constant _STAGE_EXECUTOR_PATCH_APPLIED_TOPIC = keccak256(
        "StageExecutorPatchApplied(bytes32,bytes32,bytes32,bytes32,address,address,bytes32,bytes32,bytes32,address,bytes32,bytes32,bytes32,uint256,string)"
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
        bytes32 approvalSourceId,
        bytes32 approvalSignalId,
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

    function applyStageExecutorPatch(bytes32 planId, bytes32 orderId, StageExecutorPatch calldata patch) external {
        _applyStageExecutorPatch(planId, orderId, patch, msg.sender, address(0));
    }

    function applyStageExecutorPatchFor(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata selectorSignature,
        bytes calldata previousExecutorSignature
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

        _applyStageExecutorPatch(planId, orderId, patch, selector, recoveredPreviousExecutor);
    }

    function applyStageResourcePatch(bytes32 planId, bytes32 orderId, StageResourcePatch calldata patch) external {
        _applyStageResourcePatch(planId, orderId, patch, msg.sender);
    }

    function applyStageResourcePatchFor(
        bytes32 planId,
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector,
        uint256 deadline,
        bytes calldata signature
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

        _applyStageResourcePatch(planId, orderId, patch, selector);
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
        address previousExecutorSigner
    ) private {
        _validateStageExecutorPatch(planId, orderId, patch, selector);

        ActiveStageExecutorPatch storage activePatch = _activeStageExecutorPatches[planId][orderId][patch.targetStageId];
        if (patch.patchNonce <= activePatch.patchNonce) {
            revert StageExecutorPatchNonceNotIncreasing(
                orderId, patch.targetStageId, activePatch.patchNonce, patch.patchNonce
            );
        }
        _validateStageExecutorPatchMode(planId, orderId, patch, activePatch, previousExecutorSigner);

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
        _delegateStageExecutorSignals(planId, orderId, patch);
    }

    function _delegateStageExecutorSignals(bytes32 planId, bytes32 orderId, StageExecutorPatch calldata patch) private {
        IUVPPlanMetadataModuleForStagePatch metadata = _planMetadata();
        uint256 capabilityCount = metadata.stageSignalCapabilityCount(planId, patch.targetStageId);
        uint256 delegatedCount;

        for (uint256 i = 0; i < capabilityCount; i++) {
            (bytes32 targetSourceId, bytes32 signalId, uint8 relation) =
                metadata.stageSignalCapabilityAt(planId, patch.targetStageId, i);
            if (relation != 0) {
                continue;
            }
            _delegateStageExecutorSignal(planId, orderId, targetSourceId, signalId, patch);
            delegatedCount += 1;
        }

        if (delegatedCount == 0) {
            revert StageSignalCapabilityMissing(planId, patch.targetStageId);
        }
    }

    function _delegateStageExecutorSignal(
        bytes32 planId,
        bytes32 orderId,
        bytes32 targetSourceId,
        bytes32 signalId,
        StageExecutorPatch calldata patch
    ) private {
        stateMachine.delegateStageExecutorSignalFromModule(
            planId,
            orderId,
            patch.targetStageId,
            targetSourceId,
            signalId,
            patch.executor,
            patch.role,
            patch.executorMetadataHash,
            patch.patchNonce
        );
    }

    function _validateStageExecutorPatch(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector
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
        // 出生阶段守门（簇 I 裁决）：目标阶段挂有 mint/dock trigger hook 时
        // 拒绝逐单 executor patch——云侧已强制"订阅/出生阶段终生不可变"，
        // 合约读 flags 补门封死绕行。fileResources-only 资源补丁不经过本
        // 函数（_applyStageResourcePatch），资源可替换已裁决。
        if (stateMachine.stageHasOrderTriggerHook(planId, patch.targetStageId)) {
            revert StageExecutorPatchForbiddenOnBirthStage(orderId, patch.targetStageId);
        }
        if (!_planMetadata().isStageSelectorBound(planId, patch.selectorStageId, patch.targetStageId)) {
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
        (uint256 signalCount, address latestSignalSubmitter, uint64 latestSubmittedAt, bool latestAmbiguous) =
            _stageSignalState(planId, orderId, patch.targetStageId);
        if (patch.mode == EXECUTOR_PATCH_MODE_ASSIGN) {
            if (patch.previousExecutor != address(0)) {
                revert StageExecutorPatchPreviousExecutorMismatch(
                    orderId, patch.targetStageId, address(0), patch.previousExecutor
                );
            }
            if (patch.approvalSourceId != bytes32(0) || patch.approvalSignalId != bytes32(0)) {
                revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
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
        // 同秒平局 fail-closed（F7/O6/ETH-5）：回退到"最近提交者"判定且
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

        if (patch.mode == EXECUTOR_PATCH_MODE_HANDOFF) {
            if (patch.approvalSourceId != bytes32(0) || patch.approvalSignalId != bytes32(0)) {
                revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
            }
            if (previousExecutorSigner != patch.previousExecutor) {
                revert InvalidStageExecutorPatchSignature(patch.previousExecutor, previousExecutorSigner);
            }
            return;
        }

        if (!stateMachine.hasSignal(planId, orderId, patch.approvalSourceId, patch.approvalSignalId)) {
            revert StageExecutorPatchApprovalSignalMissing(orderId, patch.approvalSourceId, patch.approvalSignalId);
        }
    }

    function _applyStageResourcePatch(
        bytes32 planId,
        bytes32 orderId,
        StageResourcePatch calldata patch,
        address selector
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

        if (!_planMetadata().isStageSelectorBound(planId, patch.selectorStageId, patch.targetStageId)) {
            revert StageSelectorBindingNotFound(planId, patch.selectorStageId, patch.targetStageId);
        }
        if (!stateMachine.hasExplicitSignalAuthorization(
                planId, orderId, patch.selectorStageId, RESOURCE_PATCH_SIGNAL_ID, selector
            )) {
            revert UnauthorizedStageResourcePatchSelector(orderId, patch.selectorStageId, selector);
        }
        (uint256 signalCount,,,) = _stageSignalState(planId, orderId, patch.targetStageId);
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
        return mode == EXECUTOR_PATCH_MODE_ASSIGN || mode == EXECUTOR_PATCH_MODE_HANDOFF
            || mode == EXECUTOR_PATCH_MODE_REPLACEMENT;
    }

    /// Count signals belonging to the target stage by its compiled capability
    /// declarations. A production source id is not the stage id: the former
    /// identifies a business source/class while the latter identifies the
    /// stage path. Looking up sourceSignalCount with targetStageId therefore
    /// lets assign patches through after a real stage signal and makes
    /// handoff/replacement read the wrong previous submitter.
    function _stageSignalState(bytes32 planId, bytes32 orderId, bytes32 stageId)
        private
        view
        returns (uint256 count, address latestSubmitter, uint64 latestSubmittedAt, bool latestAmbiguous)
    {
        IUVPPlanMetadataModuleForStagePatch metadata = _planMetadata();
        uint256 capabilityCount = metadata.stageSignalCapabilityCount(planId, stageId);
        for (uint256 i = 0; i < capabilityCount; i++) {
            (bytes32 sourceId, bytes32 signalId, uint8 relation) = metadata.stageSignalCapabilityAt(planId, stageId, i);
            if (relation != 0) {
                continue;
            }
            (bool exists,,, uint64 submittedAt, address submitter) =
                stateMachine.getSignal(planId, orderId, sourceId, signalId);
            if (!exists) {
                continue;
            }
            count += 1;
            // 最高 submittedAt 的并列提交者检测：更大的时间戳重置判定，
            // 同秒不同提交者标记歧义——消费者必须 fail-closed，不得按
            // capability 数组枚举序静默取"最后一个"。
            if (submittedAt > latestSubmittedAt) {
                latestSubmittedAt = submittedAt;
                latestSubmitter = submitter;
                latestAmbiguous = false;
            } else if (submittedAt == latestSubmittedAt && submitter != latestSubmitter) {
                latestAmbiguous = true;
            }
        }
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
        bytes memory encoded = new bytes(0x220);
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
        _writeWord(encoded, 0x140, patch.approvalSourceId);
        _writeWord(encoded, 0x160, patch.approvalSignalId);
        _writeWord(encoded, 0x180, patch.patchHash);
        _writeWord(encoded, 0x1a0, bytes32(patch.patchNonce));
        _writeWord(encoded, 0x1c0, keccak256(bytes(patch.metadataURI)));
        _writeAddress(encoded, 0x1e0, selector);
        _writeWord(encoded, 0x200, bytes32(deadline));
        return keccak256(encoded);
    }

    function _emitStageExecutorPatchApplied(
        bytes32 planId,
        bytes32 orderId,
        StageExecutorPatch calldata patch,
        address selector
    ) private {
        bytes memory metadataURI = bytes(patch.metadataURI);
        bytes memory eventData = new bytes(0x1a0 + _paddedLength(metadataURI.length));
        _writeWord(eventData, 0x00, planId);
        _writeAddress(eventData, 0x20, selector);
        _writeAddress(eventData, 0x40, patch.executor);
        _writeWord(eventData, 0x60, patch.role);
        _writeWord(eventData, 0x80, patch.executorMetadataHash);
        _writeWord(eventData, 0xa0, patch.mode);
        _writeAddress(eventData, 0xc0, patch.previousExecutor);
        _writeWord(eventData, 0xe0, patch.approvalSourceId);
        _writeWord(eventData, 0x100, patch.approvalSignalId);
        _writeWord(eventData, 0x120, patch.patchHash);
        _writeWord(eventData, 0x140, bytes32(patch.patchNonce));
        _writeWord(eventData, 0x160, bytes32(uint256(0x180)));
        _writeWord(eventData, 0x180, bytes32(metadataURI.length));
        _copyBytes(eventData, 0x1a0, metadataURI);

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
