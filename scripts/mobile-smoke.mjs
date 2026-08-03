import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer as createNetServer } from "node:net";
import { tmpdir } from "node:os";
import { extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocket, WebSocketServer } from "ws";

let targetUrl = process.env.RELAYCODE_SMOKE_URL;
const chromeCandidates = [
  process.env.CHROME_BIN,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
].filter(Boolean);

async function availablePort() {
  const server = createNetServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function fixtureResult(method, params) {
  const status = {
    protocolVersion: 1,
    bridgeVersion: "smoke",
    hostName: "QA Mac",
    agent: { id: "codex", label: "Codex", state: "ready", version: "smoke" },
    workspaceRoots: ["/fixture"],
    capabilities: {
      workspaceFiles: true,
      git: true,
      terminal: { available: true },
    },
  };
  switch (method) {
    case "relay/status":
      return status;
    case "relay/workspaces":
      return [{ path: "/fixture", name: "fixture" }];
    case "model/list":
      return {
        data: [{
          id: "gpt-smoke",
          model: "gpt-smoke",
          displayName: "Smoke model",
          isDefault: true,
          supportedReasoningEfforts: ["medium"],
        }],
      };
    case "thread/list":
      return { data: [] };
    case "account/read":
      return { account: { email: "qa@example.com", planType: "test" } };
    case "account/rateLimits/read":
      return { rateLimits: { primary: { usedPercent: 10 }, secondary: { usedPercent: 20 } } };
    case "account/usage/read":
      return { summary: { lifetimeTokens: 1234, currentStreakDays: 2, longestRunningTurnSec: 180 } };
    case "workspace/entries":
      return {
        path: String(params?.path || ""),
        parent: params?.path ? "" : null,
        entries: [
          { name: "src", path: "src", kind: "directory", size: 0, modifiedAt: 0, editable: false },
          { name: "README.md", path: "README.md", kind: "file", size: 18, modifiedAt: 0, editable: true },
        ],
        truncated: false,
      };
    case "workspace/file/read":
      return {
        path: "README.md",
        content: "# RelayCode fixture\n",
        hash: "a".repeat(64),
        size: 20,
        modifiedAt: 0,
        language: "markdown",
      };
    case "workspace/file/write":
      return {
        path: "README.md",
        hash: "b".repeat(64),
        size: String(params?.content || "").length,
        modifiedAt: Date.now(),
      };
    case "workspace/search":
      return {
        results: [{ path: "README.md", line: 1, column: 3, preview: "# RelayCode fixture" }],
      };
    case "workspace/git/status":
      return {
        branch: "codex/remote-studio",
        upstream: "origin/codex/remote-studio",
        summary: "codex/remote-studio",
        entries: [{ index: " ", workingTree: "M", path: "README.md" }],
        clean: false,
        truncated: false,
      };
    case "workspace/git/diff":
      return { path: "README.md", staged: false, diff: "-old\n+new\n", truncated: false };
    case "terminal/session/list":
      return { capability: { available: true }, sessions: [] };
    case "terminal/session/start":
      return {
        id: "terminal-smoke",
        workspace: "/fixture",
        network: false,
        output: "RelayCode sandbox · fixture · network off\n",
        sequence: 1,
        state: "running",
      };
    case "terminal/session/write":
      return { accepted: true, sequence: 2 };
    case "terminal/session/interrupt":
      return { interrupted: true };
    case "terminal/session/close":
      return { closed: true };
    default:
      return {};
  }
}

async function startFixtureServer() {
  const mobileRoot = resolve(
    fileURLToPath(new URL("../apps/mobile/dist/", import.meta.url)),
  );
  const port = await availablePort();
  const mime = {
    ".css": "text/css; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".webmanifest": "application/manifest+json",
  };
  const server = createHttpServer((request, response) => {
    const pathname = decodeURIComponent(new URL(request.url || "/", "http://localhost").pathname);
    const relative = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
    const candidate = resolve(mobileRoot, relative);
    const safe = candidate === mobileRoot || candidate.startsWith(`${mobileRoot}${sep}`);
    const target = safe && existsSync(candidate) && statSync(candidate).isFile()
      ? candidate
      : resolve(mobileRoot, "index.html");
    response.writeHead(200, {
      "Content-Type": mime[extname(target)] || "application/octet-stream",
      "Cache-Control": "no-store",
    });
    response.end(readFileSync(target));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (request, socket, head) => {
    if (new URL(request.url || "/", "http://localhost").pathname !== "/ws") {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(request, socket, head, (client) => wss.emit("connection", client));
  });
  wss.on("connection", (client) => {
    client.send(JSON.stringify({
      type: "hello",
      status: fixtureResult("relay/status"),
    }));
    client.on("message", (data) => {
      const message = JSON.parse(String(data));
      if (message.type === "ping") {
        client.send(JSON.stringify({ type: "pong", sentAt: message.sentAt, receivedAt: Date.now() }));
        return;
      }
      if (message.type !== "rpc") return;
      const result = fixtureResult(message.method, message.params);
      client.send(JSON.stringify({ type: "rpcResult", id: message.id, result }));
      if (message.method === "terminal/session/write") {
        client.send(JSON.stringify({
          type: "notification",
          method: "terminal/output",
          params: {
            sessionId: "terminal-smoke",
            sequence: 2,
            stream: "stdout",
            data: "REMOTE_OK\n",
          },
        }));
      }
    });
  });
  await new Promise((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolvePromise);
  });
  return {
    url: `http://127.0.0.1:${port}/#pair=smoke-token&bridge=ws%3A%2F%2F127.0.0.1%3A${port}%2Fws`,
    close: async () => {
      for (const client of wss.clients) client.close();
      server.closeAllConnections();
      await new Promise((resolvePromise) => server.close(resolvePromise));
    },
  };
}

async function waitForTarget(port) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`);
      const targets = await response.json();
      const page = targets.find((target) => target.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {
      // Chrome is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Chrome DevTools endpoint did not become ready.");
}

class CdpClient {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
    this.waiters = new Map();
    this.events = [];
  }

  async open() {
    await new Promise((resolve, reject) => {
      this.socket.once("open", resolve);
      this.socket.once("error", reject);
    });
    this.socket.on("message", (data) => {
      const message = JSON.parse(String(data));
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
        return;
      }
      this.events.push(message);
      const listeners = this.waiters.get(message.method);
      if (!listeners?.length) return;
      this.waiters.delete(message.method);
      for (const resolve of listeners) resolve(message.params);
    });
  }

  call(method, params = {}) {
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
  }

  waitFor(method, timeoutMs = 10_000) {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`${method} timed out.`)), timeoutMs);
      const wrapped = (params) => {
        clearTimeout(timeout);
        resolve(params);
      };
      this.waiters.set(method, [...(this.waiters.get(method) || []), wrapped]);
    });
  }

  close() {
    this.socket.close();
  }
}

const chromeBin = chromeCandidates.find((candidate) => existsSync(candidate));
if (!chromeBin) throw new Error("Chrome executable not found. Set CHROME_BIN.");

const fixture = targetUrl ? null : await startFixtureServer();
targetUrl ||= fixture.url;
const qaDir = mkdtempSync(join(tmpdir(), "relaycode-mobile-smoke-"));
const profileDir = join(qaDir, "profile");
const screenshotPath = join(qaDir, "mobile.png");
const port = await availablePort();
const chrome = spawn(chromeBin, [
  "--headless=new",
  "--disable-gpu",
  "--hide-scrollbars",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-background-networking",
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${profileDir}`,
  "about:blank",
], {
  stdio: ["ignore", "ignore", "pipe"],
});

let stderr = "";
chrome.stderr.on("data", (chunk) => {
  stderr = `${stderr}${String(chunk)}`.slice(-8_000);
});

let cdp;
try {
  const endpoint = await waitForTarget(port);
  cdp = new CdpClient(endpoint);
  await cdp.open();
  await Promise.all([
    cdp.call("Page.enable"),
    cdp.call("Runtime.enable"),
    cdp.call("Log.enable"),
    cdp.call("Network.enable"),
    cdp.call("Emulation.setDeviceMetricsOverride", {
      width: 375,
      height: 812,
      deviceScaleFactor: 2,
      mobile: true,
      screenWidth: 375,
      screenHeight: 812,
    }),
  ]);
  await cdp.call("Page.addScriptToEvaluateOnNewDocument", {
    source: `
      window.__relayCodeSocketEvents = [];
      const RelayCodeNativeWebSocket = window.WebSocket;
      window.WebSocket = class RelayCodeObservedWebSocket extends RelayCodeNativeWebSocket {
        constructor(...args) {
          super(...args);
          this.addEventListener("open", () => window.__relayCodeSocketEvents.push({ type: "open" }));
          this.addEventListener("message", (event) => window.__relayCodeSocketEvents.push({
            type: "message",
            dataType: typeof event.data,
            size: typeof event.data === "string" ? event.data.length : event.data?.size || 0
          }));
          this.addEventListener("close", (event) => window.__relayCodeSocketEvents.push({
            type: "close",
            code: event.code
          }));
        }
      };
    `,
  });

  const loaded = cdp.waitFor("Page.loadEventFired");
  await cdp.call("Page.navigate", { url: targetUrl });
  await loaded;

  let state;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    const result = await cdp.call("Runtime.evaluate", {
      expression: `JSON.stringify({
        ready: document.readyState,
        pairScreen: Boolean(document.querySelector(".pair-screen")),
        status: document.querySelector(".status-pill")?.textContent?.trim() || null,
        loading: Boolean(document.querySelector(".loading-card")),
        threadCount: document.querySelectorAll(".thread-card").length
      })`,
      returnByValue: true,
    });
    state = JSON.parse(result.result.value);
    if (state.ready === "complete" && !state.pairScreen && state.status === "연결됨" && !state.loading) break;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  const evaluated = await cdp.call("Runtime.evaluate", {
    expression: `JSON.stringify({
      viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
      scrollWidth: document.documentElement.scrollWidth,
      horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
      pairScreen: Boolean(document.querySelector(".pair-screen")),
      status: document.querySelector(".status-pill")?.textContent?.trim() || null,
      loading: Boolean(document.querySelector(".loading-card")),
      threadCount: document.querySelectorAll(".thread-card").length,
      navItems: document.querySelectorAll(".bottom-nav button").length,
      socketEvents: window.__relayCodeSocketEvents || []
    })`,
    returnByValue: true,
  });
  const pageState = JSON.parse(evaluated.result.value);
  await cdp.call("Runtime.evaluate", {
    expression: "document.querySelector('.bottom-nav button:nth-child(2)')?.click()",
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  const launchResult = await cdp.call("Runtime.evaluate", {
    expression: `JSON.stringify({
      visible: Boolean(document.querySelector(".launch-form")),
      workspaceOptions: document.querySelectorAll(".launch-form label:first-child option").length,
      modelOptions: document.querySelectorAll(".launch-form select")[1]?.options?.length || 0,
      effortOptions: document.querySelectorAll(".effort-grid button").length,
      launchDisabled: Boolean(document.querySelector(".launch-button")?.disabled),
      horizontalOverflow: document.documentElement.scrollWidth > innerWidth
    })`,
    returnByValue: true,
  });
  const launchState = JSON.parse(launchResult.result.value);

  await cdp.call("Runtime.evaluate", {
    expression: "document.querySelector('.bottom-nav button:nth-child(3)')?.click()",
  });
  await new Promise((resolve) => setTimeout(resolve, 250));
  const workspaceResult = await cdp.call("Runtime.evaluate", {
    expression: `JSON.stringify({
      visible: Boolean(document.querySelector(".workspace-screen")),
      tabs: document.querySelectorAll(".workspace-tabs button").length,
      entries: document.querySelectorAll(".file-list > button").length,
      horizontalOverflow: document.documentElement.scrollWidth > innerWidth
    })`,
    returnByValue: true,
  });
  const workspaceState = JSON.parse(workspaceResult.result.value);
  await cdp.call("Runtime.evaluate", {
    expression: "document.querySelector('.workspace-tabs button:nth-child(2)')?.click()",
  });
  await new Promise((resolve) => setTimeout(resolve, 200));
  const gitResult = await cdp.call("Runtime.evaluate", {
    expression: `JSON.stringify({
      branch: document.querySelector(".git-summary strong")?.textContent?.trim() || null,
      files: document.querySelectorAll(".git-file-list > button").length
    })`,
    returnByValue: true,
  });
  const gitState = JSON.parse(gitResult.result.value);
  await cdp.call("Runtime.evaluate", {
    expression: "document.querySelector('.workspace-tabs button:nth-child(3)')?.click()",
  });
  await new Promise((resolve) => setTimeout(resolve, 200));
  const terminalResult = await cdp.call("Runtime.evaluate", {
    expression: `JSON.stringify({
      startButton: Boolean(document.querySelector(".terminal-controls button")),
      boundary: Boolean(document.querySelector(".workspace-boundary"))
    })`,
    returnByValue: true,
  });
  const terminalState = JSON.parse(terminalResult.result.value);

  await cdp.call("Runtime.evaluate", {
    expression: "document.querySelector('.bottom-nav button:nth-child(4)')?.click()",
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  const usageResult = await cdp.call("Runtime.evaluate", {
    expression: `JSON.stringify({
      accountCard: Boolean(document.querySelector(".account-card")),
      quotaCards: document.querySelectorAll(".quota-grid article").length,
      statCards: document.querySelectorAll(".stat-grid article").length,
      horizontalOverflow: document.documentElement.scrollWidth > innerWidth
    })`,
    returnByValue: true,
  });
  const usageState = JSON.parse(usageResult.result.value);

  await cdp.call("Runtime.evaluate", {
    expression: "document.querySelector('.bottom-nav button:nth-child(5)')?.click()",
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  const settingsResult = await cdp.call("Runtime.evaluate", {
    expression: `JSON.stringify({
      rows: document.querySelectorAll(".settings-list article").length,
      securityCard: Boolean(document.querySelector(".security-card")),
      disconnectButton: Boolean(document.querySelector(".danger-button")),
      horizontalOverflow: document.documentElement.scrollWidth > innerWidth
    })`,
    returnByValue: true,
  });
  const settingsState = JSON.parse(settingsResult.result.value);

  await cdp.call("Runtime.evaluate", {
    expression: "document.querySelector('.bottom-nav button:nth-child(3)')?.click()",
  });
  await new Promise((resolve) => setTimeout(resolve, 250));
  const screenshot = await cdp.call("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: false,
  });
  writeFileSync(screenshotPath, Buffer.from(screenshot.data, "base64"));

  const runtimeErrors = cdp.events
    .filter((event) => event.method === "Runtime.exceptionThrown")
    .map((event) => event.params?.exceptionDetails?.text || "Runtime exception");
  const logErrors = cdp.events
    .filter((event) => event.method === "Log.entryAdded" && event.params?.entry?.level === "error")
    .map((event) => event.params.entry.text);
  const networkFailures = cdp.events
    .filter((event) => event.method === "Network.loadingFailed" && !event.params?.canceled)
    .map((event) => event.params?.errorText || "Network request failed");
  const webSocketFrames = cdp.events
    .filter((event) => event.method === "Network.webSocketFrameSent" || event.method === "Network.webSocketFrameReceived")
    .map((event) => {
      try {
        const payload = JSON.parse(event.params?.response?.payloadData || "{}");
        return {
          direction: event.method.endsWith("Sent") ? "sent" : "received",
          kind: payload.type === "rpc" ? `${payload.type}:${payload.method}` : String(payload.type || "unknown"),
        };
      } catch {
        return {
          direction: event.method.endsWith("Sent") ? "sent" : "received",
          kind: "non-json",
        };
      }
    });

  const report = {
    ok: !pageState.pairScreen
      && pageState.status === "연결됨"
      && !pageState.loading
      && !pageState.horizontalOverflow
      && pageState.navItems === 5
      && launchState.visible
      && launchState.workspaceOptions > 0
      && launchState.modelOptions > 0
      && launchState.effortOptions > 0
      && launchState.launchDisabled
      && !launchState.horizontalOverflow
      && workspaceState.visible
      && workspaceState.tabs === 3
      && workspaceState.entries === 2
      && !workspaceState.horizontalOverflow
      && gitState.branch === "codex/remote-studio"
      && gitState.files === 1
      && terminalState.startButton
      && terminalState.boundary
      && usageState.accountCard
      && usageState.quotaCards === 2
      && usageState.statCards === 3
      && !usageState.horizontalOverflow
      && settingsState.rows === 7
      && settingsState.securityCard
      && settingsState.disconnectButton
      && !settingsState.horizontalOverflow
      && runtimeErrors.length === 0,
    page: pageState,
    views: {
      launch: launchState,
      workspace: workspaceState,
      git: gitState,
      terminal: terminalState,
      usage: usageState,
      settings: settingsState,
    },
    runtimeErrors,
    logErrors,
    networkFailures,
    webSocketFrames,
    screenshot: screenshotPath,
  };
  console.log(JSON.stringify(report, null, 2));
  if (!report.ok) process.exitCode = 1;
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    error: error instanceof Error ? error.message : String(error),
    chrome: stderr.split("\n").filter(Boolean).slice(-4),
  }, null, 2));
  process.exitCode = 1;
} finally {
  try {
    await cdp?.call("Browser.close");
  } catch {
    // The browser may already be gone.
  }
  cdp?.close();
  chrome.kill("SIGTERM");
  await fixture?.close();
}
