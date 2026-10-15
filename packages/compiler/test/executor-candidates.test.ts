import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  EMPTY_MERKLE_ROOT,
  executorCandidateLeaf,
  executorCandidateProof,
  executorCandidatesRootOf,
  validateOnchainHookPlanArtifact,
  verifyMerkleProof,
  type ZhixuDefinition,
} from "../src/index.js";
import { compileOnchainHookPlan } from "../src/onchain/compile.js";
import { HookPlanCompilationError } from "../src/index.js";

/**
 * 执行者候选集面（UB-36②③）的编译接线与承诺公式测试：
 * - 叶公式与合约 UVPPlanRegistration._executorCandidatesRoot 逐字节一致
 *   （cast keccak 对拍向量钉死：preimage = keccak(domain)‖stageId‖20B 地址，
 *   共 84 字节紧凑形态）；
 * - 建树沿用 DockMerkle 排序去重口径（空集 = EMPTY_MERKLE_ROOT）；
 * - 编译入口三道门：阶段须声明、出生 trigger 阶段拒绝、地址合法非零；
 * - 制品承诺：候选集进 planHash，root 不一致在反序列化边界响亮拒绝。
 */

const STAGE_A = "0x1845455a34645910fcbc7220c18dcb6661ad3f045893d3694d22a99a1a5dcc11" as `0x${string}`;
const WALLET_A = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266" as `0x${string}`;
const WALLET_A_CHECKSUMMED = "0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;
const WALLET_B = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as `0x${string}`;

test("executor candidate leaf matches the cast-pinned contract formula", () => {
  // cast keccak：域字 keccak256("UVP_EXECUTOR_CANDIDATE_V1") = 0x8d55c5a3…
  // 两向量均以 84 字节 encodePacked preimage 独立计算。
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
  // 地址大小写不敏感（叶内归一小写；EIP-55 checksummed 形态同叶），
  // 与链上地址语义一致。
  assert.equal(
    executorCandidateLeaf(STAGE_A, WALLET_A_CHECKSUMMED),
    executorCandidateLeaf(STAGE_A, WALLET_A),
  );
});

test("empty candidate set roots to EMPTY_MERKLE_ROOT", () => {
  assert.equal(executorCandidatesRootOf([]), EMPTY_MERKLE_ROOT);
});

test("candidate proofs verify against the committed root", () => {
  const candidates = [
    { stageId: STAGE_A, executor: WALLET_A },
    { stageId: STAGE_A, executor: WALLET_B },
    { stageId: "0x" + "22".repeat(32) as `0x${string}`, executor: WALLET_A },
  ];
  const root = executorCandidatesRootOf(candidates);
  const proof = executorCandidateProof(candidates, STAGE_A, WALLET_B);
  assert.ok(proof);
  assert.ok(
    verifyMerkleProof(
      root,
      executorCandidateLeaf(STAGE_A, WALLET_B),
      proof,
    ),
  );
  // 不在集内的组合无证明（fail-closed）。
  assert.equal(executorCandidateProof(candidates, STAGE_A, ("0x" + "cc".repeat(20)) as `0x${string}`), undefined);
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
        source: "buyer",
        receiveSignals: {
          START: "buyer::main.kickoff",
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
        source: "buyer",
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
    // EIP-55 checksummed 形态 + 同条目重复：归一去重后单条。
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
  // 候选集进制品承诺：同一定义带/不带候选集必须分叉 planHash。
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
  // 出生 trigger 阶段（mint）的执行者终生不可变，不可为逐单 patch 候选。
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
  // 非出生阶段（market.deal）在出生定义下合法入集。
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
