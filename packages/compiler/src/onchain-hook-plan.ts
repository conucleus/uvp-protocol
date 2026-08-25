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

const ONCHAIN_PLAN_HASH_DOMAIN = "uvp:onchain-hook-plan-artifact:v1";
const ONCHAIN_ROUTE_HASH_DOMAIN = "uvp:onchain-hook-route:v1";
const ONCHAIN_SELECTOR_BINDING_HASH_DOMAIN =
  "uvp:onchain-stage-selector-binding:v1";
const ONCHAIN_SIGNAL_CAPABILITY_HASH_DOMAIN =
  "uvp:onchain-signal-capability:v1";

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
      isTrigger: hook.isTrigger,
      instructions: compileHookInstructions(hook.ast),
      dependencies: hook.dependencies.map(compileDependency),
      ...(hook.route ? { routeRef: routeRefForRoute(hook.route) } : {}),
    }))
    .sort(compareOnchainHooks);
  const crossStageIssues = crossStageDependencyIssues(
    compiledHooks.map((hook) => ({
      hookId: hook.hookId,
      stageId: hook.stageId,
      isTrigger: hook.isTrigger,
      dependencies: hook.dependencies,
    })),
  );
  if (crossStageIssues.length > 0) {
    throw new HookPlanCompilationError(crossStageIssues);
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
  const payload = {
    schemaVersion: ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    planId: hookPlanArtifact.planId,
    zhixuId: hookPlanArtifact.zhixuId,
    version: hookPlanArtifact.version,
    zhixuName: hookPlanArtifact.zhixuName,
    platform: hookPlanArtifact.platform,
    sourcePlanHash: hookPlanArtifact.planHash,
    compiledHooks,
    dependencyIndex,
    executorRoutes,
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
): OnchainHookPlanArtifact {
  return compileOnchainHookPlan(compileZhixuHookPlan(definition));
}

export function compileZhixuRegisterPlanArgs(
  definition: ZhixuDefinition,
): SolidityRegisterPlanArgs {
  return toSolidityRegisterPlanArgs(compileZhixuOnchainHookPlan(definition));
}

export function validateOnchainHookPlanArtifact(
  value: unknown,
): readonly string[] {
  const issues: string[] = [];
  if (!isRecord(value)) {
    return ["artifact must be an object"];
  }

  expectLiteral(
    value.schemaVersion,
    ONCHAIN_HOOK_PLAN_SCHEMA_VERSION,
    "schemaVersion",
    issues,
  );
  expectHexHash(value.planId, "planId", issues);
  expectNonEmptyString(value.zhixuId, "zhixuId", issues);
  expectNonEmptyString(value.version, "version", issues);
  expectNonEmptyString(value.zhixuName, "zhixuName", issues);
  if (!isPlatform(value.platform)) {
    issues.push("platform must be an object with a non-empty type");
  }
  expectHexHash(value.sourcePlanHash, "sourcePlanHash", issues);
  expectHexHash(value.planHash, "planHash", issues);

  const compiledHooks = Array.isArray(value.compiledHooks)
    ? value.compiledHooks
    : undefined;
  if (!compiledHooks) {
    issues.push("compiledHooks must be an array");
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
    if (dependencyIndex) {
      issues.push(
        ...validateOnchainDependencyIndex(compiledHooks, dependencyIndex),
      );
    }
  }

  if (executorRoutes) {
    issues.push(...validateOnchainExecutorRoutes(executorRoutes));
  }
  if (selectorBindings) {
    issues.push(...validateOnchainSelectorBindings(selectorBindings));
  }
  if (signalCapabilities) {
    issues.push(...validateOnchainSignalCapabilities(signalCapabilities));
  }

  if (isPlanHashRecomputable(value)) {
    const expectedPlanHash = hashOnchainPlanPayload({
      schemaVersion: value.schemaVersion,
      planId: value.planId,
      zhixuId: value.zhixuId,
      version: value.version,
      zhixuName: value.zhixuName,
      platform: value.platform,
      sourcePlanHash: value.sourcePlanHash,
      compiledHooks: value.compiledHooks,
      dependencyIndex: value.dependencyIndex,
      executorRoutes: value.executorRoutes,
      selectorBindings: value.selectorBindings,
      signalCapabilities: value.signalCapabilities,
    });
    if (value.planHash !== expectedPlanHash) {
      issues.push(
        "planHash must match the canonical on-chain HookPlan payload",
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

export function toSolidityRegisterPlanArgs(
  artifact: OnchainHookPlanArtifact,
): SolidityRegisterPlanArgs {
  assertOnchainHookPlanArtifact(artifact);

  const hooks = artifact.compiledHooks.map((hook) => {
    const base = {
      hookId: hook.hookId,
      stageId: hook.stageId,
      hookName: onchainHookName(hook.hookName),
      kind: hook.kind,
      isTrigger: hook.isTrigger,
      instructions: hook.instructions.map(toSolidityInstructionArg),
      dependencyKeys: uniqueSorted(
        hook.dependencies.map((dependency) => dependency.signalKey),
      ),
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
  const planHash = keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "bytes32 domain, bytes32 hooksHash, bytes32 metadataHash",
      ),
      [keccak256(stringToHex("uvp.plan.runtime.v1")), hooksHash, metadataHash],
    ),
  ) as HexString;

  return {
    schemaVersion: artifact.schemaVersion,
    sourcePlanId: artifact.planId,
    zhixuId: artifact.zhixuId,
    version: artifact.version,
    planHash,
    artifactHash: artifact.planHash,
    hooksHash,
    metadataHash,
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

function hashSolidityHooks(
  hooks: SolidityRegisterPlanArgs["hooks"],
): HexString {
  const encodedHooks = hooks.map((hook) => ({
    hookId: hook.hookId,
    stageId: hook.stageId,
    hookName: hook.hookName,
    isTrigger: hook.isTrigger,
    instructions: hook.instructions.map((instruction) =>
      solidityInstructionTuple(instruction),
    ),
    dependencyKeys: hook.dependencyKeys,
  }));
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        "(bytes32 hookId,bytes32 stageId,bytes32 hookName,bool isTrigger,(uint8 op,bytes32 sourceId,bytes32 signalId,uint16 arity,uint64 delaySeconds)[] instructions,bytes32[] dependencyKeys)[] hooks",
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
): readonly OnchainHookInstruction[] {
  return compileConditionInstructions(ast.condition, ast.source);
}

function compileConditionInstructions(
  condition: HookConditionAst,
  source: string,
): readonly OnchainHookInstruction[] {
  switch (condition.kind) {
    case "signal":
      return [signalInstruction(source, condition.signalName)];
    case "merge":
    case "anchor":
      throw new HookPlanCompilationError([
        `on-chain HookPlan does not support ${condition.kind} entries yet; `
        + "MERGE@/ANCHOR@ are per-event cloud runtime deliveries"
      ]);
    case "external":
      if (!condition.target) {
        throw new HookPlanCompilationError([
          `external condition is missing its @(...) target in stage ${source}`
        ]);
      }
      return compileHookInstructions(condition.target);
    case "not":
      return [
        ...compileConditionInstructions(condition.expr, source),
        { op: "NOT" },
      ];
    case "and":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source),
        ),
        { op: "AND", arity: condition.terms.length },
      ];
    case "or":
      return [
        ...condition.terms.flatMap((term) =>
          compileConditionInstructions(term, source),
        ),
        { op: "OR", arity: condition.terms.length },
      ];
    case "delay":
      return [
        ...compileConditionInstructions(condition.expr, source),
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

function buildOnchainDependencyIndex(
  compiledHooks: readonly OnchainCompiledHook[],
): Record<HexString, readonly HexString[]> {
  const index = new Map<HexString, Set<HexString>>();
  for (const hook of compiledHooks) {
    for (const dependency of hook.dependencies) {
      const hookIds = index.get(dependency.signalKey) ?? new Set<HexString>();
      hookIds.add(hook.hookId);
      index.set(dependency.signalKey, hookIds);
    }
  }

  const output: Record<HexString, readonly HexString[]> = {};
  for (const [signalKey, hookIds] of [...index.entries()].sort(
    ([left], [right]) => compareByCodeUnit(left, right),
  )) {
    output[signalKey] = [...hookIds].sort();
  }
  return output;
}

function compileExecutorRoute(
  route: HookPlanExecutorRoute,
): OnchainExecutorRoute {
  const executorHash = opaqueContentHash(route.executor);
  const resourcesHash =
    route.fileResources === undefined ? ZERO_HASH : opaqueContentHash(route.fileResources);
  return {
    routeId: onchainRouteId(route.stageIdentifier),
    stageId: onchainStageId(route.stageIdentifier),
    stageIdentifier: route.stageIdentifier,
    executorType: String(route.executor.supplierType),
    executorId: route.executor.supplierID ?? "",
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

function hashOnchainPlanPayload(
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
    expectOneOf(hook.kind, ["receive", "signalMap"], `${prefix}.kind`, issues);
    expectBoolean(hook.isTrigger, `${prefix}.isTrigger`, issues);

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
        ...validateInstructions(hook.instructions, `${prefix}.instructions`),
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

function validateInstructions(
  instructions: readonly unknown[],
  path: string,
): readonly string[] {
  const issues: string[] = [];
  let stackDepth = 0;

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
        stackDepth += 1;
        break;
      case "NOT":
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
        }
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
        } else {
          stackDepth = stackDepth - arity + 1;
        }
        break;
      }
      case "DELAY":
        if (
          !Number.isSafeInteger(instruction.delaySeconds) ||
          Number(instruction.delaySeconds) <= 0
        ) {
          issues.push(`${prefix}.delaySeconds must be a positive safe integer`);
        }
        if (stackDepth < 1) {
          issues.push(`${prefix}.op requires one stack item`);
        }
        break;
      default:
        issues.push(`${prefix}.op must be one of SIGNAL, NOT, AND, OR, DELAY`);
    }
  }

  if (instructions.length > 0 && stackDepth !== 1) {
    issues.push(`${path} must leave exactly one stack item`);
  }

  return issues;
}

function validateOnchainDependencies(
  dependencies: readonly unknown[],
  path: string,
): readonly string[] {
  const issues: string[] = [];
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
    if (
      dependency.kind === "timer" &&
      (!Number.isSafeInteger(dependency.delaySeconds) ||
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
 * A canonical dependency key may be watched by hooks of a single stage only:
 * bootstrap signals fan out to every registered watcher, and an unmaterialized
 * cross-stage watcher would make the submitting transaction revert forever.
 */
function crossStageDependencyIssues(hooks: readonly unknown[]): readonly string[] {
  interface Watcher {
    readonly stageId: string;
    readonly isTrigger: boolean;
  }
  const watchersBySignalKey = new Map<string, Set<Watcher>>();
  for (const hook of hooks) {
    if (
      !isRecord(hook) ||
      typeof hook.hookId !== "string" ||
      typeof hook.stageId !== "string" ||
      typeof hook.isTrigger !== "boolean" ||
      !Array.isArray(hook.dependencies)
    ) {
      continue;
    }
    for (const dependency of hook.dependencies) {
      if (!isOnchainHookDependency(dependency)) {
        continue;
      }
      const watchers =
        watchersBySignalKey.get(dependency.signalKey) ?? new Set<Watcher>();
      watchers.add({ stageId: hook.stageId, isTrigger: hook.isTrigger });
      watchersBySignalKey.set(dependency.signalKey, watchers);
    }
  }
  const issues: string[] = [];
  for (const [signalKey, watchers] of watchersBySignalKey) {
    const stages = new Set([...watchers].map((watcher) => watcher.stageId));
    // Trigger hooks crossing stages are the normal selectedStages flow (the
    // contract skips triggers of unmaterialized stages). The brick is a
    // NON-trigger watcher in a stage that has not materialized yet: it makes
    // the submitting transaction revert forever.
    const hasNonTriggerWatcher = [...watchers].some(
      (watcher) => !watcher.isTrigger,
    );
    if (stages.size > 1 && hasNonTriggerWatcher) {
      issues.push(
        `dependency ${signalKey} is shared across stages ${[...stages]
          .sort((left, right) => compareByCodeUnit(left, right))
          .join(", ")} with at least one non-trigger watcher; `
        + "an unmaterialized stage's non-trigger hook would make the "
        + "submitting transaction revert forever",
      );
    }
  }
  return issues;
}

function validateOnchainDependencyIndex(
  hooks: readonly unknown[],
  dependencyIndex: Record<string, readonly string[]>,
): readonly string[] {
  const issues: string[] = [];
  const recomputed = new Map<string, Set<string>>();
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
      const hookIds = recomputed.get(dependency.signalKey) ?? new Set<string>();
      hookIds.add(hook.hookId);
      recomputed.set(dependency.signalKey, hookIds);
    }
  }

  issues.push(...crossStageDependencyIssues(hooks));

  const expected = Object.fromEntries(
    [...recomputed.entries()]
      .sort(([left], [right]) => compareByCodeUnit(left, right))
      .map(([signalKey, hookIds]) => [signalKey, [...hookIds].sort()]),
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
  return (
    value.schemaVersion === ONCHAIN_HOOK_PLAN_SCHEMA_VERSION &&
    isHexHash(value.planId) &&
    typeof value.zhixuId === "string" &&
    typeof value.version === "string" &&
    typeof value.zhixuName === "string" &&
    isPlatform(value.platform) &&
    isHexHash(value.sourcePlanHash) &&
    Array.isArray(value.compiledHooks) &&
    isHexArrayRecord(value.dependencyIndex) &&
    Array.isArray(value.executorRoutes) &&
    Array.isArray(value.selectorBindings) &&
    Array.isArray(value.signalCapabilities) &&
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
