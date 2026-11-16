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
  `STATE_MACHINE_ABI`, `FILE_RESOURCE_MODULE_ABI`,
  `SUPPLIER_REGISTRY_ABI`, `DOCK_REGISTRY_ABI`, module call surfaces —
  including the stage-patch executor patch/dock selection and output events),
  stage executor patch and stage dock executor selection typed-data helpers,
  plan executor binding registration helpers, signal submission
  (`submitSignalFor`) typed data, `UVPZhixuRegistry/1` registry typed data
  (`ZhixuRecord`/`IdentityClaim` schema, builders, type hashes),
  direct `submitSignal` (including trailing `filesDigest`/`FilePatch`),
  `applyStageExecutorPatchFor`, and file patch call construction
  (`filePatchDigest`, `FileOp`/`FilePatch`), capability-tree root/proof
  helpers, and address/bytes32 validation. Canonical JSON serialization and
  evidence hashing are owned by `@uvp-eth/canonical-json`.
- Trigger birth helpers: `OrderTriggerKind`/`buildCompactHookFlags`,
  `buildTriggerOrderFromOutsideTypedData`, the two
  `buildTriggerOrderFromOutside*Call` encoders, and `deriveTriggerOrderId`.
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
  `capabilitiesRoot`, `executorBindingsRoot`, `birthAuthorizer`, `deadline`
  under the main `UVPStateMachine` domain (`0.19`).
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
  payloadHash, idempotencyKey, filesDigest, attributionHash, submitter,
  deadline)` under the main domain (`0.19`); `factAttributionHash` is the
  `FactAttribution(sourceId, signalId, stageId, capabilityProof)` digest that
  enters the signature, and `recoverSignalSubmissionSigner` recovers the
  signer.
- `buildSubmitSignalForCall` encodes
  `submitSignalFor(planId, orderId, sourceId, signalId, payloadHash,
  idempotencyKey, attribution, filesDigest, filePatch, submitter, deadline,
  signature)`; the submitter is the effective stage executor and `msg.sender`
  is only the relayer. `filesDigest` must equal `filePatchDigest` when the
  patch carries ops.

## Trigger Birth Bindings

- `OrderTriggerKind` is `"none" | "trigger"`.
  `buildCompactHookFlags` folds it into the compact-hook flag word:
  `"trigger"` → `HOOK_FLAG_ORDER_TRIGGER_MINT`, plus `HOOK_FLAG_EMIT_READY`
  when the hook must emit ready, `HOOK_FLAG_DOCK_EXECUTOR` for dock stages,
  and `HOOK_FLAG_DYNAMIC_EXECUTOR` for dynamic executor stages. Flags are
  committed through the plan's `hooksHash`.
- `buildTriggerOrderFromOutsideTypedData` builds
  `UVPStateMachineTriggerOrderFromOutside` typed data under the product-submit
  domain (`UVPStateMachine`, version `0.19`). `triggerHookId` +
  `triggerStageId` explicitly select one trigger birth line among the plan's
  order-trigger hooks.
- `buildTriggerOrderFromOutsideForCall` encodes the relayer-submitted signed
  birth entry; `buildTriggerOrderFromOutsideByAuthorizerCall` encodes the
  contract `birthAuthorizer` direct entry, which carries no signature.
- `deriveTriggerOrderId(planId, sourceId, signalId, payloadHash)` mirrors the
  on-chain `triggerOrderIdFor`: `keccak256(abi.encode(planId, sourceId,
  signalId, payloadHash))` with the reserved top namespace bit cleared.
- The trigger-birth surface pins the state-machine and linked
  plan-registration ABI fixtures under `contracts/uvp-contracts/fixtures/`;
  birth admission rejects with `SignalAdmissionRejected`.

## Dock Write Surface

- `DOCK_REGISTRY_ABI` / `DOCK_REGISTRY_CONTRACT_NAME` pin the static
  `UVPDockRegistry` artifact; `registerDock` stores from/to plan+source+stage,
  `docHash`, per-output `WindowInstruction[]` (op Signal/Not/And/Or/Delay),
  atoms, and per-atom/per-output capability proofs.
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
  `UVP_FILE_WRITER_V1` domain separators.
- `capabilitiesRootOf` builds the sorted-pairing tree root over the capability
  tables (signal capabilities, selector bindings, file writers)
  (dedup + sort, `keccak256(min ‖ max)` per level, odd tail leaf promoted,
  empty tables normalize to `EMPTY_CAPABILITIES_ROOT = keccak256("")`).
- `factAttribution` returns the owning stage plus its capability proof for a
  `(sourceId, signalId)` fact (relation `0` capability); wire it straight into
  the direct `submitSignal` call's `attribution` argument.
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
- `filePatchDigest(planId, orderId, filePatch)` is the canonical
  `filesDigest` carried by the direct `submitSignal` call:
  `keccak256(abi.encode(keccak256("UVP_FILE_PATCH_V1"), planId, orderId,
  targetStageId, baseHash, writerStageId, ops))`; `writerProof` is a witness
  and is excluded. `EMPTY_FILE_PATCH` is the no-patch value.
- Direct `submitSignal` calldata appends `(bytes32 filesDigest, FilePatch filePatch)`;
  omitting both produces the fileless form, and a patch-bearing call is
  rejected unless `filesDigest` equals `filePatchDigest` for the same
  plan/order/patch.
