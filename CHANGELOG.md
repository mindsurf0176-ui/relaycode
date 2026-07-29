# Changelog

All notable changes to RelayCode are documented here.

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
