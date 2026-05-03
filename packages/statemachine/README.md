# statemachine

Reference semantics for UVP HookPlan runtime and `UVPStateMachine` chain-event
replay.

This module describes the platform-neutral trigger/reducer semantics and the
chain-mode replay oracle for `UVPStateMachine`. It is a reference model and test
oracle, not a backend runtime and not Solidity source.

## State Model

- order runtime signal set with first-writer-wins semantics;
- hook lifecycle: `init | wait | reg | dispatched | fail | cxl`;
- wait timers derived from signal receive time;
- dispatch effects emitted as data, not direct executor calls;
- deterministic replay from event logs.

## Replay Goal

Given only a `HookPlan` and runtime events, this module rebuilds the runtime
state deterministically. For the ETH track, `UVPStateMachine` and
`ZhixuTrustRegistry` events are the authoritative replay input; runtime-host
events are reference-harness input.

## Local Package

```bash
pnpm install
pnpm --filter @uvp-eth/statemachine test
pnpm --filter @uvp-eth/statemachine typecheck
```

## Source

- `src/runtime.ts`: platform-neutral HookPlan reducer for `PlanRegistered`,
  `OrderRegistered`, `SignalReceived`, `TimerDue`, dispatch, and executor patch
  events.
- `src/chain.ts`: stable chain-event adapter for `PlanRegistered`,
  `OrderRegistered`, `SignalSubmitted`, `HookStatusChanged`, `HookReady`, and
  `TimerPoked` oracle replay.
- `fixtures/chain-hook-oracle.events.json`: chain-mode golden fixture for
  duplicate signals, timer due, negative cancellation, and ready-once behavior.
- `test/runtime.test.ts`: HookPlan runtime tests for duplicate signals, timer
  promotion, negative cancellation, dispatch completion, callback signals, and
  deterministic replay.
- `test/chain.test.ts`: chain adapter and golden replay tests.

## HookPlan Runtime Semantics

`DispatchSucceeded` only records that a ready hook was delivered to an executor.
It moves the hook from `reg` to `dispatched`; it does not represent business
completion. Business completion is a normal `SignalReceived` event such as
`task.stage.cmp`, emitted by the executor or an adapter and stored in the order
signal set.

## Chain-Mode Oracle

Chain-mode replay intentionally uses a stable event shape instead of Solidity
ABI bindings. It maps `SignalSubmitted` to runtime `SignalReceived` and
`TimerPoked` to runtime `TimerDue`. Chain-emitted `HookReady` and
`HookStatusChanged` events are treated as golden expectations and compared with
the reducer's `HookReady`, `HookWaiting`, and `HookCancelled` effects.

Plan publisher governance, order registrar governance, official-domain
attestation checks, and signal submitter authorization are contract rules. This
package verifies the resulting event stream and hook semantics; it does not
replace contract authorization.

This mode does not model HTTP dispatchers, runtime-host queues, executor-kit
delivery, escrow, funding, or payment adapters. A successful dispatch is never
interpreted as business completion; the only completion input is a submitted
business signal.

PRD109 tracks docked Zhixu runtime as an explicit prototype surface. Store
docking sandbox signal maps are not enough for this package to claim linked
Zhixu replay until linked order facts and mapped signals are represented in
replay input and proof projection.
