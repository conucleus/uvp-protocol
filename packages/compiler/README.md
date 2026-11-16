# compiler

Zhixu compiler for deterministic EVM state-machine artifacts.

This module compiles UVP DSL directly into deterministic on-chain artifacts.
The public protocol output is `OnchainHookPlanArtifact` and the registration
args for the two-step `UVPStateMachine.commitPlan` + `finalizePlan` flow.
`HookPlanArtifact` is compiler-internal IR (`uvp.hookPlan.v8`); the public
`OnchainHookPlanArtifact` schema is `uvp.onchainHookPlan.v8`. The package
version is `0.3.0`.

## Inputs

- `apiVersion: uvp/v0`, `kind: Zhixu` YAML/JSON definitions;
- Hook DSL expressions under `receiveSignals`, plus each stage's optional
  birth set: `sendSignals` entries marked `trigger: true` birth an order when
  submitted with an empty order id. Trigger sets are fixed at compile time and
  enter the definition identity;
- the neutral `analyze` result from uvp-core (`uvp.zhixuAnalysis.v4`): shared
  definition validation (including the chain target's trigger-set validation
  and stage materialization gate), parsed hooks/AST, the normalized per-stage
  trigger names, signal capabilities, composed admissions, and each stage's
  supplier config (`null` for a dynamic stage) — the single source for DSL
  shape and admission validation;
- per-stage supplier intent: a plain executor block (`supplierType`
  `individual`/`organization` + `supplierID`) becomes a default supplier
  binding; a stage without an executor block is a dynamic stage whose supplier
  is assigned per order at runtime;
- optional supplier candidates: `SupplierCandidateInput` =
  `{ stageIdentifier, supplierID }` with `supplierID` a canonical UUID (a bare
  address is not accepted). Candidates become candidate supplier bindings and
  are the only per-order patch targets for candidate stages;
- dock stages declare `executor: {supplierType: dock}`; the compiler only
  decorates their hooks, it does not compile dock routing or dock bindings;
- target platform metadata, currently `platform.type=blockchain`,
  `platform.provider=eth`, and optional `platform.network` such as `base` for
  this track.

Dock documents are a separate static object compiled by uvp-core
`analyze_dock_json` into `uvp.dock.v1`; this package owns the checked-in
boundary type and validation for that artifact (`src/dock-artifact.ts`), not
the Dock DSL validation.

## Outputs

- EVM-facing `OnchainHookPlanArtifact`;
- Solidity registration args for the two-step `UVPStateMachine.commitPlan` +
  `finalizePlan` flow, including the `StageSupplierBinding[]` list and
  `supplierBindingsRoot`;
- deterministic `planId`, `planHash`, source `zhixuId` and `sourcePlanHash`,
  plus the `hooksHash` / `capabilitiesRoot` / `supplierBindingsRoot` /
  `artifactHash` tuple of the Solidity registration args;
- stable hook, stage, source, signal, dependency, and route ids;
- the plan-level `triggers[]` enumeration of the order-trigger hooks (see
  Triggers);
- on-chain selector bindings for order-level execution authority,
  `HOOK_FLAG_DOCK_EXECUTOR` on every hook of a dock stage, and
  `HOOK_FLAG_DYNAMIC_EXECUTOR` on every hook of a dynamic stage;
- golden fixtures for compiler, contract, uvp-client, and replay tests;
- cross-language commitment golden vectors (`uid` / `planHash` / `hooksHash`)
  live in the sibling `uvp-core` checkout at
  `fixtures/commitments/golden-vectors.v1.json` and regenerate via
  `pnpm --filter @uvp-eth/compiler generate:commitment-golden-vectors`
  (or `make golden-vectors` from the `uvp-core` root). TS tests read them via
  `test/commitment-golden.ts`; Rust `uvp-ir` (uid cells) and Foundry
  `CommitmentGoldenVectors.t.sol` (hooksHash / runtime planHash cells) consume
  the same file.

## Supplier identity and bindings

- `supplierId` is the on-chain supplier identity: a UUID carried in the low 16
  bytes of a `bytes32` (high 16 bytes zero). The definition writes
  `executor.supplierID` as a canonical 36-character lowercase UUID; the
  compiler only decodes that UUID and never hashes it.
  `supplierIdFromUuid` / `uuidFromSupplierId` in
  `src/onchain/supplier-bindings.ts` are the single owner of that encoding;
  imports flow through `@uvp-eth/compiler/browser` and are re-exported by
  `@uvp-eth/protocol-bindings`; do not re-implement it elsewhere.
- `StageSupplierBinding` is `{ stageIdentifier, stageId, supplierID, supplierId,
  kind }` with kind `0` (default) / `1` (candidate). Default bindings are
  auto-derived from static supplier routes; candidate bindings come from
  `SupplierCandidateInput[]`. The artifact carries both the resolved
  `supplierBindings` list and its `supplierBindingsRoot`.
- Binding leaf: `keccak256(abi.encodePacked(keccak256("UVP_SUPPLIER_BINDING_V1"),
  stageId, supplierId, kind))`; the root is the sorted-pairing Merkle root over
  the leaves (empty plan pins `keccak256("")`). `supplierBindingLeaf` /
  `supplierBindingProof` / `supplierBindingsRootOf` are the single-source
  helpers (also exported from `/browser`).
- Mutual exclusions: dock and dynamic stages never carry plan bindings or
  supplier routes; birth stages carry a default binding but no candidate
  binding; a dynamic stage has no plan-default supplier at all.
- `MAX_SUPPLIER_BINDINGS` is 256 (the contract cap).

## MVP Constraint

The supported compiler surface is the chain artifact path:

- `receiveSignals` hook parsing;
- `trigger` signal lowering into order-trigger hooks;
- `selectedStages` binding validation;
- static/dynamic supplier topology validation;
- supplier binding derivation and root commitment;
- dock stage decoration (`HOOK_FLAG_DOCK_EXECUTOR`, no plan-level route);
- dynamic stage decoration (`HOOK_FLAG_DYNAMIC_EXECUTOR`, EMIT_READY receive
  hook, no plan-level route or binding).

Supplier topology follows the UVP closure rule: a stage without an
`executor.supplierID` (a dynamic stage) passes the closure rule only when it
can be reached through `selectedStages` from a stage that does name a fixed
supplier. Selector loops or selector chains with no fixed supplier anchor are
rejected. On top of the closure rule, the materialization gate is evaluated by
uvp-core `analyze` (shared validation for the chain target): every declared
stage must compile at least one hook with a materialization bit (trigger or an
EMIT_READY receive hook). A dynamic stage materializes through its own
EMIT_READY receive hooks — being reachable is not itself a materialization
path — so a declared zero-hook stage is rejected; the dynamic shape itself is
accepted and must not be rejected for lacking an executor block. This package
consumes that result; `src/onchain/validate/hooks.ts` only re-asserts the
compiled hook shape at the on-chain artifact boundary (a boundary check, not a
second implementation of the definition-level gate). The contract `commitPlan`
check is the separate registration boundary for hand-built plans.

The hook_plan shell lowering itself (one order-trigger hook per analyze-derived
trigger entry, order-trigger/emit-ready/dock-executor/dynamic-executor
decoration, `dependencyIndex`, `supplierRoutes`, `supplierBindings`,
`selectedStageBindings`, and shell assembly) lives in
`src/hook-plan/lower.ts`. Trigger-set validation (membership/duplicates/static
executor and the materialization gate) is not re-implemented here: it is part
of uvp-core `analyze`'s shared validation, and `signalCapabilities`/EvmStrict
admissions are consumed from the same analysis. This package consumes analyze
issues and parsed ASTs verbatim and must not re-implement shape/dock/admission/
DSL validation or rewrite its error text.

A dock stage never enters `supplierRoutes` or supplier bindings: its supplier
is selected once through the stage supplier patch (dkid), so the compiler
rejects a plan-level route or binding pointing at it. The same applies to a
dynamic stage: its supplier is assigned per order through the stage supplier
patch (before the stage's first signal), never at plan time.

Do not execute hooks in this module. Runtime evaluation belongs in
`hook-core`/`statemachine`.

## Future Chain Targets

`ZhixuDefinition.spec.platform` is intentionally open. Do not narrow
`provider`, `network`, `version`, or `params` to EVM-only values just because the
current public artifact is EVM-facing. The roadmap for Solana or any other
future target lives in `../../../docs/future-chain-target-roadmap.md`.

Until that roadmap's gates are satisfied, non-EVM platform metadata is a schema
reservation, not a supported runtime target.

## Local Package

This directory is intentionally self-contained. It does not import the Go UVP
repository and it does not rely on the sibling `uvp-deploy` repository.

```bash
pnpm install
pnpm --filter @uvp-eth/compiler test
pnpm --filter @uvp-eth/compiler typecheck
```

## Source

- `src/types/`: public TypeScript interfaces for Zhixu inputs, compact
  on-chain hook plans, supplier bindings, and Solidity registration args.
- `src/hook-plan.ts`: deterministic Zhixu-to-HookPlan internal IR compiler
  (consumes the neutral uvp-core `analyze` result, lowers the shell, then
  commits plan identity and plan hash).
- `src/hook-plan/assemble.ts`: planId / planHash commitment layer and the
  closed-field hook_plan artifact payload.
- `src/hook-plan/lower.ts`: chain hook_plan lowering implemented by this package —
  one synthesized order-trigger hook per analyze-reported trigger signal,
  `orderTriggerKind`/`emitReady`/dock-executor/dynamic-executor/route
  decoration, dependency index, supplier routes, and supplier bindings; it
  consumes uvp-core `analyze` (shared validation, including
  trigger-set/materialization checks, plus parsed hooks/trigger
  names/executor configs/capabilities/admissions) and does not re-implement
  shape/dock/admission/DSL validation.
- `src/dock-artifact.ts`: `uvp.dock.v1` boundary type and validation for the
  uvp-core `analyzeDock` output (resolved ids plus each output's Hook DSL
  `ast`/`dependencies`/`atoms`).
- `src/identity.ts`: content-derived `zx-<32hex>` definition uid and display
  stripping.
- `src/merkle.ts`: the single Merkle/word hashing implementation used by the
  capability, supplier-binding, and file-writer trees.
- `src/onchain/`: public Zhixu-to-on-chain artifact compiler and Solidity
  registration input builder (`compile.ts` pipeline, `validate/` boundary
  checks, `canonical/` ordering, `hash/` commitments,
  `solidity/registration.ts` calldata assembly,
  `onchain/capabilities-root.ts` — the authoritative capability-tree
  implementation, `onchain/supplier-bindings.ts` — the authoritative
  UUID-SID encoding and supplier-binding-tree implementation, and `onchain/triggers.ts` — the
  single trigger-enumeration derivation shared by the compile pipeline and the
  artifact boundary).
- `src/zhixu-loader.ts`: YAML/JSON loader for `apiVersion: uvp/v0`,
  `kind: Zhixu` definitions.
- `src/hash.ts`: viem-backed Keccak-256 boundary hashing for EVM-compatible
  test vectors.
- `fixtures/uvp-update-zhixu-v2.yaml`: UVP `0.1.3` self-bootstrap update
  fixture, normalized for the EVM track with `platform.type=blockchain`,
  `platform.provider=eth`, and `platform.network=base`.
- `test/hash.test.ts`: hash vector and canonicalization tests.
- `test/hook-plan.test.ts`: internal IR hash stability, dependency index,
  trigger-hook lowering, dynamic decoration, and selected-stage tests.

## Public Output

Use these root-package entrypoints:

- `compileZhixuOnchainHookPlan(zhixuDefinition, supplierCandidates?)`;
- `compileZhixuRegisterPlanArgs(zhixuDefinition, supplierCandidates?)`;
- `toSolidityRegisterPlanArgs(onchainHookPlanArtifact)`.

`supplierCandidates` is `SupplierCandidateInput[]` — `{ stageIdentifier, supplierID }`
with a canonical UUID `supplierID`. It is not an address list and never
overrides the UUID encoding.

`compileZhixuOnchainHookPlan(zhixu)` emits schema
`uvp.onchainHookPlan.v8`. It:

- emits stable `planId` and `planHash`;
- carries target `platform` from Zhixu YAML as a protocol field
  (`type=blockchain`, `provider=eth`, optional `network=base` for the EVM
  track; omitted `network` keeps the current default path);
- replaces hook expressions with postfix instruction arrays;
- enumerates every order-trigger hook in `triggers[]`, one entry per hook with
  `orderTriggerKind` `"trigger"` (see Triggers);
- indexes dependencies by packed signal key;
- exposes supplier routes through route references; dock and dynamic stages
  carry no route;
- decorates every hook of a `supplierType: dock` stage with
  `dockExecutor: true` (Solidity `HOOK_FLAG_DOCK_EXECUTOR`) and every hook of
  an executor-less dynamic stage with `dynamicExecutor: true` (Solidity
  `HOOK_FLAG_DYNAMIC_EXECUTOR`);
- derives `supplierBindings` (default bindings from supplier routes, candidate
  bindings from `supplierCandidates` input) and commits
  `supplierBindingsRoot`;
- compiles `selectedStageBindings` into sorted `selectorBindings` for
  `StageSelectorBinding` registration;
- lowers `spec.stages[].fileWriters` into a sorted `stageFileWriters` section
  (one `(targetStageId, writerStageId)` leaf per declared writer stage; self is
  implicit and never a leaf);
- commits the three capability tables — `selectorBindings`,
  `signalCapabilities`, and `stageFileWriters` — into a single
  `capabilitiesRoot` (domain-separated leaves mixed into one sorted paired
  Merkle tree; empty tables pin `keccak256("")`), and includes the tables in the
  canonical on-chain `planHash`;
- compiles each trigger signal's `validWhen` into the `admissions` section as a
  standalone CompactHook entry (flag 8) so the birth path can evaluate it in the
  empty-order context.

Stable ids use raw Keccak-256:

- `hookId = keccak256(stageIdentifier#hookName)`;
- `stageId = keccak256(stageIdentifier)`;
- `sourceId = keccak256(source)`;
- `signalId = keccak256(stage.signal)`;
- `signalKey = keccak256(abi.encodePacked(sourceId, signalId))`;
- `selectorStageId` / `targetStageId = keccak256(stageIdentifier)`.

`validateOnchainHookPlanArtifact(value)` checks the compact artifact shape,
recomputes ids, validates instruction stack shape, verifies `dependencyIndex`,
recomputes `supplierBindingsRoot`, and verifies `planHash`.
`toSolidityRegisterPlanArgs(value)` strips audit labels and returns a
deterministic data shape for the Solidity registration ABI (it includes the
resolved `supplierBindings`, never a raw-address candidate list).

## Triggers

`OnchainHookPlanArtifact.triggers` enumerates every order-trigger hook in
`compiledHooks`, one entry per hook with `orderTriggerKind !== "none"`, in the
artifact's canonical hook order (`stageIdentifier`, then `hookName`, then
`hookId`):

| field | meaning |
|---|---|
| `hookId` | `keccak256(stageIdentifier#hookName)`; the value the contract receives as `triggerHookId` |
| `stageIdentifier` / `stageId` | owning stage (`stageId = keccak256(stageIdentifier)`) |
| `hookName` | hook-local name; a trigger hook is named after its trigger signal |
| `orderTriggerKind` | `"trigger"` for a trigger-signal birth line |
| `source` / `signalName` | the birth fact's source class and two-part `<stageIdentifier>.<signal>` name |
| `sourceId` / `signalId` | `keccak256(source)` / `keccak256(stage.signal)` |

Each `sendSignals[]` entry marked `trigger: true` lowers to exactly one hook
with `orderTriggerKind: "trigger"`, `emitReady: true`, a single `SIGNAL`
instruction, and one positive dependency on
`<source>::<stageIdentifier>.<signal>`; that dependency's
`(sourceId, signalId)` is the birth fact. Trigger stages require a static
non-dock executor, and their ordinary `receiveSignals` hooks keep
`orderTriggerKind: "none"` and coexist with the trigger hooks. A plan may
mark several send signals and several stages as triggers.

A trigger signal's `validWhen` is compiled into the artifact's `admissions`
section as its own CompactHook entry (`flags = HOOK_FLAG_ADMISSION`): a birth
submission runs that admission check in the empty-order context before the
order is created, and the contract reverts `SignalAdmissionRejected` when it
fails.

`triggers` is a derived read face over committed hooks, not a commitment of its
own: `hashOnchainPlanPayload` excludes it, so the `planHash` covers exactly the
submitted payload minus this enumeration, and the Solidity registration args
carry no trigger field. `assertOnchainHookPlanArtifact` recomputes the
enumeration from `compiledHooks` and rejects a missing, surplus, reordered, or
tampered entry. Hook identity — including the trigger bit — stays inside
`hooksHash`.

## Solidity Alignment

The current state-machine alignment is `toSolidityRegisterPlanArgs()`:

- `planId` and `planHash` are the state-machine plan identity; the plan runtime
  hash domain is `uvp.plan.runtime.v7` and covers `hooksHash`,
  `capabilitiesRoot`, and `supplierBindingsRoot`;
- `hooks` map to `UVPStateMachine.CompactHook`; hook flags are
  `ORDER_TRIGGER_MINT` for `orderTriggerKind: "trigger"`, `EMIT_READY`,
  `HOOK_FLAG_ADMISSION` for admission entries, `HOOK_FLAG_DOCK_EXECUTOR` for
  dock-stage receive hooks, and `HOOK_FLAG_DYNAMIC_EXECUTOR` for dynamic-stage
  receive hooks;
- a `"trigger"` entry in `triggers[]` is the outside-birth entry: the caller
  passes its `hookId` as `triggerHookId`, plus `stageId`, `sourceId`, and
  `signalId`, to `triggerOrderFromOutsideFor`;
- `supplierBindings` map to `UVPStateMachine.StageSupplierBinding` and
  `supplierBindingsRoot` is signed inside `PlanCommit`; `commitPlan` takes
  `(commit, hooks, bindings, signature)`;
- `selectorBindings` map to `UVPStateMachine.StageSelectorBinding` and
  `stageFileWriters` to `UVPPlanMetadataModule.fileWriterLeaf`;
- `capabilitiesRoot` is the domain-separated leaf-mixed Merkle root over
  `selectorBindings` + `signalCapabilities` + `stageFileWriters`
  (`src/onchain/capabilities-root.ts` is the authoritative implementation,
  byte-identical to the `UVPPlanMetadataModule` leaf formulas). The chain
  stores only the root: `finalizePlan` takes just the `planId`, so
  registration cost is decoupled from table size, and membership is verified
  off-chain by recomputing the leaf from its fields and carrying
  `signalCapabilityProof` / `selectorBindingProof` / `fileWriterProof` through
  `verifyMerkleProof`. Empty tables pin `keccak256("")`;
- `instructions` map to compact `Signal`, `Not`, `And`, `Or`, and `Delay`
  operations;
- `dependencyKeys` must match `UVPStateMachine.signalKey(sourceId, signalId)`;
- supplier route metadata stays off chain and is used by Product APIs and
  `uvp-client` for routing;
- there is no order-level submitter authorization construction in the compiler:
  signal submission authority is the source stage's assigned supplier account,
  resolved on chain from the supplier registry (SID active); the artifact only
  commits the default/candidate supplier bindings and the dynamic/stage shape.

## Overlay Hashing

Supplier identity encoding, supplier binding leaves/roots, stage supplier
patch hashing, and the file patch canonical digest live in this package
(supplier bindings) and `@uvp-eth/protocol-bindings` (patch/selection typed
data). The compiler owns selector binding, file-writer leaf, supplier-binding
tree, and on-chain HookPlan artifact hashing only; file content and handles
stay outside compiler artifacts.
