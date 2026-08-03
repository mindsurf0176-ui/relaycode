# Remote Studio

RelayCode 0.2 turns the paired Mac into a bounded remote development workspace.
Open the **Code** tab in the mobile client and choose one of the roots configured
with `relaycode setup --workspace`.

## Files

- Directory loading is lazy and capped at 400 entries per request.
- Search visits at most 5,000 text files and returns at most 120 matches.
- The editor opens existing text files up to 512 KB.
- Likely credential files such as `.env`, private keys, and PEM files are hidden
  from the file API.
- Save asks for confirmation and sends the hash of the version that was opened.
  If the Mac copy changed, the write stops and the phone must reload it.
- The replacement is written to a same-directory temporary file, synced, and
  atomically renamed.

Creating, renaming, and deleting files remains available through an approved
Codex task or the direct sandbox terminal rather than dedicated file buttons.

## Git

The Git tab exposes branch state, staged/worktree status, and textual diffs.
It does not expose commit, pull, push, reset, checkout, or credential helpers as
direct mobile RPC methods. Those operations should run through a Codex task so
the normal command approval UI remains visible.

Git reads ignore global and system configuration, external diff programs,
text-conversion drivers, optional locks, and pagers. This keeps the status view
read-only and prevents repository display from silently launching user tools.

## Terminal

The current terminal is available on a macOS bridge with `sandbox-exec`.

- Up to four running sessions are kept by the bridge.
- A phone reconnect receives the last 256 KB of output.
- A running session closes after eight hours without input or output, and an
  exited session is discarded one hour later.
- A normal bridge shutdown ends every session. If the bridge is killed instead,
  a command that is still running can outlive it; the temporary home it used is
  removed the next time the bridge starts.
- RelayCode starts `zsh -f` with a new temporary `HOME`; user profiles and
  bridge environment secrets are not inherited.
- Reads use system toolchain paths and the selected workspace. Writes are
  limited to the selected workspace and the temporary home.
- Network access is off by default. Enabling it requires confirmation when the
  session starts.
- Input is capped at 16 KB per request and output chunks are capped at 32 KB.

This is a pipe-backed command shell, not a PTY. Full-screen TUI applications,
terminal resizing, and complete job control are intentionally not advertised.

## Trust boundary

A paired phone is equivalent to a powerful development credential. File saves
show a mobile confirmation, but the pairing token authorizes the underlying
RPC. A started terminal can read all files inside the selected workspace,
including secrets that happen to live there, and can modify that workspace
without a separate Codex approval.

Configure narrow project roots, keep credentials outside repositories, use a
private authenticated HTTPS/WSS path such as Tailscale Serve, and rotate the
pairing token immediately if a device is lost or shared.
