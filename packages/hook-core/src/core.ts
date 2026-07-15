import {
  compile,
  evaluateHook,
  parseHook,
  replay,
  semanticVersion,
  version
} from "@conucleus/uvp-core-node";

export const EXPECTED_UVP_CORE_VERSION = "0.1.0" as const;
export const EXPECTED_UVP_SEMANTIC_VERSION = "uvp-semantic/0.1" as const;

let compatible = false;

export function uvpCoreCompatibility(): {
  readonly coreVersion: string;
  readonly semanticVersion: string;
} {
  const coreVersion = version();
  const runtimeSemanticVersion = semanticVersion();
  if (coreVersion !== EXPECTED_UVP_CORE_VERSION || runtimeSemanticVersion !== EXPECTED_UVP_SEMANTIC_VERSION) {
    throw new Error(
      `incompatible uvp-core: expected ${EXPECTED_UVP_CORE_VERSION}/${EXPECTED_UVP_SEMANTIC_VERSION}, ` +
      `received ${coreVersion}/${runtimeSemanticVersion}`
    );
  }
  compatible = true;
  return { coreVersion, semanticVersion: runtimeSemanticVersion };
}

export function compileWithUvpCore(request: unknown): unknown {
  ensureCompatible();
  return compile(request);
}

export function parseHookWithUvpCore(request: unknown): unknown {
  ensureCompatible();
  return parseHook(request);
}

export function evaluateHookWithUvpCore(request: unknown): unknown {
  ensureCompatible();
  return evaluateHook(request);
}

export function replayWithUvpCore(request: unknown): unknown {
  ensureCompatible();
  return replay(request);
}

function ensureCompatible(): void {
  if (!compatible) {
    uvpCoreCompatibility();
  }
}
