import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import {
  compile,
  evaluateHook,
  hookPlanSchemaVersion,
  parseHook,
  replay,
  semanticVersion,
  version,
} from "@conucleus/uvp-core-node";
import * as uvpCoreNode from "@conucleus/uvp-core-node";

export const EXPECTED_UVP_CORE_VERSION = "0.1.0" as const;
export const EXPECTED_UVP_SEMANTIC_VERSION = "uvp.semantic.v1" as const;

/**
 * Native build fingerprint (uvp-node build.rs burns `git-<rev>` or
 * `no-git-<version>` at compile time). Version + semantic probes can both pass
 * against a stale dylib whose behavior already changed; the fingerprint is the
 * last line of defense comparing the loaded binary against the checked-out
 * uvp-core HEAD. The uvp-node JS wrapper re-exports the Rust
 * `build_fingerprint`, so the gate below is live (not dormant).
 */
export function uvpCoreBuildFingerprint(): string | undefined {
  const candidate = (uvpCoreNode as Record<string, unknown>).buildFingerprint;
  return typeof candidate === "function"
    ? (candidate as () => string)()
    : undefined;
}

/**
 * hookPlan schema version straight from the loaded native uvp-compiler —
 * Rust is the semantic authority for hookPlan artifacts, so consumers pin
 * matrix entries against this export instead of re-extracting the constant
 * from uvp-core sources.
 */
export function uvpCoreHookPlanSchemaVersion(): string {
  return hookPlanSchemaVersion();
}

/**
 * HEAD of the uvp-core checkout that hosts the loaded native module, or
 * undefined when the module is not a workspace checkout or git is unavailable.
 */
function checkedOutUvpCoreHead(): string | undefined {
  try {
    const require = createRequire(import.meta.url);
    const entry = require.resolve("@conucleus/uvp-core-node");
    // <uvp-core>/crates/uvp-node/index.cjs -> <uvp-core> (same two-level walk
    // as uvp-node build.rs when it resolves the workspace root).
    const workspaceRoot = resolve(dirname(entry), "../..");
    const result = spawnSync("git", ["-C", workspaceRoot, "rev-parse", "HEAD"], {
      encoding: "utf8",
    });
    if (result.status !== 0 || result.error) {
      return undefined;
    }
    const head = result.stdout.trim();
    return head.length > 0 ? head : undefined;
  } catch {
    return undefined;
  }
}

function sameRev(fingerprintRev: string, head: string): boolean {
  // hermetic builds may burn a short rev via UVP_FFI_GIT_REV; accept prefix
  // equivalence either way instead of demanding full 40-hex equality.
  return (
    fingerprintRev === head ||
    head.startsWith(fingerprintRev) ||
    fingerprintRev.startsWith(head)
  );
}

export interface UvpCoreCompatibility {
  readonly coreVersion: string;
  readonly semanticVersion: string;
  readonly buildFingerprint?: string;
}

export function uvpCoreCompatibility(): UvpCoreCompatibility {
  const coreVersion = version();
  const runtimeSemanticVersion = semanticVersion();
  if (coreVersion !== EXPECTED_UVP_CORE_VERSION || runtimeSemanticVersion !== EXPECTED_UVP_SEMANTIC_VERSION) {
    throw new Error(
      `incompatible uvp-core: expected ${EXPECTED_UVP_CORE_VERSION}/${EXPECTED_UVP_SEMANTIC_VERSION}, ` +
      `received ${coreVersion}/${runtimeSemanticVersion}`
    );
  }
  const buildFingerprint = uvpCoreBuildFingerprint();
  if (buildFingerprint === undefined) {
    // 与 Go 桥同场景硬失败：旧版 @conucleus/uvp-core-node 未导出
    // buildFingerprint 时，版本/语义探针可能双双通过而 dylib 行为已变
    // ——静默跳过等于拆除陈旧产物防线（napi 打包产物的 JS 包装必须
    // re-export buildFingerprint，见 uvp-node index.cjs）。
    throw new Error(
      "incompatible uvp-core: the loaded native module does not export buildFingerprint; " +
        "the stale-build fingerprint gate cannot run — update/rebuild @conucleus/uvp-core-node so the gate is live",
    );
  }
  if (buildFingerprint.startsWith("no-git-")) {
    // uvp-node build.rs contract: `no-git-` means the dylib was built outside
    // a git checkout, so its provenance is unknowable — refuse instead of
    // silently passing.
    throw new Error(
      `incompatible uvp-core: native build fingerprint ${buildFingerprint} has no git provenance; ` +
      "rebuild the native module from a git checkout of uvp-core"
    );
  }
  const fingerprintRev = buildFingerprint.replace(/^git-/, "");
  const head = checkedOutUvpCoreHead();
  if (head !== undefined && !sameRev(fingerprintRev, head)) {
    throw new Error(
      `stale uvp-core native module: build fingerprint ${buildFingerprint} ` +
      `does not match the checked-out uvp-core HEAD ${head}; ` +
      "rebuild with `pnpm --filter @conucleus/uvp-core-node build`"
    );
  }
  return {
    coreVersion,
    semanticVersion: runtimeSemanticVersion,
    buildFingerprint,
  };
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

/**
 * Every wrapped call re-checks the live native module versions. The check is
 * cheap enough that a swapped or rebuilt native module inside a long-lived
 * process cannot silently bypass the compatibility gate.
 */
function ensureCompatible(): void {
  uvpCoreCompatibility();
}
