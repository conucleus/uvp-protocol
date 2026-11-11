# compiler

Zhixu compiler for deterministic EVM state-machine artifacts.

This module compiles UVP DSL directly into deterministic on-chain artifacts.
The public protocol output is `OnchainHookPlanArtifact` and the registration
args for the two-step `UVPStateMachine.commitPlan` + `finalizePlan` flow.
`HookPlanArtifact` is compiler-internal IR (`uvp.hookPlan.v5`); the public
`OnchainHookPlanArtifact` schema is `uvp.onchainHookPlan.v5`.

## Inputs

- `apiVersion: uvp/v0`, `kind: Zhixu` YAML/JSON definitions;
- Hook DSL expressions under `receiveSignals`, plus each stage's optional
  `trigger` signal set: a subset of the stage's `sendSignals` that births an
  order when submitted with an empty order id. Trigger sets are fixed
  at compile time and enter the definition identity;
- the neutral `analyze` result from uvp-core (`uvp.zhixuAnalysis.v2`): shared
  definition validation (including the chain target's trigger-set validation
  and stage materialization gate), parsed hooks/AST, the normalized per-stage
  trigger names, signal capabilities, composed admissions, and dock state — the
  single source for DSL shape/dock/admission validation;
- selected-stage executor bindings and supplier `signalMap` data;
- the target-side `spec.dockInterface` and, for a `supplierType=zhixu`
  route, a `uvp.dock.resolution.v2` resolution manifest (chain-track
  publishing face: TS validates the content addressing and derives the
  neutral name catalog the uvp-core linker consumes);
- target platform metadata, currently `platform.type=blockchain`,
  `platform.provider=eth`, and optional `platform.network` such as `base` for
  this track.

## Outputs

- EVM-facing `OnchainHookPlanArtifact`;
- Solidity registration args for the two-step `UVPStateMachine.commitPlan` +
  `finalizePlan` flow;
- deterministic `planId`, `planHash`, source `zhixuId` and `sourcePlanHash`,
  plus the `hooksHash` / `capabilitiesRoot` / `artifactHash` tuple of the
  Solidity registration args and the committed `dockRoutesRoot` /
  `dockInterfaceRoot`;
- stable hook, stage, source, signal, dependency, and route ids;
- the plan-level `triggers[]` enumeration of the order-trigger hooks (see
  Triggers);
- on-chain selector bindings for order-level executor overlay authority;
- golden fixtures for compiler, contract, uvp-client, and replay tests.
  Dock commitments are computed by this package (the chain-track hash-layer
  authority; frozen word layout in `docs/dock-word-layout.md`), and the dock
  golden manifest regenerates via
  `pnpm --filter @uvp-eth/compiler generate:dock-fixtures`.
- cross-language commitment golden vectors (`uid` / `planHash` / `hooksHash`)
  live in the sibling `uvp-core` checkout at
  `fixtures/commitments/golden-vectors.v1.json` and regenerate via
  `pnpm --filter @uvp-eth/compiler generate:commitment-golden-vectors`
  (or `make golden-vectors` from the `uvp-core` root). TS tests read them via
  `test/commitment-golden.ts`; Rust `uvp-ir` (uid cells) and Foundry
  `CommitmentGoldenVectors.t.sol` (hooksHash / runtime planHash cells) consume
  the same file.

## MVP Constraint

The supported compiler surface is the chain artifact path:

- `receiveSignals` hook parsing;
- `trigger` signal lowering into order-trigger hooks;
- `selectedStages` binding validation;
- static executor route extraction;
- `supplierType=zhixu` `signalMap` compilation and same-source validation.

Executor topology follows the UVP closure rule: a stage without a
fixed `executor.supplierID` passes the closure rule only when it can be reached
through `selectedStages` from a stage that does name a fixed executor. Selector
loops or selector chains with no fixed executor anchor are rejected. On top of
the closure rule, the materialization gate is evaluated by uvp-core `analyze`
(shared validation for the chain target): every declared stage must compile at
least one hook with a materialization bit (trigger/dock order trigger or a
static executor's EMIT_READY receive hook) — an executor-less selected stage is
therefore rejected even when it is reachable, because on-chain stages
materialize only through their own hooks. This package consumes that result;
`src/onchain/validate/hooks.ts` only re-asserts the compiled hook shape at the
on-chain artifact boundary (a boundary check, not a second implementation of the
definition-level gate). The contract `commitPlan` check is the separate
registration boundary for hand-built plans.

The hook_plan shell lowering itself (one order-trigger hook per normalized
`stage.triggers[]` entry, order-trigger/emit-ready/route decoration,
`dependencyIndex`, `executorRoutes`, `selectedStageBindings`, and shell
assembly) lives in `src/hook-plan/lower.ts`. Trigger-set validation
(membership/duplicates/static executor and the materialization gate) is not
re-implemented here: it is part of uvp-core `analyze`'s shared validation, and
`signalCapabilities`/EvmStrict admissions are consumed from the same analysis.
This package consumes analyze issues and parsed ASTs verbatim and must not
re-implement shape/dock/admission/DSL validation or rewrite its error text.

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
  on-chain hook plans, and Solidity registration args.
- `src/hook-plan.ts`: deterministic Zhixu-to-HookPlan internal IR compiler
  (assembles the shell from the neutral uvp-core `analyze` result and the
  lowering module, then commits dock/plan hashes).
- `src/hook-plan/lower.ts`: chain hook_plan lowering implemented by this package —
  one synthesized order-trigger hook per analyze-reported trigger signal,
  `orderTriggerKind`/`emitReady`/route decoration, dependency index, and
  executor routes; it consumes uvp-core `analyze` (shared validation, including
  trigger-set/materialization checks, plus parsed hooks/trigger names/
  capabilities/admissions) and does not re-implement shape/dock/admission/DSL
  validation.
- `src/onchain/`: public Zhixu-to-on-chain artifact compiler and Solidity
  registration input builder (`compile.ts` pipeline, `validate/` boundary
  checks, `canonical/` ordering, `hash/` commitments,
  `solidity/registration.ts` calldata assembly,
  `onchain/capabilities-root.ts` — the authoritative capability-tree
  implementation, and `onchain/triggers.ts` — the single trigger-enumeration
  derivation shared by the compile pipeline and the artifact boundary).
- `src/zhixu-loader.ts`: YAML/JSON loader for `apiVersion: uvp/v0`,
  `kind: Zhixu` definitions.
- `src/canonical.ts`: canonical JSON normalization used before hashing.
- `src/hash.ts`: viem-backed Keccak-256 boundary hashing for EVM-compatible
  test vectors.
- `fixtures/uvp-update-zhixu-v2.yaml`: UVP `0.1.3` self-bootstrap update
  fixture, normalized for the EVM track with `platform.type=blockchain`,
  `platform.provider=eth`, and `platform.network=base`.
- `test/hash.test.ts`: hash vector and canonicalization tests.
- `test/hook-plan.test.ts`: internal IR hash stability, dependency index,
  trigger-hook lowering, selected-stage, and peer-Zhixu signal-map validation
  tests.

## Public Output

Use these root-package entrypoints:

- `compileZhixuOnchainHookPlan(zhixuDefinition)`;
- `compileZhixuRegisterPlanArgs(zhixuDefinition)`;
- `toSolidityRegisterPlanArgs(onchainHookPlanArtifact)`.

`compileZhixuOnchainHookPlan(zhixu)` emits schema
`uvp.onchainHookPlan.v5`. It:

- emits stable `planId` and `planHash`;
- carries target `platform` from Zhixu YAML as a protocol field
  (`type=blockchain`, `provider=eth`, optional `network=base` for the EVM
  track; omitted `network` keeps the current default path);
- replaces hook expressions with postfix instruction arrays;
- enumerates every order-trigger hook in `triggers[]`, one entry per hook with
  `orderTriggerKind` `"trigger"` or `"dock"` (see Triggers);
- indexes dependencies by packed signal key;
- exposes executor routes through route references;
- carries `dockInterface`, resolved `dockRoutes`, and their committed roots;
  dynamic (`target: null`) routes ride as the `unresolvedDockRoutes`
  declaration face (manifest-derived candidate set occupies the route-hash
  target slot; the leaf joins `dockRoutesRoot`);
- compiles `selectedStageBindings` into sorted `selectorBindings` for
  `StageSelectorBinding` registration;
- lowers `spec.stages[].fileWriters` into a sorted `stageFileWriters` section
  (one `(targetStageId, writerStageId)` leaf per declared writer stage; self is
  implicit and never a leaf);
- commits the three tables — `selectorBindings`, `signalCapabilities`, and
  `stageFileWriters` — into a single `capabilitiesRoot` (domain-separated
  leaves mixed into one sorted paired Merkle tree; empty tables pin
  `keccak256("")`), and includes the tables in the canonical on-chain
  `planHash`;
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
and verifies `planHash`. `toSolidityRegisterPlanArgs(value)` strips audit labels
and returns a deterministic data shape for the Solidity registration ABI.

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
| `orderTriggerKind` | `"trigger"` for a trigger-signal birth line, `"dock"` for a dock entrance |
| `source` / `signalName` | the birth fact's source class and two-part `<stageIdentifier>.<signal>` name |
| `sourceId` / `signalId` | `keccak256(source)` / `keccak256(stage.signal)` |

A `stage.triggers[]` entry lowers to exactly one hook with
`orderTriggerKind: "trigger"`, `emitReady: true`, a single `SIGNAL`
instruction, and one positive dependency on
`<source>::<stageIdentifier>.<signal>`; that dependency's
`(sourceId, signalId)` is the birth fact. Trigger stages require a static
non-zhixu executor, and their ordinary `receiveSignals` hooks keep
`orderTriggerKind: "none"` and coexist with the trigger hooks. A plan may
declare several trigger signals and several trigger stages, and may carry dock
entrances in the same enumeration.

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

- `planId` and `planHash` are the state-machine plan identity;
- `hooks` map to `UVPStateMachine.CompactHook`; hook flags are
  `ORDER_TRIGGER_MINT` for `orderTriggerKind: "trigger"`,
  `ORDER_TRIGGER_DOCK` for `"dock"`, `EMIT_READY`, and
  `HOOK_FLAG_ADMISSION` for admission entries;
- a `"trigger"` entry in `triggers[]` is the outside-birth entry: the caller
  passes its `hookId` as `triggerHookId`, plus `stageId`, `sourceId`, and
  `signalId`, to `triggerOrderFromOutsideFor`;
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
- executor route metadata stays off chain and is used by Product APIs and
  `uvp-client` for routing;
- order-level signal authorization is constructed outside the compiler by
  deploy/Product tooling from participant wallets and compiled source/signal
  ids.

## Overlay Hashing

Stage executor patch hashing and the file patch canonical digest live in
`@uvp-eth/protocol-bindings`. The compiler owns selector binding, file-writer
leaf, and on-chain HookPlan artifact hashing only; file content and handles
stay outside compiler artifacts.
