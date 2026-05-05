# statemachine

Offline chain replay oracle for `UVPStateMachine` events.

This module verifies chain-emitted hook semantics from `UVPStateMachine` event
streams. It is a test oracle, not a backend runtime or Solidity source.

## State Model

- plan and order facts reconstructed from chain events;
- order signal set with first-writer-wins semantics;
- hook lifecycle: `init | wait | reg | cxl`;
- delay/timer evaluation from `SignalSubmitted` and `TimerPoked`;
- deterministic replay from `UVPStateMachine` event logs.

## Replay Goal

Given only chain events and minimal hook metadata derived from the on-chain
artifact/register-plan boundary, this module rebuilds the expected hook state
deterministically. For the ETH track, `UVPStateMachine` and
`ZhixuTrustRegistry` events are the authoritative replay input.

## Local Package

```bash
pnpm install
pnpm --filter @uvp-eth/statemachine test
pnpm --filter @uvp-eth/statemachine typecheck
```

## Source

- `src/chain.ts`: stable chain-event adapter for `PlanRegistered`,
  `OrderRegistered`, `SignalSubmitted`, `HookStatusChanged`, `HookReady`, and
  `TimerPoked` oracle replay.
- `fixtures/chain-hook-oracle.events.json`: chain-mode golden fixture for
  duplicate signals, timer due, negative cancellation, and ready-once behavior.
- `test/chain.test.ts`: chain adapter and golden replay tests.

## Chain-Mode Oracle

Chain replay intentionally uses a stable event shape instead of Solidity ABI
bindings. `PlanRegistered` carries the compact hook metadata needed by the
oracle. `SignalSubmitted` and `TimerPoked` are treated as inputs. Chain-emitted
`HookReady` and `HookStatusChanged` events are treated as golden expectations
and compared with oracle observations.

Plan publisher governance, order registrar governance, official-domain
attestation checks, and signal submitter authorization are contract rules. This
package verifies the resulting event stream and hook semantics; it does not
replace contract authorization.

This mode does not model HTTP dispatchers, executor-kit delivery, escrow,
funding, or payment adapters. A successful delivery is never interpreted as
business completion; the only completion input is a submitted business signal.

PRD109 tracks docked Zhixu runtime as an explicit prototype surface. Store
docking sandbox signal maps are not enough for this package to claim linked
Zhixu replay until linked order facts and mapped signals are represented in
replay input and proof projection.
