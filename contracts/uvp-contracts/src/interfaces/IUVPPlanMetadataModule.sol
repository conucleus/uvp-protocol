// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUVPPlanMetadataModule {
    function signalCapabilityLeaf(bytes32 stageId, bytes32 targetSourceId, bytes32 signalId, uint8 relation)
        external
        pure
        returns (bytes32);
    function selectorBindingLeaf(bytes32 selectorStageId, bytes32 targetStageId) external pure returns (bytes32);
    function fileWriterBindingLeaf(bytes32 writerStageId, bytes32 targetStageId) external pure returns (bytes32);

    function finalizePlanMetadata(bytes32 planId, bytes32 capabilitiesRoot) external;

    function capabilitiesRoot(bytes32 planId) external view returns (bytes32);

    /// @return vocabulary 非空能力树（root != EMPTY_ROOT）即 true。零
    ///         capability 的手工 plan 词表闸全线放行的判定依据。
    function hasCapabilityVocabulary(bytes32 planId) external view returns (bool);

    function verifySignalCapability(
        bytes32 planId,
        bytes32 stageId,
        bytes32 targetSourceId,
        bytes32 signalId,
        uint8 relation,
        bytes32[] calldata proof
    ) external view returns (bool);

    function verifyStageSelectorBinding(
        bytes32 planId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool);

    function verifyFileWriterBinding(
        bytes32 planId,
        bytes32 writerStageId,
        bytes32 targetStageId,
        bytes32[] calldata proof
    ) external view returns (bool);

}
