# Security model

RelayCode controls a development machine, so a paired phone must be treated like
an SSH key.

## Defaults

- The bridge binds to `127.0.0.1`.
- Codex app-server runs over child-process stdio and is not network-exposed.
- Pairing uses a random 256-bit token. Only its SHA-256 verifier is stored.
- The native iOS shell stores its pairing configuration with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; it is not synchronized through
  iCloud and is injected into the web runtime without writing the token to web
  storage.
- Native model profiles store only a Keychain reference. Provider bearer
  credentials use separate `WhenUnlockedThisDeviceOnly` items and are attached
  only as authorization headers to explicit model requests.
- Remote model endpoints require HTTPS. Loopback HTTP is accepted only for
  local development, and credentials, query strings, and fragments are rejected
  in provider URLs.
- The on-device Linux guest uses interpreted CPU execution without JIT. It has
  no iOS filesystem bridge or guest network device, and its RAM-backed state is
  discarded when stopped.
- Native web navigation is limited to the configured RelayCode origin.
- Rotating pairing credentials invalidates an existing client on its next
  protocol message.
- Mobile RPC is allowlisted. Destructive thread deletion, config writes, and
  arbitrary process selection are not exposed. RelayCode 0.2 adds a direct
  terminal RPC that can start only the fixed sandboxed shell described below.
- Only command approvals, file approvals, and explicit agent questions are
  forwarded to the phone. Other app-server callbacks fail closed.
- New and resumed threads force `workspace-write`, `on-request` approval, and
  `user` as the approval reviewer.
- Workspace paths must resolve inside configured roots.
- Remote file access rejects traversal and symlink escape, caps text files at
  512 KB, hides likely credential filenames, and requires the previously read
  SHA-256 hash before replacing an existing file.
- Git status and diff run without global/system Git configuration, external
  diffs, text conversion, optional locks, or network operations.
- Direct terminal sessions use `/usr/bin/sandbox-exec`, a fresh temporary
  `HOME`, `zsh -f`, and a sanitized environment. Writes are limited to the
  selected workspace and temporary home. Network access is denied unless the
  phone explicitly enables it for that session. Output replay is capped and
  sessions end when the bridge restarts.
- Existing thread lists are filtered by those roots. Read, resume, rename,
  steer, interrupt, approval, and notification paths are rechecked against the
  same boundary before they reach a phone.

## Network boundary

Use Tailscale Serve or an equivalent authenticated private HTTPS tunnel. Never
expose the bridge directly to the public internet. Plain HTTP/WebSocket is only
for localhost development.

## Reporting a vulnerability

Do not open a public issue for suspected vulnerabilities. Use the repository's
[private vulnerability reporting form](https://github.com/mindsurf0176-ui/relaycode/security/advisories/new).

Do not attach pairing URLs, tokens, Codex credentials, private source code, or
unredacted logs. Include the RelayCode and Codex versions, affected command or
RPC method, impact, and a minimal reproduction.

Only the latest tagged release is supported during the public alpha.

## Known MVP limits

- The installable browser PWA still uses localStorage. Prefer the native iOS
  shell when device-only Keychain storage is required.
- One active pairing verifier is supported. Pairing a new device rotates it.
- Mobile push notifications and device revocation lists are not implemented.
- Android Keystore support is not implemented.
- The first adapter is Codex. Additional provider adapters must preserve the same
  approval and workspace boundary instead of forwarding provider APIs blindly.
- A paired client that starts a direct terminal can read source and credentials
  stored inside the selected workspace and can modify that workspace without a
  separate Codex approval object. Use narrow roots, keep secrets outside source
  trees, and rotate the pairing token after a lost or shared device.
- The direct terminal is a pipe-backed shell rather than a PTY. Interactive
  full-screen tools, job control, and terminal resize negotiation are not
  supported.
- Direct on-premises prompts leave the device and are processed by the endpoint
  selected by the user. RelayCode does not currently redact prompt contents.
- The Linux runtime is experimental and intentionally lacks persistent storage,
  package downloads, networking, and workspace mounts.
