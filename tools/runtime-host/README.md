# runtime-host

In-process UVP HookPlan runtime host and off-chain reference harness.

This package is the first runnable shell around the shared semantic core:

```text
SignalEnvelope -> RuntimeEventStore -> statemachine reducer -> HookReady -> RuntimeDispatcher
```

The implementation is intentionally in-memory plus a small local HTTP API. It
exists to test HookPlan semantics and executor-kit callbacks without spending
chain gas. It is not the authoritative ETH runtime; `UVPStateMachine` contract
state and events are authoritative for chain-native orders.

`RuntimeDispatcher` may now return callback `SignalEnvelope` values after a
successful dispatch. The host commits `DispatchSucceeded` first, then appends
those returned signals through the same `receiveSignal` path, so replay remains
append-only and deterministic.

`DispatchSucceeded` moves the ready hook to `dispatched`; executor business
completion is still represented only by the returned callback signal, such as
`exec.main.cmp`.

The package test suite includes an in-process bootstrap flow using
`executor-kit`:

```text
compile HookPlan -> register plan/order -> receive init.main.cmp
  -> HookReady(exec.main#START)
  -> executor-kit dispatcher
  -> DispatchSucceeded
  -> exec.main.cmp callback signal
  -> replay equals live projection
```

It also includes a process-boundary HTTP e2e:

```text
runtime-host HTTP server
  -> HTTP dispatcher
  -> executor-kit HTTP server
  -> runtime-host /v0/signals callback
  -> replay equals live projection
```

Local server:

```bash
pnpm --filter @uvp-eth/runtime-host cli -- serve \
  --runtime-token dev-runtime-token \
  --ready-json
```

Important local API routes:

- `POST /v0/plans`
- `POST /v0/orders`
- `POST /v0/signals`
- `POST /v0/dispatch/drain`
- `POST /v0/timers/drain`
- `GET /v0/state`
- `GET /v0/events`

```bash
pnpm --filter @uvp-eth/runtime-host typecheck
pnpm --filter @uvp-eth/runtime-host test
```

Do not add SQLite/Postgres as the next authority for the ETH runtime path. A
durable store may be useful later for local debugging, but chain-native product
state must be rebuilt from `UVPStateMachine` and `ZhixuTrustRegistry` events
through `chain-services`.
