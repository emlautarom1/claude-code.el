# MCP tools

The reference for every tool the [MCP server](architecture.md#mcp-server) advertises to the sessions this package spawns. The server itself — transport, protocol, lifecycle — and the threat model that covers all of these tools are in [`architecture.md`](architecture.md#mcp-server); this file is the catalog.

## What every tool has in common

A tool is registered with `claude-code-mcp-make-tool`, which takes its name, a description, an argument spec and the handler run with the validated argument values. It refuses an argument whose `type` is not one `claude-code--mcp-arg-types` can enforce, so the schema never advertises a type nothing checks; serving a new one is a line in that table. That registration is the single source of the `tools/list` schema and of the `--allowedTools` identifier `mcp__emacs__<tool>`, so neither can drift from the tool it describes. A new tool is that call, a section in this file, and its line in the catalog list in `claude-code-mcp.el`.

Each call runs with `default-directory` bound to the calling session's real working directory — the worktree directory for a [worktree session](glossary.md), not the parent project root it was launched from. A handler that needs that directory as a *value* rather than as ambient context reads `claude-code--mcp-session-cwd`, bound alongside it for the duration of the call and nil when the calling id names no session it can find.

Arguments arrive as JSON: an omitted optional argument, JSON `null` and JSON `false` all reach the handler as nil, so a boolean argument reads as a plain Lisp truth value. An empty string given for an *optional* argument counts as omitted too, so a handler forwarding values to a process never emits an option with nothing after it; for a required argument it stays the value it is.

An argument spec can also name the `enum` of values it accepts, which the schema advertises and `claude-code--mcp-validate-args` holds the call to: a required argument the call left out, a value of the wrong `type` and a value outside an `enum` are each a JSON-RPC `-32602` naming the argument, and the handler does not run. So is an `arguments` that is not an object at all — `null` aside, which stands for the object a call with no arguments did not send. A required boolean is the one argument nil does not condemn: `false` answers it, while `null` and silence leave it unanswered. An error the handler itself signals is a different thing — it becomes an `isError` result carrying the message, which Claude sees and can act on.

With `claude-code-mcp-auto-approve` (the default) **every** tool below is pre-authorized for spawned instances, so Claude calls them without prompting.

## `eval`

Reads and evaluates Emacs Lisp in the user's live Emacs and returns the printed result.

| Argument | Type     | Required | Meaning                                |
|----------|----------|----------|----------------------------------------|
| `code`   | `string` | yes      | Emacs Lisp source to read and evaluate |

`code` may hold several top-level forms; each is read and evaluated in order with lexical binding, and `prin1-to-string` of the **last** form's value is returned. Reading happens under the Elisp syntax table, so whitespace and comments between and after forms are skipped — code that is nothing but comments evaluates to nil rather than failing. A malformed form, including an incomplete final one, surfaces its read error as a tool error instead of silently evaluating the valid prefix.

Evaluation is aborted after `claude-code-mcp-eval-timeout` seconds. The timeout only interrupts code that yields (I/O, `sit-for`, process waits); a CPU-bound infinite loop runs on.

## `spawn`

Starts another Claude Code instance in Emacs and returns its session id.

| Argument        | Type      | Required | Meaning                                                |
|-----------------|-----------|----------|--------------------------------------------------------|
| `prompt`        | `string`  | no       | Initial prompt; without one the instance starts idle   |
| `model`         | `string`  | no       | Model alias (`opus`, `sonnet`, …) or a full model name |
| `effort`        | `string`  | no       | Effort level (`low`, `medium`, `high`, `xhigh`, `max`) |
| `worktree`      | `boolean` | no       | Run the instance in a new git worktree                 |
| `worktree_name` | `string`  | no       | Name for that worktree; asks for one on its own        |

The prompt, model, effort and worktree the [spawn menu](../README.md#usage) offers a user, plus a name for the worktree, which the menu has no field for. What the tool does *not* take is a directory: the root is the **caller's own** `claude-code--mcp-session-cwd`, so an instance always lands in the tree its parent is working in, and a call whose session id names no known session is refused rather than started somewhere arbitrary. Asking for a worktree of course moves the instance out of that tree and into a fresh checkout, which carries none of the caller's uncommitted work. Naming one asks for it: a `worktree_name` is honoured whether or not `worktree` came with it, false included, since a JSON false reaches the handler as the same nil an omitted argument does. Neither the model nor the effort is held to a set of values: both are the CLI's own vocabulary, passed through as given, so a level or an alias the CLI gains works here without a change.

The tool returns the id `claude-code-spawn` generates, which is the only durable handle on the new session: Claude renames its buffer after the terminal title within seconds of starting. An id means the instance was **launched**, not that it survived startup — an invalid model or effort is the CLI's error to report, inside a terminal the caller is not reading.

The instance takes no window of its own. Displaying one is the view's business — `claude-code-spawn` shows nothing by itself, and the `pop-to-buffer` a user sees comes from the spawn menu — so a tool-driven spawn leaves the window layout alone. The sessions views are deliberately not refreshed either: a spawn the user did not ask for should not reprint a view they may be working in, so new rows appear on their next refresh (`g`). Nothing after the launch can fail, so an error the caller sees never leaves a live instance behind it.

The instance it starts is pre-authorized for the catalog like any other, this tool included — what that costs is the [threat model](architecture.md#decisions)'s subject.
