// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

contract UVPOrderLinkModule {
    // 审计 #10 解冻批次：链接存储按 (planId, triggeredOrderId) 寻址，并
    // 记录 origin 的 plan。orderId 不再是全局键：不同 plan 下同一 orderId
    // 的派生单互不影响，同 plan 内重复注册仍被拒绝。
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
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.8");
    // 审计 #10：摘要新增 originPlanId 字段（新版本口径），签名绑定 origin
    // 的 (planId, orderId)，防止请求在 plan 域之间移植。
    bytes32 private constant _TRIGGER_ORDER_FROM_SIGNAL_TYPEHASH = keccak256(
        "UVPOrderLinkModuleTriggerOrderFromSignal(bytes32 orderId,bytes32 planId,address creator,bytes32 triggerOriginOrderId,bytes32 originPlanId,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 originSourceId,bytes32 originSignalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    mapping(bytes32 planId => mapping(bytes32 triggeredOrderId => OrderTriggerLink link)) private _orderTriggerLinks;

    event OrderLinked(
        // 审计批次（事件复合身份）：链接事件携带触发侧 planId——两 plan 同
        // 号订单时不再字节级相同；origin 侧复合身份由
        // (triggerOriginPlanId, triggerOriginOrderId) 数据字段完整携带。
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
        IUVPStateMachineCore.SignalAuthorization[] calldata authorizations,
        bytes calldata signature
    ) external {
        if (block.timestamp > trigger.deadline) {
            revert ExpiredSignalSignature(trigger.deadline);
        }
        if (trigger.submitter == address(0)) {
            revert ZeroSubmitter();
        }
        // 审计 #10：origin 订单按 (originPlanId, triggerOriginOrderId) 寻址。
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

        {
            bytes32 authorizationsHash = signalAuthorizationsHash(authorizations);
            address recoveredSigner =
                _recoverSignalSubmitter(triggerOrderFromSignalDigest(trigger, authorizationsHash), signature);
            if (recoveredSigner != trigger.submitter) {
                revert InvalidTriggerOrderSignature(trigger.submitter, recoveredSigner);
            }
        }
        _registerLinkAndTrigger(trigger, authorizations);
    }

    /// 链接登记 + 状态机派生 + 链接事件。独立函数体：OrderLinked 事件携带
    /// 复合身份数据字段后编码压力上升，外部入口帧保持精简（栈深约束）。
    function _registerLinkAndTrigger(
        IUVPStateMachineCore.TriggerOrderFromSignalRequest calldata trigger,
        IUVPStateMachineCore.SignalAuthorization[] calldata authorizations
    ) private {
        // 审计 #1 残余：origin 侧同意的权威校验在状态机的
        // triggerOrderFromSignalFromModule 内执行（提交者或执行 relayer 持有
        // origin 订单同意集合中的身份），整笔事务原子回滚，这里无需重复。
        _orderTriggerLinks[trigger.planId][trigger.orderId] = OrderTriggerLink({
            triggerOriginOrderId: trigger.triggerOriginOrderId,
            triggerOriginPlanId: trigger.originPlanId,
            originSourceId: trigger.originSourceId,
            originSignalId: trigger.originSignalId,
            triggerStageId: trigger.triggerStageId,
            exists: true
        });

        stateMachine.triggerOrderFromSignalFromModule(trigger, authorizations, msg.sender);
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

    // 审计 #10：关系判定比较 (planId, orderId) 复合身份。两个 plan 下同一
    // orderId 互为不同订单，绝不因裸 orderId 相同而被视作"当前订单"。
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
        bytes memory encoded = new bytes(0x1e0);
        _writeWord(encoded, 0x00, _TRIGGER_ORDER_FROM_SIGNAL_TYPEHASH);
        _writeWord(encoded, 0x20, trigger.orderId);
        _writeWord(encoded, 0x40, trigger.planId);
        _writeAddress(encoded, 0x60, trigger.creator);
        _writeWord(encoded, 0x80, trigger.triggerOriginOrderId);
        _writeWord(encoded, 0xa0, trigger.originPlanId);
        _writeWord(encoded, 0xc0, trigger.triggerHookId);
        _writeWord(encoded, 0xe0, trigger.triggerStageId);
        _writeWord(encoded, 0x100, trigger.originSourceId);
        _writeWord(encoded, 0x120, trigger.originSignalId);
        _writeWord(encoded, 0x140, trigger.payloadHash);
        _writeWord(encoded, 0x160, trigger.idempotencyKey);
        _writeWord(encoded, 0x180, authorizationsHash);
        _writeAddress(encoded, 0x1a0, trigger.submitter);
        _writeWord(encoded, 0x1c0, bytes32(trigger.deadline));
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
