# Glossary

Terms used throughout `claude-code.el` and its documentation. They are chosen to
match Claude Code's own vocabulary wherever one exists.

- **Session** — a single Claude Code conversation, identified by a UUID (`sessionId`). A session's history lives in a transcript on disk and outlives any process. Its *liveness* is one of three states — *alive*, *external*, or *dead* (defined below).

- **Transcript** — the append-only `.jsonl` file recording a session's messages, stored under `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.

- **Instance** (a.k.a. *claude instance*) — a running `claude` process working on a session. In this package every instance is hosted in a [Ghostel](https://github.com/dakra/ghostel) terminal buffer.

- **Instance buffer** — the Ghostel terminal buffer that hosts a running instance, named `*claude:<name>*`. This is the buffer you switch to (via *focus*) to talk to a live session directly, as you would in any terminal.

- **Managed instance** — an instance this package launched and tracks (it has an instance buffer in Emacs). Only managed instances make a session *alive* in the view.

A session's *liveness* is one of three states — *alive*, *external*, or *dead*:

- **Alive session** — a session with a live managed instance. Its **status** is Claude's native value:
  - `busy` — actively working.
  - `idle` — finished; waiting for the next prompt.
  - `waiting` — blocked on the user (a question or tool-permission prompt); the `waitingFor` field says what for.

- **Dead session** — a session that no `claude` process is running: its transcript exists on disk but neither Emacs nor any external process is handling it. A dead session is the only kind that can be resumed or deleted.

- **External session** — a session running in a `claude` process **outside** Emacs (for example, one started in a plain terminal). It is neither alive nor dead: a process is handling it, but not one Emacs manages. The view lists it in its own *external* group and flags it so it is never resumed or deleted out from under the other process.

- **Worktree session** — a session spawned with `--worktree`, running in a git worktree under the project's `.claude/worktrees/`. It is listed under its parent project's view, with the worktree directory's name shown in the *Worktree* column.

- **Sessions view** — the `tabulated-list-mode` buffer (`claude-code-sessions-mode`), named `*claude-sessions:<project>*`, that lists a project's sessions grouped by status or by liveness, opened with `M-x claude-code`.

- **Project** — the current `project.el` project (usually a git repository). Each project has its own view. Sessions are associated with a project by their working directory.

- **Config dir** — Claude Code's state directory, `~/.claude` by default, or `$CLAUDE_CONFIG_DIR` when set (`claude-code-config-dir`).

- **Encoded project directory** — the name of a project's transcript directory under `projects/`, produced by replacing every `/` and `.` in the absolute working directory with `-`. The mapping is lossy (see [`storage-model.md`](storage-model.md)).
