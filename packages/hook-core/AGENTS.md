# AGENTS.md

## Module Purpose

`uvp-protocol/packages/hook-core/` owns the platform-neutral UVP Hook DSL semantics.

It is shared by `uvp-protocol/packages/compiler/` and `uvp-protocol/packages/statemachine/` so hook parsing, dependency
extraction, timer behavior, and trigger evaluation never diverge between build
time and runtime.

## Responsibilities

- Parse `{source}::{condition}` Hook DSL expressions.
- Normalize Hook ASTs into stable expressions.
- Extract positive, negative, and timer dependencies.
- Evaluate hooks against a signal index and current time.

## Non-Responsibilities

- Do not call executors.
- Do not write to databases or chains.
- Do not import app-specific escrow logic.
- Do not implement supplier governance.

## Interface Rules

- Parser and evaluator changes are runtime semantic changes.
- Keep outputs deterministic and JSON-serializable.
- Treat signal receive time as the runtime truth for timers.
