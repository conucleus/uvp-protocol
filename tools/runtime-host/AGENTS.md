# AGENTS.md

## Module Purpose

`uvp-protocol/tools/runtime-host/` owns the first runnable off-chain UVP semantic host. It turns
compiled HookPlans and incoming SignalEnvelopes into append-only runtime events,
applies the `statemachine` reducer, and exposes local HTTP dispatcher/timer
adapter seams for executor-kit development.

## Responsibilities

- Maintain an append-only runtime event store interface.
- Host plan registration, order registration, signal receipt, timer due, and
  dispatch result events.
- Keep in-memory projections rebuildable from the event log.
- Provide deterministic tests with both in-process and HTTP executor-kit loops.
- Provide a local HTTP API for reference-runtime testing.

## Non-Responsibilities

- Do not implement PostgreSQL or Kafka storage.
- Do not become the production ETH runtime authority.
- Do not persist canonical chain-native order state.
- Do not contain chain-specific contract logic.

## Interface Rules

- Runtime state must be replayable from `RuntimeEventStore`.
- Dispatcher adapters must not evaluate hook rules.
- `HookReady` means dispatchable, not business completion.
- For chain-native orders, `UVPStateMachine` events and `chain-services`
  projections are the product-facing source; runtime-host remains a harness.
