# Design

## Concepts

Terms follow Claude Code's own vocabulary where it has one, and each term has one meaning.

- **Session**: one Claude Code conversation. Its id is its only durable name.
- **Transcript**: Claude's on-disk record of a session's conversation, which outlives any process.
- **Instance**: a running `claude` process. Claude can move it to another session without a restart. A *managed* instance is one this Emacs launched or attached and hosts in a terminal buffer.
- **Kill** ends an instance's process. **Close** ends its buffer, and the process with it unless the instance is detachable.
- **Detachable instance**: an instance held on its host by `dtach`, so it outlives its buffer and Emacs. *Detaching* closes its buffer on purpose.
- **Liveness**: a session is *alive* when a managed instance runs it, *external* when a `claude` outside Emacs runs it, and *dead* when nothing does. An external session a detachable instance runs is *attachable*: attaching hosts it in a new buffer, making it alive again.
- **Status**: what an alive session is doing, in Claude's own words, shown verbatim.
- **Project**: a `project.el` project, with a view of its own listing the sessions that work in it.
- **Worktree session**: a session Claude runs in one of the git worktrees it keeps inside a project.
- **Config dir**: where Claude keeps its state on a host.
- **MCP server**: Emacs serving tools to every local `claude`, so Claude can act on the user's live Emacs.

## Architecture

The MCP server lives in a file of its own that depends on the core, and the core loads it only to launch an instance, so the dependency runs one way.

The core has adapters, a model, operations, notifications and a view.

**Model and view.** Every capability is a plain Elisp function usable without the UI. The view is a thin layer over them, and nothing below it calls into it. Safety checks live below the view, so they hold for every caller.

**Adapters.** Each external source has its own adapter, which hands plain data to a model the package owns: Claude's state in the config dir, the status records Ghostel keeps for an instance, and `dtach`. Claude's on-disk state is undocumented and changes between releases, so a change there is fixed in one adapter. Claude's configuration is changed only through the CLI's own commands.

**Dependencies.** As few as possible. A new one needs a reason no built-in library can answer.

## Decisions

### Only managed instances make a session alive

Only a managed instance makes a session alive, since only its terminal is one Emacs can send text and interrupts to. Emacs never resumes or deletes a session another process runs. An external session can still be ended from Emacs, and attached when a detachable instance runs it.

### An instance is not a session

Claude keeps a record per running process and a transcript per session, joined by session id. Since an instance can change sessions, the package tracks it by its buffer and reads which session it runs now. A listed session is a snapshot, so each operation re-checks what it acts on, and a stale row cannot harm a live instance. One event retires an instance: its buffer closing, however that came about.

### List the sessions a person drove

A view lists a session when a person drove any part of it, from any Claude surface; one a program drove throughout, such as an agent in a fan-out or a `claude -p` run, is left out unless a managed instance runs it. The filter errs toward listing, since a stray row costs less than a session the user cannot find. Background agents the user dispatched are listed as the user's own.

### Claude stays the authority

A session is named only from its transcript, so live and dead sessions are named alike and the package stores no names. A transcript is shown as Claude's own export renders it; the package draws no conversation itself. Models, effort levels and worktree names reach the CLI as given, and the CLI judges them.

### Events, not polling

A local project's view follows events: its instances starting, changing status, switching sessions and exiting, and Claude rewriting its records of running processes. A view out of sight catches up when shown. A call for attention is an event too, the status an instance reports through its terminal, and only the session's own status asks for attention, never its subagents'.

### Remote projects

A remote project is handled on its own host, under that host's config dir. Its view is read only when the user refreshes it or acts on its sessions, never in the background, so Emacs never stalls on a network read the user did not ask for. Between reads it is never patched with what Emacs learns locally, since an old read mixed with newer events could show a state that never existed. Instead, commands acting on it offer a refresh when Emacs knows it has changed.

### Worktrees

Worktree sessions are listed in the parent project's view, with the worktree in its own column. Claude can refile a running worktree session's transcript under the parent, so only the parent's view is sure to list the whole tree. The package therefore never scopes to a worktree: a buffer inside one of Claude's worktrees acts on the parent project.

The column shows only the worktree Claude records for a session, never where its transcript is filed, so it matches where a resume lands: that worktree while its checkout exists, otherwise the parent tree.

## The MCP server

The server rides on the Emacs server. It is registered once in Claude's user configuration, and each `claude` reaches Emacs through a small stdio bridge that calls `emacsclient`, so instances Emacs did not start, or that outlived it, reach it too. It needs no dependency or port of its own.

A tool call runs in the working directory of the session that made it. That directory is context for the tool, not a sandbox. Calls run inside the user's Emacs, so a long one stalls the editor and every other caller until it returns.

### Threat model

The server trusts every process running as the user, and nothing else. Any request it accepts can run arbitrary Elisp in the user's live Emacs.

- It is reachable by exactly what reaches the Emacs server: web pages and other local users are kept out, while anything running as the user is not, and could already run Elisp through `emacsclient`.
- Claude Code's sandbox can keep the commands Claude runs off the Emacs socket, but not the model, which reaches Emacs through the tools.
- The registration reaches every `claude` sharing the config dir, including one started in an untrusted repository.
- The caller a request names only picks the directory the call runs in. It authenticates nothing.
- Auto-approval pre-authorizes every tool for the instances Emacs launches, and a tool can launch one for any caller. A `claude` that prompts per call is therefore one approved launch away from an instance running Elisp unprompted, out of sight. Nothing caps instances launching instances.
- An instance on a remote host is not wired to Emacs. Its bridge would run on that host, where the Emacs socket means nothing, and auto-approving an `emacs` server there would approve whatever that host calls by the name.
- Work on another host, in a container or under another user stays out of reach only while it cannot see the user's Emacs socket directory.
