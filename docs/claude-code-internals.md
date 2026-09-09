# Claude Code CLI internals — background agents / "Agent View"

Reverse-engineered notes on how Claude Code manages **background sessions** (the `claude agents` / "Agent View" screen, internally **"FleetView"**) as of **Claude Code v2.1.265**. These are the facts an external frontend (e.g. an Emacs client) needs. Everything here was derived by reading `~/.claude`, the official docs, and the compiled CLI binary.

> ⚠️ **Stability**: file formats under `~/.claude` are *internal* to Claude Code and Anthropic explicitly warns they can change between releases. Pin behavior to the CLI version (`claude --version`) and keep a fallback path.

---

## 0. Two different features called "agents" — don't conflate them

|               | **Agent View / background sessions** ← *this doc*                     | **Agent teams** (experimental)                          |
| ------------- | --------------------------------------------------------------------- | ------------------------------------------------------- |
| Enable        | `claude agents`, `claude --bg`, `/background` (default on)            | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, `--agent-teams` |
| Coordination  | per-user **supervisor daemon + Unix socket**                          | **tmux panes/windows + JSON files**                     |
| Internal name | **FleetView**                                                         | teams                                                   |
| Storage       | `~/.claude/{daemon,jobs,sessions}`                                    | `~/.claude/teams`, `~/.claude/tasks`                    |
| Model         | flat list of independent sessions                                     | lead + teammates, inboxes, task graph                   |

Agent View is switched off by the **`disableAgentView` setting** or `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`; with either in force `claude agents`, `--bg`, `/background` and `claude daemon` all refuse with `'<name>' is disabled by the 'disableAgentView' setting` (or `… by CLAUDE_CODE_DISABLE_AGENT_VIEW`) and no daemon is ever spawned.

Also distinct: **Task-tool subagents** (sidechains spawned inside one session) live at `projects/<enc-cwd>/<sessionId>/subagents/agent-*.jsonl` and are *not* daemon-managed. A background agent ⇔ it has a `jobs/<id>/state.json`.

---

## 1. Architecture

- A **per-user supervisor** ("daemon") owns all background sessions. It is **transient**: spawned on demand by the first `claude --bg` / `claude agents`, and self-exits on an idle timer — **5 s** with no clients once it has served one, **50 s** before the first client ever connects.
- It keeps a **pre-warmed spare worker** hot so dispatches start instantly. A spare shows up as a `jobs/<id>/` dir with **no `state.json`** plus a live session record carrying `spare: true` and no `jobId` — it is correctly invisible in listings.
- Each background session is a full headless `claude` process whose **PTY is owned by the supervisor**. That is why *detach never stops a session*: you are just closing a view of a PTY the daemon holds.
- Two IDs key everything: the full **`sessionId`** (UUID) and its 8-hex prefix used as **`jobId` / `short` / `daemonShort`** (`daemonShort == sessionId.slice(0,8)`).
- The supervisor watches its own binary and self-restarts onto a newer build, deferring while any worker reports a mid-turn session (capped at 30 min) and refusing outright to downgrade.

---

## 2. On-disk layout (`~/.claude/`, or `$CLAUDE_CONFIG_DIR`)

| Path                                   | Contents                                                             |
| -------------------------------------- | -------------------------------------------------------------------- |
| `daemon.lock`                          | JSON: pid/version/procStart, log paths, `origin`, `spawnedBy`        |
| `daemon.status.json`                   | supervisor heartbeat + lightweight workers mirror                    |
| `daemon.log`                           | supervisor + worker lifecycle log (text; rotates to `daemon.log.1`)  |
| `daemon/roster.json`                   | **authoritative** live-worker registry (keyed by jobId)              |
| `daemon/control.key`                   | 32-char shared secret for the control socket                         |
| `daemon/pipe.key`                      | 16-hex nonce naming the Windows control pipe                         |
| `daemon/auth/<key>.json`, `<key>.tokens.json` | auth material and claim tokens                                |
| `daemon/dispatch/`, `dispatch/rejected/` | dispatch requests staged on disk                                   |
| `daemon/attach-journal`                | attach/detach journal                                                |
| `daemon/host-managed/`                 | tombstones for host-managed providers                                |
| `daemon/pty-pids/<jobId>.pid`          | PTY host pid, plus sibling `.err` / `.late` / `.exec-exit` files     |
| `sessions/<pid>.json`                  | one file **per live process** (bg + interactive), keyed by OS PID    |
| `sessions/<pid>.<sha256>.key`          | `peerToken` authorizing that pid's messaging socket                  |
| `jobs/<jobId>/state.json`              | per-job state shown in Agent View                                    |
| `jobs/<jobId>/timeline.jsonl`          | append-only human-facing state transitions                           |
| `jobs/<jobId>/tmp/`                    | scratch for the job's own writes                                     |
| `jobs/pins.json`                       | array of pinned jobIds                                               |
| `projects/<enc-cwd>/<sessionId>.jsonl` | full conversation transcript                                         |
| `history.jsonl`                        | global prompt history (all sessions)                                 |

**cwd encoding** for `projects/`: replace every `/` **and** `.` with `-` (`/home/x/.dotfiles` → `-home-x--dotfiles`).

**Control socket tree** (created on daemon start, torn down on exit): `/tmp/cc-daemon-<uid>/<hash>/` where `hash = sha256(resolve(configDir))[:8]`
(verified: `sha256("/home/emlautarom1/.claude")[:8] == 84feb6af`). Contains `control.sock` (daemon endpoint), `rv/<jobId>.sock` (rendezvous), `pty/<jobId>.sock` (terminal stream), and `spare/<id>.pty.sock` + `spare/<id>.claim.sock` for pre-warmed PTYs. On Windows the whole tree becomes named pipes, `\\.\pipe\cc-daemon-<pipe.key nonce>-<name>`.

**Messaging sockets are a separate tree**, one per live process rather than per job: `$XDG_RUNTIME_DIR/cc-socks/<pid>.sock` (i.e. `/run/user/<uid>/cc-socks/…`), falling back to `/tmp/cc-socks`, `/private/tmp/cc-socks` or the Termux tmpdir. The path is recorded as `messagingSocketPath` on the session record and authorized by the matching `sessions/<pid>.<sha256>.key`. This is the channel session-to-session messaging uses; it is not the daemon control plane.

---

## 3. Key schemas (real examples, secrets redacted)

### `sessions/<pid>.json` — per-process liveness + live status
Named by OS PID. The reader accepts `^\d+\.json$` only, so the `.key` siblings are never mistaken for records.
```json
{
  "pid": 1278303,
  "sessionId": "69e7aa47-e427-45c3-ae28-a8519f68c0ac",
  "cwd": "/home/…/pluto/.claude/worktrees/fluffy-giggling-beaver",
  "startedAt": 1788908489325, "procStart": "12966830",
  "version": "2.1.265", "peerProtocol": 1,
  "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
  "kind": "interactive", "entrypoint": "cli",
  "pidDomain": "linux:1948999a…:pid:[4026531836]",
  "messagingSocketPath": "/run/user/1000/cc-socks/1278303.sock",
  "name": "tighten-eth2api-types", "nameSource": "auto",
  "nameSince": 1788908489458,
  "updatedAt": 1788915778499,
  "status": "idle", "statusUpdatedAt": 1788915778499
}
```
- `kind`: `"interactive"` | `"bg"` | `"daemon"` | `"daemon-worker"`. Interactive sessions have **no `jobId`**; so does a `bg` spare, which carries `spare: true` instead.
- `status`: `"idle"` | `"busy"` | `"waiting"` | `"shell"` (the last for a `--bg --exec` PTY job). `waitingFor` set only when `waiting` (e.g. `"permission prompt"`, `"input needed"`).
- `procStart`: process start-time jiffies from `/proc/<pid>/stat` (field 22); `procStartFt` is the Windows filetime equivalent. `pidDomain` (`linux:<machine-id>:<pid-namespace>`) keeps PIDs from separate containers apart. Together they defeat PID reuse.
- `nameSource`: `derived` (directory-derived placeholder) | `auto` | `user` | `peer` | `hook` | `collision`; `formerNames` keeps the earlier ones.
- A bg worker also carries `jobId`, `parkedJobId`, `agent`, `logPath`, and mirrors `state`/`detail`/`tempo`/`needs` from the job file.

### `jobs/<jobId>/state.json` — per-job state (rich)
```json
{
  "state": "blocked", "tempo": "blocked",
  "detail": "implementation complete, all tests green; awaiting integration decision",
  "needs": "run `make integration` or commit on a branch?",
  "suggestedReply": "commit this on a branch",
  "output": { "result": "…final summarized answer…" },
  "inFlight": { "tasks": 0, "queued": 0, "kinds": [] },
  "fan": [ { "id": "a9a780c7…", "kind": "agent", "label": "Implement MCP support per plan",
             "startedAt": 1785188470204, "doneAt": 1785189705416 } ],
  "tokens": 382595, "children": null,
  "name": "Add MCP support with Emacs eval tool", "nameSource": "auto",
  "sessionId": "0ce24144-…", "resumeSessionId": "0ce24144-…",
  "cwd": "/home/…/claude-code.el", "daemonShort": "0ce24144",
  "template": "bg", "backend": "daemon", "cliVersion": "2.1.218",
  "intent": "I would like to add MCP support for this package…",
  "respawnFlags": ["--reply-on-resume","--model","opus[1m]","--permission-mode","plan"],
  "bgIsolation": "none", "providerEnv": {},
  "linkScanPath": "…/projects/<enc-cwd>/<sessionId>.jsonl", "linkScanOffset": 1913544,
  "createdAt": "2026-07-27T20:10:13.032Z",
  "updatedAt": "2026-07-27T22:11:59.464Z",
  "firstTerminalAt": null, "lastTerminalAt": null
}
```
- `state` (persisted): `working` | `blocked` | `done` | `failed` | `stopped`. **Do not display this verbatim** — the real UI status is *derived* (see §5).
- `tempo`: `idle` | `active` | `blocked` — activity cadence; critical to derivation.
- `detail`: live status line. `needs`: the question holding the job. `output.result`: final answer summary.
- `fan`: the job's own sub-work (`kind: agent | shell | …`), each entry `doneAt`-stamped when it finishes.
- `children`: e.g. `[{"id":"1","href":"https://github.com/…/pull/1","kind":"pr"}]` → the `#1` PR badge in the UI.
- `linkScanPath`: back-pointer to the transcript (`agents --json` never reads it).
- `template`: `bg` for a prompt job, `exec` for a `--bg --exec` shell job.

### `daemon/roster.json` — live worker registry (optional for a frontend)
`{proto, supervisorPid, updatedAt, workers}`, `workers` keyed by jobId. Per worker: `pid`, `procStart`, `sessionId`, `rendezvousSock`, `ptySock`, `messagingSock`, `cwd`, `worktreePath`, `startedAt`, `attempt`, `cliVersion`, `decModes`, `rvAuth`, `ptyAuth`, `replPid`, `pendingRespawn`, and a `dispatch` block: `{proto, short, nonce, sessionId, createdAt, source, cwd, launch, env, isolation, respawnFlags, seed, cols, rows}` where `source ∈ shell | slash | fleet | spare | respawn` and `launch` is one of `{mode:"prompt", args}`, `{mode:"resume", sessionId, transcriptPath, fork, flagArgs}`, `{mode:"exec", cmd, args}`. Only unique value to a frontend: the daemon's authoritative alive-set — which is reconstructable from live `sessions/*.json` (see the algorithm doc).

### `jobs/<jobId>/timeline.jsonl` — state transitions
```json
{"at":"…","state":"working","detail":"Summarize what this repo contains","text":""}
{"at":"…","state":"done","detail":"summarized dotfiles repo…","text":"…full final assistant text…"}
```

### Transcript `projects/<enc-cwd>/<sessionId>.jsonl`
Append-only, messages linked via `parentUuid`→`uuid`. The line types that carry a top-level `timestamp` are `user`, `assistant` (content = thinking/text/tool_use), tool results (as `user` lines with `toolUseResult`), `attachment`, `system` (`away_summary` = "while you were away"), `queue-operation`, `pr-link` and `file-history-delta`. Everything else is untimestamped metadata the CLI restamps as the session runs, most of it *last-wins*: `ai-title` (generated title), `custom-title` (`/rename` or `--name`), `last-prompt` (resume leaf), `agent-name`, `mode`, `permission-mode`, `atis-latch`, `cost-state`, `worktree-state`, `relocated` (the cwd the transcript is filed under), `file-history-snapshot`.

---

## 4. IPC (only needed for reply-without-attach / native attach)

- Transport: Unix **stream** sockets (no TCP/HTTP), or named pipes on Windows.
- Control endpoint: `/tmp/cc-daemon-<uid>/<sha256(resolve(configDir))[:8]>/control.sock`.
- Auth: `daemon/control.key` (shared secret) for the control socket; per-worker `rvAuth`/`ptyAuth` for `rv/`/`pty/` sockets. Protocol version `proto: 1`.
- **Wire framing**: newline-delimited JSON, one request and one response per connection. The client connects, writes `JSON.stringify(request) + "\n"`, reads up to the first `\n`, parses it and closes. Requests carry `{proto, op, …}`; responses carry `{ok, op, …}` or `{ok:false, code, error}` with `code ∈ ENOCONN | ETIMEOUT | EUNKNOWN`.
- **Ops**: `ping`, `list`, `has`, `nudge`, `yield`, `lease`, `leases`, `shutdown`, `await-ack`. `list` answers `{ok:true, op:"list", jobs:[…roster records…]}`, marking a worker being torn down with `dying:true`.
- The CLI's own listing does one `op:"list"` round-trip, and falls back to reading `roster.json` if the socket is unreachable (fast-fail on `ENOENT`). The client's default timeout is **5 s**, so a **wedged** daemon (socket present, unresponsive) stalls that long — the one pathological stall a file-based frontend avoids entirely. `claude daemon status` passes `timeoutMs: 1000` instead.

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
`routine?(job)` ≈ `job.routine !== undefined || job.selfWake == true || "session_cron" ∈ job.inFlight.kinds || (job.intent ?? job.initialPrompt) starts with "/loop"`.

**Why the live `status` is essential** (all three below have `state:"done"` on disk):

| jobId    | state | tempo  | live status | → derived   | UI group    |
| -------- | ----- | ------ | ----------- | ----------- | ----------- |
| 07ad8f70 | done  | active | waiting     | **blocked** | Needs input |
| ffb221f7 | done  | active | busy        | **working** | Working     |
| 91e5927d | done  | idle   | idle        | **done**    | Completed   |

**Staleness reconciliation** (applied *before* derive): a non-terminal job that is (a) not alive and (b) older than 5 s is rewritten — `state:"blocked"` → `blocked`, otherwise → `failed`. This is what stops dead jobs from showing "working" forever.

**Enum vocabularies** (three, keep them straight):
- UI groups (four, in display order): Ready for review / Needs input / Working / Completed — a failed or stopped job lands in *Completed*
- `agents --json` `state`: `working` / `blocked` / `done` / `failed` / `stopped`
- file `status`: `idle` / `busy` / `waiting` / `shell`; file `state`: `working` / `blocked` / `done` / `failed` / `stopped`

---

## 6. `claude agents --json` — what it is (and its limits)

Builds output from three parallel sources — `sessions/<pid>.json` (live, PID-checked), `jobs/<id>/state.json`, and the socket `list` (fallback `roster.json`) — via **two emit loops**:
- **Loop 1**: background jobs → emitted **with `id` and derived `state`**, `kind` always `"background"`. `pid` is present only when a live process backs the job, and the fields that would come from it (`cwd`, `startedAt`, `sessionId`, `name`, `status`) fall back to the job file.
- **Loop 2**: live sessions with no job of their own → emitted **without `id`/`state`**, `kind` mapped `bg → "background"`, else `"interactive"`. A record with a `parkedJobId` is skipped.

So `--json` count = background jobs + live jobless sessions (that's the "8 shown, 5 with id" discrepancy vs the TUI, which lists only the 5 background jobs). Without `--all`, loop 1 drops a job with no live process unless its derived state is `working` or `blocked`; `--all` relaxes that to include terminal jobs. `--cwd P` keeps only rows whose cwd is at or under `P`. Rows are sorted by `startedAt`, ascending.

It is a **lossy projection**: fields are `pid,id,cwd,kind,startedAt,sessionId,name,status,waitingFor,state`. `status` is flattened on the way out — `idle` and `waiting` pass through and **everything else reports `busy`**, so a `shell` job is indistinguishable from a working one. It **omits** `detail`, `needs`, `output.result`, `tempo`, `children`, `fan`, `tokens`, and every timestamp except `startedAt` — i.e. exactly the fields a rich UI needs. Latency is dominated by cold-starting the 216 MB single-file executable, not the listing work: a local-only subcommand costs ~90–180 ms before it does anything. ⇒ Read the files directly.

---

## 7. Documented CLI surface (version-stable control plane)

| Command                                                                                | Purpose                                                          |
| -------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `claude agents [--cwd P] [--json] [--all]`                                             | open Agent View / print JSON                                     |
| `claude attach <id>`                                                                   | attach in this terminal (host in a PTY buffer)                   |
| `claude logs <id>`                                                                     | print recent output                                              |
| `claude stop <id>` / `claude kill <id>`                                                | stop a session; conversation kept and re-attachable              |
| `claude respawn <id>` / `--all`                                                        | restart on the current CLI version, conversation intact          |
| `claude rm <id> [--discard-unpushed <commit>@<worktree-id>]`                           | delete a session **and its worktree when that is safe**          |
| `claude daemon status`                                                                 | print supervisor state, version, socket dir, worker count        |
| `claude daemon stop [--any] [--keep-workers]`                                          | stop supervisor                                                  |
| `claude --bg "<prompt>"` (`--name`,`--agent`,`--model`,`--effort`,`--permission-mode`) | dispatch                                                         |
| `claude --bg --exec 'pytest -x'`                                                       | PTY-backed shell job row (`--exec` is undocumented in `--help`)  |
| `claude --resume <id>` / `--continue` / `--fork-session` / `--session-id <uuid>`       | resume model                                                     |

`claude rm` is the one to read twice: it removes the worktree along with the session, and refuses (printing `kept <id> — …`) when the worktree holds unpushed commits or another session records it. Overriding it is deliberately awkward — `--discard-unpushed` only accepts the `<commit>@<worktree-id>` token that refusal printed, so the discard names the exact worktree state it was offered for.

**Gaps** (would need socket RE): no `claude reply <id>` command — reply via transient `attach` or `-p --resume`; the `--input-format stream-json` *input* schema is undocumented.

Relevant env: `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` (kill switch, mirroring the `disableAgentView` setting), `CLAUDE_CONFIG_DIR` (relocates storage → changes the socket hash), `CLAUDE_CODE_DEBUG_LOGS_DIR` (default `<configDir>/debug/<session-id>.txt`), `CLAUDE_JOB_DIR` (names the job dir a worker writes). Notification/SessionEnd **hooks** fire on needs-input/complete/fail and receive `transcript_path`.
