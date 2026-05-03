import assert from "node:assert/strict";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { compileZhixuHookPlan, type ZhixuDefinition } from "@uvp-eth/compiler";

const runtimeToken = "runtime-process-token";
const executorToken = "executor-process-token";
const t0 = "2026-04-27T00:00:00.000Z";

const zhixu: ZhixuDefinition = {
  apiVersion: "uvp/v0",
  kind: "Zhixu",
  metadata: {
    name: "runtime_process_demo",
    uid: "runtime-process-demo"
  },
  spec: {
    platform: { type: "cloud" },
    nucleation: { id: "core" },
    taskPatterns: [
      {
        name: "init",
        stages: [
          {
            name: "main",
            source: "buyer",
            trigger: ["TRIGGER"],
            receiveSignals: { TRIGGER: "::OUTSIDE" },
            sendSignals: ["cmp"],
            executor: { supplierType: "organization", supplierID: "init-executor" }
          }
        ]
      },
      {
        name: "exec",
        stages: [
          {
            name: "main",
            source: "buyer",
            trigger: ["START"],
            receiveSignals: {
              START: "buyer::init.main.cmp",
              TIMEOUT: "buyer::(init.main.cmp +5s) & ~exec.main.cmp"
            },
            sendSignals: ["cmp"],
            executor: { supplierType: "organization", supplierID: "exec-executor" }
          }
        ]
      }
    ]
  }
};

const plan = compileZhixuHookPlan(zhixu);
type ServerProcess = ChildProcessByStdio<null, Readable, Readable>;

test("runs a process-level runtime-host to executor-kit callback flow", { timeout: 30_000 }, async () => {
  const repoRoot = resolve(fileURLToPath(new URL("../../../..", import.meta.url)));
  const executorCli = join(repoRoot, "uvp-executor-kit/package/src/cli.ts");
  const runtimeCli = join(repoRoot, "uvp-protocol/tools/runtime-host/src/cli.ts");
  const tempDir = await mkdtemp(join(tmpdir(), "uvp-process-e2e-"));
  const executorConfig = join(tempDir, "executor.json");
  const children: ServerProcess[] = [];
  try {
    await writeFile(executorConfig, JSON.stringify({
      executorId: "exec-executor",
      handlers: {
        "exec.main#START": {
          source: "buyer",
          stageIdentifier: "exec.main",
          signalName: "exec.main.cmp",
          receivedAt: "2026-04-27T00:00:03.000Z"
        }
      }
    }));

    const executor = spawnCli(repoRoot, executorCli, [
      "serve",
      "--config",
      executorConfig,
      "--port",
      "0",
      "--executor-token",
      executorToken,
      "--runtime-token",
      runtimeToken,
      "--ready-json"
    ]);
    children.push(executor);
    const executorReady = await waitForReady(executor, "executor");

    const runtime = spawnCli(repoRoot, runtimeCli, [
      "serve",
      "--port",
      "0",
      "--runtime-token",
      runtimeToken,
      "--executor-url",
      executorReady.url,
      "--executor-token",
      executorToken,
      "--ready-json"
    ]);
    children.push(runtime);
    const runtimeReady = await waitForReady(runtime, "runtime");

    await postRuntime(runtimeReady.url, "/v0/plans", { plan });
    await postRuntime(runtimeReady.url, "/v0/orders", {
      order: {
        planId: plan.planId,
        zhixuId: plan.zhixuId,
        orderId: "order-1",
        receivedAt: t0
      }
    });
    await postRuntime(runtimeReady.url, "/v0/signals", {
      signal: {
        zhixuId: plan.zhixuId,
        orderId: "order-1",
        source: "buyer",
        stageIdentifier: "init.main",
        signalName: "init.main.cmp",
        senderId: "init-executor",
        receivedAt: t0
      }
    });
    const drain = await postRuntime(runtimeReady.url, "/v0/dispatch/drain", {});
    assert.equal((drain.events as Array<{ type: string }>)[0]?.type, "DispatchSucceeded");

    await eventually(async () => {
      const state = await getRuntimeState(runtimeReady.url);
      const order = state.state.orders[`${plan.zhixuId}::order-1`];
      assert.equal(order?.signals["buyer::exec.main.cmp"]?.senderId, "exec-executor");
      assert.equal(order?.hookStatuses["exec.main#START"]?.status, "dispatched");
      assert.equal(order?.hookStatuses["exec.main#TIMEOUT"]?.status, "cxl");
    });
  } finally {
    await Promise.all(children.map((child) => stopChild(child)));
    await rm(tempDir, { recursive: true, force: true });
  }
});

function spawnCli(root: string, script: string, args: readonly string[]): ServerProcess {
  return spawn(process.execPath, ["--import", "tsx", script, ...args], {
    cwd: root,
    env: {
      ...process.env,
      FORCE_COLOR: "0"
    },
    stdio: ["ignore", "pipe", "pipe"] as const
  });
}

function waitForReady(child: ServerProcess, label: string): Promise<{ readonly url: string }> {
  return new Promise((resolveReady, rejectReady) => {
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      rejectReady(new Error(`${label} did not become ready. stdout=${stdout} stderr=${stderr}`));
    }, 12_000);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      for (const line of stdout.split(/\r?\n/)) {
        if (!line.trim().startsWith("{")) {
          continue;
        }
        try {
          const parsed = JSON.parse(line) as { ready?: { url?: string } };
          if (parsed.ready?.url) {
            clearTimeout(timeout);
            resolveReady({ url: parsed.ready.url });
          }
        } catch {
          // Ignore non-ready JSON lines.
        }
      }
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.once("exit", (code) => {
      clearTimeout(timeout);
      rejectReady(new Error(`${label} exited before ready with ${code}. stdout=${stdout} stderr=${stderr}`));
    });
  });
}

async function postRuntime(baseUrl: string, path: string, body: unknown): Promise<Record<string, unknown>> {
  const response = await fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${runtimeToken}`,
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });
  const json = await response.json() as Record<string, unknown>;
  assert.ok(response.ok, JSON.stringify(json));
  return json;
}

async function getRuntimeState(baseUrl: string): Promise<{
  readonly state: {
    readonly orders: Record<string, {
      readonly signals: Record<string, { readonly senderId: string }>;
      readonly hookStatuses: Record<string, { readonly status: string }>;
    }>;
  };
}> {
  const response = await fetch(`${baseUrl}/v0/state`, {
    headers: { authorization: `Bearer ${runtimeToken}` }
  });
  assert.equal(response.status, 200);
  return await response.json() as Awaited<ReturnType<typeof getRuntimeState>>;
}

async function eventually(assertion: () => Promise<void>, timeoutMs = 5_000): Promise<void> {
  const started = Date.now();
  let lastError: unknown;
  while (Date.now() - started < timeoutMs) {
    try {
      await assertion();
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

async function stopChild(child: ServerProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  child.kill("SIGTERM");
  await new Promise<void>((resolve) => {
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      resolve();
    }, 2_000);
    child.once("exit", () => {
      clearTimeout(timeout);
      resolve();
    });
  });
}
