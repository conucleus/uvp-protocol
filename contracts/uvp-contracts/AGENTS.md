# AGENTS.md

## Module Purpose

`uvp-protocol/contracts/uvp-contracts/` owns the Solidity source, ABI fixtures,
deployment artifacts, and contract tests for the EVM UVP state-machine track.

`UVPStateMachine`, `ZhixuTrustRegistry`, and `UVPDeploymentRegistry` are the
authoritative chain layer for plan, order, signal, hook, timer, trust-attestation
state, and versioned state-machine deployment cutover.

## Responsibilities

- Implement `ZhixuTrustRegistry` official-domain, plan, and supplier
  attestation contracts.
- Implement `UVPStateMachine` plan publisher governance, order registrar
  governance, official plan checks, order registration, signal submitter
  authorization, first-writer-wins signals, hook evaluation, and timers.
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
- `UVPStateMachine.registerPlan` must require an allowed publisher and an active
  official trust-registry attestation.
- `UVPStateMachine.registerOrder` must require an allowed registrar and must
  reject revoked plans.
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
