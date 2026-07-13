# Storage model

> ⚠️ **These are Claude Code internals and are version-volatile.** Everything here describes undocumented on-disk formats under the [config dir](glossary.md#config-dir) that Anthropic may change between releases (verified against CLI **v2.1.201**). In the code, **all** of this knowledge is confined to the *Storage adapter* section of `claude-code.el` (`claude-code--encode-cwd`, `claude-code--live-status-table`, `claude-code--project-transcripts` and their helpers). The rest of the package works only with `claude-code-session` structs. When Claude's layout changes, fix that one section.

For the background-agent / FleetView subsystem (a separate concern this package does not manage), see [`claude-code-internals.md`](claude-code-internals.md).

## Config directory

`~/.claude`, or `$CLAUDE_CONFIG_DIR` when set. Resolved once into `claude-code-config-dir`.

## Running instances — `sessions/<pid>.json`

Claude writes one JSON file per running process, named by OS PID. The fields
this package reads:

| Field        | Meaning                                                    |
| ------------ | ---------------------------------------------------------- |
| `sessionId`  | the session UUID — the join key to a transcript            |
| `cwd`        | the real, absolute working directory (never encoded)       |
| `name`       | display name (Claude-derived or user-set)                  |
| `kind`       | `interactive` or `bg` (background)                         |
| `status`     | `idle` \| `busy` \| `waiting` (may be **absent** early on) |
| `waitingFor` | set only while `waiting`, e.g. `"permission prompt"`       |
| `pid`        | OS PID (also the filename)                                 |

`claude-code--live-status-table` parses every such file into a hash keyed by `sessionId`. It is pure parsing: a missing `status` yields nil, and process liveness is decided separately (`claude-code--pid-live-p`). This package treats a session as *alive* only when it manages the instance itself, so this table is used to read a managed session's status and to flag [external](glossary.md#external-session) sessions — not as the source of aliveness.

Liveness is a plain `pid ∈ list-system-processes` check; the `procStart` field is deliberately **not** consulted. A stale `sessions/<pid>.json` (left by a crash) whose PID was reused could therefore mis-flag a dead session as external — accepted as a simplicity trade-off, since PID reuse is vanishingly unlikely (`pid_max` defaults to 4194304).

## Transcripts — `projects/<encoded-cwd>/<sessionId>.jsonl`

Append-only JSONL, one JSON object per line. This package extracts three things, by scanning **backward** from the end of the file (the values of interest sit near the tail), cached by file modification time in `claude-code--transcript-cache`:

- **Title** — a session's display title, resolved from two possible lines:
  - a user-set `{"type":"custom-title","customTitle":…}` line (this is what the `/rename` command writes), which **takes precedence** when present, otherwise
  - the last `{"type":"ai-title","aiTitle":…}` line — Claude rewrites its generated title as the conversation evolves, so the *last* one wins.
- **Last prompt** — the `{"type":"last-prompt","lastPrompt":…}` line (a preview of the opening prompt).

Worktree membership is **not** read from the transcript body. Although a `{"type":"worktree-state",…}` line does exist, the package derives worktree-ness (and the worktree name) purely from the encoded **directory name** — see [Worktrees](#worktrees) below.

Reading the whole file in Emacs and scanning backward measured ≈15 ms on the largest real transcript (6 MB); the median (~130 KB) is sub-millisecond. A shell `tac | grep` pipeline was no faster and adds per-file subprocess overhead, so the in-process read + mtime cache is used.

## The cwd encoding (lossy — never invert)

A project's transcript directory name is its absolute working directory with **every `/` and `.` replaced by `-`** (after `directory-file-name`, so a trailing slash adds no trailing hyphen):

```
/home/me/Development/proj      ->  -home-me-Development-proj
/home/me/.dotfiles             ->  -home-me--dotfiles      (the "/." becomes "--")
```

The mapping is **not reversible** (`proj.el` and `proj-el` collide), so the code never decodes a directory name — it reads the real `cwd` from session/transcript data. `claude-code--encode-cwd` and `claude-code--project-dir` implement this.

## Worktrees

`claude --worktree [name]` runs a session in a git worktree under the project's `.claude/worktrees/<name>`. Its transcript therefore lands in an encoded directory prefixed by the parent project's encoding + `--claude-worktrees-`. `claude-code--project-transcripts` lists both the project's own directory and any directory matching that prefix, tagging the latter as worktree sessions so they appear under the parent project. The **worktree name** is the single path segment following that prefix, so a session's worktree directory can be rebuilt as `<root>/.claude/worktrees/<name>` even when it is dead (no live `sessions/*.json` to read a cwd from).

## Mapping an Emacs buffer to a session

When spawning, this package generates a UUID and passes it as `--session-id`, so a Ghostel buffer is bound to its `sessionId` up front — no polling or PID-matching needed. The UUID is internal and never shown to the user. The registry `claude-code--managed` holds `sessionId -> instance` entries.
