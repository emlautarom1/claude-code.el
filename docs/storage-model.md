# Storage model

> ⚠️ **These are Claude Code internals and are version-volatile.** Everything here describes undocumented on-disk formats under the [config dir](glossary.md) that Anthropic may change between releases (verified against CLI **v2.1.265**). In the code, **all** of this knowledge is confined to the *Storage adapter* section of `claude-code.el` (`claude-code--encode-cwd`, `claude-code--live-status-table`, `claude-code--project-transcripts` and their helpers). The rest of the package works only with `claude-code-session` structs. When Claude's layout changes, fix that one section.

## Config directory

`~/.claude`, or `$CLAUDE_CONFIG_DIR` when set. Resolved once into `claude-code-config-dir`.

## Running instances — `sessions/<pid>.json`

Claude writes one JSON file per running process, named by OS PID. The fields this package reads:

| Field        | Meaning                                                    |
| ------------ | ---------------------------------------------------------- |
| `sessionId`  | the session UUID — the join key to a transcript            |
| `cwd`        | the real, absolute working directory (never encoded)       |
| `status`     | `idle` \| `busy` \| `waiting` \| `shell` (absent early on) |
| `waitingFor` | set only while `waiting`, e.g. `"permission prompt"`       |
| `pid`        | OS PID (also the filename)                                 |

`claude-code--live-status-table` parses every such file into a hash keyed by `sessionId`. It matches `<pid>.json` and nothing else, which is the CLI's own filter too: a companion `sessions/<pid>.<sha256>.key` holds the `peerToken` authorizing that process's messaging socket and carries no session id. Parsing is pure — a missing `status` yields nil, and process liveness is decided separately (`claude-code--pid-live-p`). This package treats a session as *alive* only when it manages the instance itself, so this table is used to read a managed session's status and to flag [external](glossary.md) sessions — not as the source of aliveness.

`shell` is the status of a PTY-backed `claude --bg --exec` job, never an instance this package manages, so the three the [glossary](glossary.md) names are the ones a view can reach. `claude-code--status-display` renders an unrecognised value as `unknown (VALUE)` rather than guessing, which is what keeps a vocabulary Anthropic extends from reading as the wrong status.

A session's display name comes entirely from the transcript (see [Transcripts](#transcripts--projectsencoded-cwdsessionidjsonl) and `claude-code--session-display-name`); a `/rename` is reflected there through its `custom-title`. Claude writes a `name` here too, qualified by `nameSource`: `derived` marks the directory-derived placeholder (`{"name":"proj-f8","nameSource":"derived"}`), while `auto`, `user`, `peer`, `hook` and `collision` mark real ones. Reading it would still be wrong, because this file exists only while the process does — it names live sessions and nothing else, and a view has to name dead ones from the same source as live ones. That source is the transcript.

Liveness is a plain per-PID `process-attributes` existence check. Claude records two guards against a reused PID — `procStart` (start-time jiffies) and `pidDomain` (`linux:<machine-id>:<pid-namespace>`, which also keeps PIDs from separate containers apart) — and this package consults **neither**. A stale `sessions/<pid>.json` left by a crash whose PID was reused could therefore mis-flag a dead session as external, accepted as a simplicity trade-off since PID reuse is vanishingly unlikely (`pid_max` defaults to 4194304).

### Not every process here is a terminal session

`kind` names what the process is: `interactive`, `bg` for a background agent, and `daemon` / `daemon-worker` for Claude's background-agent supervisor and the workers it owns. A pre-warmed spare carries `spare: true` and no `jobId`. The table takes them all, since it keys on `sessionId` and reads only the fields above.

This is not the inert detail it looks like. A `claude --bg` session stamps its transcript `entrypoint: "cli"`, exactly as a terminal session does, so [the entrypoint filter](#the-entrypoint-stamp) cannot tell the two apart and a project's view **lists background agents alongside the user's own sessions** — [external](glossary.md) while the worker runs, dead once it stops. That is the right answer for a session the user dispatched and may want to read or resume, and it costs no knowledge of the supervisor to reach: a live process with a matching transcript is all *external* means.

Deletion is the one asymmetry. `claude-code-delete` removes the transcript and nothing else, while Claude keeps a background agent's own state under `jobs/<first 8 of sessionId>/` — so deleting one from Emacs leaves a row in `claude agents` whose conversation is gone. Removing that state is `claude rm`'s business, not this package's.

## Transcripts — `projects/<encoded-cwd>/<sessionId>.jsonl`

Append-only JSONL, one JSON object per line. This package reads **five** fields, all cached by file modification time in `claude-code--transcript-cache`. All but the [entrypoint](#the-entrypoint-stamp) are extracted by scanning **backward** from the end of the file (the values of interest sit near the tail):

- **Title** — a session's display title, resolved from two possible lines:
  - a user-set `{"type":"custom-title","customTitle":…}` line, which **takes precedence** when present, otherwise
  - the last `{"type":"ai-title","aiTitle":…}` line — Claude rewrites its generated title as the conversation evolves, so the *last* one wins.

  Both `/rename` and `claude --name=NAME` write a `custom-title`; the spawn flag writes it as the transcript's very first line, before any `ai-title` exists.
- **Entrypoint** — the `entrypoint` stamp deciding whether the session is listed at all. See [The entrypoint stamp](#the-entrypoint-stamp).
- **Last prompt** — the `{"type":"last-prompt","lastPrompt":…}` line (a preview of the opening prompt).
- **Worktree binding** — the `{"type":"worktree-state","worktreeSession":…}` line, read as `(:name :path :bound)` by `claude-code--read-worktree-binding`. See [Worktrees](#worktrees).
- **Last-active time** — the `timestamp` (ISO-8601 UTC, e.g. `2026-06-10T13:23:27.697Z`, parsed with `date-to-time`) of the **newest line that carries one**. It drives the view's *Active* column and default most-recent-first sort, and is surfaced on every session (alive, external, or dead — a dead session's transcript still exists on disk). The file's mtime is **not** used for this: only genuine conversation lines (`user`, `assistant`, `attachment`, `system`, `queue-operation`, `pr-link`, `file-history-delta`) carry a top-level `timestamp`; the CLI also appends *untimestamped* metadata lines (`last-prompt`, `mode`, `permission-mode`, `agent-name`, `ai-title`, `worktree-state`, `relocated`, `cost-state`, …) to dead transcripts long after the conversation ends — via the resume/session picker, mode toggles, and the background-agents daemon — which bumps the mtime by minutes to days without representing real activity. Scanning for the last real `timestamp` ignores those writes. Two traps the backward scan must avoid: `file-history-snapshot` metadata lines have no top-level `timestamp` but *embed* one in a nested value, so the scan parses each candidate line and validates the top-level key rather than trusting the `"timestamp"` substring that led it there; and the rare transcript with **no** timestamped line at all (tiny orphaned agent stubs) falls back to the file mtime.

Each scan finds its candidate lines with a **literal** `search-backward` and settles the match by parsing the line, never by a regexp that extracts the value. The literal is not what buys that: Emacs applies the same fast path to a metacharacter-free regexp, and the two measure alike (3.7 ms against 3.4 ms scanning the whole of the largest transcript here, 16.8 MB, for a needle it does not contain). What costs is capturing in the pattern — `"type":"custom-title","customTitle":"\\(.*\\)"` takes **78 ms** over that same buffer, 20× a scan that leaves the extracting to `json-parse-string`. The scan that finds nothing is the one that has to touch every byte, and 7% of real transcripts carry a `custom-title` line, so that scan reaches the front of the file almost every time; it is still not what the read costs. Reading all five fields out of that 16.8 MB transcript takes 38 ms, of which 36 ms is `insert-file-contents`, and a median 309 KB transcript reads in 1.2 ms.

A shell `tac | grep` pipeline is the alternative, and it loses on everything but the outliers: five passes over the median transcript cost 15 ms against Emacs's 1.2 ms, and over the whole corpus here (182 transcripts, 134 MB) 2.7 s against 384 ms. Only on the largest file does the pipeline come out ahead (26 ms against 38 ms), which is a tail two forks per field cannot pay for. Hence the in-process read plus the mtime cache. (Measured on Emacs 31.1.)

### The entrypoint stamp

Every conversation line carries a top-level `entrypoint` naming the surface the process that wrote it belongs to. The vocabulary is wide and Anthropic keeps adding to it; v2.1.265's full table is

```
cli  mcp  bench  local-agent  local_agent  sdk-cli  sdk-ts  sdk-py
claude-vscode  claude-desktop  claude-desktop-3p  claude-security
claude-coworker  claude-coworker-terminal  claude-code-github-action
ssh-remote  remote  remote_baku  remote_cowork  remote_trigger
remote_cowork_trigger  remote_desktop  remote_mobile
claude_in_slack  claude-in-slack  claude-in-teams
```

and the CLI's own test for *a program is driving this* accepts exactly three of them:

```js
function RM(){let e=a.CLAUDE_CODE_ENTRYPOINT;return e==="sdk-ts"||e==="sdk-py"||e==="sdk-cli"}
```

`claude-code--program-entrypoints` is that set, and `claude-code--interactive-transcript-p` reports every transcript outside it as a person's. Naming the three rather than whitelisting `cli` is the point: most of the rest are a human at an IDE, a desktop, a phone or a chat client, and a `cli` whitelist would silently drop all of them along with whatever ships next. It is deliberately not a tight fit — `bench`, `mcp` and `local-agent` have no person behind them either, and the CLI groups `local-agent` with the SDK stamps elsewhere — but the residue is a handful of rows, where the whitelist's mistake is a session the user cannot find.

Two consequences worth stating plainly. `sdk-cli` marks *any* non-interactive run, so a `claude -p` the user typed themselves is filtered along with the fan-out's agents. And an **agent fan-out** — each agent a top-level session with its own transcript, 25+ of them from one `/code-review` — accumulates forever: Claude never deletes those transcripts and, once filtered, neither can this package.

The stamp is **per invocation, not per session**: each process stamps the lines *it* appends, so one transcript can carry several values. A `claude -p` session the user later resumed interactively reads `sdk-cli` at both ends with a run of `cli` in the middle. Hence the rule — a session is the user's if **any** stamp is outside the SDK set — and hence why reading only the first stamp, or only the last, would lose that session. A transcript with no stamp at all (one predating the field) is kept: absence is not evidence, and the failure worth avoiding is dropping a real session.

The scan runs **forward**, unlike every other field's — the stamp sits near the head, in practice within the first eight lines — and it parses each candidate line rather than trusting the literal that found it, because a nested `"entrypoint"` spells that literal exactly and only the top-level key may decide. A transcript the filter accepts stops at its first stamp; one it rejects has to reach the end, which is why the whole corpus here costs 25 ms against the 285 ms `insert-file-contents` spends on the same files. Every candidate is parsed, with no shortcut for a value that merely *reads* as a program's: such a shortcut is worth 15 ms of that total — 5% of the read it rides along with — and pays for it by not seeing a top-level stamp that follows a nested one on the same line, which is exactly the case that hides a session a person drove.

The stamp settles only the agent that gets a session of its own. The other kind — a `Task` sidechain inside one session — writes `projects/<encoded-cwd>/<sessionId>/subagents/agent-<hash>.jsonl`, a **subdirectory** of the project's transcript directory, with `"isSidechain":true` on every line. Sidechains outnumber real sessions here by roughly one to one. `claude-code--project-transcripts` matches `.jsonl` at one directory level, so they are already out of reach and need no stamp; making that listing recursive would put every one of them in the view.

## The cwd encoding (lossy — never invert)

A project's transcript directory name is its absolute working directory with **every `/` and `.` replaced by `-`** (after `directory-file-name`, so a trailing slash adds no trailing hyphen):

```
/home/me/Development/proj      ->  -home-me-Development-proj
/home/me/.dotfiles             ->  -home-me--dotfiles      (the "/." becomes "--")
```

The mapping is **not reversible** (`proj.el` and `proj-el` collide), so the code never decodes a directory name — a live session's real `cwd` is read from `sessions/*.json`. `claude-code--encode-cwd` implements the encoding, and `claude-code--project-transcripts` consumes it by matching encoded directory names rather than decoding the ones it finds.

## Worktrees

`claude --worktree [name]` runs a session in a git worktree under the project's `.claude/worktrees/<name>`. Its transcript starts out in an encoded directory prefixed by the parent project's encoding + `--claude-worktrees-`. `claude-code--project-transcripts` lists both the project's own directory and any directory matching that prefix, so worktree sessions appear under the parent project either way.

That prefixed name is also **exactly** what encoding the worktree's own path produces — `-home-me-proj--claude-worktrees-feat` is both the parent's worktree directory and `/home/me/proj/.claude/worktrees/feat`'s base directory. While the transcript sits there it belongs to two roots, and since a git worktree is its own `project.el` project, either of them can be the root a query or a spawn names. This is why nothing in the model may key a session's liveness on the root it was asked about (see the [session model](architecture.md#the-session-model)).

The token after that prefix decides **membership only** — which project's view lists the transcript. It is never turned back into a path or a name: the encoding is lossy, so a dot or `/` in the worktree name reads as a hyphen, and two names differing only in flattened characters share one transcript directory.

### The filing cwd — `relocated`

A transcript's directory is not fixed for the life of the session. Claude appends a `relocated` line naming the cwd it files the transcript under, and moves the file to match:

```json
{"type":"relocated","relocatedCwd":"/home/me/proj","sessionId":"…"}
```

It is a routine, repeating stamp — written into the same metadata block as `last-prompt` and `ai-title`, so a long session carries dozens — and the CLI resolves a transcript's cwd as the newest `relocatedCwd`, falling back to the `cwd` on the head line. **A live worktree session's transcript can therefore already sit in the parent project's directory while the session is still bound to its worktree**, its head line still naming the worktree it opened in. Once that happens the transcript belongs to the parent root **alone**: a view opened from inside the worktree lists nothing, while the parent's view lists the session and names the worktree from the binding below. Nothing here reads `relocated`; the file's actual location is what `claude-code--project-transcripts` walks, and the binding is what names the worktree.

### The binding — `worktree-state`

Which worktree a session *runs in* is recorded in the transcript body, not in the directory name. Claude writes a `worktree-state` line whenever that changes:

```json
{"type":"worktree-state","worktreeSession":{"originalCwd":"/home/me/proj","preEnterOriginalCwd":"/home/me/proj","worktreePath":"/home/me/proj/.claude/worktrees/feat","worktreeName":"feat","worktreeBranch":"worktree-feat","originalBranch":"main","originalHeadCommit":"…","sessionId":"…"},"sessionId":"…"}
```

and clears it to `"worktreeSession":null` when the session leaves. Two lines answer two questions, both found by one backward scan each: the **newest** `worktree-state` line says whether Claude still considers the session bound, and the newest line that carries a binding names the worktree — as the user wrote it, so `my.feat` survives where the directory token flattened it to `my-feat`. `claude-code--read-worktree-binding` returns both as `(:name :path :bound)`, and the *Worktree* column shows `:name`.

Leaving is not only an `ExitWorktree`: **a clean exit clears the binding too, even when the user answers "Keep worktree"**. Claude's own parting message says as much, printing `claude --worktree <name> --resume <session>` as the way back in. A hard kill writes nothing, so a killed session stays bound and Claude re-enters its worktree unaided.

The directory settles neither question. A session that left can still be filed under the worktree, and one Claude still holds can already be filed under the parent (see [the filing cwd](#the-filing-cwd--relocated)) — which is why both the binding and the name have to come from the body.

The name outlives the directory, so a session that *left* is only labelled while `:path` is still a directory (`claude-code--binding-worktree`): a worktree removed on exit — which is what Claude does to an unnamed session's clean worktree — leaves a session that now belongs to the parent tree. A session Claude still holds is labelled on Claude's word alone, without a stat, since clearing that binding is Claude's job on the next resume and not ours to anticipate.

`claude-code--resume-worktree` narrows the flag to the one case the CLI leaves to the caller — cleared binding, surviving worktree — and `claude-code-resume` passes it as `--worktree=NAME`. Three cases get no flag: a still-bound session, which Claude returns by itself; one whose worktree is gone, where the flag would build a fresh checkout instead of resuming in none; and a transcript predating the binding, whose flattened token is not a name that can be passed back.

The name must also **round-trip**. `--worktree=NAME` always resolves to `<root>/.claude/worktrees/NAME`, while `worktreeName` is only the recorded worktree's base name — Claude will enter a worktree anywhere (`EnterWorktree` on a `git worktree add` checkout, a `WorktreeCreate` hook's own location), and `enteredExisting` on the binding marks that it did. So the flag is withheld unless `:path` is exactly the path the flag would produce; otherwise resuming a worktree kept elsewhere would build an empty checkout beside the work rather than return to it. Comparing paths covers every such placement without reading `enteredExisting`, and it errs toward a plain resume in the parent tree.

## MCP configuration

The [MCP server](architecture.md#mcp-server) adds **nothing** to the on-disk layout under the config dir. Each spawned instance is wired to the server entirely through the command line: `claude` is passed `--mcp-config` with an inline JSON blob

```json
{"mcpServers":{"emacs":{"type":"http","url":"http://127.0.0.1:<port>/mcp/<sessionId>"}}}
```

(plus `--allowedTools` listing every registered tool when auto-approve is on). No `.mcp.json` is written and no user/project MCP config is touched — our server is *added alongside* whatever the user already has. Because the JSON is handed to `claude` execvp-style (Ghostel does not go through a shell), it needs no escaping.

The one piece of on-disk state the server *reads* is a running session's real cwd: `claude-code--session-cwd` takes it from the `sessions/<pid>.json` `cwd` field (the worktree directory for a worktree session), falling back to the launch-time registry root in the brief window before that file exists. This is a read through the existing storage adapter — no new format.

## Mapping an Emacs buffer to a session

When spawning, this package generates a UUID and passes it as `--session-id`, so a Ghostel buffer is bound to its `sessionId` up front — no polling or PID-matching needed. The UUID is internal and never shown to the user. The registry `claude-code--managed` holds `sessionId -> instance` entries.
