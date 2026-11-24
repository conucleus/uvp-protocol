// Plan registration calldata builders: the two-step commitPlan/finalizePlan
// encoding and the PlanCommit digest are protocol-bindings' own contract.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { decodeFunctionData, type Hex } from "viem";
import { capabilityTablesOf, type DockArtifact } from "@uvp-eth/compiler/browser";
import {
  DOCK_REGISTRY_ABI,
  PLAN_COMMIT_PRIMARY_TYPE,
  STATE_MACHINE_ABI,
  buildPlanCommitCall,
  buildPlanCommitTypedDataFor,
  buildPlanFinalizeCall,
  buildRegisterDockCallFromArtifact,
  capabilitiesRootOf,
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
  supplierBindingsRoot: bytes32("07"),
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
  supplierBindings: [
    { stageId: bytes32("10"), supplierId: bytes32("11"), kind: 0 },
    { stageId: bytes32("10"), supplierId: bytes32("12"), kind: 1 },
  ],
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
    const [commit, hooks, bindings, signature] = decoded.args as readonly [
      {
        readonly publisher: string;
        readonly deadline: bigint;
        readonly hooksHash: string;
        readonly supplierBindingsRoot: string;
      },
      readonly { readonly instructions: readonly { readonly op: number }[] }[],
      readonly { readonly supplierId: string; readonly kind: number }[],
      string,
    ];
    assert.equal(commit.publisher, PUBLISHER);
    assert.equal(commit.deadline, 1_700_000_000n);
    assert.equal(commit.hooksHash, registration.hooksHash);
    assert.equal(commit.supplierBindingsRoot, registration.supplierBindingsRoot);
    assert.deepEqual(hooks[0]?.instructions.map((instruction) => instruction.op), [0, 2, 4]);
    assert.deepEqual(
      bindings.map((binding) => [binding.supplierId, binding.kind]),
      [
        [registration.supplierBindings[0]!.supplierId, 0],
        [registration.supplierBindings[1]!.supplierId, 1],
      ],
    );
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
      version: "1",
      chainId: 31337,
      verifyingContract: STATE_MACHINE,
    });
    assert.equal(typedData.message.publisher, PUBLISHER);
    assert.equal(typedData.message.hooksHash, registration.hooksHash);
    assert.equal(typedData.message.capabilitiesRoot, registration.capabilitiesRoot);
    assert.equal(
      typedData.message.supplierBindingsRoot,
      registration.supplierBindingsRoot,
    );
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
});

describe("dock registration capability tables", () => {
  const fromSourceId = bytes32("31");
  const toSourceId = bytes32("32");
  const toStageId = bytes32("33");
  const atomStageId = bytes32("34");
  const atomSignalId = bytes32("35");
  const outputSignalId = bytes32("36");

  const artifact = {
    selectorBindings: [{ selectorStageId: atomStageId, targetStageId: toStageId }],
    signalCapabilities: [
      {
        stageId: atomStageId,
        targetSourceId: fromSourceId,
        signalId: atomSignalId,
        targetOrderRelation: 0 as const,
      },
      {
        stageId: toStageId,
        targetSourceId: toSourceId,
        signalId: outputSignalId,
        targetOrderRelation: 0 as const,
      },
    ],
  } as unknown as Parameters<typeof capabilityTablesOf>[0];

  const dockArtifact: DockArtifact = {
    schemaVersion: "uvp.dock.v1",
    dkid: "zd-00000000000000000000000000000000",
    docHash: bytes32("40"),
    from: { zhixu: "zx-from", source: "seller", sourceId: fromSourceId },
    to: {
      zhixu: "zx-to",
      source: "buyer",
      stage: "main",
      stageId: toStageId,
      sourceId: toSourceId,
    },
    signalMap: [{
      signal: "delivered",
      signalId: outputSignalId,
      sourceId: toSourceId,
      stageId: toStageId,
      targetOrderRelation: 0,
      rawExpression: "deliver.shipped",
      ast: {
        raw: "deliver.shipped",
        source: "seller",
        condition: { kind: "signal", signalName: "deliver.shipped" },
      },
      dependencies: [{ kind: "positive", source: "seller", signalName: "deliver.shipped" }],
      atoms: [{
        zhixu: "zx-from",
        source: "seller",
        sourceId: fromSourceId,
        stage: "deliver",
        stageId: atomStageId,
        signal: "shipped",
        signalId: atomSignalId,
        targetOrderRelation: 0,
      }],
    }],
  };

  it("derives dock proofs from compiler capability tables without renaming fields", () => {
    const tables = capabilityTablesOf(artifact);
    const root = capabilitiesRootOf(tables.selectorBindings, tables.signalCapabilities);
    assert.match(root, /^0x[0-9a-f]{64}$/);

    const call = buildRegisterDockCallFromArtifact(
      { dockRegistryAddress: STATE_MACHINE, chainId: 31337 },
      {
        artifact: dockArtifact,
        fromPlanId: bytes32("50"),
        toPlanId: bytes32("51"),
        fromCapabilityTables: tables,
        toCapabilityTables: tables,
      },
    );
    assert.equal(call.functionName, "registerDock");
    const decoded = decodeFunctionData({ abi: DOCK_REGISTRY_ABI, data: call.data });
    const outputs = (decoded.args as readonly unknown[])[6] as readonly {
      readonly atoms: readonly { readonly capabilityProof: readonly string[] }[];
      readonly capabilityProof: readonly string[];
    }[];
    assert.equal(outputs.length, 1);
    assert.ok((outputs[0]?.atoms[0]?.capabilityProof.length ?? 0) > 0);
    assert.ok((outputs[0]?.capabilityProof.length ?? 0) > 0);

    const relationTables = {
      selectorBindings: tables.selectorBindings,
      signalCapabilities: tables.signalCapabilities.map((capability) => ({
        stageId: capability.stageId,
        targetSourceId: capability.targetSourceId,
        signalId: capability.signalId,
        relation: 0 as const,
      })),
    };
    assert.equal(
      capabilitiesRootOf(relationTables.selectorBindings, relationTables.signalCapabilities),
      root,
    );
    assert.equal(
      buildRegisterDockCallFromArtifact(
        { dockRegistryAddress: STATE_MACHINE, chainId: 31337 },
        {
          artifact: dockArtifact,
          fromPlanId: bytes32("50"),
          toPlanId: bytes32("51"),
          fromCapabilityTables: relationTables,
          toCapabilityTables: relationTables,
        },
      ).data,
      call.data,
    );
  });
});
