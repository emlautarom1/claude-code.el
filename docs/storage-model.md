# Storage model

> ⚠️ **These are Claude Code internals and are version-volatile.** Everything here describes undocumented on-disk formats under the [config dir](glossary.md) that Anthropic may change between releases (verified against CLI **v2.1.201**, the worktree binding against **v2.1.261**). In the code, **all** of this knowledge is confined to the *Storage adapter* section of `claude-code.el` (`claude-code--encode-cwd`, `claude-code--live-status-table`, `claude-code--project-transcripts` and their helpers). The rest of the package works only with `claude-code-session` structs. When Claude's layout changes, fix that one section.

For the background-agent / FleetView subsystem (a separate concern this package does not manage), see [`claude-code-internals.md`](claude-code-internals.md).

## Config directory

`~/.claude`, or `$CLAUDE_CONFIG_DIR` when set. Resolved once into `claude-code-config-dir`.

## Running instances — `sessions/<pid>.json`

Claude writes one JSON file per running process, named by OS PID. The fields this package reads:

| Field        | Meaning                                                    |
| ------------ | ---------------------------------------------------------- |
| `sessionId`  | the session UUID — the join key to a transcript            |
| `cwd`        | the real, absolute working directory (never encoded)       |
| `status`     | `idle` \| `busy` \| `waiting` (may be **absent** early on) |
| `waitingFor` | set only while `waiting`, e.g. `"permission prompt"`       |
| `pid`        | OS PID (also the filename)                                 |

`claude-code--live-status-table` parses every such file into a hash keyed by `sessionId`. It is pure parsing: a missing `status` yields nil, and process liveness is decided separately (`claude-code--pid-live-p`). This package treats a session as *alive* only when it manages the instance itself, so this table is used to read a managed session's status and to flag [external](glossary.md) sessions — not as the source of aliveness.

A session's display name comes entirely from the transcript (see [Transcripts](#transcripts--projectsencoded-cwdsessionidjsonl) and `claude-code--session-display-name`); a `/rename` is reflected there through its `custom-title`. Claude also writes a `name` on this file, but for most sessions that is a directory-derived placeholder (`{"name":"proj-f8","nameSource":"derived"}`) which would shadow the live transcript title — so the transcript is the sole source.

Liveness is a plain per-PID `process-attributes` existence check; the `procStart` field is deliberately **not** consulted. A stale `sessions/<pid>.json` (left by a crash) whose PID was reused could therefore mis-flag a dead session as external — accepted as a simplicity trade-off, since PID reuse is vanishingly unlikely (`pid_max` defaults to 4194304).

## Transcripts — `projects/<encoded-cwd>/<sessionId>.jsonl`

Append-only JSONL, one JSON object per line. This package reads **four** fields, all cached by file modification time in `claude-code--transcript-cache`. Each is extracted by scanning **backward** from the end of the file (the values of interest sit near the tail):

- **Title** — a session's display title, resolved from two possible lines:
  - a user-set `{"type":"custom-title","customTitle":…}` line, which **takes precedence** when present, otherwise
  - the last `{"type":"ai-title","aiTitle":…}` line — Claude rewrites its generated title as the conversation evolves, so the *last* one wins.

  Both `/rename` and `claude --name=NAME` write a `custom-title`; the spawn flag writes it as the transcript's very first line, before any `ai-title` exists.
- **Last prompt** — the `{"type":"last-prompt","lastPrompt":…}` line (a preview of the opening prompt).
- **Worktree binding** — the `{"type":"worktree-state","worktreeSession":…}` line, read as `(:name :path :bound)` by `claude-code--read-worktree-binding`. See [Worktrees](#worktrees).
- **Last-active time** — the `timestamp` (ISO-8601 UTC, e.g. `2026-06-10T13:23:27.697Z`, parsed with `date-to-time`) of the **newest line that carries one**. It drives the view's *Active* column and default most-recent-first sort, and is surfaced on every session (alive, external, or dead — a dead session's transcript still exists on disk). The file's mtime is **not** used for this: only genuine conversation lines (`user`, `assistant`, `attachment`, `system`, `queue-operation`, `pr-link`, `file-history-delta`) carry a top-level `timestamp`; the CLI also appends *untimestamped* metadata lines (`last-prompt`, `mode`, `permission-mode`, `agent-name`, `ai-title`, `worktree-state`, …) to dead transcripts long after the conversation ends — via the resume/session picker, mode toggles, and the background-agents daemon — which bumps the mtime by minutes to days without representing real activity. Scanning for the last real `timestamp` ignores those writes. Two traps the backward scan must avoid: `file-history-snapshot` metadata lines have no top-level `timestamp` but *embed* one in a nested value, so the scan parses each candidate line and validates the top-level key rather than trusting the `"timestamp"` substring that led it there; and the rare transcript with **no** timestamped line at all (tiny orphaned agent stubs) falls back to the file mtime.

Each scan picks its candidate lines with a **literal** `search-backward`, never a regexp: a regexp cannot use Boyer-Moore, and the search that finds nothing is the one that has to touch every byte. Under 1% of real transcripts carry a `custom-title` line, so that scan reaches the front of the file almost every time — on the largest one here (4.5 MB) the literal takes 0.9 ms against the equivalent regexp's 18 ms. That leaves the whole read at 8.7 ms, of which 7.3 ms is `insert-file-contents`; a median 230 KB transcript reads in 0.7 ms. A shell `tac | grep` pipeline was no faster and adds per-file subprocess overhead, so the in-process read + mtime cache is used.

## The cwd encoding (lossy — never invert)

A project's transcript directory name is its absolute working directory with **every `/` and `.` replaced by `-`** (after `directory-file-name`, so a trailing slash adds no trailing hyphen):

```
/home/me/Development/proj      ->  -home-me-Development-proj
/home/me/.dotfiles             ->  -home-me--dotfiles      (the "/." becomes "--")
```

The mapping is **not reversible** (`proj.el` and `proj-el` collide), so the code never decodes a directory name — a live session's real `cwd` is read from `sessions/*.json`. `claude-code--encode-cwd` implements the encoding, and `claude-code--project-transcripts` consumes it by matching encoded directory names rather than decoding the ones it finds.

## Worktrees

`claude --worktree [name]` runs a session in a git worktree under the project's `.claude/worktrees/<name>`. Its transcript therefore lands in an encoded directory prefixed by the parent project's encoding + `--claude-worktrees-`. `claude-code--project-transcripts` lists both the project's own directory and any directory matching that prefix, so worktree sessions appear under the parent project.

That prefixed name is also **exactly** what encoding the worktree's own path produces — `-home-me-proj--claude-worktrees-feat` is both the parent's worktree directory and `/home/me/proj/.claude/worktrees/feat`'s base directory. One transcript therefore belongs to two roots, and since a git worktree is its own `project.el` project, either of them can be the root a query or a spawn names. This is why nothing in the model may key a session's liveness on the root it was asked about (see the [session model](architecture.md#the-session-model)).

The token after that prefix decides **membership only** — which project's view lists the transcript. It is never turned back into a path or a name: the encoding is lossy, so a dot or `/` in the worktree name reads as a hyphen, and two names differing only in flattened characters share one transcript directory.

### The binding — `worktree-state`

Which worktree a session *runs in* is recorded in the transcript body, not in the directory name. Claude writes a `worktree-state` line whenever that changes:

```json
{"type":"worktree-state","worktreeSession":{"originalCwd":"/home/me/proj","worktreePath":"/home/me/proj/.claude/worktrees/feat","worktreeName":"feat","worktreeBranch":"worktree-feat","originalBranch":"main","originalHeadCommit":"…","sessionId":"…"},"sessionId":"…"}
```

and clears it to `"worktreeSession":null` when the session leaves. Two lines answer two questions, both found by one backward scan each: the **newest** `worktree-state` line says whether Claude still considers the session bound, and the newest line that carries a binding names the worktree — as the user wrote it, so `my.feat` survives where the directory token flattened it to `my-feat`. `claude-code--read-worktree-binding` returns both as `(:name :path :bound)`, and the *Worktree* column shows `:name`.

Leaving is not only an `ExitWorktree`: **a clean exit clears the binding too, even when the user answers "Keep worktree"**, and moves the transcript out of the worktree's encoded directory into the parent project's. Such a session then looks, by directory alone, like a main-tree session — which is why the name has to come from the body. Claude's own parting message says as much, printing `claude --worktree <name> --resume <session>` as the way back in. A hard kill writes nothing, so a killed session stays bound and Claude re-enters its worktree unaided.

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
