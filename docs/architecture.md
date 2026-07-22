# Architecture

`claude-code.el` is one file organized as four layers, top to bottom in the source. Each layer only depends on the ones above it.

```
Storage adapter   ~/.claude parsing + cwd encoding   (Claude internals live here)
        │  returns plain data
Model             claude-code-session structs, the sessions query, process usage
        │  structs only
Operations        spawn / resume / kill / delete / rename / send / interrupt / focus
        │
View              claude-code-sessions-mode + transient menu + `claude-code'
```

## Model / view separation

Every fundamental capability is a plain function usable from Elisp without the UI: `claude-code-spawn`, `claude-code-resume`, `claude-code-kill`, `claude-code-delete`, `claude-code-rename`, `claude-code-send-text`, `claude-code-interrupt`, `claude-code-focus`, and the query `claude-code-sessions`. The view is a thin presentation and command layer over these.

## Storage-adapter boundary

All knowledge of Claude's on-disk formats is quarantined in the *Storage adapter* section (see [`storage-model.md`](storage-model.md)). It exposes only plain data — hashes and plists — so a format change is a single-section fix and never ripples through the model, operations, or view.

## The session model

`claude-code-session` is a `cl-defstruct` describing a session. `claude-code-sessions PROJECT-ROOT` builds the list, and every row falls into one of three liveness states (`claude-code--session-liveness`):

- **Alive** = one entry per live *managed* instance (`claude-code--managed` registry ∩ live Ghostel process), keyed by the UUID we assigned at spawn. Status/name come from the live `sessions/*.json` entry; title/last-prompt from the transcript.
- **External** = a transcript for the project that is *not* an Emacs-managed instance but whose `sessions/*.json` PID is still alive — i.e. a `claude` running the session in some other terminal. It is flagged `external-p`, which blocks resume and delete, and it gets its own group in the view. It is deliberately **not** called "dead": a process is handling it.
- **Dead** = every remaining transcript — no process, inside or outside Emacs, is running it. Only dead sessions can be resumed or deleted.

This realises the decision that **aliveness is Emacs-managed only**: a session is alive exactly when Emacs holds its terminal, which also guarantees focus and send-text always work on alive rows.

The struct holds several raw name sources (the live `name`, the transcript `title`, the last prompt), but the *displayed* name is computed in exactly one place — `claude-code--session-display-name` — and is never cached, so it always reflects Claude's own data (including a `/rename`) and cannot drift.

### Registry lifecycle

`claude-code-spawn` / `claude-code-resume` create a Ghostel buffer, record it in `claude-code--managed`, and register `claude-code--on-exit` on `ghostel-exit-functions`. When the process dies the entry is removed and the session naturally becomes dead on the next query.

### Resource usage

`claude-code--process-snapshot` builds the process table once per refresh; `claude-code--process-usage` sums `pcpu`/`rss` over a PID's whole subtree (Claude spawns child processes). `pcpu` may be a lifetime average depending on platform.

## The view

`claude-code-sessions-mode` derives from `tabulated-list-mode`. Grouping uses Emacs 30's `tabulated-list-groups`, which prints a header line per group and sorts entries within each group. Collapsing is therefore trivial: a collapsed group contributes its header but no rows (`claude-code--collapsed`). Marks use `tabulated-list` tags backed by `claude-code--marks`; column sorting is built in. A per-buffer timer (`claude-code-refresh-interval`) refreshes the view while it is visible, preserving point and re-applying marks. Colors come from the Emacs palette faces `success` (idle) / `warning` (busy) / `error` (waiting) / `shadow` (dead) / `font-lock-comment-face` (external).

## Decisions

1. **Custom `tabulated-list-mode`**, not literal `ibuffer.el` (which is tied to buffer objects and cannot represent dead sessions).
2. **IDE/MCP integration is deferred** — v1 is orchestration only, so the only dependency is Ghostel (a WebSocket IDE server would pull in `websocket`).
3. **Alive = Emacs-managed only**; all dead sessions are read from disk.
4. **Worktree sessions appear under their parent project**, with the worktree directory's name in the *Worktree* column.
5. **Native Claude vocabulary** (`busy`/`idle`/`waiting`) is surfaced verbatim.
6. **Storage internals are quarantined** in the storage-adapter section.
