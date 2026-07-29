import {
  WS_AUTH_PREFIX,
  WS_PROTOCOL,
  type AllowedMethod,
  type BridgeStatus,
  type ServerMessage,
} from "@relaycode/protocol";

type Listener = (message: ServerMessage) => void;
type StateListener = (state: ConnectionState) => void;
type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: number;
};

type NativeMessage = {
  type: "savePairing" | "clearPairing";
  token?: string;
  bridge?: string;
};

declare global {
  interface Window {
    __RELAYCODE_NATIVE__?: boolean;
    __RELAYCODE_NATIVE_PAIRING__?: {
      token: string;
      bridge: string;
    };
    webkit?: {
      messageHandlers?: {
        relaycode?: {
          postMessage: (message: NativeMessage) => void;
        };
      };
    };
  }
}

export type ConnectionState = "unpaired" | "connecting" | "connected" | "disconnected";

const tokenKey = "relaycode.pairToken";
const bridgeKey = "relaycode.bridgeUrl";

function defaultBridgeUrl(): string {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${location.host}/ws`;
}

function nativePairing(): { token: string; bridge: string } | null {
  const value = window.__RELAYCODE_NATIVE_PAIRING__;
  if (!window.__RELAYCODE_NATIVE__ || !value) return null;
  return {
    token: typeof value.token === "string" ? value.token : "",
    bridge: typeof value.bridge === "string" ? value.bridge : defaultBridgeUrl(),
  };
}

function postNative(message: NativeMessage): boolean {
  const handler = window.webkit?.messageHandlers?.relaycode;
  if (!window.__RELAYCODE_NATIVE__ || !handler) return false;
  handler.postMessage(message);
  return true;
}

export function consumePairingFragment(): void {
  const params = new URLSearchParams(location.hash.replace(/^#/, ""));
  const token = params.get("pair");
  const bridge = params.get("bridge");
  if (token || bridge) {
    const current = pairingConfig();
    savePairing(token || current.token, bridge || current.bridge);
    history.replaceState(null, "", `${location.pathname}${location.search}`);
  }
}

export function pairingConfig(): { token: string; bridge: string } {
  const native = nativePairing();
  if (native) return native;
  return {
    token: localStorage.getItem(tokenKey) || "",
    bridge: localStorage.getItem(bridgeKey) || defaultBridgeUrl(),
  };
}

export function savePairing(token: string, bridge: string): void {
  const pairing = { token: token.trim(), bridge: bridge.trim() };
  if (window.__RELAYCODE_NATIVE__) {
    window.__RELAYCODE_NATIVE_PAIRING__ = pairing;
    postNative({ type: "savePairing", ...pairing });
    return;
  }
  localStorage.setItem(tokenKey, pairing.token);
  localStorage.setItem(bridgeKey, pairing.bridge);
}

export function clearPairing(): void {
  if (window.__RELAYCODE_NATIVE__) {
    window.__RELAYCODE_NATIVE_PAIRING__ = { token: "", bridge: defaultBridgeUrl() };
    postNative({ type: "clearPairing" });
  }
  localStorage.removeItem(tokenKey);
  localStorage.removeItem(bridgeKey);
}

export class BridgeClient {
  private socket: WebSocket | null = null;
  private listeners = new Set<Listener>();
  private stateListeners = new Set<StateListener>();
  private pending = new Map<string, Pending>();
  private reconnectTimer?: number;
  private reconnectAttempt = 0;
  private manuallyClosed = false;
  state: ConnectionState = pairingConfig().token ? "disconnected" : "unpaired";
  status?: BridgeStatus;

  connect(): void {
    const { token, bridge } = pairingConfig();
    if (!token || !bridge) {
      this.setState("unpaired");
      return;
    }
    if (
      this.socket
      && (this.socket.readyState === WebSocket.CONNECTING || this.socket.readyState === WebSocket.OPEN)
    ) return;
    this.manuallyClosed = false;
    this.setState("connecting");
    const socket = new WebSocket(bridge, [WS_PROTOCOL, `${WS_AUTH_PREFIX}${token}`]);
    this.socket = socket;
    socket.addEventListener("open", () => {
      this.reconnectAttempt = 0;
      this.setState("connected");
    });
    socket.addEventListener("message", (event) => {
      let message: ServerMessage;
      try {
        message = JSON.parse(String(event.data)) as ServerMessage;
      } catch {
        return;
      }
      if (message.type === "hello" || message.type === "status") this.status = message.status;
      if (message.type === "rpcResult") {
        const pending = this.pending.get(message.id);
        if (pending) {
          window.clearTimeout(pending.timer);
          this.pending.delete(message.id);
          if (message.error) pending.reject(new Error(message.error.message));
          else pending.resolve(message.result);
        }
      }
      for (const listener of this.listeners) listener(message);
    });
    socket.addEventListener("close", () => {
      if (this.socket === socket) this.socket = null;
      this.rejectPending(new Error("Mac 연결이 끊겼습니다."));
      if (!this.manuallyClosed) {
        this.setState("disconnected");
        this.scheduleReconnect();
      }
    });
    socket.addEventListener("error", () => {
      // close carries the reconnect path.
    });
  }

  disconnect(): void {
    this.manuallyClosed = true;
    if (this.reconnectTimer) window.clearTimeout(this.reconnectTimer);
    this.socket?.close(1000, "Client disconnected");
    this.socket = null;
    this.setState(pairingConfig().token ? "disconnected" : "unpaired");
  }

  rpc<T = unknown>(method: AllowedMethod, params?: unknown): Promise<T> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("Mac과 연결되어 있지 않습니다."));
    }
    const id = crypto.randomUUID();
    this.socket.send(JSON.stringify({ type: "rpc", id, method, params }));
    return new Promise<T>((resolve, reject) => {
      const timer = window.setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} 응답 시간이 초과됐습니다.`));
      }, 35_000);
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        timer,
      });
    });
  }

  respondServerRequest(id: number | string, result: unknown): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Mac과 연결되어 있지 않습니다.");
    }
    this.socket.send(JSON.stringify({ type: "serverResponse", id, result }));
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  subscribeState(listener: StateListener): () => void {
    this.stateListeners.add(listener);
    listener(this.state);
    return () => this.stateListeners.delete(listener);
  }

  private setState(state: ConnectionState): void {
    this.state = state;
    for (const listener of this.stateListeners) listener(state);
  }

  private scheduleReconnect(): void {
    const delay = Math.min(1_000 * 2 ** this.reconnectAttempt, 15_000) + Math.random() * 500;
    this.reconnectAttempt += 1;
    this.reconnectTimer = window.setTimeout(() => this.connect(), delay);
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      window.clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

export const bridgeClient = new BridgeClient();

window.addEventListener("relaycode:native-resume", () => {
  bridgeClient.connect();
});
