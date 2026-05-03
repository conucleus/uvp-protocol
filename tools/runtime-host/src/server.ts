import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { assertHookPlanArtifact, HookPlanArtifactValidationError } from "@uvp-eth/compiler";
import { RuntimeTransitionError } from "@uvp-eth/statemachine";
import type { RuntimeHost } from "./runtime-host.js";
import { RuntimeHostError } from "./runtime-host.js";
import type { RuntimeOrderRegistration, SignalEnvelope } from "./types.js";

export const DEFAULT_RUNTIME_TOKEN_ENV = "UVP_RUNTIME_TOKEN";

export interface RuntimeHostServerOptions {
  readonly runtimeHost: RuntimeHost;
  readonly token: string;
  readonly host?: string;
  readonly port?: number;
}

export interface RuntimeHostServerHandle {
  readonly server: Server;
  readonly url: string;
  readonly host: string;
  readonly port: number;
  close(): Promise<void>;
}

interface ApiResponse {
  readonly status: number;
  readonly body: unknown;
}

const MAX_BODY_BYTES = 1_000_000;

export async function startRuntimeHostServer(options: RuntimeHostServerOptions): Promise<RuntimeHostServerHandle> {
  const bindHost = options.host ?? "127.0.0.1";
  const port = options.port ?? 0;
  const token = requireNonEmpty(options.token, "token");
  const server = createServer((request, response) => {
    void handleRuntimeHostRequest(options.runtimeHost, token, request, response);
  });

  await new Promise<void>((resolve) => {
    server.listen(port, bindHost, resolve);
  });

  const address = server.address() as AddressInfo;
  const publicHost = address.address === "::" || address.address === "0.0.0.0" ? "127.0.0.1" : address.address;
  const url = `http://${formatHost(publicHost)}:${address.port}`;
  return {
    server,
    url,
    host: publicHost,
    port: address.port,
    close: () => closeServer(server)
  };
}

async function handleRuntimeHostRequest(
  runtimeHost: RuntimeHost,
  token: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> {
  try {
    const apiResponse = await routeRuntimeHostRequest(runtimeHost, token, request);
    writeJson(response, apiResponse.status, apiResponse.body);
  } catch (error) {
    writeJson(response, statusForError(error), {
      error: errorCodeForError(error),
      message: error instanceof Error ? error.message : "unknown error"
    });
  }
}

async function routeRuntimeHostRequest(
  runtimeHost: RuntimeHost,
  token: string,
  request: IncomingMessage
): Promise<ApiResponse> {
  const method = request.method ?? "GET";
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

  if (method === "GET" && url.pathname === "/healthz") {
    return { status: 200, body: { ok: true, service: "runtime-host" } };
  }

  requireBearerToken(request, token);

  if (method === "GET" && url.pathname === "/v0/state") {
    return { status: 200, body: runtimeHost.snapshot() };
  }

  if (method === "GET" && url.pathname === "/v0/events") {
    return { status: 200, body: { events: await runtimeHost.getEvents() } };
  }

  if (method === "POST" && url.pathname === "/v0/plans") {
    const body = await readJsonBody(request);
    const plan = isRecord(body) && "plan" in body ? body.plan : body;
    assertHookPlanArtifact(plan);
    const state = await runtimeHost.registerPlan(plan);
    return { status: 201, body: { state } };
  }

  if (method === "POST" && url.pathname === "/v0/orders") {
    const body = await readJsonBody(request);
    const order = isRecord(body) && "order" in body ? body.order : body;
    const state = await runtimeHost.registerOrder(toOrderRegistration(order));
    return { status: 201, body: { state } };
  }

  if (method === "POST" && url.pathname === "/v0/signals") {
    const body = await readJsonBody(request);
    const signal = isRecord(body) && "signal" in body ? body.signal : body;
    const state = await runtimeHost.receiveSignal(toSignalEnvelope(signal));
    return { status: 202, body: { state } };
  }

  if (method === "POST" && url.pathname === "/v0/dispatch/drain") {
    const events = await runtimeHost.drainDispatchQueue();
    return { status: 200, body: { events, state: runtimeHost.getState() } };
  }

  if (method === "POST" && url.pathname === "/v0/timers/drain") {
    const body = await readJsonBody(request);
    const now = isRecord(body) && typeof body.now === "string" ? body.now : undefined;
    const events = await runtimeHost.runDueTimers(now);
    return { status: 200, body: { events, state: runtimeHost.getState() } };
  }

  if (["GET", "POST"].includes(method)) {
    return { status: 404, body: { error: "not_found" } };
  }
  return { status: 405, body: { error: "method_not_allowed" } };
}

function requireBearerToken(request: IncomingMessage, token: string): void {
  if (request.headers.authorization !== `Bearer ${token}`) {
    throw new UnauthorizedError("missing or invalid bearer token");
  }
}

async function readJsonBody(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > MAX_BODY_BYTES) {
      throw new BadRequestError("request body too large");
    }
    chunks.push(buffer);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  if (raw.trim().length === 0) {
    return {};
  }
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    throw new BadRequestError("request body must be valid JSON");
  }
}

function toOrderRegistration(value: unknown): RuntimeOrderRegistration {
  if (!isRecord(value)) {
    throw new BadRequestError("order must be an object");
  }
  return {
    planId: asString(value.planId, "order.planId") as `0x${string}`,
    zhixuId: asString(value.zhixuId, "order.zhixuId"),
    orderId: asString(value.orderId, "order.orderId"),
    ...(typeof value.receivedAt === "string" ? { receivedAt: value.receivedAt } : {})
  };
}

function toSignalEnvelope(value: unknown): SignalEnvelope {
  if (!isRecord(value)) {
    throw new BadRequestError("signal must be an object");
  }
  return {
    zhixuId: asString(value.zhixuId, "signal.zhixuId"),
    orderId: asString(value.orderId, "signal.orderId"),
    source: asString(value.source, "signal.source"),
    stageIdentifier: asString(value.stageIdentifier, "signal.stageIdentifier"),
    signalName: asString(value.signalName, "signal.signalName"),
    senderId: asString(value.senderId, "signal.senderId"),
    ...(typeof value.idempotencyKey === "string" ? { idempotencyKey: value.idempotencyKey } : {}),
    ...(typeof value.traceId === "string" ? { traceId: value.traceId } : {}),
    ...(typeof value.payloadRef === "string" ? { payloadRef: value.payloadRef } : {}),
    ...(typeof value.receivedAt === "string" ? { receivedAt: value.receivedAt } : {})
  };
}

function asString(value: unknown, fieldName: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new BadRequestError(`${fieldName} must be a non-empty string`);
  }
  return value;
}

function writeJson(response: ServerResponse, status: number, body: unknown): void {
  response.statusCode = status;
  response.setHeader("content-type", "application/json; charset=utf-8");
  response.end(JSON.stringify(body, jsonReplacer));
}

function jsonReplacer(_key: string, value: unknown): unknown {
  return typeof value === "bigint" ? value.toString() : value;
}

function statusForError(error: unknown): number {
  if (error instanceof UnauthorizedError) {
    return 401;
  }
  if (
    error instanceof BadRequestError ||
    error instanceof RuntimeHostError ||
    error instanceof RuntimeTransitionError ||
    error instanceof HookPlanArtifactValidationError
  ) {
    return 400;
  }
  return 500;
}

function errorCodeForError(error: unknown): string {
  if (error instanceof UnauthorizedError) {
    return "unauthorized";
  }
  if (error instanceof BadRequestError || error instanceof HookPlanArtifactValidationError) {
    return "bad_request";
  }
  if (error instanceof RuntimeHostError || error instanceof RuntimeTransitionError) {
    return "runtime_error";
  }
  return "internal_server_error";
}

function closeServer(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function requireNonEmpty(value: string | undefined, fieldName: string): string {
  if (!value || value.trim().length === 0) {
    throw new Error(`${fieldName} is required`);
  }
  return value;
}

function formatHost(host: string): string {
  return host.includes(":") ? `[${host}]` : host;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

class UnauthorizedError extends Error {}

class BadRequestError extends Error {}
