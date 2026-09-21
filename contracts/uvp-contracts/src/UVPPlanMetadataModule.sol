// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";

/// 计划能力表/绑定表的链上形态：一棵 capabilitiesRoot 承诺全部叶子
/// （signal capability 叶与 selector binding 叶域分隔混编），建树在链下
/// （TS/Rust 编译器），使用方按"字段当场重算叶 + 携 proof"验证 membership。
contract UVPPlanMetadataModule is IUVPPlanMetadataModule {
    struct PlanMetadata {
        bytes32 capabilitiesRoot;
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
    }

    error PlanMetadataAlreadyFinalized(bytes32 planId);
    error UnauthorizedStateMachine(address caller);
    error UnknownPlan();

    IUVPStateMachineCore public immutable stateMachine;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    bytes32 private constant _DOMAIN_SIGNAL_CAPABILITY = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant _DOMAIN_SELECTOR_BINDING = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant _DOMAIN_DOCK_INTERFACE = keccak256("UVP_DOCK_INTERFACE_V2");

    mapping(bytes32 planId => PlanMetadata metadata) private _metadata;
    mapping(bytes32 planId => bool finalized) public planMetadataFinalized;

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function finalizePlanMetadata(
        bytes32 planId,
        bytes32 newCapabilitiesRoot,
        bytes32 routesRoot,
        bytes32 interfaceRoot
    ) external {
        if (msg.sender != address(stateMachine)) {
            revert UnauthorizedStateMachine(msg.sender);
        }
        if (planMetadataFinalized[planId]) {
            revert PlanMetadataAlreadyFinalized(planId);
        }
        PlanMetadata storage metadata = _metadata[planId];
        metadata.capabilitiesRoot = newCapabilitiesRoot;
        metadata.dockRoutesRoot = routesRoot;
        metadata.dockInterfaceRoot = interfaceRoot;
        planMetadataFinalized[planId] = true;
    }

    function signalCapabilityLeaf(bytes32 stageId, bytes32 targetSourceId, bytes32 signalId, uint8 relation)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(_DOMAIN_SIGNAL_CAPABILITY, stageId, targetSourceId, signalId, uint256(relation))
        );
    }

    function selectorBindingLeaf(bytes32 selectorStageId, bytes32 targetStageId) public pure returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_SELECTOR_BINDING, selectorStageId, targetStageId));
    }

    function capabilitiesRoot(bytes32 planId) external view returns (bytes32) {
        _requireKnownPlan(planId);
        return _metadata[planId].capabilitiesRoot;
    }

    function dockRoutesRoot(bytes32 planId) external view returns (bytes32) {
        _requireKnownPlan(planId);
        return _metadata[planId].dockRoutesRoot;
    }

    function dockInterfaceRoot(bytes32 planId) external view returns (bytes32) {
        _requireKnownPlan(planId);
        return _metadata[planId].dockInterfaceRoot;
    }

    function hasCapabilityVocabulary(bytes32 planId) external view returns (bool) {
        _requireKnownPlan(planId);
        return _metadata[planId].capabilitiesRoot != DockMerkle.EMPTY_ROOT;
    }

    function verifyDockRoute(bytes32 planId, bytes32 leaf, bytes32[] calldata proof) external view returns (bool) {
        _requireKnownPlan(planId);
        return DockMerkle.verify(_metadata[planId].dockRoutesRoot, leaf, proof);
    }

    function verifyDockInterfacePort(
        bytes32 planId,
        bytes32 definitionUidId,
        bytes32 interfaceNameId,
        uint8 orderModesWord,
        bytes32 inputsRoot,
        bytes32 outputsRoot,
        bytes32[] calldata proof
    ) external view returns (bool) {
        _requireKnownPlan(planId);
        // 具名接口叶由承诺输入重算（调用方不得自报叶值）：
        // H("UVP_DOCK_INTERFACE_V2", uidId, interfaceNameId, orderModesWord,
        //   inputsRoot, outputsRoot)，与 Rust/TS 逐字节一致。
        bytes32 interfaceLeaf = keccak256(
            abi.encode(
                _DOMAIN_DOCK_INTERFACE,
                definitionUidId,
                interfaceNameId,
                uint256(orderModesWord),
                inputsRoot,
                outputsRoot
            )
        );
        return DockMerkle.verify(_metadata[planId].dockInterfaceRoot, interfaceLeaf, proof);
    }

    function verifySignalCapability(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation,
        bytes32[] calldata proof
    ) external view returns (bool) {
        _requireKnownPlan(planId);
        bytes32 leaf = signalCapabilityLeaf(stageId, targetSourceId, signalId, relation);
        return DockMerkle.verify(_metadata[planId].capabilitiesRoot, leaf, proof);
    }

    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool) {
        _requireKnownPlan(planId);
        bytes32 leaf = selectorBindingLeaf(selectorStageId, targetStageId);
        return DockMerkle.verify(_metadata[planId].capabilitiesRoot, leaf, proof);
    }

    function _requireKnownPlan(bytes32 planId) private view {
        if (!stateMachine.planExists(planId)) {
            revert UnknownPlan();
        }
    }
}
