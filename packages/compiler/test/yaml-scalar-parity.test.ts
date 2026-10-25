import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import YAML from "yaml";
import { parseZhixuDefinition, ZhixuLoadError } from "../src/index.js";

const corpusUrl = new URL(
  "../../../../uvp-core/fixtures/yaml/yaml-scalar-parity.v1.json",
  import.meta.url
);

interface TrackExpectation {
  readonly form: "string" | "number" | "boolean" | "null" | "object" | "error";
  readonly value?: unknown;
}

interface ParityCase {
  readonly name: string;
  readonly yaml: string;
  readonly path: string;
  readonly ts: TrackExpectation | null;
}

interface ParityCorpus {
  readonly schemaVersion: string;
  readonly cases: readonly ParityCase[];
}

async function loadCorpus(): Promise<ParityCorpus> {
  const corpus = JSON.parse(await readFile(corpusUrl, "utf8")) as ParityCorpus;
  assert.equal(
    corpus.schemaVersion,
    "uvp.yamlScalarParity.v1",
    "parity corpus schemaVersion drifted; migrate every consumer before shipping the new file"
  );
  return corpus;
}

function scalarForm(value: unknown): string {
  if (value === null) {
    return "null";
  }
  if (Array.isArray(value)) {
    return "array";
  }
  return typeof value;
}

test("yaml bare scalars load to the pinned ts forms and never pass the loader as non-strings", async () => {
  const corpus = await loadCorpus();
  for (const item of corpus.cases) {
    const expectation = item.ts;
    if (expectation === null) {
      continue;
    }
    const loaded = YAML.parse(item.yaml) as Record<string, unknown>;
    const actual = loaded[item.path];
    assert.equal(
      scalarForm(actual),
      expectation.form,
      `${item.name}: ts 装载形态漂移（路径 ${item.path}）`
    );
    if ("value" in expectation) {
      assert.deepEqual(actual, expectation.value, `${item.name}: ts 装载值漂移`);
    }
    const labelsYaml = [
      "apiVersion: uvp/v0",
      "kind: Zhixu",
      "metadata:",
      "  name: parity-probe",
      "  labels:",
      ...item.yaml
        .split("\n")
        .filter((line) => line !== "")
        .map((line) => `    ${line}`),
      "spec:",
      "  stages: []",
    ].join("\n");
    if (expectation.form === "string") {
      const definition = parseZhixuDefinition(labelsYaml, "parity-probe.yaml");
      const labels = definition.metadata.labels as Record<string, unknown>;
      assert.deepEqual(
        labels[item.path],
        actual,
        `${item.name}: 字符串值必须原样通过装载路径`
      );
    } else {
      assert.throws(
        () => parseZhixuDefinition(labelsYaml, "parity-probe.yaml"),
        (error: unknown) =>
          error instanceof ZhixuLoadError && /must be a string/.test(error.message),
        `${item.name}: 非字符串标量必须被装载边界拒绝`
      );
    }
  }
});
