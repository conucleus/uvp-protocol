# @uvp-eth/product-dto

User-facing DTO contracts for the UVP product workbench.

This package intentionally avoids React, chain clients, storage, and wallet code.
It describes the product language the UI consumes:

- `ZhixuDetailDTO` for reviewed order structures;
- `ProductOrderDTO` for one running order;
- `ProductTaskDTO` for a user's actionable work item.
- `FulfillmentPluginKind` and `ProductParticipantProfileDTO` for the ordinary
  participant App entry and task plugins.
- `StageExecutorActionKind`, `ProductExecutorOverlayDTO`,
  `ProductResourceOverlayDTO`, `ProductResourceRequirementDTO`, and
  `ProductSelectableTargetDTO` for executor action projections.
- `ProductDockedZhixuRuntimeDTO` as the shared productization convergence
  vocabulary for docked Zhixu local/linked order projections. Executor overlays
  are chain-backed; docked runtime uses signal bindings between independent
  orders rather than a local/linked hierarchy.
- `ParticipantAddOnManifestDTO` for Store-authored role-slot page manifests.
  These manifests describe ordinary participant pages and map buttons to
  Product API actions; they are Store metadata, not chain authorization.
- `ProductResourceManifestDTO`, `ProductResourceAccessPolicyDTO`, and
  `ProductResourceAccessStatusDTO` for product-safe resource visibility,
  manifest, and access-state language.
- `RoleSlotDTO` stage responsibility metadata and capability plugin declarations
  for wallet-bound order executors. `roleSlotId` remains the protocol key; product
  clients may call the same responsibility a performance slot.
- `StoreZhixuConsoleDTO` for the first nucleus-facing Store Console lifecycle
  view.
- `StoreSearchResponseDTO`, `StoreOrderCandidatesResponseDTO`, and
  `StoreZhixuDetailDTO` for nucleus-facing Store search, order disambiguation,
  and Zhixu explanation views.
- `StoreSupplierDTO` for PRD53 supplier registry rows that merge Store metadata
  with `ZhixuTrustRegistry` supplier trust projection status.

`chain-services` enriches these DTOs from `UVPStateMachine` and
`ZhixuTrustRegistry` projections when chain events are available. Demo, local
fallback data, and the PRD89 Phase 2 customs scenario live behind the explicit
`@uvp-eth/product-dto/fixtures` subpath; the package root is the production
DTO/domain surface. The Phase 2 fixture includes role-slot manifests, resource
manifest metadata, Product Schema selector bindings, and a deterministic
on-chain HookPlan artifact for Store draft validation. `zhixu-store-web` should
render these DTOs without showing internal protocol words such as signal, gas,
HookReady, sourceId, signalId, ABI, or registryAddress in ordinary UI.

Raw chain details belong in proof rows and advanced proof payloads only.

The Store Console DTO is not ordinary-user language. It may expose lifecycle
words such as compiled, attested, active, deprecated, and revoked because it is
for nuclei, governance operators, and reviewers who manage order definitions.
Supplier capability tags in this package are Store metadata tags only. They
help with matching and review workflows, but they are not chain truth and do not
grant `submitSignal` authorization.

Generic participant manifests are independent from `FulfillmentPluginKind`.
Existing `fulfillmentKind` and `capabilityPlugin` payloads remain supported for
fallback clients. New clients should prefer `RoleSlotDTO.addOnManifest` and
`ProductTaskDTO.addOnManifest` when present: the manifest is a declarative page
contract for executor actions. The public action vocabulary is `submit_signal`,
`stage_executor_patch`, and `stage_resource_patch`. Production resource DTOs
should point at encrypted or content-addressed manifests, not HTTP download
URLs, cloud object keys, or plaintext handles.

`STORE_PRODUCT_SCHEMA_V1_REQUIRED_FIELDS` and
`PARTICIPANT_ADDON_MANIFEST_V1_ACTION_KINDS` are the public alpha freeze points
for the Store authoring bundle. They should be reviewed like API fields before
the five core compartments are split into separate repositories.
