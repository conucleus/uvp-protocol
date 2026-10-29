// Plan registration and outside-trigger birth calldata builders: the two-step
// commitPlan/finalizePlan encoding, the PlanCommit digest, and the
// triggerOrderFromOutsideFor calldata are protocol-bindings' own contract.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { decodeFunctionData, type Hex } from "viem";
import {
  PLAN_COMMIT_PRIMARY_TYPE,
  STATE_MACHINE_ABI,
  buildPlanCommitCall,
  buildPlanCommitTypedDataFor,
  buildPlanFinalizeCall,
  buildTriggerOrderFromOutsideForCall,
  buildTriggerOrderFromOutsideTypedData,
  type PlanRegistrationArgs,
} from "../src/index.js";

const STATE_MACHINE = "0x0000000000000000000000000000000000000001" as const;
const PUBLISHER = "0x0000000000000000000000000000000000000002" as const;
const SIGNATURE = `0x${"11".repeat(65)}` as Hex;

function bytes32(suffix: string): Hex {
  return `0x${suffix.padStart(64, "0")}` as Hex;
}

const registration: PlanRegistrationArgs = {
  planId: bytes32("01"),
  planHash: bytes32("02"),
  hooksHash: bytes32("03"),
  capabilitiesRoot: bytes32("04"),
  dockRoutesRoot: bytes32("05"),
  dockInterfaceRoot: bytes32("06"),
  executorCandidatesRoot: bytes32("07"),
  hooks: [{
    hookId: bytes32("0a"),
    stageId: bytes32("0b"),
    hookName: bytes32("0c"),
    flags: 5,
    instructions: [
      { op: "SIGNAL", sourceId: bytes32("0d"), signalId: bytes32("0e") },
      { op: "AND", arity: 2 },
      { op: "DELAY", delaySeconds: 5 },
    ],
    dependencyKeys: [bytes32("0f")],
  }],
  executorCandidates: [{ stageId: bytes32("10"), executor: PUBLISHER }],
};

describe("plan registration builders", () => {
  it("encodes commitPlan with numeric instruction opcodes and the publisher commitment", () => {
    const call = buildPlanCommitCall(
      { stateMachineAddress: STATE_MACHINE, chainId: 31337 },
      {
        publisher: PUBLISHER,
        deadline: 1_700_000_000n,
        registration,
        signature: SIGNATURE,
      },
    );

    assert.equal(call.address, STATE_MACHINE);
    assert.equal(call.functionName, "commitPlan");
    assert.equal(call.chainId, 31337);
    const decoded = decodeFunctionData({ abi: STATE_MACHINE_ABI, data: call.data });
    assert.equal(decoded.functionName, "commitPlan");
    assert.ok(decoded.args);
    const [commit, hooks, candidates, signature] = decoded.args as readonly [
      { readonly publisher: string; readonly deadline: bigint; readonly hooksHash: string; readonly birthAuthorizer: string },
      readonly { readonly instructions: readonly { readonly op: number }[] }[],
      readonly { readonly executor: string }[],
      string,
    ];
    assert.equal(commit.publisher, PUBLISHER);
    assert.equal(commit.deadline, 1_700_000_000n);
    assert.equal(commit.hooksHash, registration.hooksHash);
    assert.equal(commit.birthAuthorizer, PUBLISHER);
    assert.deepEqual(hooks[0]?.instructions.map((instruction) => instruction.op), [0, 2, 4]);
    assert.equal(candidates[0]?.executor, PUBLISHER);
    assert.equal(signature, SIGNATURE);
  });

  it("derives the plan-commit digest from the same commitment fields", () => {
    const typedData = buildPlanCommitTypedDataFor(
      { stateMachineAddress: STATE_MACHINE, chainId: 31337 },
      { publisher: PUBLISHER, deadline: 1_700_000_000n, registration },
    );
    assert.equal(typedData.primaryType, PLAN_COMMIT_PRIMARY_TYPE);
    assert.deepEqual(typedData.domain, {
      name: "UVPStateMachine",
      version: "0.15",
      chainId: 31337,
      verifyingContract: STATE_MACHINE,
    });
    assert.equal(typedData.message.publisher, PUBLISHER);
    assert.equal(typedData.message.hooksHash, registration.hooksHash);
    assert.equal(typedData.message.capabilitiesRoot, registration.capabilitiesRoot);
    assert.equal(typedData.message.birthAuthorizer, PUBLISHER);
    assert.equal(typedData.message.deadline, "1700000000");
  });

  it("encodes finalizePlan for the already-derived planId", () => {
    const call = buildPlanFinalizeCall({ stateMachineAddress: STATE_MACHINE }, registration.planId);
    assert.equal(call.address, STATE_MACHINE);
    assert.equal(call.functionName, "finalizePlan");
    const decoded = decodeFunctionData({ abi: STATE_MACHINE_ABI, data: call.data });
    assert.equal(decoded.functionName, "finalizePlan");
    assert.ok(decoded.args);
    assert.equal(decoded.args[0], registration.planId);
  });

  it("builds order birth calldata through the triggerOrderFromOutsideFor surface", () => {
    const trigger = {
      planId: registration.planId,
      creator: PUBLISHER,
      triggerHookId: bytes32("11"),
      triggerStageId: bytes32("12"),
      sourceId: bytes32("13"),
      signalId: bytes32("14"),
      payloadHash: bytes32("15"),
      idempotencyKey: bytes32("16"),
      submitter: PUBLISHER,
      deadline: 1_700_000_000n,
    };
    const authorizations = [{
      sourceId: bytes32("17"),
      signalId: bytes32("18"),
      submitter: PUBLISHER,
      role: bytes32("00"),
      metadataHash: bytes32("00"),
    }];
    const birthFactAttribution = {
      sourceId: bytes32("13"),
      signalId: bytes32("14"),
      stageId: bytes32("00"),
      capabilityProof: [],
    };
    const typedData = buildTriggerOrderFromOutsideTypedData({
      ...trigger,
      chainId: 31337,
      verifyingContract: STATE_MACHINE,
      authorizations,
    });
    assert.equal(typedData.primaryType, "UVPStateMachineTriggerOrderFromOutside");

    const call = buildTriggerOrderFromOutsideForCall(
      { stateMachineAddress: STATE_MACHINE, chainId: 31337 },
      { ...trigger, authorizations, signature: SIGNATURE, birthFactAttribution },
    );
    const decoded = decodeFunctionData({ abi: STATE_MACHINE_ABI, data: call.data });
    assert.equal(decoded.functionName, "triggerOrderFromOutsideFor");
    assert.ok(decoded.args);
    assert.equal(decoded.args[2], SIGNATURE);
    assert.equal((decoded.args[0] as { readonly planId: string }).planId, registration.planId);
  });
});
