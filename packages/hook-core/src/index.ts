export {
  HookExpressionError,
  evaluateHook,
  extractHookDependencies,
  normalizeHookExpression,
  parseHookExpression,
  signalKey
} from "./semantics.js";

export {
  compileWithUvpCore,
  evaluateHookWithUvpCore,
  EXPECTED_UVP_CORE_VERSION,
  EXPECTED_UVP_SEMANTIC_VERSION,
  parseHookWithUvpCore,
  replayWithUvpCore,
  uvpCoreCompatibility
} from "./core.js";

export * from "./types.js";
