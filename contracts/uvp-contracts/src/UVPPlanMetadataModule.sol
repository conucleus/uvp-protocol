// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";

contract UVPPlanMetadataModule {
    struct StageSelectorBinding {
        bytes32 selectorStageId;
        bytes32 targetStageId;
    }

    struct SignalCapability {
        bytes32 stageId;
        bytes32 targetSourceId;
        bytes32 signalId;
        uint8 targetOrderRelation;
    }

    struct PlanMetadata {
        bytes32[] selectorBindingKeys;
        bytes32[] signalCapabilityKeys;
        mapping(bytes32 bindingKey => StageSelectorBinding binding) selectorBindings;
        mapping(bytes32 capabilityKey => bool exists) signalCapabilities;
    }

    error InvalidSignalCapability();
    error InvalidTargetOrderRelation(uint8 targetOrderRelation);
    error StageSelectorBindingAlreadyRegistered(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId);
    error UnauthorizedPlanMetadataPublisher(bytes32 planId, address publisher);
    error UnknownPlan();
    error ZeroSelectorStageId();
    error ZeroSignalId();
    error ZeroSourceId();
    error ZeroTargetStageId();

    IUVPStateMachineCore public immutable stateMachine;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;
    uint8 public constant SIGNAL_TARGET_TRIGGER_ORIGIN = 1;

    mapping(bytes32 planId => PlanMetadata metadata) private _metadata;

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

    function registerPlanMetadata(
        bytes32 planId,
        StageSelectorBinding[] calldata selectorBindings,
        SignalCapability[] calldata signalCapabilities
    ) external {
        _requirePlanPublisher(planId);
        _registerStageSelectorBindings(planId, selectorBindings);
        _registerSignalCapabilities(planId, signalCapabilities);
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

    function isStageSelectorBound(bytes32 planId, bytes32 selectorStageId, bytes32 targetStageId)
        external
        view
        returns (bool)
    {
        _requireKnownPlan(planId);
        return _metadata[planId].selectorBindings[stageSelectorBindingKey(selectorStageId, targetStageId)]
            .selectorStageId != bytes32(0);
    }

    function isSignalCapabilityRegistered(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) external view returns (bool) {
        _requireKnownPlan(planId);
        return _metadata[planId].signalCapabilities[signalCapabilityKey(stageId, targetSourceId, signalId, relation)];
    }

    function stageSelectorBindingKey(bytes32 selectorStageId, bytes32 targetStageId) public pure returns (bytes32) {
        return keccak256(abi.encode(selectorStageId, targetStageId));
    }

    function signalCapabilityKey(
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation
    ) public pure returns (bytes32) {
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
            metadata.selectorBindingKeys.push(key);
            emit StageSelectorBindingRegistered(planId, binding.selectorStageId, binding.targetStageId);
        }
    }

    function _registerSignalCapabilities(bytes32 planId, SignalCapability[] calldata signalCapabilities) private {
        PlanMetadata storage metadata = _metadata[planId];
        for (uint256 i = 0; i < signalCapabilities.length; i++) {
            SignalCapability calldata capability = signalCapabilities[i];
            _validateSignalCapability(capability);
            bytes32 capabilityKey = signalCapabilityKey(
                capability.stageId,
                capability.targetSourceId,
                capability.signalId,
                capability.targetOrderRelation
            );
            if (metadata.signalCapabilities[capabilityKey]) {
                revert InvalidSignalCapability();
            }
            metadata.signalCapabilities[capabilityKey] = true;
            metadata.signalCapabilityKeys.push(capabilityKey);
            emit SignalCapabilityRegistered(
                planId,
                capability.stageId,
                capability.targetSourceId,
                capability.signalId,
                capability.targetOrderRelation
            );
        }
    }

    function _requirePlanPublisher(bytes32 planId) private view {
        _requireKnownPlan(planId);
        if (stateMachine.planPublisher(planId) != msg.sender) {
            revert UnauthorizedPlanMetadataPublisher(planId, msg.sender);
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
