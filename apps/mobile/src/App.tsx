import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import type { BridgeStatus, ServerMessage } from "@relaycode/protocol";
import {
  bridgeClient,
  clearPairing,
  pairingConfig,
  savePairing,
  type ConnectionState,
} from "./bridge";

type View = "home" | "start" | "usage" | "settings" | "thread";
type UnknownRecord = Record<string, unknown>;
type Workspace = { path: string; name: string };
type Model = {
  id: string;
  model: string;
  displayName: string;
  description?: string;
  isDefault?: boolean;
  defaultReasoningEffort?: string;
  supportedReasoningEfforts?: Array<{ reasoningEffort?: string } | string>;
};
type Turn = { id: string; status?: string; items?: TimelineItem[] };
type Thread = {
  id: string;
  preview?: string;
  name?: string | null;
  cwd?: string;
  modelProvider?: string;
  updatedAt?: number;
  recencyAt?: number | null;
  status?: unknown;
  turns?: Turn[];
};
type TimelineItem = UnknownRecord & { id?: string; type?: string };
type Approval = { id: number | string; method: string; params: UnknownRecord };
type InputQuestion = {
  id: string;
  header?: string;
  question?: string;
  isOther?: boolean;
  isSecret?: boolean;
  options?: Array<{ label?: string; description?: string }> | null;
};

function record(value: unknown): UnknownRecord {
  return value && typeof value === "object" && !Array.isArray(value) ? value as UnknownRecord : {};
}

function array<T = unknown>(value: unknown): T[] {
  return Array.isArray(value) ? value as T[] : [];
}

function basename(path: unknown): string {
  if (typeof path !== "string") return "Workspace";
  return path.split(/[\\/]/).filter(Boolean).at(-1) || path;
}

function threadTitle(thread: Thread): string {
  return thread.name?.trim() || thread.preview?.trim() || "새 개발 세션";
}

function threadState(status: unknown): string {
  if (typeof status === "string") return status;
  const value = record(status);
  return typeof value.type === "string" ? value.type : "idle";
}

function relativeTime(timestamp?: number | null): string {
  if (!timestamp) return "";
  const value = timestamp < 10_000_000_000 ? timestamp * 1000 : timestamp;
  const seconds = Math.max(0, Math.round((Date.now() - value) / 1000));
  if (seconds < 60) return "방금";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}분 전`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}시간 전`;
  return `${Math.floor(seconds / 86_400)}일 전`;
}

function flattenItems(thread: Thread): TimelineItem[] {
  return array<Turn>(thread.turns).flatMap((turn) => array<TimelineItem>(turn.items));
}

function modelEfforts(model?: Model): string[] {
  const values = array<{ reasoningEffort?: string } | string>(model?.supportedReasoningEfforts)
    .map((item) => typeof item === "string" ? item : item.reasoningEffort)
    .filter((item): item is string => Boolean(item));
  return values.length ? values : ["low", "medium", "high", "xhigh"];
}

function PairScreen({ state, error }: { state: ConnectionState; error: string }) {
  const saved = pairingConfig();
  const [token, setToken] = useState(saved.token);
  const [bridge, setBridge] = useState(saved.bridge);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    savePairing(token, bridge);
    bridgeClient.disconnect();
    bridgeClient.connect();
  };

  return (
    <main className="pair-screen">
      <div className="pair-orbit" aria-hidden="true">
        <span />
        <span />
        <span />
      </div>
      <section className="pair-card">
        <div className="brand-mark">&lt;/&gt;</div>
        <p className="eyebrow">PRIVATE DEV LINK</p>
        <h1>Mac의 개발 환경을<br />폰에 연결하세요.</h1>
        <p className="pair-copy">
          저장소와 자격 증명은 Mac에 남습니다. RelayCode는 세션, 승인, diff만 안전하게 중계합니다.
        </p>
        <form onSubmit={submit}>
          <label>
            Bridge WebSocket
            <input
              value={bridge}
              onChange={(event) => setBridge(event.target.value)}
              placeholder="wss://your-mac.tailnet.ts.net/ws"
              autoCapitalize="none"
              autoCorrect="off"
            />
          </label>
          <label>
            Pairing token
            <input
              value={token}
              onChange={(event) => setToken(event.target.value)}
              placeholder="Mac에서 npm run pair"
              autoCapitalize="none"
              autoCorrect="off"
              type="password"
            />
          </label>
          <button className="primary-button" disabled={!token.trim() || !bridge.trim()}>
            {state === "connecting" ? "연결 확인 중…" : "Mac 연결"}
          </button>
        </form>
        {error && <p className="inline-error">{error}</p>}
        <p className="pair-hint">Mac에서 출력된 QR 링크를 열면 이 화면은 자동으로 채워집니다.</p>
      </section>
    </main>
  );
}

function StatusPill({ state }: { state: ConnectionState }) {
  const label = state === "connected" ? "연결됨" : state === "connecting" ? "연결 중" : "오프라인";
  return <span className={`status-pill ${state}`}><i />{label}</span>;
}

function HomeScreen({
  threads,
  approvals,
  loading,
  onOpen,
  onStart,
}: {
  threads: Thread[];
  approvals: Approval[];
  loading: boolean;
  onOpen: (thread: Thread) => void;
  onStart: () => void;
}) {
  const active = threads.filter((thread) => {
    const value = threadState(thread.status).toLowerCase();
    return value.includes("active") || value.includes("running");
  });
  return (
    <section className="screen">
      <div className="hero-card">
        <div>
          <p className="eyebrow">MOBILE MISSION CONTROL</p>
          <h2>{approvals.length ? `${approvals.length}개의 결정이 기다려요` : active.length ? `${active.length}개 작업이 실행 중이에요` : "다음 작업을 시작할까요?"}</h2>
          <p>긴 대화보다 현재 상태와 다음 결정에 집중합니다.</p>
        </div>
        <button className="hero-action" onClick={onStart} aria-label="새 작업">+</button>
      </div>

      {approvals.length > 0 && (
        <div className="attention-strip">
          <span className="attention-icon">!</span>
          <div><strong>Mac 작업이 멈춰 있습니다</strong><small>아래 승인 카드에서 계속 여부를 선택하세요.</small></div>
        </div>
      )}

      <div className="section-heading">
        <div><p className="eyebrow">RUNS</p><h3>최근 개발 세션</h3></div>
        <span>{threads.length}</span>
      </div>
      <div className="thread-list">
        {threads.slice(0, 20).map((thread) => {
          const state = threadState(thread.status);
          return (
            <button className="thread-card" key={thread.id} onClick={() => onOpen(thread)}>
              <span className={`run-light ${state}`} />
              <span className="thread-main">
                <strong>{threadTitle(thread)}</strong>
                <small>{basename(thread.cwd)} · {thread.modelProvider || "codex"}</small>
              </span>
              <span className="thread-side">
                <small>{relativeTime(thread.recencyAt ?? thread.updatedAt)}</small>
                <b>›</b>
              </span>
            </button>
          );
        })}
        {loading && threads.length === 0 && (
          <div className="loading-card" role="status">
            <span />
            <div><i /><i /></div>
            <small>Mac에서 세션을 불러오는 중</small>
          </div>
        )}
        {!loading && threads.length === 0 && (
          <div className="empty-card">
            <span>&lt;/&gt;</span>
            <strong>아직 세션이 없습니다</strong>
            <p>작업 폴더와 모델을 고르고 첫 원격 개발 작업을 시작하세요.</p>
            <button onClick={onStart}>첫 작업 만들기</button>
          </div>
        )}
      </div>
    </section>
  );
}

function StartScreen({
  workspaces,
  models,
  busy,
  onSubmit,
}: {
  workspaces: Workspace[];
  models: Model[];
  busy: boolean;
  onSubmit: (input: { cwd: string; model?: string; effort?: string; prompt: string }) => Promise<void>;
}) {
  const defaultModel = models.find((model) => model.isDefault) || models[0];
  const [cwd, setCwd] = useState(workspaces[0]?.path || "");
  const [model, setModel] = useState(defaultModel?.model || defaultModel?.id || "");
  const selectedModel = models.find((item) => item.model === model || item.id === model) || defaultModel;
  const efforts = modelEfforts(selectedModel);
  const [effort, setEffort] = useState(selectedModel?.defaultReasoningEffort || efforts[0]);
  const [prompt, setPrompt] = useState("");

  useEffect(() => {
    if (!cwd && workspaces[0]) setCwd(workspaces[0].path);
  }, [cwd, workspaces]);
  useEffect(() => {
    if (!model && defaultModel) setModel(defaultModel.model || defaultModel.id);
  }, [defaultModel, model]);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    await onSubmit({ cwd, model: model || undefined, effort: effort || undefined, prompt });
  };

  return (
    <section className="screen">
      <div className="section-heading start-heading">
        <div><p className="eyebrow">LAUNCH</p><h3>새 개발 작업</h3></div>
      </div>
      <form className="launch-form" onSubmit={submit}>
        <label className="field-card">
          <span>작업 공간</span>
          <select value={cwd} onChange={(event) => setCwd(event.target.value)}>
            {workspaces.map((workspace) => <option key={workspace.path} value={workspace.path}>{workspace.name}</option>)}
          </select>
          <small>{cwd || "Mac에서 허용할 workspace root를 설정하세요."}</small>
        </label>

        <div className="field-card">
          <span>실행 엔진</span>
          <div className="engine-row">
            <div className="engine-logo">C</div>
            <div><strong>Codex App Server</strong><small>공식 stdio 연결 · 모바일 승인</small></div>
            <i>READY</i>
          </div>
        </div>

        <label className="field-card">
          <span>모델 경로</span>
          <select value={model} onChange={(event) => setModel(event.target.value)}>
            {models.map((item) => (
              <option key={item.id} value={item.model || item.id}>{item.displayName || item.model || item.id}</option>
            ))}
          </select>
          <small>{selectedModel?.description || "Mac의 Codex 모델 카탈로그에서 불러옵니다."}</small>
        </label>

        <div className="field-card">
          <span>추론 강도</span>
          <div className="effort-grid">
            {efforts.map((value) => (
              <button type="button" key={value} className={effort === value ? "selected" : ""} onClick={() => setEffort(value)}>
                {value}
              </button>
            ))}
          </div>
        </div>

        <label className="prompt-card">
          <span>무엇을 맡길까요?</span>
          <textarea
            value={prompt}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder="예: 현재 실패하는 테스트의 원인을 찾고, 수정한 뒤 전체 테스트를 실행해줘."
            rows={7}
          />
          <div className="task-chips">
            {["원인 조사", "구현", "테스트", "리뷰"].map((label) => (
              <button type="button" key={label} onClick={() => setPrompt((current) => current || `${label}부터 진행해줘.`)}>{label}</button>
            ))}
          </div>
        </label>

        <div className="safety-note"><span>✓</span><p><strong>모바일 안전 모드</strong><br />workspace-write · 작업별 승인 · 네트워크 기본 제한</p></div>
        <button className="primary-button launch-button" disabled={busy || !cwd || !prompt.trim()}>
          {busy ? "세션 준비 중…" : "작업 시작"}
        </button>
      </form>
    </section>
  );
}

function ItemCard({ item }: { item: TimelineItem }) {
  const type = item.type || "activity";
  if (type === "userMessage") {
    const text = array<UnknownRecord>(item.content).map((part) => part.text).filter(Boolean).join("\n");
    return <article className="timeline-item user-item"><p>{String(text || "")}</p></article>;
  }
  if (type === "agentMessage") {
    return <article className="timeline-item agent-item"><span className="timeline-label">AGENT</span><p>{String(item.text || "")}</p></article>;
  }
  if (type === "reasoning") {
    return <details className="timeline-item detail-item"><summary>판단 과정 요약</summary><pre>{array(item.summary).join("\n") || array(item.content).join("\n")}</pre></details>;
  }
  if (type === "plan") {
    return <article className="timeline-item plan-item"><span className="timeline-label">PLAN</span><pre>{String(item.text || "")}</pre></article>;
  }
  if (type === "commandExecution") {
    return (
      <details className="timeline-item tool-item">
        <summary><span className={`tool-dot ${String(item.status || "")}`} />명령 실행 <b>{String(item.status || "")}</b></summary>
        <code>{String(item.command || "")}</code>
        {item.aggregatedOutput ? <pre>{String(item.aggregatedOutput)}</pre> : null}
      </details>
    );
  }
  if (type === "fileChange") {
    return (
      <details className="timeline-item tool-item">
        <summary><span className={`tool-dot ${String(item.status || "")}`} />파일 변경 <b>{String(item.status || "")}</b></summary>
        <ul>{array<UnknownRecord>(item.changes).map((change, index) => <li key={index}>{String(change.path || change.filePath || "file")}</li>)}</ul>
      </details>
    );
  }
  if (type === "mcpToolCall" || type === "dynamicToolCall" || type === "collabAgentToolCall") {
    return (
      <details className="timeline-item tool-item">
        <summary><span className={`tool-dot ${String(item.status || "")}`} />{String(item.tool || type)} <b>{String(item.status || "")}</b></summary>
        <pre>{JSON.stringify(item.arguments || item, null, 2)}</pre>
      </details>
    );
  }
  return (
    <details className="timeline-item detail-item">
      <summary>{type}</summary>
      <pre>{JSON.stringify(item, null, 2)}</pre>
    </details>
  );
}

function UserInputDock({
  approval,
  onRespond,
}: {
  approval: Approval;
  onRespond: (approval: Approval, result: unknown) => void;
}) {
  const questions = array<InputQuestion>(approval.params.questions);
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const ready = questions.length > 0 && questions.every((question) => Boolean(answers[question.id]?.trim()));
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!ready) return;
    onRespond(approval, {
      answers: Object.fromEntries(questions.map((question) => [
        question.id,
        { answers: [answers[question.id].trim()] },
      ])),
    });
  };

  return (
    <aside className="approval-dock question-dock">
      <div className="approval-grabber" />
      <div className="approval-title">
        <span>?</span>
        <div><p className="eyebrow">INPUT REQUIRED</p><h3>작업을 계속하려면 답이 필요해요</h3></div>
      </div>
      <form className="question-form" onSubmit={submit}>
        {questions.map((question) => {
          const options = array<{ label?: string; description?: string }>(question.options);
          return (
            <fieldset key={question.id}>
              <legend><small>{question.header || "질문"}</small>{question.question || "응답을 입력하세요."}</legend>
              {options.length > 0 && (
                <div className="question-options">
                  {options.map((option, index) => {
                    const label = String(option.label || `옵션 ${index + 1}`);
                    return (
                      <button
                        type="button"
                        key={`${question.id}-${label}`}
                        className={answers[question.id] === label ? "selected" : ""}
                        onClick={() => setAnswers((current) => ({ ...current, [question.id]: label }))}
                      >
                        <strong>{label}</strong>
                        {option.description && <small>{String(option.description)}</small>}
                      </button>
                    );
                  })}
                </div>
              )}
              {(options.length === 0 || question.isOther) && (
                <input
                  type={question.isSecret ? "password" : "text"}
                  value={options.some((option) => option.label === answers[question.id]) ? "" : answers[question.id] || ""}
                  onChange={(event) => setAnswers((current) => ({ ...current, [question.id]: event.target.value }))}
                  placeholder={options.length ? "직접 입력" : "답변"}
                  autoComplete="off"
                />
              )}
            </fieldset>
          );
        })}
        <button className="primary-button question-submit" disabled={!ready}>답변 보내고 계속</button>
      </form>
    </aside>
  );
}

function approvalResult(method: string, decision: "accept" | "acceptForSession" | "decline" | "cancel"): unknown {
  if (method === "execCommandApproval" || method === "applyPatchApproval") {
    const legacy = {
      accept: "approved",
      acceptForSession: "approved_for_session",
      decline: "denied",
      cancel: "abort",
    } as const;
    return { decision: legacy[decision] };
  }
  return { decision };
}

function ApprovalDock({
  approvals,
  onRespond,
}: {
  approvals: Approval[];
  onRespond: (approval: Approval, result: unknown) => void;
}) {
  if (!approvals.length) return null;
  const approval = approvals[0];
  if (approval.method === "item/tool/requestUserInput") {
    return <UserInputDock key={approval.id} approval={approval} onRespond={onRespond} />;
  }
  const isCommand = approval.method === "item/commandExecution/requestApproval" || approval.method === "execCommandApproval";
  const isFile = approval.method === "item/fileChange/requestApproval" || approval.method === "applyPatchApproval";
  const rawCommand = approval.params.command;
  const command = Array.isArray(rawCommand) ? rawCommand.join(" ") : String(rawCommand || "명령 미리보기 없음");
  const changedFiles = Object.keys(record(approval.params.fileChanges));
  return (
    <aside className="approval-dock">
      <div className="approval-grabber" />
      <div className="approval-title">
        <span>{isCommand ? "$" : "±"}</span>
        <div><p className="eyebrow">ACTION REQUIRED</p><h3>{isCommand ? "명령 실행을 허용할까요?" : "파일 변경을 허용할까요?"}</h3></div>
      </div>
      {approval.params.reason ? <p className="approval-reason">{String(approval.params.reason)}</p> : null}
      {isCommand && <pre className="approval-command">{command}</pre>}
      {isFile && changedFiles.length > 0 && <pre className="approval-command">{changedFiles.join("\n")}</pre>}
      <small className="approval-path">{String(approval.params.cwd || approval.params.grantRoot || "")}</small>
      {isCommand || isFile ? (
        <div className="approval-actions">
          <button className="deny" onClick={() => onRespond(approval, approvalResult(approval.method, "decline"))}>거절</button>
          <button onClick={() => onRespond(approval, approvalResult(approval.method, "accept"))}>이번만 허용</button>
          <button className="approve" onClick={() => onRespond(approval, approvalResult(approval.method, "acceptForSession"))}>세션 동안 허용</button>
        </div>
      ) : (
        <p className="approval-unsupported">지원하지 않는 요청입니다. 브리지가 안전하게 중단합니다.</p>
      )}
      {approvals.length > 1 && <small className="approval-count">이후 {approvals.length - 1}개 더 대기 중</small>}
    </aside>
  );
}

function ThreadScreen({
  thread,
  items,
  diff,
  activeTurn,
  onSend,
  onInterrupt,
  onBack,
}: {
  thread?: Thread;
  items: TimelineItem[];
  diff: string;
  activeTurn?: string;
  onSend: (text: string) => Promise<void>;
  onInterrupt: () => Promise<void>;
  onBack: () => void;
}) {
  const [text, setText] = useState("");
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const value = text.trim();
    if (!value) return;
    setText("");
    await onSend(value);
  };
  return (
    <section className="thread-screen">
      <header className="thread-header">
        <button onClick={onBack}>‹</button>
        <div><strong>{thread ? threadTitle(thread) : "세션"}</strong><small>{basename(thread?.cwd)} · {activeTurn ? "작업 중" : "대기"}</small></div>
        {activeTurn ? <button className="stop-button" onClick={onInterrupt}>■</button> : <span className="header-spacer" />}
      </header>
      <div className="timeline">
        {items.map((item, index) => <ItemCard key={String(item.id || `${item.type}-${index}`)} item={item} />)}
        {diff && (
          <details className="timeline-item diff-item">
            <summary>현재 turn diff 보기</summary>
            <pre>{diff}</pre>
          </details>
        )}
        {activeTurn && <div className="working-indicator"><i /><i /><i /><span>Mac에서 작업 중</span></div>}
      </div>
      <form className="thread-composer" onSubmit={submit}>
        <textarea value={text} onChange={(event) => setText(event.target.value)} placeholder={activeTurn ? "진행 중인 작업에 추가 지시…" : "다음 작업을 입력하세요…"} rows={1} />
        <button disabled={!text.trim()}>↑</button>
      </form>
    </section>
  );
}

function UsageScreen({ account, limits, usage }: { account: unknown; limits: unknown; usage: unknown }) {
  const accountValue = record(account);
  const snapshot = record(record(limits).rateLimits);
  const windows = [
    ["빠른 한도", record(snapshot.primary)],
    ["주간 한도", record(snapshot.secondary)],
  ] as const;
  const summary = record(record(usage).summary);
  return (
    <section className="screen">
      <div className="section-heading start-heading"><div><p className="eyebrow">CAPACITY</p><h3>사용량과 상태</h3></div></div>
      <div className="account-card">
        <div className="account-avatar">C</div>
        <div><strong>{String(record(accountValue.account).email || "Codex account")}</strong><small>{String(record(accountValue.account).planType || accountValue.planType || accountValue.authMode || "connected")}</small></div>
        <span>HEALTHY</span>
      </div>
      <div className="quota-grid">
        {windows.map(([label, value]) => {
          const used = Number(value.usedPercent || 0);
          return (
            <article key={label}>
              <div><span>{label}</span><strong>{Math.max(0, 100 - used).toFixed(0)}%</strong></div>
              <div className="meter"><i style={{ width: `${Math.min(100, Math.max(0, used))}%` }} /></div>
              <small>{value.resetsAt ? `${new Date(Number(value.resetsAt) * 1000).toLocaleString()} 초기화` : "초기화 정보 없음"}</small>
            </article>
          );
        })}
      </div>
      <div className="section-heading"><div><p className="eyebrow">ACTIVITY</p><h3>누적 작업 지표</h3></div></div>
      <div className="stat-grid">
        <article><span>누적 토큰</span><strong>{Number(summary.lifetimeTokens || 0).toLocaleString()}</strong></article>
        <article><span>연속 사용</span><strong>{String(summary.currentStreakDays || 0)}일</strong></article>
        <article><span>최장 작업</span><strong>{Math.round(Number(summary.longestRunningTurnSec || 0) / 60)}분</strong></article>
      </div>
      {!limits && <div className="empty-card compact"><strong>사용량 데이터를 불러올 수 없습니다</strong><p>API 키 인증이나 제공자 종류에 따라 quota 정보가 없을 수 있습니다.</p></div>}
    </section>
  );
}

function SettingsScreen({ status, onForget }: { status?: BridgeStatus; onForget: () => void }) {
  const config = pairingConfig();
  return (
    <section className="screen">
      <div className="section-heading start-heading"><div><p className="eyebrow">HOST</p><h3>연결과 보안</h3></div></div>
      <div className="settings-list">
        <article><span>Mac</span><strong>{status?.hostName || "—"}</strong></article>
        <article><span>Agent</span><strong>{status?.agent.label || "Codex"} · {status?.agent.state || "offline"}</strong></article>
        <article><span>Bridge</span><strong className="mono">{config.bridge}</strong></article>
        <article><span>Workspace roots</span><strong>{status?.workspaceRoots.length || 0}개</strong></article>
        <article><span>Protocol</span><strong>v{status?.protocolVersion || 1}</strong></article>
      </div>
      <div className="security-card">
        <span>⌁</span>
        <div><strong>저장소는 이 기기로 복사되지 않습니다</strong><p>명령, 파일 변경, 도구 실행은 Mac의 sandbox와 승인 정책을 그대로 따릅니다.</p></div>
      </div>
      <button className="danger-button" onClick={onForget}>이 휴대폰 연결 해제</button>
    </section>
  );
}

export function App() {
  const [connection, setConnection] = useState<ConnectionState>(bridgeClient.state);
  const [status, setStatus] = useState<BridgeStatus | undefined>(bridgeClient.status);
  const [view, setView] = useState<View>("home");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(false);
  const [threads, setThreads] = useState<Thread[]>([]);
  const [models, setModels] = useState<Model[]>([]);
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [account, setAccount] = useState<unknown>();
  const [limits, setLimits] = useState<unknown>();
  const [usage, setUsage] = useState<unknown>();
  const [currentThread, setCurrentThread] = useState<Thread>();
  const [items, setItems] = useState<TimelineItem[]>([]);
  const [activeTurn, setActiveTurn] = useState<string>();
  const [diff, setDiff] = useState("");
  const [approvals, setApprovals] = useState<Approval[]>([]);

  const refresh = useCallback(async () => {
    setLoading(true);
    const core = [
      bridgeClient.rpc<BridgeStatus>("relay/status").then(setStatus),
      bridgeClient.rpc<Workspace[]>("relay/workspaces").then(setWorkspaces),
      bridgeClient.rpc<{ data?: Model[] }>("model/list", { limit: 100 })
        .then((value) => setModels(array<Model>(record(value).data))),
      bridgeClient.rpc<{ data?: Thread[] }>("thread/list", { limit: 50 })
        .then((value) => setThreads(array<Thread>(record(value).data))),
    ];
    const metrics = [
      bridgeClient.rpc("account/read").then(setAccount),
      bridgeClient.rpc("account/rateLimits/read").then(setLimits),
      bridgeClient.rpc("account/usage/read").then(setUsage),
    ];
    await Promise.allSettled(core);
    setLoading(false);
    void Promise.allSettled(metrics);
  }, []);

  useEffect(() => {
    const unsubscribeState = bridgeClient.subscribeState((state) => {
      setConnection(state);
      if (state === "connected") {
        setError("");
        void refresh();
      }
    });
    const unsubscribe = bridgeClient.subscribe((message: ServerMessage) => {
      if (message.type === "hello" || message.type === "status") setStatus(message.status);
      if (message.type === "serverRequest") {
        const params = record(message.params);
        setApprovals((current) => current.some((item) => item.id === message.id) ? current : [...current, {
          id: message.id,
          method: message.method,
          params,
        }]);
        navigator.vibrate?.([80, 60, 80]);
      }
      if (message.type !== "notification") return;
      const params = record(message.params);
      const threadId = typeof params.threadId === "string" ? params.threadId : undefined;
      if (message.method === "serverRequest/resolved") {
        const requestId = params.requestId ?? params.id;
        setApprovals((current) => current.filter((item) => item.id !== requestId));
      }
      if (threadId && currentThread?.id !== threadId) return;
      if (message.method === "turn/started") {
        const turn = record(params.turn);
        if (typeof turn.id === "string") setActiveTurn(turn.id);
      }
      if (message.method === "turn/completed") {
        setActiveTurn(undefined);
        void refresh();
      }
      if (message.method === "turn/diff/updated" && typeof params.diff === "string") setDiff(params.diff);
      if ((message.method === "item/started" || message.method === "item/completed") && params.item) {
        const item = record(params.item) as TimelineItem;
        setItems((current) => {
          const index = current.findIndex((entry) => entry.id && entry.id === item.id);
          if (index < 0) return [...current, item];
          const copy = [...current];
          copy[index] = item;
          return copy;
        });
      }
      if (message.method === "item/agentMessage/delta" && typeof params.delta === "string") {
        const itemId = String(params.itemId || "live-agent");
        setItems((current) => {
          const index = current.findIndex((entry) => entry.id === itemId);
          if (index < 0) return [...current, { id: itemId, type: "agentMessage", text: params.delta }];
          const copy = [...current];
          copy[index] = { ...copy[index], text: `${String(copy[index].text || "")}${params.delta}` };
          return copy;
        });
      }
    });
    bridgeClient.connect();
    return () => {
      unsubscribe();
      unsubscribeState();
    };
  }, [currentThread?.id, refresh]);

  const openThread = useCallback(async (thread: Thread) => {
    setBusy(true);
    setError("");
    try {
      const resumed = await bridgeClient.rpc<UnknownRecord>("thread/resume", { threadId: thread.id });
      const read = await bridgeClient.rpc<UnknownRecord>("thread/read", { threadId: thread.id });
      const loaded = (record(read).thread || record(resumed).thread || thread) as Thread;
      setCurrentThread(loaded);
      setItems(flattenItems(loaded));
      setDiff("");
      const runningTurn = array<Turn>(loaded.turns).find((turn) => turn.status === "inProgress");
      setActiveTurn(runningTurn?.id);
      setView("thread");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  }, []);

  const startTask = useCallback(async (input: { cwd: string; model?: string; effort?: string; prompt: string }) => {
    setBusy(true);
    setError("");
    try {
      const started = await bridgeClient.rpc<UnknownRecord>("thread/start", {
        cwd: input.cwd,
        model: input.model,
      });
      const thread = record(started).thread as Thread;
      if (!thread?.id) throw new Error("Codex가 새 thread id를 반환하지 않았습니다.");
      setCurrentThread(thread);
      setItems([]);
      setDiff("");
      setView("thread");
      const turn = await bridgeClient.rpc<UnknownRecord>("turn/start", {
        threadId: thread.id,
        model: input.model,
        effort: input.effort,
        input: [{ type: "text", text: input.prompt }],
      });
      const turnId = record(record(turn).turn).id;
      if (typeof turnId === "string") setActiveTurn(turnId);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  }, []);

  const sendToThread = useCallback(async (text: string) => {
    if (!currentThread) return;
    const method = activeTurn ? "turn/steer" : "turn/start";
    const params = activeTurn
      ? { threadId: currentThread.id, expectedTurnId: activeTurn, input: [{ type: "text", text }] }
      : { threadId: currentThread.id, input: [{ type: "text", text }] };
    const result = await bridgeClient.rpc<UnknownRecord>(method, params);
    const turnId = record(record(result).turn).id || record(result).turnId;
    if (typeof turnId === "string") setActiveTurn(turnId);
  }, [activeTurn, currentThread]);

  const interrupt = useCallback(async () => {
    if (!currentThread || !activeTurn) return;
    await bridgeClient.rpc("turn/interrupt", { threadId: currentThread.id, turnId: activeTurn });
  }, [activeTurn, currentThread]);

  const approvalResponse = useCallback((approval: Approval, result: unknown) => {
    bridgeClient.respondServerRequest(approval.id, result);
    setApprovals((current) => current.filter((item) => item.id !== approval.id));
  }, []);

  const forget = useCallback(() => {
    bridgeClient.disconnect();
    clearPairing();
    setConnection("unpaired");
    setView("home");
  }, []);

  const navigation = useMemo(() => [
    { id: "home" as const, label: "작업", icon: "⌁" },
    { id: "start" as const, label: "시작", icon: "+" },
    { id: "usage" as const, label: "용량", icon: "◔" },
    { id: "settings" as const, label: "연결", icon: "⋯" },
  ], []);

  if (connection === "unpaired" || (!status && connection !== "connected")) {
    return <PairScreen state={connection} error={error} />;
  }

  return (
    <main className="app-shell">
      {view !== "thread" && (
        <header className="app-header">
          <div className="brand"><div className="brand-mark small">&lt;/&gt;</div><div><strong>RelayCode</strong><small>{status?.hostName || "Mac host"}</small></div></div>
          <StatusPill state={connection} />
        </header>
      )}

      {error && <button className="error-banner" onClick={() => setError("")}>{error}<span>×</span></button>}
      {view === "home" && <HomeScreen threads={threads} approvals={approvals} loading={loading} onOpen={openThread} onStart={() => setView("start")} />}
      {view === "start" && <StartScreen workspaces={workspaces} models={models} busy={busy} onSubmit={startTask} />}
      {view === "usage" && <UsageScreen account={account} limits={limits} usage={usage} />}
      {view === "settings" && <SettingsScreen status={status} onForget={forget} />}
      {view === "thread" && <ThreadScreen thread={currentThread} items={items} diff={diff} activeTurn={activeTurn} onSend={sendToThread} onInterrupt={interrupt} onBack={() => setView("home")} />}

      <ApprovalDock approvals={approvals} onRespond={approvalResponse} />

      {view !== "thread" && (
        <nav className="bottom-nav">
          {navigation.map((item) => (
            <button key={item.id} className={view === item.id ? "active" : ""} onClick={() => setView(item.id)}>
              <span>{item.icon}</span>{item.label}
              {item.id === "home" && approvals.length > 0 && <i>{approvals.length}</i>}
            </button>
          ))}
        </nav>
      )}
    </main>
  );
}
