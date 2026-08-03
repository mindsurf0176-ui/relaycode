import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TerminalManager, terminalCapability, terminalSandboxProfile } from "./terminal.js";
import { WorkspaceService } from "./workspace.js";

function fixture(): { root: string; service: WorkspaceService } {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "relaycode-workspace-")));
  mkdirSync(join(root, "src"));
  writeFileSync(join(root, "src", "index.ts"), "export const answer = 41;\n");
  writeFileSync(join(root, ".env"), "SECRET=not-for-mobile\n");
  return { root, service: new WorkspaceService([root]) };
}

describe("remote workspace service", () => {
  it("lists, reads, and conflict-safely writes text files", async () => {
    const { root, service } = fixture();
    const listing = await service.request("workspace/entries", {
      workspace: root,
      path: "src",
    }) as {
      parent: string;
      entries: Array<{ path: string; editable: boolean }>;
    };
    expect(listing.parent).toBe("");
    expect(listing.entries).toContainEqual(expect.objectContaining({
      path: "src/index.ts",
      editable: true,
    }));

    const opened = await service.request("workspace/file/read", {
      workspace: root,
      path: "src/index.ts",
    }) as { content: string; hash: string };
    expect(opened.content).toContain("answer = 41");

    const saved = await service.request("workspace/file/write", {
      workspace: root,
      path: "src/index.ts",
      content: "export const answer = 42;\n",
      expectedHash: opened.hash,
    }) as { hash: string };
    expect(saved.hash).not.toBe(opened.hash);
    expect(readFileSync(join(root, "src", "index.ts"), "utf8")).toContain("42");

    await expect(service.request("workspace/file/write", {
      workspace: root,
      path: "src/index.ts",
      content: "stale edit\n",
      expectedHash: opened.hash,
    })).rejects.toThrow(/changed on the Mac/);
  });

  it("blocks traversal, external symlinks, binary files, and likely credentials", async () => {
    const { root, service } = fixture();
    const outside = realpathSync(mkdtempSync(join(tmpdir(), "relaycode-outside-")));
    writeFileSync(join(outside, "secret.txt"), "outside\n");
    symlinkSync(join(outside, "secret.txt"), join(root, "src", "external.txt"));
    writeFileSync(join(root, "src", "binary.bin"), Buffer.from([0, 1, 2]));

    await expect(service.request("workspace/file/read", {
      workspace: root,
      path: "../secret.txt",
    })).rejects.toThrow(/traversal/);
    await expect(service.request("workspace/file/read", {
      workspace: root,
      path: "src/external.txt",
    })).rejects.toThrow(/outside the workspace/);
    await expect(service.request("workspace/file/read", {
      workspace: root,
      path: "src/binary.bin",
    })).rejects.toThrow(/Binary/);
    await expect(service.request("workspace/file/read", {
      workspace: root,
      path: ".env",
    })).rejects.toThrow(/credential/);
  });

  it("searches bounded source text and reports Git status and diffs", async () => {
    const { root, service } = fixture();
    execFileSync("git", ["init", "-q"], { cwd: root });
    execFileSync("git", ["config", "user.email", "relaycode@example.invalid"], { cwd: root });
    execFileSync("git", ["config", "user.name", "RelayCode Test"], { cwd: root });
    execFileSync("git", ["add", "src/index.ts"], { cwd: root });
    execFileSync("git", ["commit", "-qm", "fixture"], { cwd: root });
    writeFileSync(join(root, "src", "index.ts"), "export const answer = 42;\n");

    const search = await service.request("workspace/search", {
      workspace: root,
      query: "answer",
    }) as { results: Array<{ path: string; line: number }> };
    expect(search.results).toContainEqual(expect.objectContaining({
      path: "src/index.ts",
      line: 1,
    }));

    const status = await service.request("workspace/git/status", {
      workspace: root,
    }) as { clean: boolean; entries: Array<{ path: string }> };
    expect(status.clean).toBe(false);
    expect(status.entries).toContainEqual(expect.objectContaining({
      path: "src/index.ts",
    }));

    const diff = await service.request("workspace/git/diff", {
      workspace: root,
      path: "src/index.ts",
    }) as { diff: string };
    expect(diff.diff).toContain("-export const answer = 41;");
    expect(diff.diff).toContain("+export const answer = 42;");

    unlinkSync(join(root, "src", "index.ts"));
    const deletedDiff = await service.request("workspace/git/diff", {
      workspace: root,
      path: "src/index.ts",
    }) as { diff: string };
    expect(deletedDiff.diff).toContain("deleted file mode");
  });
});

describe("sandboxed terminal sessions", () => {
  it("reports a truthful platform capability and produces a scoped profile", () => {
    const capability = terminalCapability();
    expect(capability.available).toBe(process.platform === "darwin");
    if (process.platform === "darwin") {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "relaycode-terminal-profile-")));
      const home = realpathSync(mkdtempSync(join(tmpdir(), "relaycode-terminal-home-")));
      const offline = terminalSandboxProfile(root, home, false);
      const online = terminalSandboxProfile(root, home, true);
      expect(offline).toContain(`(subpath "${root}")`);
      expect(offline).not.toContain("(allow network*)");
      expect(online).toContain("(allow network*)");
    }
  });

  it.runIf(process.platform === "darwin")(
    "keeps writes inside the selected workspace and replays output",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "relaycode-terminal-root-")));
      const outside = join(
        realpathSync(tmpdir()),
        `relaycode-terminal-outside-${Date.now()}`,
      );
      const outsideSecret = join(
        realpathSync(tmpdir()),
        `relaycode-terminal-secret-${Date.now()}`,
      );
      writeFileSync(outsideSecret, "MUST_NOT_LEAK\n");
      const manager = new TerminalManager([root]);
      const started = await manager.request("terminal/session/start", {
        workspace: root,
        network: false,
      }) as { id: string };
      await manager.request("terminal/session/write", {
        sessionId: started.id,
        data: `printf 'REMOTE_OK\\n'; touch inside.txt; touch '${outside}'; cat '${outsideSecret}'; printf 'DONE\\n'\n`,
      });

      let output = "";
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const listed = await manager.request("terminal/session/list", {}) as {
          sessions: Array<{ id: string; output: string }>;
        };
        output = listed.sessions.find((session) => session.id === started.id)?.output || "";
        if (output.includes("\nREMOTE_OK\n") && output.includes("\nDONE\n")) break;
        await new Promise((resolve) => setTimeout(resolve, 25));
      }

      expect(output).toContain("REMOTE_OK");
      expect(output).toContain("Operation not permitted");
      expect(output).not.toContain("\nMUST_NOT_LEAK\n");
      expect(existsSync(join(root, "inside.txt"))).toBe(true);
      expect(existsSync(outside)).toBe(false);
      await manager.request("terminal/session/close", {
        sessionId: started.id,
      });
      manager.close();
    },
  );
});
