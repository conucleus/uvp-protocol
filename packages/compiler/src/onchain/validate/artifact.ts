import { validateDockCommitments } from "../../dock-validation.js";
import { hashOnchainPlanPayload } from "../hash/plan.js";
import {
  canonicalOrderIssues,
  hookOrderKey,
  routeOrderKey,
  selectorBindingOrderKey,
  signalCapabilityOrderKey,
} from "../canonical/ordering.js";
import {
  expectHexHash,
  expectLiteral,
  expectNonEmptyString,
  isHexHash,
  isRecord,
} from "../shape.js";
import {
  duplicateCurrentOrderFactKeyIssues,
  validateOnchainExecutorRoutes,
  validateOnchainSelectorBindings,
  validateOnchainSignalCapabilities,
} from "./capabilities.js";
import {
  declaredStageIdentifiers,
  silentOrderTriggerIssues,
  unmaterializableStageIssues,
  validateOnchainCompiledHooks,
  validateOnchainDependencyIndex,
} from "./hooks.js";
import {
  planDependencyCountIssues,
  signalCapabilityCountIssues,
} from "./limits.js";
import {
  ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
  type HexString,
  type OnchainCompiledHook,
  type OnchainHookPlanArtifact,
  type ZhixuPlatform,
} from "../../types/index.js";

/**
 * OnchainHookPlanArtifact 反序列化边界校验（自 onchain-hook-plan.ts 原样
 * 迁入）：封闭字段集、逐段形状/承诺校验编排与 planHash 重算。dock 承诺
 * 复用根 dock-validation.ts，不复制 Dock 规则。
 */

export class OnchainHookPlanArtifactValidationError extends Error {
  readonly issues: readonly string[];

  constructor(issues: readonly string[]) {
    super(issues.join("; "));
    this.name = "OnchainHookPlanArtifactValidationError";
    this.issues = issues;
  }
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

export { onchainDockTrackIssues, onchainUnresolvedRouteIssues };
