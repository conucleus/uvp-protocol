// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {ECDSA} from "./libraries/ECDSA.sol";
import {UVPSignatures} from "./libraries/UVPSignatures.sol";

interface IUVPPlanMetadataModuleForDocking {
    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        external
        view
        returns (bool);
}

contract UVPDockingModule {
    struct DockedSignalBinding {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bytes32 linkedSourceId;
        bytes32 linkedSignalId;
    }

    struct DockedOrderLink {
        bytes32 selectorStageId;
        bytes32 localSourceId;
        bytes32 linkedOrderId;
        bytes32 linkedPlanId;
        bytes32 linkHash;
        uint256 linkNonce;
        string metadataURI;
        DockedSignalBinding[] signalBindings;
    }

    struct ActiveDockedOrderLink {
        bytes32 selectorStageId;
        bytes32 localSourceId;
        bytes32 linkedPlanId;
        address selector;
        bytes32 linkHash;
        uint256 linkNonce;
        string metadataURI;
        bool exists;
    }

    struct ActiveDockedSignalBinding {
        bytes32 localSourceId;
        bytes32 localSignalId;
        bool exists;
    }

    error DockedOrderLinkNonceNotIncreasing(
        bytes32 localOrderId, bytes32 linkedOrderId, uint256 previousNonce, uint256 linkNonce
    );
    error DockedSignalBindingNotFound(
        bytes32 localOrderId, bytes32 linkedOrderId, bytes32 linkedSourceId, bytes32 linkedSignalId
    );
    error ExpiredDockedOrderLinkSignature(uint256 deadline);
    error InvalidDockedOrderLinkSignature(address expectedSigner, address recoveredSigner);
    error InvalidDockedOrderLinkSignatureLength(uint256 length);
    error StageSelectorBindingNotFound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error UnauthorizedDockedOrderLinkSelector(bytes32 localOrderId, bytes32 selectorStageId, address selector);
    error UnknownDockedOrderLink(bytes32 localOrderId, bytes32 linkedOrderId);
    error UnknownLinkedOrder(bytes32 linkedOrderId);
    error UnknownOrder();
    error ZeroLinkedOrderId();
    error ZeroLinkedPlanId();
    error ZeroLinkHash();
    error ZeroLocalOrderId();
    error ZeroSelector();
    error ZeroSelectorStageId();
    error ZeroSignalId();
    error ZeroSourceId();

    IUVPStateMachineCore public immutable stateMachine;

    bytes32 public constant DOCKED_ORDER_LINK_SIGNAL_ID = keccak256("uvp.docked_order_link.v1");

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("UVPDockingModule");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("0.1");
    // 审计 #10：摘要新增 localPlanId 字段（新版本口径），docking 链接签名
    // 绑定本地订单的 (planId, orderId) 复合身份。
    bytes32 private constant _DOCKED_ORDER_LINK_TYPEHASH = keccak256(
        "UVPDockingModuleDockedOrderLink(bytes32 localPlanId,bytes32 localOrderId,bytes32 selectorStageId,bytes32 localSourceId,bytes32 linkedOrderId,bytes32 linkedPlanId,bytes32 linkHash,uint256 linkNonce,bytes32 signalBindingsHash,string metadataURI,address selector,uint256 deadline)"
    );

    // 审计 #10：链接存储按 (localPlanId, localOrderId, linkedPlanId,
    // linkedOrderId) 寻址；不同 plan 下同 id 订单的 docking 链接互不冲突。
    mapping(
        bytes32 localPlanId
            => mapping(
                bytes32 localOrderId
                    => mapping(bytes32 linkedPlanId => mapping(bytes32 linkedOrderId => ActiveDockedOrderLink link))
            )
    ) private _activeDockedOrderLinks;
    mapping(
        bytes32 localPlanId
            => mapping(
                bytes32 localOrderId
                    => mapping(
                        bytes32 linkedPlanId
                            => mapping(
                                bytes32 linkedOrderId
                                    => mapping(bytes32 linkedSignalKey => ActiveDockedSignalBinding binding)
                            )
                    )
            )
    ) private _activeDockedSignalBindings;

    event DockedOrderLinked(
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed localSourceId,
        bytes32 selectorStageId,
        bytes32 linkedPlanId,
        address selector,
        bytes32 linkHash,
        uint256 linkNonce,
        string metadataURI
    );
    event DockedSignalMapped(
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed linkedSourceId,
        bytes32 linkedSignalId,
        bytes32 localSourceId,
        bytes32 localSignalId
    );
    event DockedSignalSubmitted(
        bytes32 indexed localOrderId,
        bytes32 indexed linkedOrderId,
        bytes32 indexed linkedSourceId,
        bytes32 linkedSignalId,
        bytes32 localSourceId,
        bytes32 localSignalId,
        bytes32 payloadHash,
        address submitter
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function linkDockedOrder(bytes32 localPlanId, bytes32 localOrderId, DockedOrderLink calldata link) external {
        _linkDockedOrder(localPlanId, localOrderId, link, msg.sender);
    }

    function linkDockedOrderFor(
        bytes32 localPlanId,
        bytes32 localOrderId,
        DockedOrderLink calldata link,
        address selector,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) {
            revert ExpiredDockedOrderLinkSignature(deadline);
        }
        if (selector == address(0)) {
            revert ZeroSelector();
        }

        address recoveredSigner =
            _recoverDockedOrderLinkSelector(dockedOrderLinkDigest(localPlanId, localOrderId, link, selector, deadline), signature);
        if (recoveredSigner != selector) {
            revert InvalidDockedOrderLinkSignature(selector, recoveredSigner);
        }

        _linkDockedOrder(localPlanId, localOrderId, link, selector);
    }

    function submitDockedSignal(
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 linkedPlanId,
        bytes32 linkedOrderId,
        bytes32 linkedSourceId,
        bytes32 linkedSignalId,
        bytes32 idempotencyKey
    ) external {
        ActiveDockedOrderLink storage dockedLink =
            _activeDockedOrderLinks[localPlanId][localOrderId][linkedPlanId][linkedOrderId];
        if (!dockedLink.exists) {
            revert UnknownDockedOrderLink(localOrderId, linkedOrderId);
        }

        (bool linkedSignalExists, bytes32 payloadHash,,, address submitter) =
            stateMachine.getSignal(linkedPlanId, linkedOrderId, linkedSourceId, linkedSignalId);
        if (!linkedSignalExists) {
            revert DockedSignalBindingNotFound(localOrderId, linkedOrderId, linkedSourceId, linkedSignalId);
        }

        ActiveDockedSignalBinding storage binding = _activeDockedSignalBindings[localPlanId][localOrderId][linkedPlanId][
            linkedOrderId
        ][_signalKey(linkedSourceId, linkedSignalId)];
        if (!binding.exists) {
            revert DockedSignalBindingNotFound(localOrderId, linkedOrderId, linkedSourceId, linkedSignalId);
        }

        stateMachine.submitSignalFromModule(
            localPlanId, localOrderId, binding.localSourceId, binding.localSignalId, payloadHash, idempotencyKey, submitter
        );
        emit DockedSignalSubmitted(
            localOrderId,
            linkedOrderId,
            linkedSourceId,
            linkedSignalId,
            binding.localSourceId,
            binding.localSignalId,
            payloadHash,
            submitter
        );
    }

    function orderDockedOrderLinkNonce(
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 linkedPlanId,
        bytes32 linkedOrderId
    ) external view returns (uint256) {
        return _activeDockedOrderLinks[localPlanId][localOrderId][linkedPlanId][linkedOrderId].linkNonce;
    }

    // 返回元组不再重复 linkedPlanId：它已是入参并在存储中校验一致。
    function getActiveDockedOrderLink(
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 linkedPlanId,
        bytes32 linkedOrderId
    )
        external
        view
        returns (
            bool exists,
            bytes32 selectorStageId,
            bytes32 localSourceId,
            address selector,
            bytes32 linkHash,
            uint256 linkNonce,
            string memory metadataURI
        )
    {
        ActiveDockedOrderLink storage activeLink =
            _activeDockedOrderLinks[localPlanId][localOrderId][linkedPlanId][linkedOrderId];
        return (
            activeLink.exists,
            activeLink.selectorStageId,
            activeLink.localSourceId,
            activeLink.selector,
            activeLink.linkHash,
            activeLink.linkNonce,
            activeLink.metadataURI
        );
    }

    function getActiveDockedSignalBinding(
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 linkedPlanId,
        bytes32 linkedOrderId,
        bytes32 linkedSourceId,
        bytes32 linkedSignalId
    ) external view returns (bool exists, bytes32 localSourceId, bytes32 localSignalId) {
        ActiveDockedSignalBinding storage binding = _activeDockedSignalBindings[localPlanId][localOrderId][linkedPlanId][
            linkedOrderId
        ][_signalKey(linkedSourceId, linkedSignalId)];
        return (binding.exists, binding.localSourceId, binding.localSignalId);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function dockedOrderLinkDigest(
        bytes32 localPlanId,
        bytes32 localOrderId,
        DockedOrderLink calldata link,
        address selector,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                _DOCKED_ORDER_LINK_TYPEHASH,
                localPlanId,
                localOrderId,
                link.selectorStageId,
                link.localSourceId,
                link.linkedOrderId,
                link.linkedPlanId,
                link.linkHash,
                link.linkNonce,
                _dockedSignalBindingsHash(link.signalBindings),
                keccak256(bytes(link.metadataURI)),
                selector,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _linkDockedOrder(bytes32 localPlanId, bytes32 localOrderId, DockedOrderLink calldata link, address selector)
        private
    {
        if (selector == address(0)) {
            revert ZeroSelector();
        }
        if (localOrderId == bytes32(0)) {
            revert ZeroLocalOrderId();
        }
        if (link.selectorStageId == bytes32(0)) {
            revert ZeroSelectorStageId();
        }
        if (link.localSourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (link.linkedOrderId == bytes32(0)) {
            revert ZeroLinkedOrderId();
        }
        if (link.linkedPlanId == bytes32(0)) {
            revert ZeroLinkedPlanId();
        }
        if (link.linkHash == bytes32(0)) {
            revert ZeroLinkHash();
        }
        // 审计 #10：本地与对端订单都按 (planId, orderId) 复合键验证存在性；
        // 对端订单存在性检查同时证明其 plan 归属与 link.linkedPlanId 一致。
        if (!stateMachine.orderExists(localPlanId, localOrderId)) {
            revert UnknownOrder();
        }
        if (!stateMachine.orderExists(link.linkedPlanId, link.linkedOrderId)) {
            revert UnknownLinkedOrder(link.linkedOrderId);
        }

        if (!_planMetadata().isStageSelectorBound(localPlanId, link.selectorStageId, link.localSourceId)) {
            revert StageSelectorBindingNotFound(localPlanId, link.selectorStageId, link.localSourceId);
        }
        if (!stateMachine.hasExplicitSignalAuthorization(
                localPlanId, localOrderId, link.selectorStageId, DOCKED_ORDER_LINK_SIGNAL_ID, selector
            )) {
            revert UnauthorizedDockedOrderLinkSelector(localOrderId, link.selectorStageId, selector);
        }

        ActiveDockedOrderLink storage activeLink =
            _activeDockedOrderLinks[localPlanId][localOrderId][link.linkedPlanId][link.linkedOrderId];
        if (link.linkNonce <= activeLink.linkNonce) {
            revert DockedOrderLinkNonceNotIncreasing(
                localOrderId, link.linkedOrderId, activeLink.linkNonce, link.linkNonce
            );
        }

        activeLink.selectorStageId = link.selectorStageId;
        activeLink.localSourceId = link.localSourceId;
        activeLink.linkedPlanId = link.linkedPlanId;
        activeLink.selector = selector;
        activeLink.linkHash = link.linkHash;
        activeLink.linkNonce = link.linkNonce;
        activeLink.metadataURI = link.metadataURI;
        activeLink.exists = true;

        emit DockedOrderLinked(
            localOrderId,
            link.linkedOrderId,
            link.localSourceId,
            link.selectorStageId,
            link.linkedPlanId,
            selector,
            link.linkHash,
            link.linkNonce,
            link.metadataURI
        );

        for (uint256 i = 0; i < link.signalBindings.length; i++) {
            _activateDockedSignalBinding(localPlanId, localOrderId, link.linkedPlanId, link.linkedOrderId, link.signalBindings[i]);
        }
    }

    function _activateDockedSignalBinding(
        bytes32 localPlanId,
        bytes32 localOrderId,
        bytes32 linkedPlanId,
        bytes32 linkedOrderId,
        DockedSignalBinding calldata binding
    ) private {
        if (binding.localSourceId == bytes32(0) || binding.linkedSourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (binding.localSignalId == bytes32(0) || binding.linkedSignalId == bytes32(0)) {
            revert ZeroSignalId();
        }

        ActiveDockedSignalBinding storage activeBinding =
            _activeDockedSignalBindings[localPlanId][localOrderId][linkedPlanId][linkedOrderId][
                _signalKey(binding.linkedSourceId, binding.linkedSignalId)
            ];

        activeBinding.localSourceId = binding.localSourceId;
        activeBinding.localSignalId = binding.localSignalId;
        activeBinding.exists = true;

        emit DockedSignalMapped(
            localOrderId,
            linkedOrderId,
            binding.linkedSourceId,
            binding.linkedSignalId,
            binding.localSourceId,
            binding.localSignalId
        );
    }

    function _dockedSignalBindingsHash(DockedSignalBinding[] calldata bindings) private pure returns (bytes32) {
        bytes32 rollingHash = keccak256(abi.encode(bindings.length));
        for (uint256 i = 0; i < bindings.length; i++) {
            DockedSignalBinding calldata binding = bindings[i];
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    binding.localSourceId,
                    binding.localSignalId,
                    binding.linkedSourceId,
                    binding.linkedSignalId
                )
            );
        }
        return rollingHash;
    }

    function _signalKey(bytes32 sourceId, bytes32 signalId) private pure returns (bytes32) {
        return keccak256(abi.encode(sourceId, signalId));
    }

    function _planMetadata() private view returns (IUVPPlanMetadataModuleForDocking) {
        return IUVPPlanMetadataModuleForDocking(stateMachine.planMetadataModule());
    }

    function _recoverDockedOrderLinkSelector(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) {
            revert InvalidDockedOrderLinkSignatureLength(signature.length);
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
