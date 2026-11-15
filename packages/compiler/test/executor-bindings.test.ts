import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
  EMPTY_MERKLE_ROOT,
  executorBindingLeaf,
  executorBindingProof,
  executorBindingsRootOf,
  HOOK_FLAG_DYNAMIC_EXECUTOR,
  HOOK_FLAG_EMIT_READY,
  hashOnchainPlanPayload,
  HookPlanCompilationError,
  keccak256Hex,
  onchainSupplierId,
  toSolidityRegisterPlanArgs,
  validateOnchainHookPlanArtifact,
  verifyMerkleProof,
  type OnchainHookPlanArtifact,
  type ZhixuDefinition,
} from "../src/index.js";
import type { ExecutorBinding } from "../src/types/index.js";

function staticZhixu(mainSupplierID = "main-org"): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "binding_static_demo" },
    spec: {
      platform: { type: "blockchain", provider: "eth" },
      nucleation: { id: "core" },
      stages: [
        {
          name: "main",
          source: "buyer",
          receiveSignals: { START: "buyer::main.kickoff" },
          sendSignals: [{ name: "str" }, { name: "cmp" }, { name: "kickoff" }],
          executor: {
            supplierType: "organization",
            supplierID: mainSupplierID,
          },
        },
        {
          name: "deal",
          source: "trading",
          receiveSignals: { PLACE: "trading::deal.kickoff" },
          sendSignals: [{ name: "closed" }, { name: "kickoff" }],
          executor: {
            supplierType: "organization",
            supplierID: "deal-org",
          },
        },
      ],
    },
  };
}

function birthZhixu(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "binding_birth_demo" },
    spec: {
      platform: { type: "blockchain", provider: "eth" },
      nucleation: { id: "core" },
      stages: [
        {
          name: "main",
          source: "buyer",
          sendSignals: [{ name: "str", trigger: true }, { name: "cmp" }],
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
}

function dockZhixu(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "binding_dock_demo" },
    spec: {
      platform: { type: "blockchain", provider: "eth" },
      nucleation: { id: "core" },
      stages: [
        {
          name: "accept",
          source: "acceptor",
          receiveSignals: { CHECK: "acceptor::accept.check" },
          sendSignals: [{ name: "accepted" }, { name: "check" }],
          executor: { supplierType: "dock" },
        },
        {
          name: "gate",
          source: "acceptor",
          receiveSignals: { OPEN: "acceptor::gate.open" },
          sendSignals: [{ name: "open" }],
          executor: { supplierType: "organization", supplierID: "gate-org" },
        },
      ],
    },
  };
}

function dynamicZhixu(): ZhixuDefinition {
  return {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "binding_dynamic_demo" },
    spec: {
      platform: { type: "blockchain", provider: "eth" },
      nucleation: { id: "core" },
      stages: [
        {
          name: "anchor",
          source: "buyer",
          selectedStages: ["main"],
          receiveSignals: { BEGIN: "buyer::anchor.self_ready" },
          sendSignals: [{ name: "executor_selected" }, { name: "self_ready" }],
          executor: { supplierType: "organization", supplierID: "anchor-org" },
        },
        {
          name: "main",
          source: "buyer",
          receiveSignals: {
            GO: "buyer::anchor.executor_selected",
            WAIT: "buyer::main.cmp",
          },
          sendSignals: [{ name: "cmp" }],
        },
      ],
    },
  };
}

function isCompilationIssue(error: unknown, expected: string | RegExp): boolean {
  return (
    error instanceof HookPlanCompilationError &&
    error.issues.some((issue) =>
      typeof expected === "string" ? issue.includes(expected) : expected.test(issue),
    )
  );
}

function repin(artifact: OnchainHookPlanArtifact): OnchainHookPlanArtifact {
  const { planHash: _stale, ...payload } = artifact;
  return { ...artifact, planHash: hashOnchainPlanPayload(payload) };
}

function bindingOf(
  bindings: readonly ExecutorBinding[],
  stageIdentifier: string,
  kind: 0 | 1,
): readonly ExecutorBinding[] {
  return bindings.filter(
    (binding) =>
      binding.stageIdentifier === stageIdentifier && binding.kind === kind,
  );
}

test("default bindings derive from each plain executor supplierID and commit to the root", () => {
  const artifact = compileZhixuOnchainHookPlan(staticZhixu());

  assert.equal(artifact.executorBindings.length, 2);
  assert.deepEqual(
    bindingOf(artifact.executorBindings, "main", 0).map((binding) => ({
      stageId: binding.stageId,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
    [
      {
        stageId: keccak256Hex("main"),
        supplierId: onchainSupplierId("main-org"),
        kind: 0,
      },
    ],
  );
  assert.deepEqual(
    bindingOf(artifact.executorBindings, "deal", 0).map((binding) => ({
      stageId: binding.stageId,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
    [
      {
        stageId: keccak256Hex("deal"),
        supplierId: onchainSupplierId("deal-org"),
        kind: 0,
      },
    ],
  );
  assert.equal(
    artifact.executorBindingsRoot,
    executorBindingsRootOf(artifact.executorBindings),
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(artifact), []);

  const defaultBinding = bindingOf(artifact.executorBindings, "main", 0)[0]!;
  const proof = executorBindingProof(
    artifact.executorBindings,
    defaultBinding.stageId,
    defaultBinding.supplierId,
    0,
  );
  assert.ok(proof, "every committed default binding must be provable");
  assert.equal(
    verifyMerkleProof(
      artifact.executorBindingsRoot,
      executorBindingLeaf(
        defaultBinding.stageId,
        defaultBinding.supplierId,
        defaultBinding.kind,
      ),
      proof,
    ),
    true,
  );
});

test("candidate input carries a supplierID and adds a kind=1 leaf beside the default binding", () => {
  const bare = compileZhixuOnchainHookPlan(staticZhixu());
  const withCandidate = compileZhixuOnchainHookPlan(staticZhixu(), [
    { stageIdentifier: "main", supplierID: "candidate-org" },
  ]);

  assert.deepEqual(
    bindingOf(withCandidate.executorBindings, "main", 1).map((binding) => ({
      stageId: binding.stageId,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
    [
      {
        stageId: keccak256Hex("main"),
        supplierId: onchainSupplierId("candidate-org"),
        kind: 1,
      },
    ],
  );
  assert.equal(bindingOf(withCandidate.executorBindings, "main", 0).length, 1);
  assert.equal(
    withCandidate.executorBindingsRoot,
    executorBindingsRootOf(withCandidate.executorBindings),
  );
  assert.notEqual(withCandidate.executorBindingsRoot, bare.executorBindingsRoot);
  assert.notEqual(withCandidate.planHash, bare.planHash);
  assert.deepEqual(validateOnchainHookPlanArtifact(withCandidate), []);

  const args = toSolidityRegisterPlanArgs(withCandidate);
  assert.deepEqual(
    args.executorBindings,
    withCandidate.executorBindings.map((binding) => ({
      stageId: binding.stageId,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
  );
  assert.equal(args.executorBindingsRoot, withCandidate.executorBindingsRoot);
  assert.notEqual(args.planHash, toSolidityRegisterPlanArgs(bare).planHash);

  const candidateBinding = bindingOf(withCandidate.executorBindings, "main", 1)[0]!;
  const candidateProof = executorBindingProof(
    withCandidate.executorBindings,
    candidateBinding.stageId,
    candidateBinding.supplierId,
    1,
  );
  assert.ok(candidateProof, "candidate patch proofs must be derivable from the committed set");
});

test("register args carry the binding set, root, and dynamic hook flag end-to-end", () => {
  const args = compileZhixuRegisterPlanArgs(staticZhixu(), [
    { stageIdentifier: "deal", supplierID: "candidate-deal" },
  ]);
  assert.equal(args.schemaVersion, "uvp.onchainHookPlan.v8");
  assert.equal(args.executorBindings.length, 3);
  assert.equal(
    args.executorBindingsRoot,
    executorBindingsRootOf(args.executorBindings),
  );
  for (const binding of args.executorBindings) {
    assert.deepEqual(Object.keys(binding).sort(), ["kind", "stageId", "supplierId"]);
  }

  const dynamicArgs = compileZhixuRegisterPlanArgs(dynamicZhixu());
  const dynamicHook = dynamicArgs.hooks.find(
    (hook) => hook.stageId === keccak256Hex("main"),
  );
  assert.ok(dynamicHook, "the dynamic stage must register its receive hooks");
  assert.equal(
    dynamicHook.flags,
    HOOK_FLAG_EMIT_READY | HOOK_FLAG_DYNAMIC_EXECUTOR,
    "dynamic receive hooks register EMIT_READY | HOOK_FLAG_DYNAMIC_EXECUTOR",
  );
  assert.equal(dynamicHook.routeId, undefined);
});

test("dynamic stage binds no plan executor and materializes without a route", () => {
  const artifact = compileZhixuOnchainHookPlan(dynamicZhixu());
  assert.deepEqual(validateOnchainHookPlanArtifact(artifact), []);

  const mainHooks = artifact.compiledHooks.filter(
    (hook) => hook.stageIdentifier === "main",
  );
  assert.equal(mainHooks.length, 2);
  for (const hook of mainHooks) {
    assert.equal(hook.dynamicExecutor, true);
    assert.equal(hook.emitReady, true);
    assert.equal(hook.dockExecutor, false);
    assert.equal(hook.orderTriggerKind, "none");
    assert.equal(hook.routeRef, undefined);
  }
  const anchorHook = artifact.compiledHooks.find(
    (hook) => hook.stageIdentifier === "anchor",
  );
  assert.equal(anchorHook?.dynamicExecutor, false);
  assert.ok(anchorHook?.routeRef);

  assert.deepEqual(
    artifact.executorBindings.map((binding) => binding.stageIdentifier),
    ["anchor"],
    "dynamic stages carry no default or candidate binding",
  );
  assert.equal(
    artifact.executorBindingsRoot,
    executorBindingsRootOf(artifact.executorBindings),
  );
});

test("dynamic, candidate, birth, and dock executor bindings are mutually exclusive", () => {
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(dynamicZhixu(), [
        { stageIdentifier: "main", supplierID: "candidate-org" },
      ]),
    (error: unknown) => isCompilationIssue(error, "is a dynamic stage"),
  );
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(birthZhixu(), [
        { stageIdentifier: "main", supplierID: "candidate-org" },
      ]),
    (error: unknown) => isCompilationIssue(error, "birth-stage executors are immutable"),
  );
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(dockZhixu(), [
        { stageIdentifier: "accept", supplierID: "candidate-org" },
      ]),
    (error: unknown) => isCompilationIssue(error, "is a dock stage"),
  );
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(staticZhixu(), [
        { stageIdentifier: "ghost", supplierID: "candidate-org" },
      ]),
    (error: unknown) => isCompilationIssue(error, "not a stage declared in this plan"),
  );
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(staticZhixu(), [
        { stageIdentifier: "main", supplierID: "   " },
      ]),
    (error: unknown) => isCompilationIssue(error, "non-empty supplierID"),
  );

  const artifact = compileZhixuOnchainHookPlan(dynamicZhixu());
  const mixed = repin({
    ...artifact,
    compiledHooks: artifact.compiledHooks.map((hook) =>
      hook.stageIdentifier === "main" && hook.hookName === "GO"
        ? { ...hook, dynamicExecutor: false }
        : hook,
    ),
  });
  assert.ok(
    validateOnchainHookPlanArtifact(mixed).some((issue) =>
      issue.includes("InconsistentDynamicExecutorFlag"),
    ),
    "mixing dynamic and non-dynamic hooks of one stage must be rejected",
  );

  const withRoute = repin({
    ...artifact,
    executorRoutes: [
      ...artifact.executorRoutes,
      {
        routeId: keccak256Hex("main#executorRoute"),
        stageId: keccak256Hex("main"),
        stageIdentifier: "main",
        executorType: "organization",
        executorId: "main-org",
        executorHash: keccak256Hex("main-executor"),
        resourcesHash: keccak256Hex("main-resources"),
        routeHash: keccak256Hex("main-route"),
      },
    ],
  });
  assert.ok(
    validateOnchainHookPlanArtifact(withRoute).some((issue) =>
      issue.includes("dynamic executor stage main must not carry an executor route"),
    ),
    "a dynamic stage must not be given a plan-level route",
  );
});

test("duplicate bindings are rejected at compile time instead of absorbed by the Merkle tree", () => {
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(staticZhixu(), [
        { stageIdentifier: "main", supplierID: "candidate-org" },
        { stageIdentifier: "main", supplierID: "candidate-org" },
      ]),
    (error: unknown) =>
      isCompilationIssue(error, "duplicate executor binding") &&
      isCompilationIssue(error, "DuplicateExecutorBinding"),
  );
});

test("the binding cap mirrors the contract's MAX_EXECUTOR_BINDINGS bound", () => {
  const candidates = Array.from({ length: 257 }, (_, index) => ({
    stageIdentifier: "main",
    supplierID: `candidate-org-${index}`,
  }));
  assert.throws(
    () => compileZhixuOnchainHookPlan(staticZhixu(), candidates),
    (error: unknown) => isCompilationIssue(error, "TooManyExecutorBindings"),
  );
});

test("a binding-free plan pins the empty binding root and rejects tampered roots", () => {
  const dockOnly: ZhixuDefinition = {
    apiVersion: "uvp/v0",
    kind: "Zhixu",
    metadata: { name: "binding_empty_demo" },
    spec: {
      platform: { type: "blockchain", provider: "eth" },
      nucleation: { id: "core" },
      stages: [
        {
          name: "accept",
          source: "acceptor",
          receiveSignals: { CHECK: "acceptor::accept.check" },
          sendSignals: [{ name: "accepted" }, { name: "check" }],
          executor: { supplierType: "dock" },
        },
      ],
    },
  };
  const emptyArtifact = compileZhixuOnchainHookPlan(dockOnly);
  assert.deepEqual(emptyArtifact.executorBindings, []);
  assert.equal(emptyArtifact.executorBindingsRoot, EMPTY_MERKLE_ROOT);
  assert.deepEqual(validateOnchainHookPlanArtifact(emptyArtifact), []);

  const artifact = compileZhixuOnchainHookPlan(staticZhixu());
  const tamperedRoot = repin({
    ...artifact,
    executorBindingsRoot: keccak256Hex("tampered binding root"),
  });
  assert.ok(
    validateOnchainHookPlanArtifact(tamperedRoot).includes(
      "executorBindingsRoot must match the recomputed root over the executor binding leaves",
    ),
  );
  const tamperedDefault = repin({
    ...artifact,
    executorBindings: artifact.executorBindings.map((binding) =>
      binding.kind === 0
        ? { ...binding, supplierId: onchainSupplierId("tampered-supplier") }
        : binding,
    ),
  });
  assert.ok(
    validateOnchainHookPlanArtifact(tamperedDefault).some((issue) =>
      issue.includes(
        "must commit the supplierId derived from the route's executor.supplierID",
      ),
    ),
  );
});
