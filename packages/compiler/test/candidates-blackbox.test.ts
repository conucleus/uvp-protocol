import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
  HookPlanCompilationError,
  EMPTY_MERKLE_ROOT,
  executorCandidatesRootOf,
  keccak256Hex,
  OnchainHookPlanArtifactValidationError,
  toSolidityRegisterPlanArgs,
  validateOnchainHookPlanArtifact,
  type ExecutorCandidateInput,
  type OnchainExecutorCandidate,
  type OnchainHookPlanArtifact,
  type ZhixuDefinition,
} from "../src/index.js";
import { compileOnchainHookPlan } from "../src/onchain/compile.js";
import { hashOnchainPlanPayload } from "../src/onchain/hash/plan.js";
import {
  encodeAbiParameters,
  keccak256,
  parseAbiParameters,
  stringToHex,
} from "viem";

/**
 * 执行者候选集黑盒对抗测试：只依据行为规格（候选集承诺面）自由探索，
 * 不重复 executor-candidates.test.ts 已钉住的断言（叶公式金标、空集根、
 * proof 往返、编译三道门的正例、篡改 root 的基础形态）。覆盖面：
 * - 编译入口门：零地址 / 39·41 位 / 非十六进制 / 缺 0x 前缀 / 非字符串；
 * - 归一化：大小写单条、混合大小写重复去重、输入顺序无关、跨阶段同地址；
 * - planHash 敏感性：改一字节 / 加一条 / 删一条 / 换序（根的规范序语义
 *   与制品 payload 的顺序敏感性分开钉）；
 * - runtime 六域哈希：独立重算、任一域分叉、domain 串 v3 分叉；
 * - calldata 形态：executorCandidates 只含 {stageId, executor} 且规范序；
 * - 反序列化边界：未知顶层字段、缺 executorCandidates（不重算 planHash）、
 *   非数组、条目畸形（stageId/executor 形态）、乱序（重签后仍拒）、
 *   重签后的 root 篡改、出生阶段不可变门的制品边界镜像。
 */

const WALLET_A = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266" as `0x${string}`;
const WALLET_A_EIP55 = "0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;
const WALLET_B = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as `0x${string}`;
const WALLET_C = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc" as `0x${string}`;

/** 双阶段 fixture：main 与 deal 均为非出生阶段（拍平形态，单段命名）。 */
const twoStageZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "candidates_blackbox" },
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
        sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "kickoff" }],
        executor: {
          supplierType: "organization",
          supplierID: "patchable-org",
        },
      },
      {
        name: "deal",
        source: "trading",
        receiveSignals: {
          PLACE: "trading::deal.kickoff",
        },
        sendSignals: [{ name: "closed" }, { name: "kickoff" }],
        executor: {
          supplierType: "organization",
          supplierID: "trading-org",
        },
      },
    ],
  },
};

/** 出生（order-trigger）阶段 fixture：main 带 mint 出生边。 */
const birthZhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "candidates_blackbox_birth" },
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

/** 篡改制品载荷后按生产公式重签 planHash（让拦截者聚焦被测门本身）。 */
function repin(artifact: OnchainHookPlanArtifact): OnchainHookPlanArtifact {
  const { planHash: _stale, ...payload } = artifact;
  return { ...payload, planHash: hashOnchainPlanPayload(payload) };
}

function isGateRejection(error: unknown, message: string): boolean {
  return (
    error instanceof HookPlanCompilationError &&
    error.issues.some((issue) => issue.includes(message))
  );
}

/** 六域 runtime preimage 的独立实现（与规格公式逐字对应）。 */
function runtimePlanHash(
  domain: string,
  hooksHash: string,
  capabilitiesRoot: string,
  dockRoutesRoot: string,
  dockInterfaceRoot: string,
  executorCandidatesRoot: string,
): string {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "bytes32 domain, bytes32 hooksHash, bytes32 capabilitiesRoot, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot, bytes32 executorCandidatesRoot",
      ),
      [
        keccak256(stringToHex(domain)),
        hooksHash as `0x${string}`,
        capabilitiesRoot as `0x${string}`,
        dockRoutesRoot as `0x${string}`,
        dockInterfaceRoot as `0x${string}`,
        executorCandidatesRoot as `0x${string}`,
      ],
    ),
  );
}

function candidateWith(
  stageIdentifier: string,
  executor: `0x${string}`,
): ExecutorCandidateInput {
  return { stageIdentifier, executor };
}

// ---------------------------------------------------------------------------
// 编译入口门（规格 3）：地址形态
// ---------------------------------------------------------------------------

test("compile gate: zero address candidate is rejected", () => {
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
        candidateWith("main", ("0x" + "0".repeat(40)) as `0x${string}`),
      ]),
    (error: unknown) => isGateRejection(error, "non-zero 20-byte address"),
  );
});

test("compile gate: malformed address shapes are rejected (39/41 hex, non-hex, no 0x)", () => {
  const malformed = [
    "0x" + "a".repeat(39), // 39 位：不足 20 字节
    "0x" + "a".repeat(41), // 41 位：超出 20 字节
    "0x" + "g".repeat(40), // 非十六进制字符
    "f39fd6e51aad88f6f4ce6ab8827279cfffb92266", // 缺 0x 前缀
  ];
  for (const executor of malformed) {
    assert.throws(
      () =>
        compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
          candidateWith(
            "main",
            executor as unknown as `0x${string}`,
          ),
        ]),
      (error: unknown) =>
        isGateRejection(error, "must be a non-zero 20-byte address"),
      `executor ${JSON.stringify(executor)} must be rejected`,
    );
  }
});

// ---------------------------------------------------------------------------
// 归一化（规格 5）
// ---------------------------------------------------------------------------

test("compile normalizes a checksummed address into the canonical lowercase form", () => {
  const checksummed = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A_EIP55),
  ]);
  const lowercase = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
  ]);
  assert.equal(checksummed.executorCandidates[0]?.executor, WALLET_A);
  // 大小写只是拼写差：整份制品必须逐字节一致（不是"近似"）。
  assert.deepEqual(checksummed, lowercase);
});

test("compile dedupes case-variant duplicate entries into the single canonical artifact", () => {
  const duplicated = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("main", WALLET_A_EIP55),
  ]);
  const single = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
  ]);
  assert.equal(duplicated.executorCandidates.length, 1);
  assert.deepEqual(duplicated, single);
});

test("candidate input order never leaks into the artifact", () => {
  const forward = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("main", WALLET_B),
    candidateWith("deal", WALLET_C),
  ]);
  const backward = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("deal", WALLET_C),
    candidateWith("main", WALLET_B),
    candidateWith("main", WALLET_A),
  ]);
  assert.deepEqual(backward, forward);
  // 规范序：stageId 字节序在外，executor 字节序在内。
  const order = forward.executorCandidates.map(
    (candidate) => `${candidate.stageId}:${candidate.executor}`,
  );
  assert.deepEqual(order, [...order].sort());
});

test("the same executor across two stages yields one entry per stage", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("deal", WALLET_A),
  ]);
  assert.equal(artifact.executorCandidates.length, 2);
  assert.deepEqual(
    new Set(artifact.executorCandidates.map((c) => c.stageId)).size,
    2,
  );
  assert.equal(
    artifact.executorCandidatesRoot,
    executorCandidatesRootOf([
      { stageId: keccak256Hex("main"), executor: WALLET_A },
      { stageId: keccak256Hex("deal"), executor: WALLET_A },
    ]),
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(artifact), []);
});

// ---------------------------------------------------------------------------
// planHash 敏感性（规格 2/5）
// ---------------------------------------------------------------------------

test("planHash forks on any candidate-set mutation: one byte, add one, drop one", () => {
  const baseline = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("main", WALLET_B),
  ]);
  const flippedLast = (WALLET_A.slice(0, -1) +
    (WALLET_A.endsWith("6") ? "7" : "6")) as `0x${string}`;

  const oneByte = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", flippedLast),
    candidateWith("main", WALLET_B),
  ]);
  const added = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("main", WALLET_B),
    candidateWith("main", WALLET_C),
  ]);
  const dropped = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_B),
  ]);

  for (const [label, mutant] of [
    ["one-byte flip", oneByte],
    ["added entry", added],
    ["dropped entry", dropped],
  ] as const) {
    assert.notEqual(
      mutant.executorCandidatesRoot,
      baseline.executorCandidatesRoot,
      `${label} must fork the candidates root`,
    );
    assert.notEqual(mutant.planHash, baseline.planHash, `${label} must fork planHash`);
  }
});

test("candidates root is order-independent (merkle canonical form) while the artifact payload is order-sensitive", () => {
  const set = [
    { stageId: keccak256Hex("main"), executor: WALLET_A },
    { stageId: keccak256Hex("main"), executor: WALLET_B },
    { stageId: keccak256Hex("deal"), executor: WALLET_C },
  ];
  const forward = executorCandidatesRootOf(set);
  const shuffled = executorCandidatesRootOf([...set].reverse());
  // 规范序的意义：同一集合换序后"承诺根"不变（成员资格与顺序解耦），
  // 但制品数组是 planHash 的一部分，乱序即另一份 payload。
  assert.equal(shuffled, forward);

  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("main", WALLET_B),
    candidateWith("deal", WALLET_C),
  ]);
  const { planHash: _stale, ...payload } = artifact;
  const reorderedPayload = {
    ...payload,
    executorCandidates: [...artifact.executorCandidates].reverse(),
  };
  assert.notEqual(
    hashOnchainPlanPayload(reorderedPayload as never),
    artifact.planHash,
    "array reorder must fork the artifact payload hash (the boundary pins canonical order)",
  );
});

test("an explicitly empty candidate array compiles byte-identical to the omitted form", () => {
  const omitted = compileZhixuOnchainHookPlan(twoStageZhixu);
  const explicitEmpty = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, []);
  assert.deepEqual(explicitEmpty, omitted);
  assert.deepEqual(explicitEmpty.executorCandidates, []);
  assert.equal(explicitEmpty.executorCandidatesRoot, EMPTY_MERKLE_ROOT);
});

// ---------------------------------------------------------------------------
// runtime 六域哈希（规格 2）
// ---------------------------------------------------------------------------

test("runtime planHash recomputes from the six-domain preimage and forks on any single domain", () => {
  const args = toSolidityRegisterPlanArgs(
    compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
      candidateWith("main", WALLET_A),
      candidateWith("deal", WALLET_B),
    ]),
  );
  // 独立重算：v4 六域公式必须逐字节复现。
  assert.equal(
    args.planHash,
    runtimePlanHash(
      "uvp.plan.runtime.v4",
      args.hooksHash,
      args.capabilitiesRoot,
      args.dockRoutesRoot,
      args.dockInterfaceRoot,
      args.executorCandidatesRoot,
    ),
  );
  // domain 串版本分叉：v3 ≠ v4（域字进 preimage）。
  assert.notEqual(
    args.planHash,
    runtimePlanHash(
      "uvp.plan.runtime.v3",
      args.hooksHash,
      args.capabilitiesRoot,
      args.dockRoutesRoot,
      args.dockInterfaceRoot,
      args.executorCandidatesRoot,
    ),
  );
  // 任一域变动必须分叉 runtime planHash。
  const domains = [
    args.hooksHash,
    args.capabilitiesRoot,
    args.dockRoutesRoot,
    args.dockInterfaceRoot,
    args.executorCandidatesRoot,
  ];
  const mutated = domains.map((value, index) =>
    domains.map((slot, position) =>
      position === index ? keccak256Hex(`mutated-domain-${index}`) : slot,
    ),
  );
  for (const [index, slots] of mutated.entries()) {
    assert.notEqual(
      args.planHash,
      runtimePlanHash(
        "uvp.plan.runtime.v4",
        slots[0]!,
        slots[1]!,
        slots[2]!,
        slots[3]!,
        slots[4]!,
      ),
      `mutating domain slot ${index} must fork the runtime planHash`,
    );
  }
  // domain 串本身变动同样分叉。
  assert.notEqual(
    args.planHash,
    runtimePlanHash(
      "uvp.plan.runtime.v4-mutated",
      domains[0]!,
      domains[1]!,
      domains[2]!,
      domains[3]!,
      domains[4]!,
    ),
  );
});

// ---------------------------------------------------------------------------
// calldata 形态（规格 2）
// ---------------------------------------------------------------------------

test("register args carry candidates as bare {stageId, executor} pairs in canonical order", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("deal", WALLET_A),
    candidateWith("main", WALLET_B),
  ]);
  const args = toSolidityRegisterPlanArgs(artifact);
  // calldata 条目只含链上面两个槽（stageIdentifier 是制品侧标注，不得进
  // commitPlan 第三入参）。
  assert.deepEqual(args.executorCandidates, [
    { stageId: artifact.executorCandidates[0]?.stageId, executor: artifact.executorCandidates[0]?.executor },
    { stageId: artifact.executorCandidates[1]?.stageId, executor: artifact.executorCandidates[1]?.executor },
  ]);
  for (const candidate of args.executorCandidates) {
    assert.equal(Object.keys(candidate).length, 2);
    assert.match(candidate.executor, /^0x[0-9a-f]{40}$/);
    assert.match(candidate.stageId, /^0x[0-9a-f]{64}$/);
  }
  // 制品承诺、重算根、calldata 清单三方一致。
  assert.equal(
    args.executorCandidatesRoot,
    artifact.executorCandidatesRoot,
  );
  assert.equal(
    args.executorCandidatesRoot,
    executorCandidatesRootOf(args.executorCandidates),
  );
});

test("compileZhixuRegisterPlanArgs threads candidates end-to-end from the definition", () => {
  const candidates = [
    candidateWith("main", WALLET_A),
    candidateWith("deal", WALLET_B),
  ];
  const args = compileZhixuRegisterPlanArgs(twoStageZhixu, undefined, candidates);
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, candidates);
  assert.deepEqual(
    args.executorCandidates,
    artifact.executorCandidates.map((candidate) => ({
      stageId: candidate.stageId,
      executor: candidate.executor,
    })),
  );
  assert.equal(args.artifactHash, artifact.planHash);
  // 同一定义带/不带候选集：runtime planHash 必须分叉（候选集树根随
  // PlanCommit 签名进链）。
  const bareArgs = compileZhixuRegisterPlanArgs(twoStageZhixu);
  assert.equal(bareArgs.executorCandidates.length, 0);
  assert.equal(bareArgs.executorCandidatesRoot, EMPTY_MERKLE_ROOT);
  assert.notEqual(args.planHash, bareArgs.planHash);
});

// ---------------------------------------------------------------------------
// 反序列化边界（规格 4）
// ---------------------------------------------------------------------------

test("artifact boundary rejects unknown top-level fields", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
  ]);
  const issues = validateOnchainHookPlanArtifact({
    ...artifact,
    smuggled: "not covered by planHash",
  });
  assert.ok(
    issues.some((issue) => issue.includes("unknown field `smuggled`")),
    `expected unknown-field issue, got: ${issues.join("; ")}`,
  );
});

test("artifact boundary: a missing executorCandidates array is an explicit issue and must not recompute planHash", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
  ]);
  const { executorCandidates: _removed, ...stripped } = artifact;
  const issues = validateOnchainHookPlanArtifact(stripped);
  assert.ok(
    issues.includes("executorCandidates must be an array"),
    `expected missing-array issue, got: ${issues.join("; ")}`,
  );
  // fail-open 镜像：缺失字段折成空集后哈希照常通过是禁止形态——planHash
  // 不得在字段缺失时被重算对拍。
  assert.ok(
    !issues.includes("planHash must match the canonical on-chain HookPlan payload"),
    "planHash must not be recomputed while executorCandidates is missing",
  );
});

test("artifact boundary rejects non-array executorCandidates", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
  ]);
  for (const bogus of [null, { stageId: keccak256Hex("x") }, "[]", 7]) {
    const issues = validateOnchainHookPlanArtifact({
      ...artifact,
      executorCandidates: bogus,
    });
    assert.ok(
      issues.includes("executorCandidates must be an array"),
      `expected must-be-array issue for ${JSON.stringify(bogus)}, got: ${issues.join("; ")}`,
    );
  }
});

test("artifact boundary rejects malformed candidate entries (stageId / executor shapes)", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("main", WALLET_B),
  ]);
  const malformedCandidates: readonly unknown[][] = [
    // executor 少一位（39 位十六进制）。
    [
      { stageId: artifact.executorCandidates[0]?.stageId, executor: "0x" + "a".repeat(39) },
      artifact.executorCandidates[1],
    ],
    // executor 全零（20 字节零地址）。
    [
      { stageId: artifact.executorCandidates[0]?.stageId, executor: "0x" + "0".repeat(40) },
      artifact.executorCandidates[1],
    ],
    // stageId 非小写 32 字节词（大写十六进制）。
    [
      { stageId: (artifact.executorCandidates[0]?.stageId ?? "").toUpperCase().replace("0X", "0x"), executor: WALLET_A },
      artifact.executorCandidates[1],
    ],
    // stageId 31 字节（62 位）。
    [{ stageId: "0x" + "a".repeat(62), executor: WALLET_A }, artifact.executorCandidates[1]],
    // stageId 缺失。
    [{ executor: WALLET_A }, artifact.executorCandidates[1]],
  ];
  for (const candidates of malformedCandidates) {
    const issues = validateOnchainHookPlanArtifact({
      ...artifact,
      executorCandidates: candidates,
    });
    assert.ok(
      issues.some((issue) =>
        issue.includes(
          "must carry a 32-byte stageId and a non-zero 20-byte executor address",
        ),
      ),
      `expected entry shape issue for ${JSON.stringify(candidates[0])}, got: ${issues.join("; ")}`,
    );
  }
  // 登记边界同样响亮拒绝（不得静默带病进 commitPlan calldata）。
  assert.throws(
    () =>
      toSolidityRegisterPlanArgs({
        ...artifact,
        executorCandidates: [{ executor: WALLET_A }, artifact.executorCandidates[1]!],
      } as unknown as OnchainHookPlanArtifact),
    OnchainHookPlanArtifactValidationError,
  );
});

test("artifact boundary rejects out-of-canonical-order candidates even after re-pinning planHash", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
    candidateWith("main", WALLET_B),
    candidateWith("deal", WALLET_C),
  ]);
  const reordered = repin({
    ...artifact,
    executorCandidates: [...artifact.executorCandidates].reverse(),
    // root 不变（merkle 规范序换序不变），只有数组序与 planHash 变。
  } as OnchainHookPlanArtifact);
  const issues = validateOnchainHookPlanArtifact(reordered);
  assert.ok(
    issues.some((issue) => /executorCandidates\[1\] breaks the canonical order/.test(issue)),
    `expected canonical-order issue, got: ${issues.join("; ")}`,
  );
  // 登记边界拒绝乱序清单：不得静默重排成规范序后放行。
  assert.throws(
    () => toSolidityRegisterPlanArgs(reordered),
    (error: unknown) =>
      error instanceof OnchainHookPlanArtifactValidationError &&
      error.issues.some((issue) => /breaks the canonical order/.test(issue)),
  );
});

test("artifact boundary rejects a re-pinned artifact whose candidates root was tampered", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
  ]);
  const tampered = repin({
    ...artifact,
    executorCandidatesRoot: "0x" + "77".repeat(32),
  } as OnchainHookPlanArtifact);
  const issues = validateOnchainHookPlanArtifact(tampered);
  assert.ok(
    issues.includes(
      "executorCandidatesRoot must match the recomputed root over the candidate leaves",
    ),
    `expected root mismatch issue, got: ${issues.join("; ")}`,
  );
  assert.throws(() => toSolidityRegisterPlanArgs(tampered), /executorCandidatesRoot must match/);
});

test("artifact boundary mirrors the birth-stage immutability gate", () => {
  const base = compileZhixuOnchainHookPlan(birthZhixu, undefined, [
    candidateWith("deal", WALLET_A),
  ]);
  assert.deepEqual(validateOnchainHookPlanArtifact(base), []);

  // 把候选条目重定向到出生阶段（root/planHash 同步重签，让拦截者聚焦
  // 出生门本身）：出生阶段执行者终生不可变，制品边界必须拒绝。
  const birthStageId = keccak256Hex("main");
  const retargeted = [
    { stageIdentifier: "main", stageId: birthStageId, executor: WALLET_A },
  ] satisfies OnchainExecutorCandidate[];
  const retargetedArtifact = repin({
    ...base,
    executorCandidates: retargeted,
    executorCandidatesRoot: executorCandidatesRootOf(retargeted),
  } as OnchainHookPlanArtifact);
  const issues = validateOnchainHookPlanArtifact(retargetedArtifact);
  assert.ok(
    issues.some((issue) => issue.includes("birth-stage executors are immutable")),
    `expected birth-stage issue, got: ${issues.join("; ")}`,
  );
});


test("non-string executor fails as a typed compilation issue, not a bare TypeError", () => {
  // D1 回归：归一化在 preflight 之后，畸形输入走类型化错误门。
  try {
    compileOnchainHookPlan(compileZhixuHookPlan(twoStageZhixu), [
      { stageIdentifier: "main", executor: 42 as unknown as `0x${string}` },
    ]);
    assert.fail("expected HookPlanCompilationError");
  } catch (error) {
    assert.ok(error instanceof HookPlanCompilationError);
    assert.ok(
      error.issues.some((issue) => issue.includes("non-zero 20-byte address")),
    );
  }
});

test("artifact boundary enforces the lowercase executor form in both directions", () => {
  // D2 回归：混合大小写条目显式拒绝（编译器恒产小写）。
  const withCandidates = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    { stageIdentifier: "main", executor: WALLET_A_EIP55 },
  ]);
  const mixedCase = {
    ...withCandidates,
    executorCandidates: withCandidates.executorCandidates.map((candidate) => ({
      ...candidate,
      executor: candidate.executor.slice(0, 4) + candidate.executor.slice(4).toUpperCase(),
    })),
  };
  const { planHash: _ignored, ...mixedPayload } = mixedCase;
  assert.ok(
    validateOnchainHookPlanArtifact(mixedPayload).some((issue) =>
      issue.includes("lowercase address form"),
    ),
  );
});

test("candidate entries reject unknown fields (closed key set)", () => {
  // D3 回归：条目级封闭字段集，与 hooks/capabilities 条目同纪律。
  const withCandidates = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    { stageIdentifier: "main", executor: WALLET_A },
  ]);
  const smuggled = {
    ...withCandidates,
    executorCandidates: withCandidates.executorCandidates.map((candidate) => ({
      ...candidate,
      note: "smuggled",
    })),
  };
  const { planHash: _ignored, ...smuggledPayload } = smuggled;
  assert.ok(
    validateOnchainHookPlanArtifact(smuggledPayload).some((issue) =>
      issue.includes("unknown field `note` on executorCandidates[0]"),
    ),
  );
});

test("artifact boundary mirrors the declared-stage gate", () => {
  // D4 回归：候选 stageId 不在本计划已注册 hook 阶段集合内 → 制品边界拒绝。
  const withCandidates = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    { stageIdentifier: "main", executor: WALLET_A },
  ]);
  const ghostStageId = ("0x" + "99".repeat(32)) as `0x${string}`;
  const ghost = {
    ...withCandidates,
    executorCandidates: [
      ...withCandidates.executorCandidates,
      {
        stageIdentifier: "ghost.stage",
        stageId: ghostStageId,
        executor: WALLET_B,
      },
    ],
    executorCandidatesRoot: executorCandidatesRootOf([
      ...withCandidates.executorCandidates,
      { stageId: ghostStageId, executor: WALLET_B },
    ]),
  };
  const { planHash: _ignored, ...ghostPayload } = ghost;
  assert.ok(
    validateOnchainHookPlanArtifact(ghostPayload).some((issue) =>
      issue.includes("is not a stage declared in this plan"),
    ),
  );
});
