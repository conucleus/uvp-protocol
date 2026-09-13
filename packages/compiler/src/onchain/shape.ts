import type { HexString, ZhixuPlatform } from "../types/index.js";

/**
 * onchain 各阶段共享的形状/词表微助手（自 onchain-hook-plan.ts 原样迁入，
 * 单一归属，不在 validate/instructions/canonical/hash/solidity 间复制定义）。
 * isHexArrayRecord / isPlatform 仅 validate/artifact 消费，保持该文件私有。
 */

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isHexHash(value: unknown): value is HexString {
  return typeof value === "string" && /^0x[0-9a-f]{64}$/.test(value);
}

export function expectLiteral(
  value: unknown,
  expected: string,
  fieldName: string,
  issues: string[],
): void {
  if (value !== expected) {
    issues.push(`${fieldName} must be ${expected}`);
  }
}

export function expectHexHash(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (!isHexHash(value)) {
    issues.push(`${fieldName} must be a lowercase 32-byte hex hash`);
  }
}

export function expectNonEmptyString(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string" || value.trim().length === 0) {
    issues.push(`${fieldName} must be a non-empty string`);
  }
}

export function expectString(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string") {
    issues.push(`${fieldName} must be a string`);
  }
}

export function expectBoolean(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "boolean") {
    issues.push(`${fieldName} must be a boolean`);
  }
}

export function expectOneOf(
  value: unknown,
  allowed: readonly string[],
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string" || !allowed.includes(value)) {
    issues.push(`${fieldName} must be one of ${allowed.join(", ")}`);
  }
}

export function assertNever(value: never): never {
  throw new Error(
    `unsupported on-chain HookPlan node: ${JSON.stringify(value)}`,
  );
}
