# uvp-dock

Standalone EVM Dock controller package (`UVPDockController`, `UVPDockEvaluator`, `IUVPDockController`), physically isolated from the frozen `uvp-contracts` core.

## Module Boundaries

- Consumes `uvp-contracts` interfaces and libraries via Foundry remapping (`uvp-contracts/=lib/uvp-contracts/src/`, backed by relative symlink `lib/uvp-contracts -> ../../uvp-contracts`) without modifying any frozen core contract or fixture.
- Registers itself as a regular supplier (`controllerSupplierId`) in `UVPIdentityRegistry` on deployment; external registrar activation (`activateSupplier`) is required before target orders can execute through it.
- Interacts with `UVPStateMachine` strictly through standard public read/write interfaces (`getSignal`, `hasSignal`, `signalAdmissionVerdict`, `effectiveStageAccount`, `submitSignal`).
- Does not enter `UVPStateMachine.moduleSetHash()` or `freezeModules()`.
- Enforces uniqueness only on the target stage slot `(toPlanId, toOrderId, toStageId)` so a single source order supports 1:N fan-out, while bidirectional pairing composes two unidirectional links atomically via `bindLinkPair`.

## Local Run

```bash
forge test -vv
```
