// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUVPPlanMetadataModule {
    /// 能力树的域分隔叶编码。叶子由承诺输入在合约内重算（调用方不得
    /// 自报叶值），membership 由调用方携带的 proof 证明——与
    /// verifyDockInterfacePort 同一纪律。
    function signalCapabilityLeaf(bytes32 stageId, bytes32 targetSourceId, bytes32 signalId, uint8 relation)
        external
        pure
        returns (bytes32);
    function selectorBindingLeaf(bytes32 selectorStageId, bytes32 targetStageId) external pure returns (bytes32);

    function finalizePlanMetadata(
        bytes32 planId,
        bytes32 capabilitiesRoot,
        bytes32 dockRoutesRoot,
        bytes32 dockInterfaceRoot
    ) external;

    function capabilitiesRoot(bytes32 planId) external view returns (bytes32);

    function dockRoutesRoot(bytes32 planId) external view returns (bytes32);

    function dockInterfaceRoot(bytes32 planId) external view returns (bytes32);

    /// @return vocabulary 非空能力树（root != EMPTY_ROOT）即 true。零
    ///         capability 的手工 plan 词表闸全线放行的判定依据。
    function hasCapabilityVocabulary(bytes32 planId) external view returns (bool);

    function verifyDockRoute(bytes32 planId, bytes32 leaf, bytes32[] calldata proof) external view returns (bool);

    function verifyDockInterfacePort(
        bytes32 planId,
        bytes32 definitionUidId,
        bytes32 interfaceNameId,
        uint8 orderModesWord,
        bytes32 inputsRoot,
        bytes32 outputsRoot,
        bytes32[] calldata proof
    ) external view returns (bool);

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
}
