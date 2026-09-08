import { compileWithUvpCore } from "@uvp-eth/hook-core";
import {
  HOOK_PLAN_SCHEMA_VERSION,
  type HookPlanArtifact,
  type ZhixuPlatform,
  type ZhixuDefinition,
  type DockResolutionManifest,
} from "./types/index.js";
import { validateDockCommitments } from "./dock-validation.js";
import { compareByCodePoint } from "./canonical.js";
import { hashCanonical } from "./hash.js";
import {
  assembleChainTrackHookPlan,
  hookPlanPayloadForHash,
  planIdOf,
  prepareDockResolution,
  HOOK_PLAN_HASH_DOMAIN,
  type HookPlanShell,
} from "./dock-commitments.js";

export class HookPlanCompilationError extends Error {
  readonly issues: readonly string[];

  constructor(issues: readonly string[]) {
    super(issues.join("; "));
    this.name = "HookPlanCompilationError";
    this.issues = issues;
  }
}

export class HookPlanArtifactValidationError extends Error {
  readonly issues: readonly string[];

  constructor(issues: readonly string[]) {
    super(issues.join("; "));
    this.name = "HookPlanArtifactValidationError";
    this.issues = issues;
  }
}

/**
 * Deterministic code-unit ordering. localeCompare is ICU/locale dependent and
 * must never participate in canonical artifact construction, which has to
 * reproduce byte-identically across environments (Rust side orders by bytes).
 */
export function compareByCodeUnit(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

/**
 * 编译入口：core 产出中性 plan 壳（hooks/依赖索引/中性 dock 声明），
 * 链轨承诺（uid/planId/roots/routeHash/planHash）由 TS 在壳上计算组装
 * （PRD100_102_DESIGN.md §5.2）。resolution manifest 是链轨发布面：TS
 * 先做内容寻址校验并派生 core linker 消费的中性 name 目录。
 */
export function compileZhixuHookPlan(
  definition: ZhixuDefinition,
  resolutionManifest?: DockResolutionManifest,
): HookPlanArtifact {
  const issues = validateZhixuShape(definition);
  if (issues.length > 0) {
    throw new HookPlanCompilationError(issues);
  }

  let resolution;
  if (resolutionManifest !== undefined) {
    try {
      resolution = prepareDockResolution(resolutionManifest);
    } catch (error) {
      throw new HookPlanCompilationError([
        error instanceof Error ? error.message : String(error)
      ]);
    }
  }

  let shell: unknown;
  try {
    shell = compileWithUvpCore({
      target: "hook_plan",
      definition,
      ...(resolution === undefined ? {} : { resolutionManifest: resolution.neutral }),
    });
  } catch (error) {
    throw new HookPlanCompilationError([
      error instanceof Error ? error.message : String(error)
    ]);
  }

  const artifact = assembleChainTrackHookPlan(
    definition,
    shell as HookPlanShell,
    resolution,
  );

  const artifactIssues = validateHookPlanArtifact(artifact);
  if (artifactIssues.length > 0) {
    throw new HookPlanArtifactValidationError(artifactIssues);
  }
  return artifact;
}

export function validateHookPlanArtifact(value: unknown): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value)) {
    return ["artifact must be an object"];
  }

  expectLiteral(value.schemaVersion, HOOK_PLAN_SCHEMA_VERSION, "schemaVersion", issues);
  expectHexHash(value.planId, "planId", issues);
  expectNonEmptyString(value.zhixuId, "zhixuId", issues);
  expectNonEmptyString(value.zhixuName, "zhixuName", issues);
  if (!isPlatform(value.platform)) {
    issues.push("platform must be an object with a non-empty type");
  }
  expectHexHash(value.planHash, "planHash", issues);

  // 承诺重算（对齐 onchain 侧 hashOnchainPlanPayload 的边界口径）：planId
  // 与 planHash 都从携带字段独立重推导——篡改 compiledHooks/source 后保留
  // 旧 planHash 的毒制品在此拒绝，不等到链上。重算抛错（负载携带非 JSON
  // 值）同样按 issue 报告，校验器的契约是返回 issues 而非抛出。
  if (isPlatform(value.platform) && typeof value.zhixuId === "string" && typeof value.zhixuName === "string") {
    try {
      const recomputedPlanId = planIdOf(value.zhixuId, value.zhixuName, value.platform);
      if (typeof value.planId === "string" && value.planId !== recomputedPlanId) {
        issues.push(
          "planId must match the recomputed H(uvp:hook-plan-id:v1; compiler/platform/zhixuId/zhixuName)",
        );
      }
    } catch {
      issues.push("planId preimage is not canonicalizable (platform carries non-JSON values)");
    }
  }
  if (value.source === undefined) {
    issues.push(
      "source is required (the canonical annotation-stripped definition snapshot in the planHash preimage)",
    );
  } else if (typeof value.planHash === "string" && /^0x[0-9a-f]{64}$/.test(value.planHash)) {
    try {
      const recomputedPlanHash = hashCanonical(
        HOOK_PLAN_HASH_DOMAIN,
        hookPlanPayloadForHash(value as Omit<HookPlanArtifact, "planHash">),
      );
      if (value.planHash !== recomputedPlanHash) {
        issues.push(
          "planHash must match the recomputed H(uvp:hook-plan-artifact:v1; payload) over the carried fields",
        );
      }
    } catch {
      issues.push(
        "planHash preimage is not canonicalizable (payload carries undefined or non-JSON values)",
      );
    }
  }

  const compiledHooks = Array.isArray(value.compiledHooks) ? value.compiledHooks : undefined;
  if (!compiledHooks) {
    issues.push("compiledHooks must be an array");
  }
  const dependencyIndex = isStringArrayRecord(value.dependencyIndex) ? value.dependencyIndex : undefined;
  if (!dependencyIndex) {
    issues.push("dependencyIndex must be a record of string arrays");
  }
  if (!isRecord(value.executorRoutes)) {
    issues.push("executorRoutes must be an object");
  }
  if (!Array.isArray(value.dockRoutes)) {
    issues.push("dockRoutes must be an array");
  }
  if (value.unresolvedDockRoutes !== undefined) {
    issues.push(...validateUnresolvedDockRoutes(value.unresolvedDockRoutes));
  }
  expectHexHash(value.dockRoutesRoot as unknown, "dockRoutesRoot", issues);
  expectHexHash(value.dockInterfaceRoot as unknown, "dockInterfaceRoot", issues);
  issues.push(...validateDockCommitments(value));
  if (!Array.isArray(value.selectedStageBindings)) {
    issues.push("selectedStageBindings must be an array");
  }
  if (!Array.isArray(value.signalCapabilities)) {
    issues.push("signalCapabilities must be an array");
  }

  if (compiledHooks) {
    issues.push(...validateCompiledHooks(compiledHooks));
    if (dependencyIndex) {
      issues.push(...validateDependencyIndex(compiledHooks, dependencyIndex));
    }
  }

  if (isRecord(value.executorRoutes)) {
    for (const [routeKey, route] of Object.entries(value.executorRoutes)) {
      if (!isRecord(route)) {
        issues.push(`executorRoutes.${routeKey} must be an object`);
        continue;
      }
      if (route.stageIdentifier !== routeKey) {
        issues.push(`executorRoutes.${routeKey}.stageIdentifier must equal ${routeKey}`);
      }
      if (!isRecord(route.executor)) {
        issues.push(`executorRoutes.${routeKey}.executor must be an object`);
      }
    }
  }

  if (Array.isArray(value.selectedStageBindings)) {
    for (const [index, binding] of value.selectedStageBindings.entries()) {
      if (!isRecord(binding)) {
        issues.push(`selectedStageBindings[${index}] must be an object`);
        continue;
      }
      expectNonEmptyString(binding.selectorStageIdentifier, `selectedStageBindings[${index}].selectorStageIdentifier`, issues);
      expectNonEmptyString(binding.targetStageIdentifier, `selectedStageBindings[${index}].targetStageIdentifier`, issues);
    }
  }
  if (Array.isArray(value.signalCapabilities)) {
    issues.push(...validateSignalCapabilities(value.signalCapabilities));
  }

  return issues;
}

export function assertHookPlanArtifact(value: unknown): asserts value is HookPlanArtifact {
  const issues = validateHookPlanArtifact(value);
  if (issues.length > 0) {
    throw new HookPlanArtifactValidationError(issues);
  }
}

// 端口名形态（与 Rust valid_port_name 同规则）：^[a-z][a-z0-9_]{0,31}$。
function isPortName(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[a-z][a-z0-9_]{0,31}$/.test(value)
  );
}

/**
 * 未解析 route 声明面（§8.8）逐元素校验：mode 枚举、端口名形态、至少一
 * 条映射（D019 镜像）与基础身份字段。承诺字段不得在场——未解析 route 无
 * 哈希可承诺，出现即毒产物。
 */
function validateUnresolvedDockRoutes(
  routes: unknown,
): readonly string[] {
  const issues: string[] = [];
  if (!Array.isArray(routes)) {
    return ["unresolvedDockRoutes must be an array when present"];
  }
  for (const [index, route] of routes.entries()) {
    const prefix = `unresolvedDockRoutes[${index}]`;
    if (!isRecord(route)) {
      issues.push(`${prefix} must be an object`);
      continue;
    }
    expectLiteral(
      route.schemaVersion,
      "uvp.dockRoute.unresolved.v1",
      `${prefix}.schemaVersion`,
      issues,
    );
    expectNonEmptyString(route.stageIdentifier, `${prefix}.stageIdentifier`, issues);
    expectHexHash(route.stageId, `${prefix}.stageId`, issues);
    expectHexHash(route.localDefinitionRefHash, `${prefix}.localDefinitionRefHash`, issues);
    expectHexHash(route.localPlanId, `${prefix}.localPlanId`, issues);
    expectNonEmptyString(route.localSource, `${prefix}.localSource`, issues);
    expectNonEmptyString(route.interfaceName, `${prefix}.interfaceName`, issues);
    expectOneOf(route.orderMode, ["new", "existing"], `${prefix}.orderMode`, issues);
    for (const absent of ["routeId", "routeHash", "target", "sourceSeam"]) {
      if (route[absent] !== undefined) {
        issues.push(`${prefix}.${absent} must not be present on an unresolved route`);
      }
    }

    const inputs = Array.isArray(route.inputBindings) ? route.inputBindings : undefined;
    const outputs = Array.isArray(route.outputBindings) ? route.outputBindings : undefined;
    if (!inputs) {
      issues.push(`${prefix}.inputBindings must be an array`);
    }
    if (!outputs) {
      issues.push(`${prefix}.outputBindings must be an array`);
    }
    if (inputs) {
      for (const [bindingIndex, binding] of inputs.entries()) {
        const bindingPath = `${prefix}.inputBindings[${bindingIndex}]`;
        if (!isRecord(binding)) {
          issues.push(`${bindingPath} must be an object`);
          continue;
        }
        if (typeof binding.hookId !== "string" || !binding.hookId.includes("#")) {
          issues.push(`${bindingPath}.hookId must be a full hook identifier <task>.<stage>#<channel>`);
        }
        if (!isPortName(binding.port)) {
          issues.push(`${bindingPath}.port must match ^[a-z][a-z0-9_]{0,31}$`);
        }
      }
    }
    if (outputs) {
      for (const [bindingIndex, binding] of outputs.entries()) {
        const bindingPath = `${prefix}.outputBindings[${bindingIndex}]`;
        if (!isRecord(binding)) {
          issues.push(`${bindingPath} must be an object`);
          continue;
        }
        expectNonEmptyString(binding.signal, `${bindingPath}.signal`, issues);
        if (!isPortName(binding.port)) {
          issues.push(`${bindingPath}.port must match ^[a-z][a-z0-9_]{0,31}$`);
        }
      }
    }
    // D019 镜像：route 至少声明一项输入或输出映射。
    if (inputs !== undefined && outputs !== undefined && inputs.length + outputs.length === 0) {
      issues.push(
        `${prefix} must declare at least one input or output binding (a route maps an input or an output)`,
      );
    }
  }
  return issues;
}

function validateCompiledHooks(hooks: readonly unknown[]): readonly string[] {
  const issues: string[] = [];
  const hookIds = new Set<string>();
  for (const [index, hook] of hooks.entries()) {
    if (!isRecord(hook)) {
      issues.push(`compiledHooks[${index}] must be an object`);
      continue;
    }
    const prefix = `compiledHooks[${index}]`;
    expectNonEmptyString(hook.hookId, `${prefix}.hookId`, issues);
    expectOneOf(hook.kind, ["receive"], `${prefix}.kind`, issues);
    expectNonEmptyString(hook.stageIdentifier, `${prefix}.stageIdentifier`, issues);
    expectNonEmptyString(hook.hookName, `${prefix}.hookName`, issues);
    expectOneOf(
      hook.orderTriggerKind,
      ["none", "mint", "dock"],
      `${prefix}.orderTriggerKind`,
      issues,
    );
    expectBoolean(hook.emitReady, `${prefix}.emitReady`, issues);
    expectNonEmptyString(hook.rawExpression, `${prefix}.rawExpression`, issues);
    expectNonEmptyString(hook.normalizedExpression, `${prefix}.normalizedExpression`, issues);
    if (!isRecord(hook.ast)) {
      issues.push(`${prefix}.ast must be an object`);
    }
    if (!Array.isArray(hook.dependencies)) {
      issues.push(`${prefix}.dependencies must be an array`);
    } else {
      issues.push(...validateDependencies(hook.dependencies, `${prefix}.dependencies`));
    }
    if (typeof hook.hookId === "string") {
      if (hookIds.has(hook.hookId)) {
        issues.push(`duplicate hookId ${hook.hookId}`);
      }
      hookIds.add(hook.hookId);
    }
    if (
      typeof hook.stageIdentifier === "string" &&
      typeof hook.hookName === "string" &&
      typeof hook.hookId === "string" &&
      hook.hookId !== `${hook.stageIdentifier}#${hook.hookName}`
    ) {
      issues.push(`${prefix}.hookId must equal stageIdentifier#hookName`);
    }
    if (hook.route !== undefined) {
      if (!isRecord(hook.route)) {
        issues.push(`${prefix}.route must be an object`);
      } else if (hook.route.stageIdentifier !== hook.stageIdentifier) {
        issues.push(`${prefix}.route.stageIdentifier must equal hook stageIdentifier`);
      }
    }
  }
  return issues;
}

function validateDependencies(dependencies: readonly unknown[], path: string): readonly string[] {
  const issues: string[] = [];
  for (const [index, dependency] of dependencies.entries()) {
    if (!isRecord(dependency)) {
      issues.push(`${path}[${index}] must be an object`);
      continue;
    }
    expectOneOf(dependency.kind, ["positive", "negative", "timer"], `${path}[${index}].kind`, issues);
    expectString(dependency.source, `${path}[${index}].source`, issues);
    expectNonEmptyString(dependency.signalName, `${path}[${index}].signalName`, issues);
    if (dependency.delaySeconds !== undefined) {
      // E12：delaySeconds 只要在场就必须是正安全整数（非数值/NaN 拒绝），
      // 不按 kind 静默放行。
      if (!Number.isSafeInteger(dependency.delaySeconds) || Number(dependency.delaySeconds) <= 0) {
        issues.push(`${path}[${index}].delaySeconds must be a positive safe integer when present`);
      }
    }
    if (
      dependency.kind === "timer" &&
      (typeof dependency.delaySeconds !== "number" ||
        !Number.isSafeInteger(dependency.delaySeconds) || Number(dependency.delaySeconds) <= 0)
    ) {
      issues.push(`${path}[${index}].delaySeconds must be a positive safe integer for timer dependencies`);
    }
  }
  return issues;
}

function validateSignalCapabilities(capabilities: readonly unknown[]): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  for (const [index, capability] of capabilities.entries()) {
    if (!isRecord(capability)) {
      issues.push(`signalCapabilities[${index}] must be an object`);
      continue;
    }
    const prefix = `signalCapabilities[${index}]`;
    expectNonEmptyString(capability.stageIdentifier, `${prefix}.stageIdentifier`, issues);
    expectNonEmptyString(capability.source, `${prefix}.source`, issues);
    expectNonEmptyString(capability.declaredSignal, `${prefix}.declaredSignal`, issues);
    expectNonEmptyString(capability.targetSource, `${prefix}.targetSource`, issues);
    expectNonEmptyString(capability.targetSignalName, `${prefix}.targetSignalName`, issues);
    expectOneOf(capability.targetOrderRelation, ["current", "triggerOrigin"], `${prefix}.targetOrderRelation`, issues);
    if (
      typeof capability.stageIdentifier === "string" &&
      typeof capability.targetSource === "string" &&
      typeof capability.targetSignalName === "string" &&
      typeof capability.targetOrderRelation === "string"
    ) {
      const key = [
        capability.stageIdentifier,
        capability.targetSource,
        capability.targetSignalName,
        capability.targetOrderRelation
      ].join("\u0000");
      if (seen.has(key)) {
        issues.push(`duplicate signal capability ${capability.stageIdentifier}:${capability.targetSource}::${capability.targetSignalName}`);
      }
      seen.add(key);
    }
  }
  return issues;
}

function validateDependencyIndex(
  hooks: readonly unknown[],
  dependencyIndex: Record<string, readonly string[]>
): readonly string[] {
  const issues: string[] = [];
  const recomputed = new Map<string, Set<string>>();
  for (const hook of hooks) {
    if (!isRecord(hook) || typeof hook.hookId !== "string" || !Array.isArray(hook.dependencies)) {
      continue;
    }
    for (const dependency of hook.dependencies) {
      if (!isHookDependency(dependency)) {
        continue;
      }
      const key = hookDependencyKey(dependency);
      const hookIds = recomputed.get(key) ?? new Set<string>();
      hookIds.add(hook.hookId);
      recomputed.set(key, hookIds);
    }
  }

  const expected = Object.fromEntries(
    [...recomputed.entries()]
      // Rust 权威是 BTreeMap<String, BTreeSet<String>>（字节序 = 码点序）；
      // 默认 .sort() 按 UTF-16 码元比较，会把星面字符（代理对）排到
      // U+E000..U+FFFF 的高 BMP 键之前，误拒合法 Rust 产物。
      .sort(([left], [right]) => compareByCodePoint(left, right))
      .map(([key, hookIds]) => [
        key,
        [...hookIds].sort(compareByCodePoint),
      ])
  );
  if (JSON.stringify(expected) !== JSON.stringify(dependencyIndex)) {
    issues.push("dependencyIndex must match compiled hook dependencies");
  }
  return issues;
}

interface HookDependencyLike {
  readonly source: string;
  readonly signalName: string;
}

function isHookDependency(value: unknown): value is HookDependencyLike {
  return (
    isRecord(value) &&
    (value.kind === "positive" || value.kind === "negative" || value.kind === "timer") &&
    typeof value.source === "string" &&
    typeof value.signalName === "string"
  );
}

function hookDependencyKey(dependency: HookDependencyLike): string {
  return `${dependency.source}::${dependency.signalName}`;
}

function validateZhixuShape(definition: ZhixuDefinition): readonly string[] {
  const issues: string[] = [];
  if (definition.apiVersion !== "uvp/v0") {
    issues.push("apiVersion must be uvp/v0");
  }
  if (definition.kind !== "Zhixu") {
    issues.push("kind must be Zhixu");
  }
  if (!definition.metadata?.name) {
    issues.push("metadata.name is required");
  }
  if (!isPlatform(definition.spec?.platform)) {
    issues.push("spec.platform must be an object with a non-empty type");
  }
  if (!definition.spec?.taskPatterns?.length) {
    issues.push("spec.taskPatterns must contain at least one task pattern");
  }
  return issues;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArrayRecord(value: unknown): value is Record<string, readonly string[]> {
  if (!isRecord(value)) {
    return false;
  }
  return Object.values(value).every(
    (item) => Array.isArray(item) && item.every((entry) => typeof entry === "string")
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
    (
      value.params === undefined ||
      (
        isRecord(value.params) &&
        Object.values(value.params).every((item) => typeof item === "string")
      )
    )
  );
}

function expectLiteral(
  value: unknown,
  expected: string,
  fieldName: string,
  issues: string[]
): void {
  if (value !== expected) {
    issues.push(`${fieldName} must be ${expected}`);
  }
}

function expectHexHash(value: unknown, fieldName: string, issues: string[]): void {
  if (typeof value !== "string" || !/^0x[0-9a-f]{64}$/.test(value)) {
    issues.push(`${fieldName} must be a lowercase 32-byte hex hash`);
  }
}

function expectNonEmptyString(value: unknown, fieldName: string, issues: string[]): void {
  if (typeof value !== "string" || value.trim().length === 0) {
    issues.push(`${fieldName} must be a non-empty string`);
  }
}

function expectString(value: unknown, fieldName: string, issues: string[]): void {
  if (typeof value !== "string") {
    issues.push(`${fieldName} must be a string`);
  }
}

function expectBoolean(value: unknown, fieldName: string, issues: string[]): void {
  if (typeof value !== "boolean") {
    issues.push(`${fieldName} must be a boolean`);
  }
}

function expectOneOf(
  value: unknown,
  allowed: readonly string[],
  fieldName: string,
  issues: string[]
): void {
  if (typeof value !== "string" || !allowed.includes(value)) {
    issues.push(`${fieldName} must be one of ${allowed.join(", ")}`);
  }
}

function assertNever(value: never): never {
  throw new Error(`unexpected value: ${String(value)}`);
}
