import {
  definitionRefHash,
  dockCandidateLeaf,
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
import { DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION } from "./types/index.js";

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
 * Dynamic (target:null) routes join the same recomputation: each
 * unresolvedDockRoutes entry's routeId/candidatesRoot/routeHash is
 * re-derived from its carried fields, and dockRoutesRoot is compared against
 * the combined leaf set (static route hashes ∪ dynamic route hashes) — the
 * root finalize freezes.
 *
 * This helper deliberately only checks the commitment surface.  The regular
 * HookPlan/on-chain validators own the rest of the schema and append their
 * detailed field diagnostics independently (declaration-face shape lives in
 * validateUnresolvedDockRouteDeclarations).
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
  const unresolvedRoutes = Array.isArray(value.unresolvedDockRoutes)
    ? value.unresolvedDockRoutes
    : undefined;
  // dockRoutes/unresolvedDockRoutes 的数组形状由各制品校验器报告（层属
  // 职责），此处只在数组在场时重算承诺——与既有 dockRoutes 口径一致。
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
    // 动态（target:null）route 的叶与静态叶同树：dockRoutesRoot 是
    // finalize 冻结的最终根（静态叶 ∪ 动态叶），两个制品边界按同一口径
    // 重算。任一动态叶 routeHash 非法则整树对拍失效（fail-closed）。
    if (unresolvedRoutes !== undefined) {
      for (const [index, route] of unresolvedRoutes.entries()) {
        if (
          !isRecord(route) ||
          !isHexHash(route.routeHash)
        ) {
          issues.push(
            `${path}.unresolvedDockRoutes[${index}].routeHash must be a lowercase 32-byte hex hash`,
          );
          allRouteHashesValid = false;
          continue;
        }
        routeHashes.push(route.routeHash);
        issues.push(
          ...validateUnresolvedRouteCommitments(
            route,
            `${path}.unresolvedDockRoutes[${index}]`,
          ),
        );
      }
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
  for (const [index, entry] of interfaces.entries()) {
    if (!isRecord(entry)) {
      // 形状 issue 已由上方逐 entry 承诺重算产出（interfaces[i] must be an
      // object），此处只标记聚合不可继续，不重复报。
      allInterfaceRootsValid = false;
      continue;
    }
    // fail-closed：单接口 root 非 hex 是显式 issue——静默 continue 会让
    // 定义级 dockInterfaceRoot/interfaceRoot 对拍整段失效（垃圾值即绕过）。
    if (!isHexHash(entry.interfaceRoot)) {
      issues.push(
        `${path}.dockInterface.interfaces[${index}].interfaceRoot must be a lowercase 32-byte hex hash`,
      );
      allInterfaceRootsValid = false;
      continue;
    }
    interfaceRoots.push(entry.interfaceRoot as string);
  }
  // 定义级 interfaceRoot 非 hex 同样显式报 issue：它是 root 对拍的被检值，
  // 垃圾值不得静默解除比对义务。
  expectHexHashCommitment(
    dockInterface.interfaceRoot,
    `${path}.dockInterface.interfaceRoot`,
    issues,
  );
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
    // fail-closed：承诺字段非 hex/缺失一律显式报 issue，再按重算结果比对。
    // 非字面量（含垃圾值 0xzz…/number/undefined）与重算 root 恒不等，
    // 比对义务不因字段形状坏而豁免。
    expectHexHashCommitment(
      route.inputBindingsRoot,
      `${path}.inputBindingsRoot`,
      issues,
    );
    expectHexHashCommitment(
      route.outputBindingsRoot,
      `${path}.outputBindingsRoot`,
      issues,
    );
    if (route.inputBindingsRoot !== inputsRoot) {
      issues.push(
        `${path}.inputBindingsRoot must match the recomputed root over input binding hashes`,
      );
    }
    if (route.outputBindingsRoot !== outputsRoot) {
      issues.push(
        `${path}.outputBindingsRoot must match the recomputed root over output binding hashes`,
      );
    }
    expectHexHashCommitment(
      target?.definitionRefHash,
      `${path}.target.definitionRefHash`,
      issues,
    );
    // routeHash 重算以三个 word 全部在场为前提；字段缺失/畸形时上面的
    // issue 已把该 route 判废，重算本身无意义（臆造占位 word 只会产出
    // 必然不匹配的二次噪声），在此跳过重算而不是静默放过整条 route。
    if (
      target !== undefined &&
      isHexHash(target.definitionRefHash) &&
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

/**
 * 单条未解析（target:null 动态选择）route 的承诺重算（UVPDockingModule
 * 4.4）：routeId、candidatesRoot（候选叶 merkle）与 routeHash（目标槽 =
 * 候选集 root、两绑定根恒 EMPTY）全部从携带字段独立重推导——候选清单
 * 伪造/换叶/换根在此暴露，制品不得携带与声明面分叉的承诺。
 */
function validateUnresolvedRouteCommitments(
  route: Record<string, unknown>,
  path: string,
): readonly string[] {
  const issues: string[] = [];
  const orderMode = route.orderMode;
  if (orderMode !== "new" && orderMode !== "existing") {
    issues.push(`${path}.orderMode must be "new" or "existing"`);
    return issues;
  }
  const localDefinitionRefHash = route.localDefinitionRefHash;
  const stageIdentifier = route.stageIdentifier;
  const interfaceName = route.interfaceName;
  if (!isHexHash(localDefinitionRefHash)) {
    issues.push(
      `${path}.localDefinitionRefHash must be a lowercase 32-byte hex hash`,
    );
    return issues;
  }
  if (typeof stageIdentifier !== "string" || stageIdentifier.length === 0) {
    issues.push(`${path}.stageIdentifier must be a non-empty string`);
    return issues;
  }
  if (typeof interfaceName !== "string" || interfaceName.length === 0) {
    issues.push(`${path}.interfaceName must be a non-empty string`);
    return issues;
  }
  if (!isHexHash(route.routeId)) {
    issues.push(`${path}.routeId must be a lowercase 32-byte hex hash`);
    return issues;
  }
  const recomputedRouteId = dockRouteId(
    localDefinitionRefHash,
    stageKey(stageIdentifier),
  );
  if (recomputedRouteId !== route.routeId) {
    issues.push(
      `${path}.routeId must match the recomputed H(UVP_DOCK_ROUTE_ID_V1, localDefinitionRefHash, stageKey)`,
    );
  }
  const candidates = Array.isArray(route.candidates)
    ? route.candidates
    : undefined;
  if (candidates === undefined || candidates.length === 0) {
    issues.push(
      `${path}.candidates must be a non-empty array (the frozen candidate root is the route's only selection universe)`,
    );
    return issues;
  }
  const candidateRefHashes: `0x${string}`[] = [];
  for (const [index, candidate] of candidates.entries()) {
    if (!isRecord(candidate) || !isHexHash(candidate.definitionRefHash)) {
      issues.push(
        `${path}.candidates[${index}].definitionRefHash must be a lowercase 32-byte hex hash`,
      );
      return issues;
    }
    candidateRefHashes.push(candidate.definitionRefHash);
  }
  expectHexHashCommitment(route.candidatesRoot, `${path}.candidatesRoot`, issues);
  const recomputedCandidatesRoot = merkleRoot(
    candidateRefHashes.map((definitionRefHash) =>
      dockCandidateLeaf({
        routeId: route.routeId as `0x${string}`,
        targetDefinitionRefHash: definitionRefHash,
        interfaceName,
      }),
    ),
  );
  if (route.candidatesRoot !== recomputedCandidatesRoot) {
    issues.push(
      `${path}.candidatesRoot must match the recomputed merkle root over candidate leaves H(UVP_DOCK_CANDIDATE_V1, routeId, candidateDefinitionRefHash, keccak(interfaceName))`,
    );
  }
  if (isHexHash(route.candidatesRoot)) {
    const recomputedRouteHash = routeHashOf({
      localDefinitionRefHash,
      targetDefinitionRefHash: route.candidatesRoot,
      interfaceName,
      orderMode,
      inputBindingsRoot: EMPTY_MERKLE_ROOT,
      outputBindingsRoot: EMPTY_MERKLE_ROOT,
    });
    if (recomputedRouteHash !== route.routeHash) {
      issues.push(
        `${path}.routeHash must match the recomputed dynamic-route preimage (target slot = candidatesRoot, empty binding roots)`,
      );
    }
  }
  return issues;
}

/**
 * 未解析 route 声明面（§8.8，target:null 动态选择）逐元素形状校验：
 * mode 枚举、端口名形态、至少一条映射（D019 镜像）、基础身份字段与候选
 * 清单（manifest 派生的候选身份）。`target`/`sourceSeam` 不得在场——它们
 * 只能在运行期选定目标后计算（hook plan IR 与 onchain 产物共用本面）。
 */
export function validateUnresolvedDockRouteDeclarations(
  routes: unknown,
  path = "artifact.unresolvedDockRoutes",
): readonly string[] {
  const issues: string[] = [];
  if (!Array.isArray(routes)) {
    return [`${path} must be an array when present`];
  }
  // 显式空数组不得与缺键共享同一 planHash：封闭字段集承诺 plan 的唯一
  // 字节形态，而两个制品的哈希 preimage 装配对"空数组/缺键"做同一归一
  // （hookPlanPayloadForHash 及链轨同口径）——放行空数组会让两种序列化
  // 形态落到同一哈希上。编译器自身对空集只落缺键（dock-commitments 的
  // 装配分支），空数组只能是手改制品。
  if (routes.length === 0) {
    return [
      `${path} must not be an empty array — omit the key instead; the closed field set pins one byte form per plan and the compiler never emits an empty list`,
    ];
  }
  for (const [index, route] of routes.entries()) {
    const prefix = `${path}[${index}]`;
    if (!isRecord(route)) {
      issues.push(`${prefix} must be an object`);
      continue;
    }
    expectLiteralValue(
      route.schemaVersion,
      DOCK_ROUTE_UNRESOLVED_SCHEMA_VERSION,
      `${prefix}.schemaVersion`,
      issues,
    );
    expectNonEmptyStringValue(route.stageIdentifier, `${prefix}.stageIdentifier`, issues);
    expectHexHashValue(route.stageId, `${prefix}.stageId`, issues);
    expectHexHashValue(route.localDefinitionRefHash, `${prefix}.localDefinitionRefHash`, issues);
    expectHexHashValue(route.localPlanId, `${prefix}.localPlanId`, issues);
    expectNonEmptyStringValue(route.localSource, `${prefix}.localSource`, issues);
    expectNonEmptyStringValue(route.interfaceName, `${prefix}.interfaceName`, issues);
    expectOneOfValue(route.orderMode, ["new", "existing"], `${prefix}.orderMode`, issues);
    expectHexHashValue(route.routeId, `${prefix}.routeId`, issues);
    expectHexHashValue(route.candidatesRoot, `${prefix}.candidatesRoot`, issues);
    expectHexHashValue(route.routeHash, `${prefix}.routeHash`, issues);
    for (const absent of ["target", "sourceSeam"]) {
      if (route[absent] !== undefined) {
        issues.push(
          `${prefix}.${absent} must not be present on an unresolved route (computable only after runtime target selection)`,
        );
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
        expectNonEmptyStringValue(binding.signal, `${bindingPath}.signal`, issues);
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

    const candidates = Array.isArray(route.candidates)
      ? route.candidates
      : undefined;
    if (!candidates || candidates.length === 0) {
      issues.push(
        `${prefix}.candidates must be a non-empty array (a dynamic route freezes its selection universe at compile time)`,
      );
    } else {
      const seenRefHashes = new Set<string>();
      for (const [candidateIndex, candidate] of candidates.entries()) {
        const candidatePath = `${prefix}.candidates[${candidateIndex}]`;
        if (!isRecord(candidate)) {
          issues.push(`${candidatePath} must be an object`);
          continue;
        }
        expectNonEmptyStringValue(candidate.zhixuUid, `${candidatePath}.zhixuUid`, issues);
        expectNonEmptyStringValue(candidate.zhixuName, `${candidatePath}.zhixuName`, issues);
        expectHexHashValue(candidate.definitionRefHash, `${candidatePath}.definitionRefHash`, issues);
        expectHexHashValue(candidate.artifactHash, `${candidatePath}.artifactHash`, issues);
        if (candidate.cloudArtifactId !== undefined && typeof candidate.cloudArtifactId !== "string") {
          issues.push(`${candidatePath}.cloudArtifactId must be a string when present`);
        }
        if (candidate.evmPlanId !== undefined && !isHexHash(candidate.evmPlanId)) {
          issues.push(`${candidatePath}.evmPlanId must be a lowercase 32-byte hex hash when present`);
        }
        if (
          typeof candidate.definitionRefHash === "string" &&
          seenRefHashes.has(candidate.definitionRefHash)
        ) {
          issues.push(
            `${candidatePath}.definitionRefHash duplicates an earlier candidate — one published definition cannot occupy two leaves`,
          );
        }
        if (typeof candidate.definitionRefHash === "string") {
          seenRefHashes.add(candidate.definitionRefHash);
        }
      }
    }
  }
  return issues;
}

/** 端口名形态（与 Rust valid_port_name 同规则）：^[a-z][a-z0-9_]{0,31}$。 */
function isPortName(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[a-z][a-z0-9_]{0,31}$/.test(value)
  );
}

function expectLiteralValue(
  value: unknown,
  expected: string,
  fieldName: string,
  issues: string[],
): void {
  if (value !== expected) {
    issues.push(`${fieldName} must be ${expected}`);
  }
}

function expectNonEmptyStringValue(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string" || value.trim().length === 0) {
    issues.push(`${fieldName} must be a non-empty string`);
  }
}

function expectHexHashValue(
  value: unknown,
  fieldName: string,
  issues: string[],
): void {
  if (!isHexHash(value)) {
    issues.push(`${fieldName} must be a lowercase 32-byte hex hash`);
  }
}

function expectOneOfValue(
  value: unknown,
  allowed: readonly string[],
  fieldName: string,
  issues: string[],
): void {
  if (typeof value !== "string" || !allowed.includes(value)) {
    issues.push(`${fieldName} must be one of ${allowed.join(", ")}`);
  }
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
  // fail-closed：root/interfaceRoot 非 hex/缺失一律显式报 issue，且比对
  // 不豁免——非字面量与重算 root 恒不等，形状坏项不得静默跳过对拍。
  expectHexHashCommitment(entry.inputsRoot, `${path}.inputsRoot`, issues);
  expectHexHashCommitment(entry.outputsRoot, `${path}.outputsRoot`, issues);
  expectHexHashCommitment(entry.interfaceRoot, `${path}.interfaceRoot`, issues);
  if (entry.inputsRoot !== inputsRoot) {
    issues.push(
      `${path}.inputsRoot must match the recomputed root over input-port leaves`,
    );
  }
  if (entry.outputsRoot !== outputsRoot) {
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

/**
 * 承诺字段的 fail-closed 形状门：非 lowercase 32-byte hex（含缺失/垃圾值
 * 如 0xzz…）一律产出显式 issue。比对义务不因形状坏而解除——调用方在
 * issue 在场时继续/停止重算都判定制品无效，静默跳过才是漏洞。
 */
function expectHexHashCommitment(
  value: unknown,
  path: string,
  issues: string[],
): void {
  if (!isHexHash(value)) {
    issues.push(`${path} must be a lowercase 32-byte hex hash`);
  }
}
