# Architecture

The package is two files. `claude-code.el` is the core, organized as four layers, top to bottom in the source; each layer only depends on the ones above it. `claude-code-mcp.el` is a self-contained addition (the [MCP server](#mcp-server)) that sits beside the core: it `require`s `claude-code.el` at load, while the core loads *it* lazily from the spawn path and `declare-function`s its single entry point, so the dependency stays one-way and acyclic.

```
Storage adapter   ~/.claude parsing + cwd encoding   (Claude internals live here)
        │  returns plain data
Model             claude-code-session structs, the sessions query, process usage
        │  structs only
Operations        spawn / resume / kill / delete / rename / send / interrupt / focus
        │
View              claude-code-sessions-mode + spawn menu + claude-code-sessions
```

## Model / view separation

Every fundamental capability is a plain function usable from Elisp without the UI: `claude-code-spawn`, `claude-code-resume`, `claude-code-kill`, `claude-code-delete`, `claude-code-rename`, `claude-code-send-text`, `claude-code-interrupt`, `claude-code-focus`, and the query `claude-code-project-sessions`. The view is a thin presentation and command layer over these.

## Storage-adapter boundary

All knowledge of Claude's on-disk formats is quarantined in the *Storage adapter* section (see [`storage-model.md`](storage-model.md)). It exposes only plain data — hashes and plists — so a format change is a single-section fix and never ripples through the model, operations, or view.

## The session model

`claude-code-session` is a `cl-defstruct` describing a session. `claude-code-project-sessions PROJECT-ROOT` builds the list, and every row falls into one of three liveness states (`claude-code--session-liveness`):

- **Alive** = one entry per live *managed* instance (`claude-code--managed` registry ∩ live Ghostel process), keyed by the UUID we assigned at spawn. Status comes from the live `sessions/*.json` entry; title/last-prompt (and hence the display name) from the transcript.
- **External** = a transcript for the project that is *not* an Emacs-managed instance but whose `sessions/*.json` PID is still alive — i.e. a `claude` running the session in some other terminal. It is flagged `external-p`, and it gets its own group in the view. It is deliberately **not** called "dead": a process is handling it. Resume and delete both refuse it **in the model**, so a headless caller cannot attach a second process to it either, and both check by **id** through `claude-code--external-p`, not only the flag on a struct.
- **Dead** = every remaining transcript — no process, inside or outside Emacs, is running it. Only dead sessions can be resumed or deleted.

This realises the decision that **aliveness is Emacs-managed only**: a session is alive exactly when Emacs holds its terminal, which also guarantees focus and send-text always work on alive rows.

The **id is the only durable name for a session**, which is what those states are decided by, and it has two consequences:

- Liveness never depends on the root a query names, because one session can belong to two roots (see [storage model](storage-model.md#worktrees)). The registry's launch root answers *membership* alone, and only until Claude writes a transcript.
- A struct is only as fresh as the query that built it, so `claude-code-delete` and `claude-code-kill` re-check by id: a resume or a relaunch between the query and the act must not turn a stale row into damage to a live instance.

The struct holds the transcript's raw name sources (the `title` and the last prompt), and the *displayed* name is computed in exactly one place — `claude-code--session-display-name` — and is never cached, so it always reflects the transcript (including a `/rename`, which lands as a `custom-title`) and cannot drift.

### Registry lifecycle

`claude-code-spawn` / `claude-code-resume` create a Ghostel buffer, record it in `claude-code--managed`, and register `claude-code--on-exit` on `ghostel-exit-functions`. When the process dies the entry is removed and the session naturally becomes dead on the next query.

### Resource usage

`claude-code--process-snapshot` builds the process table once per refresh; `claude-code--process-usage` sums `pcpu`/`rss` over a PID's whole subtree (Claude spawns child processes). `pcpu` may be a lifetime average depending on platform. Usage is nil when the snapshot has no entry for the PID — a process that died before it was sampled reads as unknown, not as idle — and the view leaves those cells empty.

## The view

`claude-code-sessions-mode` derives from `tabulated-list-mode`. Columns are *Status · Active · Id · Worktree · CPU% · Mem · Name*, with **Name last** so it is never truncated and fills the remaining window width. The *Active* column shows each session's last activity as a compact relative age (the newest timestamped transcript line — see [storage model](storage-model.md)); it is the **default sort key**, reversed, so the most recently active session heads each group. Grouping uses Emacs 30's `tabulated-list-groups`, which prints a header line per group and sorts entries within each group. Collapsing is therefore trivial: a collapsed group contributes its header but no rows (`claude-code--collapsed`). The *Dead* group starts collapsed and any group can be toggled with `TAB`. Marks use `tabulated-list` tags backed by `claude-code--marks`, and since a mark silently outranks point as the target of `k` and `d`, the view works to keep one from going unnoticed: the tag is painted by the `tabulated-list-printer` (`claude-code--print-entry`) rather than after the fact, so it survives the reprints that bypass `claude-code--redraw` (column sorting, `revert-buffer`, the column-width commands); a collapsed group, which prints no rows, reports the count in its header instead — `▸ Dead (3, 2 marked)`; and `claude-code--tabulated-groups` prunes marks to the sessions the listing holds. Colors come from the Emacs palette faces `success` (idle) / `warning` (busy) / `error` (waiting) / `shadow` (dead) / `font-lock-comment-face` (external).

Spawn, resume, kill and delete change which sessions exist, so they redraw through `claude-code--refresh-views` and unmark through `claude-code--drop-marks`. Both cover **every** view whether or not it is displayed: no view owns a session (per the [session model](#the-session-model) above), so any of them can be holding the row a command just changed, or a spent mark. Each view recomputes independently. `g`, `TAB` and `G` change one view's own presentation only, and redraw that buffer alone.

Each redraw goes through `claude-code--redraw`, the one place responsible for not losing the cursor. It follows `dired-revert`: restore by **identity** (the session id) and fall back to the **line and column** when the row at point is gone — deleted, or folded away — so a run of `d` walks down the list. A line number is the right fallback because it survives the rows above point changing, which a buffer position does not. `claude-code--place` takes that snapshot and `claude-code--goto-place` replays it. A caller that knows better passes its own target: `claude-code-sessions-toggle-group` asks for the header of the group it just toggled, which is what makes `TAB TAB` fold and unfold in place. Like `dired-restore-positions` this covers **every window** showing the view, since the reprint's `erase-buffer` collapses all their `window-point`s to the top; each window's scroll is restored too, so a row keeps its height on screen.

Every `claude-code-sessions-*` command reads the view's buffer-local state, so each one guards with `claude-code--ensure-sessions-mode` (a `user-error` outside the view) and tags its `interactive` form with the mode. The tag scopes `M-x`/`M-S-x` completion, but the guard is the real boundary: when `read-extended-command-predicate` is otherwise unset, transient installs one that ignores mode tags.

Two commands are global, each resolving its project through `claude-code--project-root`: `claude-code-sessions` and `claude-code-spawn-menu`. The menu resolves the root **before** `transient-setup` and hands it down as the prefix's `:scope`, so a buffer with no project prompts before the menu appears, and `claude-code--spawn-session` reads the root from the scope instead of the buffer it runs in — that is what frees the menu from the view, which it neither opens nor needs selected. The suffix carries transient's `transient--suffix-only` completion predicate, so `M-x` never offers it.

A spawn displays the new instance with `pop-to-buffer`, so `display-buffer-alist` and window dedication choose the window — the menu runs from any buffer, including a dedicated side window, and must not take it over. `claude-code-focus` and `RET` use `switch-to-buffer`: showing the instance *in the selected window* is what they are for, with `o` as the other-window variant.

## MCP server

`claude-code-mcp.el` exposes Emacs *to* the sessions this package spawns. One HTTP server runs per Emacs, shared by every session; each spawned instance is pointed at it with an inline `--mcp-config` blob (see [storage model](storage-model.md#mcp-configuration)). The server advertises a growing **catalog of tools**; today the catalog holds one, `eval` (read and evaluate Elisp, return the printed result). It mirrors the core's layering:

- **Transport** — quarantined `web-server` glue, the only part that touches sockets. `claude-code--mcp-handle` reads one POST's session id, body and declared `Content-Length` off the request and writes back the envelope the protocol layer returns — an empty `202` when it returns nil (a notification). Every JSON-RPC message travels over POST; the CLI also opens a `GET /mcp/<uuid>` to try to establish a server→client SSE stream, which `claude-code--mcp-handle-get` answers with **HTTP 405** — the code the Streamable-HTTP spec mandates when the endpoint offers no SSE stream (we push no server-initiated messages). The server binds to `127.0.0.1:0`; the OS-assigned port is read back from the listener process.
- **Protocol** — the **pure, socket-free** response authority. `claude-code--mcp-response-for-body` maps a raw POST body to a response envelope: it guards body integrity (web-server frames the body by the blank line, *not* `Content-Length`, so a body split across packets arrives truncated — a `string-bytes`-vs-header mismatch is answered with a `-32700` error, as is unparseable JSON) and hands the parsed request to `claude-code--mcp-handle-request`, which dispatches it to a result, an error envelope, or `nil` for a notification (a JSON-RPC message with no `id`; the transport still acknowledges it with an empty `202`, or the CLI handshake stalls). This is what the unit tests drive directly. The `initialize` handshake reports protocol version **`2025-06-18`** — the revision whose Streamable-HTTP transport we actually implement (single-message POST bodies, optional sessions, optional SSE); the server always reports this one version it supports rather than echoing the client's requested version.
- **Registry/catalog** — `claude-code--mcp-tools` maps a tool name to a plist (`:description`/`:args`/`:handler`); `claude-code-mcp-make-tool` registers one. Plain data describing each advertised tool.

All JSON crosses the wire through the C built-ins `json-serialize`/`json-parse-string`: **every JSON array is an Emacs vector** and JSON false/null are `:json-false`/`:null` — a list-of-alists would error under `json-serialize`.

**Session context.** Each tool runs with `default-directory` bound to the calling session's *real* cwd, resolved by `claude-code--mcp-with-session` through the model accessor `claude-code--session-cwd id`. For a worktree session that real cwd is the worktree directory, not the parent project root the instance was launched from — binding it makes `default-directory`-relative operations land in the right tree (best-effort context for an arbitrary-Elisp tool, not a sandbox). This accessor is the **one deliberate exception** to the structs-only convention: it is keyed by the id *string* (the path token the transport hands over), because the MCP file never builds `claude-code-session` structs — it reaches session state only through this single function.

**Lifecycle.** The server starts lazily on the first spawn (idempotent ensure; a live listener's port is reused) and lives exactly as long as the last managed instance. This module owns both ends of that itself: it puts `claude-code-mcp-stop` on `claude-code-last-instance-exit-hook`, which the core runs when its registry empties, so the core holds no MCP knowledge beyond building the CLI arguments. `claude-code-mcp-stop` is a clean no-op when nothing is live, so it is safe to call unconditionally.

## Decisions

1. **Custom `tabulated-list-mode`**, not literal `ibuffer.el` (which is tied to buffer objects and cannot represent dead sessions).
2. **MCP integration ships as an HTTP server** — every spawned instance connects back to one Emacs [MCP server](#mcp-server) over loopback HTTP (Streamable-HTTP transport via the `web-server` package). It is kept in its own file (`claude-code-mcp.el`) and loaded lazily from the spawn path.
3. **Alive = Emacs-managed only**; all dead sessions are read from disk.
4. **Worktree sessions appear under their parent project**, with the worktree's encoded directory token in the *Worktree* column.
5. **Native Claude vocabulary** (`busy`/`idle`/`waiting`) is surfaced verbatim.
6. **Storage internals are quarantined** in the storage-adapter section.
7. **The MCP server trusts the local machine.** Stated honestly: the default `claude-code-mcp-auto-approve` pre-authorizes **every registered tool**, so the spawned `claude` invokes them without a prompt — and since today's catalog holds `eval`, that means the loopback server executes **arbitrary Elisp in the user's live Emacs** (buffer contents, in-memory secrets, the full Emacs API) driven by whatever process holds the URL. The `/mcp/<uuid>` path is only a multiplexing key, **not** a security boundary: the full URL (uuid included) sits on `claude`'s command line, visible to any same-user process via `ps`/`/proc`. So the real boundary is the loopback bind plus single-user trust — acceptable only on a machine where every local user is trusted. Turn it off with `claude-code-mcp-enabled nil`, or drop auto-approval with `claude-code-mcp-auto-approve nil` (Claude then prompts per call).
