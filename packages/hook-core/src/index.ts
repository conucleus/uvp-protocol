export {
  HookExpressionError,
  evaluateHook,
  extractHookDependencies,
  normalizeHookExpression,
  parseHookExpression,
  signalKey
} from "./semantics.js";

export {
  analyzeDockWithUvpCore,
  analyzeWithUvpCore,
  evaluateHookWithUvpCore,
  EXPECTED_UVP_CORE_VERSION,
  EXPECTED_UVP_SEMANTIC_VERSION,
  parseHookWithUvpCore,
  replayWithUvpCore,
  uvpCoreBuildFingerprint,
  uvpCoreCompatibility,
  type AnalyzeDockRequest,
  type UvpCoreCompatibility
} from "./core.js";

export {
  ZHIXU_ANALYSIS_SCHEMA_VERSION,
  type ZhixuAnalysis,
  type ZhixuAnalysisExecutor,
  type ZhixuAnalysisHook,
  type ZhixuAnalysisRequest,
  type ZhixuAnalysisSendSignal,
  type ZhixuAnalysisStage
} from "./analysis.js";

export * from "./types.js";
