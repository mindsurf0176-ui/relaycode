# Changelog

All notable changes to RelayCode are documented here.

## 0.5.1

- Move multi-gigabyte on-device model transfers to a persistent iOS
  background `URLSession`.
- Reconnect to an active model download after suspension, system termination,
  or relaunch instead of silently starting over.
- Drain temporary `FileHandle` buffers while hashing multi-gigabyte models,
  preventing the SHA-256 verification pass from growing to gigabytes of memory.
- Preserve resumable state after transient network failures and recover a
  fully downloaded staging artifact if the app exits during SHA-256
  verification.
- Keep model artifacts available to background finalization after the first
  device unlock while continuing to exclude them from device backups.

## 0.3.0

- Upgrade the internal model from Qwen2.5-Coder 0.5B Q4_0 to the official
  Qwen2.5-Coder 1.5B Q4_K_M artifact.
- Expand the internal inference context from 4,096 to 8,192 tokens and the
  output budget from 384 to 768 tokens.
- Improve coding instructions and retain the latest request by trimming old
  conversation turns when the context is full.
- Remove the legacy 0.5B model after the upgraded model is verified.

## 0.1.1

- Avoid overwriting an existing Tailscale Serve endpoint during setup.
- Reuse an existing RelayCode mapping or select the first free HTTPS port from
  8443 through 8453 when port 443 is already occupied.

## 0.1.0

- Added a mobile-first PWA for Codex sessions, approvals, diffs, and usage.
- Added a loopback-only bridge with token pairing and workspace boundaries.
- Added a native SwiftUI iOS shell with device-only Keychain storage.
- Added the `relaycode` setup, serve, pair, status, and doctor CLI.
- Added release packaging, CI, and Homebrew service support.
