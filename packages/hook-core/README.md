# hook-core

Platform-neutral Hook DSL parser, dependency extractor, and evaluator for UVP.

This package is the shared semantic core used by `compiler` and `statemachine`.
It does not know about databases, Solidity, escrow, Kafka, or funding adapters.

## P0 Semantics

- Supported operators: `&`, `|`, `~`, `+5s/+30m/+1h/+1d`, and parentheses.
- Supported external anchors: `OUTSIDE`, `OUTSIDE@(...)`, and `OUTSOURCE@(...)`.
- Signal references must use `task.stage.signal`.
- Runtime signal indexes are first-writer-wins by `source::signalName`.
- Negative conditions are monotonic: once `~A` sees `A`, the hook evaluates to
  `cxl`, even if another positive anchor has not arrived yet.
- Delays use the positive anchor's first receive time; `AND` and `OR` wait on
  the earliest live due timer.

```bash
pnpm --filter @uvp-eth/hook-core typecheck
pnpm --filter @uvp-eth/hook-core test
```
