# @uvp-eth/chain-read-contract

Neutral wire contract for chain-services' anonymous generic chain reads
(`GET /chain/orders`, `/chain/tasks`, `/chain/sync-state`, `/chain/snapshot`,
`/chain/plans/:planId/:planHash/admissions`,
`/chain/plans/:planId/:planHash/triggers`).

This package is the single owner of the chain read wire field names and JSON
value types. It defines no chain runtime, storage, or business rules:

- projection DTOs for orders, tasks, plans, deployments, modules, governance,
  docks, dock bindings, supplier registry bindings, sync state, and the full
  projection snapshot; plan DTOs carry `executorBindingsRoot` +
  `executorBindings` (default/candidate) and `dynamicExecutorStages`; order
  stage-executor overlays carry the active `supplierId`/`patchNonce` and the
  registry-resolved `effectiveExecutor`, and signals carry the `relayer`
  wallet next to the business `submitter`;
- `ChainDock` (`uvp.dock.v1`) is the static Dock registry projection
  (`dkid`, `docHash`, from/to identities, each output's Hook DSL AST +
  dependencies + atoms, registration provenance);
- `ChainDockBinding` (`uvp.dockBinding.v1`) is derived from the selected dkid,
  the `dock_link` payload file record, and poke evaluation: `binding_id`,
  from/to identities, optional `selected_by` fact reference, optional
  `pending` (a newer `dock_link` file patch has not been poked yet), and
  per-output A/B windows + emission (`emitted_binding_id` when the fact came
  from another binding). A `pending: true` row carries no live windows
  (`a_window`/`b_window` omitted or null); non-pending rows require them. There is no payload hash/generation and no link
  status field. Windows reference the fact that opened/closed them
  (`ChainProvenance` on chain, `ChainDockFactRef` on cloud) plus an optional
  `delay_seconds`; there is no wall-clock timestamp;
- plan capability table DTOs carried on `ChainPlanProjection`;
- plan admission DTOs for `/chain/plans/:planId/:planHash/admissions`;
- plan trigger DTOs for `/chain/plans/:planId/:planHash/triggers`: each
  `ChainPlanTrigger` mirrors one order-trigger hook of the recorded plan
  artifact (`orderTriggerKind` `trigger`, plus hookId, stage/signal identity),
  in artifact order; dock stages carry a hook flag, not a trigger kind;
- the serialization rule that every bigint field is a decimal string
  (`toWire`/`Wire<T>`);
- runtime guards, decoders, response-envelope parsers, and the typed
  `ChainReadContractError` used by `@uvp-eth/uvp-client/chain-read`.

`uvp-chain-services/service` serializes its internal indexer projections through
`toWire` and types `/chain/*` responses with these DTOs; `@uvp-eth/uvp-client/chain-read`
reads the same DTOs over HTTP and revives block numbers to bigint, and the used-car
backend's projection store consumes that view. Indexer-internal projection types stay in chain-services.

## Snapshot keys

`ChainProjectionSnapshot` carries `stateMachineDocks` (static Dock registry by
`dkid`), `stateMachineDockBindings` (bindings by `binding_id`; one A order
maps to one binding id), and `stateMachineSuppliers` (SupplierRegistry
bindings by `supplierId`, including the rotation/revocation provenance; revoked
suppliers keep their last executor and revocation proof). The old dynamic
dock-instance keys (`stateMachineDocksByTargetOrder`,
`stateMachineOrderDockChainDepth`), the old Link rows, and the two dock diagnostics
(`unresolvedDockEventCount`, `unresolvedDockTargetDeploymentCount`) are gone.

Order projections no longer carry the former `authorizations` map or any
`SignalAuthorization` row: signal submission rights are the effective stage
executor resolved from the plan binding plus the supplier registry, so task
assignments surface `assigneeSupplierId`/`assigneeExecutor` instead of the
removed role/metadata fields.

## Gates

```bash
cd uvp-protocol/packages/chain-read-contract
pnpm typecheck
pnpm test
```
