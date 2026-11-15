// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

contract UVPOrderLinkModule {
    struct OrderTriggerLink {
        bytes32 triggerOriginOrderId;
        bytes32 triggerOriginPlanId;
        bytes32 originSourceId;
        bytes32 originSignalId;
        bytes32 triggerStageId;
        bool exists;
    }

    error ExpiredSignalSignature(uint256 deadline);
    error InvalidSignalSignatureLength(uint256 length);
    error InvalidTriggerOrderSignature(address expectedSigner, address recoveredSigner);
    error OrderTriggerLinkAlreadyRegistered(bytes32 triggeredOrderId);
    error UnknownOrder();
    error UnknownOrderTriggerLink(bytes32 triggeredOrderId);
    error ZeroSubmitter();

    IUVPStateMachineCore public immutable stateMachine;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPOrderLinkModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.9");
    bytes32 private constant _TRIGGER_ORDER_FROM_SIGNAL_TYPEHASH = keccak256(
        "UVPOrderLinkModuleTriggerOrderFromSignal(bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 originPlanId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,address submitter,uint256 deadline)"
    );

    mapping(bytes32 planId => mapping(bytes32 triggeredOrderId => OrderTriggerLink link)) private _orderTriggerLinks;

    event OrderLinked(
        bytes32 indexed triggeredOrderId,
        bytes32 indexed triggerOriginOrderId,
        bytes32 indexed triggerStageId,
        bytes32 planId,
        bytes32 originPlanId,
        bytes32 originSourceId,
        bytes32 originSignalId
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function triggerOrderFromSignalFor(
        IUVPStateMachineCore.TriggerOrderFromSignalRequest calldata trigger,
        bytes calldata signature,
        IUVPStateMachineCore.FactAttribution[] calldata originFactAttributions
    ) external {
        if (block.timestamp > trigger.deadline) {
            revert ExpiredSignalSignature(trigger.deadline);
        }
        if (trigger.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        if (!stateMachine.orderExists(trigger.originPlanId, trigger.triggerOriginOrderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.hasSignal(
                trigger.originPlanId, trigger.triggerOriginOrderId, trigger.originSourceId, trigger.originSignalId
            )) {
            revert UnknownOrder();
        }
        if (_orderTriggerLinks[trigger.planId][trigger.orderId].exists) {
            revert OrderTriggerLinkAlreadyRegistered(trigger.orderId);
        }

        address recoveredSigner = _recoverSignalSubmitter(triggerOrderFromSignalDigest(trigger), signature);
        if (recoveredSigner != trigger.submitter) {
            revert InvalidTriggerOrderSignature(trigger.submitter, recoveredSigner);
        }
        _registerLinkAndTrigger(trigger, originFactAttributions);
    }

    function _registerLinkAndTrigger(
        IUVPStateMachineCore.TriggerOrderFromSignalRequest calldata trigger,
        IUVPStateMachineCore.FactAttribution[] calldata originFactAttributions
    ) private {
        _orderTriggerLinks[trigger.planId][trigger.orderId] = OrderTriggerLink({
            triggerOriginOrderId: trigger.triggerOriginOrderId,
            triggerOriginPlanId: trigger.originPlanId,
            originSourceId: trigger.originSourceId,
            originSignalId: trigger.originSignalId,
            triggerStageId: trigger.triggerStageId,
            exists: true
        });

        stateMachine.triggerOrderFromSignalFromModule(trigger, msg.sender, originFactAttributions);
        emit OrderLinked(
            trigger.orderId,
            trigger.triggerOriginOrderId,
            trigger.triggerStageId,
            trigger.planId,
            trigger.originPlanId,
            trigger.originSourceId,
            trigger.originSignalId
        );
    }

    function targetOrderRelation(bytes32 fromPlanId, bytes32 fromOrderId, bytes32 targetPlanId, bytes32 targetOrderId)
        external
        view
        returns (uint8)
    {
        if (fromPlanId == targetPlanId && fromOrderId == targetOrderId) {
            return SIGNAL_TARGET_CURRENT_ORDER;
        }
        OrderTriggerLink storage link = _orderTriggerLinks[fromPlanId][fromOrderId];
        if (link.exists && link.triggerOriginPlanId == targetPlanId && link.triggerOriginOrderId == targetOrderId) {
            return SIGNAL_TARGET_TRIGGER_ORIGIN;
        }
        revert UnknownOrderTriggerLink(fromOrderId);
    }

    function getTriggerOriginLink(bytes32 planId, bytes32 triggeredOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 triggerOriginOrderId,
            bytes32 triggerOriginPlanId,
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        )
    {
        OrderTriggerLink storage link = _orderTriggerLinks[planId][triggeredOrderId];
        return (
            link.exists,
            link.triggerOriginOrderId,
            link.triggerOriginPlanId,
            link.originSourceId,
            link.originSignalId,
            link.triggerStageId
        );
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function triggerOrderFromSignalDigest(IUVPStateMachineCore.TriggerOrderFromSignalRequest calldata trigger)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                _TRIGGER_ORDER_FROM_SIGNAL_TYPEHASH,
                trigger.orderId,
                trigger.planId,
                trigger.creator,
                trigger.triggerOriginOrderId,
                trigger.originPlanId,
                trigger.triggerHookId,
                trigger.triggerStageId,
                trigger.originSourceId,
                trigger.originSignalId,
                trigger.payloadHash,
                trigger.idempotencyKey,
                trigger.submitter,
                trigger.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _recoverSignalSubmitter(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidSignalSignatureLength(signature.length);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ECDSA.recover(digest, UVPSignatures.Signature({v: v, r: r, s: s}));
    }
}
