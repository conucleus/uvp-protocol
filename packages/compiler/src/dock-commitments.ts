import { hashCanonical } from "./hash.js";
import {
  definitionRefHash,
  definitionUid,
  dockCandidateLeaf,
  dockRouteId,
  EMPTY_MERKLE_ROOT,
  inputBindingHash,
  inputPortLeaf,
  interfaceLeaf,
  interfaceRootOf,
  keccakWord,
  merkleRoot,
  outputBindingHash,
  outputPortLeaf,
  routeHash as routeHashOf,
  splitCanonicalSignal,
  stageKey,
  stripAnnotations,
  ZERO_WORD,
} from "./dock.js";
import { canonicalize } from "./canonical.js";
import { validateDockCommitments } from "./dock-validation.js";
import {
  COMPILER_NAME,
  COMPILER_VERSION,
  DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
  DOCK_ROUTE_SCHEMA_VERSION,
  DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION,
  HOOK_PLAN_SCHEMA_VERSION,
  type DockInterfaceArtifactInterface,
  type DockInterfaceArtifactV2,
  type DockOrderMode,
  type DockResolutionManifest,
  type DockResolutionTarget,
  type DockRouteInputBinding,
  type DockRouteOutputBinding,
  type DockRouteV2,
  type HexString,
  type HookPlanArtifact,
  type NeutralDockRoute,
  type NeutralDockTarget,
  type NeutralDockTargets,
  type NeutralInterfaceDeclaration,
  type NeutralUnresolvedDockRoute,
  type UnresolvedDockRouteCandidate,
  type UnresolvedDockRouteV1,
  type ZhixuDefinition,
  type ZhixuPlatform,
} from "./types/index.js";

/**
 * 链轨承诺层：uvp-core 只产出中性 plan 壳（无哈希、无派生身份），本模块
 * 在壳上计算全部链上承诺（TS 权威实现；word 布局单源 docs/dock-word-layout.md）。
 */

export const HOOK_PLAN_ID_DOMAIN = "uvp:hook-plan-id:v1";
export const HOOK_PLAN_HASH_DOMAIN = "uvp:hook-plan-artifact:v1";

export interface HookPlanShell {
  readonly schemaVersion: typeof HOOK_PLAN_SCHEMA_VERSION;
  readonly zhixuName: string;
  readonly platform: unknown;
  readonly compiledHooks: readonly ShellHook[];
  readonly dependencyIndex: Record<string, readonly string[]>;
  readonly executorRoutes: Record<string, unknown>;
  readonly dockRoutes?: readonly NeutralDockRoute[];
  readonly dockInterface?: readonly NeutralInterfaceDeclaration[];
  readonly unresolvedDockRoutes?: readonly NeutralUnresolvedDockRoute[];
  readonly selectedStageBindings: readonly unknown[];
  readonly signalCapabilities: readonly unknown[];
  readonly admissions: readonly unknown[];
}

interface ShellHook {
  readonly hookId: string;
  readonly stageIdentifier: string;
  readonly dependencies: readonly {
    readonly kind: string;
    readonly source: string;
    readonly signalName: string;
  }[];
}

export interface PreparedDockResolution {
  readonly neutral: NeutralDockTargets;
  readonly byUid: ReadonlyMap<string, PreparedTarget>;
}

export interface PreparedTarget {
  readonly uid: string;
  readonly name: string;
  readonly definitionRefHash: HexString;
  readonly artifactHash: HexString;
  readonly interfaces: readonly DockInterfaceArtifactInterface[];
  readonly dockInterfaceRoot: HexString;
  readonly cloudArtifactId?: string;
  readonly evmPlanId?: HexString;
  readonly chainPlanId?: HexString;
}

export function prepareDockResolution(
  manifest: DockResolutionManifest,
): PreparedDockResolution {
  if (manifest.schemaVersion !== "uvp.dock.resolution.v2") {
    throw new RangeError(
      `resolutionManifest.schemaVersion must be "uvp.dock.resolution.v2", received ${JSON.stringify(manifest.schemaVersion)}`,
    );
  }
  const byUid = new Map<string, PreparedTarget>();
  const neutralDefinitions: NeutralDockTarget[] = [];
  for (const [index, entry] of manifest.definitions.entries()) {
    const path = `resolutionManifest.definitions[${index}]`;
    const prepared = prepareTargetEntry(entry, path);
    const uid = prepared.uid;
    if (byUid.has(uid)) {
      throw new RangeError(
        `${path}: duplicate definition uid ${JSON.stringify(uid)} — uid is the resolution key and must be unique in the manifest`,
      );
    }
    byUid.set(uid, prepared);
    neutralDefinitions.push({
      uid,
      definition: entry.definition,
    });
  }
  return {
    neutral: neutralDefinitions,
    byUid,
  };
}

export function normalizePlatformPreimage(platform: unknown): unknown {
  if (
    typeof platform !== "object" ||
    platform === null ||
    Array.isArray(platform)
  ) {
    return platform;
  }
  const record = platform as { params?: unknown };
  if (
    record.params === undefined ||
    typeof record.params !== "object" ||
    record.params === null ||
    Object.keys(record.params).length > 0
  ) {
    return platform;
  }
  const normalized = { ...(platform as Record<string, unknown>) };
  delete normalized.params;
  return normalized;
}

function prepareTargetEntry(
  entry: DockResolutionTarget,
  path: string,
): PreparedTarget {
  const uid = definitionUid(entry.definition);
  if (uid !== entry.zhixu) {
    throw new RangeError(
      `${path}.zhixu declares ${JSON.stringify(entry.zhixu)} but the embedded definition derives ${JSON.stringify(uid)} — the manifest is not content-addressed`,
    );
  }
  const refHash = definitionRefHash(uid);
  if (refHash !== entry.definitionRefHash) {
    throw new RangeError(
      `${path}.definitionRefHash does not match H(UVP_DEFINITION_REF_V1, keccak(uid)) over the embedded definition`,
    );
  }
  if (!entry.published || entry.artifactHash === `0x${"0".repeat(64)}`) {
    throw new RangeError(
      `${path}: target artifact ${uid} is not published/immutable`,
    );
  }
  if (entry.evmPlanId !== undefined) {
    const recomputedPlanId = planIdOf(
      uid,
      entry.definition.metadata.name,
      entry.definition.spec.platform,
    );
    if (entry.evmPlanId !== recomputedPlanId) {
      throw new RangeError(
        `${path}.evmPlanId does not match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName) over the embedded definition`,
      );
    }
  }
  const edgeIssues = dockEdgeCorrespondenceIssues(entry, path);
  if (edgeIssues.length > 0) {
    throw new RangeError(edgeIssues.join("; "));
  }
  const interfaceIssues = interfaceCorrespondenceIssues(entry, path);
  if (interfaceIssues.length > 0) {
    throw new RangeError(interfaceIssues.join("; "));
  }
  const dockInterfaceRoot = merkleRoot(
    entry.interfaces.map((interfaceEntry) => interfaceEntry.interfaceRoot),
  );
  const commitmentIssues = validateDockCommitments({
    dockRoutes: [],
    dockRoutesRoot: EMPTY_MERKLE_ROOT,
    dockInterface: {
      schemaVersion: DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
      definition: { uid, definitionRefHash: refHash },
      interfaces: entry.interfaces,
      interfaceRoot: dockInterfaceRoot,
    },
    dockInterfaceRoot,
  });
  if (commitmentIssues.length > 0) {
    throw new RangeError(commitmentIssues.join("; "));
  }
  return {
    uid,
    name: entry.definition.metadata.name,
    definitionRefHash: refHash,
    artifactHash: entry.artifactHash,
    interfaces: entry.interfaces,
    dockInterfaceRoot,
    ...(entry.cloudArtifactId === undefined
      ? {}
      : { cloudArtifactId: entry.cloudArtifactId }),
    ...(entry.evmPlanId === undefined ? {} : { evmPlanId: entry.evmPlanId }),
    ...(entry.chainPlanId === undefined ? {} : { chainPlanId: entry.chainPlanId }),
  };
}

export function buildDockInterfaceArtifact(
  declarations: readonly NeutralInterfaceDeclaration[],
  uid: string,
  hooksById: ReadonlyMap<string, ShellHook>,
): DockInterfaceArtifactV2 {
  const interfaces = [...declarations]
    .sort((left, right) => compareBytes(left.name, right.name))
    .map((declaration) => {
      const inputs = Object.entries(declaration.inputs ?? {})
        .sort(([left], [right]) => compareBytes(left, right))
        .map(([portName, port]) => {
          const hook = hooksById.get(port.hook);
          const dependency =
            hook !== undefined && hook.dependencies.length === 1
              ? hook.dependencies[0]
              : undefined;
          if (
            dependency === undefined ||
            dependency.kind !== "positive"
          ) {
            throw new RangeError(
              `dockInterface input port ${portName} must reference a hook with exactly one positive canonical signal atom, received ${JSON.stringify(port.hook)}`,
            );
          }
          if (port.source !== dependency.source) {
            throw new RangeError(
              `dockInterface input port ${portName} declares source ${JSON.stringify(port.source)} but its hook atom source is ${JSON.stringify(dependency.source)} — the neutral declaration and the compiled hook disagree`,
            );
          }
          const canonicalInputSignal = `${dependency.source}::${dependency.signalName}`;
          return {
            port: portName,
            stageIdentifier: stageIdentifierOfHook(port.hook),
            hookName: hookNameOfHook(port.hook),
            hookId: port.hook,
            canonicalInputSignal,
            canonicalInputSignalHash: keccakWord(canonicalInputSignal),
            source: port.source,
            sourceId: keccakWord(port.source),
            signalId: keccakWord(dependency.signalName),
            leafHash: inputPortLeaf({
              uid,
              interfaceName: declaration.name,
              portName,
              hookId: port.hook,
            }),
          };
        });
      const outputs = Object.entries(declaration.outputs ?? {})
        .sort(([left], [right]) => compareBytes(left, right))
        .map(([portName, port]) => {
          const [source, signalName] = splitCanonicalSignal(port.signal);
          return {
            port: portName,
            canonicalOutputSignal: port.signal,
            canonicalOutputSignalHash: keccakWord(port.signal),
            source,
            sourceId: keccakWord(source),
            signalId: keccakWord(signalName),
            leafHash: outputPortLeaf({
              uid,
              interfaceName: declaration.name,
              portName,
              canonicalSignal: port.signal,
            }),
          };
        });
      const inputsRoot = merkleRoot(inputs.map((port) => port.leafHash));
      const outputsRoot = merkleRoot(outputs.map((port) => port.leafHash));
      return {
        name: declaration.name,
        orderModes: [...declaration.orderModes] as DockOrderMode[],
        inputs,
        outputs,
        inputsRoot,
        outputsRoot,
        interfaceRoot: interfaceLeaf({
          uid,
          interfaceName: declaration.name,
          orderModes: declaration.orderModes,
          inputsRoot,
          outputsRoot,
        }),
      };
    });
  const artifact: DockInterfaceArtifactV2 = {
    schemaVersion: DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
    definition: { uid, definitionRefHash: definitionRefHash(uid) },
    interfaceRoot: merkleRoot(interfaces.map((entry) => entry.interfaceRoot)),
    interfaces,
  };
  return artifact;
}

export function buildDockRoute(
  neutral: NeutralDockRoute,
  context: {
    readonly localDefinitionRefHash: HexString;
    readonly localPlanId: HexString;
    readonly localStageSources: ReadonlyMap<string, string>;
    readonly resolution: PreparedDockResolution;
  },
): DockRouteV2 {
  const stageIdentifier = neutral.local.stageIdentifier;
  const stageKeyWord = stageKey(stageIdentifier);
  const routeId = dockRouteId(context.localDefinitionRefHash, stageKeyWord);
  const target = context.resolution.byUid.get(neutral.target.uid);
  if (target === undefined) {
    throw new RangeError(
      `dock route ${stageIdentifier} targets ${JSON.stringify(neutral.target.uid)} which is absent from the validated resolution manifest`,
    );
  }
  const interfaceEntry = target.interfaces.find(
    (candidate) => candidate.name === neutral.target.interfaceName,
  );
  if (interfaceEntry === undefined) {
    throw new RangeError(
      `dock route ${stageIdentifier} targets interface ${JSON.stringify(neutral.target.interfaceName)} which target ${neutral.target.uid} does not publish`,
    );
  }
  if (target.chainPlanId === undefined) {
    throw new RangeError(
      `dock route ${stageIdentifier} targets ${JSON.stringify(neutral.target.uid)} whose resolution manifest entry lacks chainPlanId — `
        + "the route hash commits to the target plan's on-chain registered plan id, so the manifest must publish it",
    );
  }

  const inputBindings: DockRouteInputBinding[] = neutral.inputBindings.map(
    (binding) => {
      const port = interfaceEntry.inputs.find(
        (candidate) => candidate.port === binding.port,
      );
      if (port === undefined) {
        throw new RangeError(
          `dock route ${stageIdentifier} binds unknown target input port ${JSON.stringify(binding.port)}`,
        );
      }
      return {
        localHookName: hookNameOfHook(binding.hookId),
        targetPort: binding.port,
        targetInputSignalHash: port.canonicalInputSignalHash,
        targetSourceId: port.sourceId,
        targetSignalId: port.signalId,
        targetStageIdentifier: port.stageIdentifier,
        targetSignalName: port.canonicalInputSignal,
        bindingHash: inputBindingHash({
          routeId,
          interfaceName: neutral.target.interfaceName,
          localHookId: binding.hookId,
          portName: binding.port,
          targetSourceId: port.sourceId,
          targetSignalId: port.signalId,
        }),
      };
    },
  );
  const stageSource = context.localStageSources.get(stageIdentifier);
  if (stageSource === undefined) {
    throw new RangeError(
      `dock route ${stageIdentifier} has no matching stage in the local definition`,
    );
  }
  const outputBindings: DockRouteOutputBinding[] = neutral.outputBindings.map(
    (binding) => {
      const port = interfaceEntry.outputs.find(
        (candidate) => candidate.port === binding.port,
      );
      if (port === undefined) {
        throw new RangeError(
          `dock route ${stageIdentifier} binds unknown target output port ${JSON.stringify(binding.port)}`,
        );
      }
      const localSourceId = keccakWord(stageSource);
      const localSignalId = keccakWord(
        `${stageIdentifier}.${binding.signal}`,
      );
      return {
        localSignalName: binding.signal,
        localSourceId,
        localSignalId,
        targetPort: binding.port,
        targetOutputSignalHash: port.canonicalOutputSignalHash,
        targetSourceId: port.sourceId,
        targetSignalId: port.signalId,
        targetSignalName: port.canonicalOutputSignal,
        bindingHash: outputBindingHash({
          routeId,
          interfaceName: neutral.target.interfaceName,
          localSourceId,
          localSignalId,
          portName: binding.port,
          targetSourceId: port.sourceId,
          targetSignalId: port.signalId,
        }),
      };
    },
  );

  const localFactKeys = new Set<string>();
  for (const binding of outputBindings) {
    const factKey = `${binding.localSourceId}:${binding.localSignalId}`;
    if (localFactKeys.has(factKey)) {
      throw new RangeError(
        `dock route ${stageIdentifier} maps local signal ${JSON.stringify(binding.localSignalName)} onto multiple output ports; `
          + "one local fact key (localSourceId, localSignalId) may drive at most one output binding per route "
          + "(a second delivery of the same local fact reverts SignalAlreadyExists and burns keeper gas)",
      );
    }
    localFactKeys.add(factKey);
  }

  inputBindings.sort((left, right) => compareBytes(left.bindingHash, right.bindingHash));
  outputBindings.sort((left, right) => compareBytes(left.bindingHash, right.bindingHash));
  const inputBindingsRoot = merkleRoot(
    inputBindings.map((binding) => binding.bindingHash),
  );
  const outputBindingsRoot = merkleRoot(
    outputBindings.map((binding) => binding.bindingHash),
  );

  const seams = new Set<string>();
  for (const binding of neutral.inputBindings) {
    const port = interfaceEntry.inputs.find(
      (candidate) => candidate.port === binding.port,
    );
    if (port !== undefined) {
      seams.add(port.source);
    }
  }
  for (const binding of neutral.outputBindings) {
    const output = interfaceEntry.outputs.find(
      (candidate) => candidate.port === binding.port,
    );
    if (output !== undefined) {
      seams.add(output.source);
    }
  }
  if (seams.size > 1) {
    throw new RangeError(
      `dock route ${stageIdentifier} must bind a single target source seam across route-bound input port sources and route-bound output signal prefixes, found ${JSON.stringify([...seams])}`,
    );
  }

  return {
    schemaVersion: DOCK_ROUTE_SCHEMA_VERSION,
    routeId,
    local: {
      definitionRefHash: context.localDefinitionRefHash,
      planId: context.localPlanId,
      stageIdentifier,
      stageKey: stageKeyWord,
    },
    target: {
      definitionRefHash: target.definitionRefHash,
      zhixuUid: target.uid,
      zhixuName: target.name,
      interfaceName: neutral.target.interfaceName,
      interfaceRoot: interfaceEntry.interfaceRoot,
      dockInterfaceRoot: target.dockInterfaceRoot,
      artifactHash: target.artifactHash,
      ...(target.cloudArtifactId === undefined
        ? {}
        : { cloudArtifactId: target.cloudArtifactId }),
      ...(target.evmPlanId === undefined ? {} : { evmPlanId: target.evmPlanId }),
      chainPlanId: target.chainPlanId,
    },
    orderMode: neutral.orderMode,
    sourceSeam: [...seams][0] as string,
    inputBindings,
    outputBindings,
    inputBindingsRoot,
    outputBindingsRoot,
    routeHash: routeHashOf({
      localDefinitionRefHash: context.localDefinitionRefHash,
      targetDefinitionRefHash: target.definitionRefHash,
      targetPlanId: target.chainPlanId,
      interfaceName: neutral.target.interfaceName,
      orderMode: neutral.orderMode,
      inputBindingsRoot,
      outputBindingsRoot,
    }),
  };
}

export function buildUnresolvedDockRoute(
  neutral: NeutralUnresolvedDockRoute,
  context: {
    readonly localDefinitionRefHash: HexString;
    readonly localPlanId: HexString;
    readonly resolution: PreparedDockResolution | undefined;
  },
): UnresolvedDockRouteV1 {
  const stageIdentifier = neutral.stageIdentifier;
  const routeId = dockRouteId(
    context.localDefinitionRefHash,
    stageKey(stageIdentifier),
  );
  if (context.resolution === undefined) {
    throw new RangeError(
      `unresolved dock route ${stageIdentifier} declares a dynamic (null) target but no resolution manifest was prepared — ` +
        "the candidate universe of a dynamic route is derived from the published targets in the manifest, so without one there is nothing to freeze into the route's candidate root",
    );
  }
  const candidates: UnresolvedDockRouteCandidate[] = [];
  let selfTargetSkipped = false;
  for (const target of context.resolution.byUid.values()) {
    if (target.definitionRefHash === context.localDefinitionRefHash) {
      selfTargetSkipped = true;
      continue;
    }
    const interfaceEntry = target.interfaces.find(
      (candidate) => candidate.name === neutral.interfaceName,
    );
    if (
      interfaceEntry === undefined ||
      !interfaceEntry.orderModes.includes(neutral.orderMode)
    ) {
      continue;
    }
    if (target.chainPlanId === undefined) {
      throw new RangeError(
        `unresolved dock route ${stageIdentifier}: manifest definition ${JSON.stringify(target.uid)} is a candidate but lacks chainPlanId — `
          + "the candidate leaf commits to the candidate plan's on-chain registered plan id, so the manifest must publish it",
      );
    }
    candidates.push({
      zhixuUid: target.uid,
      zhixuName: target.name,
      definitionRefHash: target.definitionRefHash,
      artifactHash: target.artifactHash,
      ...(target.cloudArtifactId === undefined
        ? {}
        : { cloudArtifactId: target.cloudArtifactId }),
      ...(target.evmPlanId === undefined
        ? {}
        : { evmPlanId: target.evmPlanId }),
      chainPlanId: target.chainPlanId,
    });
  }
  if (candidates.length === 0) {
    throw new RangeError(
      `unresolved dock route ${stageIdentifier} has an empty candidate set: ${
        selfTargetSkipped
          ? "the only manifest definition publishing interface " +
            `${JSON.stringify(neutral.interfaceName)} for order mode ${JSON.stringify(neutral.orderMode)} is the local definition itself, ` +
            "and a route cannot attach to its own order (self-attach is rejected on chain)"
          : "no manifest definition publishes interface " +
            `${JSON.stringify(neutral.interfaceName)} for order mode ${JSON.stringify(neutral.orderMode)} — ` +
            "the frozen candidate root would make the route permanently un-attachable (attach only accepts membership in the frozen root)"
      }`,
    );
  }
  candidates.sort((left, right) =>
    left.definitionRefHash < right.definitionRefHash
      ? -1
      : left.definitionRefHash > right.definitionRefHash
        ? 1
        : 0,
  );
  const candidatesRoot = merkleRoot(
    candidates.map((candidate) =>
      dockCandidateLeaf({
        routeId,
        targetDefinitionRefHash: candidate.definitionRefHash,
        targetPlanId: candidate.chainPlanId,
        interfaceName: neutral.interfaceName,
      }),
    ),
  );
  return {
    schemaVersion: DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION,
    stageIdentifier,
    stageId: stageKey(stageIdentifier),
    localDefinitionRefHash: context.localDefinitionRefHash,
    localPlanId: context.localPlanId,
    localSource: neutral.localSource,
    interfaceName: neutral.interfaceName,
    orderMode: neutral.orderMode,
    inputBindings: neutral.inputBindings,
    outputBindings: neutral.outputBindings,
    routeId,
    candidates,
    candidatesRoot,
    routeHash: routeHashOf({
      localDefinitionRefHash: context.localDefinitionRefHash,
      targetDefinitionRefHash: candidatesRoot,
      targetPlanId: ZERO_WORD,
      interfaceName: neutral.interfaceName,
      orderMode: neutral.orderMode,
      inputBindingsRoot: EMPTY_MERKLE_ROOT,
      outputBindingsRoot: EMPTY_MERKLE_ROOT,
    }),
  };
}

export function assembleChainTrackHookPlan(
  definition: ZhixuDefinition,
  shell: HookPlanShell,
  resolution: PreparedDockResolution | undefined,
): HookPlanArtifact {
  const zhixuId = definitionUid(definition);
  const localDefinitionRefHash = definitionRefHash(zhixuId);
  const hooksById = new Map(
    shell.compiledHooks.map((hook) => [hook.hookId, hook]),
  );
  const dockInterface =
    shell.dockInterface === undefined
      ? null
      : buildDockInterfaceArtifact(shell.dockInterface, zhixuId, hooksById);
  const dockInterfaceRoot =
    dockInterface === null ? EMPTY_MERKLE_ROOT : dockInterface.interfaceRoot;
  const platform = shell.platform as HookPlanArtifact["platform"];
  const planId = planIdOf(zhixuId, shell.zhixuName, platform);
  const localStageSources = flattenStageSources(definition);
  const dockRoutes = (shell.dockRoutes ?? []).map((route) =>
    buildDockRoute(route, {
      localDefinitionRefHash,
      localPlanId: planId,
      localStageSources,
      resolution: resolution ?? failNoResolution(route),
    }),
  );
  const unresolvedDockRoutes = shell.unresolvedDockRoutes?.map((route) =>
    buildUnresolvedDockRoute(route, {
      localDefinitionRefHash,
      localPlanId: planId,
      resolution,
    }),
  );
  const dockRoutesRoot = merkleRoot([
    ...dockRoutes.map((route) => route.routeHash),
    ...(unresolvedDockRoutes ?? []).map((route) => route.routeHash),
  ]);

  const payload = {
    schemaVersion: HOOK_PLAN_SCHEMA_VERSION,
    planId,
    zhixuId,
    zhixuName: shell.zhixuName,
    platform,
    compiledHooks: shell.compiledHooks as HookPlanArtifact["compiledHooks"],
    dependencyIndex: shell.dependencyIndex,
    executorRoutes: shell.executorRoutes,
    dockInterface,
    dockRoutes,
    dockRoutesRoot,
    dockInterfaceRoot,
    selectedStageBindings: shell.selectedStageBindings,
    signalCapabilities: shell.signalCapabilities,
    admissions: shell.admissions,
    source: canonicalize(stripAnnotations(definition)),
    ...(unresolvedDockRoutes === undefined || unresolvedDockRoutes.length === 0
      ? {}
      : { unresolvedDockRoutes }),
  };
  const planHash = hashCanonical(HOOK_PLAN_HASH_DOMAIN, payload);
  return {
    schemaVersion: HOOK_PLAN_SCHEMA_VERSION,
    planId,
    zhixuId,
    zhixuName: shell.zhixuName,
    platform,
    compiledHooks: shell.compiledHooks as unknown as HookPlanArtifact["compiledHooks"],
    dependencyIndex: shell.dependencyIndex,
    executorRoutes: shell.executorRoutes as HookPlanArtifact["executorRoutes"],
    dockInterface,
    dockRoutes,
    ...(unresolvedDockRoutes === undefined || unresolvedDockRoutes.length === 0
      ? {}
      : { unresolvedDockRoutes }),
    dockRoutesRoot,
    dockInterfaceRoot,
    selectedStageBindings:
      shell.selectedStageBindings as HookPlanArtifact["selectedStageBindings"],
    signalCapabilities:
      shell.signalCapabilities as HookPlanArtifact["signalCapabilities"],
    admissions: shell.admissions as HookPlanArtifact["admissions"],
    source: payload.source,
    planHash,
  };
}

export function planIdOf(
  zhixuId: string,
  zhixuName: string,
  platform: unknown,
): HexString {
  return hashCanonical(HOOK_PLAN_ID_DOMAIN, {
    compiler: { name: COMPILER_NAME, version: COMPILER_VERSION },
    platform: normalizePlatformPreimage(platform),
    zhixuId,
    zhixuName,
  });
}

export function hookPlanPayloadForHash(
  artifact: Omit<HookPlanArtifact, "planHash">,
): Record<string, unknown> {
  const unresolved =
    artifact.unresolvedDockRoutes === undefined ||
    artifact.unresolvedDockRoutes.length === 0
      ? {}
      : { unresolvedDockRoutes: artifact.unresolvedDockRoutes };
  return {
    schemaVersion: artifact.schemaVersion,
    planId: artifact.planId,
    zhixuId: artifact.zhixuId,
    zhixuName: artifact.zhixuName,
    platform: artifact.platform,
    compiledHooks: artifact.compiledHooks,
    dependencyIndex: artifact.dependencyIndex,
    executorRoutes: artifact.executorRoutes,
    dockInterface: artifact.dockInterface,
    dockRoutes: artifact.dockRoutes,
    dockRoutesRoot: artifact.dockRoutesRoot,
    dockInterfaceRoot: artifact.dockInterfaceRoot,
    selectedStageBindings: artifact.selectedStageBindings,
    signalCapabilities: artifact.signalCapabilities,
    admissions: artifact.admissions,
    source: artifact.source,
    ...unresolved,
  };
}

export function hookPlanHashOf(
  artifact: Omit<HookPlanArtifact, "planHash">,
): HexString {
  return hashCanonical(HOOK_PLAN_HASH_DOMAIN, hookPlanPayloadForHash(artifact));
}

function failNoResolution(route: NeutralDockRoute): PreparedDockResolution {
  throw new RangeError(
    `dock route ${route.local.stageIdentifier} resolved against a target but no resolution manifest was prepared`,
  );
}

function flattenStageSources(
  definition: ZhixuDefinition,
): Map<string, string> {
  const sources = new Map<string, string>();
  for (const stage of definition.spec.stages) {
    sources.set(stage.name, stage.source);
  }
  return sources;
}

function stageIdentifierOfHook(hookId: string): string {
  const hashIndex = hookId.indexOf("#");
  if (hashIndex <= 0) {
    throw new RangeError(
      `hook reference must be <stage>#<hookName>, received ${JSON.stringify(hookId)}`,
    );
  }
  return hookId.slice(0, hashIndex);
}

function hookNameOfHook(hookId: string): string {
  const hashIndex = hookId.indexOf("#");
  if (hashIndex <= 0 || hashIndex === hookId.length - 1) {
    throw new RangeError(
      `hook reference must be <stage>#<hookName>, received ${JSON.stringify(hookId)}`,
    );
  }
  return hookId.slice(hashIndex + 1);
}

function compareBytes(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function dockEdgeCorrespondenceIssues(
  entry: DockResolutionTarget,
  path: string,
): readonly string[] {
  const issues: string[] = [];
  const derived = new Set<string>();
  for (const stage of entry.definition.spec.stages) {
    const targetName = stage.executor?.zhixuExecutorConfig?.target?.zhixu;
    if (typeof targetName === "string") {
      derived.add(targetName);
    }
  }
  const declared = entry.dockEdges ?? [];
  const declaredSet = new Set<string>();
  for (const [index, edge] of declared.entries()) {
    if (declaredSet.has(edge.target)) {
      issues.push(
        `${path}.dockEdges[${index}] duplicates target ${JSON.stringify(edge.target)}`,
      );
      continue;
    }
    declaredSet.add(edge.target);
  }
  for (const target of derived) {
    if (!declaredSet.has(target)) {
      issues.push(
        `${path}.dockEdges must declare static target ${JSON.stringify(target)} `
        + "(referenced by a zhixu executor in the embedded definition; omitting it bypasses the D015 startup-graph cycle check)",
      );
    }
  }
  for (const target of declaredSet) {
    if (!derived.has(target)) {
      issues.push(
        `${path}.dockEdges declares target ${JSON.stringify(target)} which the embedded definition never statically references`,
      );
    }
  }
  return issues;
}

function interfaceCorrespondenceIssues(
  entry: DockResolutionTarget,
  path: string,
): readonly string[] {
  const issues: string[] = [];
  const declared = entry.definition.spec.dockInterface ?? {};
  const declaredNames = new Set(Object.keys(declared));
  const artifactNames = new Set<string>();
  for (const [index, artifactInterface] of entry.interfaces.entries()) {
    const interfacePath = `${path}.interfaces[${index}]`;
    const name = artifactInterface.name;
    if (artifactNames.has(name)) {
      issues.push(`${interfacePath} duplicates interface name ${JSON.stringify(name)}`);
      continue;
    }
    artifactNames.add(name);
    const source = declared[name];
    if (source === undefined) {
      issues.push(
        `${interfacePath} is absent from the embedded definition's spec.dockInterface`,
      );
      continue;
    }
    if (
      [...source.orderModes].sort(compareBytes).join(",") !==
      [...artifactInterface.orderModes].sort(compareBytes).join(",")
    ) {
      issues.push(
        `${interfacePath}.orderModes must equal spec.dockInterface[${JSON.stringify(name)}].orderModes`,
      );
    }
    const sourceInputs = source.inputs ?? {};
    for (const port of artifactInterface.inputs) {
      const sourcePort = sourceInputs[port.port];
      if (sourcePort === undefined) {
        issues.push(
          `${interfacePath}.inputs declares port ${JSON.stringify(port.port)} absent from the definition`,
        );
      } else if (sourcePort.hook !== port.hookId) {
        issues.push(
          `${interfacePath}.inputs[${JSON.stringify(port.port)}].hookId must equal the definition's hook reference`,
        );
      }
    }
    for (const portName of Object.keys(sourceInputs)) {
      if (!artifactInterface.inputs.some((port) => port.port === portName)) {
        issues.push(
          `${interfacePath}.inputs must declare definition port ${JSON.stringify(portName)}`,
        );
      }
    }
    const sourceOutputs = source.outputs ?? {};
    for (const port of artifactInterface.outputs) {
      const sourcePort = sourceOutputs[port.port];
      if (sourcePort === undefined) {
        issues.push(
          `${interfacePath}.outputs declares port ${JSON.stringify(port.port)} absent from the definition`,
        );
      } else if (sourcePort.signal !== port.canonicalOutputSignal) {
        issues.push(
          `${interfacePath}.outputs[${JSON.stringify(port.port)}].canonicalOutputSignal must equal the definition's signal`,
        );
      }
    }
    for (const portName of Object.keys(sourceOutputs)) {
      if (!artifactInterface.outputs.some((port) => port.port === portName)) {
        issues.push(
          `${interfacePath}.outputs must declare definition port ${JSON.stringify(portName)}`,
        );
      }
    }
  }
  for (const name of declaredNames) {
    if (!artifactNames.has(name)) {
      issues.push(
        `${path}.interfaces must declare spec.dockInterface entry ${JSON.stringify(name)}`,
      );
    }
  }
  return issues;
}
