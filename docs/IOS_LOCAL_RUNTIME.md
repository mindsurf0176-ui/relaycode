# iOS local runtime architecture

RelayCode's native client is intended to become a complete mobile development
workspace, not only a remote web shell. The product keeps two independent
choices:

1. **Model route** — where inference and agent reasoning happen.
2. **Execution route** — where files, Git operations, commands, and tests run.

Separating these routes lets a user connect an on-premises model to a remote
Mac, use an on-device model with an iPhone workspace, or use a cloud model while
keeping execution inside a private host.

## Product modes

### Remote Studio

- Model: Codex, Ollama, LM Studio, or another provider configured on the host.
- Execution: the paired Mac or Linux host.
- Strengths: full repositories, toolchains, long-running tests, containers, and
  the existing RelayCode approval boundary.
- This remains the dependable path for production development.

### On-premises AI

- Model: an HTTPS OpenAI-compatible endpoint reachable through a private
  tailnet or internal network.
- Execution: either a paired host or the local iOS workspace.
- Provider credentials stay in Keychain on iOS or in the host's protected
  environment. Configuration objects only retain a Keychain reference.
- A host-side Codex route requires a provider that implements the Responses API.
  Ollama and LM Studio can also be selected through Codex's local-provider
  configuration.

### Pocket Workspace

- Model: on-premises, Apple Foundation Models for suitable helper tasks, or a
  downloaded on-device model.
- Execution: the app container and user-selected Files locations.
- Features: project browser, text editor, search, Git status/diff, a bounded
  terminal, patch review, and explicit write approvals.
- Native tools and WASI commands run without JIT and cannot escape the selected
  workspace.

### Pocket Linux (experimental)

- Model: any model route.
- Execution: an interpreted Linux environment stored inside the app container.
- It is not hardware virtualization. iOS does not expose Apple's
  Virtualization framework for iPhone VM hosting.
- It runs in the foreground, without root access, host kernel access, USB
  passthrough, or a promise of desktop-class performance.
- The App Store build must not depend on JIT. A full-system interpreter remains
  an optional later runtime after size, license, battery, and review testing.

The first working runtime now uses `mini-rv32ima` to boot a Linux 6.1.14
RV32-NOMMU kernel with a Buildroot BusyBox userland. It executes in 64 MB of
RAM, communicates through an emulated UART, and has no JIT, guest networking,
or host filesystem access. Its filesystem is currently reset with every boot.

## Native architecture

```text
SwiftUI workspace
├── Task board and approvals
├── File browser and editor
├── Diff and Git views
├── Terminal
└── Model and runtime settings
        │
        ├── ModelRouter
        │   ├── Paired Codex app-server
        │   ├── OpenAI-compatible on-prem endpoint
        │   ├── Apple Foundation Models
        │   └── Downloaded on-device model
        │
        └── ExecutionRouter
            ├── Paired host
            ├── Native iOS sandbox tools
            ├── WASI sandbox
            └── Interpreted Linux runtime (experimental)
```

The agent loop uses a narrow `ModelRouter` interface and receives tools only
from the selected `ExecutionRouter`. A model response never gains direct file
or process access. Every write, command, network request, and workspace change
is represented as a typed operation and evaluated by the permission broker.

## Runtime decisions

### Model support

- **Paired Codex:** keep the existing app-server adapter for the richest agent
  event, approval, and thread support.
- **Host-local models:** add a RelayCode settings surface for Codex's built-in
  Ollama/LM Studio mode and custom Responses-compatible providers.
- **Direct on-premises models:** implement a native provider using a private
  HTTPS base URL, model identifier, and optional Keychain credential reference.
- **On-device models:** use a small coding-capable model through MLX Swift or
  Core ML for the first stable implementation. Model assets are optional
  downloads with device, storage, memory, and thermal checks.
- **Apple Foundation Models:** use for focused tasks such as summaries,
  classification, and structured extraction. It is not the default coding
  agent because Apple's guidance says the system model is not suited to code
  generation and complex reasoning.
- **Core AI:** evaluate after iOS 27 and the framework leave beta. Do not make a
  beta-only framework a requirement for the initial App Store release.

### Local execution

The first local runtime is a development sandbox rather than a pretend VM:

- security-scoped access to user-selected folders;
- a native text editor with atomic saves and conflict detection;
- repository status and diffs through a library, not an unrestricted shell;
- a terminal backed by a small, audited set of native Unix utilities;
- WebAssembly/WASI commands through an interpreter such as WasmKit;
- network access off by default and granted per workspace or command;
- no background promise after iOS suspends the app.

An Alpine environment may be added later through user-mode or full-system
interpretation. It must remain behind the same workspace, network, resource,
and approval policies.

### Implemented Linux boundary

- `RelayCodeLinuxRuntime.c` owns the interpreted CPU, RAM, timers, UART, and
  lifecycle.
- `LinuxRuntimeEngine` runs bounded instruction slices on a dedicated serial
  queue so the SwiftUI main thread remains responsive.
- `LinuxRuntimeController` auto-logs into the bundled root account and exposes
  only terminal bytes to the UI.
- The pinned guest image is bundled at build time after SHA-256 verification.
- The verification script boots the guest and requires both Linux 6.1.14 and
  the `RELAYCODE_LINUX_OK` shell marker.

## App Store boundary

- Executable project source remains fully visible and editable to the user.
- Downloaded content cannot silently change RelayCode's product functionality.
- Bundled runtime assets are pinned, checksummed, and licensed; optional
  downloaded model assets are also removable.
- The runtime writes only to the app container or user-selected
  security-scoped locations.
- No feature depends on private APIs, jailbreaks, JIT workarounds, or a
  permanently running background process.
- The app description and review notes clearly present RelayCode as a
  programming and development tool.

## Delivery order

### Slice 5 — provider routing

1. [Done] Add model and execution route contracts to `RelayCodeCore`.
2. Add host-side Ollama, LM Studio, and custom provider configuration.
3. [Done] Add native Keychain-backed on-premises endpoint profiles.
4. [Done] Expose health, model discovery, Chat Completions inference, and
   capability checks without exposing credentials to the web client.

### Slice 6 — native workspace

1. Replace the single full-screen web shell with SwiftUI navigation.
2. Add local folder import, file tree, editor, search, and diff.
3. Add Git status, branch, commit, pull, and push with explicit confirmation.
4. Keep the existing remote console as one workspace type.

### Slice 7 — on-device inference

1. Add a small downloaded coding model through MLX Swift or Core ML.
2. Enforce compatibility, storage, memory, context, and thermal budgets.
3. Run a constrained local edit loop with review-before-write.
4. Add Apple Foundation Models only for tasks it handles reliably.

### Slice 8 — local command runtime

1. [Done] Add the first interactive Linux/BusyBox command runtime.
2. Add a WASI interpreter and signed command catalog.
3. [Partial] Add terminal sessions, cancellation, and output limits; workspace
   scoping remains.
4. [Done] Validate a no-JIT interpreted Linux runtime; persistent images,
   networking, and folder mounts remain.

## Release criteria

- A lost or stolen pairing credential is revocable.
- Provider secrets never appear in logs, URLs, web storage, or repository
  configuration.
- A local model cannot perform writes without the same approval object used by
  remote agents.
- Path traversal, symlink escape, oversized output, and runaway process tests
  fail closed.
- Every runtime reports truthful capabilities; the UI never labels WASI or a
  native Unix command set as a full Linux VM.
- The app remains useful when the on-device model or Linux runtime is not
  installed.
