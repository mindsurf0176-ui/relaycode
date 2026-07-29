# Contributing

RelayCode controls developer machines. Keep changes small, reviewable, and
fail-closed at every trust boundary.

## Development

Requirements: Node.js 20+, npm, and Codex CLI.

```bash
npm install
npm run typecheck
npm test
npm run build
```

For iOS source verification on macOS:

```bash
npm run ios:verify
```

## Pull requests

- Explain the user-visible behavior and security impact.
- Add tests for protocol, pairing, path, or approval changes.
- Never broaden the mobile RPC allowlist as a convenience workaround.
- Never include pairing URLs, credentials, `.env` files, or local Codex state.
- Keep provider-specific behavior behind the bridge boundary.

For vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a
public issue.
