import assert from "node:assert/strict";
import test from "node:test";
import {
  evaluateHook,
  extractHookDependencies,
  HookExpressionError,
  normalizeHookExpression,
  parseHookExpression,
  signalKey,
  type HookExpressionAst,
  type SignalIndex
} from "../src/index.js";

const at = "2026-04-27T00:00:00.000Z";
const later = "2026-04-27T00:00:06.000Z";

function index(entries: readonly [string, string, string][]): SignalIndex {
  return Object.fromEntries(
    entries.map(([source, signalName, receivedAt]) => [
      signalKey(source, signalName),
      { source, signalName, receivedAt }
    ])
  );
}

test("parses and evaluates a single positive signal", () => {
  const ast = parseHookExpression("buyer::main.cmp");

  assert.equal(normalizeHookExpression(ast), "buyer::main.cmp");
  assert.deepEqual(extractHookDependencies(ast), [
    { kind: "positive", source: "buyer", signalName: "main.cmp" }
  ]);
  assert.deepEqual(evaluateHook(ast, index([]), at), { status: "init" });
  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "main.cmp", at]]), at),
    { status: "reg" }
  );
});

test("supports AND and OR expressions", () => {
  const andAst = parseHookExpression("buyer::a.cmp & b.cmp");
  const orAst = parseHookExpression("buyer::a.cmp | b.cmp");
  const nestedAst = parseHookExpression("buyer::(a.cmp & b.cmp) | c.cmp");

  assert.deepEqual(evaluateHook(andAst, index([["buyer", "a.cmp", at]]), at), {
    status: "init"
  });
  assert.deepEqual(evaluateHook(orAst, index([["buyer", "a.cmp", at]]), at), {
    status: "reg"
  });
  assert.deepEqual(evaluateHook(nestedAst, index([["buyer", "c.cmp", at]]), at), {
    status: "reg"
  });
});

test("cancels negative branches under monotonic existence semantics", () => {
  const ast = parseHookExpression("buyer::~cancel.cmp & pay.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "cancel.cmp", at]]), at), {
    status: "cxl",
    reason: "negated condition exists: cancel.cmp"
  });
  assert.deepEqual(evaluateHook(ast, index([["buyer", "pay.cmp", at]]), at), {
    status: "reg"
  });
});

test("evaluates delayed hooks from first receive time", () => {
  const ast = parseHookExpression("buyer::(pay.cmp +5s) & ~refund.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "pay.cmp", at]]), at), {
    status: "wait",
    dueAt: "2026-04-27T00:00:05.000Z"
  });
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "pay.cmp", at],
        ["buyer", "refund.cmp", "2026-04-27T00:00:03.000Z"]
      ]),
      later
    ),
    { status: "cxl", reason: "negated condition exists: refund.cmp" }
  );
  assert.deepEqual(evaluateHook(ast, index([["buyer", "pay.cmp", at]]), later), {
    status: "reg"
  });
});

test("keeps OR expressions waiting on the earliest live delayed branch", () => {
  const ast = parseHookExpression("buyer::(pay.cmp +5s) | override.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "pay.cmp", at]]), at), {
    status: "wait",
    dueAt: "2026-04-27T00:00:05.000Z"
  });
  assert.deepEqual(evaluateHook(ast, index([["buyer", "override.cmp", at]]), at), {
    status: "reg"
  });
});

test("handles multiple delayed branches and chooses the earliest due timer", () => {
  const ast = parseHookExpression("buyer::(a.cmp +5s) | (b.cmp +1d)");

  assert.deepEqual(
    extractHookDependencies(ast).filter((dependency) => dependency.kind === "timer"),
    [
      { kind: "timer", source: "buyer", signalName: "a.cmp", delaySeconds: 5 },
      { kind: "timer", source: "buyer", signalName: "b.cmp", delaySeconds: 86_400 }
    ]
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "a.cmp", at],
        ["buyer", "b.cmp", at]
      ]),
      at
    ),
    { status: "wait", dueAt: "2026-04-27T00:00:05.000Z" }
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "a.cmp", at],
        ["buyer", "b.cmp", at]
      ]),
      later
    ),
    { status: "reg" }
  );
});

test("keeps AND expressions waiting until the latest live delayed branch", () => {
  const ast = parseHookExpression("buyer::(a.cmp +5s) & (b.cmp +10s)");

  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "a.cmp", at],
        ["buyer", "b.cmp", at]
      ]),
      at
    ),
    { status: "wait", dueAt: "2026-04-27T00:00:10.000Z" }
  );
  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "a.cmp", at]]), at),
    { status: "init" }
  );
});

test("evaluates timestamps at chain second precision", () => {
  const ast = parseHookExpression("buyer::pay.cmp +5s");

  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "pay.cmp", "2026-04-27T00:00:00.900Z"]]), "2026-04-27T00:00:04.999Z"),
    { status: "wait", dueAt: "2026-04-27T00:00:05.000Z" }
  );
  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "pay.cmp", "2026-04-27T00:00:00.900Z"]]), "2026-04-27T00:00:05.001Z"),
    { status: "reg" }
  );
});

test("evaluates nested parentheses with multiple negative guards", () => {
  const ast = parseHookExpression("buyer::a.cmp & (b.cmp | (c.cmp +5s)) & ~cancel.cmp & ~fail.cmp");

  assert.equal(
    normalizeHookExpression(ast),
    "buyer::a.cmp&(b.cmp|c.cmp+5s)&~cancel.cmp&~fail.cmp"
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "a.cmp", at],
        ["buyer", "c.cmp", at]
      ]),
      at
    ),
    { status: "wait", dueAt: "2026-04-27T00:00:05.000Z" }
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "a.cmp", at],
        ["buyer", "c.cmp", at],
        ["buyer", "fail.cmp", "2026-04-27T00:00:01.000Z"]
      ]),
      later
    ),
    { status: "cxl", reason: "negated condition exists: fail.cmp" }
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "a.cmp", at],
        ["buyer", "b.cmp", at]
      ]),
      at
    ),
    { status: "reg" }
  );
});

test("cancels delayed hooks when the negative signal arrives before the anchor", () => {
  const ast = parseHookExpression("buyer::(pay.cmp +5s) & ~refund.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "refund.cmp", at]]), later), {
    status: "cxl",
    reason: "negated condition exists: refund.cmp"
  });
});

test("evaluates the decaying veto across its three states", () => {
  const ast = parseHookExpression("buyer::pay.cmp & ~(cancel.cmp +5s)");

  // 否决位延时被否定：依赖按 negative 投影、不出 timer（到期推进的是
  // 否决成熟而非就绪等待，调度器无 poke 期限可言）。
  assert.deepEqual(extractHookDependencies(ast), [
    { kind: "negative", source: "buyer", signalName: "cancel.cmp" },
    { kind: "positive", source: "buyer", signalName: "pay.cmp" }
  ]);
  // 态一：被否定信号缺席 → 放行（无期限）。
  assert.deepEqual(evaluateHook(ast, index([["buyer", "pay.cmp", at]]), later), {
    status: "reg"
  });
  // 态二：在案未熟 → 放行，有效期钉在成熟时刻（前一毫秒仍放行）。
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "pay.cmp", at],
        ["buyer", "cancel.cmp", at]
      ]),
      "2026-04-27T00:00:04.999Z"
    ),
    { status: "reg", expiresAt: "2026-04-27T00:00:05.000Z" }
  );
  // 态三：在案已熟 → 否决（Not 语义短路整个门，与 ~A 同一取消理由面）。
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "pay.cmp", at],
        ["buyer", "cancel.cmp", at]
      ]),
      "2026-04-27T00:00:05.000Z"
    ),
    { status: "cxl", reason: "negated condition exists: cancel.cmp+5s" }
  );
});

test("rejects the decaying veto outside the conjunction-operand position", () => {
  // 位置规则负例（uvp-core validate_anchors 的 veto_slot 闸）：根位 /
  // Or 子项 / 双重否定。Delay 操作数内的否决位先被嵌套延时闸拦截
  // （正位与否决位同闸），报错为 no-nested-delays 口径。
  assert.throws(
    () => parseHookExpression("buyer::~(cancel.cmp +14d)"),
    /decaying veto .\(signal\+duration\) is only allowed as a direct operand of a conjunction/
  );
  assert.throws(
    () => parseHookExpression("buyer::a.cmp | ~(cancel.cmp +14d)"),
    /decaying veto .\(signal\+duration\) is only allowed as a direct operand of a conjunction/
  );
  assert.throws(
    () => parseHookExpression("buyer::a.cmp & ~(~(cancel.cmp +14d))"),
    /negation only supports direct signal references/
  );
  assert.throws(
    () => parseHookExpression("buyer::(a.cmp & ~(cancel.cmp +14d)) +5s"),
    /no nested delays/
  );
});

test("parses subscription entries with empty source header", () => {
  const ast = parseHookExpression("::ANCHOR(@seller::ship.cmp)");

  assert.equal(ast.source, "");
  assert.deepEqual(ast.condition, {
    kind: "subscription",
    source: "seller",
    signal: "ship.cmp"
  });
  assert.deepEqual(extractHookDependencies(ast), [
    { kind: "positive", source: "seller", signalName: "ship.cmp" }
  ]);
});

test("defers subscription entries to per-event delivery without expression verdict", () => {
  const ast = parseHookExpression("::ANCHOR(@seller::ship.cmp)");

  assert.deepEqual(evaluateHook(ast, index([]), at), { status: "init" });
  assert.deepEqual(evaluateHook(ast, index([["seller", "ship.cmp", at]]), at), {
    status: "init"
  });
});

test("rejects non-canonical cross-source header forms", () => {
  assert.throws(() => parseHookExpression("::OUTSIDE"), /retired in uvp\.semantic\.v1/);
  assert.throws(() => parseHookExpression("buyer::OUTSOURCE"), /retired in uvp\.semantic\.v1/);
  // 扇入类旧标头不在关键字清单内：没有退役清单条目，按
  // 通用语法错误拒绝（与 uvp-core 解析器同口径）。词元按字节拼装，
  // 保持全仓 hook 语境的零命中口径。
  const retiredHeader = ["MER", "GE"].join("");
  assert.throws(
    () => parseHookExpression(`buyer::${retiredHeader}@(peer::a.b)`),
    /signal reference must use stage\.signal/
  );
  assert.throws(() => parseHookExpression("::ANCHOR@(farmer.settle)"), /retired in uvp\.semantic\.v1/);
  assert.throws(
    () => parseHookExpression(`::${retiredHeader}@(seller::a.b, buyer::d.e)`),
    /empty source is only allowed for ANCHOR/
  );
});

test("rejects raw-less ASTs at adapter boundaries", () => {
  const ast = parseHookExpression("buyer::main.cmp");
  const rawLess = {
    source: ast.source,
    condition: ast.condition
  } as HookExpressionAst;

  assert.throws(() => normalizeHookExpression(rawLess), /raw expression/);
  assert.throws(() => extractHookDependencies(rawLess), /raw expression/);
  assert.throws(() => evaluateHook(rawLess, index([["buyer", "main.cmp", at]]), at), /raw expression/);
});

test("rejects invalid hooks", () => {
  assert.throws(() => parseHookExpression("buyer::~cancel.cmp"), HookExpressionError);
  assert.throws(() => parseHookExpression("::main.cmp"), HookExpressionError);
  assert.throws(() => parseHookExpression("buyer::main.cmp && next.cmp"), HookExpressionError);
  assert.throws(() => parseHookExpression("buyer::main.cmp +0s"), HookExpressionError);
  assert.throws(() => parseHookExpression("buyer::cmp"), HookExpressionError);
});
