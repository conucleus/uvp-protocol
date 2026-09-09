import {
  definitionRefHash,
  dockRouteId,
  EMPTY_MERKLE_ROOT,
  inputBindingHash,
  inputPortLeaf,
  interfaceLeaf,
  merkleRoot,
  outputBindingHash,
  outputPortLeaf,
  routeHash as routeHashOf,
  stageKey,
} from "./dock.js";

/**
 * Validate the Merkle commitments carried by a HookPlan artifact (dock v2).
 *
 * The chain-track TS assembly (dock-commitments.ts) computes every
 * leaf/root/route hash while producing the artifact.  The artifact boundary
 * must repeat the same word-level recomputation when it receives a
 * serialized artifact, otherwise a caller could repin `planHash` around a
 * stale or hand-crafted route/interface commitment and still pass local
 * validation.
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
      issues.push(
        ...validateDockRouteCommitments(route, `${path}.dockRoutes[${index}]`),
      );
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

  const definition = isRecord(dockInterface.definition)
    ? dockInterface.definition
    : undefined;
  const uid = definition?.uid;
  const definitionRef = definition?.definitionRefHash;
  const interfaces = dockInterface.interfaces;
  if (
    typeof uid !== "string" ||
    uid.length === 0 ||
    !isHexHash(definitionRef)
  ) {
    issues.push(
      `${path}.dockInterface.definition must carry a non-empty uid and a lowercase 32-byte hex definitionRefHash`,
    );
    return issues;
  }
  if (!Array.isArray(interfaces)) {
    issues.push(`${path}.dockInterface.interfaces must be an array`);
    return issues;
  }
  if (definitionRefHash(uid) !== definitionRef) {
    issues.push(
      `${path}.dockInterface.definition.definitionRefHash must match H(UVP_DEFINITION_REF_V1, keccak(uid))`,
    );
  }

  for (const [index, entry] of interfaces.entries()) {
    if (!isRecord(entry)) {
      issues.push(`${path}.dockInterface.interfaces[${index}] must be an object`);
      continue;
    }
    issues.push(
      ...validateInterfaceCommitments(
        entry,
        uid,
        `${path}.dockInterface.interfaces[${index}]`,
      ),
    );
  }

  const interfaceRoots: string[] = [];
  let allInterfaceRootsValid = true;
  for (const entry of interfaces) {
    if (!isRecord(entry) || !isHexHash(entry.interfaceRoot)) {
      allInterfaceRootsValid = false;
      continue;
    }
    interfaceRoots.push(entry.interfaceRoot as string);
  }
  if (allInterfaceRootsValid && isHexHash(dockInterface.interfaceRoot)) {
    const expectedRoot = merkleRoot(interfaceRoots as `0x${string}`[]);
    if (dockInterface.interfaceRoot !== expectedRoot) {
      issues.push(
        `${path}.dockInterface.interfaceRoot must match the recomputed root over interface leaves`,
      );
    }
    // 定义级 root（PlanCommit 的接口根承诺）与接口叶重算结果必须一致。
    if (isHexHash(value.dockInterfaceRoot) && value.dockInterfaceRoot !== expectedRoot) {
      issues.push(
        `${path}.dockInterfaceRoot must match the recomputed root over interface leaves`,
      );
    }
  }
  return issues;
}

/**
 * 单条 route 的承诺重算（对 TS 组装层的逐 word 自校验，防实现漂移）：
 * routeId、每条 bindingHash、两 root、routeHash 全部从携带字段独立重推导。
 */
function validateDockRouteCommitments(
  route: Record<string, unknown>,
  path: string,
): readonly string[] {
  const issues: string[] = [];
  const orderMode = route.orderMode;
  if (orderMode !== "new" && orderMode !== "existing") {
    issues.push(`${path}.orderMode must be "new" or "existing"`);
    return issues;
  }

  const local = isRecord(route.local) ? route.local : undefined;
  const target = isRecord(route.target) ? route.target : undefined;
  const interfaceName =
    target !== undefined && typeof target.interfaceName === "string"
      ? target.interfaceName
      : undefined;
  // fail-closed：承诺重算的输入字段缺失即显式拒绝——静默跳过会让一条
  // local/routeId/interfaceName 残缺的 route 绕过全部重算（含 dockRoutesRoot
  // 对拍，root 对拍依赖每条 routeHash 有效）。
  if (local === undefined) {
    issues.push(`${path}.local must be an object`);
    return issues;
  }
  if (!isHexHash(local.definitionRefHash)) {
    issues.push(
      `${path}.local.definitionRefHash must be a lowercase 32-byte hex hash`,
    );
    return issues;
  }
  if (typeof local.stageIdentifier !== "string") {
    issues.push(`${path}.local.stageIdentifier must be a string`);
    return issues;
  }
  if (!isHexHash(route.routeId)) {
    issues.push(
      `${path}.routeId must be a lowercase 32-byte hex hash`,
    );
    return issues;
  }
  if (interfaceName === undefined) {
    issues.push(`${path}.target.interfaceName must be a string`);
    return issues;
  }
  const recomputedRouteId = dockRouteId(
    local.definitionRefHash,
    stageKey(local.stageIdentifier),
  );
  if (recomputedRouteId !== route.routeId) {
    issues.push(
      `${path}.routeId must match the recomputed H(UVP_DOCK_ROUTE_ID_V1, localDefinitionRefHash, stageKey)`,
    );
  }

  // fail-closed：绑定数组缺失/非数组是形状问题，不是"空绑定"——静默按 []
  // 重算会让携带 EMPTY root 的残缺 route 通过全部承诺对拍。
  const inputBindings = Array.isArray(route.inputBindings)
    ? route.inputBindings
    : undefined;
  const outputBindings = Array.isArray(route.outputBindings)
    ? route.outputBindings
    : undefined;
  if (inputBindings === undefined) {
    issues.push(`${path}.inputBindings must be an array`);
  }
  if (outputBindings === undefined) {
    issues.push(`${path}.outputBindings must be an array`);
  }
  const inputHashes: string[] = [];
  const outputHashes: string[] = [];
  let bindingsComputable = true;
  for (const [index, binding] of (inputBindings ?? []).entries()) {
    if (
      !isRecord(binding) ||
      !isHexHash(binding.bindingHash) ||
      typeof binding.localHookName !== "string" ||
      typeof binding.targetPort !== "string" ||
      !isHexHash(binding.targetSourceId) ||
      !isHexHash(binding.targetSignalId)
    ) {
      // 形状坏项显式报 issue：只跳过该条的重算，不静默吞掉。
      issues.push(
        `${path}.inputBindings[${index}] must carry bindingHash, localHookName, targetPort, targetSourceId and targetSignalId`,
      );
      bindingsComputable = false;
      continue;
    }
    const recomputed = inputBindingHash({
      routeId: route.routeId,
      interfaceName,
      localHookId: `${local.stageIdentifier}#${binding.localHookName}`,
      portName: binding.targetPort,
      targetSourceId: binding.targetSourceId,
      targetSignalId: binding.targetSignalId,
    });
    if (recomputed !== binding.bindingHash) {
      issues.push(
        `${path}.inputBindings[${index}].bindingHash must match the recomputed input-binding preimage`,
      );
    }
    inputHashes.push(binding.bindingHash);
  }
  for (const [index, binding] of (outputBindings ?? []).entries()) {
    if (
      !isRecord(binding) ||
      !isHexHash(binding.bindingHash) ||
      !isHexHash(binding.localSourceId) ||
      !isHexHash(binding.localSignalId) ||
      typeof binding.targetPort !== "string" ||
      !isHexHash(binding.targetSourceId) ||
      !isHexHash(binding.targetSignalId)
    ) {
      issues.push(
        `${path}.outputBindings[${index}] must carry bindingHash, localSourceId, localSignalId, targetPort, targetSourceId and targetSignalId`,
      );
      bindingsComputable = false;
      continue;
    }
    const recomputed = outputBindingHash({
      routeId: route.routeId,
      interfaceName,
      localSourceId: binding.localSourceId,
      localSignalId: binding.localSignalId,
      portName: binding.targetPort,
      targetSourceId: binding.targetSourceId,
      targetSignalId: binding.targetSignalId,
    });
    if (recomputed !== binding.bindingHash) {
      issues.push(
        `${path}.outputBindings[${index}].bindingHash must match the recomputed output-binding preimage`,
      );
    }
    outputHashes.push(binding.bindingHash);
  }

  if (bindingsComputable) {
    const inputsRoot = merkleRoot(inputHashes as `0x${string}`[]);
    const outputsRoot = merkleRoot(outputHashes as `0x${string}`[]);
    if (isHexHash(route.inputBindingsRoot) && route.inputBindingsRoot !== inputsRoot) {
      issues.push(
        `${path}.inputBindingsRoot must match the recomputed root over input binding hashes`,
      );
    }
    if (isHexHash(route.outputBindingsRoot) && route.outputBindingsRoot !== outputsRoot) {
      issues.push(
        `${path}.outputBindingsRoot must match the recomputed root over output binding hashes`,
      );
    }
    if (
      isHexHash(target?.definitionRefHash) &&
      isHexHash(route.inputBindingsRoot) &&
      isHexHash(route.outputBindingsRoot)
    ) {
      const recomputedRouteHash = routeHashOf({
        localDefinitionRefHash: local.definitionRefHash,
        targetDefinitionRefHash: target.definitionRefHash,
        interfaceName,
        orderMode,
        inputBindingsRoot: route.inputBindingsRoot,
        outputBindingsRoot: route.outputBindingsRoot,
      });
      if (recomputedRouteHash !== route.routeHash) {
        issues.push(
          `${path}.routeHash must match the recomputed route preimage`,
        );
      }
    }
  }
  return issues;
}

/** 单个具名接口的承诺重算：端口叶 → 两 root → interfaceLeaf_v2。 */
function validateInterfaceCommitments(
  entry: Record<string, unknown>,
  uid: string,
  path: string,
): readonly string[] {
  const issues: string[] = [];
  const name = entry.name;
  if (typeof name !== "string" || name.length === 0) {
    // 无名接口不得静默跳过承诺重算：它的叶仍参与定义级 root，跳过即绕过
    // interfaceRoot 对拍。
    issues.push(`${path}.name must be a non-empty string`);
    return issues;
  }
  if (!Array.isArray(entry.orderModes)) {
    issues.push(`${path}.orderModes must be an array`);
    return issues;
  }
  const inputs = Array.isArray(entry.inputs) ? entry.inputs : undefined;
  const outputs = Array.isArray(entry.outputs) ? entry.outputs : undefined;
  if (inputs === undefined || outputs === undefined) {
    issues.push(`${path}.inputs and outputs must be arrays`);
    return issues;
  }

  const inputLeaves: string[] = [];
  let inputsComputable = true;
  for (const [index, port] of inputs.entries()) {
    if (
      !isRecord(port) ||
      !isHexHash(port.leafHash) ||
      typeof port.port !== "string" ||
      typeof port.hookId !== "string"
    ) {
      issues.push(
        `${path}.inputs[${index}] must carry leafHash, port and hookId`,
      );
      inputsComputable = false;
      continue;
    }
    // input 端口必须携带所属 stage 的 source 类（非空字符串）
    // ——中性 resolution manifest 与 linker 的双侧单源校验都依赖该字段，
    // 缺失/空白在制品边界响亮拒绝（source 不入叶哈希，独立成 issue）。
    if (
      typeof port.source !== "string" ||
      (port.source as string).trim().length === 0
    ) {
      issues.push(
        `${path}.inputs[${index}].source must be a non-empty string (the owning stage's source class; the neutral manifest and the single-seam validation require it)`,
      );
    }
    const recomputed = inputPortLeaf({
      uid,
      interfaceName: name,
      portName: port.port,
      hookId: port.hookId,
    });
    if (recomputed !== port.leafHash) {
      issues.push(
        `${path}.inputs[${index}].leafHash must match the recomputed input-port preimage`,
      );
    }
    inputLeaves.push(port.leafHash);
  }
  const outputLeaves: string[] = [];
  let outputsComputable = true;
  for (const [index, port] of outputs.entries()) {
    if (
      !isRecord(port) ||
      !isHexHash(port.leafHash) ||
      typeof port.port !== "string" ||
      typeof port.canonicalOutputSignal !== "string"
    ) {
      issues.push(
        `${path}.outputs[${index}] must carry leafHash, port and canonicalOutputSignal`,
      );
      outputsComputable = false;
      continue;
    }
    const recomputed = outputPortLeaf({
      uid,
      interfaceName: name,
      portName: port.port,
      canonicalSignal: port.canonicalOutputSignal,
    });
    if (recomputed !== port.leafHash) {
      issues.push(
        `${path}.outputs[${index}].leafHash must match the recomputed output-port preimage`,
      );
    }
    outputLeaves.push(port.leafHash);
  }

  if (!inputsComputable || !outputsComputable) {
    return issues;
  }
  const inputsRoot = merkleRoot(inputLeaves as `0x${string}`[]);
  const outputsRoot = merkleRoot(outputLeaves as `0x${string}`[]);
  if (isHexHash(entry.inputsRoot) && entry.inputsRoot !== inputsRoot) {
    issues.push(
      `${path}.inputsRoot must match the recomputed root over input-port leaves`,
    );
  }
  if (isHexHash(entry.outputsRoot) && entry.outputsRoot !== outputsRoot) {
    issues.push(
      `${path}.outputsRoot must match the recomputed root over output-port leaves`,
    );
  }
  if (
    isHexHash(entry.inputsRoot) &&
    isHexHash(entry.outputsRoot) &&
    isHexHash(entry.interfaceRoot)
  ) {
    try {
      const recomputedLeaf = interfaceLeaf({
        uid,
        interfaceName: name,
        orderModes: entry.orderModes.map((mode) => String(mode)),
        inputsRoot: entry.inputsRoot,
        outputsRoot: entry.outputsRoot,
      });
      if (recomputedLeaf !== entry.interfaceRoot) {
        issues.push(
          `${path}.interfaceRoot must match the recomputed interface-leaf preimage`,
        );
      }
    } catch {
      issues.push(
        `${path}.orderModes must be a non-empty subset of {new, existing} without duplicates`,
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
