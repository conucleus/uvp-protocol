import { EMPTY_MERKLE_ROOT, merkleRoot } from "./dock.js";

/**
 * Validate the Merkle commitments carried by a HookPlan artifact.
 *
 * The Rust linker checks these commitments while producing the portable
 * artifact.  The TS artifact boundary must repeat the check when it receives
 * a serialized artifact, otherwise a caller could repin `planHash` around a
 * stale route/interface root and still pass local validation.
 *
 * This helper deliberately only checks the commitment surface.  The regular
 * HookPlan/on-chain validators own the rest of the schema and append their
 * detailed field diagnostics independently.
 */
export function validateDockCommitments(
  value: unknown,
  path = "artifact",
): readonly string[] {
  if (!isRecord(value)) {
    return [];
  }

  const issues: string[] = [];
  const routes = value.dockRoutes;
  if (Array.isArray(routes)) {
    const routeHashes: string[] = [];
    let allRouteHashesValid = true;
    for (const [index, route] of routes.entries()) {
      if (!isRecord(route)) {
        issues.push(`${path}.dockRoutes[${index}] must be an object`);
        allRouteHashesValid = false;
        continue;
      }
      if (!isHexHash(route.routeHash)) {
        issues.push(
          `${path}.dockRoutes[${index}].routeHash must be a lowercase 32-byte hex hash`,
        );
        allRouteHashesValid = false;
        continue;
      }
      routeHashes.push(route.routeHash);
    }
    if (allRouteHashesValid && isHexHash(value.dockRoutesRoot)) {
      const expectedRoot = merkleRoot(routeHashes as `0x${string}`[]);
      if (value.dockRoutesRoot !== expectedRoot) {
        issues.push(
          `${path}.dockRoutesRoot must match the recomputed root over dock route hashes`,
        );
      }
    }
  }

  const dockInterface = value.dockInterface;
  if (dockInterface === null) {
    if (isHexHash(value.dockInterfaceRoot) && value.dockInterfaceRoot !== EMPTY_MERKLE_ROOT) {
      issues.push(
        `${path}.dockInterfaceRoot must be the empty root when dockInterface is null`,
      );
    }
    return issues;
  }
  if (dockInterface === undefined) {
    // fail-closed：undefined 与非对象同口径拒绝——null 是唯一的"无 dock 接口"
    // 合法表达，字段缺失不得静默跳过承诺校验。
    issues.push(`${path}.dockInterface must be an object or null`);
    return issues;
  }
  if (!isRecord(dockInterface)) {
    issues.push(`${path}.dockInterface must be an object or null`);
    return issues;
  }

  const inputs = dockInterface.inputs;
  const outputs = dockInterface.outputs;
  if (!Array.isArray(inputs)) {
    issues.push(`${path}.dockInterface.inputs must be an array`);
  }
  if (!Array.isArray(outputs)) {
    issues.push(`${path}.dockInterface.outputs must be an array`);
  }
  if (!Array.isArray(inputs) || !Array.isArray(outputs)) {
    return issues;
  }

  const interfaceLeaves: string[] = [];
  let allLeavesValid = true;
  for (const [index, port] of inputs.entries()) {
    if (!isRecord(port)) {
      issues.push(`${path}.dockInterface.inputs[${index}] must be an object`);
      allLeavesValid = false;
      continue;
    }
    if (!isHexHash(port.leafHash)) {
      issues.push(
        `${path}.dockInterface.inputs[${index}].leafHash must be a lowercase 32-byte hex hash`,
      );
      allLeavesValid = false;
      continue;
    }
    interfaceLeaves.push(port.leafHash);
  }
  for (const [index, port] of outputs.entries()) {
    if (!isRecord(port)) {
      issues.push(`${path}.dockInterface.outputs[${index}] must be an object`);
      allLeavesValid = false;
      continue;
    }
    if (!isHexHash(port.leafHash)) {
      issues.push(
        `${path}.dockInterface.outputs[${index}].leafHash must be a lowercase 32-byte hex hash`,
      );
      allLeavesValid = false;
      continue;
    }
    interfaceLeaves.push(port.leafHash);
  }
  if (allLeavesValid && isHexHash(value.dockInterfaceRoot)) {
    const expectedRoot = merkleRoot(interfaceLeaves as `0x${string}`[]);
    if (value.dockInterfaceRoot !== expectedRoot) {
      issues.push(
        `${path}.dockInterfaceRoot must match the recomputed root over interface leaves`,
      );
    }
  }
  return issues;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isHexHash(value: unknown): value is `0x${string}` {
  return typeof value === "string" && /^0x[0-9a-f]{64}$/.test(value);
}
