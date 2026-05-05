// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

interface IUVPPlanMetadataModuleForDerivedSignal {
    function isSignalCapabilityRegistered(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) external view returns (bool);
}

interface IUVPOrderLinkModuleForDerivedSignal {
    function targetOrderRelation(bytes32 fromOrderId, bytes32 targetOrderId) external view returns (uint8);
}

contract UVPDerivedSignalModule {
    error ExpiredSignalSignature(uint256 deadline);
    error InvalidSignalCapability();
    error InvalidSignalSignature(address expectedSigner, address recoveredSigner);
    error InvalidSignalSignatureLength(uint256 length);
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
        "UVPDerivedSignalModuleSignal(bytes32 fromOrderId,bytes32 fromStageId,bytes32 targetOrderId,bytes32 targetSourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function submitDerivedSignal(
        bytes32 fromOrderId,
        bytes32 fromStageId,
        bytes32 targetOrderId,
        bytes32 targetSourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey
    ) external {
        _submitDerivedSignal(
            fromOrderId,
            fromStageId,
            targetOrderId,
            targetSourceId,
            signalId,
            payloadHash,
            idempotencyKey,
            msg.sender
        );
    }

    function submitDerivedSignalFor(
        bytes32 fromOrderId,
        bytes32 fromStageId,
        bytes32 targetOrderId,
        bytes32 targetSourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredSignalSignature(deadline);
        }
        if (submitter == address(0)) {
            revert ZeroSubmitter();
        }

        address recoveredSigner = _recoverSignalSubmitter(
            derivedSignalDigest(
                fromOrderId,
                fromStageId,
                targetOrderId,
                targetSourceId,
                signalId,
                payloadHash,
                idempotencyKey,
                submitter,
                deadline
            ),
            signature
        );
        if (recoveredSigner != submitter) {
            revert InvalidSignalSignature(submitter, recoveredSigner);
        }

        _submitDerivedSignal(
            fromOrderId,
            fromStageId,
            targetOrderId,
            targetSourceId,
            signalId,
            payloadHash,
            idempotencyKey,
            submitter
        );
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function derivedSignalDigest(
        bytes32 fromOrderId,
        bytes32 fromStageId,
        bytes32 targetOrderId,
        bytes32 targetSourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _DERIVED_SIGNAL_TYPEHASH,
                fromOrderId,
                fromStageId,
                targetOrderId,
                targetSourceId,
                signalId,
                payloadHash,
                idempotencyKey,
                submitter,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _submitDerivedSignal(
        bytes32 fromOrderId,
        bytes32 fromStageId,
        bytes32 targetOrderId,
        bytes32 targetSourceId,
        bytes32 signalId,
        bytes32 payloadHash,
        bytes32 idempotencyKey,
        address submitter
    ) private {
        if (fromStageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (targetSourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        if (!stateMachine.orderExists(fromOrderId) || !stateMachine.orderExists(targetOrderId)) {
            revert UnknownOrder();
        }

        uint8 relation = _targetOrderRelation(fromOrderId, targetOrderId);
        bytes32 fromPlanId = stateMachine.orderPlanId(fromOrderId);
        if (!_planMetadata().isSignalCapabilityRegistered(fromPlanId, fromStageId, targetSourceId, signalId, relation)) {
            revert InvalidSignalCapability();
        }
        if (!_isDerivedSignalSubmitterAuthorized(fromOrderId, fromStageId, targetOrderId, targetSourceId, signalId, submitter)) {
            revert UnauthorizedSignalSubmitter(targetOrderId, targetSourceId, signalId, submitter);
        }

        stateMachine.submitSignalFromModule(targetOrderId, targetSourceId, signalId, payloadHash, idempotencyKey, submitter);
    }

    function _isDerivedSignalSubmitterAuthorized(
        bytes32 fromOrderId,
        bytes32 fromStageId,
        bytes32 targetOrderId,
        bytes32 targetSourceId,
        bytes32 signalId,
        address submitter
    ) private view returns (bool) {
        if (submitter == address(0)) {
            return false;
        }
        if (stateMachine.activeStageExecutor(fromOrderId, fromStageId) == submitter) {
            return true;
        }
        return stateMachine.hasExplicitSignalAuthorization(targetOrderId, targetSourceId, signalId, submitter)
            || stateMachine.hasExplicitSignalAuthorization(fromOrderId, fromStageId, signalId, submitter);
    }

    function _targetOrderRelation(bytes32 fromOrderId, bytes32 targetOrderId) private view returns (uint8) {
        if (fromOrderId == targetOrderId) {
            return 0;
        }
        return IUVPOrderLinkModuleForDerivedSignal(stateMachine.orderLinkModule()).targetOrderRelation(
            fromOrderId, targetOrderId
        );
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
