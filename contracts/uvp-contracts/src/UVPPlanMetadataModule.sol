// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {DockMerkle} from "./libraries/DockMerkle.sol";

contract UVPPlanMetadataModule is IUVPPlanMetadataModule {
    struct PlanMetadata {
        bytes32 dockRoutesRoot;
        bytes32 dockInterfaceRoot;
        bytes32[] selectorBindingKeys;
        bytes32[] signalCapabilityKeys;
        mapping(bytes32 stageId => bytes32[] capabilityKeys) stageSignalCapabilityKeys;
        mapping(bytes32 bindingKey => StageSelectorBinding binding) selectorBindings;
        mapping(bytes32 targetStageId => bool exists) selectorTargetStages;
        mapping(bytes32 capabilityKey => SignalCapability capability) signalCapabilities;
    }

    error InvalidSignalCapability();
    error DuplicateCurrentOrderSignalCapability(bytes32 planId, bytes32 sourceId, bytes32 signalId, bytes32 stageId);
    error InvalidTargetOrderRelation(uint8 targetOrderRelation);
    error StageSelectorBindingAlreadyRegistered(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error PlanMetadataAlreadyFinalized(bytes32 planId);
    error TooManySignalCapabilities(uint256 count, uint256 max);
    error UnauthorizedStateMachine(address caller);
    error UnknownPlan();
    error ZeroSelectorStageId();
    error ZeroSignalId();
    error ZeroSourceId();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    // G-18 链上强制：能力表超过该上限时 _signalStageId 的线性扫描会让
    // 每次信号提交的 gas 随 plan 规模无界增长（手签超大能力表 plan 毒化
    // 全体提交者）。TS/Rust 编译器以同一数值预检；这里是注册边界兜底。
    uint256 public constant MAX_SIGNAL_CAPABILITIES = 256;

    bytes32 private constant _DOMAIN_DOCK_INTERFACE = keccak256("UVP_DOCK_INTERFACE_V2");

    mapping(bytes32 planId => PlanMetadata metadata) private _metadata;
    mapping(bytes32 planId => bool finalized) public planMetadataFinalized;
    // E16 注册守卫：relation=0 的事实键 → 唯一属主阶段。同一
    // (sourceId, signalId) 被两个阶段以 relation=0 重复声明会让
    // UVPStateMachine._signalStageId 按数组序"取首个匹配"，阶段归属静默
    // 漂移——注册边界直接拒绝。
    mapping(bytes32 planId => mapping(bytes32 factKey => bytes32 stageId)) private _currentOrderFactStages;

    event StageSelectorBindingRegistered(
        bytes32 indexed planId, bytes32 indexed selectorStageId, bytes32 indexed targetStageId
    );
    event SignalCapabilityRegistered(
        bytes32 indexed planId,
        bytes32 indexed stageId,
        bytes32 indexed targetSourceId,
        bytes32 signalId,
        uint8 relation
    );

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function finalizePlanMetadata(
        bytes32 planId,
        StageSelectorBinding[] calldata selectorBindings,
        SignalCapability[] calldata signalCapabilities,
        bytes32 routesRoot,
        bytes32 interfaceRoot
    ) external {
        if (msg.sender != address(stateMachine)) {
            revert UnauthorizedStateMachine(msg.sender);
        }
        if (planMetadataFinalized[planId]) {
            revert PlanMetadataAlreadyFinalized(planId);
        }
        _metadata[planId].dockRoutesRoot = routesRoot;
        _metadata[planId].dockInterfaceRoot = interfaceRoot;
        _registerStageSelectorBindings(planId, selectorBindings);
        _registerSignalCapabilities(planId, signalCapabilities);
        planMetadataFinalized[planId] = true;
    }

    function dockRoutesRoot(bytes32 planId) external view returns (bytes32) {
        _requireKnownPlan(planId);
        return _metadata[planId].dockRoutesRoot;
    }

    function dockInterfaceRoot(bytes32 planId) external view returns (bytes32) {
        _requireKnownPlan(planId);
        return _metadata[planId].dockInterfaceRoot;
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
                _DOMAIN_DOCK_INTERFACE, definitionUidId, interfaceNameId, uint256(orderModesWord), inputsRoot, outputsRoot
            )
        );
        return DockMerkle.verify(_metadata[planId].dockInterfaceRoot, interfaceLeaf, proof);
    }

    function planSelectorBindingCount(bytes32 planId) external view returns (uint256) {
        _requireKnownPlan(planId);
        return _metadata[planId].selectorBindingKeys.length;
    }

    function planSelectorBindingAt(bytes32 planId, uint256 index)
        external
        view
        returns (bytes32 selectorStageId, bytes32 targetStageId)
    {
        _requireKnownPlan(planId);
        PlanMetadata storage metadata = _metadata[planId];
        StageSelectorBinding storage binding = metadata.selectorBindings[metadata.selectorBindingKeys[index]];
        return (binding.selectorStageId, binding.targetStageId);
    }

    function planSignalCapabilityCount(bytes32 planId) external view returns (uint256) {
        _requireKnownPlan(planId);
        return _metadata[planId].signalCapabilityKeys.length;
    }

    function planSignalCapabilityAt(bytes32 planId, uint256 index)
        external
        view
        returns (bytes32 stageId, bytes32 targetSourceId, bytes32 signalId, uint8 targetOrderRelation)
    {
        _requireKnownPlan(planId);
        PlanMetadata storage metadata = _metadata[planId];
        SignalCapability storage capability = metadata.signalCapabilities[metadata.signalCapabilityKeys[index]];
        return (capability.stageId, capability.targetSourceId, capability.signalId, capability.targetOrderRelation);
    }

    function stageSignalCapabilityCount(bytes32 planId, bytes32 stageId) external view returns (uint256) {
        _requireKnownPlan(planId);
        return _metadata[planId].stageSignalCapabilityKeys[stageId].length;
    }

    function stageSignalCapabilityAt(bytes32 planId, bytes32 stageId, uint256 index)
        external
        view
        returns (bytes32 targetSourceId, bytes32 signalId, uint8 targetOrderRelation)
    {
        _requireKnownPlan(planId);
        PlanMetadata storage metadata = _metadata[planId];
        SignalCapability storage capability =
            metadata.signalCapabilities[metadata.stageSignalCapabilityKeys[stageId][index]];
        return (capability.targetSourceId, capability.signalId, capability.targetOrderRelation);
    }

    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        external
        view
        returns (bool)
    {
        _requireKnownPlan(planId);
        return _metadata[planId].selectorBindings[stageSelectorBindingKey(
                selectorStageId, targetStageId
            )].selectorStageId != bytes32(0);
    }

    function isSelectorTargetStage(bytes32 planId, bytes32 targetStageId) external view returns (bool) {
        _requireKnownPlan(planId);
        if (targetStageId == bytes32(0)) {
            return false;
        }
        return _metadata[planId].selectorTargetStages[targetStageId];
    }

    function isSignalCapabilityRegistered(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) external view returns (bool) {
        _requireKnownPlan(planId);
        return _metadata[planId].signalCapabilities[signalCapabilityKey(
                stageId, targetSourceId, signalId, relation
            )].stageId != bytes32(0);
    }

    function stageSelectorBindingKey(bytes32 selectorStageId, bytes32 targetStageId) public pure returns (bytes32) {
        return keccak256(abi.encode(selectorStageId, targetStageId));
    }

    function signalCapabilityKey(bytes32 stageId, bytes32 targetSourceId, bytes32 signalId, uint8 relation)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(stageId, targetSourceId, signalId, relation));
    }

    function _registerStageSelectorBindings(bytes32 planId, StageSelectorBinding[] calldata selectorBindings) private {
        PlanMetadata storage metadata = _metadata[planId];
        for (uint256 i = 0; i < selectorBindings.length; i++) {
            StageSelectorBinding calldata binding = selectorBindings[i];
            if (binding.selectorStageId == bytes32(0)) {
                revert ZeroSelectorStageId();
            }
            if (binding.targetStageId == bytes32(0)) {
                revert ZeroTargetStageId();
            }

            bytes32 key = stageSelectorBindingKey(binding.selectorStageId, binding.targetStageId);
            if (metadata.selectorBindings[key].selectorStageId != bytes32(0)) {
                revert StageSelectorBindingAlreadyRegistered(planId, binding.selectorStageId, binding.targetStageId);
            }

            metadata.selectorBindings[key] =
                StageSelectorBinding({selectorStageId: binding.selectorStageId, targetStageId: binding.targetStageId});
            metadata.selectorTargetStages[binding.targetStageId] = true;
            metadata.selectorBindingKeys.push(key);
            emit StageSelectorBindingRegistered(planId, binding.selectorStageId, binding.targetStageId);
        }
    }

    function _registerSignalCapabilities(bytes32 planId, SignalCapability[] calldata signalCapabilities) private {
        if (signalCapabilities.length > MAX_SIGNAL_CAPABILITIES) {
            revert TooManySignalCapabilities(signalCapabilities.length, MAX_SIGNAL_CAPABILITIES);
        }
        PlanMetadata storage metadata = _metadata[planId];
        for (uint256 i = 0; i < signalCapabilities.length; i++) {
            SignalCapability calldata capability = signalCapabilities[i];
            _validateSignalCapability(capability);
            bytes32 capabilityKey = signalCapabilityKey(
                capability.stageId, capability.targetSourceId, capability.signalId, capability.targetOrderRelation
            );
            if (metadata.signalCapabilities[capabilityKey].stageId != bytes32(0)) {
                revert InvalidSignalCapability();
            }
            // E16：relation=0 的事实键唯一属主。跨阶段重复声明在此拒绝，
            // 而不是让状态机侧 _signalStageId 按数组序取首个匹配。
            if (capability.targetOrderRelation == SIGNAL_TARGET_CURRENT_ORDER) {
                bytes32 factKey = keccak256(abi.encode(capability.targetSourceId, capability.signalId));
                bytes32 ownerStageId = _currentOrderFactStages[planId][factKey];
                if (ownerStageId != bytes32(0) && ownerStageId != capability.stageId) {
                    revert DuplicateCurrentOrderSignalCapability(
                        planId, capability.targetSourceId, capability.signalId, ownerStageId
                    );
                }
                _currentOrderFactStages[planId][factKey] = capability.stageId;
            }
            metadata.signalCapabilities[capabilityKey] = capability;
            metadata.signalCapabilityKeys.push(capabilityKey);
            metadata.stageSignalCapabilityKeys[capability.stageId].push(capabilityKey);
            emit SignalCapabilityRegistered(
                planId,
                capability.stageId,
                capability.targetSourceId,
                capability.signalId,
                capability.targetOrderRelation
            );
        }
    }

    function _requireKnownPlan(bytes32 planId) private view {
        if (!stateMachine.planExists(planId)) {
            revert UnknownPlan();
        }
    }

    function _validateSignalCapability(SignalCapability calldata capability) private pure {
        if (capability.stageId == bytes32(0)) {
            revert ZeroTargetStageId();
        }
        if (capability.targetSourceId == bytes32(0)) {
            revert ZeroSourceId();
        }
        if (capability.signalId == bytes32(0)) {
            revert ZeroSignalId();
        }
        if (
            capability.targetOrderRelation != SIGNAL_TARGET_CURRENT_ORDER
                && capability.targetOrderRelation != SIGNAL_TARGET_TRIGGER_ORIGIN
        ) {
            revert InvalidTargetOrderRelation(capability.targetOrderRelation);
        }
    }
}
