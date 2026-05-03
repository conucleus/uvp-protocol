import {
  extractHookDependencies,
  normalizeHookExpression,
  parseHookExpression,
  signalKey,
  type HookDependency,
  type HookExpressionAst
} from "@uvp-eth/hook-core";
import { canonicalize } from "./canonical.js";
import { hashCanonical } from "./hash.js";
import {
  COMPILER_NAME,
  COMPILER_VERSION,
  HOOK_PLAN_SCHEMA_VERSION,
  type CompiledHookPlanHook,
  type ExecuteConfigs,
  type HookPlanArtifact,
  type HookPlanExecutorRoute,
  type SelectedStageBinding,
  type ZhixuPlatform,
  type ZhixuDefinition,
  type ZhixuStage
} from "./types/index.js";

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

export function compileZhixuHookPlan(definition: ZhixuDefinition): HookPlanArtifact {
  const issues = validateZhixuShape(definition);
  if (issues.length > 0) {
    throw new HookPlanCompilationError(issues);
  }

  const zhixuId = definition.metadata.uid ?? definition.metadata.name;
  const version = definition.metadata.annotations?.version ?? "1";
  const platform = normalizePlatform(definition.spec.platform);
  const stageEntries = flattenStages(definition);
  const stageIds = new Set(stageEntries.map((entry) => entry.stageIdentifier));
  const selectedStageBindings = buildSelectedStageBindings(stageEntries, stageIds);
  const executorRoutes = buildExecutorRoutes(stageEntries);

  const validationIssues = [
    ...validateStageExecutors(stageEntries, selectedStageBindings),
    ...validateTriggerReferences(stageEntries),
    ...validateReceiveSignalReferences(stageEntries),
    ...validateSignalMaps(stageEntries)
  ];
  if (validationIssues.length > 0) {
    throw new HookPlanCompilationError(validationIssues);
  }

  const compiledHooks = stageEntries.flatMap((entry) => compileStageHooks(entry));
  const dependencyIndex = buildDependencyIndex(compiledHooks);
  const planId = hashCanonical("uvp:hook-plan-id:v1", {
    compiler: { name: COMPILER_NAME, version: COMPILER_VERSION },
    platform,
    version,
    zhixuId,
    zhixuName: definition.metadata.name
  });

  const payload = {
    schemaVersion: HOOK_PLAN_SCHEMA_VERSION,
    planId,
    zhixuId,
    version,
    zhixuName: definition.metadata.name,
    platform,
    compiledHooks,
    dependencyIndex,
    executorRoutes,
    selectedStageBindings,
    source: canonicalize(definition)
  };
  const planHash = hashCanonical("uvp:hook-plan-artifact:v1", payload);

  return {
    schemaVersion: HOOK_PLAN_SCHEMA_VERSION,
    planId,
    zhixuId,
    version,
    zhixuName: definition.metadata.name,
    platform,
    compiledHooks,
    dependencyIndex,
    executorRoutes,
    selectedStageBindings,
    planHash
  };
}

export function validateHookPlanArtifact(value: unknown): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value)) {
    return ["artifact must be an object"];
  }

  expectLiteral(value.schemaVersion, HOOK_PLAN_SCHEMA_VERSION, "schemaVersion", issues);
  expectHexHash(value.planId, "planId", issues);
  expectNonEmptyString(value.zhixuId, "zhixuId", issues);
  expectNonEmptyString(value.version, "version", issues);
  expectNonEmptyString(value.zhixuName, "zhixuName", issues);
  if (!isPlatform(value.platform)) {
    issues.push("platform must be an object with a non-empty type");
  }
  expectHexHash(value.planHash, "planHash", issues);

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
  if (!Array.isArray(value.selectedStageBindings)) {
    issues.push("selectedStageBindings must be an array");
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

  return issues;
}

function normalizePlatform(platform: ZhixuPlatform): ZhixuPlatform {
  return {
    type: platform.type,
    ...(platform.provider !== undefined ? { provider: platform.provider } : {}),
    ...(platform.version !== undefined ? { version: platform.version } : {}),
    ...(platform.params !== undefined ? { params: platform.params } : {})
  };
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
  for (const [index, hook] of hooks.entries()) {
    if (!isRecord(hook)) {
      issues.push(`compiledHooks[${index}] must be an object`);
      continue;
    }
    const prefix = `compiledHooks[${index}]`;
    expectNonEmptyString(hook.hookId, `${prefix}.hookId`, issues);
    expectOneOf(hook.kind, ["receive", "signalMap"], `${prefix}.kind`, issues);
    expectNonEmptyString(hook.stageIdentifier, `${prefix}.stageIdentifier`, issues);
    expectNonEmptyString(hook.hookName, `${prefix}.hookName`, issues);
    expectBoolean(hook.trigger, `${prefix}.trigger`, issues);
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
    if (
      dependency.kind === "timer" &&
      (!Number.isSafeInteger(dependency.delaySeconds) || Number(dependency.delaySeconds) <= 0)
    ) {
      issues.push(`${path}[${index}].delaySeconds must be a positive safe integer for timer dependencies`);
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
      const key = signalKey(dependency.source, dependency.signalName);
      const hookIds = recomputed.get(key) ?? new Set<string>();
      hookIds.add(hook.hookId);
      recomputed.set(key, hookIds);
    }
  }

  const expected = Object.fromEntries(
    [...recomputed.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, hookIds]) => [key, [...hookIds].sort()])
  );
  if (JSON.stringify(expected) !== JSON.stringify(dependencyIndex)) {
    issues.push("dependencyIndex must match compiled hook dependencies");
  }
  return issues;
}

function isHookDependency(value: unknown): value is HookDependency {
  return (
    isRecord(value) &&
    (value.kind === "positive" || value.kind === "negative" || value.kind === "timer") &&
    typeof value.source === "string" &&
    typeof value.signalName === "string"
  );
}

interface StageEntry {
  readonly taskName: string;
  readonly stage: ZhixuStage;
  readonly stageIdentifier: string;
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

function flattenStages(definition: ZhixuDefinition): readonly StageEntry[] {
  const entries: StageEntry[] = [];
  const taskNames = new Set<string>();
  for (const task of definition.spec.taskPatterns) {
    if (taskNames.has(task.name)) {
      throw new HookPlanCompilationError([`duplicate task pattern ${task.name}`]);
    }
    taskNames.add(task.name);

    const stageNames = new Set<string>();
    for (const stage of task.stages) {
      if (stageNames.has(stage.name)) {
        throw new HookPlanCompilationError([`duplicate stage ${task.name}.${stage.name}`]);
      }
      stageNames.add(stage.name);
      entries.push({
        taskName: task.name,
        stage,
        stageIdentifier: `${task.name}.${stage.name}`
      });
    }
  }
  return entries;
}

function buildSelectedStageBindings(
  stageEntries: readonly StageEntry[],
  stageIds: ReadonlySet<string>
): readonly SelectedStageBinding[] {
  const bindings: SelectedStageBinding[] = [];
  const issues: string[] = [];
  const seenBindings = new Set<string>();
  for (const entry of stageEntries) {
    for (const target of entry.stage.selectedStages ?? []) {
      if (!stageIds.has(target)) {
        issues.push(`${entry.stageIdentifier}.selectedStages references unknown stage ${target}`);
        continue;
      }
      const bindingKey = `${entry.stageIdentifier}->${target}`;
      if (seenBindings.has(bindingKey)) {
        issues.push(`${entry.stageIdentifier}.selectedStages contains duplicate target ${target}`);
        continue;
      }
      seenBindings.add(bindingKey);
      bindings.push({
        selectorStageIdentifier: entry.stageIdentifier,
        targetStageIdentifier: target
      });
    }
  }
  if (issues.length > 0) {
    throw new HookPlanCompilationError(issues);
  }
  return bindings.sort((left, right) =>
    left.selectorStageIdentifier.localeCompare(right.selectorStageIdentifier) ||
    left.targetStageIdentifier.localeCompare(right.targetStageIdentifier)
  );
}

function buildExecutorRoutes(
  stageEntries: readonly StageEntry[]
): Record<string, HookPlanExecutorRoute> {
  const routes: Record<string, HookPlanExecutorRoute> = {};
  for (const entry of stageEntries) {
    if (!entry.stage.executor) {
      continue;
    }
    routes[entry.stageIdentifier] = routeForStage(entry);
  }
  return sortRecord(routes);
}

function validateStageExecutors(
  stageEntries: readonly StageEntry[],
  selectedStageBindings: readonly SelectedStageBinding[]
): readonly string[] {
  const issues: string[] = [];
  const targetsBySelector = new Map<string, string[]>();
  for (const binding of selectedStageBindings) {
    const targets = targetsBySelector.get(binding.selectorStageIdentifier) ?? [];
    targets.push(binding.targetStageIdentifier);
    targetsBySelector.set(binding.selectorStageIdentifier, targets);
  }

  const anchoredClosure = new Set<string>();
  const queue: string[] = [];
  for (const entry of stageEntries) {
    if (!hasStaticExecutor(entry.stage.executor)) {
      continue;
    }
    anchoredClosure.add(entry.stageIdentifier);
    queue.push(entry.stageIdentifier);
  }

  while (queue.length > 0) {
    const selectorStageIdentifier = queue.shift()!;
    for (const targetStageIdentifier of targetsBySelector.get(selectorStageIdentifier) ?? []) {
      if (anchoredClosure.has(targetStageIdentifier)) {
        continue;
      }
      anchoredClosure.add(targetStageIdentifier);
      queue.push(targetStageIdentifier);
    }
  }

  for (const entry of stageEntries) {
    if (hasStaticExecutor(entry.stage.executor) || anchoredClosure.has(entry.stageIdentifier)) {
      continue;
    }
    issues.push(
      `${entry.stageIdentifier} has no static executor and is not reachable from a static executor through selectedStages`
    );
  }
  return issues;
}

function validateTriggerReferences(stageEntries: readonly StageEntry[]): readonly string[] {
  const issues: string[] = [];
  for (const entry of stageEntries) {
    const receiveSignals = entry.stage.receiveSignals ?? {};
    for (const trigger of entry.stage.trigger) {
      if (!receiveSignals[trigger]) {
        issues.push(`${entry.stageIdentifier}.trigger references missing receiveSignals key ${trigger}`);
      }
    }
  }
  return issues;
}

function validateReceiveSignalReferences(stageEntries: readonly StageEntry[]): readonly string[] {
  const issues: string[] = [];
  const catalog = buildSignalReferenceCatalog(stageEntries);
  for (const entry of stageEntries) {
    for (const [hookName, rawExpression] of Object.entries(entry.stage.receiveSignals ?? {})) {
      const ast = parseHookExpressionForValidation(
        rawExpression,
        `${entry.stageIdentifier}.receiveSignals.${hookName}`,
        issues
      );
      if (!ast) {
        continue;
      }
      issues.push(
        ...validateHookDependencyReferences(
          ast,
          `${entry.stageIdentifier}.receiveSignals.${hookName}`,
          catalog
        )
      );
    }
  }
  return issues;
}

function validateSignalMaps(stageEntries: readonly StageEntry[]): readonly string[] {
  const issues: string[] = [];
  const catalog = buildSignalReferenceCatalog(stageEntries);
  for (const entry of stageEntries) {
    const executor = entry.stage.executor;
    if (executor?.supplierType !== "zhixu") {
      continue;
    }
    const signalMap = executor.zhixuExecutorConfig?.signalMap;
    if (!signalMap) {
      issues.push(`${entry.stageIdentifier}.executor.zhixuExecutorConfig.signalMap is required`);
      continue;
    }
    if (!signalMap.str || !signalMap.cmp) {
      issues.push(`${entry.stageIdentifier}.signalMap must contain str and cmp`);
      continue;
    }
    const parsed = Object.entries(signalMap).map(([signal, raw]) => ({
      signal,
      ast: parseHookExpressionForValidation(
        raw,
        `${entry.stageIdentifier}.executor.zhixuExecutorConfig.signalMap.${signal}`,
        issues
      )
    }));
    if (parsed.some((item) => !item.ast)) {
      continue;
    }
    const parsedHooks = parsed as readonly {
      readonly signal: string;
      readonly ast: HookExpressionAst;
    }[];
    const sources = new Set(parsedHooks.map((item) => item.ast.source));
    if (sources.size !== 1) {
      issues.push(`${entry.stageIdentifier}.signalMap must reference one source`);
    }
    for (const item of parsedHooks) {
      issues.push(
        ...validateHookDependencyReferences(
          item.ast,
          `${entry.stageIdentifier}.executor.zhixuExecutorConfig.signalMap.${item.signal}`,
          catalog
        )
      );
    }
  }
  return issues;
}

interface SignalReferenceCatalog {
  readonly localSources: ReadonlySet<string>;
  readonly stagesByIdentifier: ReadonlyMap<string, StageEntry>;
}

function buildSignalReferenceCatalog(
  stageEntries: readonly StageEntry[]
): SignalReferenceCatalog {
  return {
    localSources: new Set(stageEntries.map((entry) => entry.stage.source)),
    stagesByIdentifier: new Map(
      stageEntries.map((entry) => [entry.stageIdentifier, entry])
    )
  };
}

function parseHookExpressionForValidation(
  rawExpression: string,
  path: string,
  issues: string[]
): HookExpressionAst | undefined {
  try {
    return parseHookExpression(rawExpression);
  } catch (error) {
    issues.push(`${path} is invalid: ${error instanceof Error ? error.message : String(error)}`);
    return undefined;
  }
}

function validateHookDependencyReferences(
  ast: HookExpressionAst,
  path: string,
  catalog: SignalReferenceCatalog
): readonly string[] {
  const issues: string[] = [];
  const seen = new Set<string>();
  for (const dependency of extractHookDependencies(ast)) {
    const dependencyKey = `${dependency.source}::${dependency.signalName}`;
    if (seen.has(dependencyKey)) {
      continue;
    }
    seen.add(dependencyKey);

    if (dependency.signalName === "OUTSIDE" || dependency.signalName === "OUTSOURCE") {
      continue;
    }
    if (!catalog.localSources.has(dependency.source)) {
      continue;
    }

    const signalReference = parseSignalReference(dependency.signalName);
    if (!signalReference) {
      continue;
    }

    const referencedStage = catalog.stagesByIdentifier.get(signalReference.stageIdentifier);
    if (!referencedStage) {
      issues.push(`${path} references unknown stage ${signalReference.stageIdentifier}`);
      continue;
    }
    if (referencedStage.stage.source !== dependency.source) {
      issues.push(
        `${path} references ${signalReference.stageIdentifier} under source ${dependency.source}, but stage source is ${referencedStage.stage.source}`
      );
      continue;
    }
    const sentSignals = referencedStage.stage.sendSignals;
    if (sentSignals && !sentSignals.includes(signalReference.signalName)) {
      issues.push(`${path} references unknown signal ${signalReference.stageIdentifier}.${signalReference.signalName}`);
    }
  }
  return issues;
}

function parseSignalReference(
  signalName: string
): { readonly stageIdentifier: string; readonly signalName: string } | undefined {
  const parts = signalName.split(".");
  if (parts.length !== 3) {
    return undefined;
  }
  return {
    stageIdentifier: `${parts[0]}.${parts[1]}`,
    signalName: parts[2]!
  };
}

function compileStageHooks(entry: StageEntry): readonly CompiledHookPlanHook[] {
  const hooks: CompiledHookPlanHook[] = [];
  for (const [hookName, rawExpression] of Object.entries(entry.stage.receiveSignals ?? {})) {
    hooks.push(compileHook({
      kind: "receive",
      stageIdentifier: entry.stageIdentifier,
      hookName,
      trigger: entry.stage.trigger.includes(hookName),
      rawExpression,
      ...(entry.stage.executor ? { route: routeForStage(entry) } : {})
    }));
  }

  if (entry.stage.executor?.supplierType === "zhixu") {
    for (const [signalName, rawExpression] of Object.entries(
      entry.stage.executor.zhixuExecutorConfig?.signalMap ?? {}
    )) {
      hooks.push(compileHook({
        kind: "signalMap",
        stageIdentifier: entry.stageIdentifier,
        hookName: `signalMap.${signalName}`,
        trigger: false,
        rawExpression,
        ...(entry.stage.executor ? { route: routeForStage(entry) } : {})
      }));
    }
  }

  return hooks.sort((left, right) => left.hookId.localeCompare(right.hookId));
}

function compileHook(input: {
  readonly kind: "receive" | "signalMap";
  readonly stageIdentifier: string;
  readonly hookName: string;
  readonly trigger: boolean;
  readonly rawExpression: string;
  readonly route?: HookPlanExecutorRoute;
}): CompiledHookPlanHook {
  const ast: HookExpressionAst = parseHookExpression(input.rawExpression);
  const route = input.route;
  return {
    hookId: `${input.stageIdentifier}#${input.hookName}`,
    kind: input.kind,
    stageIdentifier: input.stageIdentifier,
    hookName: input.hookName,
    trigger: input.trigger,
    rawExpression: input.rawExpression,
    normalizedExpression: normalizeHookExpression(ast),
    ast,
    dependencies: extractHookDependencies(ast),
    ...(route ? { route } : {})
  };
}

function buildDependencyIndex(
  compiledHooks: readonly CompiledHookPlanHook[]
): Record<string, readonly string[]> {
  const index = new Map<string, Set<string>>();
  for (const hook of compiledHooks) {
    for (const dependency of hook.dependencies) {
      const key = signalKey(dependency.source, dependency.signalName);
      const hooks = index.get(key) ?? new Set<string>();
      hooks.add(hook.hookId);
      index.set(key, hooks);
    }
  }

  const output: Record<string, readonly string[]> = {};
  for (const [key, hookIds] of [...index.entries()].sort(([left], [right]) => left.localeCompare(right))) {
    output[key] = [...hookIds].sort();
  }
  return output;
}

function routeForStage(entry: StageEntry): HookPlanExecutorRoute {
  const executor = entry.stage.executor;
  if (!executor) {
    throw new HookPlanCompilationError([`${entry.stageIdentifier} has no executor route`]);
  }
  return {
    stageIdentifier: entry.stageIdentifier,
    executor,
    ...(entry.stage.fileResources ? { fileResources: entry.stage.fileResources } : {})
  };
}

function hasStaticExecutor(executor: ExecuteConfigs | undefined): boolean {
  return Boolean(executor?.supplierID);
}

function sortRecord<T>(record: Record<string, T>): Record<string, T> {
  return Object.fromEntries(
    Object.entries(record).sort(([left], [right]) => left.localeCompare(right))
  ) as Record<string, T>;
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
