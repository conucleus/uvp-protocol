import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  EMPTY_MERKLE_ROOT,
  executorCandidateLeaf,
  executorCandidatesRootOf,
  validateOnchainHookPlanArtifact,
  type ZhixuDefinition,
} from "../src/index.js";
import { compileOnchainHookPlan } from "../src/onchain/compile.js";
import { HookPlanCompilationError } from "../src/index.js";

const STAGE_A = "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11" as `0x${string}`;
const WALLET_A = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266" as `0x${string}`;
const WALLET_A_CHECKSUMMED = "0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;
const WALLET_B = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as `0x${string}`;

test("executor candidate leaf matches the cast-pinned contract formula", () => {
  assert.equal(
    executorCandidateLeaf(
      "0x" + "11".repeat(32) as `0x${string}`,
      "0x" + "ab".repeat(20) as `0x${string}`,
    ),
    "0x5b22efbfe1045235509160768b32e5c055af8335b1c9fdc2337a3f9b09921682",
  );
  assert.equal(
    executorCandidateLeaf(STAGE_A, WALLET_A),
    "0x20f60f793488a664cf5a4c1215c1e6fc9628e783d7e060297b669d4c93f48c95",
  );
  assert.equal(
    executorCandidateLeaf(STAGE_A, WALLET_A_CHECKSUMMED),
    executorCandidateLeaf(STAGE_A, WALLET_A),
  );
});

test("empty candidate set roots to EMPTY_MERKLE_ROOT", () => {
  assert.equal(executorCandidatesRootOf([]), EMPTY_MERKLE_ROOT);
});

const candidateZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "candidate_face_demo" },
  spec: {
    platform: { type: "blockchain", provider: "eth" },
    nucleation: { id: "core_org" },
    stages: [
      {
        name: "main",
        source: "slot_a",
        receiveSignals: {
          START: "slot_a::main.kickoff",
        },
        sendSignals: [
          { name: "str" },
          { name: "cmp" },
          { name: "kickoff" },
        ],
        executor: {
          supplierType: "organization",
          supplierID: "patchable-org",
        },
      },
    ],
  },
};

const birthZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "candidate_birth_demo" },
  spec: {
    platform: { type: "blockchain", provider: "eth" },
    nucleation: { id: "core_org" },
    stages: [
      {
        name: "main",
        source: "slot_a",
        mint: "per-fact",
        receiveSignals: {
          ON_DEAL: "::ANCHOR(@trading::deal.closed)",
        },
        sendSignals: [{ name: "str" }, { name: "cmp" }],
        executor: { supplierType: "organization", supplierID: "birth-org" },
      },
      {
        name: "deal",
        source: "trading",
        receiveSignals: { PLACE: "trading::deal.kickoff" },
        sendSignals: [{ name: "closed" }, { name: "kickoff" }],
        executor: { supplierType: "organization", supplierID: "trading-org" },
      },
    ],
  },
};

test("compile attaches normalized candidates and shifts the artifact commitment", () => {
  const bare = compileZhixuOnchainHookPlan(candidateZhixu);
  assert.deepEqual(bare.executorCandidates, []);
  assert.equal(bare.executorCandidatesRoot, EMPTY_MERKLE_ROOT);

  const withCandidates = compileZhixuOnchainHookPlan(candidateZhixu, undefined, [
    { stageIdentifier: "main", executor: WALLET_B },
    { stageIdentifier: "main", executor: WALLET_A },
    { stageIdentifier: "main", executor: WALLET_A_CHECKSUMMED },
  ]);
  assert.deepEqual(
    withCandidates.executorCandidates.map((candidate) => candidate.executor),
    [WALLET_B, WALLET_A],
  );
  assert.equal(
    withCandidates.executorCandidatesRoot,
    executorCandidatesRootOf([
      { stageId: bare.compiledHooks[0]!.stageId, executor: WALLET_A },
      { stageId: bare.compiledHooks[0]!.stageId, executor: WALLET_B },
    ]),
  );
  assert.notEqual(withCandidates.planHash, bare.planHash);
  assert.deepEqual(validateOnchainHookPlanArtifact(withCandidates), []);
});

test("compile rejects candidates for undeclared stages, birth stages, and bad addresses", () => {
  const ir = compileZhixuHookPlan(candidateZhixu);
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(candidateZhixu, undefined, [
        { stageIdentifier: "no_such_task.stage", executor: WALLET_A },
      ]),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => issue.includes("not a stage declared in this plan")),
  );
  assert.throws(
    () =>
      compileOnchainHookPlan(ir, [
        { stageIdentifier: "main", executor: "0x1234" },
      ]),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => issue.includes("non-zero 20-byte address")),
  );
  const birthIr = compileZhixuHookPlan(birthZhixu);
  assert.throws(
    () =>
      compileOnchainHookPlan(birthIr, [
        { stageIdentifier: "main", executor: WALLET_A },
      ]),
    (error: unknown) =>
      error instanceof HookPlanCompilationError &&
      error.issues.some((issue) => issue.includes("birth-stage executors are immutable")),
  );
  const birthWithCandidates = compileOnchainHookPlan(birthIr, [
    { stageIdentifier: "deal", executor: WALLET_A },
  ]);
  assert.equal(birthWithCandidates.executorCandidates.length, 1);
});

test("artifact boundary rejects a tampered candidates root", () => {
  const withCandidates = compileZhixuOnchainHookPlan(candidateZhixu, undefined, [
    { stageIdentifier: "main", executor: WALLET_A },
  ]);
  const tampered = {
    ...withCandidates,
    executorCandidatesRoot: "0x" + "77".repeat(32),
  };
  const { planHash: _ignored, ...payload } = tampered;
  assert.ok(
    validateOnchainHookPlanArtifact(payload).some((issue) =>
      issue.includes("executorCandidatesRoot must match the recomputed root"),
    ),
  );
});
