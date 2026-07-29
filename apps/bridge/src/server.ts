import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { hostname } from "node:os";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
  PROTOCOL_VERSION,
  WS_PROTOCOL,
  allowedAgentMethods,
  mobileServerRequestMethods,
  parseClientMessage,
  type AllowedAgentMethod,
  type BridgeStatus,
  type ServerMessage,
} from "@relaycode/protocol";
import { WebSocket, WebSocketServer } from "ws";
import { canonicalRoots, currentTokenHash, type RelayConfig } from "./config.js";
import { CodexAppServer } from "./codex-app-server.js";
import { assertWorkspacePath, sanitizeAgentParams, tokenFromProtocols, tokenMatches } from "./security.js";

const bridgeVersion = "0.1.1";
const allowedMethods = new Set<string>(allowedAgentMethods);
const allowedServerRequests = new Set<string>(mobileServerRequestMethods);
const threadScopedMethods = new Set<string>([
  "thread/read",
  "thread/resume",
  "thread/name/set",
  "turn/start",
  "turn/steer",
  "turn/interrupt",
]);
const maxMessageBytes = 1_000_000;
const debugEnabled = process.env.RELAYCODE_DEBUG === "1";

function debug(event: string, details?: Record<string, unknown>): void {
  if (!debugEnabled) return;
  console.error(`[relaycode:debug] ${event}${details ? ` ${JSON.stringify(details)}` : ""}`);
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function eventThreadId(params: unknown): string | undefined {
  const value = record(params);
  if (typeof value.threadId === "string") return value.threadId;
  if (typeof value.conversationId === "string") return value.conversationId;
  return undefined;
}

const mimeTypes: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webmanifest": "application/manifest+json",
};

function codexVersion(): string | undefined {
  try {
    return execFileSync(process.env.CODEX_BIN || "codex", ["--version"], {
      encoding: "utf8",
      timeout: 5_000,
    }).trim();
  } catch {
    return undefined;
  }
}

function webRoot(): string {
  if (process.env.RELAYCODE_WEB_ROOT?.trim()) return resolve(process.env.RELAYCODE_WEB_ROOT);
  const here = fileURLToPath(new URL(".", import.meta.url));
  const developmentRoot = resolve(here, "../../mobile/dist");
  const releaseRoot = resolve(here, "../share/relaycode/mobile");
  return existsSync(developmentRoot) ? developmentRoot : releaseRoot;
}

function safeWebPath(root: string, requestPath: string): string | null {
  const decoded = decodeURIComponent(requestPath.split("?")[0] || "/");
  const relativePath = decoded === "/" ? "index.html" : decoded.replace(/^\/+/, "");
  const target = resolve(root, relativePath);
  return target === root || target.startsWith(`${root}${sep}`) ? target : null;
}

export class RelayServer {
  private readonly roots: string[];
  private readonly authorizedThreads = new Set<string>();
  private readonly codex = new CodexAppServer();
  private readonly clients = new Set<WebSocket>();
  private readonly server = createServer((request, response) => this.handleHttp(request, response));
  private readonly wss = new WebSocketServer({
    noServer: true,
    handleProtocols: (protocols) => protocols.has(WS_PROTOCOL) ? WS_PROTOCOL : false,
  });

  constructor(private readonly config: RelayConfig) {
    this.roots = canonicalRoots(config);
    this.server.on("upgrade", (request, socket, head) => {
      const path = new URL(request.url || "/", "http://localhost").pathname;
      const token = tokenFromProtocols(request.headers["sec-websocket-protocol"]);
      let expectedHash = "";
      try {
        expectedHash = currentTokenHash();
      } catch {
        // A missing or malformed verifier fails closed.
      }
      if (path !== "/ws" || !tokenMatches(token, expectedHash)) {
        socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      this.wss.handleUpgrade(request, socket, head, (ws) => this.wss.emit("connection", ws, request));
    });
    this.wss.on("connection", (ws, request) => {
      this.handleConnection(ws, tokenFromProtocols(request.headers["sec-websocket-protocol"]));
    });

    this.codex.on("notification", (message: { method: string; params?: unknown }) => {
      const threadId = eventThreadId(message.params);
      if (threadId && !this.authorizedThreads.has(threadId)) {
        debug("notification outside workspace boundary", { method: message.method });
        return;
      }
      this.broadcast({ type: "notification", method: message.method, params: message.params });
    });
    this.codex.on("serverRequest", (message: { id: number | string; method: string; params?: unknown }) => {
      if (!allowedServerRequests.has(message.method)) {
        debug("server request rejected", { method: message.method });
        this.codex.reject(message.id, -32601, "RelayCode does not expose this server request to mobile clients.");
        return;
      }
      const threadId = eventThreadId(message.params);
      if (threadId && !this.authorizedThreads.has(threadId)) {
        debug("server request outside workspace boundary", { method: message.method });
        this.codex.reject(message.id, -32600, "Thread is outside the configured RelayCode workspace roots.");
        return;
      }
      this.broadcast({
        type: "serverRequest",
        id: message.id,
        method: message.method,
        params: message.params,
      });
    });
    this.codex.on("state", () => this.broadcast({ type: "status", status: this.status() }));
    this.codex.on("warning", (message: string) => {
      this.broadcast({ type: "notification", method: "relay/warning", params: { message } });
    });
  }

  async listen(): Promise<void> {
    await this.codex.start().catch(() => {
      // The HTTP server still starts so the mobile client can show a useful offline state.
    });
    await new Promise<void>((resolvePromise, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.config.port, this.config.host, () => resolvePromise());
    });
  }

  close(): void {
    for (const client of this.clients) client.close(1001, "Bridge shutting down");
    this.codex.stop();
    this.server.close();
  }

  status(): BridgeStatus {
    return {
      protocolVersion: PROTOCOL_VERSION,
      bridgeVersion,
      hostName: this.config.displayName || hostname(),
      agent: {
        id: "codex",
        label: "Codex",
        state: this.codex.state,
        version: codexVersion(),
        error: this.codex.lastError,
      },
      workspaceRoots: this.config.workspaceRoots,
    };
  }

  private handleConnection(ws: WebSocket, token: string | null): void {
    this.clients.add(ws);
    debug("client connected", { protocol: ws.protocol, readyState: ws.readyState });
    this.send(ws, { type: "hello", status: this.status() });
    ws.on("close", (code) => {
      debug("client closed", { code });
      this.clients.delete(ws);
    });
    ws.on("message", async (data, binary) => {
      let expectedHash = "";
      try {
        expectedHash = currentTokenHash();
      } catch {
        // A missing or malformed verifier fails closed.
      }
      if (!tokenMatches(token, expectedHash)) {
        ws.close(4001, "Pairing token rotated");
        return;
      }
      const byteLength = Array.isArray(data)
        ? data.reduce((total, chunk) => total + chunk.byteLength, 0)
        : data.byteLength;
      if (binary || byteLength > maxMessageBytes) {
        ws.close(1009, "Message too large");
        return;
      }
      let raw: unknown;
      try {
        raw = JSON.parse(data.toString());
      } catch {
        ws.close(1003, "Invalid JSON");
        return;
      }
      const message = parseClientMessage(raw);
      if (!message) {
        ws.close(1008, "Invalid protocol message");
        return;
      }
      debug("client message", {
        type: message.type,
        method: message.type === "rpc" ? message.method : undefined,
      });
      if (message.type === "ping") {
        this.send(ws, { type: "pong", sentAt: message.sentAt, receivedAt: Date.now() });
        return;
      }
      if (message.type === "serverResponse") {
        try {
          this.codex.respond(message.id, message.result);
        } catch (error) {
          this.send(ws, {
            type: "notification",
            method: "relay/error",
            params: { message: error instanceof Error ? error.message : String(error) },
          });
        }
        return;
      }

      try {
        let result: unknown;
        if (message.method === "relay/status") {
          result = this.status();
        } else if (message.method === "relay/workspaces") {
          result = this.config.workspaceRoots.map((path) => ({
            path,
            name: path.split(sep).filter(Boolean).at(-1) || path,
          }));
        } else if (allowedMethods.has(message.method)) {
          const method = message.method as AllowedAgentMethod;
          const params = sanitizeAgentParams(method, message.params, this.config, this.roots);
          if (threadScopedMethods.has(method)) {
            const threadId = record(params).threadId;
            if (typeof threadId !== "string") throw new Error("A thread id is required.");
            await this.authorizeExistingThread(threadId);
          }
          result = await this.codex.request(method, params);
          result = this.filterAndAuthorizeResult(method, result);
        } else {
          throw new Error("RPC method is not available on the mobile bridge.");
        }
        this.send(ws, { type: "rpcResult", id: message.id, result });
      } catch (error) {
        this.send(ws, {
          type: "rpcResult",
          id: message.id,
          error: { message: error instanceof Error ? error.message : String(error) },
        });
      }
    });
  }

  private handleHttp(request: IncomingMessage, response: ServerResponse): void {
    if (request.url === "/healthz") {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(JSON.stringify({ ok: true, agent: this.codex.state }));
      return;
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405).end();
      return;
    }
    const root = webRoot();
    const path = safeWebPath(root, request.url || "/");
    const fallback = resolve(root, "index.html");
    const target = path && existsSync(path) && statSync(path).isFile() ? path : fallback;
    if (!existsSync(target)) {
      response.writeHead(503, { "Content-Type": "application/json; charset=utf-8" });
      response.end(JSON.stringify({
        error: "RelayCode mobile build is missing.",
        action: "Run npm run build -w @relaycode/mobile or use the Vite dev server.",
      }));
      return;
    }
    const body = readFileSync(target);
    response.writeHead(200, {
      "Content-Type": mimeTypes[extname(target)] || "application/octet-stream",
      "Cache-Control": target.endsWith("index.html") ? "no-store" : "public, max-age=3600",
      "Content-Security-Policy": [
        "default-src 'self'",
        "connect-src 'self' ws: wss:",
        "img-src 'self' data: blob:",
        "style-src 'self' 'unsafe-inline'",
        "script-src 'self'",
      ].join("; "),
    });
    if (request.method === "HEAD") response.end();
    else response.end(body);
  }

  private send(ws: WebSocket, message: ServerMessage): void {
    debug("server message", { type: message.type, readyState: ws.readyState });
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
  }

  private broadcast(message: ServerMessage): void {
    for (const client of this.clients) this.send(client, message);
  }

  private authorizeThread(value: unknown): boolean {
    const thread = record(value);
    if (typeof thread.id !== "string" || typeof thread.cwd !== "string") return false;
    try {
      assertWorkspacePath(thread.cwd, this.roots);
      this.authorizedThreads.add(thread.id);
      return true;
    } catch {
      return false;
    }
  }

  private async authorizeExistingThread(threadId: string): Promise<void> {
    if (this.authorizedThreads.has(threadId)) return;
    const result = record(await this.codex.request("thread/read", {
      threadId,
      includeTurns: false,
    }));
    if (!this.authorizeThread(result.thread)) {
      throw new Error("Thread is outside the configured RelayCode workspace roots.");
    }
  }

  private filterAndAuthorizeResult(method: AllowedAgentMethod, result: unknown): unknown {
    const value = record(result);
    if (method === "thread/list") {
      const data = Array.isArray(value.data) ? value.data.filter((thread) => this.authorizeThread(thread)) : [];
      return { ...value, data };
    }
    if (method === "thread/start" || method === "thread/resume" || method === "thread/read") {
      if (!this.authorizeThread(value.thread)) {
        throw new Error("Thread is outside the configured RelayCode workspace roots.");
      }
    }
    return result;
  }
}
