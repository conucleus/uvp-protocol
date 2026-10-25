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
import {
  commitmentGoldenCase,
  commitmentRegisterHooksArgs,
} from "./commitment-golden.js";
import { hashSolidityRegisterHooks } from "../src/onchain/solidity/registration.js";

const WALLET_A = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266" as `0x${string}`;
const WALLET_A_EIP55 = "0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`;
const WALLET_B = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as `0x${string}`;
const WALLET_C = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc" as `0x${string}`;

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

test("baseline commitments are pinned by the shared golden vectors", () => {
  for (const name of [
    "candidates_blackbox_two_stage",
    "candidates_blackbox_with_candidates",
    "candidates_blackbox_birth",
  ]) {
    const golden = commitmentGoldenCase(name);
    const onchain = compileZhixuOnchainHookPlan(
      golden.input.definition,
      undefined,
      golden.input.executorCandidates,
    );
    const args = toSolidityRegisterPlanArgs(onchain);
    assert.equal(onchain.planHash, golden.expected.onchainPlanHash, `${name}: onchain planHash`);
    assert.equal(args.planHash, golden.expected.runtimePlanHash, `${name}: runtime planHash`);
    assert.equal(args.hooksHash, golden.expected.hooksHash, `${name}: hooksHash`);
    assert.equal(
      onchain.executorCandidatesRoot,
      golden.expected.executorCandidatesRoot,
      `${name}: executorCandidatesRoot`,
    );
    assert.equal(
      hashSolidityRegisterHooks(commitmentRegisterHooksArgs(golden.input.hooks)),
      golden.expected.hooksHash,
      `${name}: pinned hooks array must rehash to the expected hooksHash`,
    );
  }
});

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
    "0x" + "a".repeat(39),
    "0x" + "a".repeat(41),
    "0x" + "g".repeat(40),
    "f39fd6e51aad88f6f4ce6ab8827279cfffb92266",
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

test("compile normalizes a checksummed address into the canonical lowercase form", () => {
  const checksummed = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A_EIP55),
  ]);
  const lowercase = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("main", WALLET_A),
  ]);
  assert.equal(checksummed.executorCandidates[0]?.executor, WALLET_A);
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

test("runtime planHash recomputes from the six-domain preimage and forks on any single domain", () => {
  const args = toSolidityRegisterPlanArgs(
    compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
      candidateWith("main", WALLET_A),
      candidateWith("deal", WALLET_B),
    ]),
  );
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

test("register args carry candidates as bare {stageId, executor} pairs in canonical order", () => {
  const artifact = compileZhixuOnchainHookPlan(twoStageZhixu, undefined, [
    candidateWith("deal", WALLET_A),
    candidateWith("main", WALLET_B),
  ]);
  const args = toSolidityRegisterPlanArgs(artifact);
  assert.deepEqual(args.executorCandidates, [
    { stageId: artifact.executorCandidates[0]?.stageId, executor: artifact.executorCandidates[0]?.executor },
    { stageId: artifact.executorCandidates[1]?.stageId, executor: artifact.executorCandidates[1]?.executor },
  ]);
  for (const candidate of args.executorCandidates) {
    assert.equal(Object.keys(candidate).length, 2);
    assert.match(candidate.executor, /^0x[0-9a-f]{40}$/);
    assert.match(candidate.stageId, /^0x[0-9a-f]{64}$/);
  }
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
  const bareArgs = compileZhixuRegisterPlanArgs(twoStageZhixu);
  assert.equal(bareArgs.executorCandidates.length, 0);
  assert.equal(bareArgs.executorCandidatesRoot, EMPTY_MERKLE_ROOT);
  assert.notEqual(args.planHash, bareArgs.planHash);
});

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
    [
      { stageId: artifact.executorCandidates[0]?.stageId, executor: "0x" + "a".repeat(39) },
      artifact.executorCandidates[1],
    ],
    [
      { stageId: artifact.executorCandidates[0]?.stageId, executor: "0x" + "0".repeat(40) },
      artifact.executorCandidates[1],
    ],
    [
      { stageId: (artifact.executorCandidates[0]?.stageId ?? "").toUpperCase().replace("0X", "0x"), executor: WALLET_A },
      artifact.executorCandidates[1],
    ],
    [{ stageId: "0x" + "a".repeat(62), executor: WALLET_A }, artifact.executorCandidates[1]],
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
  } as OnchainHookPlanArtifact);
  const issues = validateOnchainHookPlanArtifact(reordered);
  assert.ok(
    issues.some((issue) => /executorCandidates\[1\] breaks the canonical order/.test(issue)),
    `expected canonical-order issue, got: ${issues.join("; ")}`,
  );
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
