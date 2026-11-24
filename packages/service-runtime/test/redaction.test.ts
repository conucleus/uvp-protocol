import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createRedactingLogger,
  redactErrorMessage,
  redactSecrets,
  type Logger,
} from "../src/index.js";

const KEY = "abcd1234efgh5678ijkl9012mnop3456";

function recordedLogger(): {
  readonly logger: Logger;
  readonly entries: { readonly message: string; readonly context?: Record<string, unknown> }[];
} {
  const entries: { message: string; context?: Record<string, unknown> }[] = [];
  const record = (message: string, context?: Record<string, unknown>): void => {
    entries.push({ message, ...(context === undefined ? {} : { context }) });
  };
  const logger: Logger = {
    debug: record,
    info: record,
    warn: record,
    error: record,
  };
  return { logger, entries };
}

describe("redactErrorMessage", () => {
  it("redacts embedded RPC path keys for Alchemy and Infura URLs", () => {
    const alchemy = redactErrorMessage(
      new Error(`HTTP request failed. URL: https://eth-mainnet.g.alchemy.com/v2/${KEY}`),
    );
    assert.ok(!alchemy.includes(KEY), "Alchemy path key must not survive redaction");
    assert.match(alchemy, /\/v2\/\[redacted\]/);

    const infura = redactErrorMessage(
      new Error(`HTTP request failed. URL: https://mainnet.infura.io/v3/${KEY}.`),
    );
    assert.ok(!infura.includes(KEY), "Infura path key must not survive redaction");
    assert.match(infura, /\/v3\/\[redacted\]\./);
  });

  it("redacts QuickNode subdomain and path credentials", () => {
    const message = redactErrorMessage(
      new Error(`connect ECONNREFUSED https://${KEY}.quiknode.pro/${KEY}/`),
    );
    assert.ok(!message.includes(KEY), "QuickNode credentials must not survive redaction");
    assert.match(message, /https:\/\/redacted\.quiknode\.pro\/\[redacted\]\//);
  });

  it("redacts userinfo embedded in error message URLs", () => {
    const message = redactErrorMessage(
      new Error("fetch failed for https://rpc-user:super-secret@rpc.example.com/v1"),
    );
    assert.ok(!message.includes("rpc-user"), "URL username must not survive redaction");
    assert.ok(!message.includes("super-secret"), "URL password must not survive redaction");
    assert.match(message, /https:\/\/redacted:redacted@rpc\.example\.com\/v1/);
  });

  it("leaves non-credential paths in embedded URLs untouched", () => {
    const message = redactErrorMessage(
      new Error("POST https://example.com/api/v1/orders failed"),
    );
    assert.equal(message, "POST https://example.com/api/v1/orders failed");
  });
});

describe("redacting logger and object traversal", () => {
  it("redacts path keys embedded in log messages and context strings", () => {
    const { logger, entries } = recordedLogger();
    createRedactingLogger(logger).error(
      `rpc failed at https://eth-mainnet.g.alchemy.com/v2/${KEY}`,
      { cause: new Error(`userinfo https://rpc-user:super-secret@rpc.example.com/`) },
    );
    const entry = entries[0];
    assert.ok(entry);
    assert.ok(!entry.message.includes(KEY));
    assert.match(entry.message, /\/v2\/\[redacted\]/);
    const cause = entry.context?.cause;
    assert.ok(!JSON.stringify(cause).includes("super-secret"));
  });

  it("redacts userinfo and path keys traversed by redactSecrets", () => {
    const redacted = redactSecrets({
      detail: "https://rpc-user:super-secret@rpc.example.com/v1",
      endpoint: `https://mainnet.infura.io/v3/${KEY}`,
    });
    assert.ok(!JSON.stringify(redacted).includes("super-secret"));
    assert.ok(!JSON.stringify(redacted).includes(KEY));
  });
});
