;;; claude-code.el --- Orchestrate Claude Code sessions from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lautaro Emanuel

;; Author: Lautaro Emanuel
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (ghostel "0"))
;; Keywords: tools, processes
;; URL: https://github.com/emlautarom1/claude-code.el

;;; Commentary:

;; Orchestrate and manage Claude Code CLI sessions from Emacs, scoped to the
;; current `project.el' project.  Running instances are hosted in `ghostel'
;; terminal buffers.  A "claude sessions" view lists every session of a project
;; (alive and dead) and offers spawn/resume/kill/rename/inspect actions.
;;
;; The package is split into a programmatic model (plain functions operating on
;; `claude-code-session' structs) and a view layer.  All knowledge of the
;; on-disk `~/.claude' layout is confined to the "Storage adapter" section;
;; those formats are Claude internals and are documented in
;; docs/storage-model.md.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'tabulated-list)
(require 'transient)

;; Ghostel is required lazily in the spawn path (see `claude-code-spawn').
;; Declaring its API here keeps the byte-compiler happy without the native
;; module being present, so the package compiles and tests in CI.
(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function ghostel-send-key "ghostel" (key-name &optional mods))
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function ghostel-send-C-c "ghostel" ())
(defvar ghostel--pid)
(defvar ghostel--process)
(defvar ghostel-exit-functions)


;;;; Customization

(defgroup claude-code nil
  "Orchestrate Claude Code CLI sessions from Emacs."
  :group 'tools
  :prefix "claude-code-")

(defcustom claude-code-cli "claude"
  "Executable used to launch the Claude Code CLI."
  :type 'string)

(defcustom claude-code-config-dir
  (or (getenv "CLAUDE_CONFIG_DIR") (expand-file-name "~/.claude"))
  "Directory where Claude Code stores its state.
Mirrors the CLI's own `$CLAUDE_CONFIG_DIR' resolution."
  :type 'directory)


;;;; Storage adapter
;;
;; Everything in this section depends on Claude Code's internal, version-volatile
;; on-disk layout under `claude-code-config-dir'.  Keep that knowledge HERE only;
;; the rest of the package must speak in `claude-code-session' structs.  See
;; docs/storage-model.md for the documented formats.

(defun claude-code--encode-cwd (path)
  "Encode absolute PATH into its Claude project-directory name.
Claude replaces every slash and dot in the absolute working directory with a
hyphen.  This mapping is lossy and MUST NOT be inverted; read the real cwd from
session data instead."
  (replace-regexp-in-string
   "[/.]" "-" (directory-file-name (expand-file-name path))))

(defun claude-code--project-dir (cwd)
  "Return the transcript directory under `claude-code-config-dir' for CWD."
  (expand-file-name (claude-code--encode-cwd cwd)
                    (expand-file-name "projects" claude-code-config-dir)))

(defun claude-code--live-status-table ()
  "Parse the per-process files under sessions/ into a hash table.
The table is keyed by session id; each value is a plist with keys
:pid, :cwd, :name, :kind, :status and :waiting-for.  This is pure
parsing of the files Claude writes for every running instance;
process liveness is decided by the caller.  A missing status field
yields a nil :status rather than an error."
  (let ((dir (expand-file-name "sessions" claude-code-config-dir))
        (table (make-hash-table :test 'equal)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.json\\'"))
        (ignore-errors
          (let* ((obj (with-temp-buffer
                        (insert-file-contents file)
                        (json-parse-buffer :object-type 'hash-table)))
                 (id (gethash "sessionId" obj)))
            (when id
              (puthash id
                       (list :pid (gethash "pid" obj)
                             :cwd (gethash "cwd" obj)
                             :name (gethash "name" obj)
                             :kind (gethash "kind" obj)
                             :status (gethash "status" obj)
                             :waiting-for (gethash "waitingFor" obj))
                       table))))))
    table))

(defvar claude-code--transcript-cache (make-hash-table :test 'equal)
  "Cache mapping a transcript file to (MTIME . FIELDS).
Transcripts are append-only, so an unchanged modification time means
the extracted fields are still valid.")

(defun claude-code--json-line-field (regexp field)
  "Return FIELD of the last line in the current buffer matching REGEXP.
Point is moved.  Returns nil when no matching line parses."
  (goto-char (point-max))
  (when (re-search-backward regexp nil t)
    (let ((line (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))))
      (ignore-errors (gethash field (json-parse-string line))))))

(defun claude-code--read-transcript-fields (file)
  "Read the title and last-prompt fields from transcript FILE.
A user-set custom title (what `/rename' writes) wins over Claude's generated
title; only when there is no custom title does the last `ai-title' apply."
  (with-temp-buffer
    (insert-file-contents file)
    (list :title
          (or (claude-code--json-line-field
               "\"type\"[[:space:]]*:[[:space:]]*\"custom-title\"" "customTitle")
              (claude-code--json-line-field
               "\"type\"[[:space:]]*:[[:space:]]*\"ai-title\"" "aiTitle"))
          :last-prompt
          (claude-code--json-line-field
           "\"type\"[[:space:]]*:[[:space:]]*\"last-prompt\"" "lastPrompt"))))

(defun claude-code--transcript-fields (file)
  "Return a plist of (:id :title :last-prompt) for transcript FILE.
The id is the file's base name (the session id).  Results are cached
by FILE's modification time."
  (let ((mtime (file-attribute-modification-time (file-attributes file)))
        (cached (gethash file claude-code--transcript-cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let ((fields (cons :id (cons (file-name-base file)
                                    (claude-code--read-transcript-fields file)))))
        (puthash file (cons mtime fields) claude-code--transcript-cache)
        fields))))

(defun claude-code--project-transcripts (cwd)
  "Return transcript descriptors for project CWD and its worktrees.
Each descriptor is a plist with keys :id, :title, :last-prompt,
:transcript (absolute file) and :worktree-p.  Worktrees are the
transcript directories Claude creates under CWD's .claude/worktrees;
they are matched by their encoded-directory prefix."
  (let* ((projects (expand-file-name "projects" claude-code-config-dir))
         (base (claude-code--encode-cwd cwd))
         (wt-prefix (concat base "--claude-worktrees-"))
         (result '()))
    (when (file-directory-p projects)
      (dolist (name (directory-files projects nil nil t))
        (let ((worktree-p (string-prefix-p wt-prefix name)))
          (when (or (equal name base) worktree-p)
            (let ((dir (expand-file-name name projects)))
              (when (file-directory-p dir)
                (dolist (file (directory-files dir t "\\.jsonl\\'"))
                  (push (append (claude-code--transcript-fields file)
                                (list :transcript file :worktree-p worktree-p))
                        result))))))))
    (nreverse result)))

(provide 'claude-code)
;;; claude-code.el ends here
