import { describe, expect, it } from "vitest";
import type { RelayConfig } from "./config.js";
import { nativePairUrl, pairUrl } from "./pair.js";

const config: RelayConfig = {
  version: 1,
  displayName: "QA Mac",
  host: "127.0.0.1",
  port: 8787,
  workspaceRoots: ["/tmp/workspace"],
  tokenHash: "a".repeat(64),
  publicUrl: "https://mac.example.ts.net:8443",
};

describe("pairing links", () => {
  it("keeps the HTTPS link as a browser fallback", () => {
    const token = "b".repeat(43);
    const url = new URL(pairUrl(config, token));
    const fragment = new URLSearchParams(url.hash.slice(1));

    expect(url.origin).toBe("https://mac.example.ts.net:8443");
    expect(fragment.get("pair")).toBe(token);
    expect(fragment.get("bridge")).toBe(
      "wss://mac.example.ts.net:8443/ws",
    );
  });

  it("creates a one-tap native iOS deep link", () => {
    const token = "c".repeat(43);
    const url = new URL(nativePairUrl(config, token));

    expect(url.protocol).toBe("relaycode:");
    expect(url.hostname).toBe("pair");
    expect(url.searchParams.get("pair")).toBe(token);
    expect(url.searchParams.get("bridge")).toBe(
      "wss://mac.example.ts.net:8443/ws",
    );
  });
});
