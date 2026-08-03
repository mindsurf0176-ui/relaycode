import { existsSync, mkdirSync, mkdtempSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { removeStaleTerminalHomes, terminalSandboxProfile } from "./terminal.js";

function agedTerminalHome(ageMilliseconds: number): string {
  const path = mkdtempSync(join(tmpdir(), "relaycode-terminal-"));
  const seconds = (Date.now() - ageMilliseconds) / 1_000;
  utimesSync(path, seconds, seconds);
  return path;
}

describe("terminal temporary home cleanup", () => {
  it("removes homes an orphaned bridge left behind", () => {
    const stale = agedTerminalHome(48 * 60 * 60 * 1_000);
    const fresh = agedTerminalHome(0);
    const unrelated = mkdtempSync(join(tmpdir(), "relaycode-unrelated-"));

    removeStaleTerminalHomes();

    expect(existsSync(stale)).toBe(false);
    expect(existsSync(fresh)).toBe(true);
    expect(existsSync(unrelated)).toBe(true);
  });
});

describe("terminal sandbox profile", () => {
  const workspace = mkdtempSync(join(tmpdir(), "relaycode-workspace-"));
  const home = mkdtempSync(join(tmpdir(), "relaycode-terminal-home-"));

  it("denies by default and keeps writes inside the workspace and home", () => {
    const profile = terminalSandboxProfile(workspace, home, false);
    expect(profile).toContain("(deny default)");
    expect(profile).toContain(`(allow file-write* (subpath "${workspace}") (subpath "${home}")`);
    expect(profile).not.toContain("(allow network*)");
  });

  it("adds network only when the session asked for it", () => {
    expect(terminalSandboxProfile(workspace, home, true)).toContain("(allow network*)");
  });

  it("does not let a workspace name escape the profile string", () => {
    const hostile = join(workspace, 'quote"break');
    mkdirSync(hostile, { recursive: true });
    const profile = terminalSandboxProfile(hostile, home, false);
    expect(profile).toContain('quote\\"break');
    expect(profile.match(/\(allow network\*\)/)).toBeNull();
  });
});
