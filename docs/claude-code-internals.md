# Claude Code CLI internals — background agents / "Agent View"

Reverse-engineered notes on how Claude Code manages **background sessions** (the `claude agents` / "Agent View" screen, internally **"FleetView"**) as of **Claude Code v2.1.201**. These are the facts an external frontend (e.g. an Emacs client) needs. Everything here was derived by reading `~/.claude`, the official docs, and the compiled CLI binary.

> ⚠️ **Stability**: file formats under `~/.claude` are *internal* to Claude Code and Anthropic explicitly warns they can change between releases. Pin behavior to the CLI version (`claude --version`) and keep a fallback path.

---

## 0. Two different features called "agents" — don't conflate them

|               | **Agent View / background sessions** ← *this doc*                     | **Agent teams** (experimental)           |
| ------------- | --------------------------------------------------------------------- | ---------------------------------------- |
| Enable        | `claude agents`, `claude --bg`, `/background` (default on, v2.1.139+) | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` |
| Coordination  | per-user **supervisor daemon + Unix socket**                          | **tmux panes/windows + JSON files**      |
| Internal name | **FleetView**                                                         | teams                                    |
| Storage       | `~/.claude/{daemon,jobs,sessions}`                                    | `~/.claude/teams`, `~/.claude/tasks`     |
| Model         | flat list of independent sessions                                     | lead + teammates, inboxes, task graph    |

Also distinct: **Task-tool subagents** (sidechains spawned inside one session) live at `projects/<enc-cwd>/<sessionId>/subagents/agent-*.jsonl` and are *not* daemon-managed. A background agent ⇔ it has a `jobs/<id>/state.json`.

---

## 1. Architecture

- A **per-user supervisor** ("daemon") owns all background sessions. It is **transient**: spawned on demand by the first `claude --bg` / `claude agents`, and self-exits after ~5 s idle with no clients.
- It keeps a **pre-warmed spare worker** hot so dispatches start instantly. A spare shows up as a `jobs/<id>/` dir with **no `state.json`** plus a live `bg` session with no matching job — it is correctly invisible in listings.
- Each background session is a full headless `claude` process whose **PTY is owned by the supervisor**. That is why *detach never stops a session*: you are just closing a view of a PTY the daemon holds.
- Two IDs key everything: the full **`sessionId`** (UUID) and its 8-hex prefix used as **`jobId` / `short`** (`jobId == sessionId[:8]`).

---

## 2. On-disk layout (`~/.claude/`, or `$CLAUDE_CONFIG_DIR`)

| Path                                   | Contents                                                          |
| -------------------------------------- | ----------------------------------------------------------------- |
| `daemon.lock`                          | JSON: pid/version/socket-owner of the current daemon              |
| `daemon.status.json`                   | supervisor heartbeat + lightweight workers mirror                 |
| `daemon.log`                           | supervisor + worker lifecycle log (text)                          |
| `daemon/roster.json`                   | **authoritative** live-worker registry (keyed by jobId)           |
| `daemon/control.key`                   | 32-char shared secret for the control socket                      |
| `sessions/<pid>.json`                  | one file **per live process** (bg + interactive), keyed by OS PID |
| `jobs/<jobId>/state.json`              | per-job state shown in Agent View                                 |
| `jobs/<jobId>/timeline.jsonl`          | append-only human-facing state transitions                        |
| `jobs/pins.json`                       | array of pinned jobIds                                            |
| `projects/<enc-cwd>/<sessionId>.jsonl` | full conversation transcript                                      |
| `history.jsonl`                        | global prompt history (all sessions)                              |

**cwd encoding** for `projects/`: replace every `/` **and** `.` with `-` (`/home/x/.dotfiles` → `-home-x--dotfiles`).

**Live socket tree** (created on daemon start, torn down on exit): `/tmp/cc-daemon-<uid>/<hash>/` where `hash = sha256("<configDir>")[:8]`
(verified: `sha256("/home/emlautarom1/.claude")[:8] == 84feb6af`). Contains `control.sock` (daemon endpoint), `rv/<jobId>.sock` (rendezvous), `pty/<jobId>.sock` (terminal stream), and `spare/` pre-warmed PTYs.

---

## 3. Key schemas (real examples, secrets redacted)

### `sessions/<pid>.json` — per-process liveness + live status
Named by OS PID. Carries the **live** status; `state`/`detail`/`tempo` are `null` here (they live in the job file).
```json
{
  "pid": 136334, "kind": "bg", "jobId": "07ad8f70",
  "sessionId": "07ad8f70-9188-46f6-adee-52a955591e5a",
  "cwd": "/home/…/binser", "name": "project exploration",
  "startedAt": 1783807855539, "procStart": "325364",
  "status": "waiting", "waitingFor": "permission prompt",
  "state": null, "detail": null, "tempo": null,
  "updatedAt": 1783809210301, "statusUpdatedAt": 1783809210301,
  "version": "2.1.201", "entrypoint": "cli", "peerProtocol": 1, "agent": null
}
```
- `kind`: `"bg"` (background) or `"interactive"`. Interactive sessions have **no `jobId`**.
- `status`: `"idle"` | `"busy"` | `"waiting"`. `waitingFor` set only when `waiting` (e.g. `"permission prompt"`, `"input needed"`).
- `procStart`: process start-time jiffies from `/proc/<pid>/stat` (field 22) — used to defeat PID reuse.

### `jobs/<jobId>/state.json` — per-job state (rich)
```json
{
  "state": "done", "tempo": "active",
  "detail": "Ask me a question using the Claude Code CLI harness about this project",
  "output": { "result": "…final summarized answer…" },
  "inFlight": { "tasks": 0, "queued": 0, "kinds": [] },
  "tokens": 2425, "children": null,
  "sessionId": "07ad8f70-…", "resumeSessionId": "07ad8f70-…",
  "cwd": "/home/…/binser", "daemonShort": "07ad8f70",
  "template": "bg", "intent": "Explore what this project…",
  "respawnFlags": ["--effort","xhigh","--permission-mode","bypassPermissions"],
  "linkScanPath": "…/projects/<enc-cwd>/<sessionId>.jsonl", "linkScanOffset": 60878,
  "createdAt": "2026-07-11T20:13:43.333Z",
  "updatedAt": "2026-07-11T22:33:20.149Z",
  "firstTerminalAt": "2026-07-11T20:14:21.912Z"
}
```
- `state` (persisted): `working` | `done` | `failed` | `stopped`. **Do not display this verbatim** — the real UI status is *derived* (see §5).
- `tempo`: `idle` | `active` | `blocked` — activity cadence; critical to derivation.
- `detail`: live status line; `output.result`: final answer summary.
- `children`: e.g. `[{"id":"1","href":"https://github.com/…/pull/1","kind":"pr"}]` → the `#1` PR badge in the UI.
- `linkScanPath`: back-pointer to the transcript (`agents --json` never reads it).

### `daemon/roster.json` — live worker registry (optional for a frontend)
Keyed by jobId; per worker: `pid`, `procStart`, `sessionId`, `rendezvousSock`, `ptySock`, `cwd`, `startedAt`, `decModes`, `cols`/`rows`, `rvAuth`, `ptyAuth`, and a `dispatch` block (`source: slash|spare|shell`, `launch:{mode:"prompt",args}`). Only unique value to a frontend: the daemon's authoritative alive-set — which is reconstructable from live `sessions/*.json` (see the algorithm doc).

### `jobs/<jobId>/timeline.jsonl` — state transitions
```json
{"at":"…","state":"working","detail":"Summarize what this repo contains","text":""}
{"at":"…","state":"done","detail":"summarized dotfiles repo…","text":"…full final assistant text…"}
```

### Transcript `projects/<enc-cwd>/<sessionId>.jsonl`
Append-only, messages linked via `parentUuid`→`uuid`. Line `type`s include `user`, `assistant` (content = thinking/text/tool_use), tool results (as `user` lines with `toolUseResult`), `system` (`away_summary` = "while you were away"), `ai-title` (session title), `last-prompt` (resume leaf), `mode`/`permission-mode`.

---

## 4. IPC (only needed for reply-without-attach / native attach)

- Transport: Unix **stream** sockets (no TCP/HTTP).
- Control endpoint: `/tmp/cc-daemon-<uid>/<sha256(configDir)[:8]>/control.sock`.
- Auth: `daemon/control.key` (shared secret) for the control socket; per-worker `rvAuth`/`ptyAuth` for `rv/`/`pty/` sockets. Protocol version `proto: 1`.
- The CLI's own listing does one `op:"list"` round-trip, and falls back to reading `roster.json` if the socket is unreachable (fast-fail on `ENOENT`).
  A **wedged** daemon (socket present, unresponsive) causes a **5 s timeout** — the one pathological stall a file-based frontend avoids entirely.
- Exact wire framing of `proto 1` was not captured; the persisted `dispatch` block is the strongest evidence of the launch-request schema.

---

## 5. State derivation (the important part)

The persisted `state.json.state` is **not** the displayed status. The CLI derives it from three inputs joined by jobId: `state.json.state`, `state.json.tempo`, and the live session's `status` (+ `waitingFor`). Observed reference logic:

```
derive(state, tempo, status, job):
  if status == "busy":                      return "working"    # live process busy wins
  if state ∈ {done,failed,stopped} and tempo != "active"
       and not (state=="done" and routine?(job)):
       return {done→done, failed→failed, stopped→stopped}[state]
  if tempo == "blocked" or status == "waiting":
       return "blocked"
  return "working"
```
`routine?(job)` ≈ `job.routine || job.selfWake==true || "session_cron" ∈ job.inFlight.kinds`.

**Why the live `status` is essential** (all three below have `state:"done"` on disk):

| jobId    | state | tempo  | live status | → derived   | UI group    |
| -------- | ----- | ------ | ----------- | ----------- | ----------- |
| 07ad8f70 | done  | active | waiting     | **blocked** | Needs input |
| ffb221f7 | done  | active | busy        | **working** | Working     |
| 91e5927d | done  | idle   | idle        | **done**    | Completed   |

**Staleness reconciliation** (applied *before* derive): a non-terminal job that is (a) not alive and (b) older than 5 s is rewritten — `state:"blocked"` → `blocked`, otherwise → `failed`. This is what stops dead jobs from showing "working" forever.

**Enum vocabularies** (three, keep them straight):
- UI: Working / Needs input / Idle / Completed / Failed / Stopped
- `agents --json` `state`: `working` / `blocked` / `done` / `failed` / `stopped`
- file `status`: `idle` / `busy` / `waiting`; file `state`: `working` / `done` / `failed` / `stopped`

---

## 6. `claude agents --json` — what it is (and its limits)

Builds output from three parallel sources — `sessions/<pid>.json` (live, PID-checked), `jobs/<id>/state.json`, and the socket `list` (fallback `roster.json`) — via **two emit loops**:
- **Loop 1**: background jobs → emitted **with `id` and derived `state`**.
- **Loop 2**: live *interactive* sessions → emitted **without `id`/`state`**.

So `--json` count = background jobs + live interactive sessions (that's the "8 shown, 5 with id" discrepancy vs the TUI, which lists only the 5 background jobs). `--all` only relaxes loop-1's filter to also include terminal jobs.

It is a **lossy projection**: fields are `pid,id,cwd,kind,startedAt,sessionId, name,status,waitingFor,state`. It **omits** `detail`, `output.result`, `tempo`, `children`, `tokens`, and every timestamp except `startedAt` — i.e. exactly the fields a rich UI needs. Latency is dominated by **Bun cold-start of the 251 MB single-file executable**, not the listing work. ⇒ Read the files directly.

---

## 7. Documented CLI surface (version-stable control plane)

| Command                                                                                | Purpose                                                   |
| -------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| `claude agents [--cwd P] [--json] [--all]`                                             | open Agent View / print JSON                              |
| `claude attach <id>`                                                                   | attach in this terminal (host in a PTY buffer)            |
| `claude logs <id>`                                                                     | print recent output                                       |
| `claude stop <id>` / `claude kill <id>`                                                | stop a session                                            |
| `claude respawn <id>` / `--all`                                                        | restart, conversation intact                              |
| `claude rm <id>`                                                                       | remove from list (transcript kept, resumable)             |
| `claude daemon status`                                                                 | print supervisor state, version, socket dir, worker count |
| `claude daemon stop [--any] [--keep-workers]`                                          | stop supervisor                                           |
| `claude --bg "<prompt>"` (`--name`,`--agent`,`--model`,`--effort`,`--permission-mode`) | dispatch                                                  |
| `claude --bg --exec 'pytest -x'`                                                       | PTY-backed shell job row                                  |
| `claude --resume <id>` / `--continue` / `--fork-session` / `--session-id <uuid>`       | resume model                                              |

**Gaps** (would need socket RE): no `claude reply <id>` command — reply via transient `attach` or `-p --resume`; the `--input-format stream-json` *input* schema is undocumented.

Relevant env: `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` (kill switch), `CLAUDE_CONFIG_DIR` (relocates storage → changes the socket hash), `CLAUDE_CODE_DEBUG_LOGS_DIR` (default `~/.claude/debug/<session-id>.txt`). Notification/SessionEnd **hooks** fire on needs-input/complete/fail and receive `transcript_path`.
