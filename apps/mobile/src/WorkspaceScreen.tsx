import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ServerMessage } from "@relaycode/protocol";
import { bridgeClient } from "./bridge";

type Workspace = { path: string; name: string };
type WorkspaceMode = "files" | "git" | "terminal";
type WorkspaceEntry = {
  name: string;
  path: string;
  kind: "directory" | "file" | "symlink" | "other";
  size: number;
  modifiedAt: number;
  editable: boolean;
};
type DirectoryListing = {
  path: string;
  parent: string | null;
  entries: WorkspaceEntry[];
  truncated: boolean;
};
type OpenFile = {
  path: string;
  content: string;
  hash: string;
  size: number;
  modifiedAt: number;
  language: string;
};
type SearchResult = {
  path: string;
  line: number;
  column: number;
  preview: string;
};
type GitEntry = {
  index: string;
  workingTree: string;
  path: string;
};
type GitStatus = {
  branch: string;
  upstream: string;
  summary: string;
  entries: GitEntry[];
  clean: boolean;
  truncated: boolean;
};
type TerminalSession = {
  id: string;
  workspace: string;
  network: boolean;
  output: string;
  sequence: number;
  state: "running" | "exited";
  exitCode?: number | null;
  signal?: string | null;
};
type TerminalList = {
  capability: { available: boolean; reason?: string };
  sessions: TerminalSession[];
};

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function readableBytes(value: number): string {
  if (value < 1_000) return `${value} B`;
  if (value < 1_000_000) return `${(value / 1_000).toFixed(1)} KB`;
  return `${(value / 1_000_000).toFixed(1)} MB`;
}

function displayPath(value: string): string {
  return value || "프로젝트 루트";
}

function gitPath(value: string): string {
  return value.includes(" -> ") ? value.split(" -> ").at(-1)! : value;
}

export function WorkspaceScreen({
  workspaces,
  onError,
}: {
  workspaces: Workspace[];
  onError: (message: string) => void;
}) {
  const [workspace, setWorkspace] = useState(workspaces[0]?.path || "");
  const [mode, setMode] = useState<WorkspaceMode>("files");
  const [loading, setLoading] = useState(false);
  const [path, setPath] = useState("");
  const [listing, setListing] = useState<DirectoryListing>();
  const [openFile, setOpenFile] = useState<OpenFile>();
  const [editorContent, setEditorContent] = useState("");
  const [saving, setSaving] = useState(false);
  const [query, setQuery] = useState("");
  const [searchResults, setSearchResults] = useState<SearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [git, setGit] = useState<GitStatus>();
  const [diff, setDiff] = useState<{ path: string; text: string; staged: boolean }>();
  const [terminalList, setTerminalList] = useState<TerminalList>({
    capability: { available: false },
    sessions: [],
  });
  const [terminalId, setTerminalId] = useState("");
  const [terminalInput, setTerminalInput] = useState("");
  const [terminalNetwork, setTerminalNetwork] = useState(false);
  const terminalOutputRef = useRef<HTMLPreElement>(null);

  const activeTerminal = useMemo(
    () => terminalList.sessions.find((session) => session.id === terminalId),
    [terminalId, terminalList.sessions],
  );
  const editorDirty = Boolean(
    openFile && editorContent !== openFile.content,
  );

  useEffect(() => {
    if (!workspace && workspaces[0]) setWorkspace(workspaces[0].path);
  }, [workspace, workspaces]);

  const run = useCallback(async <T,>(
    action: () => Promise<T>,
  ): Promise<T | undefined> => {
    try {
      return await action();
    } catch (cause) {
      onError(cause instanceof Error ? cause.message : String(cause));
      return undefined;
    }
  }, [onError]);

  const loadEntries = useCallback(async (
    requestedPath = path,
  ) => {
    if (!workspace) return;
    setLoading(true);
    const value = await run(() => bridgeClient.rpc<DirectoryListing>(
      "workspace/entries",
      { workspace, path: requestedPath },
    ));
    if (value) {
      setListing(value);
      setPath(value.path);
      setOpenFile(undefined);
      setSearchResults([]);
    }
    setLoading(false);
  }, [path, run, workspace]);

  const loadGit = useCallback(async () => {
    if (!workspace) return;
    setLoading(true);
    const value = await run(() => bridgeClient.rpc<GitStatus>(
      "workspace/git/status",
      { workspace },
    ));
    if (value) setGit(value);
    setLoading(false);
  }, [run, workspace]);

  const loadTerminals = useCallback(async () => {
    const value = await run(() => bridgeClient.rpc<TerminalList>(
      "terminal/session/list",
      {},
    ));
    if (!value) return;
    const sessions = value.sessions.filter(
      (session) => session.workspace === workspace,
    );
    setTerminalList({ ...value, sessions });
    setTerminalId((current) => (
      sessions.some((session) => session.id === current)
        ? current
        : sessions[0]?.id || ""
    ));
  }, [run, workspace]);

  useEffect(() => {
    setPath("");
    setListing(undefined);
    setOpenFile(undefined);
    setEditorContent("");
    setSearchResults([]);
    setGit(undefined);
    setDiff(undefined);
    if (mode === "files") void loadEntries("");
    if (mode === "git") void loadGit();
    if (mode === "terminal") void loadTerminals();
  }, [workspace, mode]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => bridgeClient.subscribe((message: ServerMessage) => {
    if (message.type !== "notification") return;
    if (
      message.method !== "terminal/output"
      && message.method !== "terminal/exited"
    ) {
      return;
    }
    const value = record(message.params);
    const sessionId = String(value.sessionId || "");
    setTerminalList((current) => ({
      ...current,
      sessions: current.sessions.map((session) => {
        if (session.id !== sessionId) return session;
        if (message.method === "terminal/output") {
          const output = `${session.output}${String(value.data || "")}`;
          return {
            ...session,
            output: output.slice(-256 * 1024),
            sequence: Number(value.sequence || session.sequence),
          };
        }
        return {
          ...session,
          state: "exited",
          exitCode: typeof value.code === "number" ? value.code : null,
          signal: typeof value.signal === "string" ? value.signal : null,
        };
      }),
    }));
  }), []);

  useEffect(() => {
    const target = terminalOutputRef.current;
    if (target) target.scrollTop = target.scrollHeight;
  }, [activeTerminal?.output]);

  const openRemoteFile = async (filePath: string) => {
    if (editorDirty && !window.confirm("저장하지 않은 변경을 버릴까요?")) return;
    setLoading(true);
    const value = await run(() => bridgeClient.rpc<OpenFile>(
      "workspace/file/read",
      { workspace, path: filePath },
    ));
    if (value) {
      setOpenFile(value);
      setEditorContent(value.content);
      setSearchResults([]);
    }
    setLoading(false);
  };

  const saveFile = async () => {
    if (!openFile || !editorDirty) return;
    if (!window.confirm(`${openFile.path}\nMac 저장소에 변경을 저장할까요?`)) {
      return;
    }
    setSaving(true);
    const value = await run(() => bridgeClient.rpc<{
      hash: string;
      size: number;
      modifiedAt: number;
    }>("workspace/file/write", {
      workspace,
      path: openFile.path,
      content: editorContent,
      expectedHash: openFile.hash,
    }));
    if (value) {
      setOpenFile({
        ...openFile,
        content: editorContent,
        hash: value.hash,
        size: value.size,
        modifiedAt: value.modifiedAt,
      });
    }
    setSaving(false);
  };

  const search = async (event: FormEvent) => {
    event.preventDefault();
    if (!query.trim()) return;
    setSearching(true);
    setOpenFile(undefined);
    const value = await run(() => bridgeClient.rpc<{
      results: SearchResult[];
    }>("workspace/search", {
      workspace,
      path,
      query: query.trim(),
    }));
    if (value) setSearchResults(value.results);
    setSearching(false);
  };

  const showDiff = async (filePath: string, staged = false) => {
    const pathValue = gitPath(filePath);
    setLoading(true);
    const value = await run(() => bridgeClient.rpc<{ diff: string }>(
      "workspace/git/diff",
      { workspace, path: pathValue, staged },
    ));
    if (value) setDiff({
      path: pathValue,
      text: value.diff || "표시할 diff가 없습니다. 새 파일은 파일 탭에서 확인하세요.",
      staged,
    });
    setLoading(false);
  };

  const startTerminal = async () => {
    if (
      terminalNetwork
      && !window.confirm(
        "이 터미널 세션에 외부 네트워크를 허용할까요?\n파일 쓰기는 선택한 workspace 안으로 계속 제한됩니다.",
      )
    ) {
      return;
    }
    const value = await run(() => bridgeClient.rpc<TerminalSession>(
      "terminal/session/start",
      { workspace, network: terminalNetwork },
    ));
    if (!value) return;
    setTerminalList((current) => ({
      ...current,
      sessions: [value, ...current.sessions],
    }));
    setTerminalId(value.id);
  };

  const sendTerminal = async (event: FormEvent) => {
    event.preventDefault();
    const command = terminalInput.trim();
    if (!activeTerminal || !command || activeTerminal.state !== "running") {
      return;
    }
    setTerminalInput("");
    await run(() => bridgeClient.rpc("terminal/session/write", {
      sessionId: activeTerminal.id,
      data: `${command}\n`,
    }));
  };

  const interruptTerminal = async () => {
    if (!activeTerminal || activeTerminal.state !== "running") return;
    await run(() => bridgeClient.rpc("terminal/session/interrupt", {
      sessionId: activeTerminal.id,
    }));
  };

  const closeTerminal = async () => {
    if (!activeTerminal) return;
    await run(() => bridgeClient.rpc("terminal/session/close", {
      sessionId: activeTerminal.id,
    }));
    setTerminalList((current) => ({
      ...current,
      sessions: current.sessions.filter(
        (session) => session.id !== activeTerminal.id,
      ),
    }));
    setTerminalId("");
  };

  return (
    <section className="screen workspace-screen">
      <div className="section-heading start-heading">
        <div><p className="eyebrow">REMOTE STUDIO</p><h3>코드와 터미널</h3></div>
        {loading && <span className="workspace-spinner" aria-label="불러오는 중" />}
      </div>

      <label className="workspace-picker">
        <span>Mac workspace</span>
        <select value={workspace} onChange={(event) => setWorkspace(event.target.value)}>
          {workspaces.map((item) => (
            <option value={item.path} key={item.path}>{item.name}</option>
          ))}
        </select>
      </label>

      <div className="workspace-tabs">
        {([
          ["files", "파일"],
          ["git", "Git"],
          ["terminal", "터미널"],
        ] as const).map(([value, label]) => (
          <button
            key={value}
            className={mode === value ? "active" : ""}
            onClick={() => setMode(value)}
          >
            {label}
          </button>
        ))}
      </div>

      {mode === "files" && (
        <div className="workspace-panel">
          {openFile ? (
            <div className="remote-editor">
              <div className="editor-toolbar">
                <button onClick={() => {
                  if (!editorDirty || window.confirm("저장하지 않은 변경을 버릴까요?")) {
                    setOpenFile(undefined);
                    setEditorContent("");
                  }
                }}>‹</button>
                <div><strong>{openFile.path.split("/").at(-1)}</strong><small>{openFile.path} · {openFile.language}</small></div>
                <button
                  className="save-file"
                  disabled={!editorDirty || saving}
                  onClick={saveFile}
                >
                  {saving ? "저장 중" : editorDirty ? "저장" : "저장됨"}
                </button>
              </div>
              <textarea
                className="code-editor"
                value={editorContent}
                onChange={(event) => setEditorContent(event.target.value)}
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
              />
            </div>
          ) : (
            <>
              <form className="workspace-search" onSubmit={search}>
                <input
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder="이 폴더에서 코드 검색"
                  autoCapitalize="none"
                  autoCorrect="off"
                />
                <button disabled={searching || !query.trim()}>
                  {searching ? "…" : "검색"}
                </button>
              </form>
              <div className="path-toolbar">
                <button
                  disabled={listing?.parent === null || listing?.parent === undefined}
                  onClick={() => void loadEntries(listing?.parent || "")}
                >‹</button>
                <strong>{displayPath(listing?.path || path)}</strong>
                <button onClick={() => void loadEntries()}>↻</button>
              </div>
              {searchResults.length > 0 ? (
                <div className="search-result-list">
                  <div className="result-heading">
                    <strong>검색 결과 {searchResults.length}개</strong>
                    <button onClick={() => setSearchResults([])}>닫기</button>
                  </div>
                  {searchResults.map((result) => (
                    <button
                      key={`${result.path}:${result.line}:${result.column}`}
                      onClick={() => void openRemoteFile(result.path)}
                    >
                      <strong>{result.path}</strong>
                      <small>{result.line}:{result.column} · {result.preview}</small>
                    </button>
                  ))}
                </div>
              ) : (
                <div className="file-list">
                  {listing?.entries.map((entry) => (
                    <button
                      key={entry.path}
                      disabled={entry.kind !== "directory" && !entry.editable}
                      onClick={() => {
                        if (entry.kind === "directory") void loadEntries(entry.path);
                        else if (entry.editable) void openRemoteFile(entry.path);
                      }}
                    >
                      <span className={`file-icon ${entry.kind}`}>
                        {entry.kind === "directory" ? "▰" : entry.kind === "file" ? "·/" : "↗"}
                      </span>
                      <span><strong>{entry.name}</strong><small>{entry.kind === "file" ? readableBytes(entry.size) : entry.kind}</small></span>
                      <b>{entry.kind === "directory" || entry.editable ? "›" : "잠김"}</b>
                    </button>
                  ))}
                  {!loading && listing?.entries.length === 0 && (
                    <div className="empty-card compact"><strong>빈 폴더입니다</strong></div>
                  )}
                </div>
              )}
            </>
          )}
        </div>
      )}

      {mode === "git" && (
        <div className="workspace-panel">
          <div className="git-summary">
            <div><span>BRANCH</span><strong>{git?.branch || "—"}</strong><small>{git?.upstream || "로컬 브랜치"}</small></div>
            <button onClick={() => {
              setDiff(undefined);
              void loadGit();
            }}>새로고침</button>
          </div>
          {diff ? (
            <div className="git-diff">
              <div><button onClick={() => setDiff(undefined)}>‹</button><strong>{diff.path}</strong><span>{diff.staged ? "STAGED" : "WORKTREE"}</span></div>
              <pre>{diff.text}</pre>
            </div>
          ) : git?.clean ? (
            <div className="empty-card compact"><strong>작업 트리가 깨끗합니다</strong><p>Mac 저장소에 변경된 파일이 없습니다.</p></div>
          ) : (
            <div className="git-file-list">
              {git?.entries.map((entry, index) => (
                <button
                  key={`${entry.path}-${index}`}
                  onClick={() => void showDiff(entry.path, entry.index !== " " && entry.workingTree === " ")}
                >
                  <span>{entry.index}{entry.workingTree}</span>
                  <strong>{entry.path}</strong>
                  <b>›</b>
                </button>
              ))}
            </div>
          )}
          <p className="workspace-boundary">
            커밋·pull·push는 아직 Codex 작업 승인 흐름에서 실행됩니다. 이 탭은 상태와 diff를 읽기 전용으로 보여줍니다.
          </p>
        </div>
      )}

      {mode === "terminal" && (
        <div className="workspace-panel terminal-panel">
          {!terminalList.capability.available ? (
            <div className="empty-card compact">
              <strong>샌드박스 터미널을 사용할 수 없습니다</strong>
              <p>{terminalList.capability.reason || "Mac 브리지 상태를 확인하세요."}</p>
            </div>
          ) : (
            <>
              <div className="terminal-controls">
                <select value={terminalId} onChange={(event) => setTerminalId(event.target.value)}>
                  <option value="">새 세션</option>
                  {terminalList.sessions.map((session, index) => (
                    <option key={session.id} value={session.id}>
                      터미널 {index + 1} · {session.state} · network {session.network ? "on" : "off"}
                    </option>
                  ))}
                </select>
                {!activeTerminal ? (
                  <button onClick={() => void startTerminal()}>시작</button>
                ) : (
                  <button className="terminal-close" onClick={() => void closeTerminal()}>닫기</button>
                )}
              </div>
              {!activeTerminal && (
                <label className="network-toggle">
                  <input
                    type="checkbox"
                    checked={terminalNetwork}
                    onChange={(event) => setTerminalNetwork(event.target.checked)}
                  />
                  <span><strong>외부 네트워크 허용</strong><small>기본값은 차단입니다. 파일 쓰기는 workspace 내부만 허용됩니다.</small></span>
                </label>
              )}
              {activeTerminal && (
                <>
                  <pre className="terminal-output" ref={terminalOutputRef}>
                    {activeTerminal.output || "터미널 준비 중…"}
                  </pre>
                  <form className="terminal-input" onSubmit={sendTerminal}>
                    <span>$</span>
                    <input
                      value={terminalInput}
                      onChange={(event) => setTerminalInput(event.target.value)}
                      placeholder={activeTerminal.state === "running" ? "명령 입력" : "세션이 종료됐습니다"}
                      disabled={activeTerminal.state !== "running"}
                      autoCapitalize="none"
                      autoCorrect="off"
                      spellCheck={false}
                    />
                    <button disabled={!terminalInput.trim() || activeTerminal.state !== "running"}>실행</button>
                  </form>
                  <div className="terminal-meta">
                    <span>network {activeTerminal.network ? "on" : "off"}</span>
                    <span>{activeTerminal.state}</span>
                    {activeTerminal.state === "running" && (
                      <button onClick={() => void interruptTerminal()}>중단</button>
                    )}
                  </div>
                </>
              )}
              <p className="workspace-boundary">
                zsh 설정과 Mac 자격 증명은 전달되지 않습니다. 쓰기는 선택한 workspace와 격리된 임시 HOME에만 허용됩니다.
              </p>
            </>
          )}
        </div>
      )}
    </section>
  );
}
