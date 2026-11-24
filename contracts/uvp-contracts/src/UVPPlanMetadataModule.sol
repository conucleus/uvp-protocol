// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUVPStateMachineCore} from "./interfaces/IUVPStateMachineCore.sol";
import {IUVPPlanMetadataModule} from "./interfaces/IUVPPlanMetadataModule.sol";
import {MerkleCommitment} from "./libraries/MerkleCommitment.sol";

contract UVPPlanMetadataModule is IUVPPlanMetadataModule {
    error PlanMetadataAlreadyFinalized(bytes32 planId);
    error UnauthorizedStateMachine(address caller);
    error UnknownPlan();
    error UnsupportedSignalTargetRelation(uint8 relation);

    IUVPStateMachineCore public immutable stateMachine;

    uint8 public constant SIGNAL_TARGET_CURRENT_ORDER = 0;

    bytes32 private constant _DOMAIN_SIGNAL_CAPABILITY = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant _DOMAIN_SELECTOR_BINDING = keccak256("UVP_SELECTOR_BINDING_V1");
    bytes32 private constant _DOMAIN_FILE_WRITER_BINDING = keccak256("UVP_FILE_WRITER_BINDING_V1");

    mapping(bytes32 planId => bytes32 capabilitiesRoot) private _capabilitiesRoots;
    mapping(bytes32 planId => bool finalized) public planMetadataFinalized;

    constructor(address stateMachineAddress) {
        stateMachine = IUVPStateMachineCore(stateMachineAddress);
    }

    function finalizePlanMetadata(bytes32 planId, bytes32 newCapabilitiesRoot) external {
        if (msg.sender != address(stateMachine)) {
            revert UnauthorizedStateMachine(msg.sender);
        }
        if (planMetadataFinalized[planId]) {
            revert PlanMetadataAlreadyFinalized(planId);
        }
        _capabilitiesRoots[planId] = newCapabilitiesRoot;
        planMetadataFinalized[planId] = true;
    }

    function signalCapabilityLeaf(bytes32 stageId, bytes32 targetSourceId, bytes32 signalId, uint8 relation)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_DOMAIN_SIGNAL_CAPABILITY, stageId, targetSourceId, signalId, uint256(relation)));
    }

    function selectorBindingLeaf(bytes32 selectorStageId, bytes32 targetStageId) public pure returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_SELECTOR_BINDING, selectorStageId, targetStageId));
    }

    function fileWriterBindingLeaf(bytes32 writerStageId, bytes32 targetStageId) public pure returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_FILE_WRITER_BINDING, writerStageId, targetStageId));
    }

    function capabilitiesRoot(bytes32 planId) external view returns (bytes32) {
        _requireKnownPlan(planId);
        return _capabilitiesRoots[planId];
    }

    function hasCapabilityVocabulary(bytes32 planId) external view returns (bool) {
        _requireKnownPlan(planId);
        return _capabilitiesRoots[planId] != MerkleCommitment.EMPTY_ROOT;
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
        if (relation != SIGNAL_TARGET_CURRENT_ORDER) {
            revert UnsupportedSignalTargetRelation(relation);
        }
        bytes32 leaf = signalCapabilityLeaf(stageId, targetSourceId, signalId, relation);
        return MerkleCommitment.verify(_capabilitiesRoots[planId], leaf, proof);
    }

    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool) {
        _requireKnownPlan(planId);
        bytes32 leaf = selectorBindingLeaf(selectorStageId, targetStageId);
        return MerkleCommitment.verify(_capabilitiesRoots[planId], leaf, proof);
    }

    function verifyFileWriterBinding(
        bytes32 planId,
        bytes32 writerStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool) {
        _requireKnownPlan(planId);
        bytes32 leaf = fileWriterBindingLeaf(writerStageId, targetStageId);
        return MerkleCommitment.verify(_capabilitiesRoots[planId], leaf, proof);
    }

    function _requireKnownPlan(bytes32 planId) private view {
        if (!stateMachine.planExists(planId)) {
            revert UnknownPlan();
        }
    }
}
