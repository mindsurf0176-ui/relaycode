import { describe, expect, it } from "vitest";
import { normalizePublicUrl } from "./config.js";
import { chooseTailscaleHttpsPort, parseCliArgs, tailscalePublicUrl } from "./cli.js";

describe("RelayCode CLI", () => {
  it("parses repeatable workspace setup options", () => {
    const result = parseCliArgs([
      "setup",
      "--workspace",
      "/tmp/one",
      "-w",
      "/tmp/two",
      "--port",
      "9876",
      "--skip-tailscale",
      "--no-service",
    ]);
    expect(result.command).toBe("setup");
    expect(result.workspaces).toEqual(["/tmp/one", "/tmp/two"]);
    expect(result.port).toBe(9876);
    expect(result.skipTailscale).toBe(true);
    expect(result.noService).toBe(true);
  });

  it("derives a private HTTPS URL only from an online tailnet node", () => {
    expect(tailscalePublicUrl(JSON.stringify({
      BackendState: "Running",
      Self: { DNSName: "mac.example.ts.net.", Online: true },
    }))).toBe("https://mac.example.ts.net");
    expect(tailscalePublicUrl(JSON.stringify({
      BackendState: "Stopped",
      Self: { DNSName: "mac.example.ts.net.", Online: false },
    }))).toBeNull();
  });

  it("requires HTTPS away from loopback", () => {
    expect(normalizePublicUrl("https://mac.example.ts.net/")).toBe("https://mac.example.ts.net");
    expect(normalizePublicUrl("http://127.0.0.1:8787")).toBe("http://127.0.0.1:8787");
    expect(() => normalizePublicUrl("http://mac.example.ts.net")).toThrow(/HTTPS/);
    expect(() => normalizePublicUrl("https://mac.example.ts.net/relay")).toThrow(/path/);
  });

  it("does not overwrite an existing Tailscale Serve endpoint", () => {
    const status = JSON.stringify({
      TCP: {
        443: { HTTPS: true },
        8443: { HTTPS: true },
      },
      Web: {
        "mac.example.ts.net:443": {
          Handlers: { "/": { Proxy: "http://127.0.0.1:9000" } },
        },
      },
    });
    expect(chooseTailscaleHttpsPort(status, 8787)).toBe(8444);
    expect(chooseTailscaleHttpsPort("{}", 8787)).toBe(443);
  });

  it("reuses an existing RelayCode Tailscale Serve endpoint", () => {
    const status = JSON.stringify({
      TCP: { 3333: { HTTPS: true } },
      Web: {
        "mac.example.ts.net:3333": {
          Handlers: { "/": { Proxy: "http://localhost:8787/" } },
        },
      },
    });
    expect(chooseTailscaleHttpsPort(status, 8787)).toBe(3333);
  });
});
