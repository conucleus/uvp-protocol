import {
  analyzeWithUvpCore,
  type ZhixuAnalysis,
} from "@uvp-eth/hook-core";
import {
  HOOK_PLAN_SCHEMA_VERSION,
  type HookPlanArtifact,
  type ZhixuPlatform,
  type ZhixuDefinition,
} from "./types/index.js";
import { compareByCodePoint, canonicalJson } from "@uvp-eth/canonical-json";
import { hashCanonical } from "./hash.js";
import { definitionUid } from "./identity.js";
import {
  assembleChainTrackHookPlan,
  hookPlanPayloadForHash,
  normalizePlatformPreimage,
  planIdOf,
  HOOK_PLAN_HASH_DOMAIN,
} from "./hook-plan/assemble.js";
import { lowerHookPlanShell } from "./hook-plan/lower.js";

/**
 * 链轨 hook_plan 入口：uvp-core `analyze` 是定义级 DSL/表达式校验的唯一
 * authority（形状、出生信号集、物化门、hook 解析），本模块只消费 analyze
 * 结果做链轨 lowering 与 planId/planHash 承诺，不再重复校验输入定义；
 * `validateHookPlanArtifact` 是外部传入 artifact 的边界校验（跨包入口），
 * 不在本模块的编译路径上二次调用。
 */

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

export { compareCanonicalKey } from "./canonical-key.js";

export function compileZhixuHookPlan(
  definition: ZhixuDefinition,
): HookPlanArtifact {
  let analysis: ZhixuAnalysis;
  try {
    analysis = analyzeWithUvpCore({ definition });
  } catch (error) {
    throw new HookPlanCompilationError([
      error instanceof Error ? error.message : String(error)
    ]);
  }

  try {
    return assembleChainTrackHookPlan(
      definition,
      lowerHookPlanShell(analysis),
    );
  } catch (error) {
    throw new HookPlanCompilationError([
      error instanceof Error ? error.message : String(error),
    ]);
  }
}

const HOOK_PLAN_ARTIFACT_FIELDS: readonly string[] = [
  "schemaVersion",
  "planId",
  "zhixuId",
  "zhixuName",
  "platform",
  "compiledHooks",
  "dependencyIndex",
  "supplierRoutes",
  "selectedStageBindings",
  "signalCapabilities",
  "admissions",
  "source",
  "planHash",
];

export function validateHookPlanArtifact(value: unknown): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value)) {
    return ["artifact must be an object"];
  }

  for (const key of Object.keys(value)) {
    if (!HOOK_PLAN_ARTIFACT_FIELDS.includes(key)) {
      issues.push(
        `unknown field \`${key}\` on the artifact — planHash does not cover undeclared fields, so the artifact would not be the plan's unique byte form; remove it or recompile`,
      );
    }
  }

  expectLiteral(value.schemaVersion, HOOK_PLAN_SCHEMA_VERSION, "schemaVersion", issues);
  expectHexHash(value.planId, "planId", issues);
  expectNonEmptyString(value.zhixuId, "zhixuId", issues);
  expectNonEmptyString(value.zhixuName, "zhixuName", issues);
  if (!isPlatform(value.platform)) {
    issues.push("platform must be an object with a non-empty type");
  }
  expectHexHash(value.planHash, "planHash", issues);

  if (isPlatform(value.platform) && typeof value.zhixuId === "string" && typeof value.zhixuName === "string") {
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
      issues.push("planId preimage is not canonicalizable (platform carries non-JSON values)");
    }
  }
  if (value.source === undefined) {
    issues.push(
      "source is required (the canonical annotation-stripped definition snapshot in the planHash preimage)",
    );
  } else {
    issues.push(...sourceBindingIssues(value));
    if (typeof value.planHash === "string" && /^0x[0-9a-f]{64}$/.test(value.planHash)) {
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
  }

  const compiledHooks = Array.isArray(value.compiledHooks) ? value.compiledHooks : undefined;
  if (!compiledHooks) {
    issues.push("compiledHooks must be an array");
  }
  const dependencyIndex = isStringArrayRecord(value.dependencyIndex) ? value.dependencyIndex : undefined;
  if (!dependencyIndex) {
    issues.push("dependencyIndex must be a record of string arrays");
  }
  if (!isRecord(value.supplierRoutes)) {
    issues.push("supplierRoutes must be an object");
  }
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

  if (isRecord(value.supplierRoutes)) {
    for (const [routeKey, route] of Object.entries(value.supplierRoutes)) {
      if (!isRecord(route)) {
        issues.push(`supplierRoutes.${routeKey} must be an object`);
        continue;
      }
      if (route.stageIdentifier !== routeKey) {
        issues.push(`supplierRoutes.${routeKey}.stageIdentifier must equal ${routeKey}`);
      }
      if (!isRecord(route.executor)) {
        issues.push(`supplierRoutes.${routeKey}.executor must be an object`);
      } else if (route.executor.supplierType === "dock") {
        issues.push(
          `supplierRoutes.${routeKey} must not carry a dock supplier; a dock stage's supplier is selected once through the stage supplier patch (dkid), not as a plan route`,
        );
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
  if (Array.isArray(value.admissions)) {
    issues.push(...validateAdmissions(value.admissions));
  } else {
    issues.push("admissions must be an array");
  }

  if (compiledHooks) {
    issues.push(
      ...danglingMetadataStageIssues(
        compiledHooks,
        Array.isArray(value.selectedStageBindings) ? value.selectedStageBindings : [],
        Array.isArray(value.signalCapabilities) ? value.signalCapabilities : [],
        Array.isArray(value.admissions) ? value.admissions : [],
      ),
    );
  }

  return issues;
}

function sourceBindingIssues(value: Record<string, unknown>): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value.source)) {
    return [
      "source must be the canonical Zhixu definition object the artifact was compiled from",
    ];
  }
  if (typeof value.zhixuId === "string") {
    try {
      if (definitionUid(value.source) !== value.zhixuId) {
        issues.push(
          "zhixuId must equal definitionUid(source); a forged or swapped id would bind the plan to another definition's identity",
        );
      }
    } catch {
      issues.push(
        "source must be content-canonicalizable so definitionUid(source) can be recomputed",
      );
    }
  }
  const sourceMetadata = isRecord(value.source.metadata)
    ? value.source.metadata
    : undefined;
  if (
    typeof value.zhixuName === "string" &&
    typeof sourceMetadata?.name === "string" &&
    value.zhixuName !== sourceMetadata.name
  ) {
    issues.push(
      "zhixuName must equal source.metadata.name; the carried source snapshot is the only owner of the plan's display identity",
    );
  }

  let analysis: ZhixuAnalysis | undefined;
  try {
    analysis = analyzeWithUvpCore({ definition: value.source });
  } catch (error) {
    issues.push(
      "source must be an analyzable Zhixu definition: "
        + (error instanceof Error ? error.message : String(error)),
    );
  }
  if (analysis !== undefined) {
    if (
      isPlatform(value.platform)
      && !canonicalEqual(
        analysis.platform,
        normalizePlatformPreimage(value.platform),
      )
    ) {
      issues.push(
        "platform must match the source definition's spec.platform (empty params normalize away)",
      );
    }
    const expectedCapabilities = new Map<string, unknown>();
    for (const capability of analysis.signalCapabilities) {
      if (
        isRecord(capability) &&
        typeof capability.stageIdentifier === "string" &&
        typeof capability.targetSignalName === "string"
      ) {
        expectedCapabilities.set(
          `${capability.stageIdentifier}\u0000${capability.targetSignalName}`,
          capability,
        );
      }
    }
    if (Array.isArray(value.signalCapabilities)) {
      for (const [index, capability] of value.signalCapabilities.entries()) {
        if (
          !isRecord(capability) ||
          typeof capability.stageIdentifier !== "string" ||
          typeof capability.targetSignalName !== "string"
        ) {
          continue;
        }
        const expected = expectedCapabilities.get(
          `${capability.stageIdentifier}\u0000${capability.targetSignalName}`,
        );
        if (expected === undefined) {
          issues.push(
            `signalCapabilities[${index}] ${capability.stageIdentifier}::${capability.targetSignalName} is not a sendSignal declared by the source definition; `
              + "a capability can only be declared by the stage that owns the signal",
          );
        } else if (!canonicalEqual(expected, capability)) {
          issues.push(
            `signalCapabilities[${index}] must match the source definition's sendSignals as analyzed by uvp-core`,
          );
        }
      }
    }

    const expectedAdmissions = new Map<string, unknown>();
    for (const admission of analysis.admissions) {
      if (
        isRecord(admission) &&
        typeof admission.stageIdentifier === "string" &&
        typeof admission.signalName === "string"
      ) {
        expectedAdmissions.set(
          `${admission.stageIdentifier}\u0000${admission.signalName}`,
          admission,
        );
      }
    }
    if (Array.isArray(value.admissions)) {
      const declaredAdmissions = new Set<string>();
      for (const [index, admission] of value.admissions.entries()) {
        if (
          !isRecord(admission) ||
          typeof admission.stageIdentifier !== "string" ||
          typeof admission.signalName !== "string"
        ) {
          continue;
        }
        const key = `${admission.stageIdentifier}\u0000${admission.signalName}`;
        const expected = expectedAdmissions.get(key);
        if (expected === undefined) {
          issues.push(
            `admissions[${index}] ${admission.stageIdentifier}::${admission.signalName} is not declared with validWhen by the source definition; `
              + "a forged admission would gate an emission the source never declared",
          );
          continue;
        }
        declaredAdmissions.add(key);
        if (!canonicalEqual(expected, admission)) {
          issues.push(
            `admissions[${index}] must match the source definition's sendSignals[].validWhen as analyzed by uvp-core`,
          );
        }
      }
      for (const [key, admission] of expectedAdmissions) {
        if (declaredAdmissions.has(key)) {
          continue;
        }
        const expected = admission as {
          readonly stageIdentifier: string;
          readonly signalName: string;
        };
        issues.push(
          `admissions must include ${expected.stageIdentifier}::${expected.signalName} from the source definition's sendSignals[].validWhen; `
            + "a stripped admission would bypass the emission gate",
        );
      }
    }
  }
  return issues;
}

function canonicalEqual(left: unknown, right: unknown): boolean {
  try {
    return canonicalJson(left) === canonicalJson(right);
  } catch {
    return false;
  }
}

export function assertHookPlanArtifact(value: unknown): asserts value is HookPlanArtifact {
  const issues = validateHookPlanArtifact(value);
  if (issues.length > 0) {
    throw new HookPlanArtifactValidationError(issues);
  }
}

function validateCompiledHooks(hooks: readonly unknown[]): readonly string[] {
  const issues: string[] = [];
  const hookIds = new Set<string>();
  const dynamicByStage = new Map<string, boolean>();
  const mixedDynamicStages = new Set<string>();
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
      ["none", "trigger"],
      `${prefix}.orderTriggerKind`,
      issues,
    );
    expectBoolean(hook.emitReady, `${prefix}.emitReady`, issues);
    expectBoolean(hook.dockExecutor, `${prefix}.dockExecutor`, issues);
    expectBoolean(hook.dynamicExecutor, `${prefix}.dynamicExecutor`, issues);
    if (hook.dynamicExecutor === true) {
      if (hook.orderTriggerKind !== "none") {
        issues.push(
          `${prefix} is a dynamic-executor hook and must not carry an order-trigger bit; birth executors are fixed at plan time`,
        );
      }
      if (hook.dockExecutor === true) {
        issues.push(
          `${prefix} cannot be both a dynamic-executor and a dock-executor hook`,
        );
      }
      if (hook.emitReady !== true) {
        issues.push(
          `${prefix} is a dynamic-executor hook without EMIT_READY; a dynamic stage materializes only through its own emit-ready hooks`,
        );
      }
      if (hook.route !== undefined) {
        issues.push(
          `${prefix} is a dynamic-executor hook and must not carry a supplier route; the supplier is assigned per order through the stage supplier patch`,
        );
      }
    }
    if (hook.dockExecutor === true) {
      if (hook.orderTriggerKind !== "none") {
        issues.push(`${prefix} is a dock stage hook and must not carry an order-trigger bit`);
      }
      if (hook.emitReady !== true) {
        issues.push(
          `${prefix} is a dock stage hook without EMIT_READY; a dock stage materializes only through its own emit-ready hooks, so the flag would be unreachable`,
        );
      }
      if (hook.route !== undefined) {
        issues.push(
          `${prefix} is a dock stage hook and must not carry a supplier route; the dock supplier is selected once through the stage supplier patch (dkid)`,
        );
      }
    }
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
    if (
      typeof hook.stageIdentifier === "string" &&
      typeof hook.dynamicExecutor === "boolean"
    ) {
      const current = dynamicByStage.get(hook.stageIdentifier);
      if (current === undefined) {
        dynamicByStage.set(hook.stageIdentifier, hook.dynamicExecutor);
      } else if (current !== hook.dynamicExecutor && !mixedDynamicStages.has(hook.stageIdentifier)) {
        mixedDynamicStages.add(hook.stageIdentifier);
        issues.push(
          `stage ${hook.stageIdentifier} mixes dynamic-executor hooks with non-dynamic hooks; `
            + "the contract collects the per-stage dynamic set from hook flags and reverts InconsistentDynamicSupplierFlag",
        );
      }
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
    expectLiteral(capability.targetOrderRelation, "current", `${prefix}.targetOrderRelation`, issues);
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

function validateAdmissions(admissions: readonly unknown[]): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  for (const [index, admission] of admissions.entries()) {
    if (!isRecord(admission)) {
      issues.push(`admissions[${index}] must be an object`);
      continue;
    }
    const prefix = `admissions[${index}]`;
    expectNonEmptyString(admission.stageIdentifier, `${prefix}.stageIdentifier`, issues);
    expectNonEmptyString(admission.signalName, `${prefix}.signalName`, issues);
    if (
      !Array.isArray(admission.rawExpression) ||
      admission.rawExpression.length === 0 ||
      admission.rawExpression.some((item: unknown) => typeof item !== "string" || item === "")
    ) {
      issues.push(`${prefix}.rawExpression must be a non-empty array of non-empty strings`);
    }
    expectNonEmptyString(admission.normalizedExpression, `${prefix}.normalizedExpression`, issues);
    if (!isRecord(admission.ast)) {
      issues.push(`${prefix}.ast must be an object`);
    }
    if (!Array.isArray(admission.dependencies)) {
      issues.push(`${prefix}.dependencies must be an array`);
    } else {
      issues.push(...validateDependencies(admission.dependencies, `${prefix}.dependencies`));
    }
    if (
      typeof admission.stageIdentifier === "string" &&
      typeof admission.signalName === "string"
    ) {
      const key = `${admission.stageIdentifier}\u0000${admission.signalName}`;
      if (seen.has(key)) {
        issues.push(
          `duplicate admission ${admission.stageIdentifier}::${admission.signalName}`,
        );
      }
      seen.add(key);
    }
  }
  return issues;
}

function danglingMetadataStageIssues(
  hooks: readonly unknown[],
  selectedStageBindings: readonly unknown[],
  signalCapabilities: readonly unknown[],
  admissions: readonly unknown[],
): readonly string[] {
  const issues: string[] = [];
  const hookStages = new Set<string>();
  for (const hook of hooks) {
    if (isRecord(hook) && typeof hook.stageIdentifier === "string") {
      hookStages.add(hook.stageIdentifier);
    }
  }
  const references: readonly { readonly path: string; readonly stage: string }[] = [
    ...selectedStageBindings.flatMap((binding, index) =>
      isRecord(binding)
        ? [
            ...(typeof binding.selectorStageIdentifier === "string"
              ? [{
                  path: `selectedStageBindings[${index}].selectorStageIdentifier`,
                  stage: binding.selectorStageIdentifier,
                }]
              : []),
            ...(typeof binding.targetStageIdentifier === "string"
              ? [{
                  path: `selectedStageBindings[${index}].targetStageIdentifier`,
                  stage: binding.targetStageIdentifier,
                }]
              : []),
          ]
        : [],
    ),
    ...signalCapabilities.flatMap((capability, index) =>
      isRecord(capability) && typeof capability.stageIdentifier === "string"
        ? [{
            path: `signalCapabilities[${index}].stageIdentifier`,
            stage: capability.stageIdentifier,
          }]
        : [],
    ),
    ...admissions.flatMap((admission, index) =>
      isRecord(admission) && typeof admission.stageIdentifier === "string"
        ? [{
            path: `admissions[${index}].stageIdentifier`,
            stage: admission.stageIdentifier,
          }]
        : [],
    ),
  ];
  for (const reference of references) {
    if (hookStages.has(reference.stage)) {
      continue;
    }
    issues.push(
      `${reference.path} references stage ${reference.stage} which has no compiled hooks; `
        + "on-chain stage existence is established solely by hook registration, so capability and "
        + "binding leaves anchored to this stage can never be materialized or proven — "
        + "reference a stage declared by at least one hook",
    );
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
