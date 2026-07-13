# claude-code.el — project conventions

Emacs orchestration tool for the Claude Code CLI. Read `docs/` for the domain
model: `docs/glossary.md`, `docs/storage-model.md`, `docs/architecture.md`.

## Hard rules

- **Target Emacs 30+ only.** No backwards-compatibility code: no `defalias`/`fset`
  shims, no feature-detection fallbacks, no obsolete aliases.
- **No "history" comments.** Never describe how code "used to" work or that
  something "replaces" a prior approach — Git holds the history.
- **One dependency only: `ghostel`.** Everything else must be built into Emacs
  (`cl-lib`, `project`, `tabulated-list`, `transient`, `json`). `ghostel` is
  loaded lazily and referenced via `declare-function`, so the package
  byte-compiles and tests without its native module present.
- **Single file:** all code lives in `claude-code.el`; tests in
  `test/claude-code-tests.el`.
- **Naming:** `claude-code-` for public symbols, `claude-code--` for internals.

## Architecture

- **Model/view separation.** Every fundamental operation (spawn, resume, kill,
  delete, rename, query) is a plain function usable from Elisp without the UI.
- **Storage adapter.** All knowledge of the `~/.claude` on-disk layout lives in
  ONE clearly-marked section ("Storage adapter"). Those formats are Claude
  internals and version-volatile — keep them quarantined and documented in
  `docs/storage-model.md`. The rest of the code speaks only
  `claude-code-session` structs.

## Workflow

- **Test-first.** Add/extend ERT tests before or alongside each feature.
  Fixtures under `test/fixtures/` are real (redacted) data.
- **Verify with `make`:** `make compile` (warnings are errors) and `make test`
  must stay green. They run automatically via the `Stop` hook
  (`scripts/compile-and-test.sh`).
- Keep `docs/` current whenever behavior or the storage model changes.

## Debugging with a real instance

`make test` never launches `claude` — it runs pure logic against fixtures. To
exercise the live spawn/kill lifecycle, run `make integration` (needs Ghostel's
native module and a logged-in CLI; skipped by `make test` and CI).

**Gotcha for anyone debugging spawning from inside a Claude Code session** (e.g.
you, a Claude Code agent, driving Emacs to test this package): a running
`claude` exports `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`,
`CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_SSE_PORT` and friends to mark its
subprocesses as **nested children**. A `claude` spawned with those set does NOT
create its own top-level session — no `sessions/*.json`, no transcript — so the
view shows nothing and spawning looks broken. Strip those variables before
spawning. The integration test does this via
`claude-code-tests--with-top-level-env`; an ad-hoc `emacs --batch` harness needs
`env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION …`. A normally launched Emacs
never has these variables, so **production code deliberately does not touch the
environment** — this is a test/debug concern only.
