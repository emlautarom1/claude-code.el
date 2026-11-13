# MCP tools

The reference for every tool the [MCP server](architecture.md#mcp-server) advertises to every local `claude`. The server itself — bridge, protocol, wiring — and the threat model that covers all of these tools are in [`architecture.md`](architecture.md#mcp-server); this file is the catalog.

## What every tool has in common

A tool is registered with `claude-code-mcp-make-tool`, which takes its name, a description, an argument spec and the handler run with the validated argument values. It refuses an argument whose `type` is not one `claude-code--mcp-arg-types` can enforce, so the schema never advertises a type nothing checks; serving a new one is a line in that table. That registration is the single source of the `tools/list` schema, so it cannot drift from the tool it describes; Claude knows the tool as `mcp__emacs__<tool>`. A new tool is that call, a section in this file, and its line in the catalog list in `claude-code-mcp.el`.

Each call runs in a temporary buffer, killed when the call ends, whose `default-directory` is the working directory of the calling `claude` as its sessions/ file says — the worktree directory for a [worktree session](glossary.md), not the parent project root it was launched from — or, for a process with no such file, the directory its bridge started in. A handler that needs that directory as a *value* rather than as ambient context reads `claude-code--mcp-session-cwd`, bound for the duration of the call.

Arguments arrive as JSON: an omitted optional argument and JSON `null` reach the handler as nil, and so does the JSON `false` a boolean accepts — which is what lets a boolean argument read as a plain Lisp truth value. An empty string is a value only a string carries, and given for an *optional* argument it counts as omitted, so a handler forwarding values to a process never emits an option with nothing after it; for a required argument it stays the value it is. Which spellings a type accepts is the type's own business, so `false` given for a string, or an empty string given for a boolean, is the wrong type rather than a quiet nil.

An argument spec can also name the `enum` of values it accepts, which the schema advertises and `claude-code--mcp-validate-args` holds the call to: a required argument the call left out, a value of the wrong `type` and a value outside an `enum` are each a JSON-RPC `-32602` naming the argument, and the handler does not run. So is a `params`, or an `arguments`, that is not an object at all — `null` aside, which stands for the object a call did not send. A required boolean is the one argument nil does not condemn: `false` answers it, while `null` and silence leave it unanswered. An error the handler itself signals is a different thing — it becomes an `isError` result carrying the message, which Claude sees and can act on.

With `claude-code-mcp-auto-approve` (the default) **every** tool below is pre-authorized for the instances Emacs launches, so Claude calls them without prompting.

## `eval`

Reads and evaluates a single Emacs Lisp form in the user's live Emacs and returns the printed result.

| Argument | Type     | Required | Meaning                  |
|----------|----------|----------|--------------------------|
| `code`   | `string` | yes      | A single Emacs Lisp form |

`code` holds exactly one top-level form, evaluated with lexical binding; `prin1-to-string` of its value is returned, untruncated whatever `print-length` and `print-level` the user runs with. Whitespace and comments around the form are ignored, so code that is nothing but comments evaluates to nil. The form is read before any of it runs, so a malformed one evaluates nothing at all. Trailing text that reads as a second form is refused, asking for both to be wrapped in `(progn ...)`; trailing text that reads as no form — `(+ 1 2))`, `(+ 1 2) (+ 3` — gets the read error instead.

`(current-buffer)` is the call's temporary buffer, never one the user can see, so a form that names no buffer touches none. Name the buffer to act on with `(with-current-buffer BUFFER ...)`, or reach the one the user is looking at with `(window-buffer (selected-window))`. That fresh buffer is a default, not a boundary.

Evaluation is aborted after `claude-code-mcp-eval-timeout` seconds. The timeout only interrupts code that yields (I/O, `sit-for`, process waits); a CPU-bound infinite loop runs on until the user quits it with `C-g`.

## `spawn`

Starts another Claude Code instance in Emacs and returns its session id.

| Argument   | Type     | Required | Meaning                                                |
|------------|----------|----------|--------------------------------------------------------|
| `prompt`   | `string` | no       | Initial prompt; without one the instance starts idle   |
| `name`     | `string` | no       | Display name for the session                           |
| `model`    | `string` | no       | Model alias (`opus`, `sonnet`, …) or a full model name |
| `effort`   | `string` | no       | Effort level (`low`, `medium`, `high`, `xhigh`, `max`) |
| `worktree` | `string` | no       | Name of the git worktree to run the instance in        |

The name, model, effort and worktree the [create menu](../README.md#usage) offers a user, plus one the menu does not: `prompt`, since the menu starts every session idle. `name` is the session's display name in the sessions view, while `worktree` names the checkout it runs in. What the tool does *not* take is a directory: the instance runs where the caller does (`claude-code--mcp-session-cwd`), as a [worktree session](glossary.md) of the caller's worktree when it has one. Naming another worktree moves the instance out of that tree, carrying none of the caller's uncommitted work. Naming an existing one, the caller's own included, enters it rather than building another; it may carry an earlier session's commits, and [the CLI may reset it](storage-model.md#worktrees) first. Unlike the menu, the tool cannot have Claude name a fresh worktree.

Nothing here checks the name: it reaches the CLI as given, which makes both the directory and the branch. The tool asks for letters, digits, dots, underscores and dashes, which is what the CLI accepts intact ([the rest](storage-model.md#worktrees) it either rewrites or rejects, and a rejected name is an instance that dies at startup). Neither the model nor the effort is held to a set of values: both are the CLI's own vocabulary, passed through as given, so a level or an alias the CLI gains works here without a change. The display name is not checked either; it is whatever the caller wants read in the view.

The tool returns the id `claude-code-spawn` generates, which is the only durable handle on the new session: Claude renames its buffer after the terminal title within seconds of starting. An id means the instance was **launched**, not that it survived startup — an invalid model or effort is the CLI's error to report, inside a terminal the caller is not reading.

The instance takes no window of its own. Displaying one is the view's business — `claude-code-spawn` shows nothing by itself, and the display a user sees comes from the create menu — so a tool-driven spawn leaves the window layout alone. The sessions views pick the instance up as they do any other change ([the view](architecture.md#the-view)). Nothing after the launch can fail, so an error the caller sees never leaves a live instance behind it.

The instance is detachable when `claude-code-detachable` makes one in the caller's directory so. Either way it is pre-authorized for the catalog like any other instance Emacs launches, this tool included, whoever called — what that costs is the [threat model](architecture.md#decisions)'s subject.
