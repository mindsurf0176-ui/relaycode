import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";

type RpcId = number | string;
type RpcMessage = {
  id?: RpcId;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code?: number; message?: string };
};

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
};

export type CodexState = "starting" | "ready" | "offline";

export class CodexAppServer extends EventEmitter {
  private child: ChildProcessWithoutNullStreams | null = null;
  private nextId = 1;
  private pending = new Map<RpcId, Pending>();
  state: CodexState = "offline";
  lastError?: string;

  async start(): Promise<void> {
    if (this.child) return;
    this.state = "starting";
    this.emit("state", this.state);

    const child = spawn(process.env.CODEX_BIN || "codex", ["app-server", "--stdio"], {
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;
    const lines = createInterface({ input: child.stdout });
    lines.on("line", (line) => this.onLine(line));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => this.emit("stderr", chunk));
    child.once("error", (error) => this.goOffline(error));
    child.once("exit", (code, signal) => {
      this.goOffline(new Error(`Codex app-server exited (${code ?? signal ?? "unknown"}).`));
    });

    try {
      await this.request("initialize", {
        clientInfo: {
          name: "relaycode_mobile",
          title: "RelayCode",
          version: "0.1.0",
        },
      });
      this.notify("initialized", {});
      this.state = "ready";
      this.lastError = undefined;
      this.emit("state", this.state);
    } catch (error) {
      child.kill("SIGTERM");
      this.goOffline(error instanceof Error ? error : new Error(String(error)));
      throw error;
    }
  }

  request(method: string, params?: unknown): Promise<unknown> {
    if (!this.child) return Promise.reject(new Error("Codex app-server is offline."));
    const id = this.nextId++;
    const message: RpcMessage = { id, method };
    if (params !== undefined) message.params = params;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out.`));
      }, 30_000);
      this.pending.set(id, { resolve, reject, timer });
      this.write(message);
    });
  }

  respond(id: RpcId, result: unknown): void {
    if (!this.child) throw new Error("Codex app-server is offline.");
    this.write({ id, result });
  }

  reject(id: RpcId, code: number, message: string): void {
    if (!this.child) throw new Error("Codex app-server is offline.");
    this.write({ id, error: { code, message } });
  }

  stop(): void {
    this.child?.kill("SIGTERM");
    this.child = null;
    this.goOffline(new Error("Codex app-server stopped."));
  }

  private notify(method: string, params?: unknown): void {
    const message: RpcMessage = { method };
    if (params !== undefined) message.params = params;
    this.write(message);
  }

  private write(message: RpcMessage): void {
    this.child?.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private onLine(line: string): void {
    let message: RpcMessage;
    try {
      message = JSON.parse(line) as RpcMessage;
    } catch {
      this.emit("warning", "Codex app-server emitted invalid JSON.");
      return;
    }

    if (message.id !== undefined && !message.method) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(message.error.message || `Codex RPC error ${message.error.code ?? ""}`));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (message.id !== undefined && message.method) {
      this.emit("serverRequest", message);
      return;
    }

    if (message.method) this.emit("notification", message);
  }

  private goOffline(error: Error): void {
    if (this.state === "offline" && !this.child) return;
    this.child = null;
    this.state = "offline";
    this.lastError = error.message;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    this.emit("state", this.state);
  }
}
