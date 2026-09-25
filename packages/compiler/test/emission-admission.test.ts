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

/**
 * 发射适格面（admissions）编译面测试：IR/onchain 产物条目、过滤档指令
 * （hook 档非法而过滤档合法的形态放行）、过滤档镜像门的拒绝面与
 * Solidity 注册参数的 flag=8 承诺。
 */

const admissionZhixu = (validWhen: string): ZhixuDefinition => ({
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: { name: "admission_demo" },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    taskPatterns: [
      {
        name: "flow",
        stages: [
          {
            // 自发种子阶段：BEGIN 自收 seed 物化自身（静态 executor 钩子）。
            name: "gate",
            source: "buyer",
            receiveSignals: { BEGIN: "buyer::flow.gate.seed" },
            sendSignals: [{ name: "seed" }, { name: "ready" }],
            executor: { supplierType: "organization", supplierID: "gate-org" },
          },
          {
            name: "work",
            source: "buyer",
            receiveSignals: { RUN: "buyer::flow.gate.ready" },
            sendSignals: [
              { name: "cmp", validWhen },
              { name: "cmp_err" },
            ],
            executor: { supplierType: "organization", supplierID: "work-org" },
          },
        ],
      },
    ],
  },
});

function seedInstruction(signalName: string): OnchainHookInstruction {
  const sourceId = onchainSourceId("buyer");
  const signalId = onchainSignalId(signalName);
  return {
    op: "SIGNAL",
    source: "buyer",
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
    admissionZhixu("buyer::flow.gate.seed & ~(flow.work.cmp_err +14d)"),
  );

  assert.equal(plan.admissions.length, 1);
  const admission = plan.admissions[0] as CompiledHookPlanAdmission;
  assert.equal(admission.stageIdentifier, "flow.work");
  assert.equal(admission.signalName, "flow.work.cmp");
  assert.deepEqual(
    admission.dependencies.map((dependency) => [
      dependency.kind,
      dependency.source,
      dependency.signalName,
    ]),
    [
      ["negative", "buyer", "flow.work.cmp_err"],
      ["positive", "buyer", "flow.gate.seed"],
    ],
  );
});

test("onchain admission entries carry the fact-key identity triple", () => {
  const onchain = compileZhixuOnchainHookPlan(
    admissionZhixu("buyer::flow.gate.seed & ~(flow.work.cmp_err +14d)"),
  );

  const admission = firstAdmission(onchain.admissions);
  const expectedSignalId = onchainSignalId("flow.work.cmp");
  const expectedSourceId = onchainSourceId("buyer");
  assert.equal(admission.admissionId, onchainSignalKey(expectedSourceId, expectedSignalId));
  assert.equal(admission.signalId, expectedSignalId);
  assert.equal(admission.stageId, onchainStageId("flow.work"));
  assert.deepEqual(
    admission.instructions.map((instruction) => instruction.op),
    ["SIGNAL", "SIGNAL", "DELAY", "NOT", "AND"],
  );
});

test("hook-profile-illegal but filter-legal decaying positions compile: bare root, OR branch", () => {
  const bareRoot = compileZhixuOnchainHookPlan(admissionZhixu("buyer::~(flow.work.cmp_err +14d)"));
  assert.deepEqual(
    firstAdmission(bareRoot.admissions).instructions.map((i) => i.op),
    ["SIGNAL", "DELAY", "NOT"],
  );

  const orBranch = compileZhixuOnchainHookPlan(
    admissionZhixu("buyer::flow.gate.seed | ~(flow.work.cmp_err +14d)"),
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
        admissionZhixu("buyer::(flow.gate.seed & ~(flow.work.cmp_err +14d)) +5s"),
      ),
    (error: unknown) =>
      error instanceof HookPlanCompilationError && /no nested delays/.test(error.message),
  );
});

test("admission registration args reuse the hook slot shape with flag 8 inside hooksHash", () => {
  const onchain = compileZhixuOnchainHookPlan(
    admissionZhixu("buyer::flow.gate.seed & ~(flow.work.cmp_err +14d)"),
  );
  const args = toSolidityRegisterPlanArgs(onchain);
  const admission = firstAdmission(onchain.admissions);

  const admissionArg = args.hooks.find((hook) => hook.flags === HOOK_FLAG_ADMISSION);
  assert.ok(admissionArg, "admission entry must ride the CompactHook array");
  assert.equal(admissionArg.kind, "admission");
  assert.equal(admissionArg.hookId, admission.admissionId);
  assert.equal(admissionArg.hookName, admission.signalId);
  assert.deepEqual(
    admissionArg.dependencyKeys,
    [...new Set(admission.dependencies.map((dependency) => dependency.signalKey))].sort(),
  );
  // hooksHash 对提交的 calldata 重算——适格面随 hook 槽一同入承诺。
  assert.equal(args.hooksHash, hashSolidityRegisterHooks(args.hooks));
});

/**
 * 过滤档镜像门（反序列化边界与编译入口共用 validateOnchainCompiledAdmissions
 * 单点实现）：变异制品按字段断言对应 issue；planHash 承诺重算门由专门
 * 测试覆盖，此处按正则聚焦镜像面。
 */
function admissionIssuesOf(
  mutate: (admission: OnchainCompiledAdmission) => OnchainCompiledAdmission,
): readonly string[] {
  const onchain = compileZhixuOnchainHookPlan(
    admissionZhixu("buyer::flow.gate.seed & ~(flow.work.cmp_err +14d)"),
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
      seedInstruction("flow.work.cmp_err"),
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
      seedInstruction("flow.work.cmp_err"),
      { op: "DELAY", delaySeconds: 30 * 24 * 60 * 60 + 1 },
    ],
  }));
  assert.match(issues.join("; "), /must not exceed 2592000/);
});

test("filter-profile mirror rejects roots that do not leave a single stack item", () => {
  const issues = admissionIssuesOf((admission) => ({
    ...admission,
    instructions: [
      seedInstruction("flow.work.cmp_err"),
      seedInstruction("flow.gate.seed"),
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
      onchainSourceId("seller"),
      onchainSignalId(admission.signalName),
    ),
  }));
  assert.match(issues.join("; "), /admissionId must be keccak256/);
});

/** loader 侧闭集测试的声明面基座（合法形态，按用例覆写 sendSignals）。 */
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
      taskPatterns: [
        {
          name: "flow",
          stages: [
            {
              name: "gate",
              source: "buyer",
              receiveSignals: { BEGIN: "buyer::flow.gate.seed" },
              sendSignals: [{ name: "seed" }],
              executor: { supplierType: "organization", supplierID: "gate-org" },
            },
            {
              name: "work",
              source: "buyer",
              receiveSignals: { RUN: "buyer::flow.gate.ready" },
              sendSignals,
              executor: { supplierType: "organization", supplierID: "work-org" },
            },
          ],
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
      /must be an object \{name, validWhen\?\}/.test(error.message),
  );

  assert.throws(
    () => parseZhixuDefinition(loaderCaseZhixu([{ name: "cmp", validWhen: 14 }])),
    (error: unknown) =>
      error instanceof ZhixuLoadError &&
      /validWhen must be a string when present/.test(error.message),
  );
});

test("compiler-side rejections mirror core: self-reference and blank validWhen", () => {
  assert.throws(
    () => compileZhixuHookPlan(admissionZhixu("buyer::flow.work.cmp & flow.gate.seed")),
    (error: unknown) =>
      error instanceof HookPlanCompilationError && /D028/.test(error.message),
  );

  assert.throws(
    () => compileZhixuHookPlan(admissionZhixu("   ")),
    (error: unknown) =>
      error instanceof HookPlanCompilationError && /D027/.test(error.message),
  );
});
