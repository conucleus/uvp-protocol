import { validateDockCommitments, validateUnresolvedDockRouteDeclarations } from "../../dock-validation.js";
import { planIdOf } from "../../dock-commitments.js";
import { hashOnchainPlanPayload } from "../hash/plan.js";
import { capabilitiesRootOf } from "../capabilities-root.js";
import {
  canonicalOrderIssues,
  admissionOrderKey,
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
  birthStageStaticExecutorIssues,
  declaredStageIdentifiers,
  duplicateBirthChannelKeyIssues,
  silentOrderTriggerIssues,
  unmaterializableStageIssues,
  validateOnchainCompiledAdmissions,
  validateOnchainCompiledHooks,
  validateOnchainDependencyIndex,
} from "./hooks.js";
import {
  planDependencyCountIssues,
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
  "unresolvedDockRoutes",
  "dockRoutesRoot",
  "dockInterfaceRoot",
  "capabilitiesRoot",
  "selectorBindings",
  "signalCapabilities",
  "admissions",
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
  // 姊妹边界 hook-plan.ts 同口径：planId 从携带字段独立重推导（planIdOf
  // 单点做空 params 归一，Rust 权威口径）——制品携带全部 preimage 字段
  // （zhixuId/zhixuName/platform），planId 钉值与公式分叉必须在本边界
  // 拒绝，不留"IR 边界拒、onchain 边界放"的双侧口径差。重算抛错
  // （platform 携带非 JSON 值）按 issue 报告，校验器的契约是返回
  // issues 而非抛裸 TypeError。
  if (
    isPlatform(value.platform) &&
    typeof value.zhixuId === "string" &&
    typeof value.zhixuName === "string"
  ) {
    try {
      const recomputedPlanId = planIdOf(
        value.zhixuId,
        value.zhixuName,
        value.platform,
      );
      if (typeof value.planId === "string" && value.planId !== recomputedPlanId) {
        issues.push(
          "planId must match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName)",
        );
      }
    } catch {
      issues.push(
        "planId preimage is not canonicalizable (platform carries non-JSON values)",
      );
    }
  }
  // 姊妹边界 hook-plan.ts 同口径：dock 字段缺失/畸形必须在形状层报 issue，
  // 而不是落进 planHash 重算的 ?? 兜底或 canonicalize 的未类型化
  // TypeError（fail-open：缺失被钉成 []/null 后哈希仍可通过）。
  if (!Array.isArray(value.dockRoutes)) {
    issues.push("dockRoutes must be an array");
  }
  // 动态路由声明面与 dockRoutes 同口径：在场而非数组必须显式报 issue，
  // 不得静默跳过形状与承诺校验。
  if (
    value.unresolvedDockRoutes !== undefined &&
    !Array.isArray(value.unresolvedDockRoutes)
  ) {
    issues.push("unresolvedDockRoutes must be an array when present");
  }
  expectHexHash(value.dockRoutesRoot, "dockRoutesRoot", issues);
  expectHexHash(value.dockInterfaceRoot, "dockInterfaceRoot", issues);
  expectHexHash(value.capabilitiesRoot, "capabilitiesRoot", issues);
  issues.push(...validateDockCommitments(value));
  issues.push(...capabilitiesRootCommitmentIssues(value));
  if (Array.isArray(value.dockRoutes)) {
    issues.push(...onchainDockTrackIssues(value.dockRoutes));
  }
  // 动态路由声明面（仅非空时在场）：形状与 hook plan IR 共用单点实现，
  // 本地承诺（routeId/candidatesRoot/routeHash + dockRoutesRoot 合树）由
  // validateDockCommitments 重算，链轨接受域（mode）由下方门把关。
  if (Array.isArray(value.unresolvedDockRoutes)) {
    issues.push(
      ...validateUnresolvedDockRouteDeclarations(
        value.unresolvedDockRoutes,
        "unresolvedDockRoutes",
      ),
      ...onchainUnresolvedRouteIssues(value.unresolvedDockRoutes),
    );
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
  // 适格面（与 IR 同约定：core 恒产数组，可为空）：在场而非数组必须显式
  // 报 issue——缺失的 admissions 折成空集后哈希照常通过，未声明面与
  // 空适格面在承诺上不可区分是 fail-open。
  const admissions = Array.isArray(value.admissions)
    ? value.admissions
    : undefined;
  if (!admissions) {
    issues.push("admissions must be an array");
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
    // 订阅/出生阶段静态执行者镜像（Rust validate_stage_executors 第二道）：
    // mint 出生阶段的投递目标编译期定死，selectorBindings 可达不豁免。
    issues.push(
      ...birthStageStaticExecutorIssues(compiledHooks, executorRoutes ?? []),
    );
    // U2 同一守卫同样作用于反序列化 artifact 边界。
    issues.push(...duplicateBirthChannelKeyIssues(compiledHooks));
    issues.push(...planDependencyCountIssues(compiledHooks as readonly OnchainCompiledHook[]));
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
                },
              ]
            : [],
        ),
      ),
    );
  }
  if (admissions) {
    // 过滤档镜像门同样作用于反序列化 artifact 边界（与 hook 族同纪律）。
    issues.push(...validateOnchainCompiledAdmissions(admissions));
    issues.push(
      ...canonicalOrderIssues(admissions, admissionOrderKey, "admissions"),
    );
  }

  if (isPlanHashRecomputable(value)) {
    // 姊妹实现 hook-plan.ts 同口径：重算抛错（负载深层携带 undefined/非
    // JSON 值）按 issue 报告，校验器的契约是返回 issues 而非抛裸 TypeError。
    // 动态路由声明面与 IR 同约定：仅非空时入哈希（空数组/缺失不落键）。
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
        ...(Array.isArray(value.unresolvedDockRoutes) &&
        value.unresolvedDockRoutes.length > 0
          ? { unresolvedDockRoutes: value.unresolvedDockRoutes }
          : {}),
        dockRoutesRoot: value.dockRoutesRoot,
        dockInterfaceRoot: value.dockInterfaceRoot,
        capabilitiesRoot: value.capabilitiesRoot,
        selectorBindings: value.selectorBindings,
        signalCapabilities: value.signalCapabilities,
        admissions: value.admissions,
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
 * 链轨 dock route 门（静态路由，UVPDockingModule 4.4 接受域）：
 * - `orderMode: "existing"`：4.4 起链轨承接（attachDockedOrder 对等挂接，
 *   不铸子单）；modeWord=existing 进 routeHash/dockInstanceId 双 preimage，
 *   与 new 不可互冒——不再拒绝，产物原样承载。
 * - new 模式恰一条 input 绑定（Rust D010 / 合约 DockBindingCountInvalid
 *   镜像）：出生锚必须唯一确定，inputBindings 数 ≠1 在两个边界同口径拒绝。
 * - 静态路由必须携带静态 target 块：动态（target:null）路由的唯一承载面
 *   是 unresolvedDockRoutes（其叶已随 dockRoutesRoot 冻结），塞进
 *   dockRoutes 的空 target 是形态走私。
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
        `dock route ${stageIdentifier} has no statically linked target block; ` +
          "a dynamic (null) route must be carried in unresolvedDockRoutes (its route leaf is already frozen into dockRoutesRoot via the candidate-root target slot), never in dockRoutes",
      );
    }
  }
  return issues;
}

/**
 * 能力树承诺重算（与 validateDockCommitments 同纪律）：登记边界
 * （toSolidityRegisterPlanArgs）按两表重算 capabilitiesRoot——artifact
 * 自带的 root 若与两表不一致，调用方重签 planHash 后仍能过本地校验，
 * 登记时被静默覆盖成重算值，制品承诺与链上注册根就此分叉。必须在
 * artifact 边界响亮拒绝。表项形状非法时跳过重算——形状 issue 由
 * validateOnchainSelectorBindings / validateOnchainSignalCapabilities 报告。
 */
function capabilitiesRootCommitmentIssues(
  value: Record<string, unknown>,
): readonly string[] {
  const selectorBindings = Array.isArray(value.selectorBindings)
    ? value.selectorBindings
    : undefined;
  const signalCapabilities = Array.isArray(value.signalCapabilities)
    ? value.signalCapabilities
    : undefined;
  if (
    !selectorBindings ||
    !signalCapabilities ||
    !isHexHash(value.capabilitiesRoot)
  ) {
    return [];
  }

  const bindings: {
    selectorStageId: HexString;
    targetStageId: HexString;
  }[] = [];
  for (const binding of selectorBindings) {
    if (
      isRecord(binding) &&
      isHexHash(binding.selectorStageId) &&
      isHexHash(binding.targetStageId)
    ) {
      bindings.push({
        selectorStageId: binding.selectorStageId,
        targetStageId: binding.targetStageId,
      });
    } else {
      return [];
    }
  }

  const capabilities: {
    stageId: HexString;
    targetSourceId: HexString;
    signalId: HexString;
    targetOrderRelation: 0 | 1;
  }[] = [];
  for (const capability of signalCapabilities) {
    if (
      isRecord(capability) &&
      isHexHash(capability.stageId) &&
      isHexHash(capability.targetSourceId) &&
      isHexHash(capability.signalId) &&
      capability.targetOrderRelation === "current"
    ) {
      capabilities.push({
        stageId: capability.stageId,
        targetSourceId: capability.targetSourceId,
        signalId: capability.signalId,
        targetOrderRelation: 0,
      });
    } else {
      return [];
    }
  }

  if (value.capabilitiesRoot !== capabilitiesRootOf(bindings, capabilities)) {
    return [
      "capabilitiesRoot must match the recomputed root over selector bindings and signal capabilities",
    ];
  }
  return [];
}

/**
 * 未解析 route（target:null 动态选择，§8.8 / UVPDockingModule 4.4）的链轨
 * 接受域门：动态路由整体承接（声明面随产物携带，routeHash 目标槽 = 候选
 * 集 root，随 dockRoutesRoot 在 finalize 冻结，attach 携 proof 选定），
 * 唯一保留的拒绝是 orderMode=new——合约终态没有 new 模式动态路由的消费
 * 方（openDockedOrder 只按静态目标槽重算 routeHash，无候选集回退；
 * attachDockedOrder——唯一的动态路径——钉 existing）。编译入口与反序列化
 * 边界共用本门。
 */
function onchainUnresolvedRouteIssues(
  routes: readonly unknown[] | undefined,
): readonly string[] {
  if (!Array.isArray(routes)) {
    return [];
  }
  const issues: string[] = [];
  for (const [index, route] of routes.entries()) {
    if (!isRecord(route) || route.orderMode !== "new") {
      continue;
    }
    const stageIdentifier =
      (typeof route.stageIdentifier === "string" && route.stageIdentifier) ||
      `unresolvedDockRoutes[${index}]`;
    issues.push(
      `UNRESOLVED_DOCK_MODE: unresolved dock route ${stageIdentifier} declares order mode "new"; ` +
        "the chain terminal state has no dynamic consumer for new-mode routes — " +
        'openDockedOrder recomputes the static target slot only and attachDockedOrder (the dynamic path) pins order mode "existing"',
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
    Array.isArray(value.admissions) &&
    Array.isArray(value.dockRoutes) &&
    (value.unresolvedDockRoutes === undefined ||
      Array.isArray(value.unresolvedDockRoutes)) &&
    (value.dockInterface === null || isRecord(value.dockInterface)) &&
    isHexHash(value.dockRoutesRoot) &&
    isHexHash(value.dockInterfaceRoot) &&
    isHexHash(value.capabilitiesRoot) &&
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
