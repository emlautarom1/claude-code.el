# claude-code.el — project conventions

Emacs orchestration tool for the Claude Code CLI. Read `DESIGN.md` for the concepts, the architecture and the design decisions.

## Hard rules

- **Target Emacs 30+ only.** No backwards-compatibility code: no `defalias`/`fset` shims, no feature-detection fallbacks, no obsolete aliases.
- **No "history" comments.** Never describe how code "used to" work or that something "replaces" a prior approach — Git holds the history.
- **As few dependencies as possible.** `ghostel` is loaded lazily and referenced via `declare-function`, so the package byte-compiles and tests without its native module.
- **Source split:** the core orchestration lives in `claude-code.el`; the MCP server lives in `claude-code-mcp.el`. Tests mirror the split: `test/claude-code-tests.el` and `test/claude-code-mcp-tests.el`.
- **Naming:** `claude-code-` for public symbols, `claude-code--` for internals.

## Architecture

- **Storage adapter.** All knowledge of the config dir's on-disk layout lives in the "Storage adapter" section.
- **Ghostel adapter.** Reads of the program status records Ghostel keeps for an instance go through the "Ghostel adapter" section.
- **dtach adapter.** How a detachable instance is held on its host by `dtach` lives in the "dtach adapter" section.
- **MCP tool documentation.** A tool's contract — what it does and the inputs it accepts — lives in its `:description` strings, which agents read; anything else about it goes in its handler. `DESIGN.md` covers the server and the threat model over the whole catalog, and names no tool. Adding a tool is its registration and a line in the catalog list in `claude-code-mcp.el`.

## Workflow

- **Test-first.** Add/extend ERT tests before or alongside each feature. Fixtures under `test/fixtures/` are real (redacted) data.
- **Verify with `make`:** `make compile` (warnings are errors) and `make test` must stay green. They run automatically via the `Stop` hook (`scripts/compile-and-test.sh`).
- **Docs.** `DESIGN.md` stays high-level: concepts, decisions and trade-offs, with no internal symbols, CLI internals or version stamps. Implementation detail and CLI or Emacs behavior go in docstrings and comments next to the code, and only where the code does not already say it. Update `DESIGN.md`, `README.md`, docstrings and comments in the same change that makes them stale.

## Debugging with a real instance

`make test` never launches `claude` — it runs pure logic against fixtures. To exercise the live spawn/kill lifecycle, run `make integration` (needs Ghostel's native module and a logged-in CLI; skipped by `make test` and CI).

**Gotcha for anyone debugging spawning from inside a Claude Code session** (e.g. you, a Claude Code agent, driving Emacs to test this package): a running `claude` exports `CLAUDE_CODE_CHILD_SESSION` (among other `CLAUDE_*` variables) to its subprocesses. An interactive `claude` spawned with it set is a **nested child**: it does NOT create its own top-level session — no `sessions/*.json`, no transcript — so the view shows nothing and spawning looks broken. Strip it before spawning. The integration test does this via `claude-code-tests--with-top-level-env`; an ad-hoc `emacs --batch` harness needs `env -u CLAUDE_CODE_CHILD_SESSION …`. A normally launched Emacs never has these variables, so **production code deliberately leaves the nesting markers alone** — this is a test/debug concern only.
