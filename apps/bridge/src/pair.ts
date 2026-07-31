import qrcode from "qrcode-terminal";
import type { RelayConfig } from "./config.js";

function normalizePublicUrl(config: RelayConfig): string {
  return process.env.RELAYCODE_PUBLIC_URL?.trim()
    || process.env.RELAYCODE_WEB_URL?.trim()
    || config.publicUrl
    || `http://${config.host === "0.0.0.0" ? "127.0.0.1" : config.host}:${config.port}`;
}

function bridgeUrl(config: RelayConfig): string {
  const publicUrl = normalizePublicUrl(config).replace(/\/+$/, "");
  return process.env.RELAYCODE_BRIDGE_URL?.trim()
    || publicUrl.replace(/^http/, "ws") + "/ws";
}

export function pairUrl(config: RelayConfig, token: string): string {
  const publicUrl = normalizePublicUrl(config).replace(/\/+$/, "");
  const fragment = new URLSearchParams({
    pair: token,
    bridge: bridgeUrl(config),
  });
  return `${publicUrl}/#${fragment.toString()}`;
}

export function nativePairUrl(config: RelayConfig, token: string): string {
  const query = new URLSearchParams({
    pair: token,
    bridge: bridgeUrl(config),
  });
  return `relaycode://pair?${query.toString()}`;
}

export function printPairing(config: RelayConfig, token: string): void {
  const nativeUrl = nativePairUrl(config, token);
  const webUrl = pairUrl(config, token);
  console.log("\nScan once to open RelayCode and pair this iPhone:\n");
  console.log(nativeUrl);
  console.log();
  qrcode.generate(nativeUrl, { small: true });
  console.log("\nBrowser/PWA fallback:\n");
  console.log(webUrl);
  console.log("\nTreat both links like an SSH key.");
}
