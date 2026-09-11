import { hashCanonical } from "./hash.js";
import {
  definitionRefHash,
  definitionUid,
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
} from "./dock.js";
import { canonicalize } from "./canonical.js";
import { validateDockCommitments } from "./dock-validation.js";
import {
  COMPILER_NAME,
  COMPILER_VERSION,
  DOCK_INTERFACE_ARTIFACT_SCHEMA_VERSION,
  DOCK_ROUTE_SCHEMA_VERSION,
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
  type NeutralInterfaceDeclaration,
  type NeutralResolutionManifest,
  type NeutralUnresolvedDockRoute,
  type ZhixuDefinition,
  type ZhixuPlatform,
} from "./types/index.js";

/**
 * 链轨承诺层：uvp-core 只产出中性 plan 壳（无哈希、无派生身份），本模块
 * 在壳上计算全部链上承诺（TS 权威实现）。
 * 公式与 word 布局冻结于 UVPDockingModule abiVersion 4.2（规格见
 * docs/dock-word-layout.md），Solidity 逐字节对拍钉死。
 */

export const HOOK_PLAN_ID_DOMAIN = "uvp:hook-plan-id:v1";
export const HOOK_PLAN_HASH_DOMAIN = "uvp:hook-plan-artifact:v1";

/** core 中性 hook_plan 壳（承诺字段的输入面；哈希字段一律不在此层）。 */
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

/** 链轨 resolution manifest 的校验+解析结果（route 组装的寻址面）。 */
export interface PreparedDockResolution {
  /** core linker 消费的中性 name 目录。 */
  readonly neutral: NeutralResolutionManifest;
  /** name → 发布面数据（含 TS 重算的定义级 dockInterfaceRoot）。 */
  readonly byName: ReadonlyMap<string, PreparedTarget>;
}

export interface PreparedTarget {
  readonly uid: string;
  readonly definitionRefHash: HexString;
  readonly artifactHash: HexString;
  readonly interfaces: readonly DockInterfaceArtifactInterface[];
  readonly dockInterfaceRoot: HexString;
  readonly cloudArtifactId?: string;
  readonly evmPlanId?: HexString;
}

export function prepareDockResolution(
  manifest: DockResolutionManifest,
): PreparedDockResolution {
  if (manifest.schemaVersion !== "uvp.dock.resolution.v2") {
    throw new RangeError(
      `resolutionManifest.schemaVersion must be "uvp.dock.resolution.v2", received ${JSON.stringify(manifest.schemaVersion)}`,
    );
  }
  const byName = new Map<string, PreparedTarget>();
  type NeutralDefinition = NeutralResolutionManifest["definitions"][number];
  const neutralDefinitions: NeutralDefinition[] = [];
  for (const [index, entry] of manifest.definitions.entries()) {
    const path = `resolutionManifest.definitions[${index}]`;
    const prepared = prepareTargetEntry(entry, path);
    const name = entry.definition.metadata.name;
    if (byName.has(name)) {
      throw new RangeError(
        `${path}: duplicate definition name ${JSON.stringify(name)} — names are the resolution key and must be unique in the manifest`,
      );
    }
    byName.set(name, prepared);
    neutralDefinitions.push({
      name,
      interfaces: entry.interfaces.map((interfaceEntry, interfaceIndex) =>
        neutralInterfaceOf(
          interfaceEntry,
          entry.definition,
          `${path}.interfaces[${interfaceIndex}]`,
        ),
      ),
      ...(entry.dockEdges === undefined ? {} : { dockEdges: entry.dockEdges }),
    });
  }
  return {
    neutral: {
      schemaVersion: "uvp.dock.resolution.v2",
      definitions: neutralDefinitions,
    },
    byName,
  };
}

/**
 * planId preimage 的 platform 归一（Rust 权威 normalize_platform_value
 * 同口径）：空 params 不入 preimage，其余键按原文。内嵌定义允许携带
 * params:{}，跳过归一会把空对象当成 preimage 分叉误拒 manifest。
 */
function normalizePlatformPreimage(platform: ZhixuPlatform): ZhixuPlatform {
  if (
    platform.params === undefined ||
    Object.keys(platform.params).length > 0
  ) {
    return platform;
  }
  const normalized = { ...platform };
  delete normalized.params;
  return normalized;
}

/**
 * 单个发布面 entry 的内容寻址校验（链轨内务，不入 core）：uid/引用哈希从
 * 内嵌定义全文重算，接口叶/根由 manifest 数据逐 word 重算——自不一致的
 * manifest 在编译期拒绝，不推迟到运行期。
 */
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
  // evmPlanId 是目标定义的派生 planId（同 keyed preimage：compiler/platform/
  // zhixuId/zhixuName），可从内嵌定义独立重算——manifest 自身可重算的
  // 承诺面到此为止（artifactHash = 目标 plan 的 planHash，目标 plan 不在
  // manifest 内，无法在此重算，信任边界在发布流程）。preimage 的 platform
  // 与 Rust 权威 normalize_platform_value 同口径归一（空 params 不入
  // preimage）：内嵌定义允许携带 params:{}，以原文重算会把空对象当成
  // preimage 分叉误拒 manifest。
  if (entry.evmPlanId !== undefined) {
    const recomputedPlanId = planIdOf(
      uid,
      entry.definition.metadata.name,
      normalizePlatformPreimage(entry.definition.spec.platform),
    );
    if (entry.evmPlanId !== recomputedPlanId) {
      throw new RangeError(
        `${path}.evmPlanId does not match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName) over the embedded definition`,
      );
    }
  }
  // manifest 声明面对内嵌定义的交叉重算：dockEdges（静态出边）与
  // interfaces（接口声明）都是"持有定义全文却纯信任输入"的字段——漏报
  // dockEdges 会绕过 core D015 的启动图环检测，接口漂移则让调用方按
  // 幻影端口组装配 route。
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
  // 接口叶/两根/定义级根的逐 word 重算（复用 dock-validation 的 fail-closed
  // 重算路径）；_uid/refHash 已单独校验，此处占位值不再参与。
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
    definitionRefHash: refHash,
    artifactHash: entry.artifactHash,
    interfaces: entry.interfaces,
    dockInterfaceRoot,
    ...(entry.cloudArtifactId === undefined
      ? {}
      : { cloudArtifactId: entry.cloudArtifactId }),
    ...(entry.evmPlanId === undefined ? {} : { evmPlanId: entry.evmPlanId }),
  };
}

/**
 * 发布面接口 → core 中性声明（端口 map 形态，键序由 canonical 化消除）。
 * input 端口补 `{source, hook}`：source 从内嵌定义所属
 * stage 的声明 source 派生——缺失/空白即响亮失败，不回退、不臆造；发布面
 * artifact 端口自带的 source 与之交叉比对，自不一致的 manifest 拒绝
 * （core parse_interface_declaration 对中性声明按必填键校验同一形状）。
 */
function neutralInterfaceOf(
  interfaceEntry: DockInterfaceArtifactInterface,
  definition: ZhixuDefinition,
  path: string,
): NeutralInterfaceDeclaration {
  const stageSources = flattenStageSources(definition);
  const inputs: Record<string, { source: string; hook: string }> = {};
  for (const port of interfaceEntry.inputs) {
    const stageSource = stageSources.get(port.stageIdentifier);
    if (stageSource === undefined) {
      throw new RangeError(
        `${path}.inputs[${JSON.stringify(port.port)}] references hook ${JSON.stringify(port.hookId)} whose stage ${JSON.stringify(port.stageIdentifier)} is absent from the embedded definition — the neutral input-port source cannot be derived`,
      );
    }
    if (stageSource.trim().length === 0) {
      throw new RangeError(
        `${path}.inputs[${JSON.stringify(port.port)}] references stage ${JSON.stringify(port.stageIdentifier)} which declares a blank source — the neutral input-port source cannot be derived`,
      );
    }
    if (port.source !== stageSource) {
      throw new RangeError(
        `${path}.inputs[${JSON.stringify(port.port)}].source declares ${JSON.stringify(port.source)} but the embedded definition's stage ${JSON.stringify(port.stageIdentifier)} source is ${JSON.stringify(stageSource)} — the manifest is not content-addressed`,
      );
    }
    inputs[port.port] = { source: stageSource, hook: port.hookId };
  }
  const outputs: Record<string, { signal: string }> = {};
  for (const port of interfaceEntry.outputs) {
    outputs[port.port] = { signal: port.canonicalOutputSignal };
  }
  return {
    name: interfaceEntry.name,
    orderModes: [...interfaceEntry.orderModes],
    inputs,
    outputs,
  };
}

// ---------------------------------------------------------------------------
// 中性接口声明 → 接口承诺 artifact v2（目标侧）
// ---------------------------------------------------------------------------

/**
 * 从中性接口声明 + 本地 hook 表推导接口承诺：入口端口的 canonical 信号取
 * 该 hook 编译后的单一正向原子（D013 由 core 保证），sourceId/signalId 是
 * 运行期寻址数据、只随产物携带不入叶。
 */
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
          // D013 判定必须覆盖依赖列表全量：只看第一条会让"首项正向 + 尾随
          // 否定/计时依赖"的组合条件伪装成单一 atom 进接口承诺。
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
          // 中性声明的 input 端口 source（所属 stage 的 source 类，core 自
          // 定义派生）与编译后 hook 原子 source 必须一致（core D013 同口径）：
          // 分叉即制品自不一致，响亮拒绝。
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

// ---------------------------------------------------------------------------
// 中性 route → 链轨承诺 route v2（调用方侧）
// ---------------------------------------------------------------------------

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
  const target = context.resolution.byName.get(neutral.target.name);
  if (target === undefined) {
    throw new RangeError(
      `dock route ${stageIdentifier} targets ${JSON.stringify(neutral.target.name)} which is absent from the validated resolution manifest`,
    );
  }
  const interfaceEntry = target.interfaces.find(
    (candidate) => candidate.name === neutral.target.interfaceName,
  );
  if (interfaceEntry === undefined) {
    throw new RangeError(
      `dock route ${stageIdentifier} targets interface ${JSON.stringify(neutral.target.interfaceName)} which target ${neutral.target.name} does not publish`,
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

  // 绑定按 bindingHash 排序（word 字节序）；merkle root 与产物数组同口径。
  inputBindings.sort((left, right) => compareBytes(left.bindingHash, right.bindingHash));
  outputBindings.sort((left, right) => compareBytes(left.bindingHash, right.bindingHash));
  const inputBindingsRoot = merkleRoot(
    inputBindings.map((binding) => binding.bindingHash),
  );
  const outputBindingsRoot = merkleRoot(
    outputBindings.map((binding) => binding.bindingHash),
  );

  // D012 双侧镜像（core link_dock_routes）：被绑定接口的
  // 全部 input 端口 source（它们是同一接缝的投递邮箱）+ route-bound 输出
  // 端口的 canonical signal 前缀，并集不得多于一个 seam——input 侧跨源
  // 寻址在编译期拒绝。与 core 权威同谓词（>1 才拒）：并集为空需要接口
  // 无 input 端口且 route 无输出绑定，与 D019（至少一项绑定）矛盾，
  // 不可达。
  const seams = new Set<string>(
    interfaceEntry.inputs.map((port) => port.source),
  );
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
      `dock route ${stageIdentifier} must bind a single target source seam across the interface's input and bound output ports, found ${JSON.stringify([...seams])}`,
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
      zhixuName: neutral.target.name,
      interfaceName: neutral.target.interfaceName,
      interfaceRoot: interfaceEntry.interfaceRoot,
      dockInterfaceRoot: target.dockInterfaceRoot,
      artifactHash: target.artifactHash,
      ...(target.cloudArtifactId === undefined
        ? {}
        : { cloudArtifactId: target.cloudArtifactId }),
      ...(target.evmPlanId === undefined ? {} : { evmPlanId: target.evmPlanId }),
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
      interfaceName: neutral.target.interfaceName,
      orderMode: neutral.orderMode,
      inputBindingsRoot,
      outputBindingsRoot,
    }),
  };
}

// ---------------------------------------------------------------------------
// 中性壳 → 链轨 hook plan 制品
// ---------------------------------------------------------------------------

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
  const dockRoutesRoot = merkleRoot(dockRoutes.map((route) => route.routeHash));
  const unresolvedDockRoutes = shell.unresolvedDockRoutes?.map((route) => ({
    schemaVersion: route.schemaVersion,
    stageIdentifier: route.stageIdentifier,
    stageId: stageKey(route.stageIdentifier),
    localDefinitionRefHash,
    localPlanId: planId,
    localSource: route.localSource,
    interfaceName: route.interfaceName,
    orderMode: route.orderMode,
    inputBindings: route.inputBindings,
    outputBindings: route.outputBindings,
  }));

  // planHash 的 source 快照剔除 metadata.annotations：注解永不参与任何
  // 身份，planHash 随业务内容变化、不随文档注解变化。
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
    platform,
    zhixuId,
    zhixuName,
  });
}

/**
 * planHash 的 preimage 装配（与 assembleChainTrackHookPlan 同口径）：
 * 边界校验用它对携带字段整体重算，防"篡改 compiledHooks + 保留旧
 * planHash"的毒制品通过反序列化校验。
 */
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

/** taskPattern.name + stage.name 的两段标识（与 core flatten_stages 同口径）。 */
function flattenStageSources(
  definition: ZhixuDefinition,
): Map<string, string> {
  const sources = new Map<string, string>();
  for (const pattern of definition.spec.taskPatterns) {
    for (const stage of pattern.stages) {
      sources.set(`${pattern.name}.${stage.name}`, stage.source);
    }
  }
  return sources;
}

function stageIdentifierOfHook(hookId: string): string {
  const hashIndex = hookId.indexOf("#");
  if (hashIndex <= 0) {
    throw new RangeError(
      `hook reference must be <task>.<stage>#<hookName>, received ${JSON.stringify(hookId)}`,
    );
  }
  return hookId.slice(0, hashIndex);
}

function hookNameOfHook(hookId: string): string {
  const hashIndex = hookId.indexOf("#");
  if (hashIndex <= 0 || hashIndex === hookId.length - 1) {
    throw new RangeError(
      `hook reference must be <task>.<stage>#<hookName>, received ${JSON.stringify(hookId)}`,
    );
  }
  return hookId.slice(hashIndex + 1);
}

/** 字节序比较（Rust str Ord）；hex word 与 ASCII 标识符上等价于码点序。 */
function compareBytes(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

/**
 * dockEdges 声明 vs 内嵌定义静态出边（各 stage zhixu 执行者解析态目标
 * name 集）的交叉比对：D015 的启动图以 manifest 声明为边源，漏报即绕过
 * 环检测——集不相等（含缺声明/多声明/重复）一律拒绝。
 */
function dockEdgeCorrespondenceIssues(
  entry: DockResolutionTarget,
  path: string,
): readonly string[] {
  const issues: string[] = [];
  const derived = new Set<string>();
  for (const pattern of entry.definition.spec.taskPatterns) {
    for (const stage of pattern.stages) {
      const targetName = stage.executor?.zhixuExecutorConfig?.target?.zhixu;
      if (typeof targetName === "string") {
        derived.add(targetName);
      }
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

/**
 * manifest interfaces vs 内嵌定义 spec.dockInterface 的对应性比对：接口
 * 名/下单模式/端口及其 hook/signal 引用逐项相等——自不一致的发布面在
 * 编译期拒绝，调用方不得按幻影端口组装 route。
 */
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
