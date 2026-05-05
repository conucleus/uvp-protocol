# AGENTS.md

## Module Purpose

`uvp-protocol/contracts/uvp-contracts/` owns the Solidity source, ABI fixtures,
deployment artifacts, and contract tests for the EVM UVP state-machine track.

`UVPStateMachine`, its protocol modules, `ZhixuTrustRegistry`, and
`UVPDeploymentRegistry` are the authoritative chain layer for plan, order,
signal, hook, timer, trust-attestation state, and versioned state-machine
deployment cutover.

## Responsibilities

- Implement `ZhixuTrustRegistry` owner-controlled plan and supplier attestation
  contracts. A registry address is the trust boundary; do not reintroduce trust
  domains.
- Implement `UVPStateMachine` plan publisher governance, order registrar
  governance, order registration, signal submitter authorization,
  first-writer-wins signals, hook evaluation, and timers.
- Keep stage patch, derived signal, docking, plan metadata, order link, and lens
  behavior in explicit module contracts configured by the state-machine owner.
- Implement `UVPDeploymentRegistry` as a versioned redeployment cutover ledger;
  it records active deployments for new orders but must not forward signals or
  hold order state.
- Emit stable events for indexers and replay tools.
- Maintain ABI and deployment fixtures.

## Non-Responsibilities

- Do not implement web UI.
- Do not implement relayer APIs.
- Do not store plaintext evidence or trade documents.
- Do not create executor business signatures in protocol helpers.
- Do not implement escrow, custody, exchange, stablecoin settlement, release,
  refund, or payment-provider behavior in the protocol core.

## Contract Rules

- Treat ABI, event topics, constructor args, function selectors, and fixture
  hashes as public interfaces.
- `UVPStateMachine.registerPlan` must require an allowed publisher, but must not
  hold, query, or enforce a trust registry.
- Public order creation must go through signed trigger-order entrypoints
  (`triggerOrderFromOutsideFor` on the core or `triggerOrderFromSignalFor` on
  the order-link module), require an allowed registrar transaction sender, and
  recover the business submitter.
- Product order paths must bind explicit signal submitter authorization before
  accepting first-writer-wins signals unless a target stage has an active
  executor overlay; in that case the overlay's active executor is the only valid
  submitter for that target-stage signal.
- Every hook state transition and emitted readiness event must be replayable.
- Future fund movement must be modeled as a separate adapter PRD and separate
  adapter code; it must consume state-machine signals rather than replacing the
  semantic core.
- Prefer explicit versioning over silent storage or ABI changes.
- State-machine upgrades must be modeled as new deployments registered and
  activated through `UVPDeploymentRegistry`, not as proxy storage upgrades.

## Testing Expectations

- Unit tests for each contract.
- Unauthorized publisher, registrar, and signal submitter tests.
- Official plan attestation and revocation tests.
- First-writer-wins duplicate signal tests.
- Hook readiness, timer, negative-cancel, and replay parity tests.
- ABI/hash fixture verification for state-machine and trust-registry contracts.
