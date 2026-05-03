# compiler

Zhixu compiler for deterministic HookPlan and EVM state-machine artifacts.

This module compiles UVP DSL into deterministic runtime artifacts. The protocol
output is `HookPlanArtifact`, `OnchainHookPlanArtifact`, and
`UVPStateMachine.registerPlan` args.

## Inputs

- `apiVersion: uvp/v0`, `kind: Zhixu` YAML/JSON definitions;
- Hook DSL expressions under `receiveSignals`;
- selected-stage executor bindings and supplier `signalMap` data;
- target platform metadata, currently `platform.type=blockchain` and
  `platform.provider=eth` for this track.

## Outputs

- platform-neutral `HookPlanArtifact`;
- EVM-facing `OnchainHookPlanArtifact`;
- Solidity `UVPStateMachine.registerPlan` args;
- deterministic `planId`, `planHash`, source `zhixu_hash`, `policy_hash`,
  `metadata_hash`, and `artifact_hash`;
- stable hook, stage, source, signal, dependency, and route ids;
- on-chain selector bindings for order-level executor overlay authority;
- golden fixtures for compiler, contract, executor-kit, and replay tests.

## MVP Constraint

The supported compiler surface is the generic HookPlan path:

- `receiveSignals` hook parsing;
- `trigger` reference validation;
- `selectedStages` binding validation;
- static executor route extraction;
- `supplierType=zhixu` `signalMap` compilation and same-source validation.

Executor topology follows the original UVP closure rule: a stage without a
fixed `executor.supplierID` is valid only when it can be reached through
`selectedStages` from a stage that does name a fixed executor. Selector loops or
selector chains with no fixed executor anchor are rejected, so product flows
cannot publish order stages that nobody is authorized to select or perform.

Do not execute hooks in this module. Runtime evaluation belongs in
`hook-core`/`statemachine`.

## Local Package

This directory is intentionally self-contained. It does not import the Go UVP
repository and it does not rely on the sibling `uvp-deploy` repository.

```bash
pnpm install
pnpm --filter @uvp-eth/compiler test
pnpm --filter @uvp-eth/compiler typecheck
```

## Source

- `src/types/`: public TypeScript interfaces for Zhixu HookPlan inputs,
  compiler artifacts, compact on-chain hook plans, and Solidity registration
  args.
- `src/hook-plan.ts`: deterministic Zhixu-to-HookPlan compiler.
- `src/onchain-hook-plan.ts`: compact HookPlan compiler for Solidity
  registration inputs.
- `src/zhixu-loader.ts`: YAML/JSON loader for `apiVersion: uvp/v0`,
  `kind: Zhixu` definitions.
- `src/canonical.ts`: canonical JSON normalization used before hashing.
- `src/hash.ts`: in-module Keccak-256 boundary hashing for EVM-compatible test
  vectors.
- `fixtures/uvp-update-zhixu-v2.yaml`: UVP `0.1.3` self-bootstrap update
  fixture, normalized for the EVM track with `platform.type=blockchain` and
  `platform.provider=eth`.
- `test/hash.test.ts`: hash vector and canonicalization tests.
- `test/hook-plan.test.ts`: HookPlan hash stability, dependency index, trigger,
  selected-stage, and peer-Zhixu signal-map validation tests.

## HookPlan Output

`compileZhixuHookPlan(zhixu)` emits:

- stable `planId` and `planHash`;
- target `platform` from Zhixu YAML, now treated as a protocol field
  (`type=blockchain`, `provider=eth` for the EVM track);
- `compiledHooks` with normalized Hook ASTs and dependencies;
- `dependencyIndex` keyed by `source::signal`;
- `executorRoutes` for dispatch adapters;
- `selectedStageBindings` for order-level executor patch authority.

`validateHookPlanArtifact(value)` and `assertHookPlanArtifact(value)` provide a
runtime checker for this public artifact boundary.

## On-Chain HookPlan Output

`compileOnchainHookPlan(hookPlanArtifact)` emits schema
`uvp.onchainHookPlan.v1`. It keeps the same `planId`, `zhixuId`, and `version`
as the platform-neutral plan, replaces hook expressions with postfix
instruction arrays, indexes dependencies by packed signal key, and exposes
executor routes through route references. It also compiles
`selectedStageBindings` into sorted `selectorBindings` for PRD81
`StageSelectorBinding` registration, and includes those bindings in the
canonical on-chain `planHash`.

Stable ids use raw Keccak-256:

- `hookId = keccak256(stageIdentifier#hookName)`;
- `stageId = keccak256(stageIdentifier)`;
- `sourceId = keccak256(source)`;
- `signalId = keccak256(task.stage.signal)`;
- `signalKey = keccak256(abi.encodePacked(sourceId, signalId))`.
- `selectorStageId` / `targetStageId = keccak256(stageIdentifier)`.

`validateOnchainHookPlanArtifact(value)` checks the compact artifact shape,
recomputes ids, validates instruction stack shape, verifies `dependencyIndex`,
and verifies `planHash`. `toSolidityRegisterPlanArgs(value)` strips audit labels
and returns a deterministic data shape for the Solidity registration ABI.

## Solidity Alignment

The current state-machine alignment is `toSolidityRegisterPlanArgs()`:

- `planId` and `planHash` are the state-machine plan identity;
- `hooks` map to `UVPStateMachine.CompactHook`;
- `selectorBindings` map to `UVPStateMachine.StageSelectorBinding`;
- `instructions` map to compact `Signal`, `Not`, `And`, `Or`, and `Delay`
  operations;
- `dependencyKeys` must match `UVPStateMachine.signalKey(sourceId, signalId)`;
- executor route metadata stays off chain and is used by Product APIs and
  `executor-kit` for routing;
- order-level signal authorization is constructed outside the compiler by
  deploy/Product tooling from participant wallets and compiled source/signal
  ids.

## Overlay Hashing

Stage executor patch, stage resource patch, and resource manifest hashing live
in `@uvp-eth/protocol-bindings`. The compiler owns selector binding and
on-chain HookPlan artifact hashing only; resource plaintext and manifests stay
outside compiler artifacts.
