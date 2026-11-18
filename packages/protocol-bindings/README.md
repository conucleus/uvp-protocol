# @uvp-eth/protocol-bindings

Browser-safe UVP EVM protocol bindings shared by chain services, executor
tools, and participant apps.

## Local Commands

```bash
pnpm --filter @uvp-eth/protocol-bindings typecheck
pnpm --filter @uvp-eth/protocol-bindings test
pnpm --filter @uvp-eth/protocol-bindings build
pnpm --filter @uvp-eth/protocol-bindings generate:artifact-abis
```

## Boundary

- Exposes core and module ABI constants (`UVP_STATE_MACHINE_ARTIFACT_ABI`,
  `STATE_MACHINE_ABI`, `FILE_RESOURCE_MODULE_ABI`, `SUPPLIER_REGISTRY_ABI`,
  `DOCK_REGISTRY_ABI`, `DERIVED_SIGNAL_MODULE_ABI`,
  `STATE_MACHINE_LENS_ABI`, module call surfaces — including the stage-patch
  executor patch/dock selection and output events), stage executor patch and
  stage dock executor selection typed-data helpers, plan executor binding
  registration helpers, signal submission typed data
  (`UVPStateMachineSignalSubmission`) and the single `submitSignal` call
  builder, `UVPZhixuRegistry/1` registry typed data (`ZhixuRecord`/
  `IdentityClaim` schema, builders, type hashes), file patch call construction
  (`filePatchHash`, `filePatchDigest`, `FileOp`/`FilePatch`), capability-tree
  root/proof helpers, and address/bytes32 validation. Canonical JSON
  serialization and evidence hashing are owned by `@uvp-eth/canonical-json`.
- Trigger hooks are committed through `buildCompactHookFlags` (`OrderTriggerKind`
  `"none" | "trigger"`); trigger birth itself is the same `submitSignal`
  surface with `orderId == 0`.
- Does not import Node-only modules, read env vars, hold private keys, run
  watchers, request wallet signatures, or submit transactions.
- The test suite consumes the shared capabilities-root golden vectors from
  `../compiler/fixtures/capabilities-root/v1/vectors.json` by relative path
  (the same fixture feeds the compiler TS tests and the Foundry parity
  suite). The coupling is a deliberate directory-layout contract, not a
  package dependency; moving that fixture requires updating all three
  consumers together.

## Plan Registration Bindings

- `PlanCommitPayload` / `PlanCommitTypedData` mirror
  `UVPStateMachine.PlanCommit`: the publisher signs `publisher`, `hooksHash`,
  `capabilitiesRoot`, `supplierBindingsRoot`, `deadline` under the main
  `UVPStateMachine` domain (`0.20`).
- `ExecutorBinding` is `{ stageId, supplierId, kind }` with kind `0`
  (default) / `1` (candidate); `buildPlanCommitCall` encodes
  `commitPlan(commit, hooks, bindings, signature)` from
  `PlanRegistrationArgs.executorBindings` and
  `PlanRegistrationArgs.executorBindingsRoot`. Supplier IDs, binding roots,
  binding proofs, and default-vs-candidate derivation are owned by
  `@uvp-eth/compiler/browser`; this package only carries them into calldata.

## Signal Submission Bindings

- `buildSignalSubmissionTypedData` builds
  `UVPStateMachineSignalSubmission(planId, orderId, sourceId, signalId,
  payloadHash, idempotencyKey, patchHash, attributionHash, submitter,
  deadline)` under the main domain (`0.20`); `factAttributionHash` is the
  `FactAttribution(sourceId, signalId, stageId, capabilityProof)` digest that
  enters the signature, and `recoverSignalSubmissionSigner` recovers the
  signer. Omit `orderId` (or pass zero) to sign the trigger-birth context,
  where the contract generates the order id.
- `buildSubmitSignalCall` encodes `submitSignal(submission, signature)` from
  `SubmitSignalCallArgs`. An omitted or empty signature is a direct submit
  (`submitter` must equal `msg.sender`); a non-empty signature is a relayed
  submit signed by `submitter`. `patchHash` is covered by the signature; pass
  `filePatchHash(filePatch)` for patch-bearing submissions and zero otherwise.
- `orderId == 0` is trigger birth: the contract resolves the trigger hook from
  `(sourceId, signalId)`, requires the trigger-stage assigned supplier, and
  enforces the `(submitter, idempotencyKey)` first-win rule before creating
  the order. `orderId != 0` targets an existing order; `signalId == 0` is a
  file-only patch.

## Dock Write Surface

- `DOCK_REGISTRY_ABI` / `DOCK_REGISTRY_CONTRACT_NAME` pin the static
  `UVPDockRegistry` artifact; `registerDock` stores from/to plan+source+stage,
  `docHash`, per-output `WindowInstruction[]` (op Signal/Not/And/Or/Delay),
  atoms, and per-atom/per-output capability proofs. Capability relations are
  current-order (`0`) only.
- `buildRegisterDockCall` and `buildRegisterDockCallFromArtifact` encode the
  registration call; missing per-atom/per-output proofs are derived from the
  plan capability tables (single-source leaf/proof helpers above).
- `selectStageDockExecutor` / `For` builders select a dkid once;
  `buildStageDockExecutorSelectionTypedData` builds the selector EIP-712
  payload (`UVPStagePatchModule`, version `0.5`), and
  `recoverStageDockExecutorSelectionSigner` recovers it. The selection carries
  `supplierId` + `patchNonce`; executor addresses are resolved on chain from
  the supplier registry.
- `buildPokeDockBindingCall` encodes `pokeDockBinding` (payload content, A
  order id, per-output capability proofs); `dockBindingId` mirrors the
  contract binding-id preimage (7 words, no payload hash).
- `DOCK_PAYLOAD_FILE_KEY` / `DOCK_BINDING_ID_DOMAIN` are the contract
  constants; `STAGE_PATCH_MODULE_ABI` carries the binding/poke/output events.

## Capability Tree Helpers

- The plan capability tables (stage selector bindings + signal capabilities +
  stage file writers) live on-chain only as a Merkle root: `commitPlan` has
  the publisher sign `capabilitiesRoot`, and submitters re-derive leaves and
  carry proofs.
- `signalCapabilityLeaf` / `selectorBindingLeaf` / `fileWriterLeaf` mirror the
  on-chain leaf formulas: `keccak256(abi.encode(keccak256(domain), …words))`
  with the `UVP_SIGNAL_CAPABILITY_V1` / `UVP_SELECTOR_BINDING_V1` /
  `UVP_FILE_WRITER_V1` domain separators. `signalCapabilityLeaf` relation is
  current-order (`0`) only.
- `capabilitiesRootOf` builds the sorted-pairing tree root over the capability
  tables (signal capabilities, selector bindings, file writers)
  (dedup + sort, `keccak256(min ‖ max)` per level, odd tail leaf promoted,
  empty tables normalize to `EMPTY_CAPABILITIES_ROOT = keccak256("")`).
- `factAttribution` returns the owning stage plus its capability proof for a
  `(sourceId, signalId)` fact (relation `0` capability); wire it straight into
  the `submitSignal` call's `attribution` argument.
- `selectorBindingProofFor` returns the selector stage plus its binding proof
  for a bound target stage; wire it into the `selectorBinding` argument.
- `fileWriterProofFor` returns the capability proof for a
  `(targetStageId, writerStageId)` file-writer leaf; wire it into a
  `FilePatch.writerProof`.

## Stage Executor Patch Helpers

- `buildStageExecutorPatchTypedData` builds
  `UVPStagePatchModuleStageExecutorPatch` EIP-712 typed data (module domain
  `0.5`) for supplier assignment and handoff payloads. The payload is
  `selectorStageId, targetStageId, supplierId, previousSupplierId,
  patchNonce`; there is no mode/role/metadata/patch-hash field.
  `previousSupplierId == 0` is the assign transition (before the stage's
  first signal); a non-zero value is the handoff transition (after it).
- `recoverStageExecutorPatchSigner` recovers either the selector wallet or the
  previous executor wallet from a signature over the same executor patch typed
  data.
- `buildApplyStageExecutorPatchForCall` encodes
  `applyStageExecutorPatchFor` calldata with `selectorSignature` and
  `previousExecutorSignature`; pass `0x` when the transition does not require
  previous-executor consent. `bindingProof` proves the selector stage binding;
  `candidateProof` proves candidate membership only for candidate stages and
  is empty for dynamic stages.
- `hashStageExecutorPatchPayload` commits to the
  `uvp:stage-executor-patch-payload:v2` domain
  (`STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN`, hashed as the leading
  `keccak256(domain)` word of the abi-encoded preimage) plus selector stage,
  target stage, supplier, previous supplier, and nonce.

## File Patch Helpers

- `FileOp` / `FilePatch` mirror the `IUVPFileResourceModule` structs:
  `writerStageId == 0` means the target stage's own executor, `handle` is the
  opaque UTF-8 reference, and `kind` is `0|1|2` (add/replace/remove) via
  `FILE_OP_KIND`.
- `filePatchHash(filePatch)` is the signed patch envelope covered by the
  `submitSignal` EIP-712 signature:
  `keccak256(abi.encode(keccak256("UVP_FILE_PATCH_HASH_V1"), targetStageId,
  baseHash, writerStageId, writerProof, ops))`; `planId`/`orderId` are not in
  the preimage (the contract recomputes it from calldata and rejects a
  relayer-replaced patch with `PatchHashMismatch`). Empty-file submissions
  carry `patchHash == 0`.
- `filePatchDigest(planId, orderId, filePatch)` is the canonical
  `filesDigest` the state machine hands to the file module after the order id
  exists: `keccak256(abi.encode(keccak256("UVP_FILE_PATCH_V1"), planId,
  orderId, targetStageId, baseHash, writerStageId, ops))`; `writerProof` is a
  witness and is excluded. `EMPTY_FILE_PATCH` is the no-patch value.
