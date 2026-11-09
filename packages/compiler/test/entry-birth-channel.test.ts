import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  capabilitiesRootOf,
  compileZhixuHookPlan,
  compileZhixuOnchainHookPlan,
  compileZhixuRegisterPlanArgs,
  hashOnchainPlanPayload,
  HOOK_FLAG_EMIT_READY,
  HOOK_FLAG_ORDER_TRIGGER_MINT,
  onchainHookId,
  onchainSignalId,
  onchainSignalKey,
  onchainSourceId,
  onchainStageId,
  parseZhixuDefinition,
  validateOnchainHookPlanArtifact,
  type OnchainHookPlanArtifact,
  type ZhixuDefinition,
} from "../src/index.js";

/**
 * 隐式 entry 出生通道的链轨产物契约：entry stage 的 order-trigger hook 形状、
 * artifact birthChannel（entry/mint/dock）派生与边界重算，以及 birthChannel
 * 不进入 planHash 承诺面的口径。
 */

const ENTRY_ISSUE =
  "birthChannel must be entry — derived from the plan's first order-trigger hook and its positive birth dependency; an entry birth is the stage's own <stageIdentifier>.str fact, every other order trigger keeps its mint/dock channel";
const OMITTED_ISSUE =
  "birthChannel must be omitted when the plan declares no order-trigger hook (there is no birth line to describe)";

const ENTRY_YAML = `apiVersion: uvp/v0
kind: Zhixu
metadata:
  name: entry-birth
spec:
  platform:
    type: blockchain
    provider: eth
    network: base
  nucleation:
    id: entry-birth
  stages:
    - name: intake
      source: deal
      sendSignals:
        - name: str
        - name: cmp
      executor:
        supplierType: organization
        supplierID: intake-contract
    - name: configure
      source: deal
      receiveSignals:
        PREV_READY: "deal::intake.cmp"
      sendSignals:
        - name: apply
      executor:
        supplierType: individual
        supplierID: buyer
`;

const FOREIGN_STR_MINT_YAML = `apiVersion: uvp/v0
kind: Zhixu
metadata:
  name: foreign-str-mint
spec:
  platform:
    type: blockchain
    provider: eth
    network: base
  nucleation:
    id: foreign-str-mint
  stages:
    - name: feeder
      source: inbound
      receiveSignals:
        START: "inbound::feeder.seed"
      sendSignals:
        - name: seed
        - name: str
      executor:
        supplierType: organization
        supplierID: feeder-exec
    - name: minted
      source: downstream
      mint: per-fact
      receiveSignals:
        BIRTH: "::ANCHOR(@inbound::feeder.str)"
      sendSignals:
        - name: str
        - name: cmp
      executor:
        supplierType: organization
        supplierID: minted-exec
`;

const entryDefinition = parseZhixuDefinition(ENTRY_YAML, "entry-birth.yaml");

function readFixture(relativePath: string): string {
  return readFileSync(new URL(relativePath, import.meta.url), "utf8");
}

function resign(artifact: OnchainHookPlanArtifact): OnchainHookPlanArtifact {
  const { planHash: _planHash, ...payload } = artifact;
  return { ...payload, planHash: hashOnchainPlanPayload(payload) };
}

test("entry plan compiles one mint birth hook and derives birthChannel entry", () => {
  const plan = compileZhixuHookPlan(entryDefinition);
  assert.deepEqual(
    plan.compiledHooks.map((hook) => `${hook.stageIdentifier}#${hook.hookName}`),
    ["intake#str", "configure#PREV_READY"],
  );
  const sourceEntry = plan.compiledHooks[0]!;
  assert.equal(sourceEntry.hookId, "intake#str");
  assert.equal(sourceEntry.kind, "receive");
  assert.equal(sourceEntry.orderTriggerKind, "mint");
  assert.equal(sourceEntry.emitReady, true);
  assert.equal(sourceEntry.rawExpression, "deal::intake.str");
  assert.equal(sourceEntry.normalizedExpression, "deal::intake.str");
  assert.deepEqual(sourceEntry.ast, {
    raw: "deal::intake.str",
    source: "deal",
    condition: { kind: "signal", signalName: "intake.str" },
  });
  assert.deepEqual(sourceEntry.dependencies, [
    { kind: "positive", source: "deal", signalName: "intake.str" },
  ]);

  const onchain = compileZhixuOnchainHookPlan(entryDefinition);
  assert.equal(onchain.birthChannel, "entry");
  assert.deepEqual(
    onchain.compiledHooks.map((hook) => hook.hookId),
    [onchainHookId("configure", "PREV_READY"), onchainHookId("intake", "str")],
  );
  const entry = onchain.compiledHooks[1]!;
  assert.equal(entry.stageIdentifier, "intake");
  assert.equal(entry.hookName, "str");
  assert.equal(entry.stageId, onchainStageId("intake"));
  assert.equal(entry.orderTriggerKind, "mint");
  assert.equal(entry.emitReady, true);
  const sourceId = onchainSourceId("deal");
  const signalId = onchainSignalId("intake.str");
  const signalKey = onchainSignalKey(sourceId, signalId);
  assert.deepEqual(entry.instructions, [
    {
      op: "SIGNAL",
      source: "deal",
      signalName: "intake.str",
      sourceId,
      signalId,
      signalKey,
    },
  ]);
  assert.deepEqual(entry.dependencies, [
    {
      kind: "positive",
      source: "deal",
      signalName: "intake.str",
      sourceId,
      signalId,
      signalKey,
    },
  ]);
  const route = onchain.executorRoutes.find(
    (candidate) => candidate.stageIdentifier === "intake",
  );
  assert.ok(route, "entry stage must carry a static executor route");
  assert.deepEqual(entry.routeRef, {
    routeId: route.routeId,
    stageId: onchainStageId("intake"),
    routeHash: route.routeHash,
  });

  const args = compileZhixuRegisterPlanArgs(entryDefinition);
  const registered = args.hooks.find(
    (candidate) => candidate.hookId === entry.hookId,
  );
  assert.ok(registered, "entry hook must reach the Solidity registration args");
  assert.equal(
    registered.flags,
    HOOK_FLAG_ORDER_TRIGGER_MINT | HOOK_FLAG_EMIT_READY,
  );
  assert.deepEqual(registered.dependencyKeys, [signalKey]);
  assert.equal(registered.routeId, route.routeId);

  assert.deepEqual(validateOnchainHookPlanArtifact(onchain), []);
});

test("birthChannel is derived, not committed, and enforced at the artifact boundary", () => {
  const onchain = compileZhixuOnchainHookPlan(entryDefinition);
  const { planHash: _planHash, ...payload } = onchain;
  assert.equal(hashOnchainPlanPayload(payload), onchain.planHash);

  assert.deepEqual(
    validateOnchainHookPlanArtifact({ ...onchain, birthChannel: "mint" }),
    [ENTRY_ISSUE],
  );
  const missing = { ...onchain } as Record<string, unknown>;
  delete missing.birthChannel;
  assert.deepEqual(validateOnchainHookPlanArtifact(missing), [ENTRY_ISSUE]);

  const triggerless = resign({
    ...onchain,
    compiledHooks: onchain.compiledHooks.map((hook) =>
      hook.orderTriggerKind === "none"
        ? hook
        : { ...hook, orderTriggerKind: "none" as const },
    ),
  });
  assert.deepEqual(validateOnchainHookPlanArtifact(triggerless), [OMITTED_ISSUE]);

  const capabilityFree = resign({
    ...onchain,
    signalCapabilities: [],
    selectorBindings: [],
    capabilitiesRoot: capabilitiesRootOf([], []),
  });
  assert.equal(capabilityFree.birthChannel, "entry");
  assert.deepEqual(validateOnchainHookPlanArtifact(capabilityFree), []);
});

test("mint and dock plans keep their birth channel", () => {
  const update = parseZhixuDefinition(
    readFixture("../fixtures/uvp-update-zhixu-v2.yaml"),
    "uvp-update-zhixu-v2.yaml",
  );
  const mint = compileZhixuOnchainHookPlan(update);
  assert.equal(mint.birthChannel, "mint");
  assert.equal(
    mint.planHash,
    "0x106c608a9a2ed4b34429522e7777a20299e039e1475aed7756cda8c5dba9edb8",
  );
  assert.deepEqual(validateOnchainHookPlanArtifact(mint), []);

  const dockFixture = JSON.parse(readFixture("../fixtures/dock/v1/manifest.json")) as {
    readonly targetDefinition: ZhixuDefinition;
  };
  const dock = compileZhixuOnchainHookPlan(dockFixture.targetDefinition);
  assert.equal(dock.birthChannel, "dock");
  assert.deepEqual(validateOnchainHookPlanArtifact(dock), []);

  const foreignStrMint = compileZhixuOnchainHookPlan(
    parseZhixuDefinition(FOREIGN_STR_MINT_YAML, "foreign-str-mint.yaml"),
  );
  assert.equal(foreignStrMint.birthChannel, "mint");
  const trigger = foreignStrMint.compiledHooks.find(
    (hook) => hook.orderTriggerKind !== "none",
  );
  assert.ok(trigger, "mint plan must carry its order-trigger hook");
  assert.equal(trigger.dependencies[0]?.signalName, "feeder.str");
});
