# RelayCode

Remote-control local Codex development from a phone without moving repositories,
shell access, or credentials into a hosted service.

> RelayCode is an early public alpha. Pairing a phone grants meaningful control
> over the configured workspaces. Read the security model before use.

## How it works

```text
iPhone, iPad, or mobile browser
            │
     private HTTPS/WSS
            │
   RelayCode bridge on Mac
            │ allowlisted stdio JSON-RPC
            ▼
      Codex app-server
            │
   repositories, shell, MCP, skills
```

The bridge binds to loopback. Tailscale Serve supplies private HTTPS access
without exposing the Codex app-server or RelayCode port to the public internet.

## Quick start

Requirements:

- macOS;
- [Codex CLI](https://github.com/openai/codex) installed and logged in;
- [Tailscale](https://tailscale.com/download) connected on the Mac and phone.

Install and configure:

```bash
brew install mindsurf0176-ui/tap/relaycode
relaycode setup --workspace ~/Projects
```

`setup` checks Codex login, configures Tailscale Serve, registers the Homebrew
background service, and prints a one-time QR code. Scan it on the phone, then use
Safari's **Add to Home Screen** action for an app-like experience.

Add another allowed root by repeating the option:

```bash
relaycode setup \
  --workspace ~/Projects \
  --workspace ~/Work/client-app
```

Every configured root becomes part of the mobile trust boundary. Prefer narrow
project directories over your entire home folder.

## CLI

| Command | Purpose |
| --- | --- |
| `relaycode setup` | Configure roots, private access, pairing, and service |
| `relaycode serve` | Run the bridge in the foreground |
| `relaycode pair` | Rotate the pairing credential and print a new QR code |
| `relaycode status` | Show bridge, URL, and workspace state |
| `relaycode doctor` | Check Node, Codex login, config permissions, Tailscale, and health |

Use another authenticated private HTTPS tunnel with:

```bash
relaycode setup \
  --workspace ~/Projects \
  --public-url https://relay.example.internal \
  --skip-tailscale
```

Do not use Tailscale Funnel, public router forwarding, or a bridge bound to
`0.0.0.0`.

## Mobile capabilities

- Start and resume Codex threads.
- Select a model and reasoning effort.
- Stream messages, command activity, plans, and file changes.
- Approve or decline commands and writes.
- Answer explicit agent questions.
- Review turn diffs and interrupt active work.
- Inspect account usage and rate-limit windows.
- Switch between explicitly configured workspace roots.
- Register and verify private OpenAI-compatible model endpoints from the native
  iOS app without exposing credentials to the web client.
- Run real chat completions against the selected on-premises model from a
  native conversation surface.
- Boot a bundled RISC-V Linux 6.1 kernel and execute BusyBox shell commands
  entirely on-device through a no-JIT interpreter.

RelayCode is an operations console rather than a clone of an existing chat app:
active work, blocked approvals, results, and diffs take priority over prose.

The Linux guest currently uses 64 MB of memory, an ephemeral in-memory
filesystem, and no guest network or host-folder mount. Its pinned interpreter
and image are downloaded and checksum-verified during the iOS build; see
[`apps/ios/RelayCode/Resources/THIRD_PARTY_NOTICES.md`](apps/ios/RelayCode/Resources/THIRD_PARTY_NOTICES.md).

## Native iOS app

The repository contains a SwiftUI app with device-only Keychain storage,
same-origin `WKWebView` containment, direct on-premises inference, and an
interpreted on-device Linux terminal. The PWA remains the fastest way to use
the remote console without installing an iOS build.

See [apps/ios/README.md](apps/ios/README.md) for local and GitHub-hosted build
instructions.

## Security

- Pairing uses a random 256-bit token; only its SHA-256 verifier is stored on the
  Mac.
- The mobile RPC surface is allowlisted.
- New and resumed sessions force `workspace-write`, `on-request` approval, and
  human review.
- Workspace paths and existing thread paths are checked before reaching the
  phone.
- Unsupported app-server callbacks fail closed.

Treat a paired phone like an SSH key. See [SECURITY.md](SECURITY.md) for the full
boundary and vulnerability reporting instructions.

## Build from source

Requirements: Node.js 20+, npm, and a working `codex login`.

```bash
git clone https://github.com/mindsurf0176-ui/relaycode.git
cd relaycode
npm install
npm run typecheck
npm test
npm run build
RELAYCODE_HOME=/tmp/relaycode-dev npm run relaycode -- setup \
  --workspace "$PWD" \
  --skip-tailscale \
  --no-service
RELAYCODE_HOME=/tmp/relaycode-dev npm run relaycode -- serve
```

For live UI development:

```bash
npm run dev
```

For release and iOS verification:

```bash
npm run release:package
npm run ios:verify
```

Pull requests also run the complete unsigned iOS build on GitHub's macOS
runner, so contributors do not need a local Xcode installation for compile
verification.

## Project status

The first adapter uses the official Codex app-server. Its protocol is still an
evolving integration surface, so RelayCode pins tested behavior behind its own
versioned mobile protocol and fail-closed adapter. Claude Code and other provider
adapters, push notifications, multi-device revocation, and an encrypted hosted
relay are future work.

RelayCode is independent open-source software and is not affiliated with or
endorsed by OpenAI or Tailscale.

Licensed under [Apache-2.0](LICENSE).
