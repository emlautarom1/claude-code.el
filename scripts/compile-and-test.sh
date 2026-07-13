#!/usr/bin/env bash
# Byte-compile and run the ERT suite.
#
# Plain mode: prints output, exits non-zero on failure.
# --hook mode: used as a Claude Code `Stop` hook; on failure it exits 2 so the
# session is blocked from finishing until compile+test are green again.
#
# Load path: this delegates to `make`, which uses only `-L .` (and `-L test`).
# Unlike claude-code-ide.el's script we do NOT probe straight/elpa for
# dependencies, because we have no external COMPILE-time deps: `transient`,
# `cl-lib`, `project` and `tabulated-list` are built into Emacs 30, and `ghostel`
# is declared with `declare-function` and required lazily, so it is never needed
# to byte-compile or to run the unit tests. Warnings are promoted to errors
# instead of being suppressed. Only `make integration` needs a real `ghostel`,
# and it loads it via `package-initialize`.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

hook=0
[[ "${1:-}" == "--hook" ]] && hook=1

out=$(make compile test 2>&1)
status=$?

if [[ $status -ne 0 ]]; then
  echo "$out" >&2
  if [[ $hook -eq 1 ]]; then
    echo "claude-code.el: compile/test FAILED -- fix before finishing." >&2
    exit 2
  fi
  exit 1
fi

[[ $hook -eq 0 ]] && echo "$out"
exit 0
