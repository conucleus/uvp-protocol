import {
  type HookConditionAst,
  type HookDependency,
  type HookExpressionAst,
} from "@uvp-eth/hook-core";
import { hashCanonical, keccak256Hex } from "./hash.js";
import {
  encodeAbiParameters,
  keccak256,
  parseAbiParameters,
  stringToHex,
} from "viem";
import { assertHookPlanArtifact, compareByCodeUnit, HookPlanCompilationError } from "./hook-plan.js";
import { canonicalStringify } from "./canonical.js";
import {
  ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
  type HexString,
  type HookPlanArtifact,
  type HookPlanExecutorRoute,
  type OnchainCompiledHook,
  type OnchainExecutorRoute,
  type OnchainExecutorRouteRef,
  type OnchainHookDependency,
  type OnchainHookInstruction,
  type OnchainHookPlanArtifact,
  type OnchainSignalCapability,
  type OnchainStageSelectorBinding,
  type SelectedStageBinding,
  type SignalCapability,
  type SignalTargetOrderRelation,
  type SolidityRegisterInstructionArg,
  type SolidityRegisterPlanArgs,
  type SolidityRegisterSignalCapabilityArg,
  type SolidityRegisterStageSelectorBindingArg,
  type ZhixuDefinition,
  type ZhixuPlatform,
} from "./types/index.js";
import { compileZhixuHookPlan } from "./hook-plan.js";
import {
  dockRoutesRootOf,
  interfaceRootOf,
} from "./dock.js";
import { validateDockCommitments } from "./dock-validation.js";
import type {
  DockResolutionManifest,
  DockRouteV2,
  OrderTriggerKind,
} from "./types/index.js";

// Mirrors UVPStateMachine.MAX_HOOK_DELAY_SECONDS (30 days): the contract
// reverts HookDelayTooLong above this bound, so the fail-closed artifact
// preflight must reject the same inputs instead of letting the transaction
// revert on-chain.
const MAX_ONCHAIN_HOOK_DELAY_SECONDS = 2_592_000;
// Mirrors UVPStateMachine.MAX_PLAN_DEPENDENCIES (1024): the contract reverts
// TooManyDependencies while registering the plan dependency index, so the
// preflight must reject plans with more than 1024 distinct dependency keys.
const MAX_PLAN_DEPENDENCIES = 1024;
// Documented cap on compiled signal capabilities (= the plan-wide total of
// sendSignals declarations). UVPPlanMetadataModule._registerSignalCapabilities
// writes one storage slot per capability at plan registration, so an
// oversized hand-signed table makes registration gas plan-controlled and
// unbounded; the contract reverts TooManySignalCapabilities at the same 256.
// Stage-ownership lookups are single-key owner-index reads
// (_signalStageId -> currentOrderFactStage), so the cap bounds registration
// cost, not per-submission queries. Rust uvp-core mirrors this cap.
const MAX_SIGNAL_CAPABILITIES = 256;

/**
 * supplierType 闭集（与 uvp_model::SUPPLIER_TYPES / Go supplierTypes 同源，
 * 注册表 rule executor-supplier-type-closed-enum）：executorRoutes 把
 * supplierType 烧进链上承诺（executorHash），合约侧无闭集守卫——闭集外的
 * 字符串（含 "Zhixu" 等大小写变体）必须在链轨编译期拒绝，不是烧进承诺后
 * 才在消费侧炸开。比对按 trim 后进行（与 Go/Rust 同口径）。
 */
const SUPPLIER_TYPES: readonly string[] = ["individual", "organization", "zhixu"];

/**
 * fileResources 的 fileType 闭集（与 Go fileTypes 同源：
 * local|http|txcloud|plain_text）：fileResources 经 resourcesHash 进链上
 * 承诺，拼错的 fileType 不得静默成承诺内容。
 */
const FILE_TYPES: readonly string[] = ["local", "http", "txcloud", "plain_text"];

const ONCHAIN_PLAN_HASH_DOMAIN = "uvp:onchain-hook-plan-artifact:v1";
const ONCHAIN_ROUTE_HASH_DOMAIN = "uvp:onchain-hook-route:v1";
const ONCHAIN_SELECTOR_BINDING_HASH_DOMAIN =
  "uvp:onchain-stage-selector-binding:v1";
const ONCHAIN_SIGNAL_CAPABILITY_HASH_DOMAIN =
  "uvp:onchain-signal-capability:v1";
const PLAN_RUNTIME_HASH_DOMAIN_V2 = "uvp.plan.runtime.v2";

/** CompactHook flags 位定义。 */
export const HOOK_FLAG_ORDER_TRIGGER_MINT = 1;
export const HOOK_FLAG_ORDER_TRIGGER_DOCK = 2;
export const HOOK_FLAG_EMIT_READY = 4;

export function solidityHookFlags(
  orderTriggerKind: OrderTriggerKind,
  emitReady: boolean,
): number {
  let flags = 0;
  if (orderTriggerKind === "mint") {
    flags |= HOOK_FLAG_ORDER_TRIGGER_MINT;
  }
  if (orderTriggerKind === "dock") {
    flags |= HOOK_FLAG_ORDER_TRIGGER_DOCK;
  }
  if (emitReady) {
    flags |= HOOK_FLAG_EMIT_READY;
  }
  return flags;
}

export class OnchainHookPlanArtifactValidationError extends Error {
  readonly issues: readonly string[];

  constructor(issues: readonly string[]) {
    super(issues.join("; "));
    this.name = "OnchainHookPlanArtifactValidationError";
    this.issues = issues;
  }
}

export function compileOnchainHookPlan(
  hookPlanArtifact: HookPlanArtifact,
): OnchainHookPlanArtifact {
  assertHookPlanArtifact(hookPlanArtifact);

  const compiledHooks = hookPlanArtifact.compiledHooks
    .map((hook) => ({
      hookId: onchainHookId(hook.stageIdentifier, hook.hookName),
      stageId: onchainStageId(hook.stageIdentifier),
      stageIdentifier: hook.stageIdentifier,
      hookName: hook.hookName,
      kind: hook.kind,
      orderTriggerKind: hook.orderTriggerKind,
      emitReady: hook.emitReady,
      instructions: compileHookInstructions(hook.ast, hook.stageIdentifier, {
        orderTriggerKind: hook.orderTriggerKind,
      }),
      dependencies: hook.dependencies.map(compileDependency),
      ...(hook.route ? { routeRef: routeRefForRoute(hook.route) } : {}),
    }))
    .sort(compareOnchainHooks);
  // 逐 hook 顺序语义与合约 _registerPlanHook 一致（见 crossStageDependencyIssues）。
  const crossStageIssues = crossStageDependencyIssues(compiledHooks);
  // 不可物化阶段（无 order-trigger / EMIT_READY hook 的阶段）不得挂任何
  // receive hook，且阶段声明不得编译为零 hook——纯 flags=0 watcher 不物化
  // 阶段，零 hook 阶段同样不物化，链上对该阶段的任何求值都是不可
  // 恢复死锁（Rust 编译器是第一道，这里是 artifact 边界的第二道）。
  const materializationIssues = unmaterializableStageIssues(
    compiledHooks,
    declaredStageIdentifiers(
      hookPlanArtifact.signalCapabilities.map((capability) => capability.stageIdentifier),
      Object.keys(hookPlanArtifact.executorRoutes),
      hookPlanArtifact.dockRoutes.map((route) => route.local.stageIdentifier),
      hookPlanArtifact.selectedStageBindings.flatMap((binding) => [
        binding.selectorStageIdentifier,
        binding.targetStageIdentifier,
      ]),
    ),
  );
  const silentTriggerIssues = silentOrderTriggerIssues(compiledHooks);
  const dependencyCountIssues = planDependencyCountIssues(compiledHooks);
  const capabilityCountIssues = signalCapabilityCountIssues(
    hookPlanArtifact.signalCapabilities,
  );
  const currentOrderFactKeyIssues = duplicateCurrentOrderFactKeyIssues(
    hookPlanArtifact.signalCapabilities.map((capability) => ({
      stage: capability.stageIdentifier,
      sourceId: onchainSourceId(capability.targetSource),
      signalId: onchainSignalId(capability.targetSignalName),
      isCurrentOrder: capability.targetOrderRelation === "current",
    })),
  );
  // 链轨拒绝：Rust 两个 profile 都放行 existing 与
  // 动态 target（hook plan 产物携带 unresolvedDockRoutes 声明面，§8.8），
  // 是否上链由宿主轨道决定——on-chain 编译在这里显式拒绝，不静默降级。
  // Rust hook_plan 不再对 target:null 兜底拒绝，这里是 on-chain 边界对
  // 未解析 route 的第一道门。
  const dockTrackIssues = onchainDockTrackIssues(hookPlanArtifact.dockRoutes);
  const unresolvedTrackIssues = onchainUnresolvedRouteIssues(
    hookPlanArtifact.unresolvedDockRoutes,
  );
  const preflightIssues = [
    ...crossStageIssues,
    ...materializationIssues,
    ...silentTriggerIssues,
    ...dependencyCountIssues,
    ...capabilityCountIssues,
    ...currentOrderFactKeyIssues,
    ...dockTrackIssues,
    ...unresolvedTrackIssues,
  ];
  if (preflightIssues.length > 0) {
    throw new HookPlanCompilationError(preflightIssues);
  }
  const dependencyIndex = buildOnchainDependencyIndex(compiledHooks);
  const executorRoutes = Object.values(hookPlanArtifact.executorRoutes)
    .map(compileExecutorRoute)
    .sort(compareExecutorRoutes);
  const selectorBindings = compileSelectorBindings(
    hookPlanArtifact.selectedStageBindings,
  );
  const signalCapabilities = compileSignalCapabilities(
    hookPlanArtifact.signalCapabilities,
  );
  // fail-closed：dock roots 由 TS 侧从 core 产物重算并断言一致，任何分叉
  // 都在编译期暴露。
  const dockRoutes = hookPlanArtifact.dockRoutes;
  const recomputedRoutesRoot = dockRoutesRootOf(dockRoutes);
  if (recomputedRoutesRoot !== hookPlanArtifact.dockRoutesRoot) {
    throw new OnchainHookPlanArtifactValidationError([
      "dockRoutesRoot does not match the recomputed root over dock route hashes",
    ]);
  }
  if (hookPlanArtifact.dockInterface !== null) {
    const recomputedInterfaceRoot = interfaceRootOf(hookPlanArtifact.dockInterface);
    if (recomputedInterfaceRoot !== hookPlanArtifact.dockInterfaceRoot) {
      throw new OnchainHookPlanArtifactValidationError([
        "dockInterfaceRoot does not match the recomputed root over interface leaves",
      ]);
    }
  }
  const payload = {
    schemaVersion: ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    planId: hookPlanArtifact.planId,
    zhixuId: hookPlanArtifact.zhixuId,
    zhixuName: hookPlanArtifact.zhixuName,
    platform: hookPlanArtifact.platform,
    sourcePlanHash: hookPlanArtifact.planHash,
    compiledHooks,
    dependencyIndex,
    executorRoutes,
    dockInterface: hookPlanArtifact.dockInterface,
    dockRoutes,
    dockRoutesRoot: hookPlanArtifact.dockRoutesRoot,
    dockInterfaceRoot: hookPlanArtifact.dockInterfaceRoot,
    selectorBindings,
    signalCapabilities,
  };

  return {
    ...payload,
    planHash: hashOnchainPlanPayload(payload),
  };
}

export function compileZhixuOnchainHookPlan(
  definition: ZhixuDefinition,
  resolutionManifest?: DockResolutionManifest,
): OnchainHookPlanArtifact {
  return compileOnchainHookPlan(
    compileZhixuHookPlan(definition, resolutionManifest),
  );
}

// These args feed the two-step `commitPlan` + `finalizePlan` flow. The
// `RegisterPlanArgs` name is kept for API stability; renaming is a breaking
// change.
export function compileZhixuRegisterPlanArgs(
  definition: ZhixuDefinition,
  resolutionManifest?: DockResolutionManifest,
): SolidityRegisterPlanArgs {
  return toSolidityRegisterPlanArgs(
    compileZhixuOnchainHookPlan(definition, resolutionManifest),
  );
}

/**
 * OnchainHookPlanArtifact 的封闭字段集（与 types/index.ts 声明同步）：
 * planHash 只覆盖这些字段——未声明额外字段不进哈希，放行会让"同一 plan
 * 唯一字节数组形态"承诺失效（两个仅多余字段不同的制品共享 planHash）。
 */
const ONCHAIN_ARTIFACT_FIELDS: readonly string[] = [
  "schemaVersion",
  "planId",
  "zhixuId",
  "zhixuName",
  "platform",
  "sourcePlanHash",
  "compiledHooks",
  "dependencyIndex",
  "executorRoutes",
  "dockInterface",
  "dockRoutes",
  "dockRoutesRoot",
  "dockInterfaceRoot",
  "selectorBindings",
  "signalCapabilities",
  "planHash",
];

export function validateOnchainHookPlanArtifact(
  value: unknown,
): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value)) {
    return ["artifact must be an object"];
  }

  for (const key of Object.keys(value)) {
    if (!ONCHAIN_ARTIFACT_FIELDS.includes(key)) {
      issues.push(
        `unknown field \`${key}\` on the artifact — planHash does not cover undeclared fields, so the artifact would not be the plan's unique byte form; remove it or recompile`,
      );
    }
  }

  expectLiteral(
    value.schemaVersion,
    ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    "schemaVersion",
    issues,
  );
  expectHexHash(value.planId, "planId", issues);
  expectNonEmptyString(value.zhixuId, "zhixuId", issues);
  expectNonEmptyString(value.zhixuName, "zhixuName", issues);
  if (!isPlatform(value.platform)) {
    issues.push("platform must be an object with a non-empty type");
  }
  expectHexHash(value.sourcePlanHash, "sourcePlanHash", issues);
  expectHexHash(value.planHash, "planHash", issues);
  // 姊妹边界 hook-plan.ts 同口径：dock 字段缺失/畸形必须在形状层报 issue，
  // 而不是落进 planHash 重算的 ?? 兜底或 canonicalize 的未类型化
  // TypeError（fail-open：缺失被钉成 []/null 后哈希仍可通过）。
  if (!Array.isArray(value.dockRoutes)) {
    issues.push("dockRoutes must be an array");
  }
  expectHexHash(value.dockRoutesRoot, "dockRoutesRoot", issues);
  expectHexHash(value.dockInterfaceRoot, "dockInterfaceRoot", issues);
  issues.push(...validateDockCommitments(value));
  if (Array.isArray(value.dockRoutes)) {
    issues.push(...onchainDockTrackIssues(value.dockRoutes));
  }

  const compiledHooks = Array.isArray(value.compiledHooks)
    ? value.compiledHooks
    : undefined;
  if (!compiledHooks) {
    issues.push("compiledHooks must be an array");
  } else if (compiledHooks.length === 0) {
    issues.push("compiledHooks must not be empty (contract reverts EmptyPlan)");
  }

  const dependencyIndex = isHexArrayRecord(value.dependencyIndex)
    ? value.dependencyIndex
    : undefined;
  if (!dependencyIndex) {
    issues.push("dependencyIndex must be a record of 32-byte hex hash arrays");
  }

  const executorRoutes = Array.isArray(value.executorRoutes)
    ? value.executorRoutes
    : undefined;
  if (!executorRoutes) {
    issues.push("executorRoutes must be an array");
  }
  const selectorBindings = Array.isArray(value.selectorBindings)
    ? value.selectorBindings
    : undefined;
  if (!selectorBindings) {
    issues.push("selectorBindings must be an array");
  }
  const signalCapabilities = Array.isArray(value.signalCapabilities)
    ? value.signalCapabilities
    : undefined;
  if (!signalCapabilities) {
    issues.push("signalCapabilities must be an array");
  }

  if (compiledHooks) {
    issues.push(
      ...validateOnchainCompiledHooks(compiledHooks, executorRoutes ?? []),
    );
    issues.push(
      ...canonicalOrderIssues(compiledHooks, hookOrderKey, "compiledHooks"),
    );
    if (dependencyIndex) {
      issues.push(
        ...validateOnchainDependencyIndex(compiledHooks, dependencyIndex),
      );
    }
    // 同一守卫同样作用于反序列化 artifact 边界。
    issues.push(
      ...unmaterializableStageIssues(
        compiledHooks as readonly OnchainCompiledHook[],
        declaredStageIdentifiers(
          (signalCapabilities ?? []).map((capability) =>
            isRecord(capability) && typeof capability.stageIdentifier === "string"
              ? capability.stageIdentifier
              : undefined,
          ),
          (executorRoutes ?? [])
            .map((route) =>
              isRecord(route) && typeof route.stageIdentifier === "string"
                ? route.stageIdentifier
                : undefined,
            ),
          (Array.isArray(value.dockRoutes) ? value.dockRoutes : []).map(
            (route) =>
              isRecord(route) &&
              isRecord(route.local) &&
              typeof route.local.stageIdentifier === "string"
                ? route.local.stageIdentifier
                : undefined,
          ),
          (selectorBindings ?? []).flatMap((binding) =>
            isRecord(binding)
              ? [
                  typeof binding.selectorStageIdentifier === "string"
                    ? binding.selectorStageIdentifier
                    : undefined,
                  typeof binding.targetStageIdentifier === "string"
                    ? binding.targetStageIdentifier
                    : undefined,
                ]
              : [],
          ),
        ),
      ),
    );
    issues.push(
      ...silentOrderTriggerIssues(compiledHooks as readonly OnchainCompiledHook[]),
    );
    issues.push(...planDependencyCountIssues(compiledHooks as readonly OnchainCompiledHook[]));
  }

  if (signalCapabilities) {
    issues.push(
      ...signalCapabilityCountIssues(signalCapabilities as readonly unknown[]),
    );
  }

  if (executorRoutes) {
    issues.push(...validateOnchainExecutorRoutes(executorRoutes));
    // 规范序（编译产物的确定性口径）：planHash 覆盖数组顺序，但重排后重签
    // 的制品能通过承诺对拍——规范序让同一 plan 只有唯一字节数组形态。
    issues.push(
      ...canonicalOrderIssues(executorRoutes, routeOrderKey, "executorRoutes"),
    );
  }
  if (selectorBindings) {
    issues.push(...validateOnchainSelectorBindings(selectorBindings));
    issues.push(
      ...canonicalOrderIssues(
        selectorBindings,
        selectorBindingOrderKey,
        "selectorBindings",
      ),
    );
  }
  if (signalCapabilities) {
    issues.push(
      ...canonicalOrderIssues(
        signalCapabilities,
        signalCapabilityOrderKey,
        "signalCapabilities",
      ),
    );
    issues.push(...validateOnchainSignalCapabilities(signalCapabilities));
    issues.push(
      ...duplicateCurrentOrderFactKeyIssues(
        (signalCapabilities as readonly unknown[]).flatMap((capability) =>
          isRecord(capability) &&
          typeof capability.stageIdentifier === "string" &&
          typeof capability.targetSourceId === "string" &&
          typeof capability.signalId === "string"
            ? [
                {
                  stage: capability.stageIdentifier,
                  sourceId: capability.targetSourceId,
                  signalId: capability.signalId,
                  isCurrentOrder:
                    capability.targetOrderRelation === "current",
                },
              ]
            : [],
        ),
      ),
    );
  }

  if (isPlanHashRecomputable(value)) {
    // 姊妹实现 hook-plan.ts 同口径：重算抛错（负载深层携带 undefined/非
    // JSON 值）按 issue 报告，校验器的契约是返回 issues 而非抛裸 TypeError。
    try {
      const expectedPlanHash = hashOnchainPlanPayload({
        schemaVersion: value.schemaVersion,
        planId: value.planId,
        zhixuId: value.zhixuId,
        zhixuName: value.zhixuName,
        platform: value.platform,
        sourcePlanHash: value.sourcePlanHash,
        compiledHooks: value.compiledHooks,
        dependencyIndex: value.dependencyIndex,
        executorRoutes: value.executorRoutes,
        dockInterface: value.dockInterface,
        dockRoutes: value.dockRoutes,
        dockRoutesRoot: value.dockRoutesRoot,
        dockInterfaceRoot: value.dockInterfaceRoot,
        selectorBindings: value.selectorBindings,
        signalCapabilities: value.signalCapabilities,
      });
      if (value.planHash !== expectedPlanHash) {
        issues.push(
          "planHash must match the canonical on-chain HookPlan payload",
        );
      }
    } catch {
      issues.push(
        "planHash preimage is not canonicalizable (payload carries undefined or non-JSON values)",
      );
    }
  }

  return issues;
}

export function assertOnchainHookPlanArtifact(
  value: unknown,
): asserts value is OnchainHookPlanArtifact {
  const issues = validateOnchainHookPlanArtifact(value);
  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }
}

// Solidity boundary builder: returns args for the two-step
// commitPlan + finalizePlan registration flow. compileZhixuRegisterPlanArgs
// wraps this for direct Zhixu definitions.
export function toSolidityRegisterPlanArgs(
  artifact: OnchainHookPlanArtifact,
): SolidityRegisterPlanArgs {
  assertOnchainHookPlanArtifact(artifact);

  const hooks = artifact.compiledHooks.map((hook) => {
    const dependencyKeys = uniqueSorted(
      hook.dependencies.map((dependency) => dependency.signalKey),
    );
    if (dependencyKeys.length === 0) {
      // Fail-closed mirror of UVPStateMachine._validateHook, which reverts
      // InvalidHook when hook.dependencyKeys is empty.
      throw new OnchainHookPlanArtifactValidationError([
        `compiledHooks ${hook.hookId} dependencyKeys must not be empty `
        + "(contract reverts InvalidHook for empty dependencyKeys)",
      ]);
    }
    const base = {
      hookId: hook.hookId,
      stageId: hook.stageId,
      hookName: onchainHookName(hook.hookName),
      kind: hook.kind,
      flags: solidityHookFlags(hook.orderTriggerKind, hook.emitReady),
      instructions: hook.instructions.map(toSolidityInstructionArg),
      dependencyKeys,
    };
    return hook.routeRef ? { ...base, routeId: hook.routeRef.routeId } : base;
  });
  const selectorBindings = artifact.selectorBindings.map((binding) => ({
    selectorStageId: binding.selectorStageId,
    targetStageId: binding.targetStageId,
  }));
  const signalCapabilities = artifact.signalCapabilities.map((capability) => ({
    stageId: capability.stageId,
    targetSourceId: capability.targetSourceId,
    signalId: capability.signalId,
    targetOrderRelation: solidityTargetOrderRelation(
      capability.targetOrderRelation,
    ),
  }));
  const hooksHash = hashSolidityHooks(hooks);
  const metadataHash = hashSolidityPlanMetadata(
    selectorBindings,
    signalCapabilities,
  );
  // PlanCommit runtime hash 覆盖 dock roots。
  const planHash = keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "bytes32 domain, bytes32 hooksHash, bytes32 metadataHash, bytes32 dockRoutesRoot, bytes32 dockInterfaceRoot",
      ),
      [
        keccak256(stringToHex(PLAN_RUNTIME_HASH_DOMAIN_V2)),
        hooksHash,
        metadataHash,
        artifact.dockRoutesRoot,
        artifact.dockInterfaceRoot,
      ],
    ),
  ) as HexString;

  return {
    schemaVersion: artifact.schemaVersion,
    sourcePlanId: artifact.planId,
    zhixuId: artifact.zhixuId,
    planHash,
    artifactHash: artifact.planHash,
    hooksHash,
    metadataHash,
    dockRoutesRoot: artifact.dockRoutesRoot,
    dockInterfaceRoot: artifact.dockInterfaceRoot,
    hooks,
    dependencyIndex: Object.entries(artifact.dependencyIndex)
      .sort(([left], [right]) => compareByCodeUnit(left, right))
      .map(([signalKey, hookIds]) => ({
        signalKey: signalKey as HexString,
        hookIds,
      })),
    executorRoutes: artifact.executorRoutes.map((route) => ({
      routeId: route.routeId,
      stageId: route.stageId,
      executorType: route.executorType,
      executorId: route.executorId,
      executorHash: route.executorHash,
      resourcesHash: route.resourcesHash,
      routeHash: route.routeHash,
    })),
    selectorBindings,
    signalCapabilities,
  };
}

export function planIdForPublisher(
  publisher: `0x${string}`,
  planHash: HexString,
): HexString {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters("bytes32 domain, address publisher, bytes32 planHash"),
      [keccak256(stringToHex("uvp.plan.id.v1")), publisher, planHash],
    ),
  ) as HexString;
}

/**
 * hooksHash 的唯一权威公式（冻结口径，三方逐字节一致）：
 *
 *   hooksHash = keccak256(abi.encode(CompactHook[]))
 *
 * 其中每条指令 tuple (uint8 op, bytes32 sourceId, bytes32 signalId,
 * uint16 arity, uint64 delaySeconds) 中，非 SIGNAL 指令的 sourceId/signalId
 * 一律填 Solidity 零字（0x00…00，共 32 字节），arity/delaySeconds 未用位填
 * 0——合约 commitPlan 对提交的 calldata 本身重算（fill-agnostic），因此
 * TS compiler、uvp-deploy 驱动与任何链下预计算方必须用同一填充字节。
 * keccak256("")（0xc5d2…470）只作为 DockMerkle.EMPTY_ROOT 出现，与指令
 * 填充无关——任何一方在填充位改用它都会让含 NOT/AND/OR/DELAY 的计划在
 * commitPlan 处 PlanMetadataHashMismatch 必然 revert。导出以便跨语言冻结
 * 向量与 deploy 侧复用同一实现。
 */
export function hashSolidityRegisterHooks(
  hooks: SolidityRegisterPlanArgs["hooks"],
): HexString {
  return hashSolidityHooks(hooks);
}

function hashSolidityHooks(
  hooks: SolidityRegisterPlanArgs["hooks"],
): HexString {
  const encodedHooks = hooks.map((hook) => ({
    hookId: hook.hookId,
    stageId: hook.stageId,
    hookName: hook.hookName,
    flags: hook.flags,
    instructions: hook.instructions.map((instruction) =>
      solidityInstructionTuple(instruction),
    ),
    dependencyKeys: hook.dependencyKeys,
  }));
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "(bytes32 hookId,bytes32 stageId,bytes32 hookName,uint8 flags,(uint8 op,bytes32 sourceId,bytes32 signalId,uint16 arity,uint64 delaySeconds)[] instructions,bytes32[] dependencyKeys)[] hooks",
      ),
      [encodedHooks] as never,
    ),
  ) as HexString;
}

function hashSolidityPlanMetadata(
  selectorBindings: readonly SolidityRegisterStageSelectorBindingArg[],
  signalCapabilities: readonly SolidityRegisterSignalCapabilityArg[],
): HexString {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "(bytes32 selectorStageId,bytes32 targetStageId)[] selectorBindings,(bytes32 stageId,bytes32 targetSourceId,bytes32 signalId,uint8 targetOrderRelation)[] signalCapabilities",
      ),
      [selectorBindings, signalCapabilities],
    ),
  ) as HexString;
}

function solidityInstructionTuple(instruction: SolidityRegisterInstructionArg) {
  switch (instruction.op) {
    case "SIGNAL":
      return {
        op: 0,
        sourceId: instruction.sourceId,
        signalId: instruction.signalId,
        arity: 0,
        delaySeconds: 0n,
      };
    case "NOT":
      return {
        op: 1,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: 0,
        delaySeconds: 0n,
      };
    case "AND":
      return {
        op: 2,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: instruction.arity,
        delaySeconds: 0n,
      };
    case "OR":
      return {
        op: 3,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: instruction.arity,
        delaySeconds: 0n,
      };
    case "DELAY":
      return {
        op: 4,
        sourceId: ZERO_HASH,
        signalId: ZERO_HASH,
        arity: 0,
        delaySeconds: BigInt(instruction.delaySeconds),
      };
  }
}

const ZERO_HASH = `0x${"00".repeat(32)}` as HexString;

function compileHookInstructions(
  ast: HookExpressionAst,
  stageIdentifier: string,
  options: { readonly orderTriggerKind: OrderTriggerKind },
): readonly OnchainHookInstruction[] {
  return compileConditionInstructions(ast.condition, ast.source, stageIdentifier, options);
}

function compileConditionInstructions(
  condition: HookConditionAst,
  source: string,
  stageIdentifier: string,
  options: { readonly orderTriggerKind: OrderTriggerKind },
): readonly OnchainHookInstruction[] {
  switch (condition.kind) {
    case "signal":
      return [signalInstruction(source, condition.signalName)];
    case "subscription":
      // 出生订阅上链的现行三线口径（只描述现状，行为不动）：
      // - outside 出生（triggerOrderFromOutsideFor）：出生事实记录在【新
      //   订单】上，mint hook 在新订单内求值并物化新订单的阶段；
      // - order-link 出生（triggerOrderFromSignalFromModule）：新单 plan 的
      //   trigger hook 定义只用来【预检】origin 订单的信号状态
      //   （_requireTriggerHookReadyForOrder），随后直接标记 Ready 并物化
      //   【新订单】的阶段——源订单只被读取，绝不被链接路径求值或物化；
      // - dock 出生（openDockedOrder）：entrance 事实由模块写入新订单后
      //   标记 Ready。
      // 编译为一条 SIGNAL 指令即可，链上不存在独立的订阅投递子系统。非出
      // 生阶段（route=fanin 按类扇入 / 按单路由）的订阅是云侧运行时投递语
      // 义，仍不上链。
      if (options.orderTriggerKind === "none") {
        throw new HookPlanCompilationError([
          `on-chain HookPlan only supports subscription entries on order-trigger hooks `
          + `(::ANCHOR(@${condition.source}::${condition.signal}) in stage "${source}"); `
          + "non-birth subscriptions are cloud-side runtime deliveries "
          + "(see uvp-core docs/specs/subscription-mint-spec.md)"
        ]);
      }
      return [signalInstruction(condition.source, condition.signal)];
    case "not":
      return [
        ...compileConditionInstructions(condition.expr, source, stageIdentifier, options),
        { op: "NOT" },
      ];
    case "and":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source, stageIdentifier, options),
        ),
        { op: "AND", arity: condition.terms.length },
      ];
    case "or":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source, stageIdentifier, options),
        ),
        { op: "OR", arity: condition.terms.length },
      ];
    case "delay":
      // order-trigger hook 内禁止 DELAY（_validateHook 镜像，产出侧第一
      // 道）：出生事实与订单创建同笔交易，Delay(SIGNAL) 必得 Wait，出生
      // 路径永久 InvalidTriggerHook。
      if (options.orderTriggerKind !== "none") {
        throw new HookPlanCompilationError([
          `on-chain order-trigger hook (${options.orderTriggerKind}) must not contain DELAY `
          + `(@${source}::…+${condition.durationSeconds}s); birth facts settle at order creation `
          + "(contract _validateHook reverts InvalidInstruction)",
        ]);
      }
      return [
        ...compileConditionInstructions(condition.expr, source, stageIdentifier, options),
        { op: "DELAY", delaySeconds: condition.durationSeconds },
      ];
    default:
      assertNever(condition);
  }
}

function signalInstruction(
  source: string,
  signalName: string,
): OnchainHookInstruction {
  const sourceId = onchainSourceId(source);
  const signalId = onchainSignalId(signalName);
  return {
    op: "SIGNAL",
    source,
    signalName,
    sourceId,
    signalId,
    signalKey: onchainSignalKey(sourceId, signalId),
  };
}

function compileDependency(dependency: HookDependency): OnchainHookDependency {
  const sourceId = onchainSourceId(dependency.source);
  const signalId = onchainSignalId(dependency.signalName);
  return {
    kind: dependency.kind,
    source: dependency.source,
    signalName: dependency.signalName,
    sourceId,
    signalId,
    signalKey: onchainSignalKey(sourceId, signalId),
    ...(dependency.delaySeconds !== undefined
      ? { delaySeconds: dependency.delaySeconds }
      : {}),
  };
}

/**
 * Per-key hookIds MUST follow the compiledHooks (= commitPlan calldata) order:
 * UVPStateMachine._registerPlanHook pushes `input.hookId` while scanning the
 * submitted hooks array, and the replay oracle replays the per-key array
 * positionally. Sorting by hookId (keccak order) forks the contract's
 * dependencyIndex and flips the oracle's event pairing whenever the two
 * orders disagree on a key with ≥2 same-partition (trigger/watcher) hooks.
 */
function buildOnchainDependencyIndex(
  compiledHooks: readonly OnchainCompiledHook[],
): Record<HexString, readonly HexString[]> {
  const index = new Map<HexString, HexString[]>();
  for (const hook of compiledHooks) {
    for (const dependency of hook.dependencies) {
      const hookIds = index.get(dependency.signalKey) ?? [];
      // Mirror the contract's per-hook dependencyKey dedup: one hook can only
      // register once per key.
      if (!hookIds.includes(hook.hookId)) {
        hookIds.push(hook.hookId);
      }
      index.set(dependency.signalKey, hookIds);
    }
  }

  const output: Record<HexString, readonly HexString[]> = {};
  for (const [signalKey, hookIds] of [...index.entries()].sort(
    ([left], [right]) => compareByCodeUnit(left, right),
  )) {
    output[signalKey] = hookIds;
  }
  return output;
}

function compileExecutorRoute(
  route: HookPlanExecutorRoute,
): OnchainExecutorRoute {
  if (route.executor.supplierID === undefined || route.executor.supplierID === "") {
    throw new HookPlanCompilationError([
      `executor route "${route.stageIdentifier}" (supplierType=${String(route.executor.supplierType)}) is missing a non-empty executor.supplierID`,
    ]);
  }
  // supplierType 闭集（rule executor-supplier-type-closed-enum 的链轨编译
  // 入口镜像）：闭集外字符串经 executorHash 进链上承诺后无合约守卫可拦。
  const supplierType = String(route.executor.supplierType);
  if (!SUPPLIER_TYPES.includes(supplierType.trim())) {
    throw new HookPlanCompilationError([
      `executor route "${route.stageIdentifier}" supplierType must be one of ${SUPPLIER_TYPES.join("|")} (case-sensitive), received ${JSON.stringify(supplierType)}`,
    ]);
  }
  // fileType 闭集（与云侧编译入口同集）：fileResources 进 resourcesHash
  // 承诺，拼错的 fileType 是确定性输入缺陷，不静默成承诺内容。
  if (route.fileResources !== undefined) {
    for (const [key, resource] of Object.entries(route.fileResources)) {
      if (!FILE_TYPES.includes(String(resource.fileType))) {
        throw new HookPlanCompilationError([
          `executor route "${route.stageIdentifier}" fileResources[${JSON.stringify(key)}].fileType must be one of ${FILE_TYPES.join("|")}, received ${JSON.stringify(resource.fileType)}`,
        ]);
      }
    }
  }
  const executorHash = opaqueContentHash(route.executor);
  const resourcesHash =
    route.fileResources === undefined ? ZERO_HASH : opaqueContentHash(route.fileResources);
  return {
    routeId: onchainRouteId(route.stageIdentifier),
    stageId: onchainStageId(route.stageIdentifier),
    stageIdentifier: route.stageIdentifier,
    executorType: String(route.executor.supplierType),
    executorId: route.executor.supplierID,
    executorHash,
    resourcesHash,
    routeHash: routeHashFromDigests(
      onchainStageId(route.stageIdentifier),
      route.stageIdentifier,
      executorHash,
      resourcesHash,
    ),
  };
}

function compileSelectorBindings(
  bindings: readonly SelectedStageBinding[],
): readonly OnchainStageSelectorBinding[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  const compiled: OnchainStageSelectorBinding[] = [];

  for (const binding of bindings) {
    const selectorStageId = onchainStageId(binding.selectorStageIdentifier);
    const targetStageId = onchainStageId(binding.targetStageIdentifier);
    const bindingKey = selectorBindingKey(selectorStageId, targetStageId);
    if (seen.has(bindingKey)) {
      issues.push(
        `duplicate selector binding ${binding.selectorStageIdentifier}->${binding.targetStageIdentifier}`,
      );
      continue;
    }
    seen.add(bindingKey);
    compiled.push({
      selectorStageIdentifier: binding.selectorStageIdentifier,
      targetStageIdentifier: binding.targetStageIdentifier,
      selectorStageId,
      targetStageId,
      bindingHash: onchainSelectorBindingHash(selectorStageId, targetStageId),
    });
  }

  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }

  return compiled.sort(compareSelectorBindings);
}

function compileSignalCapabilities(
  capabilities: readonly SignalCapability[],
): readonly OnchainSignalCapability[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  const compiled: OnchainSignalCapability[] = [];
  for (const capability of capabilities) {
    const stageId = onchainStageId(capability.stageIdentifier);
    const targetSourceId = onchainSourceId(capability.targetSource);
    const signalId = onchainSignalId(capability.targetSignalName);
    const key = [
      stageId,
      targetSourceId,
      signalId,
      capability.targetOrderRelation,
    ].join("\u0000");
    if (seen.has(key)) {
      issues.push(
        `duplicate signal capability ${capability.stageIdentifier}->${capability.targetSource}::${capability.targetSignalName}`,
      );
      continue;
    }
    seen.add(key);
    compiled.push({
      stageIdentifier: capability.stageIdentifier,
      stageId,
      source: capability.source,
      declaredSignal: capability.declaredSignal,
      targetSource: capability.targetSource,
      targetSourceId,
      targetSignalName: capability.targetSignalName,
      signalId,
      targetOrderRelation: capability.targetOrderRelation,
      capabilityHash: onchainSignalCapabilityHash(
        stageId,
        targetSourceId,
        signalId,
        capability.targetOrderRelation,
      ),
    });
  }
  if (issues.length > 0) {
    throw new OnchainHookPlanArtifactValidationError(issues);
  }
  return compiled.sort(compareSignalCapabilities);
}

function routeRefForRoute(
  route: HookPlanExecutorRoute,
): OnchainExecutorRouteRef {
  return {
    routeId: onchainRouteId(route.stageIdentifier),
    stageId: onchainStageId(route.stageIdentifier),
    routeHash: onchainRouteHash(route),
  };
}

export function onchainHookId(
  stageIdentifier: string,
  hookName: string,
): HexString {
  return keccak256Hex(`${stageIdentifier}#${hookName}`);
}

export function onchainStageId(stageIdentifier: string): HexString {
  return keccak256Hex(stageIdentifier);
}

export function onchainHookName(hookName: string): HexString {
  return keccak256Hex(hookName);
}

export function onchainSourceId(source: string): HexString {
  return keccak256Hex(source);
}

export function onchainSignalId(signalName: string): HexString {
  return keccak256Hex(signalName);
}

export function onchainSelectorBindingHash(
  selectorStageId: HexString,
  targetStageId: HexString,
): HexString {
  return hashCanonical(ONCHAIN_SELECTOR_BINDING_HASH_DOMAIN, {
    selectorStageId,
    targetStageId,
  });
}

export function onchainSignalCapabilityHash(
  stageId: HexString,
  targetSourceId: HexString,
  signalId: HexString,
  targetOrderRelation: SignalTargetOrderRelation,
): HexString {
  return hashCanonical(ONCHAIN_SIGNAL_CAPABILITY_HASH_DOMAIN, {
    stageId,
    targetSourceId,
    signalId,
    targetOrderRelation,
  });
}

function onchainRouteId(stageIdentifier: string): HexString {
  return keccak256Hex(`${stageIdentifier}#executorRoute`);
}

export function onchainSignalKey(
  sourceId: HexString,
  signalId: HexString,
): HexString {
  return keccak256Hex(concatHex32(sourceId, signalId));
}

function opaqueContentHash(value: unknown): HexString {
  return keccak256Hex(canonicalStringify(value));
}

function onchainRouteHash(route: HookPlanExecutorRoute): HexString {
  return routeHashFromDigests(
    onchainStageId(route.stageIdentifier),
    route.stageIdentifier,
    opaqueContentHash(route.executor),
    route.fileResources === undefined ? ZERO_HASH : opaqueContentHash(route.fileResources),
  );
}

function routeHashFromDigests(
  stageId: HexString,
  stageIdentifier: string,
  executorHash: HexString,
  resourcesHash: HexString,
): HexString {
  return hashCanonical(ONCHAIN_ROUTE_HASH_DOMAIN, {
    stageId,
    stageIdentifier,
    executorHash,
    resourcesHash,
  });
}

/**
 * Canonical payload hash of an on-chain HookPlan artifact. Exported so
 * golden-fixture maintainers can re-pin planHash values with the exact
 * production formula instead of transcribing them by hand.
 */
export function hashOnchainPlanPayload(
  payload: Omit<OnchainHookPlanArtifact, "planHash">,
): HexString {
  return hashCanonical(ONCHAIN_PLAN_HASH_DOMAIN, payload);
}

function toSolidityInstructionArg(
  instruction: OnchainHookInstruction,
): SolidityRegisterInstructionArg {
  switch (instruction.op) {
    case "SIGNAL":
      return {
        op: "SIGNAL",
        sourceId: instruction.sourceId,
        signalId: instruction.signalId,
        signalKey: instruction.signalKey,
      };
    case "NOT":
      return { op: "NOT" };
    case "AND":
    case "OR":
      return { op: instruction.op, arity: instruction.arity };
    case "DELAY":
      return { op: "DELAY", delaySeconds: instruction.delaySeconds };
    default:
      assertNever(instruction);
  }
}

function solidityTargetOrderRelation(
  relation: SignalTargetOrderRelation,
): 0 | 1 {
  switch (relation) {
    case "current":
      return 0;
    case "triggerOrigin":
      return 1;
    default:
      assertNever(relation);
  }
}

/**
 * E16 镜像（uvp-constraints.v1.json rejectionSurfaces
 * e16-current-order-factkey-unique-owner）：relation=0（current）的事实键
 * (targetSourceId, signalId) 在 plan 内有唯一属主阶段——跨阶段重复声明在
 * UVPPlanMetadataModule finalizePlan 的注册守卫 revert
 * DuplicateCurrentOrderSignalCapability。此类 plan 能通过 commitPlan、
 * finalize 永久 revert（planId 烧毁，2318中2），这里是 artifact 边界的
 * 编译期预检；Rust/Go 镜像仍欠（镜像债）。
 */
function duplicateCurrentOrderFactKeyIssues(
  capabilities: readonly {
    readonly stage: string;
    readonly sourceId: string;
    readonly signalId: string;
    readonly isCurrentOrder: boolean;
  }[],
): readonly string[] {
  const issues: string[] = [];
  const owners = new Map<string, string>();
  for (const capability of capabilities) {
    if (!capability.isCurrentOrder) {
      continue;
    }
    const factKey = `${capability.sourceId}:${capability.signalId}`;
    const owner = owners.get(factKey);
    if (owner === undefined) {
      owners.set(factKey, capability.stage);
      continue;
    }
    if (owner !== capability.stage) {
      issues.push(
        `stage ${capability.stage} declares the current-order fact key `
          + `(${capability.sourceId}, ${capability.signalId}) already owned by stage ${owner}; `
          + "UVPPlanMetadataModule reverts DuplicateCurrentOrderSignalCapability at "
          + "finalizePlan, so the plan would commit but finalize permanently — "
          + "declare the fact key on a single stage",
      );
    }
  }
  return issues;
}

function validateOnchainCompiledHooks(
  hooks: readonly unknown[],
  executorRoutes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const hookIds = new Set<string>();
  const routeIds = new Set(
    executorRoutes
      .filter(isRecord)
      .map((route) => route.routeId)
      .filter((routeId): routeId is string => typeof routeId === "string"),
  );
  const routesById = new Map<string, Record<string, unknown>>();
  for (const route of executorRoutes) {
    if (isRecord(route) && typeof route.routeId === "string") {
      routesById.set(route.routeId, route);
    }
  }

  for (const [index, hook] of hooks.entries()) {
    if (!isRecord(hook)) {
      issues.push(`compiledHooks[${index}] must be an object`);
      continue;
    }

    const prefix = `compiledHooks[${index}]`;
    expectHexHash(hook.hookId, `${prefix}.hookId`, issues);
    expectHexHash(hook.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(
      hook.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectNonEmptyString(hook.hookName, `${prefix}.hookName`, issues);
    expectOneOf(hook.kind, ["receive"], `${prefix}.kind`, issues);
    expectOneOf(
      hook.orderTriggerKind,
      ["none", "mint", "dock"],
      `${prefix}.orderTriggerKind`,
      issues,
    );
    expectBoolean(hook.emitReady, `${prefix}.emitReady`, issues);

    if (
      typeof hook.stageIdentifier === "string" &&
      typeof hook.hookName === "string" &&
      typeof hook.hookId === "string" &&
      hook.hookId !== onchainHookId(hook.stageIdentifier, hook.hookName)
    ) {
      issues.push(
        `${prefix}.hookId must be keccak256(stageIdentifier#hookName)`,
      );
    }
    if (
      typeof hook.stageIdentifier === "string" &&
      typeof hook.stageId === "string" &&
      hook.stageId !== onchainStageId(hook.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (typeof hook.hookId === "string") {
      if (hookIds.has(hook.hookId)) {
        issues.push(`duplicate hookId ${hook.hookId}`);
      }
      hookIds.add(hook.hookId);
    }

    if (!Array.isArray(hook.instructions)) {
      issues.push(`${prefix}.instructions must be an array`);
    } else {
      issues.push(
        ...validateInstructions(hook.instructions, `${prefix}.instructions`, {
          orderTrigger:
            typeof hook.orderTriggerKind === "string" &&
            hook.orderTriggerKind !== "none",
        }),
      );
    }

    if (!Array.isArray(hook.dependencies)) {
      issues.push(`${prefix}.dependencies must be an array`);
    } else {
      issues.push(
        ...validateOnchainDependencies(
          hook.dependencies,
          `${prefix}.dependencies`,
        ),
      );
    }

    if (hook.routeRef !== undefined) {
      if (!isRecord(hook.routeRef)) {
        issues.push(`${prefix}.routeRef must be an object`);
      } else {
        expectHexHash(
          hook.routeRef.routeId,
          `${prefix}.routeRef.routeId`,
          issues,
        );
        expectHexHash(
          hook.routeRef.stageId,
          `${prefix}.routeRef.stageId`,
          issues,
        );
        expectHexHash(
          hook.routeRef.routeHash,
          `${prefix}.routeRef.routeHash`,
          issues,
        );
        if (
          typeof hook.routeRef.stageId === "string" &&
          typeof hook.stageId === "string" &&
          hook.routeRef.stageId !== hook.stageId
        ) {
          issues.push(`${prefix}.routeRef.stageId must equal hook stageId`);
        }
        if (
          typeof hook.routeRef.routeId === "string" &&
          !routeIds.has(hook.routeRef.routeId)
        ) {
          issues.push(
            `${prefix}.routeRef.routeId must reference executorRoutes`,
          );
        }
        if (
          typeof hook.routeRef.routeId === "string" &&
          typeof hook.routeRef.routeHash === "string"
        ) {
          const referencedRoute = routesById.get(hook.routeRef.routeId);
          if (
            referencedRoute &&
            referencedRoute.routeHash !== hook.routeRef.routeHash
          ) {
            issues.push(
              `${prefix}.routeRef.routeHash must match the referenced executor route`,
            );
          }
        }
      }
    }
  }

  return issues;
}

/**
 * 镜像 UVPStateMachine._validateHook 的栈机语义（bareSignal/hasPosAnchor
 * 双轨），形状校验与语义镜像同址：形状坏项计入 issues 后仍按合同口径推进
 * 栈机，让单次校验暴露全部缺口。
 */
function validateInstructions(
  instructions: readonly unknown[],
  path: string,
  options: { readonly orderTrigger: boolean },
): readonly string[] {
  const issues: string[] = [];
  let stackDepth = 0;
  const bareSignal: boolean[] = [];
  const hasPosAnchor: boolean[] = [];

  for (const [index, instruction] of instructions.entries()) {
    if (!isRecord(instruction)) {
      issues.push(`${path}[${index}] must be an object`);
      continue;
    }

    const prefix = `${path}[${index}]`;
    switch (instruction.op) {
      case "SIGNAL":
        expectString(instruction.source, `${prefix}.source`, issues);
        expectNonEmptyString(
          instruction.signalName,
          `${prefix}.signalName`,
          issues,
        );
        expectHexHash(instruction.sourceId, `${prefix}.sourceId`, issues);
        expectHexHash(instruction.signalId, `${prefix}.signalId`, issues);
        expectHexHash(instruction.signalKey, `${prefix}.signalKey`, issues);
        if (
          typeof instruction.source === "string" &&
          typeof instruction.sourceId === "string" &&
          instruction.sourceId !== onchainSourceId(instruction.source)
        ) {
          issues.push(`${prefix}.sourceId must be keccak256(source)`);
        }
        if (
          typeof instruction.signalName === "string" &&
          typeof instruction.signalId === "string" &&
          instruction.signalId !== onchainSignalId(instruction.signalName)
        ) {
          issues.push(
            `${prefix}.signalId must be keccak256(task.stage.signal)`,
          );
        }
        if (
          typeof instruction.sourceId === "string" &&
          typeof instruction.signalId === "string" &&
          isHexHash(instruction.sourceId) &&
          isHexHash(instruction.signalId) &&
          instruction.signalKey !==
            onchainSignalKey(instruction.sourceId, instruction.signalId)
        ) {
          issues.push(
            `${prefix}.signalKey must be keccak256(abi.encodePacked(sourceId, signalId))`,
          );
        }
        bareSignal[stackDepth] = true;
        hasPosAnchor[stackDepth] = true;
        stackDepth += 1;
        break;
      case "NOT":
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        // NOT 操作数必须裸 SIGNAL（_validateHook 镜像）：~(A&B)/~Delay(A) 的
        // 组合否定语义与编译器产物形态分叉，注册边界拒绝。
        if (!bareSignal[stackDepth - 1]) {
          issues.push(
            `${prefix}.op requires a bare SIGNAL operand `
            + "(contract _validateHook reverts InvalidInstruction for NOT over composite/delayed operands)",
          );
        }
        bareSignal[stackDepth - 1] = false;
        hasPosAnchor[stackDepth - 1] = false;
        break;
      case "AND":
      case "OR": {
        if (
          !Number.isSafeInteger(instruction.arity) ||
          Number(instruction.arity) < 2
        ) {
          issues.push(`${prefix}.arity must be a safe integer greater than 1`);
          break;
        }
        const arity = Number(instruction.arity);
        if (stackDepth < arity) {
          issues.push(`${prefix}.op requires ${arity} stack items`);
          break;
        }
        // And 取任一正锚，Or 需每一分支都有（Or 的缺席分支可单独就绪且
        // 锚点为 0）——只被 DELAY 的操作数正锚检查消费。
        const anchored =
          instruction.op === "AND"
            ? hasPosAnchor
                .slice(stackDepth - arity, stackDepth)
                .some(Boolean)
            : hasPosAnchor
                .slice(stackDepth - arity, stackDepth)
                .every(Boolean);
        stackDepth = stackDepth - arity + 1;
        bareSignal[stackDepth - 1] = false;
        hasPosAnchor[stackDepth - 1] = anchored;
        break;
      }
      case "DELAY":
        if (
          !Number.isSafeInteger(instruction.delaySeconds) ||
          Number(instruction.delaySeconds) <= 0
        ) {
          issues.push(`${prefix}.delaySeconds must be a positive safe integer`);
        } else if (
          Number(instruction.delaySeconds) > MAX_ONCHAIN_HOOK_DELAY_SECONDS
        ) {
          issues.push(
            `${prefix}.delaySeconds must not exceed ${MAX_ONCHAIN_HOOK_DELAY_SECONDS} `
            + "(contract MAX_HOOK_DELAY_SECONDS = 30 days, reverts HookDelayTooLong)",
          );
        }
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
          break;
        }
        // order-trigger hook 内禁止 DELAY（_validateHook 镜像）：出生事实
        // 与订单创建同笔交易，DELAY 只会让出生路径永久 InvalidTriggerHook。
        if (options.orderTrigger) {
          issues.push(
            `${prefix}.op DELAY is not allowed on order-trigger hooks `
            + "(contract _validateHook reverts InvalidInstruction; birth facts settle at order creation)",
          );
        }
        // 延时操作数须含正向信号锚点（validate_anchors 镜像）：全否定/
        // 缺席的操作数在 value=true 时 anchorAt=0，到期时刻恒在过去。
        if (!hasPosAnchor[stackDepth - 1]) {
          issues.push(
            `${prefix}.op DELAY requires an operand with a positive signal anchor `
            + "(contract _validateHook reverts InvalidInstruction for delay over purely-negative operands)",
          );
        }
        bareSignal[stackDepth - 1] = false;
        break;
      default:
        issues.push(`${prefix}.op must be one of SIGNAL, NOT, AND, OR, DELAY`);
    }
  }

  // Aligned with UVPStateMachine._validateHook: `hook.instructions.length == 0`
  // reverts InvalidHook on-chain, so an empty instruction array must fail the
  // preflight too (stack depth 0 !== 1 below).
  if (stackDepth !== 1) {
    issues.push(`${path} must leave exactly one stack item`);
  } else if (!hasPosAnchor[0]) {
    // 整体至少一正锚（validate_anchors 镜像）：纯否定条件在 value=true 时
    // anchorAt=0，注册边界拒绝。
    issues.push(
      `${path} must contain at least one positive signal anchor `
      + "(contract _validateHook reverts InvalidInstruction for purely-negative hook conditions)",
    );
  }

  return issues;
}

function validateOnchainDependencies(
  dependencies: readonly unknown[],
  path: string,
): readonly string[] {
  const issues: string[] = [];
  // Aligned with UVPStateMachine._validateHook: `hook.dependencyKeys.length == 0`
  // reverts InvalidHook on-chain, so a hook without dependencies is invalid
  // at the artifact boundary as well.
  if (dependencies.length === 0) {
    issues.push(
      `${path} must not be empty `
      + "(contract reverts InvalidHook for empty dependencyKeys)",
    );
  }
  for (const [index, dependency] of dependencies.entries()) {
    if (!isRecord(dependency)) {
      issues.push(`${path}[${index}] must be an object`);
      continue;
    }

    const prefix = `${path}[${index}]`;
    expectOneOf(
      dependency.kind,
      ["positive", "negative", "timer"],
      `${prefix}.kind`,
      issues,
    );
    expectString(dependency.source, `${prefix}.source`, issues);
    expectNonEmptyString(dependency.signalName, `${prefix}.signalName`, issues);
    expectHexHash(dependency.sourceId, `${prefix}.sourceId`, issues);
    expectHexHash(dependency.signalId, `${prefix}.signalId`, issues);
    expectHexHash(dependency.signalKey, `${prefix}.signalKey`, issues);
    if (
      typeof dependency.source === "string" &&
      typeof dependency.sourceId === "string" &&
      dependency.sourceId !== onchainSourceId(dependency.source)
    ) {
      issues.push(`${prefix}.sourceId must be keccak256(source)`);
    }
    if (
      typeof dependency.signalName === "string" &&
      typeof dependency.signalId === "string" &&
      dependency.signalId !== onchainSignalId(dependency.signalName)
    ) {
      issues.push(`${prefix}.signalId must be keccak256(task.stage.signal)`);
    }
    if (
      typeof dependency.sourceId === "string" &&
      typeof dependency.signalId === "string" &&
      isHexHash(dependency.sourceId) &&
      isHexHash(dependency.signalId) &&
      dependency.signalKey !==
        onchainSignalKey(dependency.sourceId, dependency.signalId)
    ) {
      issues.push(
        `${prefix}.signalKey must be keccak256(abi.encodePacked(sourceId, signalId))`,
      );
    }
    if (dependency.delaySeconds !== undefined) {
      // E12：delaySeconds 只要在场就必须是正安全整数——非数值/NaN/零/负数
      // 一律拒绝，不按 kind 静默放行。
      if (
        !Number.isSafeInteger(dependency.delaySeconds) ||
        Number(dependency.delaySeconds) <= 0
      ) {
        issues.push(
          `${prefix}.delaySeconds must be a positive safe integer when present`,
        );
      }
    }
    if (
      dependency.kind === "timer" &&
      (typeof dependency.delaySeconds !== "number" ||
        !Number.isSafeInteger(dependency.delaySeconds) ||
        Number(dependency.delaySeconds) <= 0)
    ) {
      issues.push(
        `${prefix}.delaySeconds must be a positive safe integer for timer dependencies`,
      );
    }
  }
  return issues;
}

/**
 * 阶段物化门（onchain target，镜像 uvp-core 659a388
 * validate_onchain_stage_materialization）：
 *
 * - 每个出现在 compiledHooks 的阶段必须至少有一个 order-trigger 或
 *   EMIT_READY hook（能物化自身阶段的 hook）。纯 flags=0 watcher 阶段在
 *   链上永远无法物化——挂在其上的任何 hook 都构成不可恢复死锁。
 * - 每个在 artifact 上留有声明投影（signalCapabilities / executorRoutes /
 *   selectorBindings）的阶段不得编译为零 hook——零 hook 阶段同样永不可
 *   物化，且其 sendSignals 在链上没有钩子可挂（submitSignal 恒 revert
 *   UnknownHook）。Rust 定义层第一道拒绝（"declares no receiveSignals"），
 *   这里是 artifact 边界的第二道。
 *
 * dock entrance 豁免口径与 Rust dock_entrance_hook_ids 单一来源一致：entrance
 * 端口钩子在两个编译器里都编译为 orderTriggerKind=dock（dock|emitReady=6），
 * 因此 artifact 层只认编译后的物化位本身、不再从 dockInterface 端口重推——
 * flags 即该豁免的产物投影，重推属于镜像扩张。
 */
function unmaterializableStageIssues(
  hooks: readonly OnchainCompiledHook[],
  declaredStages: ReadonlySet<string>,
): readonly string[] {
  const issues: string[] = [];
  const stageMaterializer = new Map<string, boolean>();
  for (const hook of hooks) {
    const canMaterialize =
      hook.orderTriggerKind !== "none" || hook.emitReady;
    const current = stageMaterializer.get(hook.stageId) ?? false;
    stageMaterializer.set(hook.stageId, current || canMaterialize);
  }
  for (const hook of hooks) {
    if (stageMaterializer.get(hook.stageId)) {
      continue;
    }
    issues.push(
      `stage ${hook.stageIdentifier} has no order-trigger or EMIT_READY hook; its hooks compile to flags=0 watchers which can never materialize the stage on-chain (deadlock, no recovery path) — the Rust compiler must reject this shape`,
    );
  }
  for (const stageIdentifier of [...declaredStages].sort(compareByCodeUnit)) {
    if (stageMaterializer.has(onchainStageId(stageIdentifier))) {
      continue;
    }
    issues.push(
      `stage ${stageIdentifier} declares no receiveSignals and compiles to zero hooks: `
        + "the stage can never materialize on-chain (materialization only happens via "
        + "this stage's own order-trigger/EMIT_READY hooks) and its sendSignals have "
        + "no hook to hang on — submitSignal requires the source stage to be "
        + "materialized and reverts UnknownHook forever (deadlock, no recovery path); "
        + "declare receiveSignals carrying a mint/dock entrance or a static executor",
    );
  }
  return issues;
}

/**
 * 链轨 dock route 门（"明确不做"项）：
 * - `orderMode: "existing"`：Rust 两个编译 profile 都放行（existing 是云轨
 *   运行时语义），on-chain 编译必须显式拒绝，不得静默降级为 new 或吞掉；
 * - 未解析目标（target 缺失/非对象/无 zhixuUid，含 `target: null` 的动态
 *   选择 route）：on-chain 没有运行时选择面，按 UNRESOLVED_DOCK_TARGET
 *   口径拒绝（与 Rust 无 manifest 时的编译期错误同锚点）；
 * - new 模式恰一条 input 绑定（Rust D010 / 合约 DockBindingCountInvalid
 *   镜像）：出生锚必须唯一确定，inputBindings 数 ≠1 在两个边界同口径拒绝。
 * 编译入口（compileOnchainHookPlan preflight）与反序列化边界
 * （validateOnchainHookPlanArtifact）共用本门。
 */
function onchainDockTrackIssues(routes: readonly unknown[]): readonly string[] {
  const issues: string[] = [];
  for (const [index, route] of routes.entries()) {
    if (!isRecord(route)) {
      continue;
    }
    const stageIdentifier =
      (isRecord(route.local) &&
        typeof route.local.stageIdentifier === "string" &&
        route.local.stageIdentifier) ||
      `dockRoutes[${index}]`;
    if (route.orderMode === "existing") {
      issues.push(
        `dock route ${stageIdentifier} uses order mode "existing", which on-chain targets do not support; ` +
          "the on-chain track requires an explicit rejection instead of a silent fallback — " +
          'serve this route from a cloud runtime or bind an interface with order mode "new"',
      );
    }
    if (
      route.orderMode === "new" &&
      (Array.isArray(route.inputBindings) ? route.inputBindings.length : 0) !== 1
    ) {
      issues.push(
        `DOCK_BINDING_COUNT_INVALID: dock route ${stageIdentifier} uses order mode "new" and must declare exactly one input binding (the birth anchor), found ` +
          (Array.isArray(route.inputBindings) ? route.inputBindings.length : 0),
      );
    }
    const target = route.target;
    if (
      !isRecord(target) ||
      typeof target.zhixuUid !== "string" ||
      target.zhixuUid.trim().length === 0
    ) {
      issues.push(
        `UNRESOLVED_DOCK_TARGET: dock route ${stageIdentifier} has no statically linked target; ` +
          "on-chain compilation cannot fill a dynamic (null) target at runtime",
      );
    }
  }
  return issues;
}

/**
 * 未解析 route（target:null 动态选择，§8.8）的链轨门：Rust hook_plan 产物
 * 携带 unresolvedDockRoutes 声明面（云轨运行时由选择记录补齐），on-chain
 * 没有运行时选择面——按 UNRESOLVED_DOCK_TARGET 口径逐条响亮拒绝，不静默
 * 丢弃。onchain 产物自身不携带该字段，此门只作用于编译入口。
 */
function onchainUnresolvedRouteIssues(
  routes: readonly unknown[] | undefined,
): readonly string[] {
  if (!Array.isArray(routes) || routes.length === 0) {
    return [];
  }
  const issues: string[] = [];
  for (const [index, route] of routes.entries()) {
    const stageIdentifier =
      (isRecord(route) &&
        typeof route.stageIdentifier === "string" &&
        route.stageIdentifier) ||
      `unresolvedDockRoutes[${index}]`;
    issues.push(
      `UNRESOLVED_DOCK_TARGET: dock route ${stageIdentifier} declares a dynamic (null) target carried as an unresolved route; ` +
        "on-chain compilation cannot fill it from selection records at runtime — " +
        "serve this route from a cloud runtime or bind a static target",
    );
  }
  return issues;
}

/**
 * artifact 边界可见的“阶段声明”全集：sendSignals（signalCapabilities）、
 * executor（executorRoutes）、dock 委托（dockRoutes）、selectedStages
 * （selectorBindings 两侧）四类声明各留一处投影；receiveSignals 的投影是
 * compiledHooks 本体。零 hook 阶段没有 compiledHooks 记录，只能从这四处
 * 发现——zhixu 委托阶段只出现在 dockRoutes 一侧、不进 executorRoutes，漏
 * 投影会让手工制品绕过零 hook 门。非字符串项交由形状校验报错，这里静默
 * 跳过。
 */
function declaredStageIdentifiers(
  ...identifierGroups: readonly (readonly (string | undefined)[])[]
): Set<string> {
  const identifiers = new Set<string>();
  for (const group of identifierGroups) {
    for (const identifier of group) {
      if (typeof identifier === "string" && identifier.trim().length > 0) {
        identifiers.add(identifier);
      }
    }
  }
  return identifiers;
}

/**
 * HookReady 三线口径统一镜像：order-trigger hook 必须携带 emitReady——
 * Rust 编译器产物恒为 trigger|EMIT_READY（flags=5/6），UVPStateMachine
 * commitPlan 对缺 EMIT_READY 的"沉默 trigger"revert SilentOrderTriggerHook。
 * 这里是 artifact 边界的镜像门禁（编译器第一道，合约注册边界兜底）。
 */
function silentOrderTriggerIssues(
  hooks: readonly OnchainCompiledHook[],
): readonly string[] {
  const issues: string[] = [];
  for (const hook of hooks) {
    if (hook.orderTriggerKind !== "none" && !hook.emitReady) {
      issues.push(
        `hook ${hook.stageIdentifier}#${hook.hookName} is an order trigger without emitReady; ` +
          `UVPStateMachine.commitPlan reverts SilentOrderTriggerHook — ` +
          `the Rust compiler must always emit trigger flags with EMIT_READY`,
      );
    }
  }
  return issues;
}

/**
 * E12 镜像：UVPStateMachine.commitPlan 对去重后的 dependency key 总数执行
 * MAX_PLAN_DEPENDENCIES=1024 上限（TooManyDependencies）——预检同口径拒绝。
 */
function planDependencyCountIssues(
  hooks: readonly OnchainCompiledHook[],
): readonly string[] {
  const keys = new Set<string>();
  for (const hook of hooks) {
    for (const dependency of hook.dependencies) {
      keys.add(dependency.signalKey);
    }
  }
  if (keys.size > MAX_PLAN_DEPENDENCIES) {
    return [
      `distinct dependency keys ${keys.size} exceed the contract limit ${MAX_PLAN_DEPENDENCIES} (commitPlan reverts TooManyDependencies)`,
    ];
  }
  return [];
}

/**
 * 能力表规模预检：sendSignals 声明总量（编译为 signalCapabilities）超过
 * MAX_SIGNAL_CAPABILITIES 时，UVPPlanMetadataModule 逐条写存储的注册循环
 * gas 随表规模无界增长（合约注册边界 revert TooManySignalCapabilities）
 * ——预检在编译/反序列化两个边界同口径拒绝。
 */
function signalCapabilityCountIssues(
  capabilities: readonly unknown[],
): readonly string[] {
  if (capabilities.length > MAX_SIGNAL_CAPABILITIES) {
    return [
      `signal capabilities ${capabilities.length} exceed the documented limit ${MAX_SIGNAL_CAPABILITIES} `
      + "(UVPPlanMetadataModule registers each capability with a storage write; unbounded plan-controlled registration gas)",
    ];
  }
  return [];
}

/**
 * Cross-stage dependency preflight mirroring UVPStateMachine._registerPlanHook
 * byte-for-byte in SEMANTICS: hooks are processed in submitted (artifact)
 * order, and per signal key the FIRST watcher pins the recorded stage.
 * A later cross-stage watcher passes only while every watcher seen so far on
 * that key (AND-accumulated) is an order trigger; a set-based "any stage plus
 * any non-trigger watcher" check is STRICTER than the contract and rejects
 * plans the contract accepts (e.g. trigger(A) → trigger(B) → watcher(A)),
 * so the sequential scan is load-bearing, not an optimization.
 *
 * Field mapping note: artifacts carry `orderTriggerKind`
 * ("none" | "mint" | "dock") — there is no `isOrderTrigger` boolean, neither
 * at compile time nor in deserialized artifacts. The trigger flag is always
 * derived as `orderTriggerKind !== "none"`; reading a boolean field here
 * silently skipped the guard for every deserialized artifact.
 */
function crossStageDependencyIssues(hooks: readonly unknown[]): readonly string[] {
  interface KeyState {
    stageId: string;
    triggerOnly: boolean;
  }
  const issues: string[] = [];
  const keyState = new Map<string, KeyState>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      typeof hook.hookId !== "string" ||
      typeof hook.stageId !== "string" ||
      typeof hook.orderTriggerKind !== "string" ||
      !Array.isArray(hook.dependencies)
    ) {
      continue;
    }
    const isOrderTrigger = hook.orderTriggerKind !== "none";
    for (const dependency of hook.dependencies) {
      if (!isOnchainHookDependency(dependency)) {
        continue;
      }
      const seen = keyState.get(dependency.signalKey);
      if (seen === undefined) {
        keyState.set(dependency.signalKey, { stageId: hook.stageId, triggerOnly: isOrderTrigger });
        continue;
      }
      const triggerOnly = seen.triggerOnly && isOrderTrigger;
      if (seen.stageId !== hook.stageId && !triggerOnly) {
        issues.push(
          `dependency ${dependency.signalKey} is shared across stages ${[seen.stageId, hook.stageId]
            .sort((left, right) => compareByCodeUnit(left, right))
            .join(", ")} with a non-trigger watcher after a foreign stage; `
          + "an unmaterialized stage's non-trigger hook would make the "
          + "submitting transaction revert forever",
        );
      }
      seen.triggerOnly = triggerOnly;
    }
  }
  return issues;
}

function validateOnchainDependencyIndex(
  hooks: readonly unknown[],
  dependencyIndex: Record<string, readonly string[]>,
): readonly string[] {
  const issues: string[] = [];
  // Recompute in compiledHooks (= calldata) order, exactly like
  // buildOnchainDependencyIndex and UVPStateMachine._registerPlanHook.
  const recomputed = new Map<string, string[]>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      typeof hook.hookId !== "string" ||
      !Array.isArray(hook.dependencies)
    ) {
      continue;
    }
    for (const dependency of hook.dependencies) {
      if (!isOnchainHookDependency(dependency)) {
        continue;
      }
      const hookIds = recomputed.get(dependency.signalKey) ?? [];
      if (!hookIds.includes(hook.hookId)) {
        hookIds.push(hook.hookId);
      }
      recomputed.set(dependency.signalKey, hookIds);
    }
  }

  issues.push(...crossStageDependencyIssues(hooks));

  const expected = Object.fromEntries(
    [...recomputed.entries()]
      .sort(([left], [right]) => compareByCodeUnit(left, right))
      .map(([signalKey, hookIds]) => [signalKey, hookIds]),
  );
  if (JSON.stringify(expected) !== JSON.stringify(dependencyIndex)) {
    issues.push("dependencyIndex must match on-chain hook dependencies");
  }
  return issues;
}

function validateOnchainExecutorRoutes(
  routes: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const routeIds = new Set<string>();
  for (const [index, route] of routes.entries()) {
    if (!isRecord(route)) {
      issues.push(`executorRoutes[${index}] must be an object`);
      continue;
    }

    const prefix = `executorRoutes[${index}]`;
    expectHexHash(route.routeId, `${prefix}.routeId`, issues);
    expectHexHash(route.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(
      route.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectNonEmptyString(route.executorType, `${prefix}.executorType`, issues);
    expectString(route.executorId, `${prefix}.executorId`, issues);
    expectHexHash(route.executorHash, `${prefix}.executorHash`, issues);
    expectHexHash(route.resourcesHash, `${prefix}.resourcesHash`, issues);
    expectHexHash(route.routeHash, `${prefix}.routeHash`, issues);
    if (
      typeof route.routeHash === "string" &&
      typeof route.stageId === "string" &&
      typeof route.stageIdentifier === "string" &&
      typeof route.executorHash === "string" &&
      typeof route.resourcesHash === "string"
    ) {
      const recomputedRouteHash = routeHashFromDigests(
        route.stageId as HexString,
        route.stageIdentifier,
        route.executorHash as HexString,
        route.resourcesHash as HexString,
      );
      if (route.routeHash !== recomputedRouteHash) {
        issues.push(`${prefix}.routeHash must match the committed content digests`);
      }
    }
    if (
      typeof route.stageIdentifier === "string" &&
      typeof route.stageId === "string" &&
      route.stageId !== onchainStageId(route.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (
      typeof route.stageIdentifier === "string" &&
      typeof route.routeId === "string" &&
      route.routeId !== onchainRouteId(route.stageIdentifier)
    ) {
      issues.push(
        `${prefix}.routeId must be keccak256(stageIdentifier#executorRoute)`,
      );
    }
    if (typeof route.routeId === "string") {
      if (routeIds.has(route.routeId)) {
        issues.push(`duplicate routeId ${route.routeId}`);
      }
      routeIds.add(route.routeId);
    }
  }
  return issues;
}

function validateOnchainSelectorBindings(
  bindings: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  for (const [index, binding] of bindings.entries()) {
    if (!isRecord(binding)) {
      issues.push(`selectorBindings[${index}] must be an object`);
      continue;
    }

    const prefix = `selectorBindings[${index}]`;
    expectNonEmptyString(
      binding.selectorStageIdentifier,
      `${prefix}.selectorStageIdentifier`,
      issues,
    );
    expectNonEmptyString(
      binding.targetStageIdentifier,
      `${prefix}.targetStageIdentifier`,
      issues,
    );
    expectHexHash(binding.selectorStageId, `${prefix}.selectorStageId`, issues);
    expectHexHash(binding.targetStageId, `${prefix}.targetStageId`, issues);
    expectHexHash(binding.bindingHash, `${prefix}.bindingHash`, issues);

    if (
      typeof binding.selectorStageIdentifier === "string" &&
      typeof binding.selectorStageId === "string" &&
      binding.selectorStageId !==
        onchainStageId(binding.selectorStageIdentifier)
    ) {
      issues.push(
        `${prefix}.selectorStageId must be keccak256(selectorStageIdentifier)`,
      );
    }
    if (
      typeof binding.targetStageIdentifier === "string" &&
      typeof binding.targetStageId === "string" &&
      binding.targetStageId !== onchainStageId(binding.targetStageIdentifier)
    ) {
      issues.push(
        `${prefix}.targetStageId must be keccak256(targetStageIdentifier)`,
      );
    }
    if (
      isHexHash(binding.selectorStageId) &&
      isHexHash(binding.targetStageId) &&
      binding.bindingHash !==
        onchainSelectorBindingHash(
          binding.selectorStageId,
          binding.targetStageId,
        )
    ) {
      issues.push(
        `${prefix}.bindingHash must match selectorStageId and targetStageId`,
      );
    }

    if (
      isHexHash(binding.selectorStageId) &&
      isHexHash(binding.targetStageId)
    ) {
      const key = selectorBindingKey(
        binding.selectorStageId,
        binding.targetStageId,
      );
      if (seen.has(key)) {
        issues.push(`duplicate selector binding ${key}`);
      }
      seen.add(key);
    }
  }
  return issues;
}

function validateOnchainSignalCapabilities(
  capabilities: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  for (const [index, capability] of capabilities.entries()) {
    if (!isRecord(capability)) {
      issues.push(`signalCapabilities[${index}] must be an object`);
      continue;
    }
    const prefix = `signalCapabilities[${index}]`;
    expectNonEmptyString(
      capability.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectHexHash(capability.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(capability.source, `${prefix}.source`, issues);
    expectNonEmptyString(
      capability.declaredSignal,
      `${prefix}.declaredSignal`,
      issues,
    );
    expectNonEmptyString(
      capability.targetSource,
      `${prefix}.targetSource`,
      issues,
    );
    expectHexHash(
      capability.targetSourceId,
      `${prefix}.targetSourceId`,
      issues,
    );
    expectNonEmptyString(
      capability.targetSignalName,
      `${prefix}.targetSignalName`,
      issues,
    );
    expectHexHash(capability.signalId, `${prefix}.signalId`, issues);
    expectOneOf(
      capability.targetOrderRelation,
      ["current", "triggerOrigin"],
      `${prefix}.targetOrderRelation`,
      issues,
    );
    expectHexHash(
      capability.capabilityHash,
      `${prefix}.capabilityHash`,
      issues,
    );

    if (
      typeof capability.stageIdentifier === "string" &&
      typeof capability.stageId === "string" &&
      capability.stageId !== onchainStageId(capability.stageIdentifier)
    ) {
      issues.push(`${prefix}.stageId must be keccak256(stageIdentifier)`);
    }
    if (
      typeof capability.targetSource === "string" &&
      typeof capability.targetSourceId === "string" &&
      capability.targetSourceId !== onchainSourceId(capability.targetSource)
    ) {
      issues.push(`${prefix}.targetSourceId must be keccak256(targetSource)`);
    }
    if (
      typeof capability.targetSignalName === "string" &&
      typeof capability.signalId === "string" &&
      capability.signalId !== onchainSignalId(capability.targetSignalName)
    ) {
      issues.push(`${prefix}.signalId must be keccak256(targetSignalName)`);
    }
    if (
      isHexHash(capability.stageId) &&
      isHexHash(capability.targetSourceId) &&
      isHexHash(capability.signalId) &&
      (capability.targetOrderRelation === "current" ||
        capability.targetOrderRelation === "triggerOrigin")
    ) {
      const expectedHash = onchainSignalCapabilityHash(
        capability.stageId,
        capability.targetSourceId,
        capability.signalId,
        capability.targetOrderRelation,
      );
      if (capability.capabilityHash !== expectedHash) {
        issues.push(`${prefix}.capabilityHash must match capability fields`);
      }
      const key = [
        capability.stageId,
        capability.targetSourceId,
        capability.signalId,
        capability.targetOrderRelation,
      ].join("\u0000");
      if (seen.has(key)) {
        issues.push(`duplicate signal capability ${key}`);
      }
      seen.add(key);
    }
  }
  return issues;
}

function isOnchainHookDependency(
  value: unknown,
): value is OnchainHookDependency {
  return (
    isRecord(value) &&
    (value.kind === "positive" ||
      value.kind === "negative" ||
      value.kind === "timer") &&
    typeof value.source === "string" &&
    typeof value.signalName === "string" &&
    isHexHash(value.sourceId) &&
    isHexHash(value.signalId) &&
    isHexHash(value.signalKey)
  );
}

function isPlanHashRecomputable(
  value: Record<string, unknown>,
): value is Omit<OnchainHookPlanArtifact, "planHash"> & {
  readonly planHash: HexString;
} {
  // dock 字段必须全部在场且形状合法才允许重算 planHash：缺失的
  // dockRoutesRoot 会让 canonicalize 抛未类型化 TypeError（破坏"返回
  // issues"契约），缺失的 dockRoutes/dockInterface 落进 ?? 兜底则把
  // 缺失钉成 []/null 后照常通过（fail-open）。两者都改为收集为 issue。
  return (
    value.schemaVersion === ONCHAIN_HOOK_PLAN_SCHEMA_VERSION &&
    isHexHash(value.planId) &&
    typeof value.zhixuId === "string" &&
    typeof value.zhixuName === "string" &&
    isPlatform(value.platform) &&
    isHexHash(value.sourcePlanHash) &&
    Array.isArray(value.compiledHooks) &&
    isHexArrayRecord(value.dependencyIndex) &&
    Array.isArray(value.executorRoutes) &&
    Array.isArray(value.selectorBindings) &&
    Array.isArray(value.signalCapabilities) &&
    Array.isArray(value.dockRoutes) &&
    (value.dockInterface === null || isRecord(value.dockInterface)) &&
    isHexHash(value.dockRoutesRoot) &&
    isHexHash(value.dockInterfaceRoot) &&
    isHexHash(value.planHash)
  );
}

function compareOnchainHooks(
  left: OnchainCompiledHook,
  right: OnchainCompiledHook,
): number {
  return (
    compareByCodeUnit(left.stageIdentifier, right.stageIdentifier) ||
    compareByCodeUnit(left.hookName, right.hookName) ||
    compareByCodeUnit(left.hookId, right.hookId)
  );
}

/**
 * 制品边界的规范序检查：键列与编译侧排序比较子同源（compareOnchainHooks
 * 等），相邻逆序即报 issue——重排数组后重签 planHash 的制品不再被放行，
 * 同一 plan 保持唯一数组形态（内容寻址前提）。
 */
function canonicalOrderIssues(
  items: readonly unknown[],
  keyOf: (item: Record<string, unknown>) => readonly string[],
  label: string,
): readonly string[] {
  const issues: string[] = [];
  let previous: readonly string[] | undefined;
  for (const [index, item] of items.entries()) {
    if (!isRecord(item)) {
      continue;
    }
    const key = keyOf(item);
    if (previous !== undefined) {
      let diverged = false;
      for (let position = 0; position < previous.length; position += 1) {
        const order = compareByCodeUnit(
          previous[position] as string,
          key[position] as string,
        );
        if (order > 0) {
          diverged = true;
          break;
        }
        if (order < 0) {
          break;
        }
      }
      if (diverged) {
        issues.push(
          `${label}[${index}] breaks the canonical order (${key.join(" < ")} must not precede ${(previous as readonly string[]).join(" < ")}); re-sort with the compiler's ordering before serializing`,
        );
      }
    }
    previous = key;
  }
  return issues;
}

function hookOrderKey(hook: Record<string, unknown>): readonly string[] {
  return [String(hook.stageIdentifier), String(hook.hookName), String(hook.hookId)];
}

function routeOrderKey(route: Record<string, unknown>): readonly string[] {
  return [String(route.stageIdentifier), String(route.routeId)];
}

function selectorBindingOrderKey(
  binding: Record<string, unknown>,
): readonly string[] {
  return [String(binding.selectorStageId), String(binding.targetStageId), String(binding.bindingHash)];
}

function signalCapabilityOrderKey(
  capability: Record<string, unknown>,
): readonly string[] {
  return [
    String(capability.stageId),
    String(capability.targetSourceId),
    String(capability.signalId),
    String(capability.targetOrderRelation),
    String(capability.capabilityHash),
  ];
}

function compareExecutorRoutes(
  left: OnchainExecutorRoute,
  right: OnchainExecutorRoute,
): number {
  return (
    compareByCodeUnit(left.stageIdentifier, right.stageIdentifier) ||
    compareByCodeUnit(left.routeId, right.routeId)
  );
}

function compareSelectorBindings(
  left: OnchainStageSelectorBinding,
  right: OnchainStageSelectorBinding,
): number {
  return (
    compareByCodeUnit(left.selectorStageId, right.selectorStageId) ||
    compareByCodeUnit(left.targetStageId, right.targetStageId) ||
    compareByCodeUnit(left.bindingHash, right.bindingHash)
  );
}

function compareSignalCapabilities(
  left: OnchainSignalCapability,
  right: OnchainSignalCapability,
): number {
  return (
    compareByCodeUnit(left.stageId, right.stageId) ||
    compareByCodeUnit(left.targetSourceId, right.targetSourceId) ||
    compareByCodeUnit(left.signalId, right.signalId) ||
    compareByCodeUnit(left.targetOrderRelation, right.targetOrderRelation) ||
    compareByCodeUnit(left.capabilityHash, right.capabilityHash)
  );
}

function selectorBindingKey(
  selectorStageId: HexString,
  targetStageId: HexString,
): string {
  return `${selectorStageId}->${targetStageId}`;
}

function uniqueSorted(values: readonly HexString[]): readonly HexString[] {
  return [...new Set(values)].sort();
}

function concatHex32(left: HexString, right: HexString): Uint8Array {
  if (!isHexHash(left) || !isHexHash(right)) {
    throw new Error("signal key inputs must be 32-byte hex hashes");
  }
  const bytes = new Uint8Array(64);
  bytes.set(hexToBytes32(left), 0);
  bytes.set(hexToBytes32(right), 32);
  return bytes;
}

function hexToBytes32(value: HexString): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < 32; index += 1) {
    bytes[index] = Number.parseInt(
      value.slice(2 + index * 2, 4 + index * 2),
      16,
    );
  }
  return bytes;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isHexHash(value: unknown): value is HexString {
  return typeof value === "string" && /^0x[0-9a-f]{64}$/.test(value);
}

function isHexArrayRecord(
  value: unknown,
): value is Record<HexString, readonly HexString[]> {
  if (!isRecord(value)) {
    return false;
  }
  return Object.entries(value).every(
    ([key, item]) =>
      isHexHash(key) &&
      Array.isArray(item) &&
      item.every((entry) => isHexHash(entry)),
  );
}

function isPlatform(value: unknown): value is ZhixuPlatform {
  return (
    isRecord(value) &&
    typeof value.type === "string" &&
    value.type.trim().length > 0 &&
    (value.provider === undefined || typeof value.provider === "string") &&
    (value.network === undefined || typeof value.network === "string") &&
    (value.version === undefined || typeof value.version === "string") &&
    (value.params === undefined ||
      (isRecord(value.params) &&
        Object.values(value.params).every((item) => typeof item === "string")))
  );
}

function expectLiteral(
  value: unknown,
  expected: string,
  fieldName: string,
  issues: string[],
): void {
  if (value !== expected) {
    issues.push(`${fieldName} must be ${expected}`);
  }
}

function expectHexHash(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (!isHexHash(value)) {
    issues.push(`${fieldName} must be a lowercase 32-byte hex hash`);
  }
}

function expectNonEmptyString(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string" || value.trim().length === 0) {
    issues.push(`${fieldName} must be a non-empty string`);
  }
}

function expectString(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string") {
    issues.push(`${fieldName} must be a string`);
  }
}

function expectBoolean(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "boolean") {
    issues.push(`${fieldName} must be a boolean`);
  }
}

function expectOneOf(
  value: unknown,
  allowed: readonly string[],
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string" || !allowed.includes(value)) {
    issues.push(`${fieldName} must be one of ${allowed.join(", ")}`);
  }
}

function assertNever(value: never): never {
  throw new Error(
    `unsupported on-chain HookPlan node: ${JSON.stringify(value)}`,
  );
}
