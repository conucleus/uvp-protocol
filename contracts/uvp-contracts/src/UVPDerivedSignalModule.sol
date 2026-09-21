// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

interface IUVPPlanMetadataModuleForDerivedSignal {
    function verifySignalCapability(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation,
        bytes32[] calldata proof
    ) external view returns (bool);
}

interface IUVPOrderLinkModuleForDerivedSignal {
    function targetOrderRelation(bytes32 fromPlanId, bytes32 fromOrderId, bytes32 targetPlanId, bytes32 targetOrderId)
        external
        view
        returns (uint8);
}

contract UVPDerivedSignalModule {
    error ExpiredSignalSignature(uint256 deadline);
    error InvalidSignalCapability();
    error InvalidSignalSignature(address expectedSigner, address recoveredSigner);
    error InvalidSignalSignatureLength(uint256 length);
    error UnauthorizedSignalCaller(address expectedCaller, address actualCaller);
    error UnauthorizedSignalSubmitter(bytes32 orderId, bytes32 sourceId, bytes32 signalId, address submitter);
    error UnknownOrder();
    error ZeroSignalId();
    error ZeroSourceId();
    error ZeroSubmitter();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPDerivedSignalModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.6");
    // 派生信号的两端都绑定 (planId, orderId) 复合身份。
    bytes32 private constant _DERIVED_SIGNAL_TYPEHASH = keccak256(
        "UVPDerivedSignalModuleSignal(bytes32 fromPlanId,bytes32 fromOrderId,bytes32 fromStageId,bytes32 targetPlanId,bytes32 targetOrderId,bytes32 targetSourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );

    event DerivedSignalSubmitted(
        // 事件携带两端的 planId——两 plan 同号订单的事件字节级不同
        // （indexers must consume the composite identity in every event）。
        bytes32 indexed fromOrderId,
        bytes32 indexed targetOrderId,
        bytes32 indexed signalId,
        bytes32 fromPlanId,
        bytes32 targetPlanId,
        bytes32 fromStageId,
        bytes32 targetSourceId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    );

    // 公开入参收敛为 request 结构体——
    // 派生信号两端都绑定 (planId, orderId) 复合身份。与
    // TriggerOrderFromSignalRequest 同构，避免过深函数栈。
    struct DerivedSignalRequest {
        bytes32 fromPlanId;
        bytes32 fromOrderId;
        bytes32 fromStageId;
        bytes32 targetPlanId;
        bytes32 targetOrderId;
        bytes32 targetSourceId;
        bytes32 signalId;
        bytes32 payloadHash;
        bytes32 idempotencyKey;
    }

    /// 能力成员资格证明（不进 EIP-712 摘要——证明是辅助材料，签名只背书
    /// 事实本身，与 dock 路由证明同口径）：from 侧计划的能力叶证明恒需；
    /// relation!=0 时 target（origin）侧计划的同款证明另需一份。
    struct DerivedSignalProofs {
        bytes32[] fromCapabilityProof;
        bytes32[] targetCapabilityProof;
        IUVPStateMachineCore.SelectorBindingProof selectorBinding;
    }

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function submitDerivedSignal(
        DerivedSignalRequest calldata request,
        address submitter,
        DerivedSignalProofs calldata proofs
    ) external {
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }
        if (msg.sender != submitter) {
            revert UnauthorizedSignalCaller(submitter, msg.sender);
        }
        uint8 relation = _validateDerivedSignal(request, submitter, proofs);
        _executeDerivedSignal(request, submitter, relation, proofs);
    }

    function submitDerivedSignalFor(
        DerivedSignalRequest calldata request,
        address submitter,
        uint256 deadline,
        bytes calldata signature,
        DerivedSignalProofs calldata proofs
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredSignalSignature(deadline);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }

        address recoveredSigner = _recoverSignalSubmitter(derivedSignalDigest(request, submitter, deadline), signature);
        if (recoveredSigner != submitter) {
            revert InvalidSignalSignature(submitter, recoveredSigner);
        }

        uint8 relation = _validateDerivedSignal(request, submitter, proofs);
        _executeDerivedSignal(request, submitter, relation, proofs);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function derivedSignalDigest(DerivedSignalRequest calldata request, address submitter, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                _DERIVED_SIGNAL_TYPEHASH,
                request.fromPlanId,
                request.fromOrderId,
                request.fromStageId,
                request.targetPlanId,
                request.targetOrderId,
                request.targetSourceId,
                request.signalId,
                request.payloadHash,
                request.idempotencyKey,
                submitter,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _executeDerivedSignal(
        DerivedSignalRequest calldata request,
        address submitter,
        uint8 relation,
        DerivedSignalProofs calldata proofs
    ) private {
        stateMachine.submitDerivedSignalFromModule(
            request.targetPlanId,
            request.targetOrderId,
            request.fromStageId,
            request.targetSourceId,
            request.signalId,
            request.payloadHash,
            request.idempotencyKey,
            submitter,
            relation == SIGNAL_TARGET_CURRENT_ORDER,
            proofs.selectorBinding
        );
        emit DerivedSignalSubmitted(
            request.fromOrderId,
            request.targetOrderId,
            request.signalId,
            request.fromPlanId,
            request.targetPlanId,
            request.fromStageId,
            request.targetSourceId,
            request.payloadHash,
            request.idempotencyKey,
            submitter
        );
    }

    function _validateDerivedSignal(
        DerivedSignalRequest calldata request,
        address submitter,
        DerivedSignalProofs calldata proofs
    ) private view returns (uint8 relation) {
        if (request.fromStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (request.targetSourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (request.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        // 两端订单都按 (planId, orderId) 复合键验证存在性——
        // 调用方声明的 plan 归属必须与链上存储一致。
        if (
            !stateMachine.orderExists(request.fromPlanId, request.fromOrderId)
                || !stateMachine.orderExists(request.targetPlanId, request.targetOrderId)
        ) {
            revert UnknownOrder();
        }

        {
            relation = _targetOrderRelation(
                request.fromPlanId, request.fromOrderId, request.targetPlanId, request.targetOrderId
            );
            // 能力成员资格按"字段重算叶 + 调用方携 proof"验证（叶子不自报）。
            if (!_planMetadata().verifySignalCapability(
                    request.fromPlanId,
                    request.fromStageId,
                    request.targetSourceId,
                    request.signalId,
                    relation,
                    proofs.fromCapabilityProof
                )) {
                revert InvalidSignalCapability();
            }
            // capability 只查 from 订单的 plan 时，自版 plan 的攻击者
            // 可对任意目标订单注入信号。跨订单派生（relation != 0）要求目标
            // （origin）订单的 plan 声明同一 capability——目标侧的 plan/授权
            // 必须参与同意。
            if (relation != 0) {
                if (!_planMetadata().verifySignalCapability(
                        request.targetPlanId,
                        request.fromStageId,
                        request.targetSourceId,
                        request.signalId,
                        relation,
                        proofs.targetCapabilityProof
                    )) {
                    revert InvalidSignalCapability();
                }
            }
        }
        // 提交者授权：from 侧提交者一律按 from 订单该阶段（fromStageId）的
        // 在任执行者门校验；对显式授权者的在任执行者检查豁免仅限 target 侧
        // ——只有目标订单侧对 (sourceId, signalId, submitter) 的显式授权可
        // 豁免（按 (planId, orderId) 寻址，显式授权以 source id 为键存储，
        // source id ≠ stage id）。from 侧显式授权不构成豁免：提交来源端的
        // 资格只能来自在任执行关系，fail-closed。
        if (
            stateMachine.activeStageExecutor(request.fromPlanId, request.fromOrderId, request.fromStageId) != submitter
                && !stateMachine.hasExplicitSignalAuthorization(
                    request.targetPlanId, request.targetOrderId, request.targetSourceId, request.signalId, submitter
                )
        ) {
            revert UnauthorizedSignalSubmitter(
                request.targetOrderId, request.targetSourceId, request.signalId, submitter
            );
        }
    }

    function _targetOrderRelation(bytes32 fromPlanId, bytes32 fromOrderId, bytes32 targetPlanId, bytes32 targetOrderId)
        private
        view
        returns (uint8)
    {
        if (fromPlanId == targetPlanId && fromOrderId == targetOrderId) {
            return 0;
        }
        return IUVPOrderLinkModuleForDerivedSignal(stateMachine.orderLinkModule())
            .targetOrderRelation(fromPlanId, fromOrderId, targetPlanId, targetOrderId);
    }

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForDerivedSignal) {
        return IUVPPlanMetadataModuleForDerivedSignal(stateMachine.planMetadataModule());
    }

    function _recoverSignalSubmitter(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidSignalSignatureLength(signature.length);
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
