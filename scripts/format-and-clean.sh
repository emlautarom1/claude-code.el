#!/usr/bin/env bash
# Format Emacs Lisp: strip trailing whitespace and reindent.
#
# Plain mode: formats all tracked *.el files.
# --hook mode: Claude Code `PostToolUse` hook; reads the tool JSON on stdin and
# formats only the edited file, and only when it is an *.el file.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

hook=0
[[ "${1:-}" == "--hook" ]] && hook=1

files=()
if [[ $hook -eq 1 ]]; then
  json=$(cat)
  f=$(printf '%s' "$json" \
    | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [[ -n "$f" ]] && files+=("$f")
else
  # Tracked and untracked (but not ignored) Emacs Lisp files.
  while IFS= read -r f; do files+=("$f"); done \
    < <(git ls-files --cached --others --exclude-standard '*.el')
fi

emacs_bin="${EMACS:-emacs}"
for f in "${files[@]}"; do
  [[ "$f" == *.el ]] || continue
  [[ -f "$f" ]] || continue
  "$emacs_bin" -Q --batch \
    --eval "(progn
              (find-file \"$f\")
              (delete-trailing-whitespace)
              (indent-region (point-min) (point-max))
              (when (buffer-modified-p) (save-buffer)))" 2>/dev/null
done
exit 0
