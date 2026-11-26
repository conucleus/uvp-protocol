// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "uvp-contracts/UVPStateMachine.sol";
import {UVPIdentityRegistry} from "uvp-contracts/UVPIdentityRegistry.sol";
import {UVPPlanMetadataModule} from "uvp-contracts/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "uvp-contracts/UVPStagePatchModule.sol";
import {UVPFileResourceModule} from "uvp-contracts/UVPFileResourceModule.sol";
import {UVPDerivedSignalModule} from "uvp-contracts/UVPDerivedSignalModule.sol";
import {IUVPStateMachineCore} from "uvp-contracts/interfaces/IUVPStateMachineCore.sol";
import {StageFile} from "uvp-contracts/interfaces/IUVPFileResourceModule.sol";
import {MerkleCommitment} from "uvp-contracts/libraries/MerkleCommitment.sol";
import {
    _HOOK_FLAG_ORDER_TRIGGER_MINT,
    _HOOK_FLAG_EMIT_READY,
    _HOOK_FLAG_DYNAMIC_EXECUTOR,
    _EIP712_DOMAIN_TYPEHASH,
    _EIP712_NAME_HASH,
    _EIP712_VERSION_HASH,
    _PLAN_COMMIT_TYPEHASH,
    _SUPPLIER_BINDING_LEAF_DOMAIN
} from "uvp-contracts/UVPStateMachineConstants.sol";
import {IUVPDockController} from "../src/interfaces/IUVPDockController.sol";
import {UVPDockController} from "../src/UVPDockController.sol";

// Contract test suite for UVPDockController invariants: bidirectional Mode B
// pairing, 1:N fan-out broadcast, RPN delay/veto window evaluation, and
// exact custom-error enforcement on security boundaries.
interface Vm {
    function addr(uint256 privateKey) external returns (address keyAddr);
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

contract Eip1271ConsentWallet {
    bytes4 private constant _MAGIC = 0x1626ba7e;
    bool public valid = true;

    function setValid(bool nextValid) external {
        valid = nextValid;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return valid ? _MAGIC : bytes4(0xffffffff);
    }

    function registerSupplier(UVPIdentityRegistry registry) external returns (bytes32) {
        return registry.registerSupplier(address(this));
    }
}

contract UVPDockControllerTest {
    struct SignalCapability {
        bytes32 stageId;
        bytes32 targetSourceId;
        bytes32 signalId;
    }

    struct SelectorBinding {
        bytes32 selectorStageId;
        bytes32 targetStageId;
    }

    struct PlanFixture {
        bytes32 planId;
        bytes32[] sortedCapLeaves;
    }

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant DOMAIN_SIGNAL_CAPABILITY = keccak256("UVP_SIGNAL_CAPABILITY_V1");
    bytes32 private constant DOMAIN_SELECTOR_BINDING = keccak256("UVP_SELECTOR_BINDING_V1");

    uint256 private constant PK_PUBLISHER = 0xa101;
    uint256 private constant PK_BUYER = 0xb202;
    uint256 private constant PK_BROKER = 0xc303;
    uint256 private constant PK_SHIP = 0xd404;
    uint256 private constant PK_FORGER = 0xe505;

    bytes32 private constant STAGE_A_BUYER = keccak256("stage.a.buyer");
    bytes32 private constant STAGE_A_WORK = keccak256("stage.a.work");
    bytes32 private constant STAGE_B_BROKER = keccak256("stage.b.broker");
    bytes32 private constant STAGE_B_UPSTREAM = keccak256("stage.b.upstream");
    bytes32 private constant STAGE_SHIP_OPS = keccak256("stage.ship.ops");
    bytes32 private constant STAGE_CAR_BUYER = keccak256("stage.car.buyer");
    bytes32 private constant STAGE_CAR_ARRIVAL = keccak256("stage.car.arrival");
    bytes32 private constant STAGE_CAR_OTHER = keccak256("stage.car.other");

    bytes32 private constant SIG_BIRTH = keccak256("sig.birth");
    bytes32 private constant SIG_PAID = keccak256("sig.paid");
    bytes32 private constant SIG_FUNDED = keccak256("sig.funded");
    bytes32 private constant SIG_CLEARED = keccak256("sig.cleared");
    bytes32 private constant SIG_SUBMIT = keccak256("sig.submit");
    bytes32 private constant SIG_ARRIVED = keccak256("sig.arrived");
    bytes32 private constant SIG_CAR_ARRIVED = keccak256("sig.car.arrived");
    bytes32 private constant SIG_OPEN = keccak256("sig.open");
    bytes32 private constant SIG_VETO = keccak256("sig.veto");

    UVPStateMachine private _sm;
    UVPIdentityRegistry private _registry;
    UVPPlanMetadataModule private _planMeta;
    UVPStagePatchModule private _stagePatch;
    UVPDockController private _controller;

    address private _publisher;
    address private _buyer;
    address private _broker;
    address private _ship;
    address private _forger;

    bytes32 private _buyerSid;
    bytes32 private _brokerSid;
    bytes32 private _shipSid;
    bytes32 private _controllerSid;

    uint256 private _idempSeq;

    function setUp() public {
        vm.warp(1_700_000_000);
        _publisher = vm.addr(PK_PUBLISHER);
        _buyer = vm.addr(PK_BUYER);
        _broker = vm.addr(PK_BROKER);
        _ship = vm.addr(PK_SHIP);
        _forger = vm.addr(PK_FORGER);

        _sm = new UVPStateMachine();
        _registry = new UVPIdentityRegistry();
        _planMeta = new UVPPlanMetadataModule(address(_sm));
        _stagePatch = new UVPStagePatchModule(address(_sm));
        UVPFileResourceModule fileMod = new UVPFileResourceModule(address(_sm));
        UVPDerivedSignalModule derivedMod = new UVPDerivedSignalModule(address(_sm));

        _sm.setIdentityRegistry(address(_registry));
        _sm.setPlanMetadataModule(address(_planMeta));
        _sm.setStagePatchModule(address(_stagePatch));
        _sm.setFileResourceModule(address(fileMod));
        _sm.setDerivedSignalModule(address(derivedMod));
        _sm.freezeModules();

        _buyerSid = _registerAndActivate(_buyer);
        _brokerSid = _registerAndActivate(_broker);
        _shipSid = _registerAndActivate(_ship);

        _controller = new UVPDockController(address(_sm));
        _controllerSid = _controller.controllerSupplierId();
        _registry.activateSupplier(_controllerSid);
    }

    function testModeBBidirectionalPairAndIdempotentReconcile() public {
        PlanFixture memory planA = _deployPlanA();
        PlanFixture memory planB = _deployPlanB();

        bytes32 orderA = _birthOrder(planA.planId, STAGE_A_BUYER, _buyer, _capProof(planA, STAGE_A_BUYER, STAGE_A_BUYER, SIG_BIRTH));
        bytes32 orderB = _birthOrder(planB.planId, STAGE_B_BROKER, _broker, _capProof(planB, STAGE_B_BROKER, STAGE_B_BROKER, SIG_BIRTH));

        _patchStage(planA, orderA, STAGE_A_BUYER, STAGE_A_WORK, _buyer, _controllerSid, 1);
        _patchStage(planB, orderB, STAGE_B_BROKER, STAGE_B_UPSTREAM, _broker, _controllerSid, 1);

        bytes32 dkidAtoB = _registerSingleSignalDock(
            planA, STAGE_A_BUYER, STAGE_A_BUYER, SIG_PAID, planB, STAGE_B_UPSTREAM, STAGE_B_UPSTREAM, SIG_FUNDED, keccak256("dock.a2b")
        );
        bytes32 dkidBtoA = _registerSingleSignalDock(
            planB, STAGE_B_BROKER, STAGE_B_BROKER, SIG_CLEARED, planA, STAGE_A_WORK, STAGE_A_WORK, SIG_SUBMIT, keccak256("dock.b2a")
        );

        IUVPDockController.BindLinkRequest memory reqAtoB = IUVPDockController.BindLinkRequest({
            dkid: dkidAtoB,
            fromOrderId: orderA,
            toOrderId: orderB,
            toConsentStageId: STAGE_B_BROKER,
            selectorProof: _selProof(planB, STAGE_B_BROKER, STAGE_B_UPSTREAM),
            deadline: block.timestamp + 300
        });
        IUVPDockController.BindLinkRequest memory reqBtoA = IUVPDockController.BindLinkRequest({
            dkid: dkidBtoA,
            fromOrderId: orderB,
            toOrderId: orderA,
            toConsentStageId: STAGE_A_BUYER,
            selectorProof: _selProof(planA, STAGE_A_BUYER, STAGE_A_WORK),
            deadline: block.timestamp + 300
        });

        bytes memory sigB = _signBindLink(reqAtoB, PK_BROKER);
        bytes memory sigA = _signBindLink(reqBtoA, PK_BUYER);

        (bytes32 linkAtoB, bytes32 linkBtoA) = _controller.bindLinkPair(reqAtoB, sigB, reqBtoA, sigA);
        require(_controller.getStageLink(planB.planId, orderB, STAGE_B_UPSTREAM) == linkAtoB, "stage link B mismatch");
        require(_controller.getStageLink(planA.planId, orderA, STAGE_A_WORK) == linkBtoA, "stage link A mismatch");

        uint64 t1 = 1_700_000_000;
        vm.warp(t1);
        _submitSignalDirect(planA.planId, orderA, STAGE_A_BUYER, STAGE_A_BUYER, SIG_PAID, _buyer, _capProof(planA, STAGE_A_BUYER, STAGE_A_BUYER, SIG_PAID));

        uint64 t2 = t1 + 100;
        vm.warp(t2);
        bytes32[][] memory proofsAtoB = _singleProofArray(_capProof(planB, STAGE_B_UPSTREAM, STAGE_B_UPSTREAM, SIG_FUNDED));
        uint256 emittedAtoB = _controller.reconcile(linkAtoB, proofsAtoB);
        require(emittedAtoB == 1, "A->B must emit 1 signal");

        (bool existsB, bytes32 payloadHashB,, uint64 submittedAtB, address submitterB) =
            _sm.getSignal(planB.planId, orderB, STAGE_B_UPSTREAM, SIG_FUNDED);
        require(existsB, "Order B funded signal missing");
        require(submittedAtB == t2, "Order B timestamp must equal target block.timestamp");
        require(submitterB == address(_controller), "Order B submitter must be controller");
        require(
            payloadHashB == keccak256(abi.encode("uvp.dock.provenance.v1", linkAtoB, dkidAtoB, planA.planId, orderA)),
            "Order B provenance hash mismatch"
        );
        require(_controller.reconcile(linkAtoB, proofsAtoB) == 0, "repeat A->B reconcile must be idempotent");

        _submitSignalDirect(planB.planId, orderB, STAGE_B_BROKER, STAGE_B_BROKER, SIG_CLEARED, _broker, _capProof(planB, STAGE_B_BROKER, STAGE_B_BROKER, SIG_CLEARED));

        uint64 t3 = t2 + 50;
        vm.warp(t3);
        bytes32[][] memory proofsBtoA = _singleProofArray(_capProof(planA, STAGE_A_WORK, STAGE_A_WORK, SIG_SUBMIT));
        uint256 emittedBtoA = _controller.reconcile(linkBtoA, proofsBtoA);
        require(emittedBtoA == 1, "B->A must emit 1 signal");

        (bool existsA,,, uint64 submittedAtA, address submitterA) =
            _sm.getSignal(planA.planId, orderA, STAGE_A_WORK, SIG_SUBMIT);
        require(existsA, "Order A submit signal missing");
        require(submittedAtA == t3, "Order A timestamp must equal target block.timestamp");
        require(submitterA == address(_controller), "Order A submitter must be controller");
        require(_controller.reconcile(linkBtoA, proofsBtoA) == 0, "repeat B->A reconcile must be idempotent");
    }

    function testOneToManyBroadcastFanOut() public {
        PlanFixture memory planShip = _deployPlanShip();
        PlanFixture memory planCar = _deployPlanCar(_buyerSid);

        bytes32 orderShip = _birthOrder(
            planShip.planId, STAGE_SHIP_OPS, _ship, _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_BIRTH)
        );
        bytes32 dkid = _registerSingleSignalDock(
            planShip,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_ARRIVED,
            planCar,
            STAGE_CAR_ARRIVAL,
            STAGE_CAR_ARRIVAL,
            SIG_CAR_ARRIVED,
            keccak256("dock.ship.to.car")
        );

        bytes32[] memory carOrders = new bytes32[](3);
        bytes32[] memory linkIds = new bytes32[](3);
        bytes32[] memory selProof = _selProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL);
        bytes32[] memory birthProof = _capProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_BUYER, SIG_BIRTH);

        for (uint256 i = 0; i < 3; i++) {
            carOrders[i] = _birthOrder(planCar.planId, STAGE_CAR_BUYER, _buyer, birthProof);
            _patchStage(planCar, carOrders[i], STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL, _buyer, _controllerSid, 1);

            IUVPDockController.BindLinkRequest memory req = IUVPDockController.BindLinkRequest({
                dkid: dkid,
                fromOrderId: orderShip,
                toOrderId: carOrders[i],
                toConsentStageId: STAGE_CAR_BUYER,
                selectorProof: selProof,
                deadline: block.timestamp + 300
            });
            if (i == 0) {
                vm.prank(_buyer);
                linkIds[i] = _controller.bindLink(req, "");
            } else {
                linkIds[i] = _controller.bindLink(req, _signBindLink(req, PK_BUYER));
            }
        }

        _submitSignalDirect(
            planShip.planId,
            orderShip,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_ARRIVED,
            _ship,
            _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_ARRIVED)
        );

        bytes32[][] memory outProofs = _singleProofArray(_capProof(planCar, STAGE_CAR_ARRIVAL, STAGE_CAR_ARRIVAL, SIG_CAR_ARRIVED));
        for (uint256 i = 0; i < 3; i++) {
            uint256 emitted = _controller.reconcile(linkIds[i], outProofs);
            require(emitted == 1, "each subscribed car order must emit");
            require(_sm.hasSignal(planCar.planId, carOrders[i], STAGE_CAR_ARRIVAL, SIG_CAR_ARRIVED), "car signal missing");
        }
    }

    function testWindowDelayAndVetoEvaluation() public {
        PlanFixture memory planShip = _deployPlanShip();
        PlanFixture memory planCar = _deployPlanCar(_buyerSid);

        bytes32 dkid = _registerDelayVetoDock(planShip, planCar, 60);

        bytes32 srcMatures = _birthOrder(
            planShip.planId, STAGE_SHIP_OPS, _ship, _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_BIRTH)
        );
        bytes32 dstMatures = _birthOrder(
            planCar.planId, STAGE_CAR_BUYER, _buyer, _capProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_BUYER, SIG_BIRTH)
        );
        _patchStage(planCar, dstMatures, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL, _buyer, _controllerSid, 1);

        IUVPDockController.BindLinkRequest memory reqMatures = IUVPDockController.BindLinkRequest({
            dkid: dkid,
            fromOrderId: srcMatures,
            toOrderId: dstMatures,
            toConsentStageId: STAGE_CAR_BUYER,
            selectorProof: _selProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL),
            deadline: block.timestamp + 300
        });
        vm.prank(_buyer);
        bytes32 linkMatures = _controller.bindLink(reqMatures, "");

        uint64 t0 = uint64(block.timestamp);
        _submitSignalDirect(
            planShip.planId,
            srcMatures,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_OPEN,
            _ship,
            _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_OPEN)
        );

        (bool active, bool srcSatisfied, uint64 srcDueAt, bool dstReady, bool emitted) =
            _controller.dockOutputWindow(linkMatures, 0);
        require(active && !srcSatisfied && srcDueAt == t0 + 60 && dstReady && !emitted, "delay window must wait");

        bytes32[][] memory outProofs = _singleProofArray(_capProof(planCar, STAGE_CAR_ARRIVAL, STAGE_CAR_ARRIVAL, SIG_CAR_ARRIVED));
        require(_controller.reconcile(linkMatures, outProofs) == 0, "must not emit before delay dueAt");

        vm.warp(t0 + 60);
        (, srcSatisfied, srcDueAt,,) = _controller.dockOutputWindow(linkMatures, 0);
        require(srcSatisfied && srcDueAt == 0, "delay window must satisfy at dueAt");
        require(_controller.reconcile(linkMatures, outProofs) == 1, "must emit after delay dueAt");
        require(_sm.hasSignal(planCar.planId, dstMatures, STAGE_CAR_ARRIVAL, SIG_CAR_ARRIVED), "matured signal missing");

        bytes32 srcVetoed = _birthOrder(
            planShip.planId, STAGE_SHIP_OPS, _ship, _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_BIRTH)
        );
        bytes32 dstVetoed = _birthOrder(
            planCar.planId, STAGE_CAR_BUYER, _buyer, _capProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_BUYER, SIG_BIRTH)
        );
        _patchStage(planCar, dstVetoed, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL, _buyer, _controllerSid, 1);

        IUVPDockController.BindLinkRequest memory reqVetoed = IUVPDockController.BindLinkRequest({
            dkid: dkid,
            fromOrderId: srcVetoed,
            toOrderId: dstVetoed,
            toConsentStageId: STAGE_CAR_BUYER,
            selectorProof: _selProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL),
            deadline: block.timestamp + 300
        });
        vm.prank(_buyer);
        bytes32 linkVetoed = _controller.bindLink(reqVetoed, "");

        uint64 tv0 = uint64(block.timestamp);
        _submitSignalDirect(
            planShip.planId,
            srcVetoed,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_OPEN,
            _ship,
            _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_OPEN)
        );
        vm.warp(tv0 + 30);
        _submitSignalDirect(
            planShip.planId,
            srcVetoed,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_VETO,
            _ship,
            _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_VETO)
        );

        vm.warp(tv0 + 120);
        (, srcSatisfied, srcDueAt,, emitted) = _controller.dockOutputWindow(linkVetoed, 0);
        require(!srcSatisfied && srcDueAt == 0 && !emitted, "vetoed window must never satisfy");
        require(_controller.reconcile(linkVetoed, outProofs) == 0, "vetoed window must not emit");
    }

    function testSecurityBoundariesRejectWithNamedErrors() public {
        PlanFixture memory planShip = _deployPlanShip();
        PlanFixture memory planCar = _deployPlanCar(_buyerSid);

        bytes32 orderShip1 = _birthOrder(
            planShip.planId, STAGE_SHIP_OPS, _ship, _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_BIRTH)
        );
        bytes32 orderShip2 = _birthOrder(
            planShip.planId, STAGE_SHIP_OPS, _ship, _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_BIRTH)
        );
        bytes32 orderCar = _birthOrder(
            planCar.planId, STAGE_CAR_BUYER, _buyer, _capProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_BUYER, SIG_BIRTH)
        );
        bytes32 dkid = _registerSingleSignalDock(
            planShip,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_ARRIVED,
            planCar,
            STAGE_CAR_ARRIVAL,
            STAGE_CAR_ARRIVAL,
            SIG_CAR_ARRIVED,
            keccak256("dock.sec")
        );

        bytes32[] memory validSelProof = _selProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL);

        IUVPDockController.BindLinkRequest memory reqUnassigned = IUVPDockController.BindLinkRequest({
            dkid: dkid,
            fromOrderId: orderShip1,
            toOrderId: orderCar,
            toConsentStageId: STAGE_CAR_BUYER,
            selectorProof: validSelProof,
            deadline: block.timestamp + 300
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPDockController.DockStageNotAssignedToController.selector,
                planCar.planId,
                orderCar,
                STAGE_CAR_ARRIVAL,
                address(0)
            )
        );
        vm.prank(_buyer);
        _controller.bindLink(reqUnassigned, "");

        _patchStage(planCar, orderCar, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL, _buyer, _controllerSid, 1);

        IUVPDockController.BindLinkRequest memory reqWrongSelector = IUVPDockController.BindLinkRequest({
            dkid: dkid,
            fromOrderId: orderShip1,
            toOrderId: orderCar,
            toConsentStageId: STAGE_CAR_OTHER,
            selectorProof: validSelProof,
            deadline: block.timestamp + 300
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPDockController.DockSelectorBindingNotFound.selector,
                planCar.planId,
                STAGE_CAR_OTHER,
                STAGE_CAR_ARRIVAL
            )
        );
        _controller.bindLink(reqWrongSelector, "");

        bytes memory forgedSig = _signBindLink(reqUnassigned, PK_FORGER);
        vm.expectRevert(
            abi.encodeWithSelector(UVPDockController.InvalidBindLinkSignature.selector, _buyer, _forger)
        );
        _controller.bindLink(reqUnassigned, forgedSig);

        bytes32 firstLinkId = _controller.bindLink(reqUnassigned, _signBindLink(reqUnassigned, PK_BUYER));

        IUVPDockController.BindLinkRequest memory reqDup = IUVPDockController.BindLinkRequest({
            dkid: dkid,
            fromOrderId: orderShip2,
            toOrderId: orderCar,
            toConsentStageId: STAGE_CAR_BUYER,
            selectorProof: validSelProof,
            deadline: block.timestamp + 300
        });
        bytes memory dupSig = _signBindLink(reqDup, PK_BUYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                UVPDockController.DockStageAlreadyLinked.selector,
                planCar.planId,
                orderCar,
                STAGE_CAR_ARRIVAL,
                firstLinkId
            )
        );
        _controller.bindLink(reqDup, dupSig);

        _submitSignalDirect(
            planShip.planId,
            orderShip1,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_ARRIVED,
            _ship,
            _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_ARRIVED)
        );
        _registry.suspendSupplier(_controllerSid);
        bytes32[][] memory outProofs = _singleProofArray(_capProof(planCar, STAGE_CAR_ARRIVAL, STAGE_CAR_ARRIVAL, SIG_CAR_ARRIVED));
        vm.expectRevert(abi.encodeWithSelector(UVPStateMachine.SupplierNotActive.selector, _controllerSid));
        _controller.reconcile(firstLinkId, outProofs);
    }

    function testEip1271ConsentWalletBindLink() public {
        Eip1271ConsentWallet wallet = new Eip1271ConsentWallet();
        bytes32 walletSid = wallet.registerSupplier(_registry);
        _registry.activateSupplier(walletSid);

        PlanFixture memory planShip = _deployPlanShip();
        PlanFixture memory planCar = _deployPlanCar(walletSid);

        bytes32 orderShip = _birthOrder(
            planShip.planId, STAGE_SHIP_OPS, _ship, _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_BIRTH)
        );
        bytes32 orderCar = _birthOrder(
            planCar.planId, STAGE_CAR_BUYER, address(wallet), _capProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_BUYER, SIG_BIRTH)
        );
        _patchStage(planCar, orderCar, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL, address(wallet), _controllerSid, 1);

        bytes32 dkid = _registerSingleSignalDock(
            planShip,
            STAGE_SHIP_OPS,
            STAGE_SHIP_OPS,
            SIG_ARRIVED,
            planCar,
            STAGE_CAR_ARRIVAL,
            STAGE_CAR_ARRIVAL,
            SIG_CAR_ARRIVED,
            keccak256("dock.eip1271")
        );

        IUVPDockController.BindLinkRequest memory req = IUVPDockController.BindLinkRequest({
            dkid: dkid,
            fromOrderId: orderShip,
            toOrderId: orderCar,
            toConsentStageId: STAGE_CAR_BUYER,
            selectorProof: _selProof(planCar, STAGE_CAR_BUYER, STAGE_CAR_ARRIVAL),
            deadline: block.timestamp + 300
        });

        wallet.setValid(false);
        vm.expectRevert(
            abi.encodeWithSelector(UVPDockController.InvalidBindLinkEIP1271Signature.selector, address(wallet))
        );
        _controller.bindLink(req, hex"1234");

        wallet.setValid(true);
        bytes32 linkId = _controller.bindLink(req, hex"1234");
        require(_controller.getLink(linkId).toConsent == address(wallet), "EIP-1271 consent mismatch");
    }

    function _deployPlanA() private returns (PlanFixture memory) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            keccak256("hook.a.birth"), STAGE_A_BUYER, SIG_BIRTH, _HOOK_FLAG_ORDER_TRIGGER_MINT | _HOOK_FLAG_EMIT_READY, STAGE_A_BUYER
        );
        hooks[1] = _signalHook(
            keccak256("hook.a.work"), STAGE_A_WORK, SIG_PAID, _HOOK_FLAG_EMIT_READY | _HOOK_FLAG_DYNAMIC_EXECUTOR, STAGE_A_BUYER
        );

        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](1);
        bindings[0] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_A_BUYER, supplierId: _buyerSid, kind: 0});

        SelectorBinding[] memory sels = new SelectorBinding[](1);
        sels[0] = SelectorBinding({selectorStageId: STAGE_A_BUYER, targetStageId: STAGE_A_WORK});

        SignalCapability[] memory caps = new SignalCapability[](3);
        caps[0] = SignalCapability({stageId: STAGE_A_BUYER, targetSourceId: STAGE_A_BUYER, signalId: SIG_BIRTH});
        caps[1] = SignalCapability({stageId: STAGE_A_BUYER, targetSourceId: STAGE_A_BUYER, signalId: SIG_PAID});
        caps[2] = SignalCapability({stageId: STAGE_A_WORK, targetSourceId: STAGE_A_WORK, signalId: SIG_SUBMIT});

        return _registerPlan(hooks, bindings, sels, caps);
    }

    function _deployPlanB() private returns (PlanFixture memory) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            keccak256("hook.b.birth"), STAGE_B_BROKER, SIG_BIRTH, _HOOK_FLAG_ORDER_TRIGGER_MINT | _HOOK_FLAG_EMIT_READY, STAGE_B_BROKER
        );
        hooks[1] = _signalHook(
            keccak256("hook.b.up"), STAGE_B_UPSTREAM, SIG_BIRTH, _HOOK_FLAG_EMIT_READY | _HOOK_FLAG_DYNAMIC_EXECUTOR, STAGE_B_BROKER
        );

        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](1);
        bindings[0] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_B_BROKER, supplierId: _brokerSid, kind: 0});

        SelectorBinding[] memory sels = new SelectorBinding[](1);
        sels[0] = SelectorBinding({selectorStageId: STAGE_B_BROKER, targetStageId: STAGE_B_UPSTREAM});

        SignalCapability[] memory caps = new SignalCapability[](3);
        caps[0] = SignalCapability({stageId: STAGE_B_BROKER, targetSourceId: STAGE_B_BROKER, signalId: SIG_BIRTH});
        caps[1] = SignalCapability({stageId: STAGE_B_BROKER, targetSourceId: STAGE_B_BROKER, signalId: SIG_CLEARED});
        caps[2] = SignalCapability({stageId: STAGE_B_UPSTREAM, targetSourceId: STAGE_B_UPSTREAM, signalId: SIG_FUNDED});

        return _registerPlan(hooks, bindings, sels, caps);
    }

    function _deployPlanShip() private returns (PlanFixture memory) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](1);
        hooks[0] = _signalHook(
            keccak256("hook.ship.birth"),
            STAGE_SHIP_OPS,
            SIG_BIRTH,
            _HOOK_FLAG_ORDER_TRIGGER_MINT | _HOOK_FLAG_EMIT_READY,
            STAGE_SHIP_OPS
        );

        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](1);
        bindings[0] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_SHIP_OPS, supplierId: _shipSid, kind: 0});

        SelectorBinding[] memory sels = new SelectorBinding[](0);

        SignalCapability[] memory caps = new SignalCapability[](4);
        caps[0] = SignalCapability({stageId: STAGE_SHIP_OPS, targetSourceId: STAGE_SHIP_OPS, signalId: SIG_BIRTH});
        caps[1] = SignalCapability({stageId: STAGE_SHIP_OPS, targetSourceId: STAGE_SHIP_OPS, signalId: SIG_ARRIVED});
        caps[2] = SignalCapability({stageId: STAGE_SHIP_OPS, targetSourceId: STAGE_SHIP_OPS, signalId: SIG_OPEN});
        caps[3] = SignalCapability({stageId: STAGE_SHIP_OPS, targetSourceId: STAGE_SHIP_OPS, signalId: SIG_VETO});

        return _registerPlan(hooks, bindings, sels, caps);
    }

    function _deployPlanCar(bytes32 buyerSupplierId) private returns (PlanFixture memory) {
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](2);
        hooks[0] = _signalHook(
            keccak256("hook.car.birth"),
            STAGE_CAR_BUYER,
            SIG_BIRTH,
            _HOOK_FLAG_ORDER_TRIGGER_MINT | _HOOK_FLAG_EMIT_READY,
            STAGE_CAR_BUYER
        );
        hooks[1] = _signalHook(
            keccak256("hook.car.arrival"),
            STAGE_CAR_ARRIVAL,
            SIG_BIRTH,
            _HOOK_FLAG_EMIT_READY | _HOOK_FLAG_DYNAMIC_EXECUTOR,
            STAGE_CAR_BUYER
        );

        UVPStateMachine.StageSupplierBinding[] memory bindings = new UVPStateMachine.StageSupplierBinding[](1);
        bindings[0] = UVPStateMachine.StageSupplierBinding({stageId: STAGE_CAR_BUYER, supplierId: buyerSupplierId, kind: 0});

        SelectorBinding[] memory sels = new SelectorBinding[](1);
        sels[0] = SelectorBinding({selectorStageId: STAGE_CAR_BUYER, targetStageId: STAGE_CAR_ARRIVAL});

        SignalCapability[] memory caps = new SignalCapability[](2);
        caps[0] = SignalCapability({stageId: STAGE_CAR_BUYER, targetSourceId: STAGE_CAR_BUYER, signalId: SIG_BIRTH});
        caps[1] = SignalCapability({stageId: STAGE_CAR_ARRIVAL, targetSourceId: STAGE_CAR_ARRIVAL, signalId: SIG_CAR_ARRIVED});

        return _registerPlan(hooks, bindings, sels, caps);
    }

    function _registerPlan(
        UVPStateMachine.CompactHook[] memory hooks,
        UVPStateMachine.StageSupplierBinding[] memory bindings,
        SelectorBinding[] memory sels,
        SignalCapability[] memory caps
    ) private returns (PlanFixture memory fixture) {
        bytes32[] memory rawLeaves = new bytes32[](sels.length + caps.length);
        for (uint256 i = 0; i < sels.length; i++) {
            rawLeaves[i] = keccak256(abi.encode(DOMAIN_SELECTOR_BINDING, sels[i].selectorStageId, sels[i].targetStageId));
        }
        for (uint256 i = 0; i < caps.length; i++) {
            rawLeaves[sels.length + i] = keccak256(
                abi.encode(DOMAIN_SIGNAL_CAPABILITY, caps[i].stageId, caps[i].targetSourceId, caps[i].signalId, uint256(0))
            );
        }

        bytes32[] memory sorted = _sortedUnique(rawLeaves);
        bytes32 capRoot = MerkleCommitment.root(sorted);
        bytes32[] memory bindingLeaves = new bytes32[](bindings.length);
        for (uint256 i = 0; i < bindings.length; i++) {
            bindingLeaves[i] = keccak256(
                abi.encodePacked(_SUPPLIER_BINDING_LEAF_DOMAIN, bindings[i].stageId, bindings[i].supplierId, bindings[i].kind)
            );
        }

        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: _publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: capRoot,
            supplierBindingsRoot: MerkleCommitment.root(bindingLeaves),
            deadline: block.timestamp + 600
        });
        bytes memory sig = _signPlanCommit(commit);
        bytes32 planId = _sm.commitPlan(commit, hooks, bindings, sig);
        _sm.finalizePlan(planId);

        fixture = PlanFixture({planId: planId, sortedCapLeaves: sorted});
    }

    function _registerSingleSignalDock(
        PlanFixture memory fromPlan,
        bytes32 fromStageId,
        bytes32 fromSourceId,
        bytes32 fromSignalId,
        PlanFixture memory toPlan,
        bytes32 toStageId,
        bytes32 toSourceId,
        bytes32 toSignalId,
        bytes32 docHash
    ) private returns (bytes32) {
        IUVPDockController.DockAtomInput[] memory atoms = new IUVPDockController.DockAtomInput[](1);
        atoms[0] = IUVPDockController.DockAtomInput({
            stageId: fromStageId,
            signalId: fromSignalId,
            relation: 0,
            capabilityProof: _capProof(fromPlan, fromStageId, fromSourceId, fromSignalId)
        });

        IUVPDockController.WindowInstruction[] memory window = new IUVPDockController.WindowInstruction[](1);
        window[0] = IUVPDockController.WindowInstruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: fromSourceId,
            signalId: fromSignalId,
            arity: 0,
            delaySeconds: 0
        });

        IUVPDockController.DockOutputInput[] memory outputs = new IUVPDockController.DockOutputInput[](1);
        outputs[0] = IUVPDockController.DockOutputInput({
            signalId: toSignalId,
            relation: 0,
            atoms: atoms,
            window: window,
            capabilityProof: _capProof(toPlan, toStageId, toSourceId, toSignalId)
        });

        return _controller.registerDock(
            fromPlan.planId, fromSourceId, toPlan.planId, toStageId, toSourceId, docHash, outputs
        );
    }

    function _registerDelayVetoDock(PlanFixture memory planShip, PlanFixture memory planCar, uint64 delaySeconds)
        private
        returns (bytes32)
    {
        IUVPDockController.DockAtomInput[] memory atoms = new IUVPDockController.DockAtomInput[](2);
        atoms[0] = IUVPDockController.DockAtomInput({
            stageId: STAGE_SHIP_OPS,
            signalId: SIG_OPEN,
            relation: 0,
            capabilityProof: _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_OPEN)
        });
        atoms[1] = IUVPDockController.DockAtomInput({
            stageId: STAGE_SHIP_OPS,
            signalId: SIG_VETO,
            relation: 0,
            capabilityProof: _capProof(planShip, STAGE_SHIP_OPS, STAGE_SHIP_OPS, SIG_VETO)
        });

        IUVPDockController.WindowInstruction[] memory window = new IUVPDockController.WindowInstruction[](5);
        window[0] = IUVPDockController.WindowInstruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: STAGE_SHIP_OPS,
            signalId: SIG_OPEN,
            arity: 0,
            delaySeconds: 0
        });
        window[1] = IUVPDockController.WindowInstruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: delaySeconds
        });
        window[2] = IUVPDockController.WindowInstruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: STAGE_SHIP_OPS,
            signalId: SIG_VETO,
            arity: 0,
            delaySeconds: 0
        });
        window[3] = IUVPDockController.WindowInstruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
        window[4] = IUVPDockController.WindowInstruction({
            op: uint8(UVPStateMachine.InstructionOp.And),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 2,
            delaySeconds: 0
        });

        IUVPDockController.DockOutputInput[] memory outputs = new IUVPDockController.DockOutputInput[](1);
        outputs[0] = IUVPDockController.DockOutputInput({
            signalId: SIG_CAR_ARRIVED,
            relation: 0,
            atoms: atoms,
            window: window,
            capabilityProof: _capProof(planCar, STAGE_CAR_ARRIVAL, STAGE_CAR_ARRIVAL, SIG_CAR_ARRIVED)
        });

        return _controller.registerDock(
            planShip.planId,
            STAGE_SHIP_OPS,
            planCar.planId,
            STAGE_CAR_ARRIVAL,
            STAGE_CAR_ARRIVAL,
            keccak256("dock.delay.veto"),
            outputs
        );
    }

    function _birthOrder(bytes32 planId, bytes32 stageId, address submitter, bytes32[] memory proof)
        private
        returns (bytes32 orderId)
    {
        _idempSeq += 1;
        UVPStateMachine.SignalSubmission memory sub = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: bytes32(0),
            sourceId: stageId,
            signalId: SIG_BIRTH,
            payloadHash: keccak256(abi.encode("birth", _idempSeq)),
            idempotencyKey: keccak256(abi.encode("idemp", _idempSeq)),
            attribution: UVPStateMachine.FactAttribution({
                sourceId: stageId, signalId: SIG_BIRTH, stageId: stageId, capabilityProof: proof
            }),
            targetStageId: bytes32(0),
            files: new StageFile[](0),
            submitter: submitter,
            deadline: block.timestamp + 300
        });
        vm.prank(submitter);
        (orderId,) = _sm.submitSignal(sub, "");
    }

    function _submitSignalDirect(
        bytes32 planId,
        bytes32 orderId,
        bytes32 stageId,
        bytes32 sourceId,
        bytes32 signalId,
        address submitter,
        bytes32[] memory proof
    ) private {
        _idempSeq += 1;
        UVPStateMachine.SignalSubmission memory sub = UVPStateMachine.SignalSubmission({
            planId: planId,
            orderId: orderId,
            sourceId: sourceId,
            signalId: signalId,
            payloadHash: keccak256(abi.encode("payload", _idempSeq)),
            idempotencyKey: keccak256(abi.encode("idemp", _idempSeq)),
            attribution: UVPStateMachine.FactAttribution({
                sourceId: sourceId, signalId: signalId, stageId: stageId, capabilityProof: proof
            }),
            targetStageId: bytes32(0),
            files: new StageFile[](0),
            submitter: submitter,
            deadline: block.timestamp + 300
        });
        vm.prank(submitter);
        _sm.submitSignal(sub, "");
    }

    function _patchStage(
        PlanFixture memory plan,
        bytes32 orderId,
        bytes32 selectorStageId,
        bytes32 targetStageId,
        address selectorAccount,
        bytes32 supplierId,
        uint256 patchNonce
    ) private {
        UVPStagePatchModule.StageSupplierPatch memory patch = UVPStagePatchModule.StageSupplierPatch({
            selectorStageId: selectorStageId,
            targetStageId: targetStageId,
            supplierId: supplierId,
            previousSupplierId: bytes32(0),
            patchNonce: patchNonce
        });
        IUVPStateMachineCore.SelectorBindingProof memory bindingProof = IUVPStateMachineCore.SelectorBindingProof({
            selectorStageId: selectorStageId, proof: _selProof(plan, selectorStageId, targetStageId)
        });
        vm.prank(selectorAccount);
        _stagePatch.applyStageSupplierPatch(plan.planId, orderId, patch, bindingProof, new bytes32[](0));
    }

    function _registerAndActivate(address account) private returns (bytes32 supplierId) {
        vm.prank(account);
        supplierId = _registry.registerSupplier(account);
        _registry.activateSupplier(supplierId);
    }

    function _signPlanCommit(UVPStateMachine.PlanCommit memory commit) private returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(_sm))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                _PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.capabilitiesRoot,
                commit.supplierBindingsRoot,
                commit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK_PUBLISHER, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signBindLink(IUVPDockController.BindLinkRequest memory req, uint256 pk) private returns (bytes memory) {
        bytes32 digest = _controller.bindLinkDigest(req);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signalHook(bytes32 hookId, bytes32 stageId, bytes32 signalId, uint8 flags, bytes32 sourceId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instructions = new UVPStateMachine.Instruction[](1);
        instructions[0] = UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: sourceId,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
        bytes32[] memory deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(sourceId, signalId));
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: keccak256(abi.encode(hookId)),
            flags: flags,
            instructions: instructions,
            dependencyKeys: deps
        });
    }

    function _capProof(PlanFixture memory plan, bytes32 stageId, bytes32 targetSourceId, bytes32 signalId)
        private
        pure
        returns (bytes32[] memory)
    {
        bytes32 leaf = keccak256(abi.encode(DOMAIN_SIGNAL_CAPABILITY, stageId, targetSourceId, signalId, uint256(0)));
        return _merkleProofFor(plan.sortedCapLeaves, leaf);
    }

    function _selProof(PlanFixture memory plan, bytes32 selectorStageId, bytes32 targetStageId)
        private
        pure
        returns (bytes32[] memory)
    {
        bytes32 leaf = keccak256(abi.encode(DOMAIN_SELECTOR_BINDING, selectorStageId, targetStageId));
        return _merkleProofFor(plan.sortedCapLeaves, leaf);
    }

    function _singleProofArray(bytes32[] memory proof) private pure returns (bytes32[][] memory arr) {
        arr = new bytes32[][](1);
        arr[0] = proof;
    }

    function _sortedUnique(bytes32[] memory raw) private pure returns (bytes32[] memory) {
        bytes32[] memory sorted = new bytes32[](raw.length);
        uint256 count;
        for (uint256 i = 0; i < raw.length; i++) {
            bool duplicate;
            for (uint256 j = 0; j < count; j++) {
                if (sorted[j] == raw[i]) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                sorted[count++] = raw[i];
            }
        }
        for (uint256 i = 1; i < count; i++) {
            bytes32 key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key;
        }
        bytes32[] memory exact = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            exact[i] = sorted[i];
        }
        return exact;
    }

    function _merkleProofFor(bytes32[] memory sorted, bytes32 leaf) private pure returns (bytes32[] memory proof) {
        uint256 index = type(uint256).max;
        for (uint256 i = 0; i < sorted.length; i++) {
            if (sorted[i] == leaf) {
                index = i;
                break;
            }
        }
        require(index != type(uint256).max, "leaf not in tree");
        bytes32[] memory buffer = new bytes32[](64);
        uint256 count;
        bytes32[] memory level = sorted;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) {
                buffer[count++] = level[sibling];
            }
            uint256 nextLength = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLength);
            uint256 cursor;
            for (uint256 i = 0; i + 1 < level.length; i += 2) {
                next[cursor++] = MerkleCommitment.pair(level[i], level[i + 1]);
            }
            if (level.length % 2 == 1) {
                next[cursor] = level[level.length - 1];
            }
            level = next;
            index /= 2;
        }
        proof = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            proof[i] = buffer[i];
        }
    }
}
