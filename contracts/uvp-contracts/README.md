# uvp-contracts

Solidity contracts for the EVM UVP state-machine track.

Public status: alpha contracts. They define the current protocol boundary and
fixture hashes, but they have not had an external security audit.

This module is a Foundry-style Solidity project. It is intentionally independent
from the Go UVP repository. Contracts, ABI fixtures, and contract tests live
under this folder; repository-level deployment scripts live under
`uvp-deploy/deploy/`.

## Layout

- `src/ZhixuTrustRegistry.sol`: owner-controlled plan/supplier attestation and
  revocation registry. The registry address is the trust boundary.
- `src/UVPStateMachine.sol`: compact core state machine for plan, order, signal,
  timer, hook status, publisher governance, registrar governance, explicit
  order-level signal authorization, and trigger-order links.
- `src/UVPStagePatchModule.sol`, `src/UVPDerivedSignalModule.sol`,
  `src/UVPDockingModule.sol`, and `src/UVPStateMachineLens.sol`: protocol
  modules configured by the core owner for patch, derived signal, docking, and
  read-helper surfaces.
- `src/UVPDeploymentRegistry.sol`: on-chain cutover ledger for versioned
  state-machine redeployments. It records candidate, canary, active,
  deprecated, and retired deployments for new-order routing; it does not
  forward signals or store order state.
- `src/libraries/ECDSA.sol`: minimal signature recovery helper.
- `src/libraries/UVPSignatures.sol`: shared signature struct used by relayed
  state-machine signal submission.
- `fixtures/uvp-state-machine.v0.7.json` and module fixture JSON files:
  pinned ABI/hash fixtures for the current core and module public interfaces.
- `fixtures/zhixu-trust-registry.v0.2.json`: pinned ABI/hash fixture for the
  current trust registry public interface.
- `test/`: dependency-free Solidity tests.

## Local Commands

Install Foundry, then run from this directory:

```bash
forge fmt
forge build
forge test
```

From the repository root, verify checked-in ABI/hash fixtures after the matching
fixture version has been refreshed:

```bash
pnpm verify:state-machine-fixture
pnpm verify:trust-registry-fixture
```

For the cross-module local Anvil bootstrap, run from the repository root:

```bash
uvp-deploy/deploy/scripts/bootstrap-local-anvil.sh --self-update
uvp-deploy/deploy/scripts/bootstrap-local-anvil.sh --failure
```

That script deploys `UVPDeploymentRegistry`, `UVPStateMachine`, the protocol
modules, and `ZhixuTrustRegistry`, registers compiler output, submits chain
signals, records registry cutover evidence, and verifies emitted events through
the TypeScript `statemachine` oracle.

## ABI Fixture

`UVPStateMachine v0.7` treats these as public interfaces:

- its no-argument constructor;
- owner/governance functions for plan publishers and order registrars;
- core function selectors for `registerPlan`, signed
  `triggerOrderFromOutsideFor`, signed `triggerOrderFromSignalFor`,
  `submitSignal`, `submitSignalFor`, module configuration, module-only
  writebacks, `signalSubmissionDigest`,
  `signalAuthorizationsHash`, trigger-order digest helpers,
  `DOMAIN_SEPARATOR`, `pokeTimer`, `orderPlanId`, `getHookStatus`,
  `isSignalSubmitterAuthorized`, `getSignalAuthorization`, executor patch mode
  constants, `DOCKED_ORDER_LINK_SIGNAL_ID`, signal target relation constants,
  `sourceSignalCount`, `lastSignalSubmitter`, stage-overlay view helpers,
  trigger-link view helpers, and signal capability helpers;
- module function selectors for stage patch, derived signal, docking, and lens
  entrypoints/digest helpers/views;
- event topics for ownership, publisher/registrar changes, `PlanRegistered`,
  `PlanPublisherRecorded`, `OrderRegistered`, `OrderMaterialized`,
  `OrderRegistrarRecorded`, `SignalCapabilityRegistered`, `OrderTriggered`,
  `OrderLinked`, `SignalSubmitterAuthorized`, `SignalSubmitted`,
  `StageMaterialized`, `HookStatusChanged`, `HookReady`, `TimerPoked`,
  `StageExecutorPatchApplied`,
  `StageResourcePatchApplied`, `StageExecutorActivated`, `DockedOrderLinked`,
  `DockedSignalMapped`, and `DockedSignalSubmitted`;
- ABI hash, bytecode hash, deployed bytecode hash, canonical artifact hash, and
  solc version.

Changing any of those values requires an explicit fixture update and adapter
review. The verifier is deliberately strict so watcher, replay, and deployment
code do not silently drift away from the contract ABI.

## MVP Chain Behavior

1. The deployer creates a `ZhixuTrustRegistry`; that registry address is the
   trust boundary.
2. The registry owner attests a compiled plan hash, artifact hash, policy hash,
   metadata hash, and metadata URI.
3. `UVPStateMachine` is deployed without registry constructor arguments.
4. The owner allowlists plan publishers and order registrars.
5. An allowed publisher registers a compact hook plan. Plan trust is a product
   and Store policy projected from the configured registry, not a state-machine
   runtime precondition.
6. An allowed registrar or relayer submits a signed trigger-order request. The
   contract recovers the business submitter, creates the order, writes explicit
   `SignalAuthorization[]` records, records the trigger fact, and materializes
   the ready trigger stage atomically.
7. Only authorized submitter wallets can call `submitSignal` for their bound
   `sourceId + signalId`. A gas relayer can use `submitSignalFor` with the
   authorized submitter's EIP-712 signature; the recorded submitter remains the
   business signer, not the relayer.
8. A wallet authorized for `EXECUTOR_PATCH_SIGNAL_ID` on a stage may apply an
   order-level executor patch through `UVPStagePatchModule` for a registered
   stage-to-target binding.
   Executor patches use `assign` before the target stage has signals, `handoff`
   after start with the previous executor's signature over the same EIP-712
   digest, or `replacement` after start with a chain-visible approval signal.
9. Executor patches constrain executor-only patch actions. Normal business
   signals still require explicit order-level authorization or a compiled
   derived signal capability; an active executor patch does not erase existing
   signal submitter authorizations. Prior `SignalSubmitted` events keep their
   original submitter.
10. A wallet authorized for `RESOURCE_PATCH_SIGNAL_ID` on a stage may apply an
    independent resource-manifest patch through `UVPStagePatchModule` for a
    target stage and resource key. The chain stores hashes, nonces, and manifest
    URIs, not plaintext business documents.
11. A wallet authorized for `DOCKED_ORDER_LINK_SIGNAL_ID` on a local stage may
    link an independent order through `UVPDockingModule` as a docked Zhixu
    execution interface. The link records the linked order id, linked plan id,
    signal bindings, metadata URI, and nonce. `submitDockedSignal` can then map
    an accepted linked-order signal into the local order according to the
    registered binding. The two orders keep independent plans, authorization,
    events, and lifecycle.
12. `triggerOrderFromOutsideFor` and `triggerOrderFromSignalFor` create orders
    through signed trigger paths. Signal-triggered child orders record a parent
    link so `UVPDerivedSignalModule` can write declared signals back to the
    trigger parent order.
13. The state machine evaluates compact hook instructions, emits
    `HookStatusChanged`, `HookReady`, and `TimerPoked`, and can be replayed from
    events by `statemachine` and `chain-services`.

`registerOrder` is not a public business ABI in v0.7. New order creation
must pass through a trigger-order entrypoint so order materialization and the
first trigger fact share one chain transaction and one business signer.

## Stable Events

Indexer and replay tooling should treat these event names as public interfaces:

- `OwnershipTransferred`
- `PlanAttested`
- `PlanRevoked`
- `SupplierAttested`
- `SupplierRevoked`
- `PlanPublisherSet`
- `OrderRegistrarSet`
- `PlanPublisherRecorded`
- `OrderRegistrarRecorded`
- `SignalCapabilityRegistered`
- `SignalSubmitterAuthorized`
- `PlanRegistered`
- `OrderRegistered`
- `OrderTriggered`
- `OrderLinked`
- `SignalSubmitted`
- `StageExecutorPatchApplied`
- `StageResourcePatchApplied`
- `StageExecutorActivated`
- `DockedOrderLinked`
- `DockedSignalMapped`
- `DockedSignalSubmitted`
- `HookStatusChanged`
- `HookReady`
- `TimerPoked`
- `DeploymentRecorded`
- `DeploymentStatusChanged`

## Hook State Machine

`UVPStateMachine` stores compact hook plans, order-to-plan bindings,
first-writer-wins signals, explicit signal submitter authorization, hook statuses
(`Init`, `Wait`, `Ready`, `Cancelled`), and timer due timestamps. It emits
`HookReady` once per hook when positive and timer conditions become satisfied;
negative signals can cancel hooks before the off-chain execution layer acts on
readiness.

## Funding Boundary

No funding, escrow, custody, settlement, release, refund, dispute-payment, ERC20,
or USDC contract lives in this module now. Future funding work must be a
separate adapter with its own PRD, authorization model, event mapping, and tests.
It must consume state-machine signals rather than replacing `UVPStateMachine` as
the protocol source of truth.

## Security Baseline

Contracts must be reviewable without relying on any off-chain backend. Any
state-machine signal must be authorized by contract checks, not by backend
database state. Any future action that moves funds must be implemented as an
adapter with its own authorization and accounting checks.

Known limits:

- Role administration is owner-managed and intentionally minimal.
- The state-machine authorization model has explicit submitter records but no
  revocation event yet; existing signals remain immutable.
- The no-authorization order overloads are compatibility paths; they create
  closed orders with no submitters and should not be used by the product flow.
