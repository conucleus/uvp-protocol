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

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPDerivedSignalModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.6");
    bytes32 private constant _DERIVED_SIGNAL_TYPEHASH = keccak256(
        "UVPDerivedSignalModuleSignal(bytes32 fromPlanId,bytes32 fromOrderId,bytes32 fromStageId,bytes32 targetPlanId,bytes32 targetOrderId,bytes32 targetSourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );

    event DerivedSignalSubmitted(
        bytes32 indexed fromOrderId,
        bytes32 indexed targetOrderId,
        bytes32 indexed signalId,
        bytes32 fromPlanId,
        bytes32 targetPlanId,
        bytes32 fromStageId,
        bytes32 targetSourceId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint8 relation
    );

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

    struct DerivedSignalProofs {
        bytes32[] fromCapabilityProof;
        bytes32[] targetCapabilityProof;
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
        _executeDerivedSignal(request, submitter, relation);
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
        _executeDerivedSignal(request, submitter, relation);
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

    function _executeDerivedSignal(DerivedSignalRequest calldata request, address submitter, uint8 relation) private {
        stateMachine.submitDerivedSignalFromModule(
            request.targetPlanId,
            request.targetOrderId,
            request.fromPlanId,
            request.fromOrderId,
            request.fromStageId,
            request.targetSourceId,
            request.signalId,
            request.payloadHash,
            request.idempotencyKey,
            submitter
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
            submitter,
            relation
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
            if (!_planMetadata()
                    .verifySignalCapability(
                        request.fromPlanId,
                        request.fromStageId,
                        request.targetSourceId,
                        request.signalId,
                        relation,
                        proofs.fromCapabilityProof
                    )) {
                revert InvalidSignalCapability();
            }
            if (relation != 0) {
                if (!_planMetadata()
                        .verifySignalCapability(
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
