# claude-code.el

Orchestrate and manage [Claude Code](https://www.anthropic.com/claude-code) CLI sessions from Emacs. Spawn, resume, and monitor multiple `claude` instances per project, each hosted in a [Ghostel](https://github.com/dakra/ghostel) terminal buffer, and manage them from an IBuffer-style dashboard.

> Status: early. Targets **Emacs 30+**. This is a personal package with a strict no-backwards-compatibility policy — see [`CLAUDE.md`](CLAUDE.md).

## Features

- **Per-project sessions view** (`M-x claude-code-sessions`) — a `tabulated-list-mode` buffer listing every session of the current `project.el` project, alive and dead.
- **Grouping** by status (`busy`/`idle`/`waiting`) or by liveness (alive / external / dead), with **collapsible groups** and column **sorting**.
- **Status and resource usage** — Claude's native status plus CPU% and memory summed over each instance's process subtree.
- **External sessions** — a `claude` running in another terminal is shown in its own group and protected from resume/delete, never disturbed by Emacs.
- **Actions** — focus an alive instance, resume a dead session, spawn a new one (with an initial prompt, a display name, a chosen model, an effort level, or a git worktree), kill instances, delete dead sessions from disk, rename, send text, and interrupt (SIGINT). Marks allow bulk kill/delete.
- **`transient` spawn menu** (`M-x claude-code-spawn-menu` from any buffer, `n` in the view) for the spawn flags: name, worktree, model, effort.
- **Attention notifications** — an instance left waiting raises a desktop notification named after the session; clicking it brings Emacs forward, switching workspace if needed, and pops that instance into view. Claude raises these on an idle timer — about a minute after a turn ends, [tunable in `~/.claude.json`](docs/architecture.md#attention-notifications). Replaceable with your own handler, or turned off, via `claude-code-notify-function`.
- **Emacs as an [MCP server](#emacs-as-an-mcp-server)** — spawned sessions can act on your live Emacs.
- **Programmatic API** — every action is a plain function; the view is optional.

## Requirements

- Emacs 30.1+
- [Ghostel](https://github.com/dakra/ghostel) — hosts each instance's terminal. Loaded lazily, so the package byte-compiles and tests without its native module.
- [`web-server`](https://github.com/eschulte/emacs-web-server) — HTTP transport for the MCP server.
- The `claude` CLI on your `PATH`
- For desktop notifications: an Emacs built with D-Bus, and a notification daemon. Verified on GNOME, where a click raises Emacs and shows the instance but does not hand over the keyboard — you click once to start typing. Other daemons dispatch a click differently and are not covered yet.

## Install

Put `claude-code.el` and `claude-code-mcp.el` on your `load-path` and:

```elisp
(require 'claude-code)
```

For `use-package` users:

```elisp
(use-package claude-code
  :vc (:url "https://github.com/emlautarom1/claude-code.el" :rev :newest)
  :commands (claude-code-sessions claude-code-spawn-menu))
```

## Usage

Run `M-x claude-code-sessions` to open the sessions view, or `M-x claude-code-spawn-menu` from any buffer to spawn an instance with options and display it. Both act on the current project — the view's own project when invoked from a sessions view — and prompt for one when the buffer belongs to none. Keys in the sessions view:

| Key       | Action                                                       |
| --------- | ------------------------------------------------------------ |
| `RET`     | focus an alive session / resume a dead one / toggle a group  |
| `o`       | like `RET`, but visit the session in another window          |
| `TAB`     | collapse or expand the group at point                        |
| `n`       | open the spawn menu (name/worktree/model/effort; `n` spawns) |
| `k`       | kill the marked instances, or the one at point               |
| `d`       | delete the marked dead sessions, or the one at point         |
| `r`       | rename the session at point                                  |
| `i`       | interrupt (SIGINT) the session at point                      |
| `s`       | send a line of text to the session at point                  |
| `m` / `u` | mark / unmark the session at point                           |
| `G`       | cycle grouping (status ↔ liveness)                           |
| `g`       | refresh                                                      |
| `?`       | describe the mode, listing every keybinding                  |

An instance appears in the selected window. A window that cannot host it — a side window, or any window dedicated to its buffer — keeps what it has and the instance opens in another window; an instance already on screen is shown there rather than a second time. Add a `display-buffer-alist` entry for the instance buffers to place them somewhere of your own choosing; it takes precedence over all of this.

## Programmatic API

```elisp
;; Spawn a new instance in the current project with an initial prompt.
(claude-code-spawn (project-root (project-current t))
                   :prompt "Explain this repository" :model "opus")
;; => (SESSION-ID . BUFFER)

;; Spawn under a display name, which is what the sessions view shows.
(claude-code-spawn root :name "release audit")

;; Spawn in a git worktree.
(claude-code-spawn root :worktree t)          ; auto-named
(claude-code-spawn root :worktree "feature")  ; named

;; Query the model.
(claude-code-project-sessions root)   ; => list of `claude-code-session' structs

;; Resume a session by id, then act on sessions.
(claude-code-resume root "SESSION-UUID")
(claude-code-kill session)
(claude-code-delete session)         ; dead sessions only
(claude-code-rename session "name")  ; alive sessions only
(claude-code-send-text session "hello" t)
(claude-code-interrupt session)
```

## Emacs as an MCP server

Spawned sessions are pointed at one loopback [MCP](https://modelcontextprotocol.io) server inside Emacs — one per Emacs, shared by every session — so Claude can act on the editor it is running under. Every tool runs with `default-directory` bound to the calling session's working directory, and the catalog is documented tool by tool in [`docs/mcp-tools.md`](docs/mcp-tools.md).

> ⚠️ **The default pre-authorizes it.** `claude-code-mcp-auto-approve` puts every advertised tool on `--allowedTools`, so a spawned `claude` runs arbitrary Elisp in your Emacs without prompting. What protects you is the loopback bind plus single-user trust — read the [threat model](docs/architecture.md#decisions) before relying on it.

| Variable                       | Default | Effect                                                 |
| ------------------------------ | ------- | ------------------------------------------------------ |
| `claude-code-mcp-enabled`      | `t`     | nil spawns instances with no `--mcp-config` at all     |
| `claude-code-mcp-auto-approve` | `t`     | nil makes Claude prompt before each tool call          |
| `claude-code-mcp-eval-timeout` | `10`    | seconds before `eval` aborts an evaluation that yields |

## Documentation

- [`docs/glossary.md`](docs/glossary.md) — terminology.
- [`docs/storage-model.md`](docs/storage-model.md) — the `~/.claude` layout this package reads (Claude internals; version-volatile).
- [`docs/architecture.md`](docs/architecture.md) — layers and design decisions.
- [`docs/mcp-tools.md`](docs/mcp-tools.md) — the tools the MCP server advertises to spawned sessions.
- [`docs/claude-code-internals.md`](docs/claude-code-internals.md) — Claude's background-agent/FleetView subsystem (reference; not managed by this package).

## Development

```sh
make deps      # install web-server if missing
make compile   # byte-compile with warnings as errors
make test      # run the ERT suite
make lint      # checkdoc
```

`make test` never launches `claude` — it runs the logic against fixtures. `make integration` exercises the real spawn/kill lifecycle and needs Ghostel's native module and a logged-in CLI, so it is skipped by `make test` and CI.

`make compile` and `make test` also run automatically via the project's Claude `Stop` hook (`scripts/compile-and-test.sh`).
