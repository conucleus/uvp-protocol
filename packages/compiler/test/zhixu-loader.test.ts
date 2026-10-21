import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
  KNOWN_FIELDS,
  loadZhixuDefinition,
  parseZhixuDefinition,
  ZhixuLoadError
} from "../src/index.js";
import { compileZhixuHookPlan } from "../src/hook-plan.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(__dirname, "../fixtures/uvp-update-zhixu-v2.yaml");
const originalFigureFixturePath = join(__dirname, "../fixtures/original-figure-custom-order.yaml");

test("loads UVP update zhixu yaml and compiles stable on-chain plan", async () => {
  const definition = await loadZhixuDefinition(fixturePath);
  const hookPlan = compileZhixuHookPlan(definition);
  const again = compileZhixuHookPlan(definition);
  const onchain = compileZhixuOnchainHookPlan(definition);
  const args = compileZhixuRegisterPlanArgs(definition);

  assert.equal(definition.apiVersion, "uvp/v0");
  assert.equal(definition.kind, "Zhixu");
  assert.equal(definition.metadata.name, "uvp-bootstrap-update-v2");
  assert.equal(definition.spec.platform.type, "blockchain");
  assert.equal(definition.spec.platform.provider, "eth");
  assert.equal(definition.spec.platform.network, "base");
  assert.equal(definition.spec.platform.version, "0.1.3");
  assert.equal(hookPlan.platform.network, "base");
  assert.equal(onchain.platform.network, "base");
  assert.equal(hookPlan.planHash, again.planHash);
  // 身份是内容派生（zx-<32hex>），不是作者手写 uid。
  assert.match(hookPlan.zhixuId, /^zx-[0-9a-f]{32}$/);
  assert.equal(onchain.zhixuId, hookPlan.zhixuId);
  assert.equal(hookPlan.compiledHooks.length, 14);
  assert.equal(onchain.compiledHooks.length, 14);
  assert.equal(args.hooks.length, 14);
  assert.equal(
    onchain.compiledHooks.filter((hook) => hook.stageIdentifier === "rollback").length,
    5
  );
  assert.equal(
    onchain.compiledHooks.some((hook) => hook.stageIdentifier === "init"),
    true
  );
});

test("loads original figure custom order yaml and compiles multi-party plan", async () => {
  const definition = await loadZhixuDefinition(originalFigureFixturePath);
  const hookPlan = compileZhixuHookPlan(definition);
  const onchain = compileZhixuOnchainHookPlan(definition);
  const args = compileZhixuRegisterPlanArgs(definition);

  assert.equal(definition.metadata.name, "original-figure-custom-order");
  assert.match(hookPlan.zhixuId, /^zx-[0-9a-f]{32}$/);
  assert.equal(hookPlan.compiledHooks.length, 16);
  assert.equal(onchain.compiledHooks.length, 16);
  assert.equal(args.hooks.length, 16);
  assert.equal(hookPlan.selectedStageBindings.length, 13);
  assert.ok(
    hookPlan.selectedStageBindings.some(
      (binding) =>
        binding.selectorStageIdentifier === "supplier_selection" &&
        binding.targetStageIdentifier === "sculpt_model"
    )
  );
  assert.ok(
    hookPlan.signalCapabilities.some(
      (capability) =>
        capability.stageIdentifier === "final_acceptance" &&
        capability.targetSource === "client" &&
        capability.targetSignalName === "final_acceptance.pass"
    )
  );
});

test("rejects non-Zhixu yaml at loader boundary", () => {
  assert.throws(
    () => parseZhixuDefinition("apiVersion: uvp/v0\nkind: Supplier\nmetadata:\n  name: no\n", "inline.yaml"),
    ZhixuLoadError
  );
});

test("rejects authored metadata.uid as an unknown field", () => {
  // uid 由系统从定义内容派生（zx-<32hex>），不是作者可写字段；出现即按
  // 未知字段响亮拒绝——锚点与 Rust serde deny_unknown_fields 的
  // "unknown field `uid`" 同口径（constraints 注册表 metadata-uid-not-an-input）。
  assert.throws(
    () =>
      parseZhixuDefinition(
        [
          "apiVersion: uvp/v0",
          "kind: Zhixu",
          "metadata:",
          "  name: uid-probe",
          "  uid: zhixu-uid-probe-v1",
          "spec:",
          "  stages: []"
        ].join("\n"),
        "inline.yaml",
      ),
    (error: unknown) =>
      error instanceof ZhixuLoadError &&
      /unknown field `uid`/.test(error.message) &&
      /derived from content/.test(error.message),
  );
});

test("rejects metadata.name that is not a slug", () => {
  // 文案锚点与 Rust validate_zhixu_shape 的 NAME_SLUG_PATTERN 对齐
  // （constraints 注册表 metadata-name-slug-shape）。
  for (const badName of ["Probe", "1probe", "probe name", "probe/name", ""]) {
    const yaml = [
      "apiVersion: uvp/v0",
      "kind: Zhixu",
      "metadata:",
      `  name: ${JSON.stringify(badName)}`,
      "spec:",
      "  stages: []"
    ].join("\n");
    assert.throws(
      () => parseZhixuDefinition(yaml, "inline.yaml"),
      (error: unknown) =>
        error instanceof ZhixuLoadError &&
        /must match \^\[a-z\]\[a-z0-9_-\]\{0,99\}\$/.test(error.message),
      `name=${JSON.stringify(badName)} must be rejected`,
    );
  }
  // 合法 slug（含中划线/下划线/数字）照常通过。
  assert.doesNotThrow(() =>
    parseZhixuDefinition(
      "apiVersion: uvp/v0\nkind: Zhixu\nmetadata:\n  name: probe_2nd-gen\nspec:\n  stages: []\n",
      "inline.yaml",
    ),
  );
});

test("rejects unknown fields at every structural level", () => {
  // 镜像 uvp_model serde deny_unknown_fields：拼错/不受支持的结构字段都是
  // 确定性非法输入，静默忽略会把"看似生效"的定义落成零值。
  const cases: readonly [string, RegExp][] = [
    [
      "apiVersion: uvp/v0\nkind: Zhixu\nmetadata:\n  name: probe\nextra: 1\nspec:\n  stages: []\n",
      /unknown field `extra` — accepted fields are apiVersion, kind, metadata, spec/,
    ],
    [
      "apiVersion: uvp/v0\nkind: Zhixu\nmetadata:\n  name: probe\n  annotaions: {}\nspec:\n  stages: []\n",
      /metadata: unknown field `annotaions` — accepted fields are name, labels, annotations/,
    ],
    [
      "apiVersion: uvp/v0\nkind: Zhixu\nmetadata:\n  name: probe\nspec:\n  stages: []\n  platfrom: {type: cloud}\n",
      /spec: unknown field `platfrom` — accepted fields are platform, nucleation, stages, dockInterface/,
    ],
    [
      [
        "apiVersion: uvp/v0",
        "kind: Zhixu",
        "metadata:",
        "  name: probe",
        "spec:",
        "  platform: {type: cloud}",
        "  nucleation: {id: core}",
        "  stages:",
        "    - name: work",
        "      source: buyer",
        "      delaiy: 5",
      ].join("\n"),
      /stages\[0\]: unknown field `delaiy`/,
    ],
    [
      [
        "apiVersion: uvp/v0",
        "kind: Zhixu",
        "metadata:",
        "  name: probe",
        "spec:",
        "  platform: {type: cloud}",
        "  nucleation: {id: core}",
        "  stages:",
        "    - name: work",
        "      source: buyer",
        "      executor:",
        "            supplierType: organization",
        "            supplierID: org-1",
        "            suplierID: org-1",
      ].join("\n"),
      /executor: unknown field `suplierID` — accepted fields are supplierType, supplierID, zhixuExecutorConfig, selectableResource/,
    ],
    [
      [
        "apiVersion: uvp/v0",
        "kind: Zhixu",
        "metadata:",
        "  name: probe",
        "spec:",
        "  platform: {type: cloud}",
        "  nucleation: {id: core}",
        "  stages: []",
        "  dockInterface:",
        "    svc:",
        "      orderModes: [new]",
        "      inputs:",
        "        execute: {hook: work#RUN, extra: 1}",
      ].join("\n"),
      /inputs\[execute\]: unknown field `extra` — accepted fields are hook/,
    ],
  ];
  for (const [yaml, anchor] of cases) {
    assert.throws(
      () => parseZhixuDefinition(yaml, "inline.yaml"),
      (error: unknown) =>
        error instanceof ZhixuLoadError && anchor.test(error.message),
      `未知字段必须被拒绝：${yaml.split("\n").find((line) => /extra|delaiy|suplier|annotaions|platfrom/.test(line)) ?? yaml}`,
    );
  }
});

test("rejects non-string values in labels/annotations/params/receiveSignals (serde BTreeMap<String,String> face)", () => {
  // 值面镜像 uvp_model 的 BTreeMap<String, String>：YAML 裸标量的三轨分叉
  // 形态（010→number、yes→string/go→boolean 等）不允许静默穿越装载边界。
  const head = [
    "apiVersion: uvp/v0",
    "kind: Zhixu",
    "metadata:",
    "  name: probe",
  ].join("\n");
  const cases: readonly [string[], RegExp][] = [
    [
      [head, "  labels:", "    tier: 010", "spec:", "  stages: []"],
      /metadata\.labels\.tier must be a string/,
    ],
    [
      [head, "  annotations:", "    flag: true", "spec:", "  stages: []"],
      /metadata\.annotations\.flag must be a string/,
    ],
    [
      [
        head,
        "spec:",
        "  platform:",
        "    type: cloud",
        "    params:",
        "      replicas: 2",
        "  stages: []",
      ],
      /spec\.platform\.params\.replicas must be a string/,
    ],
    [
      [
        head,
        "spec:",
        "  nucleation:",
        "    id: core",
        "    params:",
        "      channel: 010",
        "  stages: []",
      ],
      /spec\.nucleation\.params\.channel must be a string/,
    ],
    [
      [
        head,
        "spec:",
        "  stages:",
        "    - name: work",
        "      source: buyer",
        "      receiveSignals:",
        '        "work#RUN": 010',
      ],
      /spec\.stages\[0\]\.receiveSignals\.work#RUN must be a string/,
    ],
  ];
  for (const [lines, anchor] of cases) {
    assert.throws(
      () => parseZhixuDefinition(lines.join("\n"), "inline.yaml"),
      (error: unknown) => error instanceof ZhixuLoadError && anchor.test(error.message),
      `非字符串值必须被拒绝：${lines.join("\n")}`,
    );
  }
  // 引号包裹的字符串值照常通过五个值面。
  assert.doesNotThrow(() =>
    parseZhixuDefinition(
      [
        head,
        "  labels:",
        '    tier: "010"',
        "  annotations:",
        '    flag: "yes"',
        "spec:",
        "  platform:",
        "    type: cloud",
        "    params:",
        '      replicas: "2"',
        "  nucleation:",
        "    id: core",
        "    params:",
        '      channel: "on"',
        "  stages:",
        "    - name: work",
        "      source: buyer",
        "      receiveSignals:",
        '        "work#RUN": "order::registered"',
      ].join("\n"),
      "inline.yaml",
    ),
  );
});

test("rejects spec.stages that are missing or malformed (no silent pass-through)", () => {
  // 2609100328 疑点10：loader 声明契约 = 镜像 uvp_model 的 serde 形状面
  // （typed 反序列化对 stages 缺失/非数组、非 map 的 stage 条目响亮失败），
  // 静默 return 会让残缺 pattern 带着"已过 loader 校验"的假象离开本层。
  const head = [
    "apiVersion: uvp/v0",
    "kind: Zhixu",
    "metadata:",
    "  name: loader-probe",
    "spec:",
    "  platform:",
    "    type: cloud",
  ].join("\n");

  assert.throws(
    () =>
      parseZhixuDefinition(
        [head, "  stages: nope"].join("\n"),
        "loader-probe",
      ),
    /spec\.stages must be an array/,
  );
  assert.throws(
    () =>
      parseZhixuDefinition(
        [head, "  stages:", "    - plain-string"].join("\n"),
        "loader-probe",
      ),
    /spec\.stages\[0\] must be an object/,
  );
});

/**
 * 定义结构体字段闭集的跨语言钉死（TS 线）：与 uvp-core 仓
 * `crates/uvp-model/tests/field_set_parity.rs`、miniprogram 仓
 * `uvp-utils/api/core/v0` 的 json tag 反射测试对同一份
 * `uvp-core/fixtures/closed-sets/fields.v1.json` 做逐元素相等比对——
 * KNOWN_FIELDS 是装载边未知字段拒绝的唯一词表，任一侧增删字段都会让
 * 至少一侧的测试报警。语料文件由 uvp-core 仓持有（跨仓相对 URL 消费，
 * 与 semantics-corpus.test.ts 同范式）。
 */
test("KNOWN_FIELDS match the shared uvp-core field-set corpus", () => {
  const fieldsUrl = new URL(
    "../../../../uvp-core/fixtures/closed-sets/fields.v1.json",
    import.meta.url,
  );
  const corpus = JSON.parse(readFileSync(fieldsUrl, "utf8")) as {
    readonly schemaVersion: string;
    readonly [group: string]: unknown;
  };
  assert.equal(corpus.schemaVersion, "uvp.fieldSets.v1");

  // 键集钉死在 KNOWN_FIELDS 的字面类型上：group 以 keyof 索引，闭集
  // 分组漂移（增删结构体）继续由 deepEqual 报警，类型面不再依赖 string 索引。
  const groups = Object.keys(KNOWN_FIELDS) as (keyof typeof KNOWN_FIELDS)[];
  assert.deepEqual(
    [...groups].sort(),
    Object.keys(corpus).filter((key) => key !== "schemaVersion" && key !== "note").sort(),
    "KNOWN_FIELDS 分组与语料分组分叉：增删结构体必须同改两侧",
  );
  for (const group of groups) {
    assert.deepEqual(
      [...KNOWN_FIELDS[group]],
      corpus[group] as readonly string[],
      `${group}: 字段闭集与钉死语料分叉`,
    );
    // 闭集是集合语义：重复成员会掩盖"集合同源"的比对。
    assert.equal(new Set(KNOWN_FIELDS[group]).size, KNOWN_FIELDS[group].length, group);
  }
});
