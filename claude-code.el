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


;;;; Model
;;
;; The rest of the package works with `claude-code-session' structs produced by
;; `claude-code-sessions'.  A session has one of three liveness states
;; (`claude-code--session-liveness'): "alive" when Emacs manages a live Ghostel
;; instance for it, "external" when a `claude' process runs it outside Emacs, and
;; "dead" when no process is running it at all.

(cl-defstruct (claude-code-session (:constructor claude-code-session--create)
                                   (:copier nil))
  "A Claude Code session, alive or dead.
ID is the session UUID.  ALIVE-P is non-nil when Emacs manages a live
instance, in which case BUFFER holds the Ghostel buffer and PID its
child process.  STATUS is Claude's native `busy'/`idle'/`waiting'
string (alive sessions only), with WAITING-FOR set while waiting.
EXTERNAL-P flags a session whose process is running outside Emacs,
so it must not be resumed or deleted.  TITLE and
LAST-PROMPT come from the transcript; WORKTREE-P marks worktree
sessions; TRANSCRIPT is the absolute `.jsonl' path."
  id cwd name status waiting-for alive-p pid buffer kind worktree-p
  title last-prompt started-at transcript external-p)

(defvar claude-code--managed (make-hash-table :test 'equal)
  "Hash of session id -> plist describing an Emacs-managed instance.
Keys: :buffer (the Ghostel buffer), :origin (project root the instance
was launched from, normalised with `directory-file-name'), :cwd and
:worktree.")

(defun claude-code--session-process (buffer)
  "Return BUFFER's live Ghostel process, or nil."
  (and (buffer-live-p buffer)
       (let ((proc (buffer-local-value 'ghostel--process buffer)))
         (and (process-live-p proc) proc))))

(defun claude-code--live-managed (project-root)
  "Return an alist of (ID . BUFFER) for live managed instances of PROJECT-ROOT."
  (let ((root (directory-file-name (expand-file-name project-root)))
        (out '()))
    (maphash (lambda (id plist)
               (when (and (equal (plist-get plist :origin) root)
                          (claude-code--session-process (plist-get plist :buffer)))
                 (push (cons id (plist-get plist :buffer)) out)))
             claude-code--managed)
    out))

(defun claude-code--pid-live-p (pid)
  "Return non-nil when integer PID is a currently running process."
  (and (integerp pid) (memql pid (list-system-processes)) t))

(defun claude-code--session-liveness (session)
  "Return SESSION's liveness: `alive', `external', or `dead'.
`alive' means Emacs manages a live instance for it; `external' means a
`claude' process is running it outside Emacs; `dead' means no process is
running it at all.  This is the single classifier the view builds on."
  (cond ((claude-code-session-alive-p session) 'alive)
        ((claude-code-session-external-p session) 'external)
        (t 'dead)))

(defun claude-code-sessions (project-root)
  "Return the list of `claude-code-session' structs for PROJECT-ROOT.
A session is alive when Emacs manages a live instance for it.  Every other
transcript on disk belongs to a session Emacs does not manage: when a
`claude' process is still running it outside Emacs the session is flagged
`claude-code-session-external-p' (an external session); otherwise no process
is running it and it is dead."
  (let* ((root (directory-file-name (expand-file-name project-root)))
         (live (claude-code--live-status-table))
         (managed (claude-code--live-managed root))
         (transcripts (claude-code--project-transcripts root))
         (transcript-of (lambda (id)
                          (seq-find (lambda (d) (equal (plist-get d :id) id))
                                    transcripts)))
         (seen (make-hash-table :test 'equal))
         (sessions '()))
    (pcase-dolist (`(,id . ,buf) managed)
      (let ((info (gethash id live))
            (tr (funcall transcript-of id))
            (reg (gethash id claude-code--managed)))
        (puthash id t seen)
        (push (claude-code-session--create
               :id id :alive-p t :buffer buf
               :pid (and (buffer-live-p buf)
                         (buffer-local-value 'ghostel--pid buf))
               :cwd (or (plist-get info :cwd) (plist-get reg :cwd))
               :name (plist-get info :name)
               :status (plist-get info :status)
               :waiting-for (plist-get info :waiting-for)
               :kind (plist-get info :kind)
               :worktree-p (or (plist-get tr :worktree-p)
                               (and (plist-get reg :worktree) t))
               :title (plist-get tr :title)
               :last-prompt (plist-get tr :last-prompt)
               :transcript (plist-get tr :transcript))
              sessions)))
    (dolist (tr transcripts)
      (let ((id (plist-get tr :id)))
        (unless (gethash id seen)
          (let ((info (gethash id live)))
            (push (claude-code-session--create
                   :id id :alive-p nil
                   :external-p (and info
                                    (claude-code--pid-live-p (plist-get info :pid)))
                   :cwd (or (plist-get info :cwd) root)
                   :worktree-p (plist-get tr :worktree-p)
                   :title (plist-get tr :title)
                   :last-prompt (plist-get tr :last-prompt)
                   :transcript (plist-get tr :transcript))
                  sessions)))))
    (nreverse sessions)))

(defun claude-code--process-snapshot ()
  "Return (ATTRS . CHILDREN) hashes of the current process table.
ATTRS maps a pid to its `process-attributes' alist; CHILDREN maps a
pid to the list of its child pids.  Building this once lets several
subtrees be summed without rescanning the system each time."
  (let ((attrs (make-hash-table :test 'eql))
        (children (make-hash-table :test 'eql)))
    (dolist (p (list-system-processes))
      (let ((a (process-attributes p)))
        (when a
          (puthash p a attrs)
          (when-let* ((ppid (alist-get 'ppid a)))
            (push p (gethash ppid children))))))
    (cons attrs children)))

(defun claude-code--process-usage (pid &optional snapshot)
  "Return (CPU . RSS) summed over PID's process subtree, or nil.
SNAPSHOT is a table from `claude-code--process-snapshot'; one is built
when omitted.  CPU is a percentage that may be a lifetime average
depending on the platform; RSS is in kibibytes."
  (when (integerp pid)
    (let* ((snap (or snapshot (claude-code--process-snapshot)))
           (attrs (car snap))
           (children (cdr snap))
           (cpu 0.0) (rss 0) (stack (list pid)))
      (while stack
        (let* ((p (pop stack)) (a (gethash p attrs)))
          (when a
            (cl-incf cpu (or (alist-get 'pcpu a) 0.0))
            (cl-incf rss (or (alist-get 'rss a) 0))
            (setq stack (nconc (copy-sequence (gethash p children)) stack)))))
      (cons cpu rss))))


;;;; Operations

(cl-defun claude-code--build-args
    (&key session-id resume prompt name worktree model)
  "Build the argument list for the `claude' CLI.

When RESUME is non-nil it is a session id to resume, and it is returned as
\"-r ID\" ignoring all new-session arguments.

Otherwise a new session is described:
SESSION-ID is passed as \"--session-id\" so the caller can map the instance to
its session up front.  NAME sets the display name (\"-n\").  WORKTREE, when t,
requests a new worktree (\"-w\"); when a string, names it (\"-w NAME\").  MODEL
sets \"--model\".  PROMPT, when a non-empty string, is appended as the trailing
positional argument."
  (if resume
      (list "-r" resume)
    (let (args)
      (when session-id
        (setq args (append args (list "--session-id" session-id))))
      (when name
        (setq args (append args (list "-n" name))))
      (when worktree
        (setq args (append args (if (stringp worktree)
                                    (list "-w" worktree)
                                  (list "-w")))))
      (when model
        (setq args (append args (list "--model" model))))
      (when (and prompt (> (length prompt) 0))
        (setq args (append args (list prompt))))
      args)))

(defcustom claude-code-buffer-name-function #'claude-code--default-buffer-name
  "Function that names the buffer hosting a new instance.
Called with the project root and the requested name (or nil); must
return a string.  Name clashes are resolved by `generate-new-buffer'."
  :type 'function)

(defun claude-code--default-buffer-name (root name)
  "Return a buffer name for an instance in ROOT with display NAME."
  (format "*claude:%s*" (or name (file-name-nondirectory root))))

(defun claude-code--new-uuid ()
  "Return a random RFC-4122 version-4 UUID string."
  (let ((s (md5 (format "%d-%d-%s-%d"
                        (random most-positive-fixnum)
                        (emacs-pid)
                        (current-time-string)
                        (random most-positive-fixnum)))))
    (format "%s-%s-4%s-%s%s-%s"
            (substring s 0 8) (substring s 8 12) (substring s 13 16)
            (nth (random 4) '("8" "9" "a" "b"))
            (substring s 17 20) (substring s 20 32))))

(defun claude-code--on-exit (buffer &optional _event)
  "Unregister the managed session hosted in BUFFER when its process exits."
  (let (dead)
    (maphash (lambda (id plist)
               (when (eq (plist-get plist :buffer) buffer) (push id dead)))
             claude-code--managed)
    (dolist (id dead) (remhash id claude-code--managed))))

(defun claude-code--register (id buffer origin cwd worktree)
  "Record instance ID hosted in BUFFER, launched from ORIGIN with CWD, WORKTREE."
  (add-hook 'ghostel-exit-functions #'claude-code--on-exit)
  (puthash id (list :buffer buffer :origin origin :cwd cwd :worktree worktree)
           claude-code--managed)
  id)

(defun claude-code--buffer (session)
  "Return SESSION's live buffer or signal a `user-error'."
  (let ((buffer (claude-code-session-buffer session)))
    (unless (buffer-live-p buffer)
      (user-error "Session %s has no live buffer" (claude-code-session-id session)))
    buffer))

;;;###autoload
(cl-defun claude-code-spawn (project-root &key prompt worktree model name)
  "Spawn a new Claude Code instance for PROJECT-ROOT; return its buffer.
PROMPT is an optional initial prompt (passed as the positional argument).
WORKTREE requests a git worktree: t for an auto-named one, or a string to
name it.  MODEL and NAME set the model and display name.  The session id is
generated internally and is not exposed."
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name project-root)))
         (id (claude-code--new-uuid))
         (args (claude-code--build-args :session-id id :prompt prompt
                                        :worktree worktree :model model
                                        :name name))
         (default-directory (file-name-as-directory root))
         (buffer (generate-new-buffer
                  (funcall claude-code-buffer-name-function root name))))
    (ghostel-exec buffer claude-code-cli args)
    (claude-code--register id buffer root root worktree)
    buffer))

;;;###autoload
(defun claude-code-resume (project-root id)
  "Resume session ID for PROJECT-ROOT in a new instance; return its buffer."
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name project-root)))
         (args (claude-code--build-args :resume id))
         (default-directory (file-name-as-directory root))
         (buffer (generate-new-buffer
                  (funcall claude-code-buffer-name-function root nil))))
    (ghostel-exec buffer claude-code-cli args)
    (claude-code--register id buffer root root nil)
    buffer))

(defun claude-code-kill (session)
  "Kill the running instance of SESSION and its buffer."
  (unless (claude-code-session-alive-p session)
    (user-error "Session %s is not alive" (claude-code-session-id session)))
  (let ((buffer (claude-code-session-buffer session)))
    (remhash (claude-code-session-id session) claude-code--managed)
    (when (buffer-live-p buffer)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun claude-code-delete (session)
  "Delete dead SESSION's transcript from disk.
Refuses alive sessions and sessions running outside Emacs."
  (when (claude-code-session-alive-p session)
    (user-error "Refusing to delete an alive session; kill it first"))
  (when (claude-code-session-external-p session)
    (user-error "Session %s is running outside Emacs"
                (claude-code-session-id session)))
  (let ((file (claude-code-session-transcript session)))
    (unless (and file (file-exists-p file))
      (user-error "No transcript on disk for session %s"
                  (claude-code-session-id session)))
    (delete-file file)
    (remhash file claude-code--transcript-cache)))

(defun claude-code-send-text (session text &optional submit)
  "Send TEXT to SESSION's instance, submitting with RET when SUBMIT is non-nil.
Any newline in TEXT is delivered with a bracketed paste, so Claude's prompt
receives it as a literal newline within a single message.  Sending the newline
as a raw keystroke instead would be read as RET and submit the text early, so
only SUBMIT sends the RET that actually submits."
  (require 'ghostel)
  (with-current-buffer (claude-code--buffer session)
    (if (string-search "\n" text)
        (ghostel-paste-string text)
      (ghostel-send-string text))
    (when submit (ghostel-send-key "return"))))

(defun claude-code-rename (session name)
  "Rename SESSION to NAME by sending a /rename command to its instance.
The new name is not cached: Claude records it (in its sessions file and
transcript) and the next refresh reads it back through
`claude-code--session-display-name', so there is one source of truth."
  (unless (claude-code-session-alive-p session)
    (user-error "Can only rename an alive session"))
  (claude-code-send-text session (format "/rename %s" name) t))

(defun claude-code-interrupt (session)
  "Send an interrupt signal (SIGINT) to SESSION's instance."
  (require 'ghostel)
  (with-current-buffer (claude-code--buffer session)
    (ghostel-send-C-c)))

(defun claude-code-focus (session)
  "Display and select SESSION's instance buffer."
  (pop-to-buffer (claude-code--buffer session)))

(provide 'claude-code)
;;; claude-code.el ends here
