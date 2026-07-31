# Product direction

## Promise

From a phone, understand what every coding agent is doing and make the next safe
decision in under ten seconds.

## Deliberate differences from chat apps

- Home is an operations board, not an empty chat screen.
- Active runs, blocked approvals, test results, and diffs outrank prose.
- Model selection is a route decision with capability and quota context.
- The composer offers task verbs such as inspect, implement, test, review, and
  explain instead of copying desktop slash-command chrome.
- Risky actions are separate approval objects with command, path, network target,
  and scope.

## OpenCodex-inspired capabilities

1. Provider-neutral model catalog and routing.
2. Account health, quota windows, and usage visibility.
3. Stable threads that survive mobile reconnects.
4. Model combinations and sub-agent routes.
5. Local/self-hosted provider support.
6. A dashboard that edits routing without editing config files.

RelayCode adds the missing remote-development layer: host pairing, workspace
boundaries, task timelines, approvals, diffs, notifications, and mobile ergonomics.

## Delivery slices

### Slice 1 — safe Codex vertical

Pair host, list sessions/models, start or resume a thread, stream work, approve
commands/writes, review diffs, interrupt a turn, inspect quota.

### Slice 2 — multi-agent adapters

Add Claude Code and OpenAI-compatible adapters behind a common engine contract.
Never use subscription-token pooling to bypass provider limits.

### Slice 3 — dependable remote operation

Native iOS/Android shell, Keychain/Keystore, push notifications, multi-device
revocation, encrypted relay, reconnect replay, and background host health.

Current progress: the native iOS/iPadOS shell, device-only Keychain storage,
same-origin web containment, foreground reconnect, host health feedback, direct
remote file browse/search/edit, read-only Git status/diff, and reconnectable
macOS sandbox terminals are implemented. Terminal replay survives client
reconnects but not a bridge restart. Android, push notifications, multi-device
revocation, an encrypted relay service, and durable restart replay remain.

### Distribution — public alpha

The default distribution is a standalone GitHub repository, a versioned release
archive, a Homebrew service on the Mac, and the installable PWA on the phone.
The setup CLI owns Codex checks, narrow workspace configuration, private
Tailscale Serve setup, service startup, and one-time QR pairing. Native App Store
distribution remains a later convenience layer over the same bridge protocol.

### Slice 4 — routing intelligence

Per-task routes, fallback rules, budget ceilings, sub-agent combinations, and
quality/cost telemetry derived from real runs.

### Slice 5 — provider routing

Add host-local Ollama and LM Studio, custom Responses-compatible providers,
native Keychain-backed on-premises endpoints, and truthful provider capability
checks. Model location and command execution location remain independent.

Current native delivery: provider registration, model discovery, health checks,
Keychain credentials, and real Chat Completions inference are implemented.

### Slice 6 — native workspace

Add a SwiftUI project browser, editor, search, Git status/diff, and explicit
write operations for app-container and user-selected Files workspaces. Keep the
paired remote console as one workspace type rather than the entire native app.

Current remote delivery: the paired Mac workspace already exposes these
file/search/Git views through the shared mobile UI. Slice 6 still refers to
files stored locally in the iOS app container or selected through Files.

### Slice 7 — on-device inference

Run a small downloaded coding model through MLX Swift or Core ML with storage,
memory, context, and thermal limits. Use Apple Foundation Models only for
focused tasks it handles reliably; evaluate Core AI after its iOS 27 beta.

### Slice 8 — local command runtime

Add an audited native command subset and a no-JIT WASI interpreter. Evaluate an
interpreted Alpine environment as an optional experimental runtime, without
claiming iOS hardware virtualization or desktop-class background execution.

Current experimental delivery: RelayCode boots Linux 6.1.14 and a BusyBox
Buildroot userland with a pinned MIT RISC-V interpreter. The UART shell is
interactive and verified by a boot smoke test. Persistence, workspace mounts,
and guest networking remain later work.

See [IOS_LOCAL_RUNTIME.md](IOS_LOCAL_RUNTIME.md) for the architecture and App
Store boundary.
