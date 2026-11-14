# claude-code.el

Spawn, resume and monitor [Claude Code](https://www.anthropic.com/claude-code) CLI sessions per project from Emacs. Each instance runs in a [Ghostel](https://github.com/dakra/ghostel) terminal, and an ibuffer-style view manages them.

Status: early. A personal package with no backwards-compatibility guarantees.

## Requirements

- Emacs 30.1+
- [Ghostel](https://github.com/dakra/ghostel)
- The `claude` CLI on the project's host
- [`dtach`](https://github.com/crigler/dtach) on any host that runs detachable instances
- For the MCP server: a running Emacs server, and `sh`, `base64` and `emacsclient` on the `PATH` of each `claude` that uses it
- For desktop notifications: Emacs built with D-Bus, and a notification daemon. On GNOME, a click shows the instance without giving Emacs keyboard focus, so click once more before typing.

## Install

Put `claude-code.el` and `claude-code-mcp.el` on your `load-path` and `(require 'claude-code-mcp)`, which loads both, or:

```elisp
(use-package claude-code
  :vc (:url "https://github.com/emlautarom1/claude-code.el" :rev :newest)
  :commands (claude-code-sessions claude-code-spawn-menu))
```

## Usage

`M-x claude-code-sessions` opens the current project's sessions view, grouped by liveness or by status. `M-x claude-code-spawn-menu`, or `c` in the view, creates a session with options; opened from inside a worktree Claude made, it starts out naming that worktree. Both prompt for a project when the buffer has none.

| Key | Action |
|---|---|
| `RET` | focus an alive session, attach a `⇄` one, resume a dead one, or fold or unfold a group |
| `o` | like `RET`, in another window |
| `TAB` | fold or unfold the group at point |
| `c` | create a session |
| `n` / `p` | next / previous line |
| `k` | kill the marked running sessions, or the one at point |
| `x` | detach the marked alive sessions, or the one at point |
| `d` | delete the marked dead sessions, or the one at point |
| `r` | rename the alive session at point |
| `i` | interrupt the alive session at point |
| `s` | send a line of text to the alive session at point |
| `t` | show the session's transcript beside the view |
| `v` | show the VC status of the session's tree |
| `m` / `u` | mark / unmark |
| `G` | group by liveness or by status |
| `g` | refresh |
| `?` | list every key |

A row's status is followed by `✓` when its last turn finished or `✗` when it failed, until you type into the instance, and by `⇄` when `RET` attaches it. On a row, the echo area shows Claude's message on the last turn, if it sent one, and the session's recap, the summary Claude writes while you are away from it.

Instance buffers are in `claude-code-instance-mode`: a `display-buffer-alist` entry for `(derived-mode . claude-code-instance-mode)` decides where they open, and keys for them go in its map:

```elisp
(use-package claude-code
  :bind (:map claude-code-instance-mode-map
              ("C-c C-k" . claude-code-sessions)))
```

An instance buffer's `default-directory` follows the directory Claude works in, so `C-x p`, `C-x v` and Magit act on the session's worktree.

An instance that finishes a turn, waits on you or fails raises a desktop notification, unless it is on screen in a focused frame. Clicking it goes to the instance, and it closes once you see the instance or deal with what it announced. While a local instance runs a background shell task, such as a dev server, its finished turns raise no notification.

## Options

- `claude-code-detachable` chooses which instances keep running on their host when their buffer closes or Emacs exits; by default, those in remote directories.
- `claude-code-renderer` forces Claude's `inline` or `fullscreen` renderer over its `tui` setting.
- `claude-code-notify-function` replaces the notification handler; nil turns notifications off.

## Emacs as an MCP server

Run `M-x claude-code-mcp-install` once to register Emacs as the `emacs` MCP server for every local `claude`. `claude mcp remove --scope user emacs`, run with the same `CLAUDE_CONFIG_DIR`, unregisters it. A `claude` started while the Emacs server is down has no Emacs tools until `/mcp` reconnects it.

> **Warning:** `claude-code-mcp-auto-approve` is on by default, so every local instance Emacs launches can run arbitrary Elisp in your Emacs without asking, and so can any instance started through the server, whoever asked for it. Set it to nil to leave each call to Claude's permission mode, or unregister the server.

## Programmatic use

```elisp
(let ((root (project-root (project-current t))))
  ;; Start an instance with a first prompt; returns (SESSION-ID . BUFFER).
  (claude-code-spawn root :prompt "Explain this repository")
  ;; List the project's sessions as `claude-code-session' structs.
  (claude-code-project-sessions root)
  ;; Resume a dead session by id; returns its buffer.
  (claude-code-resume root "SESSION-ID"))
```

## Development

```sh
make compile   # byte-compile with warnings as errors
make test      # run the ERT suite
make lint      # checkdoc
```

`make test` runs against fixtures and never launches `claude`. `make integration` runs the real spawn and kill lifecycle; it needs Ghostel's native module and a logged-in CLI.
