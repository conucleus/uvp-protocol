# AGENTS.md

## Module Purpose

`uvp-protocol/packages/statemachine/` owns the UVP HookPlan runtime semantics
outside Solidity. It defines how signals, hooks, timers, dispatch effects, and
chain-event replay are expected to transition.

This module is a reference model and test oracle for
`uvp-protocol/contracts/uvp-contracts/` and `uvp-chain-services/service/`. It is
not a production backend state machine.

## Responsibilities

- Define HookPlan order runtime transition semantics.
- Define replay rules from `UVPStateMachine` contract events.
- Keep reference fixtures for first-writer-wins signals, hook readiness, timer
  waits, negative cancellation, and chain-mode expectations.
- Provide equivalence tests that compare reducer behavior with chain events.
- Document replay, duplicate signal, dispatch, and timeout behavior.

## Non-Responsibilities

- Do not hold authoritative production state.
- Do not implement relayer APIs.
- Do not send checker signals.
- Do not contain Solidity contract source.
- Do not decide plan publisher, order registrar, trust registry, or signal
  submitter authorization.
- Do not model escrow, custody, settlement, release, refund, or payment state.
- Do not import the Go `uvp` state machine.

## Interface Rules

- Event replay must treat chain events as the only source of truth.
- Any state visible in `uvp-chain-services/service/` must be derivable from replay.
- The reference model must reject transitions that contracts reject.
- If `UVPStateMachine` event behavior changes, update this module's chain-mode
  fixtures in the same change.

## Testing Expectations

- Pure transition tests.
- Replay tests from current state-machine event fixtures.
- Timeout and challenge period tests.
- Duplicate signal and invalid signer tests.
- Contract equivalence tests for `uvp-protocol/contracts/uvp-contracts/`.
