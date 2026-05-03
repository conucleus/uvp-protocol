import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  compileOnchainHookPlan,
  compileZhixuHookPlan,
  loadZhixuDefinition,
  parseZhixuDefinition,
  toSolidityRegisterPlanArgs,
  ZhixuLoadError
} from "../src/index.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(__dirname, "../fixtures/uvp-update-zhixu-v2.yaml");

test("loads UVP update zhixu yaml and compiles stable on-chain plan", async () => {
  const definition = await loadZhixuDefinition(fixturePath);
  const hookPlan = compileZhixuHookPlan(definition);
  const again = compileZhixuHookPlan(definition);
  const onchain = compileOnchainHookPlan(hookPlan);
  const args = toSolidityRegisterPlanArgs(onchain);

  assert.equal(definition.apiVersion, "uvp/v0");
  assert.equal(definition.kind, "Zhixu");
  assert.equal(definition.metadata.name, "uvp-bootstrap-update-v2");
  assert.equal(definition.spec.platform.type, "blockchain");
  assert.equal(definition.spec.platform.provider, "eth");
  assert.equal(definition.spec.platform.version, "0.1.3");
  assert.equal(hookPlan.planHash, again.planHash);
  assert.equal(hookPlan.compiledHooks.length, 9);
  assert.equal(onchain.compiledHooks.length, 9);
  assert.equal(args.hooks.length, 9);
  assert.equal(
    onchain.compiledHooks.find((hook) => hook.stageIdentifier === "update.rollback")?.instructions.at(-1)?.op,
    "OR"
  );
  assert.equal(
    args.hooks.find((hook) => hook.hookId === onchain.compiledHooks.find((item) => item.stageIdentifier === "update.init")?.hookId)?.trigger,
    true
  );
});

test("rejects non-Zhixu yaml at loader boundary", () => {
  assert.throws(
    () => parseZhixuDefinition("apiVersion: uvp/v0\nkind: Supplier\nmetadata:\n  name: no\n", "inline.yaml"),
    ZhixuLoadError
  );
});
