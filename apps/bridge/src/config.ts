import { createHash, randomBytes } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join, resolve } from "node:path";

export type RelayConfig = {
  version: 1;
  displayName: string;
  host: string;
  port: number;
  workspaceRoots: string[];
  tokenHash: string;
  publicUrl?: string;
};

export type LoadedConfig = {
  config: RelayConfig;
  path: string;
  newPairToken?: string;
};

const configHome = process.env.RELAYCODE_HOME?.trim()
  ? resolve(process.env.RELAYCODE_HOME)
  : join(homedir(), ".relaycode");

export const configPath = join(configHome, "config.json");

export function hashToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export function currentTokenHash(): string {
  const envToken = process.env.RELAYCODE_TOKEN?.trim();
  if (envToken) return hashToken(envToken);
  const parsed = JSON.parse(readFileSync(configPath, "utf8")) as { tokenHash?: unknown };
  if (typeof parsed.tokenHash !== "string" || !/^[a-f0-9]{64}$/.test(parsed.tokenHash)) {
    throw new Error("RelayCode config has an invalid pairing verifier.");
  }
  return parsed.tokenHash;
}

export function newPairToken(): string {
  return randomBytes(32).toString("base64url");
}

function configuredRoots(): string[] {
  const raw = process.env.RELAYCODE_WORKSPACE_ROOTS?.trim();
  const initial = process.env.INIT_CWD?.trim() || process.cwd();
  const values = raw ? raw.split(":") : [initial];
  return [...new Set(values.map((value) => resolve(value.trim())).filter(Boolean))];
}

function ensurePrivateHome(): void {
  mkdirSync(configHome, { recursive: true, mode: 0o700 });
  try {
    chmodSync(configHome, 0o700);
  } catch {
    // Some filesystems do not implement POSIX modes.
  }
}

export function writeConfig(config: RelayConfig): void {
  ensurePrivateHome();
  const temporary = `${configPath}.tmp-${process.pid}`;
  writeFileSync(temporary, `${JSON.stringify(config, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  try {
    chmodSync(temporary, 0o600);
  } catch {
    // Best effort on non-POSIX filesystems.
  }
  renameSync(temporary, configPath);
}

export function normalizePublicUrl(value: string | undefined): string | undefined {
  if (!value?.trim()) return undefined;
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error("RelayCode public URL must be a valid absolute URL.");
  }
  const loopback = url.hostname === "127.0.0.1"
    || url.hostname === "localhost"
    || url.hostname === "::1"
    || url.hostname === "[::1]";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new Error("RelayCode public URL must use HTTPS; HTTP is allowed only on loopback.");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("RelayCode public URL cannot contain credentials, a query, or a fragment.");
  }
  if (url.pathname !== "/" && url.pathname !== "") {
    throw new Error("RelayCode public URL must not contain a path.");
  }
  url.pathname = "/";
  return url.toString().replace(/\/$/, "");
}

function validWorkspaceRoots(values: string[]): string[] {
  const roots = values.map((value) => {
    const absolute = resolve(value.trim());
    if (!existsSync(absolute)) throw new Error(`Workspace root does not exist: ${absolute}`);
    if (!statSync(absolute).isDirectory()) throw new Error(`Workspace root is not a directory: ${absolute}`);
    return realpathSync(absolute);
  });
  if (roots.length === 0) throw new Error("RelayCode requires at least one workspace root.");
  return [...new Set(roots)];
}

function normalizeConfig(value: unknown): RelayConfig {
  if (!value || typeof value !== "object") throw new Error("RelayCode config must be an object.");
  const raw = value as Partial<RelayConfig>;
  if (raw.version !== 1) throw new Error("Unsupported RelayCode config version.");
  if (typeof raw.tokenHash !== "string" || !/^[a-f0-9]{64}$/.test(raw.tokenHash)) {
    throw new Error("RelayCode config has an invalid pairing verifier.");
  }
  const roots = Array.isArray(raw.workspaceRoots)
    ? validWorkspaceRoots(raw.workspaceRoots.filter((item): item is string => typeof item === "string"))
    : [];
  const port = Number(process.env.RELAYCODE_PORT || raw.port || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid RELAYCODE_PORT.");
  const publicUrl = normalizePublicUrl(
    process.env.RELAYCODE_PUBLIC_URL?.trim()
      || process.env.RELAYCODE_WEB_URL?.trim()
      || raw.publicUrl,
  );
  return {
    version: 1,
    displayName: process.env.RELAYCODE_NAME?.trim() || raw.displayName || hostname(),
    host: process.env.RELAYCODE_HOST?.trim() || raw.host || "127.0.0.1",
    port,
    workspaceRoots: roots,
    tokenHash: raw.tokenHash,
    publicUrl,
  };
}

export function readConfig(): RelayConfig | null {
  ensurePrivateHome();
  if (!existsSync(configPath)) return null;
  return normalizeConfig(JSON.parse(readFileSync(configPath, "utf8")) as unknown);
}

export function configure(options: {
  workspaceRoots: string[];
  publicUrl?: string;
  displayName?: string;
  host?: string;
  port?: number;
}): { config: RelayConfig; token: string } {
  const token = newPairToken();
  const config = normalizeConfig({
    version: 1,
    displayName: options.displayName?.trim() || hostname(),
    host: options.host?.trim() || "127.0.0.1",
    port: options.port || 8787,
    workspaceRoots: options.workspaceRoots,
    tokenHash: hashToken(token),
    publicUrl: options.publicUrl,
  });
  writeConfig(config);
  return { config, token };
}

export function loadConfig(): LoadedConfig {
  ensurePrivateHome();
  const envToken = process.env.RELAYCODE_TOKEN?.trim();
  const existing = readConfig();
  if (!existing) {
    const token = envToken || newPairToken();
    const config: RelayConfig = {
      version: 1,
      displayName: process.env.RELAYCODE_NAME?.trim() || hostname(),
      host: process.env.RELAYCODE_HOST?.trim() || "127.0.0.1",
      port: Number(process.env.RELAYCODE_PORT || 8787),
      workspaceRoots: configuredRoots(),
      tokenHash: hashToken(token),
    };
    const normalized = normalizeConfig(config);
    writeConfig(normalized);
    return { config: normalized, path: configPath, newPairToken: token };
  }

  const config = existing;
  if (envToken) config.tokenHash = hashToken(envToken);
  return { config, path: configPath };
}

export function rotatePairToken(): { config: RelayConfig; token: string } {
  const loaded = loadConfig();
  const token = newPairToken();
  const config = { ...loaded.config, tokenHash: hashToken(token) };
  writeConfig(config);
  return { config, token };
}

export function canonicalRoots(config: RelayConfig): string[] {
  return config.workspaceRoots.map((root) => {
    try {
      return realpathSync(root);
    } catch {
      return resolve(root);
    }
  });
}

export function configDirectory(): string {
  return dirname(configPath);
}
