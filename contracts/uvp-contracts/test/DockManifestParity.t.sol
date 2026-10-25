// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface DockManifestVm {
    function projectRoot() external view returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function parseJsonAddress(string calldata json, string calldata key) external view returns (address);
    function parseJsonBytes32(string calldata json, string calldata key) external view returns (bytes32);
    function parseJsonString(string calldata json, string calldata key) external view returns (string memory);
    function parseJsonUint(string calldata json, string calldata key) external view returns (uint256);
}

import {DockMerkle} from "../src/libraries/DockMerkle.sol";

contract DockManifestParityTest {
    DockManifestVm private constant vm = DockManifestVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant DOMAIN_DEFINITION_REF = keccak256("UVP_DEFINITION_REF_V1");
    bytes32 private constant DOMAIN_INTERFACE = keccak256("UVP_DOCK_INTERFACE_V2");
    bytes32 private constant DOMAIN_INTERFACE_INPUT = keccak256("UVP_DOCK_INTERFACE_INPUT_V2");
    bytes32 private constant DOMAIN_INTERFACE_OUTPUT = keccak256("UVP_DOCK_INTERFACE_OUTPUT_V3");
    bytes32 private constant DOMAIN_ROUTE_ID = keccak256("UVP_DOCK_ROUTE_ID_V1");
    bytes32 private constant DOMAIN_INPUT_BINDING = keccak256("UVP_DOCK_INPUT_BINDING_V2");
    bytes32 private constant DOMAIN_OUTPUT_BINDING = keccak256("UVP_DOCK_OUTPUT_BINDING_V2");
    bytes32 private constant DOMAIN_ROUTE = keccak256("UVP_DOCK_ROUTE_V3");
    bytes32 private constant DOMAIN_DOCK_CANDIDATE = keccak256("UVP_DOCK_CANDIDATE_V2");
    bytes32 private constant DOMAIN_DOCK_INSTANCE = keccak256("UVP_DOCK_INSTANCE_V2");
    bytes32 private constant DOMAIN_DOCK_ORDER = keccak256("UVP_DOCK_ORDER_V1");
    bytes32 private constant DOCK_ORDER_NAMESPACE_MASK = bytes32(uint256(1) << 255);
    bytes32 private constant DOMAIN_RUNTIME_CLOUD = keccak256("UVP_RUNTIME_CLOUD_V1");
    bytes32 private constant DOMAIN_RUNTIME_EIP155 = keccak256("UVP_RUNTIME_EIP155_V1");
    bytes32 private constant DOMAIN_INPUT_PAYLOAD = keccak256("UVP_DOCK_INPUT_PAYLOAD_V1");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "UVPDockEntrancePermitV2(bytes32 targetPlanId,bytes32 targetEntrancePortId,bytes32 interfaceNameId,bytes32 localPlanId,bytes32 routeHash,bytes32 dockInstanceId,bytes32 linkedOrderId,uint256 feeLimit,uint256 nonce,uint256 deadline)"
    );

    function assertEq(bytes32 left, bytes32 right) internal pure {
        if (left != right) {
            revert("dock manifest bytes32 mismatch");
        }
    }

    function _manifest() private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/../../packages/compiler/fixtures/dock/v1/manifest.json"));
    }

    function _word(string memory json, string memory key) private view returns (bytes32) {
        return vm.parseJsonBytes32(json, key);
    }

    function _str(string memory json, string memory key) private view returns (string memory) {
        return vm.parseJsonString(json, key);
    }

    function testEvmRuntimeDomainMatches() public {
        string memory manifest = _manifest();
        assertEq(
            keccak256(
                abi.encode(
                    DOMAIN_RUNTIME_EIP155,
                    vm.parseJsonUint(manifest, ".inputs.chainId"),
                    bytes32(uint256(uint160(vm.parseJsonAddress(manifest, ".inputs.stateMachineAddress"))))
                )
            ),
            _word(manifest, ".expected.evmRuntimeDomain")
        );
    }

    function testCloudRuntimeDomainMatches() public {
        string memory manifest = _manifest();
        assertEq(
            keccak256(
                abi.encode(
                    DOMAIN_RUNTIME_CLOUD,
                    keccak256(bytes(_str(manifest, ".inputs.cloudDeploymentId"))),
                    keccak256(bytes(_str(manifest, ".inputs.cloudSecurityDomain")))
                )
            ),
            _word(manifest, ".expected.cloudRuntimeDomain")
        );
    }

    function testDefinitionRefHashesMatch() public {
        string memory manifest = _manifest();
        assertEq(
            keccak256(abi.encode(DOMAIN_DEFINITION_REF, keccak256(bytes(_str(manifest, ".identities.parentUid"))))),
            _word(manifest, ".expected.parentDefinitionRefHash")
        );
        assertEq(
            keccak256(abi.encode(DOMAIN_DEFINITION_REF, keccak256(bytes(_str(manifest, ".identities.targetUid"))))),
            _word(manifest, ".expected.targetDefinitionRefHash")
        );
        assertEq(keccak256(bytes(_str(manifest, ".inputs.localOrderId"))), _word(manifest, ".expected.localOrderKey"));
    }

    function testNewModeRoutePreimagesMatch() public {
        string memory manifest = _manifest();
        bytes32 parentDefinitionRef = _word(manifest, ".expected.parentDefinitionRefHash");
        bytes32 targetDefinitionRef = _word(manifest, ".expected.targetDefinitionRefHash");
        bytes32 serviceNameId = keccak256(bytes(_str(manifest, ".expected.dockRoutes[0].target.interfaceName")));
        assertEq(serviceNameId, _word(manifest, ".expected.interfaceNameIds.production_service"));

        string memory serviceStage = _str(manifest, ".expected.dockRoutes[0].local.stageIdentifier");
        bytes32 serviceRouteId =
            keccak256(abi.encode(DOMAIN_ROUTE_ID, parentDefinitionRef, keccak256(bytes(serviceStage))));
        assertEq(serviceRouteId, _word(manifest, ".expected.dockRoutes[0].routeId"));

        bytes32 executeBindingHash = keccak256(
            abi.encode(
                DOMAIN_INPUT_BINDING,
                serviceRouteId,
                serviceNameId,
                keccak256(bytes(string.concat(serviceStage, "#EXECUTE"))),
                keccak256(bytes("execute")),
                _word(manifest, ".expected.dockRoutes[0].inputBindings[0].targetSourceId"),
                _word(manifest, ".expected.dockRoutes[0].inputBindings[0].targetSignalId")
            )
        );
        assertEq(executeBindingHash, _word(manifest, ".expected.dockRoutes[0].inputBindings[0].bindingHash"));
        bytes32[] memory inputLeaves = new bytes32[](1);
        inputLeaves[0] = executeBindingHash;
        bytes32 inputBindingsRoot = DockMerkle.root(inputLeaves);
        assertEq(inputBindingsRoot, _word(manifest, ".expected.dockRoutes[0].inputBindingsRoot"));

        bytes32[] memory outputBindings = new bytes32[](2);
        outputBindings[0] =
            _outputBindingHash(manifest, serviceRouteId, serviceNameId, ".expected.dockRoutes[0].outputBindings[0]");
        outputBindings[1] =
            _outputBindingHash(manifest, serviceRouteId, serviceNameId, ".expected.dockRoutes[0].outputBindings[1]");
        bytes32 outputBindingsRoot = DockMerkle.root(outputBindings);
        assertEq(outputBindingsRoot, _word(manifest, ".expected.dockRoutes[0].outputBindingsRoot"));

        assertEq(
            keccak256(
                abi.encode(
                    DOMAIN_ROUTE,
                    parentDefinitionRef,
                    targetDefinitionRef,
                    _word(manifest, ".expected.targetPlanId"),
                    serviceNameId,
                    uint256(0),
                    inputBindingsRoot,
                    outputBindingsRoot
                )
            ),
            _word(manifest, ".expected.dockRoutes[0].routeHash")
        );
    }

    function testExistingModeRoutePreimagesMatch() public {
        string memory manifest = _manifest();
        bytes32 evidenceNameId = keccak256(bytes(_str(manifest, ".expected.dockRoutes[1].target.interfaceName")));
        assertEq(evidenceNameId, _word(manifest, ".expected.interfaceNameIds.production_evidence"));
        bytes32 evidenceRouteId = _word(manifest, ".expected.dockRoutes[1].routeId");
        bytes32[] memory evidenceOutputs = new bytes32[](1);
        evidenceOutputs[0] =
            _outputBindingHash(manifest, evidenceRouteId, evidenceNameId, ".expected.dockRoutes[1].outputBindings[0]");
        assertEq(
            keccak256(
                abi.encode(
                    DOMAIN_ROUTE,
                    _word(manifest, ".expected.parentDefinitionRefHash"),
                    _word(manifest, ".expected.targetDefinitionRefHash"),
                    _word(manifest, ".expected.targetPlanId"),
                    evidenceNameId,
                    uint256(1),
                    DockMerkle.EMPTY_ROOT,
                    DockMerkle.root(evidenceOutputs)
                )
            ),
            _word(manifest, ".expected.dockRoutes[1].routeHash")
        );
    }

    function testInterfacePortLeavesMatch() public {
        string memory manifest = _manifest();
        bytes32 targetUidId = keccak256(bytes(_str(manifest, ".identities.targetUid")));
        bytes32 serviceNameId = _word(manifest, ".expected.interfaceNameIds.production_service");
        bytes32[] memory portLeaves = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) {
            string memory base = string.concat(".expected.interfaceArtifact.interfaces[1].inputs[", vmIndex(i), "]");
            portLeaves[i] = keccak256(
                abi.encode(
                    DOMAIN_INTERFACE_INPUT,
                    targetUidId,
                    serviceNameId,
                    keccak256(bytes(_str(manifest, string.concat(base, ".port")))),
                    keccak256(bytes(_str(manifest, string.concat(base, ".hookId"))))
                )
            );
            assertEq(portLeaves[i], _word(manifest, string.concat(base, ".leafHash")));
        }
        assertEq(DockMerkle.root(portLeaves), _word(manifest, ".expected.interfaceArtifact.interfaces[1].inputsRoot"));
    }

    function testInterfaceLeafAndDefinitionRootMatch() public {
        string memory manifest = _manifest();
        bytes32 targetUidId = keccak256(bytes(_str(manifest, ".identities.targetUid")));
        bytes32 serviceNameId = _word(manifest, ".expected.interfaceNameIds.production_service");
        bytes32[] memory outPortLeaves = new bytes32[](2);
        for (uint256 i = 0; i < 2; i++) {
            string memory base = string.concat(".expected.interfaceArtifact.interfaces[1].outputs[", vmIndex(i), "]");
            outPortLeaves[i] = keccak256(
                abi.encode(
                    DOMAIN_INTERFACE_OUTPUT,
                    targetUidId,
                    serviceNameId,
                    keccak256(bytes(_str(manifest, string.concat(base, ".port")))),
                    _word(manifest, string.concat(base, ".sourceId")),
                    _word(manifest, string.concat(base, ".signalId"))
                )
            );
            assertEq(outPortLeaves[i], _word(manifest, string.concat(base, ".leafHash")));
        }
        assertEq(
            DockMerkle.root(outPortLeaves), _word(manifest, ".expected.interfaceArtifact.interfaces[1].outputsRoot")
        );

        bytes32 serviceInterfaceLeaf = keccak256(
            abi.encode(
                DOMAIN_INTERFACE,
                targetUidId,
                serviceNameId,
                uint256(_orderModesMask(_str(manifest, ".expected.interfaceArtifact.interfaces[1].orderModes[0]"))),
                _word(manifest, ".expected.interfaceArtifact.interfaces[1].inputsRoot"),
                _word(manifest, ".expected.interfaceArtifact.interfaces[1].outputsRoot")
            )
        );
        assertEq(serviceInterfaceLeaf, _word(manifest, ".expected.interfaceArtifact.interfaces[1].interfaceRoot"));

        bytes32[] memory interfaceLeaves = new bytes32[](2);
        interfaceLeaves[0] = _word(manifest, ".expected.interfaceArtifact.interfaces[0].interfaceRoot");
        interfaceLeaves[1] = serviceInterfaceLeaf;
        assertEq(DockMerkle.root(interfaceLeaves), _word(manifest, ".expected.interfaceArtifact.interfaceRoot"));
    }

    function _newInstance(string memory manifest, bytes32 targetPlanId) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                _word(manifest, ".expected.evmRuntimeDomain"),
                _word(manifest, ".inputs.parentPlanIdWord"),
                _word(manifest, ".expected.parentDefinitionRefHash"),
                _word(manifest, ".expected.localOrderKey"),
                _word(manifest, ".expected.dockRoutes[0].routeId"),
                _word(manifest, ".expected.dockRoutes[0].routeHash"),
                uint256(0),
                _word(manifest, ".expected.interfaceNameIds.production_service"),
                targetPlanId
            )
        );
    }

    function _existingInstance(string memory manifest, bytes32 targetPlanId) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_DOCK_INSTANCE,
                _word(manifest, ".expected.cloudRuntimeDomain"),
                _word(manifest, ".inputs.parentPlanIdWord"),
                _word(manifest, ".expected.parentDefinitionRefHash"),
                _word(manifest, ".expected.localOrderKey"),
                _word(manifest, ".expected.dockRoutes[1].routeId"),
                _word(manifest, ".expected.dockRoutes[1].routeHash"),
                uint256(1),
                _word(manifest, ".expected.interfaceNameIds.production_evidence"),
                targetPlanId,
                keccak256(bytes(_str(manifest, ".inputs.existingTargetOrderRef")))
            )
        );
    }

    function _linkedOrder(string memory manifest, bytes32 dockInstanceId) private view returns (bytes32) {
        return bytes32(
            uint256(
                keccak256(
                    abi.encode(DOMAIN_DOCK_ORDER, dockInstanceId, _word(manifest, ".expected.targetDefinitionRefHash"))
                )
            ) | uint256(DOCK_ORDER_NAMESPACE_MASK)
        );
    }

    function _inputPayload(string memory manifest, bytes32 dockInstanceId, bytes32 linkedOrderId)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOMAIN_INPUT_PAYLOAD,
                dockInstanceId,
                _word(manifest, ".expected.dockRoutes[0].routeHash"),
                _word(manifest, ".inputs.parentPlanIdWord"),
                _word(manifest, ".expected.localOrderKey"),
                keccak256(bytes(_str(manifest, ".expected.dockRoutes[0].local.stageIdentifier"))),
                keccak256(
                    bytes(string.concat(_str(manifest, ".expected.dockRoutes[0].local.stageIdentifier"), "#EXECUTE"))
                ),
                _word(manifest, ".expected.targetPlanId"),
                linkedOrderId,
                keccak256(bytes("execute")),
                _word(manifest, ".expected.dockRoutes[0].inputBindings[0].targetSignalId"),
                uint256(0),
                bytes32(0)
            )
        );
    }

    function _permitDigest(string memory manifest, bytes32 dockInstanceId, bytes32 linkedOrderId)
        private
        view
        returns (bytes32)
    {
        bytes32 permitDomainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("UVPDockingModule"),
                keccak256("4"),
                vm.parseJsonUint(manifest, ".inputs.chainId"),
                vm.parseJsonAddress(manifest, ".inputs.dockingModuleAddress")
            )
        );
        bytes32 permitStructHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                _word(manifest, ".expected.targetPlanId"),
                keccak256(bytes("execute")),
                _word(manifest, ".expected.interfaceNameIds.production_service"),
                _word(manifest, ".inputs.parentPlanIdWord"),
                _word(manifest, ".expected.dockRoutes[0].routeHash"),
                dockInstanceId,
                linkedOrderId,
                uint256(0),
                uint256(1),
                uint256(2000000000)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", permitDomainSeparator, permitStructHash));
    }

    function _assertDistinct(bytes32 left, bytes32 right) private pure {
        if (left == right) {
            revert("dock manifest distinct check failed");
        }
    }

    function testNewModeInstancePreimageBindsTargetPlan() public {
        string memory manifest = _manifest();
        bytes32 instance = _newInstance(manifest, _word(manifest, ".expected.targetPlanId"));
        bytes32 swapped = _newInstance(manifest, keccak256("other-target-plan"));
        _assertDistinct(instance, swapped);
        _assertDistinct(_linkedOrder(manifest, instance), _linkedOrder(manifest, swapped));
        _assertDistinct(
            _inputPayload(manifest, instance, _linkedOrder(manifest, instance)),
            _inputPayload(manifest, swapped, _linkedOrder(manifest, swapped))
        );
        _assertDistinct(
            _permitDigest(manifest, instance, _linkedOrder(manifest, instance)),
            _permitDigest(manifest, swapped, _linkedOrder(manifest, swapped))
        );
    }

    function testExistingModeInstanceKeepsTailOrderRef() public {
        string memory manifest = _manifest();
        bytes32 existing = _existingInstance(manifest, _word(manifest, ".expected.targetPlanId"));
        bytes32 swapped = _existingInstance(manifest, keccak256("other-target-plan"));
        _assertDistinct(existing, swapped);
    }

    function testExistingModeEvmInstanceUsesWordLiteralOrderRef() public {
        string memory manifest = _manifest();
        bytes32 wordOrderRef = _word(manifest, ".inputs.existingEvmTargetOrderRef");
        assertEq(
            keccak256(
                abi.encode(
                    DOMAIN_DOCK_INSTANCE,
                    _word(manifest, ".expected.evmRuntimeDomain"),
                    _word(manifest, ".inputs.parentPlanIdWord"),
                    _word(manifest, ".expected.parentDefinitionRefHash"),
                    _word(manifest, ".expected.localOrderKey"),
                    _word(manifest, ".expected.dockRoutes[1].routeId"),
                    _word(manifest, ".expected.dockRoutes[1].routeHash"),
                    uint256(1),
                    _word(manifest, ".expected.interfaceNameIds.production_evidence"),
                    _word(manifest, ".expected.targetPlanId"),
                    wordOrderRef
                )
            ),
            _word(manifest, ".expected.existingEvmDockInstanceId")
        );
        _assertDistinct(
            keccak256(
                abi.encode(
                    DOMAIN_DOCK_INSTANCE,
                    _word(manifest, ".expected.evmRuntimeDomain"),
                    _word(manifest, ".inputs.parentPlanIdWord"),
                    _word(manifest, ".expected.parentDefinitionRefHash"),
                    _word(manifest, ".expected.localOrderKey"),
                    _word(manifest, ".expected.dockRoutes[1].routeId"),
                    _word(manifest, ".expected.dockRoutes[1].routeHash"),
                    uint256(1),
                    _word(manifest, ".expected.interfaceNameIds.production_evidence"),
                    _word(manifest, ".expected.targetPlanId"),
                    keccak256("different-order")
                )
            ),
            _word(manifest, ".expected.existingEvmDockInstanceId")
        );
    }

    function testDynamicSelectionCandidateVectorsMatch() public {
        string memory manifest = _manifest();
        bytes32 routeIdWord = _word(manifest, ".expected.dynamicSelection.routeId");
        bytes32 evidenceNameId = _word(manifest, ".expected.interfaceNameIds.production_evidence");
        bytes32 targetDefRef = _word(manifest, ".expected.targetDefinitionRefHash");
        bytes32 targetPlanId = _word(manifest, ".expected.targetPlanId");

        bytes32 candidateLeaf =
            keccak256(abi.encode(DOMAIN_DOCK_CANDIDATE, routeIdWord, targetDefRef, targetPlanId, evidenceNameId));
        assertEq(candidateLeaf, _word(manifest, ".expected.dynamicSelection.candidateLeaf"));
        bytes32 otherLeaf = keccak256(
            abi.encode(
                DOMAIN_DOCK_CANDIDATE,
                routeIdWord,
                keccak256(abi.encode(DOMAIN_DEFINITION_REF, keccak256("zx-ffffffffffffffffffffffffffffff"))),
                keccak256("chain-plan:zx-ffffffffffffffffffffffffffffff"),
                evidenceNameId
            )
        );
        assertEq(otherLeaf, _word(manifest, ".expected.dynamicSelection.otherCandidateLeaf"));

        _assertDistinct(candidateLeaf, otherLeaf);

        bytes32 candidatesRoot = _word(manifest, ".expected.dynamicSelection.candidatesRoot");
        uint256 proofLength = vm.parseJsonUint(manifest, ".expected.dynamicSelection.candidateProofLength");
        bytes32[] memory proof = new bytes32[](proofLength);
        for (uint256 i = 0; i < proofLength; i++) {
            proof[i] = _word(manifest, string.concat(".expected.dynamicSelection.candidateProof[", vmIndex(i), "]"));
        }
        require(DockMerkle.verify(candidatesRoot, candidateLeaf, proof), "candidate proof does not verify");

        assertEq(
            keccak256(
                abi.encode(
                    DOMAIN_ROUTE,
                    _word(manifest, ".expected.parentDefinitionRefHash"),
                    candidatesRoot,
                    bytes32(uint256(0)),
                    evidenceNameId,
                    uint256(1),
                    DockMerkle.EMPTY_ROOT,
                    DockMerkle.EMPTY_ROOT
                )
            ),
            _word(manifest, ".expected.dynamicSelection.dynamicRouteHash")
        );
    }

    function _outputBindingHash(
        string memory manifest,
        bytes32 routeIdWord,
        bytes32 interfaceNameId,
        string memory base
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_OUTPUT_BINDING,
                routeIdWord,
                interfaceNameId,
                _word(manifest, string.concat(base, ".localSourceId")),
                _word(manifest, string.concat(base, ".localSignalId")),
                keccak256(bytes(_str(manifest, string.concat(base, ".targetPort")))),
                _word(manifest, string.concat(base, ".targetSourceId")),
                _word(manifest, string.concat(base, ".targetSignalId"))
            )
        );
    }

    function _orderModesMask(string memory mode) private pure returns (uint8) {
        if (keccak256(bytes(mode)) == keccak256(bytes("new"))) {
            return 1;
        }
        if (keccak256(bytes(mode)) == keccak256(bytes("existing"))) {
            return 2;
        }
        revert("dock manifest unknown order mode");
    }

    function vmIndex(uint256 index) private pure returns (string memory) {
        if (index == 0) {
            return "0";
        }
        if (index == 1) {
            return "1";
        }
        revert("dock manifest index out of fixture range");
    }
}
