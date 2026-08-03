import { mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { RelayConfig } from "./config.js";
import { hashToken } from "./config.js";
import { RelayServer, safeWebPath } from "./server.js";

const port = 18992;

function webRootFixture(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "relaycode-web-")));
  writeFileSync(join(root, "index.html"), "<!doctype html><title>RelayCode</title>");
  return root;
}

function config(): RelayConfig {
  return {
    version: 1,
    displayName: "test",
    host: "127.0.0.1",
    port,
    workspaceRoots: [realpathSync(tmpdir())],
    tokenHash: hashToken("a".repeat(43)),
  };
}

describe("static web path resolution", () => {
  const root = webRootFixture();

  it("serves paths inside the web root", () => {
    expect(safeWebPath(root, "/")).toBe(join(root, "index.html"));
    expect(safeWebPath(root, "/assets/app.js")).toBe(join(root, "assets/app.js"));
    expect(safeWebPath(root, "/index.html?v=2")).toBe(join(root, "index.html"));
  });

  it("rejects malformed percent escapes instead of throwing", () => {
    expect(safeWebPath(root, "/%")).toBeNull();
    expect(safeWebPath(root, "/%E0%A4%A")).toBeNull();
    expect(safeWebPath(root, "/%zz")).toBeNull();
  });

  it("rejects escapes outside the web root and null bytes", () => {
    expect(safeWebPath(root, "/../../etc/passwd")).toBeNull();
    expect(safeWebPath(root, "/%2e%2e%2f%2e%2e%2fetc%2fpasswd")).toBeNull();
    expect(safeWebPath(root, "/index.html%00.png")).toBeNull();
  });
});

describe("bridge http surface", () => {
  let server: RelayServer;
  let previousWebRoot: string | undefined;
  let previousCodexBin: string | undefined;

  beforeEach(async () => {
    previousWebRoot = process.env.RELAYCODE_WEB_ROOT;
    previousCodexBin = process.env.CODEX_BIN;
    process.env.RELAYCODE_WEB_ROOT = webRootFixture();
    // A missing agent binary keeps the HTTP surface up without starting Codex.
    process.env.CODEX_BIN = join(tmpdir(), "relaycode-missing-codex");
    server = new RelayServer(config());
    await server.listen();
  });

  afterEach(() => {
    server.close();
    if (previousWebRoot === undefined) delete process.env.RELAYCODE_WEB_ROOT;
    else process.env.RELAYCODE_WEB_ROOT = previousWebRoot;
    if (previousCodexBin === undefined) delete process.env.CODEX_BIN;
    else process.env.CODEX_BIN = previousCodexBin;
  });

  it("stays alive and answers 400 on a malformed request path", async () => {
    const malformed = await fetch(`http://127.0.0.1:${port}/%`);
    expect(malformed.status).toBe(400);

    const health = await fetch(`http://127.0.0.1:${port}/healthz`);
    expect(health.status).toBe(200);
    expect(await health.json()).toMatchObject({ ok: true });
  });

  it("rejects unauthenticated WebSocket upgrades", async () => {
    const response = await fetch(`http://127.0.0.1:${port}/ws`, {
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Key": Buffer.from("relaycode-test-key").toString("base64"),
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Protocol": "relaycode.v1, relaycode.auth.wrong-token",
      },
    }).catch((error: unknown) => error as Error);
    expect(response instanceof Error ? 401 : response.status).toBe(401);
  });
});
