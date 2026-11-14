# claude-code.el

Emacs orchestration tool for the Claude Code CLI. `DESIGN.md` holds the concepts, the architecture and the design decisions; changes follow it.

## Code

- **Keep it simple.** When a behavior needs a long explanation, simplify the behavior.
- **Emacs 30+ only.** No compatibility shims, feature detection or obsolete aliases.
- **Ghostel stays lazy:** `declare-function` at the top, `require` where it is used, so the package compiles and tests without its native module.
- **Use what Emacs already has.** Built-in functions, Emacs hooks, modes and the conventions of built-in packages (Dired, IBuffer, Proced) come before a design of our own; check how they solve the problem first.
- **State lives in memory, in the package's model,** updated from events. Don't spread it across buffer-locals and globals.
- **Keep IO low:** read only the data that it's actually needed, share it across calls, and avoid re-reading data that has not changed. This is particularly important when evaluating projects over TRAMP.
- **Don't add timers, polling, caches, advice, or files of our own** (temp, journal or marker files). If only such a design is accurate present it to the user and ask for confirmation first.
- **No new concepts.** Reuse an existing identifier, term or mechanism before adding one, and prefer one mechanism for local and remote hosts over one each.
- **Design for the expected case.** These hold and need no guards, tests or docs: PIDs are not reused; a resolved CLI launches; a session runs in at most one instance; a dtach socket has at most one client; hosts run Linux, and remote ones are reached by TRAMP over SSH. Ask before handling any other edge case.

## Tests

- Test core behavior a user would notice breaking, not rendering, keymaps, window placement or configuration defaults.
- Drive public operations and assert single facts (a flag, a key, a stable substring), never whole argument lists, fixture counts, private state or stubbed private helpers.
- Cover a use case that spans several features with one scenario or integration test rather than many unit tests. Extend existing tests and reuse the test helpers before writing new ones.
- Tests are hermetic: real (redacted) fixtures, the fake CLI and TRAMP's mock host; no real file watches, network or config dir.
- `make integration` runs the live tests against a real `claude` (needs Ghostel's native module and a logged-in CLI).

## Docs

- `DESIGN.md` stays high-level: concepts, decisions and trade-offs, with no internal symbols, CLI internals or version stamps.
- Docstrings and comments say only what the code does not. A comment explains a non-obvious why; when in doubt, leave it out.
- No cross-references between documents. Update docs in the same change that makes them stale.
- An MCP tool's contract lives in its `:description`.

## Git

- Commit on the current branch; never create one unless asked.
- One commit per logical change. Land review fixes as fixups or commits of their own, never as one "review fixes" commit.
- From a review, apply doc, style and de-duplication fixes directly; bring correctness, scope and coverage findings to the user.

## Spawning `claude` from a Claude session

A running `claude` exports `CLAUDE_CODE_CHILD_SESSION`, and a `claude` spawned with it set is a nested child that writes no `sessions/*.json` or transcript, so spawning looks broken. Strip it: `env -u CLAUDE_CODE_CHILD_SESSION …`, or `claude-code-tests--with-top-level-env` in tests. Production code leaves it alone, since a normally launched Emacs never has it.
