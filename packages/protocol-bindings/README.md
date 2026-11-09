# @uvp-eth/protocol-bindings

Browser-safe UVP EVM protocol bindings shared by chain services, executor
tools, and participant apps.

## Local Commands

```bash
pnpm --filter @uvp-eth/protocol-bindings typecheck
pnpm --filter @uvp-eth/protocol-bindings test
pnpm --filter @uvp-eth/protocol-bindings build
```

## Boundary

- Exposes core and module ABI constants (`UVP_STATE_MACHINE_ARTIFACT_ABI`,
  `STATE_MACHINE_ABI`, `FILE_RESOURCE_MODULE_ABI`, module call surfaces),
  0.16 Product submit typed-data helpers, stage executor patch typed-data
  helpers, `UVPZhixuRegistry/1` registry typed data
  (`ZhixuRecord`/`IdentityClaim` schema, builders, type hashes),
  `submitSignalFor`, `applyStageExecutorPatchFor`, and file patch call
  construction (`filePatchDigest`, `FileOp`/`FilePatch`), capability-tree
  root/proof helpers, and address/bytes32 validation. Canonical JSON
  serialization and evidence hashing are owned by
  `@uvp-eth/canonical-json`.
- Does not import Node-only modules, read env vars, hold private keys, run
  watchers, request wallet signatures, or submit transactions.
- The test suite consumes the shared capabilities-root golden vectors from
  `../compiler/fixtures/capabilities-root/v1/vectors.json` by relative path
  (the same fixture feeds the compiler TS tests and the Foundry parity
  suite). The coupling is a deliberate directory-layout contract, not a
  package dependency; moving that fixture requires updating all three
  consumers together.

## Capability Tree Helpers

- The plan capability tables (stage selector bindings + signal capabilities +
  stage file writers) live on-chain only as a Merkle root: `commitPlan` has
  the publisher sign `capabilitiesRoot`, and submitters re-derive leaves and
  carry proofs.
- `signalCapabilityLeaf` / `selectorBindingLeaf` / `fileWriterLeaf` mirror the
  on-chain leaf formulas: `keccak256(abi.encode(keccak256(domain), …words))`
  with the `UVP_SIGNAL_CAPABILITY_V1` / `UVP_SELECTOR_BINDING_V1` /
  `UVP_FILE_WRITER_V1` domain separators.
- `capabilitiesRootOf` builds the sorted-pairing tree root over both tables
  (dedup + sort, `keccak256(min ‖ max)` per level, odd tail leaf promoted,
  empty tables normalize to `EMPTY_CAPABILITIES_ROOT = keccak256("")`).
- `factAttribution` returns the owning stage plus its capability proof for a
  `(sourceId, signalId)` fact (relation `0` capability); wire it straight into
  `buildSubmitSignalForCall`'s `attribution` argument.
- `selectorBindingProofFor` returns the selector stage plus its binding proof
  for a bound target stage; wire it into the `selectorBinding` argument.
- `fileWriterProofFor` returns the capability proof for a
  `(targetStageId, writerStageId)` file-writer leaf; wire it into a
  `FilePatch.writerProof`.

## Stage Executor Patch Helpers

- Exported mode constants mirror the contract constants:
  `EXECUTOR_PATCH_MODE_ASSIGN`, `EXECUTOR_PATCH_MODE_HANDOFF`, and
  `EXECUTOR_PATCH_MODE_REPLACEMENT`.
- `buildStageExecutorPatchTypedData` builds
  `UVPStagePatchModuleStageExecutorPatch` EIP-712 typed data for `assign`,
  `handoff`, and `replacement` payloads. The payload includes `mode`,
  `previousExecutor`, `approvalSourceId`, and `approvalSignalId`.
- `recoverStageExecutorPatchSigner` recovers either the selector wallet or the
  previous executor wallet from a signature over the same executor patch typed
  data.
- `buildApplyStageExecutorPatchForCall` encodes
  `applyStageExecutorPatchFor` calldata with `selectorSignature` and
  `previousExecutorSignature`; pass `0x` when the selected mode does not
  require previous-executor consent.
- `hashStageExecutorPatchPayload` commits to the
  `uvp:stage-executor-patch-payload:v1` domain
  (`STAGE_EXECUTOR_PATCH_PAYLOAD_HASH_DOMAIN`, hashed as the leading
  `keccak256(domain)` word of the abi-encoded preimage) plus selector stage,
  target stage, executor, role, executor metadata hash, mode, previous
  executor, approval source/signal ids, nonce, and metadata URI. It does not
  include file resource fields.
- Use the zero address or zero `bytes32` for unused `previousExecutor` and
  approval fields so those absences are still explicit in the signed payload.

## File Patch Helpers

- `FileOp` / `FilePatch` mirror the `IUVPFileResourceModule` structs:
  `writerStageId == 0` means the target stage's own executor, `handle` is the
  opaque UTF-8 reference, and `kind` is `0|1|2` (add/replace/remove) via
  `FILE_OP_KIND`.
- `filePatchDigest(planId, orderId, filePatch)` is the canonical
  `filesDigest` signed in the 0.16 `UVPStateMachineSignal` typed data:
  `keccak256(abi.encode(keccak256("UVP_FILE_PATCH_V1"), planId, orderId,
  targetStageId, baseHash, writerStageId, ops))`; `writerProof` is a witness
  and is excluded. `EMPTY_FILE_PATCH` is the no-patch value.
- `buildSubmitSignalForCall` appends `(bytes32 filesDigest,
  FilePatch filePatch)`; omitting both produces the fileless form, and a
  patch-bearing call is rejected unless `filesDigest` equals
  `filePatchDigest` for the same plan/order/patch.
- The digest and 0.16 typed-data golden vectors live under `fixtures/` and are
  shared with the Foundry parity probes; `PRODUCT_SUBMIT_DOMAIN_VERSION` is
  `0.16` and `UVPStateMachineSignal` ends with `bytes32 filesDigest`.
