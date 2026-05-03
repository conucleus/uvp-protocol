# uvp-protocol

Protocol boundary for the EVM-native UVP track.

Public status: alpha protocol core. Compiler artifacts, state-machine
semantics, contract interfaces, ABI fixtures, Product DTOs, and replay models
are the public spine. External audits and production governance hardening remain
open.

Before this workspace is split into public repositories, protocol-facing
Product DTOs must stay aligned with PRD109's convergence contract. Executor
overlays are the current implemented dynamic stage authority. Product task
manifests describe executor actions such as `submit_signal`,
`stage_executor_patch`, and `stage_resource_patch`. Docked Zhixu runtime is
modeled as local/linked order signal binding rather than an order hierarchy.

This domain owns deterministic semantics and public protocol interfaces:

- `packages/hook-core/`: Hook DSL parsing, dependency extraction, and local evaluation.
- `packages/compiler/`: Zhixu-to-HookPlan and EVM artifact generation.
- `packages/statemachine/`: reference state-machine reducer and chain-event replay oracle.
- `packages/product-dto/`: shared Product DTO contracts derived from protocol projections.
- `contracts/uvp-contracts/`: Solidity contracts, ABI fixtures, and Foundry tests.
- `tools/runtime-host/`: off-chain reference runtime harness.

## Development Topology

This repository is mounted by `uvp-eth` as a Git submodule. Most package
dependencies are internal to this repository and are resolved by its local
`pnpm-workspace.yaml`.

`tools/runtime-host` also consumes `@uvp-eth/executor-kit` for reference runtime
and E2E harnesses. Use the `uvp-eth` umbrella checkout for full integration
development so pnpm can resolve that cross-repository `workspace:*` dependency.

Do not put chain-service API state, product-specific UI state, deployment manifests,
or ordinary-user app code here. ABI, EIP-712 types, events, canonical hashes, and
artifact encodings are public interfaces.
