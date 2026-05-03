# AGENTS.md

## Module Purpose

`uvp-protocol/packages/compiler/` owns the EVM-oriented compilation layer. It
converts Zhixu DSL into deterministic HookPlan and on-chain state-machine
artifacts that contracts, services, executor-kit, and replay tools can verify.

This module must be independent from the Go cloud UVP compiler.

## Responsibilities

- Define the EVM MVP input schema for Zhixu HookPlan definitions.
- Produce platform-neutral HookPlan artifacts and EVM-facing compact hook plans.
- Produce stable hashes:
  - `planId`
  - `planHash`
  - `zhixu_hash`
  - `policy_hash`
  - `metadata_hash`
- Generate `UVPStateMachine.registerPlan` args for
  `uvp-protocol/contracts/uvp-contracts/`.
- Maintain golden fixtures for every supported compilation case.

## Non-Responsibilities

- Do not deploy contracts.
- Do not run a backend API.
- Do not implement the Solidity runtime.
- Do not choose participant wallet authorization for orders.
- Do not emit escrow/funding artifacts from this compiler.
- Do not import the Go `uvp` repository.

## Interface Rules

- Canonical encoding must be deterministic across machines.
- Hashes must include compiler version and schema version where needed.
- Any change to generated contract-facing data is a breaking interface change
  unless explicitly versioned.
- Generated fixtures must be readable by `uvp-protocol/contracts/uvp-contracts/`
  tests, `executor-kit`, `chain-services`, and
  `uvp-protocol/packages/statemachine/` replay tests.
- Any change to `OnchainHookPlanArtifact`, `registerPlan` args, or id/hash
  derivation must be treated as ABI-adapter drift.

## Testing Expectations

- Golden fixture tests for canonical JSON or binary encoding.
- Hash stability tests.
- Invalid HookPlan input tests.
- Cross-module fixture tests against contract ABI expectations.
