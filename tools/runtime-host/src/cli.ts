#!/usr/bin/env node
import { pathToFileURL } from "node:url";
import { Command } from "commander";
import { createHttpRuntimeDispatcher } from "./http-dispatcher.js";
import { RuntimeHost } from "./runtime-host.js";
import { DEFAULT_RUNTIME_TOKEN_ENV, startRuntimeHostServer } from "./server.js";

interface ServeOptions {
  readonly host: string;
  readonly port: string;
  readonly runtimeToken?: string;
  readonly runtimeTokenEnv: string;
  readonly executorUrl?: string;
  readonly executorToken?: string;
  readonly executorTokenEnv: string;
  readonly callbackUrl?: string;
  readonly publicHost: string;
  readonly eventIdPrefix: string;
  readonly readyJson?: boolean;
}

const DEFAULT_EXECUTOR_TOKEN_ENV = "UVP_EXECUTOR_TOKEN";

export function buildProgram(): Command {
  const program = new Command();
  program
    .name("uvp-runtime-host")
    .description("UVP HookPlan runtime host")
    .version("0.1.0");

  program
    .command("serve")
    .description("start a local runtime-host HTTP server")
    .option("--host <host>", "host to bind", "127.0.0.1")
    .option("--port <port>", "port to bind", "0")
    .option("--runtime-token <token>", "bearer token for runtime-host API")
    .option("--runtime-token-env <name>", "env var containing runtime-host bearer token", DEFAULT_RUNTIME_TOKEN_ENV)
    .option("--executor-url <url>", "executor-kit server base URL")
    .option("--executor-token <token>", "bearer token for executor-kit dispatch API")
    .option("--executor-token-env <name>", "env var containing executor-kit bearer token", DEFAULT_EXECUTOR_TOKEN_ENV)
    .option("--callback-url <url>", "public runtime-host signal callback URL")
    .option("--public-host <host>", "host used when computing callback URL for port 0", "127.0.0.1")
    .option("--event-id-prefix <prefix>", "event id prefix", "runtime-host")
    .option("--ready-json", "print a ready JSON line after the server starts")
    .action(async (options: ServeOptions) => {
      await serve(options);
    });

  return program;
}

export async function serve(options: ServeOptions): Promise<void> {
  const runtimeToken = readSecret(options.runtimeToken, options.runtimeTokenEnv, "runtime token");
  let callbackUrl = options.callbackUrl ?? "";
  const dispatcher = options.executorUrl
    ? createHttpRuntimeDispatcher({
        executorUrl: options.executorUrl,
        executorToken: readSecret(options.executorToken, options.executorTokenEnv, "executor token"),
        callbackUrl: () => callbackUrl
      })
    : undefined;

  const runtimeHost = await RuntimeHost.create({
    ...(dispatcher ? { dispatcher } : {}),
    eventIdPrefix: options.eventIdPrefix
  });
  const handle = await startRuntimeHostServer({
    runtimeHost,
    token: runtimeToken,
    host: options.host,
    port: parsePort(options.port)
  });
  callbackUrl = options.callbackUrl ?? `${handle.url.replace(options.host, options.publicHost)}/v0/signals`;

  if (options.readyJson) {
    console.log(JSON.stringify({
      ready: {
        service: "runtime-host",
        url: handle.url,
        callbackUrl,
        eventIdPrefix: options.eventIdPrefix
      }
    }));
  }

  await waitForShutdown(() => handle.close());
}

export async function main(argv = process.argv): Promise<void> {
  const runtime = argv[0] ?? "node";
  const script = argv[1] ?? "uvp-runtime-host";
  const normalizedArgv = argv.length > 2 && argv[2] === "--"
    ? [runtime, script, ...argv.slice(3)]
    : argv;
  await buildProgram().parseAsync(normalizedArgv);
}

function readSecret(value: string | undefined, envName: string, label: string): string {
  const secret = value ?? process.env[envName];
  if (!secret || secret.trim().length === 0) {
    throw new Error(`missing ${label}: pass --${label.replaceAll(" ", "-")} or set ${envName}`);
  }
  return secret;
}

function parsePort(value: string): number {
  if (!/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error("port must be a non-negative integer");
  }
  const port = Number(value);
  if (!Number.isSafeInteger(port) || port < 0 || port > 65_535) {
    throw new Error("port must be between 0 and 65535");
  }
  return port;
}

function waitForShutdown(close: () => Promise<void>): Promise<void> {
  return new Promise((resolve, reject) => {
    const shutdown = (): void => {
      close().then(resolve, reject);
    };
    process.once("SIGINT", shutdown);
    process.once("SIGTERM", shutdown);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
