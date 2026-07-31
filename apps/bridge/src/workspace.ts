import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { lstatSync } from "node:fs";
import {
  open,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  stat,
} from "node:fs/promises";
import {
  basename,
  dirname,
  extname,
  isAbsolute,
  relative,
  resolve,
  sep,
} from "node:path";
import { promisify } from "node:util";
import type { WorkspaceMethod } from "@relaycode/protocol";
import { assertWorkspacePath, isPathWithin } from "./security.js";

const execFileAsync = promisify(execFile);
const maxEditableBytes = 512 * 1024;
const maxDirectoryEntries = 400;
const maxSearchFiles = 5_000;
const maxSearchResults = 120;
const maxGitOutputBytes = 1_000_000;

const ignoredDirectories = new Set([
  ".git",
  ".next",
  ".turbo",
  ".cache",
  "build",
  "DerivedData",
  "dist",
  "node_modules",
  "Pods",
]);

type Params = Record<string, unknown>;

function params(value: unknown): Params {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("RPC params must be an object.");
  }
  return value as Params;
}

function requiredString(
  value: Params,
  key: string,
  maximumLength = 2_000,
): string {
  const candidate = value[key];
  if (
    typeof candidate !== "string"
    || candidate.trim() === ""
    || candidate.length > maximumLength
    || candidate.includes("\0")
  ) {
    throw new Error(`Invalid ${key}.`);
  }
  return candidate;
}

function optionalString(
  value: Params,
  key: string,
  maximumLength = 2_000,
): string {
  const candidate = value[key];
  if (candidate === undefined || candidate === null || candidate === "") {
    return "";
  }
  if (
    typeof candidate !== "string"
    || candidate.length > maximumLength
    || candidate.includes("\0")
  ) {
    throw new Error(`Invalid ${key}.`);
  }
  return candidate;
}

function normalizedRelativePath(value: string): string {
  if (!value || value === ".") return "";
  if (isAbsolute(value)) throw new Error("Workspace paths must be relative.");
  const normalized = value.replaceAll("\\", "/").replace(/^\.\/+/, "");
  if (
    normalized.split("/").some((part) => part === "..")
    || normalized.includes("\0")
  ) {
    throw new Error("Path traversal is not allowed.");
  }
  return normalized;
}

function pathForClient(root: string, absolute: string): string {
  return relative(root, absolute).split(sep).join("/");
}

function sha256(data: Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

function isSensitiveFile(path: string): boolean {
  const name = basename(path).toLowerCase();
  if (
    name === ".env"
    || (name.startsWith(".env.") && !name.endsWith(".example") && !name.endsWith(".sample"))
    || name === ".npmrc"
    || name === ".pypirc"
    || name === "credentials"
    || name === "id_rsa"
    || name === "id_ed25519"
  ) {
    return true;
  }
  return [".key", ".p8", ".p12", ".pem"].includes(extname(name));
}

function looksLikeText(data: Uint8Array): boolean {
  const inspected = data.subarray(0, Math.min(data.byteLength, 8_192));
  return !inspected.includes(0);
}

function languageFor(path: string): string {
  const name = basename(path).toLowerCase();
  if (name === "dockerfile") return "dockerfile";
  if (name === "makefile") return "makefile";
  const extension = extname(name).slice(1);
  const aliases: Record<string, string> = {
    h: "c",
    hpp: "cpp",
    js: "javascript",
    jsx: "javascript",
    m: "objective-c",
    mm: "objective-cpp",
    py: "python",
    rb: "ruby",
    sh: "shell",
    ts: "typescript",
    tsx: "typescript",
    yml: "yaml",
  };
  return aliases[extension] || extension || "text";
}

export class WorkspaceService {
  constructor(private readonly roots: string[]) {}

  async request(method: WorkspaceMethod, value: unknown): Promise<unknown> {
    const input = params(value);
    switch (method) {
      case "workspace/entries":
        return this.entries(input);
      case "workspace/file/read":
        return this.read(input);
      case "workspace/file/write":
        return this.write(input);
      case "workspace/search":
        return this.search(input);
      case "workspace/git/status":
        return this.gitStatus(input);
      case "workspace/git/diff":
        return this.gitDiff(input);
      default:
        throw new Error("Unsupported workspace method.");
    }
  }

  private root(input: Params): string {
    return assertWorkspacePath(requiredString(input, "workspace"), this.roots);
  }

  private async existingPath(
    root: string,
    relativePath: string,
    expected: "file" | "directory",
  ): Promise<{ absolute: string; info: Awaited<ReturnType<typeof stat>> }> {
    const relativeValue = normalizedRelativePath(relativePath);
    const candidate = resolve(root, relativeValue);
    if (!isPathWithin(candidate, root)) {
      throw new Error("Path is outside the selected workspace.");
    }
    const canonical = await realpath(candidate);
    if (!isPathWithin(canonical, root)) {
      throw new Error("Symlink targets outside the workspace are blocked.");
    }
    const info = await stat(canonical);
    if (expected === "file" && !info.isFile()) {
      throw new Error("The selected path is not a file.");
    }
    if (expected === "directory" && !info.isDirectory()) {
      throw new Error("The selected path is not a directory.");
    }
    return { absolute: canonical, info };
  }

  private async entries(input: Params): Promise<unknown> {
    const root = this.root(input);
    const requested = optionalString(input, "path");
    const { absolute } = await this.existingPath(root, requested, "directory");
    const values = await readdir(absolute, { withFileTypes: true });
    const entries = values
      .filter((entry) => entry.name !== ".DS_Store")
      .slice(0, maxDirectoryEntries)
      .map((entry) => {
        const target = resolve(absolute, entry.name);
        const clientPath = pathForClient(root, target);
        let kind: "directory" | "file" | "symlink" | "other" = "other";
        if (entry.isSymbolicLink()) kind = "symlink";
        else if (entry.isDirectory()) kind = "directory";
        else if (entry.isFile()) kind = "file";
        let size = 0;
        let modifiedAt = 0;
        if (kind === "file") {
          const info = lstatSync(target);
          size = info.size;
          modifiedAt = info.mtimeMs;
        }
        return {
          name: entry.name,
          path: clientPath,
          kind,
          size,
          modifiedAt,
          editable:
            kind === "file"
            && size <= maxEditableBytes
            && !isSensitiveFile(target),
        };
      })
      .sort((left, right) => {
        if (left.kind === "directory" && right.kind !== "directory") return -1;
        if (right.kind === "directory" && left.kind !== "directory") return 1;
        return left.name.localeCompare(right.name);
      });
    return {
      workspace: root,
      path: pathForClient(root, absolute),
      parent:
        absolute === root
          ? null
          : pathForClient(root, dirname(absolute)),
      entries,
      truncated: values.length > maxDirectoryEntries,
    };
  }

  private async read(input: Params): Promise<unknown> {
    const root = this.root(input);
    const requested = requiredString(input, "path");
    const { absolute, info } = await this.existingPath(root, requested, "file");
    if (isSensitiveFile(absolute)) {
      throw new Error("RelayCode blocks likely credential files from remote viewing.");
    }
    if (info.size > maxEditableBytes) {
      throw new Error("Files larger than 512 KB are not opened in the mobile editor.");
    }
    const data = await readFile(absolute);
    if (!looksLikeText(data)) {
      throw new Error("Binary files are not opened in the mobile editor.");
    }
    return {
      path: pathForClient(root, absolute),
      content: data.toString("utf8"),
      hash: sha256(data),
      size: data.byteLength,
      modifiedAt: info.mtimeMs,
      language: languageFor(absolute),
    };
  }

  private async write(input: Params): Promise<unknown> {
    const root = this.root(input);
    const requested = requiredString(input, "path");
    const contentValue = input.content;
    if (
      typeof contentValue !== "string"
      || contentValue.includes("\0")
      || contentValue.length > maxEditableBytes
    ) {
      throw new Error("Invalid content.");
    }
    const content = contentValue;
    const expectedHash = requiredString(input, "expectedHash", 64);
    if (!/^[a-f0-9]{64}$/.test(expectedHash)) {
      throw new Error("Invalid expectedHash.");
    }
    if (Buffer.byteLength(content, "utf8") > maxEditableBytes) {
      throw new Error("Files larger than 512 KB cannot be saved from mobile.");
    }
    const { absolute, info } = await this.existingPath(root, requested, "file");
    if (isSensitiveFile(absolute)) {
      throw new Error("RelayCode blocks likely credential files from remote editing.");
    }
    const previous = await readFile(absolute);
    if (sha256(previous) !== expectedHash) {
      throw new Error("The file changed on the Mac. Reload it before saving.");
    }

    const temporary = resolve(
      dirname(absolute),
      `.${basename(absolute)}.relaycode-${randomUUID()}.tmp`,
    );
    const handle = await open(temporary, "wx", Number(info.mode) & 0o777);
    try {
      await handle.writeFile(content, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    try {
      await rename(temporary, absolute);
    } catch (error) {
      await rm(temporary, { force: true });
      throw error;
    }
    const current = await readFile(absolute);
    const currentInfo = await stat(absolute);
    return {
      path: pathForClient(root, absolute),
      hash: sha256(current),
      size: current.byteLength,
      modifiedAt: currentInfo.mtimeMs,
    };
  }

  private async search(input: Params): Promise<unknown> {
    const root = this.root(input);
    const query = requiredString(input, "query", 120);
    const requested = optionalString(input, "path");
    const { absolute } = await this.existingPath(root, requested, "directory");
    const needle = query.toLocaleLowerCase();
    const results: Array<{
      path: string;
      line: number;
      column: number;
      preview: string;
    }> = [];
    let visitedFiles = 0;

    const visit = async (directory: string): Promise<void> => {
      if (
        results.length >= maxSearchResults
        || visitedFiles >= maxSearchFiles
      ) {
        return;
      }
      const entries = await readdir(directory, { withFileTypes: true });
      for (const entry of entries) {
        if (
          results.length >= maxSearchResults
          || visitedFiles >= maxSearchFiles
        ) {
          return;
        }
        const target = resolve(directory, entry.name);
        if (entry.isSymbolicLink()) continue;
        if (entry.isDirectory()) {
          if (!ignoredDirectories.has(entry.name)) await visit(target);
          continue;
        }
        if (!entry.isFile() || isSensitiveFile(target)) continue;
        visitedFiles += 1;
        const info = await stat(target);
        if (info.size > maxEditableBytes) continue;
        const data = await readFile(target);
        if (!looksLikeText(data)) continue;
        const lines = data.toString("utf8").split(/\r?\n/);
        for (let index = 0; index < lines.length; index += 1) {
          const column = lines[index].toLocaleLowerCase().indexOf(needle);
          if (column < 0) continue;
          results.push({
            path: pathForClient(root, target),
            line: index + 1,
            column: column + 1,
            preview: lines[index].trim().slice(0, 240),
          });
          if (results.length >= maxSearchResults) return;
        }
      }
    };

    await visit(absolute);
    return {
      query,
      path: pathForClient(root, absolute),
      results,
      visitedFiles,
      truncated:
        results.length >= maxSearchResults
        || visitedFiles >= maxSearchFiles,
    };
  }

  private async git(
    root: string,
    args: string[],
  ): Promise<string> {
    const { stdout } = await execFileAsync("git", [
      "-c",
      "core.fsmonitor=false",
      "-c",
      "core.pager=cat",
      "-C",
      root,
      ...args,
    ], {
      encoding: "utf8",
      timeout: 15_000,
      maxBuffer: maxGitOutputBytes,
      env: {
        PATH: process.env.PATH,
        LANG: process.env.LANG || "en_US.UTF-8",
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_SYSTEM: "/dev/null",
        GIT_OPTIONAL_LOCKS: "0",
        GIT_PAGER: "cat",
      },
    });
    return stdout;
  }

  private async gitStatus(input: Params): Promise<unknown> {
    const root = this.root(input);
    const output = await this.git(root, [
      "status",
      "--short",
      "--branch",
      "--untracked-files=all",
    ]);
    const lines = output.split(/\r?\n/).filter(Boolean);
    const header = lines[0]?.startsWith("## ") ? lines.shift()!.slice(3) : "";
    const [branch = "", upstreamPart = ""] = header.split("...");
    const entries = lines.slice(0, 500).map((line) => ({
      index: line[0] || " ",
      workingTree: line[1] || " ",
      path: line.slice(3),
    }));
    return {
      workspace: root,
      branch,
      upstream: upstreamPart.replace(/\s+\[.*\]$/, ""),
      summary: header,
      entries,
      truncated: lines.length > 500,
      clean: entries.length === 0,
    };
  }

  private async gitDiff(input: Params): Promise<unknown> {
    const root = this.root(input);
    const requested = optionalString(input, "path");
    const staged = input.staged === true;
    const args = [
      "diff",
      "--no-ext-diff",
      "--no-textconv",
      "--no-color",
      "--src-prefix=a/",
      "--dst-prefix=b/",
    ];
    if (staged) args.push("--cached");
    if (requested) {
      const relativePath = normalizedRelativePath(requested);
      if (!relativePath) throw new Error("A file path is required for a scoped diff.");
      const candidate = resolve(root, relativePath);
      if (!isPathWithin(candidate, root)) {
        throw new Error("Path is outside the selected workspace.");
      }
      args.push("--", relativePath);
    }
    const diff = await this.git(root, args);
    return {
      path: requested || null,
      staged,
      diff,
      truncated: Buffer.byteLength(diff, "utf8") >= maxGitOutputBytes,
    };
  }
}
