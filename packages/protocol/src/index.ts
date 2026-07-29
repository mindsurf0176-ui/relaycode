export const PROTOCOL_VERSION = 1 as const;
export const WS_PROTOCOL = "relaycode.v1";
export const WS_AUTH_PREFIX = "relaycode.auth.";

export const allowedAgentMethods = [
  "model/list",
  "thread/list",
  "thread/read",
  "thread/start",
  "thread/resume",
  "thread/name/set",
  "turn/start",
  "turn/steer",
  "turn/interrupt",
  "account/read",
  "account/rateLimits/read",
  "account/usage/read",
] as const;

export const relayMethods = [
  "relay/status",
  "relay/workspaces",
] as const;

export const mobileServerRequestMethods = [
  "item/commandExecution/requestApproval",
  "item/fileChange/requestApproval",
  "item/tool/requestUserInput",
  "execCommandApproval",
  "applyPatchApproval",
] as const;

export type AllowedAgentMethod = (typeof allowedAgentMethods)[number];
export type RelayMethod = (typeof relayMethods)[number];
export type AllowedMethod = AllowedAgentMethod | RelayMethod;
export type MobileServerRequestMethod = (typeof mobileServerRequestMethods)[number];

export type ClientRpcMessage = {
  type: "rpc";
  id: string;
  method: AllowedMethod;
  params?: unknown;
};

export type ClientServerResponseMessage = {
  type: "serverResponse";
  id: number | string;
  result: unknown;
};

export type ClientMessage =
  | ClientRpcMessage
  | ClientServerResponseMessage
  | { type: "ping"; sentAt: number };

export type BridgeStatus = {
  protocolVersion: number;
  bridgeVersion: string;
  hostName: string;
  agent: {
    id: "codex";
    label: string;
    state: "starting" | "ready" | "offline";
    version?: string;
    error?: string;
  };
  workspaceRoots: string[];
};

export type ServerMessage =
  | { type: "hello"; status: BridgeStatus }
  | { type: "rpcResult"; id: string; result?: unknown; error?: { message: string; code?: number } }
  | { type: "notification"; method: string; params: unknown }
  | { type: "serverRequest"; id: number | string; method: string; params: unknown }
  | { type: "pong"; sentAt: number; receivedAt: number }
  | { type: "status"; status: BridgeStatus };

const allowed = new Set<string>([...allowedAgentMethods, ...relayMethods]);

export function isAllowedMethod(value: unknown): value is AllowedMethod {
  return typeof value === "string" && allowed.has(value);
}

export function parseClientMessage(value: unknown): ClientMessage | null {
  if (!value || typeof value !== "object") return null;
  const message = value as Record<string, unknown>;
  if (message.type === "ping" && typeof message.sentAt === "number") {
    return { type: "ping", sentAt: message.sentAt };
  }
  if (
    message.type === "rpc"
    && typeof message.id === "string"
    && message.id.length > 0
    && isAllowedMethod(message.method)
  ) {
    return {
      type: "rpc",
      id: message.id,
      method: message.method,
      params: message.params,
    };
  }
  if (
    message.type === "serverResponse"
    && (typeof message.id === "string" || typeof message.id === "number")
    && Object.hasOwn(message, "result")
  ) {
    return { type: "serverResponse", id: message.id, result: message.result };
  }
  return null;
}
