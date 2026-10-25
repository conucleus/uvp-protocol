// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UVPStateMachine} from "../src/UVPStateMachine.sol";
import {UVPDerivedSignalModule} from "../src/UVPDerivedSignalModule.sol";
import {UVPDockingModule} from "../src/UVPDockingModule.sol";
import {UVPOrderLinkModule} from "../src/UVPOrderLinkModule.sol";
import {UVPPlanMetadataModule} from "../src/UVPPlanMetadataModule.sol";
import {UVPStagePatchModule} from "../src/UVPStagePatchModule.sol";
import {UVPStateMachineLens} from "../src/UVPStateMachineLens.sol";
import {UVPSignatures} from "../src/libraries/UVPSignatures.sol";

interface InvariantVm {
    function addr(uint256 privateKey) external returns (address keyAddr);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function warp(uint256 newTimestamp) external;
}

contract UVPStateMachineInvariantsTest {
    Handler private handler;

    function setUp() public {
        handler = new Handler();
        handler.bootstrap();
    }

    function invariant_TerminalHookStatesAreImmutable() public view {
        require(handler.terminalViolationCount() == 0, "terminal hook state was rewritten");
    }

    function invariant_SignalFirstWriteWins() public view {
        require(handler.firstWriteViolationCount() == 0, "first-write payload was overwritten");
    }

    function invariant_WaitDeadlineIsMonotonic() public view {
        require(handler.waitDeadlineViolationCount() == 0, "wait dueAt regressed");
    }
}

contract Handler {
    InvariantVm private constant vm = InvariantVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant PUBLISHER_PRIVATE_KEY = 0xc0ffee;
    uint256 private constant SUBMITTER_PRIVATE_KEY = 0xa11ce;
    bytes32 private constant ROLE_BOOTSTRAP = bytes32(uint256(0xa001));
    bytes32 private constant AUTH_METADATA_HASH = bytes32(uint256(0xa002));
    address private constant ORDER_CREATOR = address(uint160(0xc0de));
    bytes32 private constant EMPTY_DOCK_ROOT = keccak256("");
    uint8 private constant FLAG_ORDER_TRIGGER_MINT = 1;
    uint8 private constant FLAG_EMIT_READY = 4;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant STATE_MACHINE_NAME_HASH = keccak256("UVPStateMachine");
    bytes32 private constant STATE_MACHINE_VERSION_HASH = keccak256("0.15");
    bytes32 private constant PLAN_COMMIT_TYPEHASH = keccak256(
        "UVPStateMachinePlanCommit(address publisher,bytes32 hooksHash,bytes32 capabilitiesRoot,bytes32 dockRoutesRoot,bytes32 dockInterfaceRoot,bytes32 executorCandidatesRoot,address birthAuthorizer,uint256 deadline)"
    );
    bytes32 private constant TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH = keccak256(
        "UVPStateMachineTriggerOrderFromOutside(bytes32 planId,address creator,bytes32 triggerHookId,bytes32 triggerStageId,bytes32 sourceId,bytes32 signalId,bytes32 payloadHash,bytes32 idempotencyKey,bytes32 authorizationsHash,address submitter,uint256 deadline)"
    );

    uint256 private constant ORDER_COUNT = 2;
    uint256 private constant HOOK_COUNT = 6;
    uint256 private constant SIGNAL_COUNT = 9;

    UVPStateMachine private machine;
    bytes32 private planId;
    bytes32[ORDER_COUNT] private orderIds;
    bytes32[HOOK_COUNT] private hookIds;
    bytes32[SIGNAL_COUNT] private signalIds;
    bytes32 private constant SOURCE = bytes32(uint256(0x3001));

    mapping(bytes32 orderId => mapping(bytes32 hookId => uint8 terminalStatus)) private ghostTerminal;
    mapping(bytes32 orderId => mapping(bytes32 hookId => uint64 maxWaitDueAt)) private ghostMaxWaitDueAt;
    mapping(bytes32 orderId => mapping(bytes32 signalKey => bytes32 firstPayload)) private ghostFirstPayload;

    uint256 public terminalViolationCount;
    uint256 public firstWriteViolationCount;
    uint256 public waitDeadlineViolationCount;
    bool private bootstrapped;

    function bootstrap() external {
        require(!bootstrapped, "already bootstrapped");
        bootstrapped = true;
        machine = new UVPStateMachine();
        UVPStagePatchModule stagePatch = new UVPStagePatchModule(address(machine));
        UVPDerivedSignalModule derivedSignal = new UVPDerivedSignalModule(address(machine));
        UVPPlanMetadataModule planMetadata = new UVPPlanMetadataModule(address(machine));
        UVPDockingModule docking = new UVPDockingModule(address(machine), address(planMetadata));
        UVPOrderLinkModule orderLink = new UVPOrderLinkModule(address(machine));
        machine.setStagePatchModule(address(stagePatch));
        machine.setDerivedSignalModule(address(derivedSignal));
        machine.setDockingModule(address(docking));
        machine.setPlanMetadataModule(address(planMetadata));
        machine.setOrderLinkModule(address(orderLink));
        machine.setLens(address(new UVPStateMachineLens(address(machine))));
        machine.freezeModules();

        signalIds[0] = bytes32(uint256(0x4000));
        for (uint256 i = 1; i < SIGNAL_COUNT; i++) {
            signalIds[i] = keccak256(abi.encode("invariant.signal", i));
        }
        bytes32 stage0 = keccak256("invariant.stage.0");
        bytes32 stage1 = keccak256("invariant.stage.1");
        bytes32 stage2 = keccak256("invariant.stage.2");
        UVPStateMachine.CompactHook[] memory hooks = new UVPStateMachine.CompactHook[](HOOK_COUNT);

        hookIds[0] = keccak256("invariant.hook.birth");
        hooks[0] = _signalHook(hookIds[0], stage0, FLAG_ORDER_TRIGGER_MINT | FLAG_EMIT_READY, signalIds[0]);

        hookIds[1] = keccak256("invariant.hook.watch");
        hooks[1] = _signalHook(hookIds[1], stage1, FLAG_EMIT_READY, signalIds[1]);

        hookIds[2] = keccak256("invariant.hook.timer");
        {
            UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](2);
            instrs[0] = _sig(signalIds[2]);
            instrs[1] = _delay(5);
            hooks[2] = _hookWithFlags(hookIds[2], stage1, FLAG_EMIT_READY, instrs, _deps(signalIds[2]));
        }

        hookIds[3] = keccak256("invariant.hook.negative");
        {
            UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](4);
            instrs[0] = _sig(signalIds[3]);
            instrs[1] = _not();
            instrs[2] = _sig(signalIds[4]);
            instrs[3] = _and(2);
            hooks[3] = _hookWithFlags(hookIds[3], stage1, FLAG_EMIT_READY, instrs, _deps(signalIds[3], signalIds[4]));
        }

        hookIds[4] = keccak256("invariant.hook.andDelays");
        {
            UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](5);
            instrs[0] = _sig(signalIds[5]);
            instrs[1] = _delay(5);
            instrs[2] = _sig(signalIds[6]);
            instrs[3] = _delay(10);
            instrs[4] = _and(2);
            hooks[4] = _hookWithFlags(hookIds[4], stage2, FLAG_EMIT_READY, instrs, _deps(signalIds[5], signalIds[6]));
        }

        hookIds[5] = keccak256("invariant.hook.orDelay");
        {
            UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](4);
            instrs[0] = _sig(signalIds[7]);
            instrs[1] = _sig(signalIds[8]);
            instrs[2] = _or(2);
            instrs[3] = _delay(5);
            hooks[5] = _hookWithFlags(hookIds[5], stage2, FLAG_EMIT_READY, instrs, _deps(signalIds[7], signalIds[8]));
        }

        planId = _registerPlan(hooks);

        for (uint256 o = 0; o < ORDER_COUNT; o++) {
            orderIds[o] = _birthOrder(o);
        }
        _observe();
    }

    function submitSignal(uint256 seed) external {
        require(bootstrapped, "not bootstrapped");
        bytes32 orderId = orderIds[seed % ORDER_COUNT];
        bytes32 signalId = signalIds[seed % SIGNAL_COUNT];
        try machine.submitSignal(
            planId,
            orderId,
            SOURCE,
            signalId,
            keccak256(abi.encode("payload", seed)),
            keccak256(abi.encode("idem", seed)),
            _noAttribution()
        ) {}
            catch {}
        _observe();
    }

    function pokeTimer(uint256 seed) external {
        require(bootstrapped, "not bootstrapped");
        bytes32 orderId = orderIds[seed % ORDER_COUNT];
        bytes32 hookId = hookIds[seed % HOOK_COUNT];
        try machine.pokeTimer(planId, orderId, hookId) {} catch {}
        _observe();
    }

    function advanceTime(uint256 seed) external {
        require(bootstrapped, "not bootstrapped");
        vm.warp(block.timestamp + 1 + (seed % 96));
        _observe();
    }

    function _observe() private {
        for (uint256 o = 0; o < ORDER_COUNT; o++) {
            bytes32 orderId = orderIds[o];
            for (uint256 h = 0; h < HOOK_COUNT; h++) {
                bytes32 hookId = hookIds[h];
                try machine.getHookStatus(planId, orderId, hookId) returns (
                    UVPStateMachine.HookStatus status, uint64 dueAt, bool
                ) {
                    uint8 terminal = ghostTerminal[orderId][hookId];
                    if (terminal != 0) {
                        if (uint8(status) != terminal) {
                            terminalViolationCount += 1;
                        }
                    } else if (
                        status == UVPStateMachine.HookStatus.Ready || status == UVPStateMachine.HookStatus.Cancelled
                    ) {
                        ghostTerminal[orderId][hookId] = uint8(status);
                    }
                    if (status == UVPStateMachine.HookStatus.Wait) {
                        if (dueAt < ghostMaxWaitDueAt[orderId][hookId]) {
                            waitDeadlineViolationCount += 1;
                        } else if (dueAt > ghostMaxWaitDueAt[orderId][hookId]) {
                            ghostMaxWaitDueAt[orderId][hookId] = dueAt;
                        }
                    }
                } catch {}
            }
            for (uint256 s = 0; s < SIGNAL_COUNT; s++) {
                (bool exists, bytes32 payloadHash,,,) = machine.getSignal(planId, orderId, SOURCE, signalIds[s]);
                if (!exists) {
                    continue;
                }
                bytes32 key = keccak256(abi.encode(SOURCE, signalIds[s]));
                bytes32 first = ghostFirstPayload[orderId][key];
                if (first == bytes32(0)) {
                    ghostFirstPayload[orderId][key] = payloadHash;
                } else if (payloadHash != first) {
                    firstWriteViolationCount += 1;
                }
            }
        }
    }

    function _birthOrder(uint256 orderIdx) private returns (bytes32 orderId) {
        UVPStateMachine.SignalAuthorization[] memory authorizations =
            new UVPStateMachine.SignalAuthorization[](SIGNAL_COUNT);
        for (uint256 s = 0; s < SIGNAL_COUNT; s++) {
            authorizations[s] = UVPStateMachine.SignalAuthorization({
                sourceId: SOURCE,
                signalId: signalIds[s],
                submitter: address(this),
                role: ROLE_BOOTSTRAP,
                metadataHash: AUTH_METADATA_HASH
            });
        }
        bytes32 payload = keccak256(abi.encode("birth", orderIdx));
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger = UVPStateMachine.TriggerOrderFromOutsideRequest({
            planId: planId,
            creator: ORDER_CREATOR,
            triggerHookId: hookIds[0],
            triggerStageId: keccak256("invariant.stage.0"),
            sourceId: SOURCE,
            signalId: signalIds[0],
            payloadHash: payload,
            idempotencyKey: keccak256(abi.encode("birth-idem", orderIdx)),
            submitter: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        bytes memory signature = _outsideTriggerSignature(trigger, authorizations);
        machine.triggerOrderFromOutsideFor(trigger, authorizations, signature, _noAttribution());
        return machine.triggerOrderIdFor(planId, SOURCE, signalIds[0], payload);
    }

    function _registerPlan(UVPStateMachine.CompactHook[] memory hooks) private returns (bytes32) {
        address publisher = vm.addr(PUBLISHER_PRIVATE_KEY);
        UVPStateMachine.PlanCommit memory commit = UVPStateMachine.PlanCommit({
            publisher: publisher,
            hooksHash: keccak256(abi.encode(hooks)),
            capabilitiesRoot: EMPTY_DOCK_ROOT,
            dockRoutesRoot: EMPTY_DOCK_ROOT,
            dockInterfaceRoot: EMPTY_DOCK_ROOT,
            executorCandidatesRoot: EMPTY_DOCK_ROOT,
            birthAuthorizer: vm.addr(SUBMITTER_PRIVATE_KEY),
            deadline: type(uint256).max
        });
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_COMMIT_TYPEHASH,
                commit.publisher,
                commit.hooksHash,
                commit.capabilitiesRoot,
                commit.dockRoutesRoot,
                commit.dockInterfaceRoot,
                commit.executorCandidatesRoot,
                commit.birthAuthorizer,
                commit.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PUBLISHER_PRIVATE_KEY, _digest(structHash));
        bytes32 registered =
            machine.commitPlan(commit, hooks, new UVPStateMachine.ExecutorCandidate[](0), _packedSignature(v, r, s));
        machine.finalizePlan(registered);
        return registered;
    }

    function _outsideTriggerSignature(
        UVPStateMachine.TriggerOrderFromOutsideRequest memory trigger,
        UVPStateMachine.SignalAuthorization[] memory authorizations
    ) private returns (bytes memory) {
        bytes32 rollingHash = keccak256(abi.encode(authorizations.length));
        for (uint256 i = 0; i < authorizations.length; i++) {
            rollingHash = keccak256(
                abi.encode(
                    rollingHash,
                    authorizations[i].sourceId,
                    authorizations[i].signalId,
                    authorizations[i].submitter,
                    authorizations[i].role,
                    authorizations[i].metadataHash
                )
            );
        }
        bytes32 structHash = keccak256(
            abi.encode(
                TRIGGER_ORDER_FROM_OUTSIDE_TYPEHASH,
                trigger.planId,
                trigger.creator,
                trigger.triggerHookId,
                trigger.triggerStageId,
                trigger.sourceId,
                trigger.signalId,
                trigger.payloadHash,
                trigger.idempotencyKey,
                rollingHash,
                trigger.submitter,
                trigger.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SUBMITTER_PRIVATE_KEY, _digest(structHash));
        return _packedSignature(v, r, s);
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        EIP712_DOMAIN_TYPEHASH,
                        STATE_MACHINE_NAME_HASH,
                        STATE_MACHINE_VERSION_HASH,
                        block.chainid,
                        address(machine)
                    )
                ),
                structHash
            )
        );
    }

    function _signalHook(bytes32 hookId, bytes32 stageId, uint8 flags, bytes32 signalId)
        private
        pure
        returns (UVPStateMachine.CompactHook memory)
    {
        UVPStateMachine.Instruction[] memory instrs = new UVPStateMachine.Instruction[](1);
        instrs[0] = _sig(signalId);
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: keccak256(abi.encode("invariant.hookname", hookId)),
            flags: flags,
            instructions: instrs,
            dependencyKeys: _deps(signalId)
        });
    }

    function _hookWithFlags(
        bytes32 hookId,
        bytes32 stageId,
        uint8 flags,
        UVPStateMachine.Instruction[] memory instrs,
        bytes32[] memory deps
    ) private pure returns (UVPStateMachine.CompactHook memory) {
        return UVPStateMachine.CompactHook({
            hookId: hookId,
            stageId: stageId,
            hookName: keccak256(abi.encode("invariant.hookname", hookId)),
            flags: flags,
            instructions: instrs,
            dependencyKeys: deps
        });
    }

    function _sig(bytes32 signalId) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Signal),
            sourceId: SOURCE,
            signalId: signalId,
            arity: 0,
            delaySeconds: 0
        });
    }

    function _not() private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Not),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: 0
        });
    }

    function _and(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.And),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _or(uint16 arity) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Or),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: arity,
            delaySeconds: 0
        });
    }

    function _delay(uint64 delaySeconds) private pure returns (UVPStateMachine.Instruction memory) {
        return UVPStateMachine.Instruction({
            op: uint8(UVPStateMachine.InstructionOp.Delay),
            sourceId: bytes32(0),
            signalId: bytes32(0),
            arity: 0,
            delaySeconds: delaySeconds
        });
    }

    function _deps(bytes32 a) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](1);
        deps[0] = keccak256(abi.encode(SOURCE, a));
    }

    function _deps(bytes32 a, bytes32 b) private pure returns (bytes32[] memory deps) {
        deps = new bytes32[](2);
        deps[0] = keccak256(abi.encode(SOURCE, a));
        deps[1] = keccak256(abi.encode(SOURCE, b));
    }

    function _packedSignature(uint8 v, bytes32 r, bytes32 s) private pure returns (bytes memory) {
        UVPSignatures.Signature memory signature = UVPSignatures.Signature({v: v, r: r, s: s});
        return abi.encodePacked(signature.r, signature.s, signature.v);
    }

    function _noAttribution() private pure returns (UVPStateMachine.FactAttribution memory) {
        return UVPStateMachine.FactAttribution({
            sourceId: bytes32(0), signalId: bytes32(0), stageId: bytes32(0), capabilityProof: new bytes32[](0)
        });
    }
}
