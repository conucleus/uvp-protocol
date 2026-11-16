# uvp-contracts

Solidity contracts for the EVM UVP state-machine track.

Public status: alpha contracts. They define the current protocol boundary and
fixture hashes, but they have not had an external security audit.

This module is a Foundry-style Solidity project. It is intentionally independent
from the Go UVP repository. Contracts, ABI fixtures, and contract tests live
under this folder; repository-level deployment scripts live under
`uvp-deploy/deploy/`.

## Layout

- `src/UVPIdentityRegistry.sol`: owner-controlled offline-subject to wallet
  bindings. Its complete scope is subject/account registration and revocation.
- `src/UVPSupplierRegistry.sol` (+ `src/interfaces/IUVPSupplierRegistry.sol`):
  supplier identity boundary. A supplier self-registers with its own account;
  the registry mints a UUID SID (128-bit low half of a `bytes32`) and binds it
  permanently to that one account. Status is `pending` until a registrar
  activates it; `suspend`/`revoke` are registrar-gated. There is no
  rotate/setAccount write path, revoking does not free the account, and the
  reverse mapping `supplierOf` stays permanent. No EIP-712, no struct,
  no tier/validity/descriptor; identity/KYC data stays off chain.
- `src/UVPSupplierRegistryDebug.sol`: **QA-only** stand-in implementing the same
  interface (every nonzero `supplierId` resolves to one fixed debug account and
  reads as active; writes revert instead of faking registration). Production
  deployment scripts must never wire it — production uses
  `UVPSupplierRegistry` and its registration/status checks.
- `src/UVPStateMachine.sol`: compact core state machine for plan, order, signal,
  timer, hook status, signed Plan publication, supplier-bound signal
  submission (`submitSignal` / `submitSignalFor`), dynamic-stage supplier
  assignment, and trigger-order links.
- `src/UVPDockRegistry.sol`: static Dock registry. A Dock is a one-way
  `A -> B` subscription declared by the B side; the registry stores the
  resolved from/to plans, source/stage ids, the A-side `validWhen` window
  program, its atoms, the B output signals, and the document hash.
- `src/UVPStagePatchModule.sol`, `src/UVPDerivedSignalModule.sol`,
  `src/UVPFileResourceModule.sol`, and `src/UVPStateMachineLens.sol`: protocol
  modules configured by the core owner for stage supplier patch/dock supplier
  selection, derived signal, stage file maps, and read-helper surfaces.
- `src/UVPPlanRegistration.sol`: linked library hosting the externally
  segmented `commitPlan`/`finalizePlan`/`forkOrder` bodies.
- `src/UVPDeploymentRegistry.sol`: on-chain cutover ledger for versioned
  state-machine redeployments. It records candidate, canary, active,
  deprecated, and retired deployments for new-order routing; it does not
  forward signals or store order state.
- `src/libraries/ECDSA.sol`: minimal signature recovery helper.
- `src/libraries/UVPSignatures.sol`: shared signature struct used by relayed
  state-machine signal submission.
- `fixtures/uvp-state-machine.v0.20.json`,
  `fixtures/uvp-plan-registration.v0.7.json`,
  `fixtures/uvp-stage-patch-module.v0.10.json`,
  `fixtures/uvp-derived-signal-module.v0.7.json`,
  `fixtures/uvp-order-link-module.v0.4.json`,
  `fixtures/uvp-supplier-registry.v0.1.json`,
  `fixtures/uvp-file-resource-module.v0.2.json`,
  `fixtures/uvp-state-machine-lens.v0.7.json`,
  `fixtures/uvp-dock-registry.v0.1.json`,
  `fixtures/uvp-plan-metadata-module.v0.8.json`,
  `fixtures/uvp-identity-registry.v0.1.json`,
  `fixtures/uvp-deployment-registry.v0.2.json`: pinned ABI/hash fixtures for
  the current core, linked-library, and module public interfaces.
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
pnpm verify:identity-registry-fixture
pnpm verify:deployment-registry-fixture
```

For the cross-module local Anvil bootstrap, run from the repository root:

```bash
uvp-deploy/qa/scripts/bootstrap-local-anvil.sh --self-update
uvp-deploy/qa/scripts/bootstrap-local-anvil.sh --failure
```

That script deploys `UVPDeploymentRegistry`, `UVPStateMachine`, the protocol
modules (including `UVPSupplierRegistry`), and `UVPIdentityRegistry`, publishes
signed compiler output, submits chain signals, records registry cutover
evidence, and verifies emitted events through the TypeScript `statemachine`
oracle.

## ABI Fixture

`UVPStateMachine` (ABI fixture v0.20, EIP-712 domain version `0.18`) treats
these as public interfaces:

- its no-argument constructor;
- one-time module configuration followed by irreversible `freezeModules`; the
  module set is stage patch, derived signal, dock registry, plan metadata,
  order link, lens, file resource, and supplier registry (all eight slots must
  be set before freeze);
- core function selectors for signed `commitPlan(commit, hooks, bindings,
  signature)` (six-field `PlanCommit`: publisher, hooksHash, capabilitiesRoot,
  `supplierBindingsRoot`, birthAuthorizer, deadline), permissionless
  single-argument `finalizePlan(bytes32)`, derived-order-id
  `triggerOrderFromOutsideFor` (one fact, one order — the id
  is `triggerOrderIdFor(planId, sourceId, signalId, payloadHash)`, callers no
  longer self-report it; `triggerHookId` + `triggerStageId` explicitly select
  one trigger birth line and must name a MINT-flagged hook of that stage; the
  request carries a trailing `birthFactAttribution` proof, no authorization
  array) and `triggerOrderFromOutsideByAuthorizer` (contract
  `birthAuthorizer` direct entry, no signature),
  `submitSignal` (msg.sender path; carries the trailing `attribution` proof,
  `bytes32 filesDigest`, and a trailing `FilePatch filePatch`; `signalId == 0`
  means a pure file patch), and `submitSignalFor` (EIP-712 relayer path; the
  extra `submitter`/`deadline`/`signature` bind the source stage's supplier
  account, and
  `msg.sender` is only the relayer; EOA uses ECDSA, contract submitter uses
  EIP-1271), module configuration, module-only writebacks (including the
  order-link writeback `triggerOrderFromSignalFromModule` and the stage-patch
  activations `activateStageSupplierFromModule` /
  `activateStageDockSupplierFromModule`), `DOMAIN_SEPARATOR`, `pokeTimer`,
  `getHookStatus`, `hasSignal`/`getSignal`, the supplier views
  (`effectiveStageSupplier`, `effectiveStageAccount`,
  `isEffectiveStageAccount`, `stageSupplierAssignment`), plan-binding views
  (`planSupplierBindingsRoot`, `planStageDefaultSupplier`,
  `planStageHasDynamicSupplier`, `planStageIsCandidate`), signal target
  relation constants, `sourceSignalCount`, `lastSignalSubmitter`,
  per-stage native counting (`stageSignalState`), fork helpers
  (`forkOrder`/`forkOrderIdFor`/`orderParent`), plan-runtime-hash helpers,
  the dock-registry directory getter (`dockRegistry`/`setDockRegistry`), the
  dock stage/hook flag queries (`stageHasDockExecutorHook`,
  `stageHasOrderTriggerHook`), the A-window evaluator `evaluateDockWindow`
  (returns current `satisfied` and a relative `dueInSeconds`), the B-window
  query `isSignalAdmissionSatisfied`, and the dock output writeback
  `submitDockOutputSignalFromModule` plus the derived-signal writeback
  `submitDerivedSignalFromModule`. The signed from-signal trigger entrypoint is
  `triggerOrderFromSignalFor` on `UVPOrderLinkModule` (order-link module
  fixture), not a core selector;
- module function selectors for stage patch (stage supplier patch
  `applyStageSupplierPatch`/`For` with `bindingProof` + `candidateProof` and
  the signed selector/previous-supplier-account consent, dock supplier
  selection with `supplierId` + `patchNonce`), file resource (single
  `applyStageFilePatch` entry gated on `msg.sender == stateMachine`, writer
  authority = writer-stage assigned supplier account + `fileWriters`
  capability),
  derived signal (`submitDerivedSignal`/`For`, submit authority = from-stage
  assigned supplier account), dock registry (`registerDock`/`getDock`/
  `getDockOutput`), supplier registry
  (`registerSupplier`/`activateSupplier`/`suspendSupplier`/`revokeSupplier`/
  `setRegistrar`/`transferOwnership`/`accountOf`/`statusOf`/
  `isActiveSupplier`/`supplierOf`), and lens
  entrypoints/digest helpers/views, plus plan-metadata module views
  `capabilitiesRoot`, `hasCapabilityVocabulary`, `verifySignalCapability`,
  `verifyStageSelectorBinding`, and `verifyFileWriter` (membership is checked
  as field-recomputed leaves against caller-supplied Merkle proofs);
- event topics for ownership, module configuration/freeze,
  `PlanCommitted` (carries `supplierBindingsRoot`), `PlanFinalized`,
  `PlanRegistered`, `PlanPublisherRecorded`, `OrderRegistered`,
  `OrderMaterialized`, `OrderRelayerRecorded`, `OrderTriggered`,
  `SignalSubmitted` (carries `submitter`, `relayer`, `factStageId`),
  `StageMaterialized`, `StageSupplierAssigned` (carries `supplierId` +
  `patchNonce`), `HookStatusChanged`, `HookReady`, `TimerPoked`, and
  `OrderForked` (the fork birth channel, UB-39). `SignalAuthorization` events
  are deleted;
- dock registry event `DockRegistered` (carries the full Dock outputs, atoms,
  and A-window program); stage-patch module (`UVPStagePatchModule`) event
  topics for `StageSupplierPatchApplied` (carries `supplierId`,
  `previousSupplierId`, `patchNonce`), `StageDockSupplierSelected` (carries
  `supplierId`), `DockBindingPoked`, and `DockOutputSubmitted`; order-link
  module event topics for `OrderLinked`; derived signal module event topics
  for `DerivedSignalSubmitted`; file resource module (`UVPFileResourceModule`)
  event topics for `StageFilePatchApplied` and `StageFileOpApplied`; supplier
  registry event topics for `SupplierRegistered` (carries `supplierId` +
  `account`), `SupplierStatusChanged` (carries `supplierId`, previous/new
  status, `account`), `SupplierRegistrarSet`, and `OwnershipTransferred`; and
  deployment registry event topics for
  `DeploymentRegistered`, `DeploymentCanaryMarked`, `DeploymentActivated`,
  `DeploymentDeprecated`, and `DeploymentRetired`;
- ABI hash, bytecode hash, deployed bytecode hash, canonical artifact hash, and
  solc version.

Changing any of those values requires an explicit fixture update and adapter
review. The verifier is deliberately strict so watcher, replay, and deployment
code do not silently drift away from the contract ABI.

## MVP Chain Behavior

1. The deployer creates a thin `UVPIdentityRegistry` for Store-operated identity
   bindings; the StateMachine never queries it.
2. `UVPSupplierRegistry` is deployed and wired as the eighth module before
   `freezeModules`; the StateMachine resolves every stage supplier and its
   account through it. `UVPSupplierRegistryDebug` exists only for QA/local
   flows and is never part of a production deployment.
3. `UVPStateMachine` is deployed without registry constructor arguments.
4. The owner configures the complete module set and irreversibly freezes it.
   Runtime or module upgrades require a new state-machine deployment; existing
   orders remain on their original deployment and module set.
5. A publisher signs the six-field `PlanCommit` (publisher, hooksHash,
   capabilitiesRoot, supplierBindingsRoot, birthAuthorizer, deadline) together
   with the hooks and the `StageSupplierBinding[]` list; any relayer commits it.
   Binding kinds are `0 = default` and `1 = candidate`; the contract recomputes
   `supplierBindingsRoot` and rejects a mismatch. Bindings are capped at 256
   (`TooManySupplierBindings`), must be unique, must reference stages declared
   by the hooks, must point at active SIDs (`SupplierNotActive`), and are
   forbidden for dock/dynamic stages (candidate bindings also forbidden for
   birth stages; a candidate binding requires the stage's default binding). Any caller then
   finalizes with `finalizePlan(bytes32)` — a permissionless step that only
   flips the plan to finalized and stores the capabilities root, so its gas is
   independent of table size. A pending Plan cannot create an Order and
   finalized Plan metadata is immutable. Note on naming: the
   `planExists(planId)` view returns "exists AND finalized" — a committed but
   not yet finalized plan returns `false` (the ABI is frozen; consumers use it
   as the "can birth/derive here" gate, for which the two-step middle state must
   read false).
6. Any relayer submits a signed trigger-order request. A plan may carry several
   trigger birth lines: each signal declared with `sendSignals[].trigger: true`
   compiles to one order-trigger hook carrying the reused `ORDER_TRIGGER_MINT`
   bit, and the request selects one line explicitly with `triggerHookId` +
   `triggerStageId` (the hook must carry the order-trigger flag and belong to
   that stage). After the signature and plan / birth-authorizer checks, the
   contract evaluates the selected trigger signal's admission instruction plan
   in an empty order context; only if admitted does it create the order, record
   the trigger fact, and materialize the ready trigger stage atomically — no
   order-level authorization records are written. A rejected admission reverts
   `SignalAdmissionRejected(orderId, sourceId, signalId)` before the order
   exists. The plan keeps one plan-wide `birthAuthorizer`.
7. Signal submission authority is the source stage's **assigned supplier
   account**: the effective supplierId is the active stage-patch supplier when
   one exists, else the plan's default supplier (fixed/candidate/birth), else
   zero for a dynamic stage; the account is
   `supplierRegistry.accountOf(effectiveSupplierId)` and the SID must be
   `active`. `submitSignal` uses `msg.sender` as the submitter;
   `submitSignalFor` lets a relayer pay gas while the submitter's EIP-712
   signature (ECDSA or EIP-1271) binds the same supplier account. Missing
   assignment reverts `StageSupplierNotAssigned`, a non-active SID reverts
   `SupplierNotActive`, a missing registry wiring reverts
   `SupplierRegistryNotConfigured`, and a wrong wallet reverts
   `UnauthorizedStageSupplierAccount`. There is no order-level submitter
   allowlist.
   External submissions are idempotent first-win: a fact already recorded for
   the order is absorbed silently instead of reverting (at-least-once retries
   must never be rejected by an expired admission window). Plans may declare an
   emission admission face (`CompactHook` flag 8, compiled from
   `sendSignals[].validWhen`, trigger signals included): when the plan commits
   one for the submitted fact key, the contract evaluates its instruction plan
   over the pre-state at `block.timestamp` and reverts the typed
   `SignalAdmissionRejected(orderId, sourceId, signalId)` unless the verdict is
   Ready — nothing is recorded, no hooks advance. Derived-signal writes stay
   below this chokepoint, and dock output writes deliberately run the same
   admission verdict again (a not-yet-open B window skips the output instead of
   recording a failure); outside birth
   (`triggerOrderFromOutsideFor` / `triggerOrderFromOutsideByAuthorizer`)
   evaluates the trigger signal's admission instruction plan in an empty-order
   context before the order exists, so a positive-anchored admission rejects
   there — birth writes do not bypass admission.
8. Dynamic stages (`HOOK_FLAG_DYNAMIC_EXECUTOR`, flag 32) are collected from
   receive hooks at `commitPlan`: a stage mixing dynamic and non-dynamic hooks
   reverts `InconsistentDynamicExecutorFlag`; the flag is forbidden on trigger
   and dock hooks and requires `EMIT_READY`. A dynamic stage has no default
   supplier; its supplier must be assigned through the stage supplier patch
   before the stage's first signal, otherwise `_requireEffectiveSupplier`
   reverts `StageSupplierNotAssigned`. Stage materialization stays per-stage:
   every stage (dynamic included) materializes only through its own
   order-trigger or EMIT_READY hooks.
9. Order-level stage supplier change goes through `UVPStagePatchModule`. The
   selector must be the selector stage's assigned supplier account (there is no
   order-creator bypass) and the plan must declare the
   `(selectorStageId, targetStageId)`
   binding in `capabilitiesRoot`. The patch payload is
   `{ selectorStageId, targetStageId, supplierId, previousSupplierId,
   patchNonce }` and `patchNonce` must increase.
   - `previousSupplierId == 0` is **assign**: only before the target stage's
     first signal (`StageAlreadyHasSignal` otherwise), and any active SID may be
     assigned for a dynamic stage.
   - non-zero is **handoff**: only after the stage's first signal
     (`StageHasNoSignal`), the declared `previousSupplierId` must equal the
     current effective supplier, and the previous supplier account must sign
     the same EIP-712 digest.
   - candidate stages additionally require a Merkle proof for the
     `(targetStageId, supplierId, kind=1)` leaf against `supplierBindingsRoot`
     (`StageSupplierNotCandidate`); fixed stages revert
     `StageSupplierPatchForbiddenOnFixedStage`; dynamic stages require no
     proof; dock and birth stages revert
     `StageSupplierPatchForbiddenOnDockStage` /
     `StageSupplierPatchForbiddenOnBirthStage`. Assignments must point at an
     active SID (`SupplierNotActive`).
10. Stage file maps are owned by `UVPFileResourceModule` (configured as
    `fileResourceModule()` before `freezeModules`). A stage's map is
    `key -> (contentHash, handle)`: the chain stores a content hash and an
    opaque bounded handle, never plaintext, and never resolves the handle. The
    chain does not define or interpret a file type: types are backend-defined,
    freestyle and non-enumerable, and the engine must not carry a type/taxonomy
    or storage decision on chain.
    Writes are first-class patch facts (`add` requires the key absent,
    `replace`/`remove` require it present; strict, whole-patch atomic) carrying
    a mandatory `baseHash` equal to the stage's current files version —
    mismatch rejects the whole request, and there is no nonce (the projection
    holds exactly one current value per key). Write authority is the writer
    stage's **assigned supplier account** (the submitter of the business signal or
    file patch); when the writer stage differs from the target stage, the
    `fileWriters` capability leaf (`UVP_FILE_WRITER_V1`) must also prove the
    stage pair. There is no reserved `FILE_WRITE_SIGNAL_ID` row and no
    order-level authorization table. `writerStageId == 0` resolves to the
    business signal's stage, or to the target stage for a pure file patch. A
    file patch may ride one business signal in the same direct call, or stand
    alone as an empty signal (`signalId == 0`); a pure file patch is not a
    business signal — it does not increment business signal counts, does not
    evaluate hooks, and does not run admission. There is no "stage has signal"
    gate for files.
11. Docking is a static A -> B time-window binding. A Dock is registered in
    `UVPDockRegistry` as a B-side declaration: from/to plans, `from.source`,
    `to.stage`, B output signal ids, the A-side `validWhen` window program
    (`WindowInstruction[]`, the Hook-DSL stack program with atoms, `AND`/`OR`,
    `~` and `+T`), the program atoms, and the document hash. Registration is
    permissionless but proves every output against the B plan's
    `capabilitiesRoot` and every atom against the A plan's
    `capabilitiesRoot` (per-atom Merkle proofs), so a Dock can only reference
    declared signals.
    A dock stage is selected once through `UVPStagePatchModule`: the selector
    signs `StageDockSupplierSelection` (selector stage, target stage, dock id,
    `supplierId`, `patchNonce`), the contract checks the dock stage flag
    (`HOOK_FLAG_DOCK_EXECUTOR`), the selector binding, that the selector is the
    selector stage's assigned supplier account, that the SID is active, and
    that the dock/stage/plan relations match. There is no per-output
    order-level authorization row; the selected SID's supplier account is the
    submitter for output writes. Replays of the same dock id +
    supplier are absorbed, a different selection reverts. There is no link
    record and no activation: the payload is the attach stage's
    `fileResource` entry with key `keccak("dock_link")`, plain-text canonical A
    order id (`0x` + 64 hex). `pokeDockBinding` (permissionless) checks the
    payload content hash against the file record, verifies the A order exists
    under the dock's from plan, evaluates the A window program against A facts
    through the state machine's `evaluateDockWindow` (same evaluator as hooks;
    `~` closes on fact arrival, `+T` delays the anchor), and writes each
    satisfied B output signal through `submitDockOutputSignalFromModule` with
    the selected SID's supplier account as submitter. The B plan's own
    `sendSignals.validWhen` admission is judged again at write time; a closed B
    window skips the output (no failure state). The binding is identified only
    by the selected dock id, the target order/stage, the from order, and the
    `dock_link` file value (the canonical A order id):
    `bindingId = H("uvp.dock.binding_id.v1", dockId, toPlanId, toOrderId,
    toStageId, fromPlanId, fromOrderId)` (seven 32-byte words, no payload
    hash). The file record's internal `contentHash` is only used to
    authenticate the revealed payload content in `pokeDockBinding`; it never
    enters the binding id, events, views, or fact provenance. Per-output
    first-wins: an already-recorded B signal is never overwritten, and the B
    fact's provenance carries the binding id. Read views `getStageDockBinding` /
    `dockOutputWindow` take the from-order id, report whether a `dock_link`
    file record exists (the binding is current), and expose current A/B window
    satisfaction, relative `dueInSeconds`, and emitted status; historical
    window times are not on chain.
12. `triggerOrderFromOutsideFor` and `triggerOrderFromSignalFor` create orders
    through signed trigger paths. Signal-triggered orders record a trigger-origin
    link so `UVPDerivedSignalModule` can write declared signals back to the
    trigger-origin order. Establishing a trigger link requires origin-side
    consent: the origin order's creator or the assigned supplier account of the
    origin source stage (`hasTriggerOriginConsent`, which resolves the origin
    source stage's assigned supplier account); the old explicit per-fact
    authorization lookup is gone. A foreign plan mirroring the origin plan's
    public capability declarations without that standing cannot register the
    link nor create the derived order.
13. The state machine evaluates compact hook instructions, emits
    `HookStatusChanged`, `HookReady`, and `TimerPoked`, and can be replayed from
    events by `statemachine` and `chain-services`.

`registerOrder` is not a public business ABI. New order creation
must pass through a trigger-order entrypoint so order materialization and the
first trigger fact share one chain transaction and one business signer.

### Order identity is (planId, orderId)

Order storage is addressed by the composite `(planId, orderId)` key across
the state machine and every module (order-link, dock binding, stage-patch
views included). An `orderId` alone is not a global key: two plans can each own an
order with the same `orderId` without colliding, and no entry point can
address one plan's order by presenting another plan's id. Within one plan, a
second registration of the same `orderId` reverts with
`OrderAlreadyRegistered`. Off-chain order-id derivation formulas must fold
`planId` into their domain so derived order ids are plan-scoped by
construction. Function signatures take a leading `planId` parameter, and the
from-signal trigger request carries `originPlanId`. Event signatures are
pinned in the v0.20 and module fixtures; indexers must consume the composite
identity in every event and projection rather than treating `orderId` as
globally unique.

## EIP-712 Domains

Domain versions are part of the frozen public surface: main
`UVPStateMachine`/product-submit and `UVPPlanRegistration` `0.18`,
`UVPOrderLinkModule` `0.9`, `UVPStagePatchModule` `0.5`,
`UVPDerivedSignalModule` `0.7`; `UVPSupplierRegistry` and `UVPDockRegistry`
have no EIP-712 signature domain (registration is permissionless / owner or
registrar gated). The single mechanical source for versions and frozen ABI
fixtures is `uvp-deploy/deploy/compatibility/uvp-stack.v1.json`.

## Stable Events

Indexer and replay tooling should treat these event names as public interfaces:

- `OwnershipTransferred`
- `IdentityBindingRegistered`
- `IdentityBindingRevoked`
- `SupplierRegistered`
- `SupplierStatusChanged`
- `SupplierRegistrarSet`
- `PlanCommitted`
- `PlanFinalized`
- `PlanPublisherRecorded`
- `OrderRelayerRecorded`
- `OrderRegistered`
- `OrderMaterialized`
- `OrderTriggered`
- `SignalSubmitted`
- `OrderForked`
- `StageMaterialized`
- `StageSupplierPatchApplied`
- `StageFilePatchApplied`
- `StageFileOpApplied`
- `StageSupplierAssigned`
- `HookStatusChanged`
- `HookReady`
- `TimerPoked`

The module fixtures add these public events:

- `OrderLinked` (order-link module; carries `planId` + `originPlanId` alongside
  the order ids);
- `DerivedSignalSubmitted` (derived-signal module; carries `fromPlanId` +
  `targetPlanId`);
- `StageFilePatchApplied` / `StageFileOpApplied` (file resource module;
  patch-level and per-op records, replayed in log order);
- `DockRegistered` (dock registry; carries the full Dock outputs, atoms, and
  A-window programs);
- `StageDockSupplierSelected`, `DockBindingPoked`, and `DockOutputSubmitted`
  (stage-patch module; selection carries dock id, from plan, supplierId,
  selector, and nonce; poke/output events carry the binding id, from order, and
  output signal id);
- decoding note for `DeploymentDeprecated` (deployment registry): the
  `reasonHash`/`reasonURI` parameters are dual-meaning by frozen ABI. On the
  explicit `deprecateDeployment` path they carry the caller-supplied
  deprecation reason; on the activation-cutover path
  (`activateDeployment` auto-deprecating the previous active deployment) they
  carry the deprecated deployment's own `evidenceHash`/`metadataURI`
  (its canary/activation evidence), not the new deployment's activation
  evidence — indexers must disambiguate by trigger context (presence of the
  sibling `DeploymentActivated` in the same transaction).

All of these module events carry the composite `(planId, orderId)` identity:
same-id orders in different plans do not collide byte-for-byte, and indexers
must key projections on both ids.

## Hook State Machine

`UVPStateMachine` stores compact hook plans, order-to-plan bindings,
first-writer-wins signals, hook statuses (`Init`, `Wait`, `Ready`, `Cancelled`),
and timer due timestamps. It emits `HookReady` once per hook when positive and
timer conditions become satisfied; negative signals can cancel hooks before the
off-chain execution layer acts on readiness.

Order-trigger hooks are birth-line anchors. A trigger hook carries
`ORDER_TRIGGER_MINT` (the bit is reused for trigger signals) and one `SIGNAL`
instruction over its stage-qualified birth fact. A plan may declare multiple
trigger hooks, and the birth caller selects one explicitly with
`triggerHookId` + `triggerStageId`; the selected hook must carry the MINT flag,
belong to that stage, and be Ready after the birth fact is written.
Order-trigger hooks are evaluated only inside the order's own birth
transaction. Normal signal submissions — including dock output writebacks and
derived-signal writes — never evaluate order-trigger hooks: submitting another
birth line's fact inside an order born from a different fact cannot push that
line's hook to `Ready`, materialize its birth stage, or emit `HookReady` on
that order (grammar §7.2: a birth fact arrival serves only the birth of its own
unique order). Trigger hooks are not birth-key deduplicated, with trigger
signal uniqueness owned by the compiler. Non-trigger hooks (`EMIT_READY`
watchers and plain watchers) are evaluated as before. Dock stages are marked
by `HOOK_FLAG_DOCK_EXECUTOR`; dynamic stages are marked by
`HOOK_FLAG_DYNAMIC_EXECUTOR` (flag 32) — both flags mark the stage's supplier
resolution mode and are not order-trigger flags.

Per-stage counting note (UB-2): every signal write path resolves the fact's
owning stage (proof-carried attribution first, `source==stage` fallback for
zero-vocabulary plans) and maintains `stageSignalAccounts` — count, last
submitter, last timestamp, and a same-second ambiguity flag. Vocabulary plans
must carry valid attribution on every fact-write entry (submit, birth, dock
output, module mirrors): omitting the proof reverts
`InvalidSignalCapability`, so the count cannot be bypassed by
"no-proof" submissions. The stage patch module's assign/handoff timing gates
read this native count instead of caller-supplied capability tables.

Registration-bounds note: `MAX_PLAN_DEPENDENCIES` (1024) is a sanity ceiling,
not a physically reachable target. Each distinct dependency key costs two
storage-array pushes (~50k gas); within a 30M-gas block the storage cost alone
bounds committable distinct keys to roughly 600. Dedup/cross-stage checks at
registration read the persisted `dependencyIndex` (O(1) per key) instead of a
quadratic in-memory scan, so large legitimate plans register at storage cost,
and `TooManyDependencies` remains an OOG-shielded guard for absurd inputs.

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

- Role administration is owner-managed and intentionally minimal (owner +
  supplier registrars).
- Supplier identity/KYC is off-chain (`zhixu-store`); the chain records the
  SID, its permanently bound supplier account, and `pending/active/suspended/
  revoked` status. `suspendSupplier` can be reversed by activating again;
  `revokeSupplier` is terminal and keeps the SID/account binding.
- `UVPSupplierRegistryDebug` is QA-only and must never be wired in production.
