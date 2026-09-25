import {
  onchainSelectorBindingHash,
  onchainSignalCapabilityHash,
  onchainSignalId,
  onchainRouteId,
  onchainSourceId,
  onchainStageId,
  routeHashFromDigests,
} from "../hash/route.js";
import {
  expectClosedKeySet,
  expectHexHash,
  expectLiteral,
  expectNonEmptyString,
  isHexHash,
  isRecord,
} from "../shape.js";
import type { HexString } from "../../types/index.js";

/**
 * 能力声明族校验（自 onchain-hook-plan.ts 原样迁入）：executorRoutes /
 * selectorBindings / signalCapabilities 的形状与承诺重算，E16 事实键唯一
 * 属主镜像，以及 supplierType/fileType 闭集词表（编译入口与校验边界同集
 * 单一来源）。
 */

/**
 * 三张表的封闭键集（与 types/index.ts 声明同步）：与顶层 unknown-field
 * 拒绝同款——深层携带未声明额外键的制品不得作为 plan 的唯一字节数组
 * 形态通过校验。
 */
const EXECUTOR_ROUTE_FIELDS: readonly string[] = [
  "routeId",
  "stageId",
  "stageIdentifier",
  "executorType",
  "executorId",
  "executorHash",
  "resourcesHash",
  "routeHash",
];
const SELECTOR_BINDING_FIELDS: readonly string[] = [
  "selectorStageIdentifier",
  "targetStageIdentifier",
  "selectorStageId",
  "targetStageId",
  "bindingHash",
];
const SIGNAL_CAPABILITY_FIELDS: readonly string[] = [
  "stageIdentifier",
  "stageId",
  "source",
  "declaredSignal",
  "targetSource",
  "targetSourceId",
  "targetSignalName",
  "signalId",
  "targetOrderRelation",
  "capabilityHash",
];

/**
 * supplierType 闭集（与 uvp_model::SUPPLIER_TYPES / Go supplierTypes 同源，
 * 注册表 rule executor-supplier-type-closed-enum）：executorRoutes 只进
 * 制品承诺（executorHash → planHash），不进链上 PlanCommit（实参只有
 * hooksHash/capabilitiesRoot/dock roots），链上没有闭集守卫——闭集外的
 * 字符串（含 "Zhixu" 等大小写变体）只存在编译/制品边界这一道拦截。
 * 比对精确匹配、不 trim：executorHash 哈希的是原文，trim 后匹配会放行
 * 带空白的原文进承诺（与 Rust/Go 严格枚举闸同口径）。
 */
const SUPPLIER_TYPES: readonly string[] = ["individual", "organization", "zhixu"];

/**
 * fileResources 的 fileType 闭集（与 Go fileTypes 同源：
 * local|http|txcloud|plain_text）：fileResources 经 resourcesHash 进制品
 * 承诺（与 executor 路由同面，不上链），拼错的 fileType 不得静默成承诺
 * 内容。
 */
const FILE_TYPES: readonly string[] = ["local", "http", "txcloud", "plain_text"];

export { SUPPLIER_TYPES, FILE_TYPES };

/**
 * E16 镜像（uvp-constraints.v1.json rejectionSurfaces
 * e16-current-order-factkey-unique-owner）：事实键
 * (targetSourceId, signalId) 在 plan 内有唯一属主阶段。属主唯一性是携证
 * 解析的前提——链上按能力叶声明事实属主，同一事实键存在两个声明属主时，
 * 任一方都能携证把事实落到自己的阶段（阶段物化/executor 门与 origin
 * 同意链的执行者腿随之被模糊）。Rust/Go 镜像仍欠（镜像债）。
 */
function duplicateCurrentOrderFactKeyIssues(
  capabilities: readonly {
    readonly stage: string;
    readonly sourceId: string;
    readonly signalId: string;
  }[],
): readonly string[] {
  const issues: string[] = [];
  const owners = new Map<string, string>();
  for (const capability of capabilities) {
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
          + "current-order fact keys must resolve to exactly one owner stage "
          + "for proof-carrying attribution to be unambiguous",
      );
    }
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
    expectClosedKeySet(route, EXECUTOR_ROUTE_FIELDS, prefix, issues);
    expectHexHash(route.routeId, `${prefix}.routeId`, issues);
    expectHexHash(route.stageId, `${prefix}.stageId`, issues);
    expectNonEmptyString(
      route.stageIdentifier,
      `${prefix}.stageIdentifier`,
      issues,
    );
    expectNonEmptyString(route.executorType, `${prefix}.executorType`, issues);
    // executorType 闭集（编译入口 SUPPLIER_TYPES 同集同精确匹配口径）：
    // executor 路由只进制品承诺、不进链上 PlanCommit，闭集外字符串没有
    // 合约侧兜底——手工/第三方制品不得绕过 Rust 编译门把词表外值带进
    // 承诺。
    if (
      typeof route.executorType === "string" &&
      !SUPPLIER_TYPES.includes(route.executorType)
    ) {
      issues.push(
        `${prefix}.executorType must be one of ${SUPPLIER_TYPES.join("|")} (case-sensitive), received ${JSON.stringify(route.executorType)}`,
      );
    }
    // executorId 与编译入口 executor.supplierID 同口径拒空串/空白：空 id
    // 寻址不了执行者，只会在 keeper 投递面变成确定性失败。
    if (typeof route.executorId === "string" && route.executorId.trim().length === 0) {
      issues.push(
        `${prefix}.executorId must be a non-empty executor id (whitespace-only ids are rejected at the compile entry already)`,
      );
    }
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
    expectClosedKeySet(binding, SELECTOR_BINDING_FIELDS, prefix, issues);
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
    expectClosedKeySet(capability, SIGNAL_CAPABILITY_FIELDS, prefix, issues);
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
    expectLiteral(
      capability.targetOrderRelation,
      "current",
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
      capability.targetOrderRelation === "current"
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

function selectorBindingKey(
  selectorStageId: HexString,
  targetStageId: HexString,
): string {
  return `${selectorStageId}->${targetStageId}`;
}

export {
  duplicateCurrentOrderFactKeyIssues,
  validateOnchainExecutorRoutes,
  validateOnchainSelectorBindings,
  validateOnchainSignalCapabilities,
  selectorBindingKey,
};
