import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuHookPlan,
  HookPlanCompilationError,
  hashSolidityRegisterHooks,
  HOOK_FLAG_ADMISSION,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
  parseZhixuDefinition,
  toSolidityRegisterPlanArgs,
  validateOnchainHookPlanArtifact,
  ZhixuLoadError,
  type CompiledHookPlanAdmission,
  type OnchainCompiledAdmission,
  type OnchainHookInstruction,
  type OnchainHookPlanArtifact,
  type ZhixuDefinition,
} from "../src/index.js";
import { compileZhixuOnchainHookPlan } from "../src/onchain/compile.js";
import { hashOnchainPlanPayload } from "../src/onchain/hash/plan.js";
import {
  commitmentGoldenCase,
  commitmentRegisterHooksArgs,
} from "./commitment-golden.js";

const GATE_SUPPLIER = "5f0b1e2a-7c9d-4e1f-9a2b-000000000011";
const WORK_SUPPLIER = "5f0b1e2a-7c9d-4e1f-9a2b-000000000012";

const admissionZhixu = (validWhen: string): ZhixuDefinition => ({
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "admission_demo" },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    stages: [
      {
        name: "gate",
        source: "slot_a",
        receiveSignals: { BEGIN: "slot_a::gate.seed" },
        sendSignals: [{ name: "seed" }, { name: "ready" }],
        executor: { supplierType: "organization", supplierID: GATE_SUPPLIER },
      },
      {
        name: "work",
        source: "slot_a",
        receiveSignals: { RUN: "slot_a::gate.ready" },
        sendSignals: [
          { name: "cmp", validWhen: [validWhen] },
          { name: "cmp_err" },
        ],
        executor: { supplierType: "organization", supplierID: WORK_SUPPLIER },
      },
    ],
  },
});

function seedInstruction(signalName: string): OnchainHookInstruction {
  const sourceId = onchainSourceId("slot_a");
  const signalId = onchainSignalId(signalName);
  return {
    op: "SIGNAL",
    source: "slot_a",
    signalName,
    sourceId,
    signalId,
    signalKey: onchainSignalKey(sourceId, signalId),
  };
}

function firstAdmission(
  admissions: readonly OnchainCompiledAdmission[],
): OnchainCompiledAdmission {
  const [admission] = admissions;
  assert.ok(admission, "admission entry expected");
  return admission;
}

test("declared validWhen compiles into hook_plan admissions; unconditional entries do not", () => {
  const plan = compileZhixuHookPlan(
    admissionZhixu("slot_a::gate.seed & ~(work.cmp_err +14d)"),
  );

  assert.equal(plan.admissions.length, 1);
  const admission = plan.admissions[0] as CompiledHookPlanAdmission;
  assert.equal(admission.stageIdentifier, "work");
  assert.equal(admission.signalName, "work.cmp");
  assert.deepEqual(
    admission.dependencies.map((dependency) => [
      dependency.kind,
      dependency.source,
      dependency.signalName,
    ]),
    [
      ["negative", "slot_a", "work.cmp_err"],
      ["positive", "slot_a", "gate.seed"],
    ],
  );
});

test("on-chain artifact boundary rejects an admission without a matching signal capability", () => {
  const onchain = compileZhixuOnchainHookPlan(admissionZhixu("slot_a::gate.seed"));
  const realAdmission = firstAdmission(onchain.admissions);
  const signalName = "work.unknown";
  const signalId = onchainSignalId(signalName);
  const sourceId = onchainSourceId("slot_a");
  const forgedAdmission: OnchainCompiledAdmission = {
    ...realAdmission,
    signalName,
    signalId,
    admissionId: onchainSignalKey(sourceId, signalId),
  };
  const { planHash: _staleHash, ...payload } = onchain;
  const forged = { ...payload, admissions: [forgedAdmission] };
  const resigned = {
    ...forged,
    planHash: hashOnchainPlanPayload(forged),
  };
  assert.ok(
    validateOnchainHookPlanArtifact(resigned).includes(
      `admissions[0] work::${signalName} has no current-order signal capability for the declared emission; `
        + "the admission face addresses the emitted fact key (sourceId, signalId), which only the declaring stage's capability carries",
    ),
  );
});

test("hook-profile-illegal but filter-legal decaying positions compile: bare root, OR branch", () => {
  const bareRoot = compileZhixuOnchainHookPlan(admissionZhixu("slot_a::~(work.cmp_err +14d)"));
  assert.deepEqual(
    firstAdmission(bareRoot.admissions).instructions.map((i) => i.op),
    ["SIGNAL", "DELAY", "NOT"],
  );

  const orBranch = compileZhixuOnchainHookPlan(
    admissionZhixu("slot_a::gate.seed | ~(work.cmp_err +14d)"),
  );
  assert.deepEqual(
    firstAdmission(orBranch.admissions).instructions.map((i) => i.op),
    ["SIGNAL", "SIGNAL", "DELAY", "NOT", "OR"],
  );
});

test("delay operands wrapping a decaying veto are nested delays and rejected in the filter profile too", () => {
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(
        admissionZhixu("slot_a::(gate.seed & ~(work.cmp_err +14d)) +5s"),
      ),
    (error: unknown) =>
      error instanceof HookPlanCompilationError && /no nested delays/.test(error.message),
  );
});

test("admission commitments are pinned by the shared golden vectors", () => {
  for (const name of [
    "admission_demo_declared_valid_when",
    "admission_demo_bare_root_veto",
  ]) {
    const golden = commitmentGoldenCase(name);
    const onchain = compileZhixuOnchainHookPlan(golden.input.definition);
    const args = toSolidityRegisterPlanArgs(onchain);
    assert.ok(
      args.hooks.some((hook) => hook.flags === HOOK_FLAG_ADMISSION),
      `${name}: fixture must carry an admission hook slot`,
    );
    assert.equal(onchain.planHash, golden.expected.onchainPlanHash, `${name}: onchain planHash`);
    assert.equal(args.hooksHash, golden.expected.hooksHash, `${name}: hooksHash`);
    assert.equal(args.planHash, golden.expected.runtimePlanHash, `${name}: runtime planHash`);
    assert.equal(
      hashSolidityRegisterHooks(commitmentRegisterHooksArgs(golden.input.hooks)),
      golden.expected.hooksHash,
      `${name}: pinned hooks array must rehash to the expected hooksHash`,
    );
  }
});

function admissionIssuesOf(
  mutate: (admission: OnchainCompiledAdmission) => OnchainCompiledAdmission,
): readonly string[] {
  const onchain = compileZhixuOnchainHookPlan(
    admissionZhixu("slot_a::gate.seed & ~(work.cmp_err +14d)"),
  );
  const mutated = {
    ...onchain,
    admissions: onchain.admissions.map(mutate),
  } as OnchainHookPlanArtifact;
  return validateOnchainHookPlanArtifact(mutated);
}

test("filter-profile mirror rejects NOT vocabulary violations", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    instructions: [
      seedInstruction("work.cmp_err"),
      { op: "DELAY", delaySeconds: 14 },
      { op: "NOT" },
      { op: "NOT" },
    ],
  }));
  assert.match(issues.join("; "), /NOT over composite operands/);
});

test("filter-profile mirror keeps the 30d delay cap", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    instructions: [
      seedInstruction("work.cmp_err"),
      { op: "DELAY", delaySeconds: 30 * 24 * 60 * 60 + 1 },
    ],
  }));
  assert.match(issues.join("; "), /must not exceed 2592000/);
});

test("filter-profile mirror rejects anchorless delay operands (UB-1)", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    instructions: [
      seedInstruction("work.cmp_err"),
      { op: "NOT" },
      { op: "DELAY", delaySeconds: 5 },
    ],
  }));
  assert.match(
    issues.join("; "),
    /DELAY requires an operand with a positive signal anchor/,
  );
});

test("filter-profile mirror caps instruction nesting at MAX_INSTRUCTION_DEPTH (120)", () => {
  const atom = seedInstruction("gate.seed");
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    instructions: [
      ...Array.from({ length: 122 }, () => atom),
      ...Array.from({ length: 121 }, () => ({ op: "AND" as const, arity: 2 })),
    ],
  }));
  assert.ok(
    issues.some((issue) =>
      /instruction nesting depth 121 exceeds MAX_INSTRUCTION_DEPTH 120 \(contract _validateAdmission reverts InvalidInstruction\)/.test(issue),
    ),
    issues.join("; "),
  );
});

test("filter-profile mirror rejects nested delay operands", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    instructions: [
      seedInstruction("work.cmp_err"),
      { op: "DELAY", delaySeconds: 5 },
      { op: "DELAY", delaySeconds: 10 },
    ],
  }));
  assert.match(
    issues.join("; "),
    /DELAY cannot consume an operand containing another DELAY/,
  );
});

test("filter-profile mirror rejects roots that do not leave a single stack item", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    instructions: [
      seedInstruction("work.cmp_err"),
      seedInstruction("gate.seed"),
    ],
  }));
  assert.match(issues.join("; "), /must leave exactly one stack item/);
});

test("filter-profile mirror rejects dependency keys that diverge from SIGNAL atoms", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    dependencies: admission.dependencies.slice(0, 1),
  }));
  assert.match(issues.join("; "), /HookDependencyKeyMismatch/);
});

test("filter-profile mirror rejects identity derivation drift", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    admissionId: onchainSignalKey(
      onchainSourceId("slot_b"),
      onchainSignalId(admission.signalName),
    ),
  }));
  assert.match(issues.join("; "), /admissionId must be keccak256/);
});

function loaderCaseZhixu(
  sendSignals: unknown,
): string {
  return JSON.stringify({
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "admission_demo" },
    spec: {
      platform: { type: "cloud" },
      nucleation: { id: "core" },
      stages: [
        {
          name: "gate",
          source: "slot_a",
          receiveSignals: { BEGIN: "slot_a::gate.seed" },
          sendSignals: [{ name: "seed" }],
          executor: { supplierType: "organization", supplierID: GATE_SUPPLIER },
        },
        {
          name: "work",
          source: "slot_a",
          receiveSignals: { RUN: "slot_a::gate.ready" },
          sendSignals,
          executor: { supplierType: "organization", supplierID: WORK_SUPPLIER },
        },
      ],
    },
  });
}

test("sendSignals entries are a closed key set at the loader boundary", () => {
  assert.throws(
    () => parseZhixuDefinition(loaderCaseZhixu([{ name: "cmp", priority: "high" }])),
    (error: unknown) =>
      error instanceof ZhixuLoadError &&
      /unknown field `priority`/.test(error.message),
  );

  assert.throws(
    () => parseZhixuDefinition(loaderCaseZhixu(["cmp"])),
    (error: unknown) =>
      error instanceof ZhixuLoadError &&
      /must be an object \{name, validWhen\?, trigger\?\}/.test(error.message),
  );

  assert.throws(
    () => parseZhixuDefinition(loaderCaseZhixu([{ name: "cmp", validWhen: 14 }])),
    (error: unknown) =>
      error instanceof ZhixuLoadError &&
      /validWhen must be a non-empty array of non-empty strings/.test(error.message),
  );
});

test("compiler-side rejections mirror core: self-reference and blank validWhen", () => {
  assert.throws(
    () => compileZhixuHookPlan(admissionZhixu("slot_a::work.cmp & gate.seed")),
    (error: unknown) =>
      error instanceof HookPlanCompilationError && /D028/.test(error.message),
  );

  assert.throws(
    () => compileZhixuHookPlan(admissionZhixu("   ")),
    (error: unknown) =>
      error instanceof HookPlanCompilationError && /D027/.test(error.message),
  );
});
