import assert from "node:assert/strict";
import test from "node:test";
import {
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
  EMPTY_MERKLE_ROOT,
  hashOnchainPlanPayload,
  HOOK_FLAG_DYNAMIC_EXECUTOR,
  HOOK_FLAG_EMIT_READY,
  HookPlanCompilationError,
  keccak256Hex,
  supplierBindingLeaf,
  supplierBindingProof,
  supplierBindingsRootOf,
  supplierIdFromUuid,
  toSolidityRegisterPlanArgs,
  uuidFromSupplierId,
  validateOnchainHookPlanArtifact,
  verifyMerkleProof,
  type OnchainHookPlanArtifact,
  type ZhixuDefinition,
} from "../src/index.js";
import type { StageSupplierBinding } from "../src/types/index.js";

const SUPPLIER_MAIN = "5f0b1e2a-7c9d-4e1f-9a2b-000000000021";
const SUPPLIER_DEAL = "5f0b1e2a-7c9d-4e1f-9a2b-000000000022";
const SUPPLIER_BIRTH = "5f0b1e2a-7c9d-4e1f-9a2b-000000000023";
const SUPPLIER_CANDIDATE = "5f0b1e2a-7c9d-4e1f-9a2b-000000000024";
const SUPPLIER_DYNAMIC_ANCHOR = "5f0b1e2a-7c9d-4e1f-9a2b-000000000025";
const SUPPLIER_GATE = "5f0b1e2a-7c9d-4e1f-9a2b-000000000026";

function staticZhixu(mainSupplierID = SUPPLIER_MAIN): ZhixuDefinition {
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
            supplierID: SUPPLIER_DEAL,
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
          executor: { supplierType: "organization", supplierID: SUPPLIER_BIRTH },
        },
        {
          name: "deal",
          source: "trading",
          receiveSignals: { PLACE: "trading::deal.kickoff" },
          sendSignals: [{ name: "closed" }, { name: "kickoff" }],
          executor: { supplierType: "organization", supplierID: SUPPLIER_DEAL },
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
          executor: { supplierType: "organization", supplierID: SUPPLIER_GATE },
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
          executor: {
            supplierType: "organization",
            supplierID: SUPPLIER_DYNAMIC_ANCHOR,
          },
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
  bindings: readonly StageSupplierBinding[],
  stageIdentifier: string,
  kind: 0 | 1,
): readonly StageSupplierBinding[] {
  return bindings.filter(
    (binding) =>
      binding.stageIdentifier === stageIdentifier && binding.kind === kind,
  );
}

test("default bindings decode each plain executor supplierID UUID and commit to the root", () => {
  const artifact = compileZhixuOnchainHookPlan(staticZhixu());

  assert.equal(artifact.supplierBindings.length, 2);
  assert.deepEqual(
    bindingOf(artifact.supplierBindings, "main", 0).map((binding) => ({
      stageId: binding.stageId,
      supplierID: binding.supplierID,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
    [
      {
        stageId: keccak256Hex("main"),
        supplierID: SUPPLIER_MAIN,
        supplierId: supplierIdFromUuid(SUPPLIER_MAIN),
        kind: 0,
      },
    ],
  );
  assert.deepEqual(
    bindingOf(artifact.supplierBindings, "deal", 0).map((binding) => ({
      stageId: binding.stageId,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
    [
      {
        stageId: keccak256Hex("deal"),
        supplierId: supplierIdFromUuid(SUPPLIER_DEAL),
        kind: 0,
      },
    ],
  );
  assert.equal(
    artifact.supplierBindingsRoot,
    supplierBindingsRootOf(artifact.supplierBindings),
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(artifact), []);

  const defaultBinding = bindingOf(artifact.supplierBindings, "main", 0)[0]!;
  assert.equal(uuidFromSupplierId(defaultBinding.supplierId), SUPPLIER_MAIN);
  assert.equal(
    defaultBinding.supplierId,
    `0x${"00".repeat(16)}${SUPPLIER_MAIN.replaceAll("-", "")}`,
  );
  assert.equal(
    uuidFromSupplierId(supplierIdFromUuid(SUPPLIER_MAIN.toUpperCase())),
    SUPPLIER_MAIN,
    "UUID decode normalizes to lowercase canonical form",
  );
  assert.equal(
    supplierIdFromUuid("6BA7B810-9DAD-11D1-80B4-00C04FD430C8"),
    "0x000000000000000000000000000000006ba7b8109dad11d180b400c04fd430c8",
    "UUID decode matches the supplier registry mint shape (low 16 bytes, big-endian, no hash)",
  );
  assert.equal(
    uuidFromSupplierId(
      "0x000000000000000000000000000000006ba7b8109dad11d180b400c04fd430c8",
    ),
    "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  );
  const proof = supplierBindingProof(
    artifact.supplierBindings,
    defaultBinding.stageId,
    defaultBinding.supplierId,
    0,
  );
  assert.ok(proof, "every committed default binding must be provable");
  assert.equal(
    verifyMerkleProof(
      artifact.supplierBindingsRoot,
      supplierBindingLeaf(
        defaultBinding.stageId,
        defaultBinding.supplierId,
        defaultBinding.kind,
      ),
      proof,
    ),
    true,
  );
});

test("candidate input carries a supplierID UUID and adds a kind=1 leaf beside the default binding", () => {
  const bare = compileZhixuOnchainHookPlan(staticZhixu());
  const withCandidate = compileZhixuOnchainHookPlan(staticZhixu(), [
    { stageIdentifier: "main", supplierID: SUPPLIER_CANDIDATE },
  ]);

  assert.deepEqual(
    bindingOf(withCandidate.supplierBindings, "main", 1).map((binding) => ({
      stageId: binding.stageId,
      supplierID: binding.supplierID,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
    [
      {
        stageId: keccak256Hex("main"),
        supplierID: SUPPLIER_CANDIDATE,
        supplierId: supplierIdFromUuid(SUPPLIER_CANDIDATE),
        kind: 1,
      },
    ],
  );
  assert.equal(bindingOf(withCandidate.supplierBindings, "main", 0).length, 1);
  assert.equal(
    withCandidate.supplierBindingsRoot,
    supplierBindingsRootOf(withCandidate.supplierBindings),
  );
  assert.notEqual(withCandidate.supplierBindingsRoot, bare.supplierBindingsRoot);
  assert.notEqual(withCandidate.planHash, bare.planHash);
  assert.deepEqual(validateOnchainHookPlanArtifact(withCandidate), []);

  const args = toSolidityRegisterPlanArgs(withCandidate);
  assert.deepEqual(
    args.supplierBindings,
    withCandidate.supplierBindings.map((binding) => ({
      stageId: binding.stageId,
      supplierId: binding.supplierId,
      kind: binding.kind,
    })),
  );
  assert.equal(args.supplierBindingsRoot, withCandidate.supplierBindingsRoot);
  assert.notEqual(args.planHash, toSolidityRegisterPlanArgs(bare).planHash);

  const candidateBinding = bindingOf(withCandidate.supplierBindings, "main", 1)[0]!;
  const candidateProof = supplierBindingProof(
    withCandidate.supplierBindings,
    candidateBinding.stageId,
    candidateBinding.supplierId,
    1,
  );
  assert.ok(candidateProof, "candidate patch proofs must be derivable from the committed set");
});

test("register args carry the binding set, root, and dynamic hook flag end-to-end", () => {
  const args = compileZhixuRegisterPlanArgs(staticZhixu(), [
    { stageIdentifier: "deal", supplierID: SUPPLIER_CANDIDATE },
  ]);
  assert.equal(args.schemaVersion, "uvp.onchainHookPlan.v8");
  assert.equal(args.supplierBindings.length, 3);
  assert.equal(
    args.supplierBindingsRoot,
    supplierBindingsRootOf(args.supplierBindings),
  );
  for (const binding of args.supplierBindings) {
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

test("dynamic stage binds no plan supplier and materializes without a route", () => {
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
    artifact.supplierBindings.map((binding) => binding.stageIdentifier),
    ["anchor"],
    "dynamic stages carry no default or candidate binding",
  );
  assert.equal(
    artifact.supplierBindingsRoot,
    supplierBindingsRootOf(artifact.supplierBindings),
  );
});

test("dynamic, candidate, birth, and dock supplier bindings are mutually exclusive", () => {
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(dynamicZhixu(), [
        { stageIdentifier: "main", supplierID: SUPPLIER_CANDIDATE },
      ]),
    (error: unknown) => isCompilationIssue(error, "is a dynamic stage"),
  );
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(birthZhixu(), [
        { stageIdentifier: "main", supplierID: SUPPLIER_CANDIDATE },
      ]),
    (error: unknown) => isCompilationIssue(error, "birth-stage suppliers are immutable"),
  );
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(dockZhixu(), [
        { stageIdentifier: "accept", supplierID: SUPPLIER_CANDIDATE },
      ]),
    (error: unknown) => isCompilationIssue(error, "is a dock stage"),
  );
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(staticZhixu(), [
        { stageIdentifier: "ghost", supplierID: SUPPLIER_CANDIDATE },
      ]),
    (error: unknown) => isCompilationIssue(error, "not a stage declared in this plan"),
  );
  for (const supplierID of ["   ", ""]) {
    assert.throws(
      () =>
        compileZhixuOnchainHookPlan(staticZhixu(), [
          { stageIdentifier: "main", supplierID },
        ]),
      (error: unknown) => isCompilationIssue(error, "non-empty supplierID UUID"),
      `supplierID=${JSON.stringify(supplierID)} must be rejected as empty`,
    );
  }
  for (const supplierID of ["candidate-org", "5f0b1e2a-7c9d-4e1f-9a2b-00000000002"]) {
    assert.throws(
      () =>
        compileZhixuOnchainHookPlan(staticZhixu(), [
          { stageIdentifier: "main", supplierID },
        ]),
      (error: unknown) => isCompilationIssue(error, "canonical 8-4-4-4-12 UUID"),
      `supplierID=${JSON.stringify(supplierID)} must be rejected as a non-UUID`,
    );
  }

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
      issue.includes("InconsistentDynamicSupplierFlag"),
    ),
    "mixing dynamic and non-dynamic hooks of one stage must be rejected",
  );

  const withRoute = repin({
    ...artifact,
    supplierRoutes: [
      ...artifact.supplierRoutes,
      {
        routeId: keccak256Hex("main#supplierRoute"),
        stageId: keccak256Hex("main"),
        stageIdentifier: "main",
        supplierType: "organization",
        supplierID: SUPPLIER_CANDIDATE,
        supplierHash: keccak256Hex("main-supplier"),
        resourcesHash: keccak256Hex("main-resources"),
        routeHash: keccak256Hex("main-route"),
      },
    ],
  });
  assert.ok(
    validateOnchainHookPlanArtifact(withRoute).some((issue) =>
      issue.includes("dynamic stage main must not carry a supplier route"),
    ),
    "a dynamic stage must not be given a plan-level route",
  );
});

test("duplicate bindings are rejected at compile time instead of absorbed by the Merkle tree", () => {
  assert.throws(
    () =>
      compileZhixuOnchainHookPlan(staticZhixu(), [
        { stageIdentifier: "main", supplierID: SUPPLIER_CANDIDATE },
        { stageIdentifier: "main", supplierID: SUPPLIER_CANDIDATE },
      ]),
    (error: unknown) =>
      isCompilationIssue(error, "duplicate supplier binding") &&
      isCompilationIssue(error, "DuplicateSupplierBinding"),
  );
});

test("the binding cap mirrors the contract's MAX_SUPPLIER_BINDINGS bound", () => {
  const candidates = Array.from({ length: 257 }, (_, index) => ({
    stageIdentifier: "main",
    supplierID: `5f0b1e2a-7c9d-4e1f-9a2b-${index.toString(16).padStart(12, "0")}`,
  }));
  assert.throws(
    () => compileZhixuOnchainHookPlan(staticZhixu(), candidates),
    (error: unknown) => isCompilationIssue(error, "TooManySupplierBindings"),
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
  assert.deepEqual(emptyArtifact.supplierBindings, []);
  assert.equal(emptyArtifact.supplierBindingsRoot, EMPTY_MERKLE_ROOT);
  assert.deepEqual(validateOnchainHookPlanArtifact(emptyArtifact), []);

  const artifact = compileZhixuOnchainHookPlan(staticZhixu());
  const tamperedRoot = repin({
    ...artifact,
    supplierBindingsRoot: keccak256Hex("tampered binding root"),
  });
  assert.ok(
    validateOnchainHookPlanArtifact(tamperedRoot).includes(
      "supplierBindingsRoot must match the recomputed root over the supplier binding leaves",
    ),
  );
  const tamperedDefault = repin({
    ...artifact,
    supplierBindings: artifact.supplierBindings.map((binding) =>
      binding.kind === 0
        ? {
            ...binding,
            supplierID: SUPPLIER_CANDIDATE,
            supplierId: supplierIdFromUuid(SUPPLIER_CANDIDATE),
          }
        : binding,
    ),
  });
  assert.ok(
    validateOnchainHookPlanArtifact(tamperedDefault).some((issue) =>
      issue.includes(
        "must commit the supplier UUID of the route's executor.supplierID",
      ),
    ),
  );
});
