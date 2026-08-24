# hook-core

Platform-neutral Hook DSL parser, dependency extractor, and evaluator for UVP.

This package is the shared semantic core used by `compiler` and `statemachine`.
It does not know about databases, Solidity, escrow, Kafka, or funding adapters.

## P0 Semantics

- Supported operators: `&`, `|`, `~`, `+5s/+30m/+1h/+1d`, and parentheses.
- Backend/executor external inputs are declared by stage `externalSignals`.
- Supported cross-source wrappers: `::OUTSIDE@(source::task.stage.signal)`,
  `::MERGE@(source::a.cmp, source::b.cmp)`, and
  `::ANCHOR@(task.stage.signal)`. All three require an empty source header.
  `OUTSOURCE` is retired syntax and is rejected by the parser.
- Bare `OUTSIDE` / `OUTSOURCE` / `ANCHOR` hook conditions are removed syntax.
- `MERGE@` and `ANCHOR@` entries are delivered per contributing event by the
  runtime; core evaluation reports `needs_more` for them. On-chain HookPlan
  compilation does not support them yet and fails fast.
- Signal references must use `task.stage.signal`.
- Runtime signal indexes are first-writer-wins by `source::signalName`.
- Negative conditions are monotonic: once `~A` sees `A`, the hook evaluates to
  `cxl`, even if another positive anchor has not arrived yet.
- Delays use the positive anchor's first receive time; `AND` waits on the
  latest live due timer, while `OR` waits on the earliest live due timer.

```bash
pnpm --filter @uvp-eth/hook-core typecheck
pnpm --filter @uvp-eth/hook-core test
```
