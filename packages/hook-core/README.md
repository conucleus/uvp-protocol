# hook-core

Platform-neutral Hook DSL parser, dependency extractor, and evaluator for UVP.

This package is the shared semantic core used by `compiler` and `statemachine`.
It does not know about databases, Solidity, escrow, Kafka, or funding adapters.

## P0 Semantics

- Supported operators: `&`, `|`, `~`, `+5s/+30m/+1h/+1d`, and parentheses.
- Cross-source facts are consumed via the unified subscription entry
  `::ANCHOR(@source::stage.signal)` (empty source header). Delivery is
  per contributing event with full provenance; aggregation/pairing is the
  subscribing executor's decision. Order birth is declared by
  `sendSignals[].trigger: true` (birth stages accept subscription entries only).
- Signal references use `stage.signal`; subscription entries use the unified
  `::ANCHOR(...)` header form.
- Runtime signal indexes are first-writer-wins by `source::signalName`.
- Negative conditions are monotonic: once `~A` sees `A`, the hook evaluates to
  `cxl`, even if another positive anchor has not arrived yet.
- Delays use the positive anchor's first receive time; `AND` waits on the
  latest live due timer, while `OR` waits on the earliest live due timer.

```bash
pnpm --filter @uvp-eth/hook-core typecheck
pnpm --filter @uvp-eth/hook-core test
```
