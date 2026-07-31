import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import {
  existsSync,
  mkdtempSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import type { WorkspaceMethod } from "@relaycode/protocol";
import { assertWorkspacePath } from "./security.js";

type TerminalMethod = Extract<WorkspaceMethod, `terminal/${string}`>;
type Params = Record<string, unknown>;
type SessionState = "running" | "exited";

type TerminalSession = {
  id: string;
  workspace: string;
  network: boolean;
  child: ChildProcessWithoutNullStreams;
  temporaryHome: string;
  output: string;
  sequence: number;
  createdAt: number;
  lastActiveAt: number;
  state: SessionState;
  exitCode?: number | null;
  signal?: NodeJS.Signals | null;
};

const maxSessions = 4;
const maxInputBytes = 16 * 1024;
const maxReplayBytes = 256 * 1024;
const maxChunkBytes = 32 * 1024;
const expiredSessionMilliseconds = 60 * 60 * 1_000;

function params(value: unknown): Params {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("RPC params must be an object.");
  }
  return value as Params;
}

function requiredString(
  value: Params,
  key: string,
  maximumLength = 2_000,
): string {
  const candidate = value[key];
  if (
    typeof candidate !== "string"
    || candidate.trim() === ""
    || candidate.length > maximumLength
    || candidate.includes("\0")
  ) {
    throw new Error(`Invalid ${key}.`);
  }
  return candidate;
}

function escapeSandboxLiteral(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"");
}

function readableSystemPaths(): string[] {
  const paths = [
    "/Applications",
    "/Library",
    "/System",
    "/bin",
    "/dev",
    "/opt/homebrew",
    "/private/etc",
    "/private/var/db",
    "/sbin",
    "/usr",
    "/usr/local",
  ];
  const executable = realpathSync(process.execPath);
  paths.push(dirname(executable));
  return [...new Set(paths.filter((path) => existsSync(path)))];
}

export function terminalSandboxProfile(
  workspace: string,
  temporaryHome: string,
  network: boolean,
): string {
  const readable = [
    ...readableSystemPaths(),
    workspace,
    temporaryHome,
  ].map((path) => `(subpath "${escapeSandboxLiteral(path)}")`).join(" ");
  const writable = [workspace, temporaryHome]
    .map((path) => `(subpath "${escapeSandboxLiteral(path)}")`)
    .join(" ");
  return [
    "(version 1)",
    "(deny default)",
    "(import \"system.sb\")",
    "(allow process*)",
    "(allow signal)",
    "(allow sysctl-read)",
    "(allow mach-lookup)",
    "(allow ipc-posix*)",
    "(allow file-read-metadata)",
    `(allow file-read* ${readable})`,
    `(allow file-write* ${writable})`,
    network ? "(allow network*)" : "",
  ].filter(Boolean).join("\n");
}

export function terminalCapability(): {
  available: boolean;
  reason?: string;
} {
  if (process.platform !== "darwin") {
    return {
      available: false,
      reason: "The persistent remote terminal currently requires the macOS sandbox.",
    };
  }
  if (!existsSync("/usr/bin/sandbox-exec")) {
    return {
      available: false,
      reason: "sandbox-exec is unavailable on this Mac.",
    };
  }
  return { available: true };
}

export class TerminalManager extends EventEmitter {
  private readonly sessions = new Map<string, TerminalSession>();

  constructor(private readonly roots: string[]) {
    super();
  }

  async request(method: TerminalMethod, value: unknown): Promise<unknown> {
    const input = params(value);
    this.prune();
    switch (method) {
      case "terminal/session/list":
        return {
          capability: terminalCapability(),
          sessions: [...this.sessions.values()].map((session) => (
            this.publicSession(session)
          )),
        };
      case "terminal/session/start":
        return this.start(input);
      case "terminal/session/write":
        return this.write(input);
      case "terminal/session/interrupt":
        return this.interrupt(input);
      case "terminal/session/close":
        return this.closeSession(input);
      default:
        throw new Error("Unsupported terminal method.");
    }
  }

  close(): void {
    for (const session of this.sessions.values()) {
      this.terminate(session, "SIGTERM");
    }
  }

  private start(input: Params): unknown {
    const capability = terminalCapability();
    if (!capability.available) throw new Error(capability.reason);
    const runningCount = [...this.sessions.values()]
      .filter((session) => session.state === "running").length;
    if (runningCount >= maxSessions) {
      throw new Error(`At most ${maxSessions} terminal sessions may run at once.`);
    }

    const workspace = assertWorkspacePath(
      requiredString(input, "workspace"),
      this.roots,
    );
    const network = input.network === true;
    const temporaryHome = realpathSync(
      mkdtempSync(join(tmpdir(), "relaycode-terminal-")),
    );
    const profile = terminalSandboxProfile(
      workspace,
      temporaryHome,
      network,
    );
    const shell = existsSync("/bin/zsh") ? "/bin/zsh" : "/bin/sh";
    const shellArgs = shell.endsWith("zsh") ? ["-f"] : [];
    const child = spawn(
      "/usr/bin/sandbox-exec",
      ["-p", profile, shell, ...shellArgs],
      {
        cwd: workspace,
        detached: true,
        env: {
          HOME: temporaryHome,
          LANG: process.env.LANG || "en_US.UTF-8",
          LC_ALL: process.env.LC_ALL || "",
          PATH:
            process.env.RELAYCODE_TERMINAL_PATH
            || "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
          PWD: workspace,
          RELAYCODE_SANDBOX: "1",
          SHELL: shell,
          TERM: "xterm-256color",
          TMPDIR: `${temporaryHome}/`,
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    const now = Date.now();
    const session: TerminalSession = {
      id: randomUUID(),
      workspace,
      network,
      child,
      temporaryHome,
      output: "",
      sequence: 0,
      createdAt: now,
      lastActiveAt: now,
      state: "running",
    };
    this.sessions.set(session.id, session);
    this.append(
      session,
      "system",
      `RelayCode sandbox · ${basename(workspace)} · network ${network ? "on" : "off"}\n`,
    );
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (data: string) => this.append(session, "stdout", data));
    child.stderr.on("data", (data: string) => this.append(session, "stderr", data));
    child.once("error", (error) => {
      this.append(session, "stderr", `${error.message}\n`);
    });
    child.once("exit", (code, signal) => {
      session.state = "exited";
      session.exitCode = code;
      session.signal = signal;
      session.lastActiveAt = Date.now();
      this.emit("exit", {
        sessionId: session.id,
        code,
        signal,
      });
      this.removeTemporaryHome(session);
    });
    return this.publicSession(session);
  }

  private write(input: Params): unknown {
    const session = this.runningSession(requiredString(input, "sessionId", 100));
    const dataValue = input.data;
    if (
      typeof dataValue !== "string"
      || dataValue.length === 0
      || dataValue.length > maxInputBytes
      || dataValue.includes("\0")
    ) {
      throw new Error("Invalid terminal input.");
    }
    const data = dataValue;
    if (Buffer.byteLength(data, "utf8") > maxInputBytes) {
      throw new Error("Terminal input is too large.");
    }
    session.lastActiveAt = Date.now();
    this.append(session, "system", `$ ${data}`);
    session.child.stdin.write(data);
    return { accepted: true, sequence: session.sequence };
  }

  private interrupt(input: Params): unknown {
    const session = this.runningSession(requiredString(input, "sessionId", 100));
    this.signalGroup(session, "SIGINT");
    return { interrupted: true };
  }

  private closeSession(input: Params): unknown {
    const id = requiredString(input, "sessionId", 100);
    const session = this.sessions.get(id);
    if (!session) throw new Error("Terminal session was not found.");
    if (session.state === "running") this.terminate(session, "SIGTERM");
    this.sessions.delete(id);
    this.removeTemporaryHome(session);
    return { closed: true };
  }

  private publicSession(session: TerminalSession): unknown {
    return {
      id: session.id,
      workspace: session.workspace,
      network: session.network,
      output: session.output,
      sequence: session.sequence,
      createdAt: session.createdAt,
      lastActiveAt: session.lastActiveAt,
      state: session.state,
      exitCode: session.exitCode,
      signal: session.signal,
    };
  }

  private runningSession(id: string): TerminalSession {
    const session = this.sessions.get(id);
    if (!session) throw new Error("Terminal session was not found.");
    if (session.state !== "running") {
      throw new Error("Terminal session has already exited.");
    }
    return session;
  }

  private append(
    session: TerminalSession,
    stream: "stdout" | "stderr" | "system",
    rawData: string,
  ): void {
    const data = rawData.slice(0, maxChunkBytes);
    session.sequence += 1;
    session.lastActiveAt = Date.now();
    session.output = `${session.output}${data}`;
    if (Buffer.byteLength(session.output, "utf8") > maxReplayBytes) {
      session.output = Buffer.from(session.output, "utf8")
        .subarray(-maxReplayBytes)
        .toString("utf8");
    }
    this.emit("output", {
      sessionId: session.id,
      sequence: session.sequence,
      stream,
      data,
    });
  }

  private signalGroup(
    session: TerminalSession,
    signal: NodeJS.Signals,
  ): void {
    if (!session.child.pid) return;
    try {
      process.kill(-session.child.pid, signal);
    } catch {
      session.child.kill(signal);
    }
  }

  private terminate(
    session: TerminalSession,
    signal: NodeJS.Signals,
  ): void {
    this.signalGroup(session, signal);
    session.child.stdin.end();
  }

  private removeTemporaryHome(session: TerminalSession): void {
    try {
      rmSync(session.temporaryHome, { recursive: true, force: true });
    } catch {
      // A private cache directory can be removed on the next prune.
    }
  }

  private prune(): void {
    const threshold = Date.now() - expiredSessionMilliseconds;
    for (const [id, session] of this.sessions) {
      if (session.state === "exited" && session.lastActiveAt < threshold) {
        this.sessions.delete(id);
        this.removeTemporaryHome(session);
      }
    }
  }
}
