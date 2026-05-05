// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

contract UVPOrderLinkModule {
    struct OrderTriggerLink {
        bytes32 parentOrderId;
        bytes32 originSourceId;
        bytes32 originSignalId;
        bytes32 triggerStageId;
        bool exists;
    }

    error ExpiredSignalSignature(uint256 deadline);
    error InvalidSignalSignatureLength(uint256 length);
    error InvalidTriggerOrderSignature(address expectedSigner, address recoveredSigner);
    error OrderTriggerLinkAlreadyRegistered(bytes32 childOrderId);
    error UnauthorizedOrderRegistrar();
    error UnknownOrder();
    error UnknownOrderTriggerLink(bytes32 childOrderId);
    error ZeroSubmitter();

    IUVPStateMachineCore public immutable stateMachine;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_PARENT = 1;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPOrderLinkModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.7");
    bytes32 private constant _TRIGGER_ORDER_FROM_SIGNAL_TYPEHASH = keccak256(
        "UVPOrderLinkModuleTriggerOrderFromSignal(bytes32 orderId,bytes32 planId,address creator,bytes32 parentOrderId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    mapping(bytes32 childOrderId => OrderTriggerLink link) private _orderTriggerLinks;

    event OrderLinked(
        bytes32 indexed childOrderId,
        bytes32 indexed parentOrderId,
        bytes32 indexed triggerStageId,
        bytes32 originSourceId,
        bytes32 originSignalId
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function triggerOrderFromSignalFor(
        IUVPStateMachineCore.TriggerOrderFromSignalRequest calldata trigger,
        IUVPStateMachineCore.SignalAuthorization[] calldata authorizations,
        bytes calldata signature
    ) external {
        if (block.timestamp > trigger.deadline) {
            revert ExpiredSignalSignature(trigger.deadline);
        }
        if (trigger.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        if (!stateMachine.orderRegistrars(msg.sender)) {
            revert UnauthorizedOrderRegistrar();
        }
        if (!stateMachine.orderExists(trigger.parentOrderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.hasSignal(trigger.parentOrderId, trigger.originSourceId, trigger.originSignalId)) {
            revert UnknownOrder();
        }
        if (_orderTriggerLinks[trigger.orderId].exists) {
            revert OrderTriggerLinkAlreadyRegistered(trigger.orderId);
        }

        bytes32 authorizationsHash = signalAuthorizationsHash(authorizations);
        address recoveredSigner =
            _recoverSignalSubmitter(triggerOrderFromSignalDigest(trigger, authorizationsHash), signature);
        if (recoveredSigner != trigger.submitter) {
            revert InvalidTriggerOrderSignature(trigger.submitter, recoveredSigner);
        }

        _orderTriggerLinks[trigger.orderId] = OrderTriggerLink({
            parentOrderId: trigger.parentOrderId,
            originSourceId: trigger.originSourceId,
            originSignalId: trigger.originSignalId,
            triggerStageId: trigger.triggerStageId,
            exists: true
        });

        stateMachine.triggerOrderFromSignalFromModule(trigger, authorizations, msg.sender);
        emit OrderLinked(
            trigger.orderId,
            trigger.parentOrderId,
            trigger.triggerStageId,
            trigger.originSourceId,
            trigger.originSignalId
        );
    }

    function targetOrderRelation(bytes32 fromOrderId, bytes32 targetOrderId) external view returns (uint8) {
        if (fromOrderId == targetOrderId) {
            return SIGNAL_TARGET_CURRENT_ORDER;
        }
        OrderTriggerLink storage link = _orderTriggerLinks[fromOrderId];
        if (link.exists && link.parentOrderId == targetOrderId) {
            return SIGNAL_TARGET_TRIGGER_PARENT;
        }
        revert UnknownOrderTriggerLink(fromOrderId);
    }

    function getOrderTriggerLink(bytes32 childOrderId)
        external
        view
        returns (
            bool exists,
            bytes32 parentOrderId,
            bytes32 originSourceId,
            bytes32 originSignalId,
            bytes32 triggerStageId
        )
    {
        OrderTriggerLink storage link = _orderTriggerLinks[childOrderId];
        return (link.exists, link.parentOrderId, link.originSourceId, link.originSignalId, link.triggerStageId);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function signalAuthorizationsHash(IUVPStateMachineCore.SignalAuthorization[] calldata authorizations)
        public
        pure
        returns (bytes32)
    {
        bytes32 rollingHash = keccak256(abi.encode(authorizations.length));
        for (uint256 i = 0; i < authorizations.length; i++) {
            IUVPStateMachineCore.SignalAuthorization calldata authorization = authorizations[i];
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    authorization.sourceId,
                    authorization.signalId,
                    authorization.submitter,
                    authorization.role,
                    authorization.metadataHash
                )
            );
        }
        return rollingHash;
    }

    function triggerOrderFromSignalDigest(
        IUVPStateMachineCore.TriggerOrderFromSignalRequest calldata trigger,
        bytes32 authorizationsHash
    ) public view returns (bytes32) {
        bytes memory encoded = new bytes(0x1c0);
        _writeWord(encoded, 0x00, _TRIGGER_ORDER_FROM_SIGNAL_TYPEHASH);
        _writeWord(encoded, 0x20, trigger.orderId);
        _writeWord(encoded, 0x40, trigger.planId);
        _writeAddress(encoded, 0x60, trigger.creator);
        _writeWord(encoded, 0x80, trigger.parentOrderId);
        _writeWord(encoded, 0xa0, trigger.triggerHookId);
        _writeWord(encoded, 0xc0, trigger.triggerStageId);
        _writeWord(encoded, 0xe0, trigger.originSourceId);
        _writeWord(encoded, 0x100, trigger.originSignalId);
        _writeWord(encoded, 0x120, trigger.payloadHash);
        _writeWord(encoded, 0x140, trigger.idempotencyKey);
        _writeWord(encoded, 0x160, authorizationsHash);
        _writeAddress(encoded, 0x180, trigger.submitter);
        _writeWord(encoded, 0x1a0, bytes32(trigger.deadline));
        bytes32 structHash = keccak256(encoded);
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
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

    function _writeWord(bytes memory encoded, uint256 offset, bytes32 value) private pure {
        assembly {
            mstore(add(add(encoded, 0x20), offset), value)
        }
    }

    function _writeAddress(bytes memory encoded, uint256 offset, address value) private pure {
        _writeWord(encoded, offset, bytes32(uint256(uint160(value))));
    }
}
