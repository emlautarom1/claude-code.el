# MCP tools

The reference for every tool the [MCP server](architecture.md#mcp-server) advertises to the sessions this package spawns. The server itself — transport, protocol, lifecycle — and the threat model that covers all of these tools are in [`architecture.md`](architecture.md#mcp-server); this file is the catalog.

## What every tool has in common

A tool is registered with `claude-code-mcp-make-tool`, which takes its name, a description, an argument spec and the handler run with the validated argument values. It refuses an argument whose `type` is not one `claude-code--mcp-arg-types` can enforce, so the schema never advertises a type nothing checks; serving a new one is a line in that table. That registration is the single source of the `tools/list` schema and of the `--allowedTools` identifier `mcp__emacs__<tool>`, so neither can drift from the tool it describes. A new tool is that call, a section in this file, and its line in the catalog list in `claude-code-mcp.el`.

Each call runs with `default-directory` bound to the calling session's real working directory — the worktree directory for a [worktree session](glossary.md), not the parent project root it was launched from. A handler that needs that directory as a *value* rather than as ambient context reads `claude-code--mcp-session-cwd`, bound alongside it for the duration of the call and nil when the calling id names no session it can find.

Arguments arrive as JSON: an omitted optional argument and JSON `null` reach the handler as nil, and so does the JSON `false` a boolean accepts — which is what lets a boolean argument read as a plain Lisp truth value. An empty string is a value only a string carries, and given for an *optional* argument it counts as omitted, so a handler forwarding values to a process never emits an option with nothing after it; for a required argument it stays the value it is. Which spellings a type accepts is the type's own business, so `false` given for a string, or an empty string given for a boolean, is the wrong type rather than a quiet nil.

An argument spec can also name the `enum` of values it accepts, which the schema advertises and `claude-code--mcp-validate-args` holds the call to: a required argument the call left out, a value of the wrong `type` and a value outside an `enum` are each a JSON-RPC `-32602` naming the argument, and the handler does not run. So is a `params`, or an `arguments`, that is not an object at all — `null` aside, which stands for the object a call did not send. A required boolean is the one argument nil does not condemn: `false` answers it, while `null` and silence leave it unanswered. An error the handler itself signals is a different thing — it becomes an `isError` result carrying the message, which Claude sees and can act on.

With `claude-code-mcp-auto-approve` (the default) **every** tool below is pre-authorized for spawned instances, so Claude calls them without prompting.

## `eval`

Reads and evaluates a single Emacs Lisp form in the user's live Emacs and returns the printed result.

| Argument | Type     | Required | Meaning                  |
|----------|----------|----------|--------------------------|
| `code`   | `string` | yes      | A single Emacs Lisp form |

`code` holds exactly one top-level form, evaluated with lexical binding; `prin1-to-string` of its value is returned, untruncated whatever `print-length` and `print-level` the user runs with. Whitespace and comments around the form are ignored, so code that is nothing but comments evaluates to nil. The form is read before any of it runs, so a malformed one evaluates nothing at all. Trailing text that reads as a second form is refused, asking for both to be wrapped in `(progn ...)`; trailing text that reads as no form — `(+ 1 2))`, `(+ 1 2) (+ 3` — gets the read error instead.

Evaluation runs in a temporary buffer made for the call and killed when it ends, whether the form returned, signalled or timed out, so `(current-buffer)` is never a buffer the user can see and a form that names no buffer touches none. Name the buffer to act on with `(with-current-buffer BUFFER ...)`, or reach the one the user is looking at with `(window-buffer (selected-window))`. That fresh buffer is a default, not a boundary.

Evaluation is aborted after `claude-code-mcp-eval-timeout` seconds. The timeout only interrupts code that yields (I/O, `sit-for`, process waits); a CPU-bound infinite loop runs on.

## `spawn`

Starts another Claude Code instance in Emacs and returns its session id.

| Argument   | Type     | Required | Meaning                                                |
|------------|----------|----------|--------------------------------------------------------|
| `prompt`   | `string` | no       | Initial prompt; without one the instance starts idle   |
| `name`     | `string` | no       | Display name for the session                           |
| `model`    | `string` | no       | Model alias (`opus`, `sonnet`, …) or a full model name |
| `effort`   | `string` | no       | Effort level (`low`, `medium`, `high`, `xhigh`, `max`) |
| `worktree` | `string` | no       | Name of a new git worktree to run the instance in      |

The name, prompt, model, effort and worktree the [create menu](../README.md#usage) offers a user: `name` is the session's own display name, the one the sessions view shows, while `worktree` names the checkout it runs in. What the tool does *not* take is a directory: the root is the **caller's own** `claude-code--mcp-session-cwd`, so an instance always lands in the tree its parent is working in, and a call whose session id names no known session is refused rather than started somewhere arbitrary. Asking for a worktree of course moves the instance out of that tree and into a fresh checkout, which carries none of the caller's uncommitted work. Naming a worktree is the only way this tool asks for one, where the menu's `-w` only ever asks for an unnamed one: the two front ends reach disjoint halves of `claude-code-spawn`'s `:worktree`. Hold the name to letters, digits, hyphens and underscores. Nothing here checks it — it reaches the CLI as given, which makes both the directory and the branch — so a name git refuses is an instance that dies at startup. Git's own rules are wider in places (`a.b` and `feature/login` are both legal) and narrower in others (a leading or trailing `.`, a `..`, a space, and `~^:?*[\` are not), and a `/` nests the checkout one level deeper while a `.` costs precision in the *Worktree* column (see the [storage model](storage-model.md#worktrees)). Neither the model nor the effort is held to a set of values: both are the CLI's own vocabulary, passed through as given, so a level or an alias the CLI gains works here without a change. The display name is not checked either; it is whatever the caller wants read in the view.

The tool returns the id `claude-code-spawn` generates, which is the only durable handle on the new session: Claude renames its buffer after the terminal title within seconds of starting. An id means the instance was **launched**, not that it survived startup — an invalid model or effort is the CLI's error to report, inside a terminal the caller is not reading.

The instance takes no window of its own. Displaying one is the view's business — `claude-code-spawn` shows nothing by itself, and the display a user sees comes from the create menu — so a tool-driven spawn leaves the window layout alone. The sessions views are deliberately not refreshed either: a spawn the user did not ask for should not reprint a view they may be working in, so new rows appear on their next refresh (`g`). Nothing after the launch can fail, so an error the caller sees never leaves a live instance behind it.

The instance it starts is pre-authorized for the catalog like any other, this tool included — what that costs is the [threat model](architecture.md#decisions)'s subject.
