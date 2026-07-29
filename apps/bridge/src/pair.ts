import qrcode from "qrcode-terminal";
import type { RelayConfig } from "./config.js";

function normalizePublicUrl(config: RelayConfig): string {
  return process.env.RELAYCODE_PUBLIC_URL?.trim()
    || process.env.RELAYCODE_WEB_URL?.trim()
    || config.publicUrl
    || `http://${config.host === "0.0.0.0" ? "127.0.0.1" : config.host}:${config.port}`;
}

export function pairUrl(config: RelayConfig, token: string): string {
  const publicUrl = normalizePublicUrl(config).replace(/\/+$/, "");
  const bridgeUrl = process.env.RELAYCODE_BRIDGE_URL?.trim()
    || publicUrl.replace(/^http/, "ws") + "/ws";
  const fragment = new URLSearchParams({ pair: token, bridge: bridgeUrl });
  return `${publicUrl}/#${fragment.toString()}`;
}

export function printPairing(config: RelayConfig, token: string): void {
  const url = pairUrl(config, token);
  console.log("\nPair this phone once. Treat this URL like an SSH key:\n");
  console.log(url);
  console.log();
  qrcode.generate(url, { small: true });
}
