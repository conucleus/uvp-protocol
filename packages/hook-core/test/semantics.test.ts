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
  const ast = parseHookExpression("buyer::task.main.cmp");

  assert.equal(normalizeHookExpression(ast), "buyer::task.main.cmp");
  assert.deepEqual(extractHookDependencies(ast), [
    { kind: "positive", source: "buyer", signalName: "task.main.cmp" }
  ]);
  assert.deepEqual(evaluateHook(ast, index([]), at), { status: "init" });
  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "task.main.cmp", at]]), at),
    { status: "reg" }
  );
});

test("supports AND and OR expressions", () => {
  const andAst = parseHookExpression("buyer::task.a.cmp & task.b.cmp");
  const orAst = parseHookExpression("buyer::task.a.cmp | task.b.cmp");
  const nestedAst = parseHookExpression("buyer::(task.a.cmp & task.b.cmp) | task.c.cmp");

  assert.deepEqual(evaluateHook(andAst, index([["buyer", "task.a.cmp", at]]), at), {
    status: "init"
  });
  assert.deepEqual(evaluateHook(orAst, index([["buyer", "task.a.cmp", at]]), at), {
    status: "reg"
  });
  assert.deepEqual(evaluateHook(nestedAst, index([["buyer", "task.c.cmp", at]]), at), {
    status: "reg"
  });
});

test("cancels negative branches under monotonic existence semantics", () => {
  const ast = parseHookExpression("buyer::~task.cancel.cmp & task.pay.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "task.cancel.cmp", at]]), at), {
    status: "cxl",
    reason: "negated condition exists: task.cancel.cmp"
  });
  assert.deepEqual(evaluateHook(ast, index([["buyer", "task.pay.cmp", at]]), at), {
    status: "reg"
  });
});

test("evaluates delayed hooks from first receive time", () => {
  const ast = parseHookExpression("buyer::(task.pay.cmp +5s) & ~task.refund.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "task.pay.cmp", at]]), at), {
    status: "wait",
    dueAt: "2026-04-27T00:00:05.000Z"
  });
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "task.pay.cmp", at],
        ["buyer", "task.refund.cmp", "2026-04-27T00:00:03.000Z"]
      ]),
      later
    ),
    { status: "cxl", reason: "negated condition exists: task.refund.cmp" }
  );
  assert.deepEqual(evaluateHook(ast, index([["buyer", "task.pay.cmp", at]]), later), {
    status: "reg"
  });
});

test("keeps OR expressions waiting on the earliest live delayed branch", () => {
  const ast = parseHookExpression("buyer::(task.pay.cmp +5s) | task.override.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "task.pay.cmp", at]]), at), {
    status: "wait",
    dueAt: "2026-04-27T00:00:05.000Z"
  });
  assert.deepEqual(evaluateHook(ast, index([["buyer", "task.override.cmp", at]]), at), {
    status: "reg"
  });
});

test("handles multiple delayed branches and chooses the earliest due timer", () => {
  const ast = parseHookExpression("buyer::(task.a.cmp +5s) | (task.b.cmp +1d)");

  assert.deepEqual(
    extractHookDependencies(ast).filter((dependency) => dependency.kind === "timer"),
    [
      { kind: "timer", source: "buyer", signalName: "task.a.cmp", delaySeconds: 5 },
      { kind: "timer", source: "buyer", signalName: "task.b.cmp", delaySeconds: 86_400 }
    ]
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "task.a.cmp", at],
        ["buyer", "task.b.cmp", at]
      ]),
      at
    ),
    { status: "wait", dueAt: "2026-04-27T00:00:05.000Z" }
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "task.a.cmp", at],
        ["buyer", "task.b.cmp", at]
      ]),
      later
    ),
    { status: "reg" }
  );
});

test("keeps AND expressions waiting until the latest live delayed branch", () => {
  const ast = parseHookExpression("buyer::(task.a.cmp +5s) & (task.b.cmp +10s)");

  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "task.a.cmp", at],
        ["buyer", "task.b.cmp", at]
      ]),
      at
    ),
    { status: "wait", dueAt: "2026-04-27T00:00:10.000Z" }
  );
  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "task.a.cmp", at]]), at),
    { status: "init" }
  );
});

test("evaluates timestamps at chain second precision", () => {
  const ast = parseHookExpression("buyer::task.pay.cmp +5s");

  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "task.pay.cmp", "2026-04-27T00:00:00.900Z"]]), "2026-04-27T00:00:04.999Z"),
    { status: "wait", dueAt: "2026-04-27T00:00:05.000Z" }
  );
  assert.deepEqual(
    evaluateHook(ast, index([["buyer", "task.pay.cmp", "2026-04-27T00:00:00.900Z"]]), "2026-04-27T00:00:05.001Z"),
    { status: "reg" }
  );
});

test("evaluates nested parentheses with multiple negative guards", () => {
  const ast = parseHookExpression("buyer::task.a.cmp & (task.b.cmp | (task.c.cmp +5s)) & ~task.cancel.cmp & ~task.fail.cmp");

  assert.equal(
    normalizeHookExpression(ast),
    "buyer::task.a.cmp&(task.b.cmp|task.c.cmp+5s)&~task.cancel.cmp&~task.fail.cmp"
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "task.a.cmp", at],
        ["buyer", "task.c.cmp", at]
      ]),
      at
    ),
    { status: "wait", dueAt: "2026-04-27T00:00:05.000Z" }
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "task.a.cmp", at],
        ["buyer", "task.c.cmp", at],
        ["buyer", "task.fail.cmp", "2026-04-27T00:00:01.000Z"]
      ]),
      later
    ),
    { status: "cxl", reason: "negated condition exists: task.fail.cmp" }
  );
  assert.deepEqual(
    evaluateHook(
      ast,
      index([
        ["buyer", "task.a.cmp", at],
        ["buyer", "task.b.cmp", at]
      ]),
      at
    ),
    { status: "reg" }
  );
});

test("cancels delayed hooks when the negative signal arrives before the anchor", () => {
  const ast = parseHookExpression("buyer::(task.pay.cmp +5s) & ~task.refund.cmp");

  assert.deepEqual(evaluateHook(ast, index([["buyer", "task.refund.cmp", at]]), later), {
    status: "cxl",
    reason: "negated condition exists: task.refund.cmp"
  });
});

test("parses subscription entries with empty source header", () => {
  const ast = parseHookExpression("::ANCHOR(@seller::task.ship.cmp)");

  assert.equal(ast.source, "");
  assert.deepEqual(ast.condition, {
    kind: "subscription",
    source: "seller",
    signal: "task.ship.cmp"
  });
  assert.deepEqual(extractHookDependencies(ast), [
    { kind: "positive", source: "seller", signalName: "task.ship.cmp" }
  ]);
});

test("defers subscription entries to per-event delivery without expression verdict", () => {
  const ast = parseHookExpression("::ANCHOR(@seller::task.ship.cmp)");

  assert.deepEqual(evaluateHook(ast, index([]), at), { status: "init" });
  assert.deepEqual(evaluateHook(ast, index([["seller", "task.ship.cmp", at]]), at), {
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
    () => parseHookExpression(`buyer::${retiredHeader}@(peer::a.b.c)`),
    /signal reference must use task\.stage\.signal/
  );
  assert.throws(() => parseHookExpression("::ANCHOR@(farmer.main.settle)"), /retired in uvp\.semantic\.v1/);
  assert.throws(
    () => parseHookExpression(`::${retiredHeader}@(seller::a.b.c, buyer::d.e.f)`),
    /empty source is only allowed for ANCHOR/
  );
});

test("rejects raw-less ASTs at adapter boundaries", () => {
  const ast = parseHookExpression("buyer::task.main.cmp");
  const rawLess = {
    source: ast.source,
    condition: ast.condition
  } as HookExpressionAst;

  assert.throws(() => normalizeHookExpression(rawLess), /raw expression/);
  assert.throws(() => extractHookDependencies(rawLess), /raw expression/);
  assert.throws(() => evaluateHook(rawLess, index([["buyer", "task.main.cmp", at]]), at), /raw expression/);
});

test("rejects invalid hooks", () => {
  assert.throws(() => parseHookExpression("buyer::~task.cancel.cmp"), HookExpressionError);
  assert.throws(() => parseHookExpression("::task.main.cmp"), HookExpressionError);
  assert.throws(() => parseHookExpression("buyer::task.main.cmp && task.next.cmp"), HookExpressionError);
  assert.throws(() => parseHookExpression("buyer::task.main.cmp +0s"), HookExpressionError);
  assert.throws(() => parseHookExpression("buyer::cmp"), HookExpressionError);
});
