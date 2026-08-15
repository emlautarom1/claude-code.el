# MCP tools

The reference for every tool the [MCP server](architecture.md#mcp-server) advertises to the sessions this package spawns. The server itself — transport, protocol, lifecycle — and the threat model that covers all of these tools are in [`architecture.md`](architecture.md#mcp-server); this file is the catalog.

## What every tool has in common

A tool is registered with `claude-code-mcp-make-tool`, which takes its name, a description, an argument spec and the handler run with the validated argument values. That registration is the single source of the `tools/list` schema and of the `--allowedTools` identifier `mcp__emacs__<tool>`, so adding a tool is one call and nothing else.

Each call runs with `default-directory` bound to the calling session's real working directory — the worktree directory for a [worktree session](glossary.md), not the parent project root it was launched from.

Arguments arrive as JSON: an omitted optional argument, JSON `null` and JSON `false` all reach the handler as nil, so a boolean argument reads as a plain Lisp truth value. An empty string given for an *optional* argument counts as omitted too, so a handler forwarding values to a process never emits an option with nothing after it; for a required argument it stays the value it is.

An argument spec can also name the `enum` of values it accepts, which the schema advertises and `claude-code--mcp-validate-args` holds the call to: a missing required argument, a value of the wrong `type` and a value outside an `enum` are each a JSON-RPC `-32602` naming the argument, and the handler does not run. An error the handler itself signals is a different thing — it becomes an `isError` result carrying the message, which Claude sees and can act on.

With `claude-code-mcp-auto-approve` (the default) **every** tool below is pre-authorized for spawned instances, so Claude calls them without prompting.

## `eval`

Reads and evaluates Emacs Lisp in the user's live Emacs and returns the printed result.

| Argument | Type     | Required | Meaning                                |
|----------|----------|----------|----------------------------------------|
| `code`   | `string` | yes      | Emacs Lisp source to read and evaluate |

`code` may hold several top-level forms; each is read and evaluated in order with lexical binding, and `prin1-to-string` of the **last** form's value is returned. Reading happens under the Elisp syntax table, so whitespace and comments between and after forms are skipped — code that is nothing but comments evaluates to nil rather than failing. A malformed form, including an incomplete final one, surfaces its read error as a tool error instead of silently evaluating the valid prefix.

Evaluation is aborted after `claude-code-mcp-eval-timeout` seconds. The timeout only interrupts code that yields (I/O, `sit-for`, process waits); a CPU-bound infinite loop runs on.
