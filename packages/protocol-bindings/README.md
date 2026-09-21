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

- Exposes core and module ABI constants, EIP-712 Product submit typed-data
  helpers, split stage executor/resource patch typed-data helpers,
  `submitSignalFor`, `applyStageExecutorPatchFor`, and `applyStageResourcePatchFor` call
  construction, capability-tree root/proof helpers, address/bytes32
  validation, and canonical hash helpers.
- Does not import Node-only modules, read env vars, hold private keys, run
  watchers, request wallet signatures, or submit transactions.
- The test suite consumes the shared capabilities-root golden vectors from
  `../compiler/fixtures/capabilities-root/v1/vectors.json` by relative path
  (the same fixture feeds the compiler TS tests and the Foundry parity
  suite). The coupling is a deliberate directory-layout contract, not a
  package dependency; moving that fixture requires updating all three
  consumers together.

## Capability Tree Helpers

- The plan capability tables (stage selector bindings + signal capabilities)
  live on-chain only as a Merkle root: `commitPlan` has the publisher sign
  `capabilitiesRoot`, and submitters re-derive leaves and carry proofs.
- `signalCapabilityLeaf` / `selectorBindingLeaf` mirror the on-chain leaf
  formulas: `keccak256(abi.encode(keccak256(domain), …words))` with the
  `UVP_SIGNAL_CAPABILITY_V1` / `UVP_SELECTOR_BINDING_V1` domain separators.
- `capabilitiesRootOf` builds the sorted-pairing tree root over both tables
  (dedup + sort, `keccak256(min ‖ max)` per level, odd tail leaf promoted,
  empty tables normalize to `EMPTY_CAPABILITIES_ROOT = keccak256("")`).
- `factAttribution` returns the owning stage plus its capability proof for a
  `(sourceId, signalId)` fact (relation `0` capability); wire it straight into
  `buildSubmitSignalForCall`'s `attribution` argument.
- `selectorBindingProofFor` returns the selector stage plus its binding proof
  for a bound target stage; wire it into the `selectorBinding` argument.

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

## Stage Resource Patch Helpers

- `buildStageResourcePatchTypedData` builds
  `UVPStagePatchModuleStageResourcePatch` EIP-712 typed data.
- `recoverStageResourcePatchSigner` recovers the authorized stage executor
  wallet from a resource patch signature.
- `buildApplyStageResourcePatchForCall` encodes
  `applyStageResourcePatchFor` calldata.
- `hashStageResourcePatchPayload` commits to the
  `uvp:stage-resource-patch-payload:v1` domain
  (`STAGE_RESOURCE_PATCH_PAYLOAD_HASH_DOMAIN`, hashed as the leading
  `keccak256(domain)` word of the abi-encoded preimage) plus selector stage,
  target stage, resource key, manifest hash, policy hash, nonce, and
  manifest URI.

## Resource Manifest Helpers

- `hashResourceManifest` canonicalizes, validates, and hashes
  `ResourceManifestV1` JSON.
- Resource manifests reject public HTTP resource URLs.
