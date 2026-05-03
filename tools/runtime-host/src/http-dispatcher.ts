import type { RuntimeDispatcher, RuntimeDispatchResult } from "./types.js";

export interface HttpRuntimeDispatcherOptions {
  readonly executorUrl: string;
  readonly executorToken: string;
  readonly callbackUrl: string | (() => string);
  readonly timeoutMs?: number;
  readonly fetchImpl?: typeof fetch;
}

export function createHttpRuntimeDispatcher(options: HttpRuntimeDispatcherOptions): RuntimeDispatcher {
  const executorUrl = normalizeBaseUrl(options.executorUrl, "executorUrl");
  const executorToken = requireNonEmpty(options.executorToken, "executorToken");
  const timeoutMs = options.timeoutMs ?? 5_000;
  const fetchImpl = options.fetchImpl ?? fetch;

  return {
    async dispatch(effect): Promise<RuntimeDispatchResult> {
      const callbackUrl = typeof options.callbackUrl === "function" ? options.callbackUrl() : options.callbackUrl;
      try {
        requireNonEmpty(callbackUrl, "callbackUrl");
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), timeoutMs);
        try {
          const response = await fetchImpl(new URL("/v0/dispatches", executorUrl), {
            method: "POST",
            headers: {
              "authorization": `Bearer ${executorToken}`,
              "content-type": "application/json"
            },
            body: JSON.stringify({
              dispatchId: buildDispatchId(effect),
              effect,
              callbackUrl
            }),
            signal: controller.signal
          });

          if (!response.ok) {
            return {
              status: "failed",
              error: `executor dispatch failed with ${response.status}: ${await readResponseText(response)}`
            };
          }
          return { status: "succeeded" };
        } finally {
          clearTimeout(timeout);
        }
      } catch (error) {
        return {
          status: "failed",
          error: error instanceof Error ? error.message : String(error)
        };
      }
    }
  };
}

function buildDispatchId(effect: Parameters<RuntimeDispatcher["dispatch"]>[0]): string {
  return `${effect.zhixuId}:${effect.orderId}:${effect.hookId}:${effect.eventId}`;
}

function normalizeBaseUrl(value: string, fieldName: string): string {
  requireNonEmpty(value, fieldName);
  try {
    const url = new URL(value);
    return url.toString();
  } catch {
    throw new Error(`${fieldName} must be a valid URL`);
  }
}

function requireNonEmpty(value: string | undefined, fieldName: string): string {
  if (!value || value.trim().length === 0) {
    throw new Error(`${fieldName} is required`);
  }
  return value;
}

async function readResponseText(response: Response): Promise<string> {
  const text = await response.text();
  return text.length > 0 ? text.slice(0, 500) : response.statusText;
}
