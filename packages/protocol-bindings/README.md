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
  construction, address/bytes32 validation, and canonical hash helpers.
- Does not import Node-only modules, read env vars, hold private keys, run
  watchers, request wallet signatures, or submit transactions.

## Stage Executor Patch Helpers

- Exported mode constants mirror the contract constants:
  `EXECUTOR_PATCH_MODE_ASSIGN`, `EXECUTOR_PATCH_MODE_HANDOFF`, and
  `EXECUTOR_PATCH_MODE_REPLACEMENT`.
- `buildStageExecutorPatchTypedData` builds
  `UVPStagePatchModuleStageExecutorPatch` EIP-712 typed data for PRD88 `assign`,
  `handoff`, and `replacement` payloads. The payload includes `mode`,
  `previousExecutor`, `approvalSourceId`, and `approvalSignalId`.
- `recoverStageExecutorPatchSigner` recovers either the selector wallet or the
  previous executor wallet from a signature over the same executor patch typed
  data.
- `buildApplyStageExecutorPatchForCall` encodes PRD88
  `applyStageExecutorPatchFor` calldata with `selectorSignature` and
  `previousExecutorSignature`; pass `0x` when the selected mode does not
  require previous-executor consent.
- `hashStageExecutorPatchPayload` commits to selector stage, target stage,
  executor, role, executor metadata hash, mode, previous executor, approval
  source/signal ids, nonce, and metadata URI. It does not include file resource
  fields.
- Use the zero address or zero `bytes32` for unused `previousExecutor` and
  approval fields so those absences are still explicit in the signed payload.

## Stage Resource Patch Helpers

- `buildStageResourcePatchTypedData` builds
  `UVPStagePatchModuleStageResourcePatch` EIP-712 typed data.
- `recoverStageResourcePatchSigner` recovers the authorized stage executor
  wallet from a resource patch signature.
- `buildApplyStageResourcePatchForCall` encodes PRD87
  `applyStageResourcePatchFor` calldata.
- `hashStageResourcePatchPayload` commits to selector stage, target stage,
  resource key, manifest hash, policy hash, nonce, and manifest URI.

## Resource Manifest Helpers

- `hashResourceManifest` canonicalizes and hashes `ResourceManifestV1` JSON.
- `validateResourceManifestV1` applies the same validation without returning a
  hash.
- Resource manifests reject legacy file resource handle types `http`,
  `txcloud`, and `plain_text`, public HTTP resource URLs, and plaintext resource
  data markers.
