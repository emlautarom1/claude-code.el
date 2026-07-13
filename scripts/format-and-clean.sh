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

emacs_bin="${EMACS:-emacs}"

files=()
if [[ $hook -eq 1 ]]; then
  # Parse the tool JSON with Emacs itself (a real JSON parser) rather than a
  # brittle `sed' regex: the payload travels via an env var, and we read exactly
  # tool_input.file_path.  This is robust to escaped quotes and to "file_path"
  # appearing elsewhere in the payload.
  json=$(cat)
  f=$(CC_HOOK_JSON="$json" "$emacs_bin" -Q --batch --eval '
    (let* ((o (ignore-errors
                (json-parse-string (getenv "CC_HOOK_JSON")
                                   :object-type (quote hash-table))))
           (ti (and o (gethash "tool_input" o)))
           (fp (and ti (gethash "file_path" ti))))
      (when (stringp fp) (princ fp)))' 2>/dev/null)
  [[ -n "$f" ]] && files+=("$f")
else
  # Tracked and untracked (but not ignored) Emacs Lisp files.
  while IFS= read -r f; do files+=("$f"); done \
    < <(git ls-files --cached --others --exclude-standard '*.el')
fi
for f in "${files[@]}"; do
  # Only touch real `.el' files whose path has no shell/Elisp-hostile characters
  # (quotes, spaces, backslashes, `$', backticks, newlines).  Belt to the braces
  # of the environment-variable hand-off below.
  [[ "$f" =~ ^[A-Za-z0-9._/-]+\.el$ ]] || continue
  [[ -f "$f" ]] || continue
  # Pass the filename as data through the environment and read it back inside
  # Emacs with `getenv'.  The `--eval' form is a fixed literal, so a filename can
  # never be interpolated into the Elisp string and break out of it (a name
  # containing a quote, backslash, or newline would otherwise inject code).
  CC_FMT_FILE="$f" "$emacs_bin" -Q --batch \
    --eval '(with-current-buffer (find-file-noselect (getenv "CC_FMT_FILE"))
              (delete-trailing-whitespace)
              (indent-region (point-min) (point-max))
              (when (buffer-modified-p) (save-buffer)))' 2>/dev/null
done
exit 0
