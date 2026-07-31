import { execFileSync, spawnSync } from "node:child_process";
import { statSync } from "node:fs";
import { hostname } from "node:os";
import { resolve } from "node:path";
import {
  configPath,
  configure,
  loadConfig,
  readConfig,
  rotatePairToken,
  type RelayConfig,
} from "./config.js";
import { printPairing } from "./pair.js";
import { RelayServer } from "./server.js";

export const relayCodeVersion = "0.2.0";

export type CliOptions = {
  command: "help" | "version" | "setup" | "serve" | "pair" | "status" | "doctor";
  workspaces: string[];
  publicUrl?: string;
  port?: number;
  skipTailscale: boolean;
  noService: boolean;
};

function valueAfter(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value.`);
  return value;
}

export function parseCliArgs(args: string[]): CliOptions {
  const first = args[0];
  const command = first === undefined || first === "help" || first === "--help" || first === "-h"
    ? "help"
    : first === "--version" || first === "-v" || first === "version"
      ? "version"
      : first;
  if (!["help", "version", "setup", "serve", "pair", "status", "doctor"].includes(command)) {
    throw new Error(`Unknown command: ${command}`);
  }

  const options: CliOptions = {
    command: command as CliOptions["command"],
    workspaces: [],
    skipTailscale: false,
    noService: false,
  };
  for (let index = 1; index < args.length; index += 1) {
    const argument = args[index];
    switch (argument) {
      case "--workspace":
      case "-w":
        options.workspaces.push(resolve(valueAfter(args, index, argument)));
        index += 1;
        break;
      case "--public-url":
        options.publicUrl = valueAfter(args, index, argument);
        index += 1;
        break;
      case "--port": {
        const port = Number(valueAfter(args, index, argument));
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          throw new Error("--port must be an integer between 1 and 65535.");
        }
        options.port = port;
        index += 1;
        break;
      }
      case "--skip-tailscale":
        options.skipTailscale = true;
        break;
      case "--no-service":
        options.noService = true;
        break;
      default:
        throw new Error(`Unknown option: ${argument}`);
    }
  }
  return options;
}

function capture(command: string, args: string[]): string | null {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 10_000,
    }).trim();
  } catch {
    return null;
  }
}

function checkCodex(): { version: string; authenticated: boolean } {
  const version = capture(process.env.CODEX_BIN || "codex", ["--version"]);
  if (!version) {
    throw new Error(
      "Codex CLI was not found. Install it with `npm install --global @openai/codex`, then run `codex login`.",
    );
  }
  const authenticated = capture(process.env.CODEX_BIN || "codex", ["login", "status"]) !== null;
  if (!authenticated) {
    throw new Error("Codex is not authenticated. Run `codex login`, then retry `relaycode setup`.");
  }
  return { version, authenticated };
}

type TailscaleStatus = {
  BackendState?: unknown;
  Self?: {
    DNSName?: unknown;
    Online?: unknown;
  };
};

export function tailscalePublicUrl(raw: string): string | null {
  let status: TailscaleStatus;
  try {
    status = JSON.parse(raw) as TailscaleStatus;
  } catch {
    return null;
  }
  if (status.BackendState !== "Running" || status.Self?.Online !== true) return null;
  if (typeof status.Self.DNSName !== "string" || !status.Self.DNSName.trim()) return null;
  const host = status.Self.DNSName.trim().replace(/\.$/, "");
  return `https://${host}`;
}

type TailscaleServeStatus = {
  TCP?: Record<string, unknown>;
  Web?: Record<string, {
    Handlers?: Record<string, {
      Proxy?: unknown;
    }>;
  }>;
};

function portFromServeHost(host: string): number | null {
  const match = host.match(/:(\d+)$/);
  if (!match) return 443;
  const port = Number(match[1]);
  return Number.isInteger(port) ? port : null;
}

export function chooseTailscaleHttpsPort(raw: string, relayPort: number): number {
  let status: TailscaleServeStatus = {};
  try {
    status = JSON.parse(raw) as TailscaleServeStatus;
  } catch {
    // Treat unreadable status as empty and let the serve command validate it.
  }
  const targets = new Set([
    `http://127.0.0.1:${relayPort}`,
    `http://localhost:${relayPort}`,
  ]);
  const used = new Set<number>();
  for (const key of Object.keys(status.TCP || {})) {
    const port = Number(key);
    if (Number.isInteger(port)) used.add(port);
  }
  for (const [host, site] of Object.entries(status.Web || {})) {
    const port = portFromServeHost(host);
    if (port !== null) used.add(port);
    const proxy = site.Handlers?.["/"]?.Proxy;
    if (port !== null && typeof proxy === "string" && targets.has(proxy.replace(/\/+$/, ""))) {
      return port;
    }
  }
  if (!used.has(443)) return 443;
  for (let port = 8443; port <= 8453; port += 1) {
    if (!used.has(port)) return port;
  }
  throw new Error("No free Tailscale HTTPS port was found between 8443 and 8453.");
}

function configureTailscale(port: number): string | null {
  const raw = capture(process.env.TAILSCALE_BIN || "tailscale", ["status", "--json"]);
  if (!raw) return null;
  const baseUrl = tailscalePublicUrl(raw);
  if (!baseUrl) return null;
  const serveStatus = capture(process.env.TAILSCALE_BIN || "tailscale", ["serve", "status", "--json"]) || "{}";
  const httpsPort = chooseTailscaleHttpsPort(serveStatus, port);
  const result = spawnSync(
    process.env.TAILSCALE_BIN || "tailscale",
    ["serve", "--bg", `--https=${httpsPort}`, `http://127.0.0.1:${port}`],
    { stdio: "inherit" },
  );
  if (result.status !== 0) {
    throw new Error("Tailscale Serve could not be configured.");
  }
  return httpsPort === 443 ? baseUrl : `${baseUrl}:${httpsPort}`;
}

function restartHomebrewService(): boolean {
  if (!capture("brew", ["--prefix", "relaycode"])) return false;
  const result = spawnSync("brew", ["services", "restart", "relaycode"], { stdio: "inherit" });
  return result.status === 0;
}

function printHelp(): void {
  console.log(`RelayCode ${relayCodeVersion}

Mobile-first remote control for local Codex development.

Usage:
  relaycode setup [options]   Configure workspaces, Tailscale, and pairing
  relaycode serve             Run the local bridge in the foreground
  relaycode pair              Rotate the phone pairing credential
  relaycode status            Show local bridge and configuration status
  relaycode doctor            Check Codex, config, Tailscale, and bridge health

Setup options:
  -w, --workspace <path>      Allowed workspace root; repeat for more roots
      --public-url <https>    Private HTTPS URL when not using Tailscale
      --port <number>         Loopback bridge port (default: 8787)
      --skip-tailscale        Do not configure Tailscale Serve
      --no-service            Do not start the Homebrew background service

Security:
  RelayCode binds to 127.0.0.1 and should be shared only through a private
  authenticated HTTPS network such as Tailscale Serve. Never use Funnel.`);
}

async function setup(options: CliOptions): Promise<void> {
  const codex = checkCodex();
  const port = options.port || 8787;
  const workspaces = options.workspaces.length > 0 ? options.workspaces : [process.cwd()];
  const publicUrl = options.publicUrl
    || (options.skipTailscale ? undefined : configureTailscale(port))
    || undefined;
  const { config, token } = configure({
    workspaceRoots: workspaces,
    publicUrl,
    displayName: hostname(),
    host: "127.0.0.1",
    port,
  });

  console.log(`\nRelayCode configured.`);
  console.log(`Codex: ${codex.version}`);
  console.log(`Config: ${configPath}`);
  console.log(`Workspaces:\n${config.workspaceRoots.map((root) => `  - ${root}`).join("\n")}`);
  if (publicUrl) {
    console.log(`Private URL: ${publicUrl}`);
  } else {
    console.log(
      "Private URL: not configured. Install and connect Tailscale, then rerun setup without --skip-tailscale.",
    );
  }

  let serviceStarted = false;
  if (!options.noService) serviceStarted = restartHomebrewService();
  console.log(serviceStarted
    ? "Service: running through Homebrew"
    : "Service: not started; run `relaycode serve` or `brew services start relaycode`.");
  printPairing(config, token);
}

async function serve(): Promise<void> {
  const loaded = loadConfig();
  const server = new RelayServer(loaded.config);
  await server.listen();

  console.log(`RelayCode bridge listening on http://${loaded.config.host}:${loaded.config.port}`);
  console.log(`Config: ${loaded.path}`);
  console.log(`Workspace roots: ${loaded.config.workspaceRoots.join(", ")}`);
  if (loaded.newPairToken) printPairing(loaded.config, loaded.newPairToken);
  else console.log("Run `relaycode pair` when you need to pair or rotate a phone.");

  const shutdown = () => {
    server.close();
    process.exit(0);
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

async function status(): Promise<void> {
  const config = readConfig();
  if (!config) throw new Error("RelayCode is not configured. Run `relaycode setup`.");
  let health: { ok?: boolean; agent?: string } | null = null;
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/healthz`, {
      signal: AbortSignal.timeout(2_000),
    });
    health = response.ok ? await response.json() as { ok?: boolean; agent?: string } : null;
  } catch {
    health = null;
  }
  console.log(`RelayCode ${relayCodeVersion}`);
  console.log(`Bridge: ${health?.ok ? `running (${health.agent || "unknown"})` : "offline"}`);
  console.log(`Local URL: http://127.0.0.1:${config.port}`);
  console.log(`Private URL: ${config.publicUrl || "not configured"}`);
  console.log(`Workspaces:\n${config.workspaceRoots.map((root) => `  - ${root}`).join("\n")}`);
}

type DoctorResult = {
  label: string;
  ok: boolean;
  required: boolean;
  detail: string;
};

function printDoctor(result: DoctorResult): void {
  console.log(`${result.ok ? "✓" : result.required ? "✗" : "!"} ${result.label}: ${result.detail}`);
}

async function doctor(): Promise<void> {
  const config = readConfig();
  const nodeMajor = Number(process.versions.node.split(".")[0]);
  const codexVersion = capture(process.env.CODEX_BIN || "codex", ["--version"]);
  const codexLogin = codexVersion
    ? capture(process.env.CODEX_BIN || "codex", ["login", "status"])
    : null;
  const tailscaleRaw = capture(process.env.TAILSCALE_BIN || "tailscale", ["status", "--json"]);
  const tailscaleUrl = tailscaleRaw ? tailscalePublicUrl(tailscaleRaw) : null;

  let bridgeHealthy = false;
  if (config) {
    try {
      bridgeHealthy = (await fetch(`http://127.0.0.1:${config.port}/healthz`, {
        signal: AbortSignal.timeout(2_000),
      })).ok;
    } catch {
      bridgeHealthy = false;
    }
  }
  const privateMode = config
    ? (statSync(configPath).mode & 0o077) === 0
    : false;
  const results: DoctorResult[] = [
    {
      label: "Node.js",
      ok: nodeMajor >= 20,
      required: true,
      detail: process.versions.node,
    },
    {
      label: "Codex CLI",
      ok: Boolean(codexVersion),
      required: true,
      detail: codexVersion || "not found",
    },
    {
      label: "Codex login",
      ok: codexLogin !== null,
      required: true,
      detail: codexLogin === null ? "run `codex login`" : codexLogin || "authenticated",
    },
    {
      label: "Config",
      ok: Boolean(config) && privateMode,
      required: true,
      detail: !config ? "run `relaycode setup`" : privateMode ? configPath : "permissions are too broad",
    },
    {
      label: "Tailscale",
      ok: Boolean(tailscaleUrl),
      required: false,
      detail: tailscaleUrl || "not connected; another private HTTPS tunnel is required",
    },
    {
      label: "Bridge",
      ok: bridgeHealthy,
      required: false,
      detail: bridgeHealthy ? "healthy" : "offline",
    },
  ];
  results.forEach(printDoctor);
  if (results.some((result) => result.required && !result.ok)) process.exitCode = 1;
}

export async function runCli(args: string[]): Promise<void> {
  const options = parseCliArgs(args);
  switch (options.command) {
    case "help":
      printHelp();
      return;
    case "version":
      console.log(`RelayCode ${relayCodeVersion}`);
      return;
    case "setup":
      await setup(options);
      return;
    case "serve":
      await serve();
      return;
    case "pair": {
      const { config, token } = rotatePairToken();
      printPairing(config, token);
      return;
    }
    case "status":
      await status();
      return;
    case "doctor":
      await doctor();
  }
}
