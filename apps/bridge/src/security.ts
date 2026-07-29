import { timingSafeEqual } from "node:crypto";
import { existsSync, realpathSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";
import { WS_AUTH_PREFIX, WS_PROTOCOL, type AllowedAgentMethod } from "@relaycode/protocol";
import { hashToken, type RelayConfig } from "./config.js";

const effortValues = new Set(["minimal", "low", "medium", "high", "xhigh", "max"]);

export function tokenFromProtocols(header: string | string[] | undefined): string | null {
  const value = Array.isArray(header) ? header.join(",") : header;
  if (!value) return null;
  const protocols = value.split(",").map((item) => item.trim());
  if (!protocols.includes(WS_PROTOCOL)) return null;
  const auth = protocols.find((item) => item.startsWith(WS_AUTH_PREFIX));
  return auth ? auth.slice(WS_AUTH_PREFIX.length) : null;
}

export function tokenMatches(token: string | null, expectedHash: string): boolean {
  if (!token || !/^[A-Za-z0-9_-]{40,100}$/.test(token)) return false;
  const actual = Buffer.from(hashToken(token), "hex");
  const expected = Buffer.from(expectedHash, "hex");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function isWithin(path: string, root: string): boolean {
  const rel = relative(root, path);
  return rel === "" || (!rel.startsWith("..") && !rel.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`));
}

export function assertWorkspacePath(path: unknown, roots: string[]): string {
  if (typeof path !== "string" || path.trim() === "") throw new Error("A workspace path is required.");
  const absolute = resolve(path);
  if (!existsSync(absolute) || !statSync(absolute).isDirectory()) {
    throw new Error("Workspace path does not exist or is not a directory.");
  }
  const canonical = realpathSync(absolute);
  if (!roots.some((root) => isWithin(canonical, root))) {
    throw new Error("Workspace path is outside the configured RelayCode roots.");
  }
  return canonical;
}

function objectParams(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null) return {};
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("RPC params must be an object.");
  return value as Record<string, unknown>;
}

function requiredString(params: Record<string, unknown>, key: string, max = 500): string {
  const value = params[key];
  if (typeof value !== "string" || value.trim() === "" || value.length > max) {
    throw new Error(`Invalid ${key}.`);
  }
  return value;
}

function optionalString(params: Record<string, unknown>, key: string, max = 500): string | undefined {
  const value = params[key];
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || value.length > max) throw new Error(`Invalid ${key}.`);
  return value;
}

function textInput(value: unknown): Array<{ type: "text"; text: string }> {
  if (!Array.isArray(value) || value.length === 0 || value.length > 8) throw new Error("Text input is required.");
  return value.map((item) => {
    if (!item || typeof item !== "object") throw new Error("Invalid input item.");
    const raw = item as Record<string, unknown>;
    if (raw.type !== "text" || typeof raw.text !== "string" || raw.text.trim() === "" || raw.text.length > 50_000) {
      throw new Error("RelayCode MVP accepts non-empty text input only.");
    }
    return { type: "text" as const, text: raw.text };
  });
}

export function sanitizeAgentParams(
  method: AllowedAgentMethod,
  value: unknown,
  config: RelayConfig,
  roots: string[],
): unknown {
  const params = objectParams(value);
  switch (method) {
    case "model/list":
      return { limit: Math.min(Number(params.limit) || 100, 100), includeHidden: false };
    case "thread/list":
      return {
        limit: Math.min(Number(params.limit) || 50, 100),
        cursor: optionalString(params, "cursor", 500),
        searchTerm: optionalString(params, "searchTerm", 120),
        archived: params.archived === true,
        sortKey: "updated_at",
        sortDirection: "desc",
      };
    case "thread/read":
      return { threadId: requiredString(params, "threadId", 200), includeTurns: true };
    case "thread/start": {
      const cwd = assertWorkspacePath(params.cwd ?? config.workspaceRoots[0], roots);
      return {
        cwd,
        model: optionalString(params, "model", 200),
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        sandbox: "workspace-write",
        personality: optionalString(params, "personality", 40),
      };
    }
    case "thread/resume": {
      const cwd = params.cwd === undefined ? undefined : assertWorkspacePath(params.cwd, roots);
      return {
        threadId: requiredString(params, "threadId", 200),
        cwd,
        model: optionalString(params, "model", 200),
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        sandbox: "workspace-write",
      };
    }
    case "thread/name/set":
      return {
        threadId: requiredString(params, "threadId", 200),
        name: requiredString(params, "name", 100),
      };
    case "turn/start": {
      const effort = optionalString(params, "effort", 20);
      if (effort && !effortValues.has(effort)) throw new Error("Invalid reasoning effort.");
      return {
        threadId: requiredString(params, "threadId", 200),
        clientUserMessageId: optionalString(params, "clientUserMessageId", 200),
        input: textInput(params.input),
        model: optionalString(params, "model", 200),
        effort,
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
      };
    }
    case "turn/steer":
      return {
        threadId: requiredString(params, "threadId", 200),
        expectedTurnId: requiredString(params, "expectedTurnId", 200),
        clientUserMessageId: optionalString(params, "clientUserMessageId", 200),
        input: textInput(params.input),
      };
    case "turn/interrupt":
      return {
        threadId: requiredString(params, "threadId", 200),
        turnId: requiredString(params, "turnId", 200),
      };
    case "account/read":
      return { refreshToken: false };
    case "account/rateLimits/read":
    case "account/usage/read":
      return undefined;
  }
}
