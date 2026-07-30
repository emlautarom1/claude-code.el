;;; claude-code.el --- Orchestrate Claude Code sessions from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lautaro Emanuel

;; Author: Lautaro Emanuel
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (ghostel "0") (web-server "0.1.2"))
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

;; Ghostel is required lazily in the launch path (see `claude-code--launch').
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
(defvar ghostel-buffer-name-function)

;; The MCP server lives in `claude-code-mcp.el', required lazily in the launch
;; path (see `claude-code--launch').  Declaring its one entry point here keeps
;; the byte-compiler happy without pulling the MCP file (and its `web-server'
;; dependency) in eagerly, and avoids a load cycle.  Its teardown is its own
;; concern: it hooks `claude-code-last-instance-exit-hook'.
(declare-function claude-code--mcp-cli-args "claude-code-mcp" (id))


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

(defun claude-code--projects-dir ()
  "Return the directory holding every project's transcript directory."
  (expand-file-name "projects" claude-code-config-dir))

(defun claude-code--project-dir (cwd)
  "Return the transcript directory under `claude-code-config-dir' for CWD."
  (expand-file-name (claude-code--encode-cwd cwd) (claude-code--projects-dir)))

(defun claude-code--live-status-table ()
  "Parse the per-process files under sessions/ into a hash table.
The table is keyed by session id; each value is a plist with keys
:pid, :cwd, :status and :waiting-for.  This is pure parsing of
the files Claude writes for every running instance; process liveness
is decided by the caller.  A missing status field yields a nil :status
rather than an error."
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
                             :status (gethash "status" obj)
                             :waiting-for (gethash "waitingFor" obj))
                       table))))))
    table))

(defvar claude-code--transcript-cache (make-hash-table :test 'equal)
  "Cache mapping a transcript file to (MTIME . FIELDS).
Transcripts are append-only, so an unchanged modification time means
the extracted fields are still valid.")

(defun claude-code--json-line-field (regexp field)
  "Return FIELD from the newest line in the current buffer matching REGEXP.
Scans backward from the end and returns FIELD from the first match whose line
parses as JSON with a non-nil FIELD, skipping earlier-encountered matches that
lack it -- e.g. a line where REGEXP hits FIELD inside a nested value rather than
as a top-level key.  Point is moved.  Returns nil when no such line exists."
  (goto-char (point-max))
  (let (result)
    (while (and (not result) (re-search-backward regexp nil t))
      (let* ((line (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position)))
             (obj (ignore-errors (json-parse-string line))))
        (when obj (setq result (gethash field obj)))
        (goto-char (line-beginning-position))))
    result))

(defun claude-code--read-transcript-fields (file worktree-p)
  "Read the title, last-prompt, worktree-path and last-active fields from FILE.
A user-set custom title (what `/rename' writes) wins over Claude's generated
title; only when there is no custom title does the last `ai-title' apply.
WORKTREE-P asks for the lossless `worktreePath' of the `worktree-state' line --
the real cwd of a worktree session even when it is dead and has no live sessions
file to read.  Only a worktree transcript carries that line, so for any other
transcript the scan is skipped rather than reading the whole file for a
guaranteed miss.
LAST-ACTIVE is the time of the newest line carrying a real `timestamp' -- the
last genuine activity -- or nil when the transcript has no timestamped line."
  (with-temp-buffer
    (insert-file-contents file)
    (list :title
          (or (claude-code--json-line-field
               "\"type\"[[:space:]]*:[[:space:]]*\"custom-title\"" "customTitle")
              (claude-code--json-line-field
               "\"type\"[[:space:]]*:[[:space:]]*\"ai-title\"" "aiTitle"))
          :last-prompt
          (claude-code--json-line-field
           "\"type\"[[:space:]]*:[[:space:]]*\"last-prompt\"" "lastPrompt")
          :worktree-path
          (when worktree-p
            (let ((ws (claude-code--json-line-field
                       "\"type\"[[:space:]]*:[[:space:]]*\"worktree-state\""
                       "worktreeSession")))
              (and (hash-table-p ws) (gethash "worktreePath" ws))))
          :last-active
          (let ((ts (claude-code--json-line-field
                     "\"timestamp\"[[:space:]]*:" "timestamp")))
            (and (stringp ts) (ignore-errors (date-to-time ts)))))))

(defun claude-code--transcript-fields (file &optional worktree-p)
  "Return a plist of transcript FILE's cached fields.
The keys are :id (FILE's base name, the session id), :title, :last-prompt,
:worktree-path (read only when WORKTREE-P is non-nil, since only a worktree
transcript carries one), and :last-active (the newest genuine activity, from the
last timestamped line, falling back to FILE's modification time only when the
transcript has no timestamped line at all).  Cached by FILE's modification
time."
  (let ((mtime (file-attribute-modification-time (file-attributes file)))
        (cached (gethash file claude-code--transcript-cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let ((fields (cons :id (cons (file-name-base file)
                                    (claude-code--read-transcript-fields
                                     file worktree-p)))))
        (unless (plist-get fields :last-active)
          (setq fields (plist-put fields :last-active mtime)))
        (puthash file (cons mtime fields) claude-code--transcript-cache)
        fields))))

(defun claude-code--delete-transcript (file)
  "Remove transcript FILE from disk along with its cached fields."
  (delete-file file)
  (remhash file claude-code--transcript-cache))

(defun claude-code--project-transcripts (cwd)
  "Return transcript descriptors for project CWD and its worktrees.
Each descriptor is a plist with keys :id, :title, :last-prompt,
:worktree-path, :last-active, :transcript (absolute file) and :worktree-p.
Worktrees are the transcript directories Claude creates under CWD's
.claude/worktrees; they are matched by their encoded-directory prefix.  A
worktree's real cwd comes from the lossless :worktree-path in its transcript,
never by decoding the encoded (lossy) directory name."
  (let* ((projects (claude-code--projects-dir))
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
                  (push (append (claude-code--transcript-fields file worktree-p)
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
ID is the session UUID and CWD its absolute working directory.  ALIVE-P is
non-nil when Emacs manages a live instance, in which case BUFFER holds the
Ghostel buffer and PID its child process.  STATUS is Claude's native
`busy'/`idle'/`waiting' string (alive sessions only), with WAITING-FOR set
while waiting.  EXTERNAL-P flags a session whose process is running outside
Emacs, so it must not be resumed or deleted.  TITLE and LAST-PROMPT come from
the transcript and, via `claude-code--session-display-name', are the session's
only display-name sources; WORKTREE-P marks worktree sessions; TRANSCRIPT is
the absolute `.jsonl' path.  LAST-ACTIVE is the session's last genuine activity,
taken from the newest timestamped transcript line."
  id cwd status waiting-for alive-p pid buffer worktree-p
  title last-prompt transcript external-p last-active)

(defvar claude-code--managed (make-hash-table :test 'equal)
  "Hash of session id -> plist describing an Emacs-managed instance.
Keys: :buffer (the Ghostel buffer), :origin (project root the instance
was launched from, normalised with `claude-code--normalize-root'), :cwd
and :worktree.")

(defun claude-code--normalize-root (path)
  "Return PATH as an absolute, symlink-resolved directory name.
Claude records a session's cwd as the real (symlink-resolved) path its process
reports, whereas Emacs `project-root' may hand back a symlinked path.  Resolving
with `file-truename' keeps the root we compute matching Claude's encoded
transcript directory, and keeps a spawned instance's `:origin' comparable to the
root a later query normalises the same way."
  (directory-file-name (file-truename (expand-file-name path))))

(defun claude-code--session-process (buffer)
  "Return BUFFER's live Ghostel process, or nil."
  (and (buffer-live-p buffer)
       (let ((proc (buffer-local-value 'ghostel--process buffer)))
         (and (process-live-p proc) proc))))

(defun claude-code--live-managed (project-root)
  "Return an alist of (ID . BUFFER) for live managed instances of PROJECT-ROOT."
  (let ((root (claude-code--normalize-root project-root))
        (out '()))
    (maphash (lambda (id plist)
               (when (and (equal (plist-get plist :origin) root)
                          (claude-code--session-process (plist-get plist :buffer)))
                 (push (cons id (plist-get plist :buffer)) out)))
             claude-code--managed)
    out))

(defun claude-code--pid-live-p (pid &optional pids)
  "Return non-nil when integer PID is a currently running process.
PIDS is a `list-system-processes' list read in advance, so a caller testing
several pids scans the process table once; it is read here when omitted.  This
is a bare membership test and does not verify the live process is the same
`claude' the sessions file recorded -- see docs/storage-model.md for the
PID-reuse trade-off that buys."
  (and (integerp pid) (memql pid (or pids (list-system-processes))) t))

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
  (let* ((root (claude-code--normalize-root project-root))
         (live (claude-code--live-status-table))
         (managed (claude-code--live-managed root))
         (transcripts (claude-code--project-transcripts root))
         (transcript-of (lambda (id)
                          (seq-find (lambda (d) (equal (plist-get d :id) id))
                                    transcripts)))
         (pids (list-system-processes))
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
               :cwd (or (plist-get info :cwd)
                        (plist-get tr :worktree-path)
                        (plist-get reg :cwd))
               :status (plist-get info :status)
               :waiting-for (plist-get info :waiting-for)
               :worktree-p (or (plist-get tr :worktree-p)
                               (and (plist-get reg :worktree) t))
               :title (plist-get tr :title)
               :last-prompt (plist-get tr :last-prompt)
               :transcript (plist-get tr :transcript)
               :last-active (plist-get tr :last-active))
              sessions)))
    (dolist (tr transcripts)
      (let ((id (plist-get tr :id)))
        (unless (gethash id seen)
          (let ((info (gethash id live)))
            (push (claude-code-session--create
                   :id id :alive-p nil
                   :external-p (and info
                                    (claude-code--pid-live-p
                                     (plist-get info :pid) pids))
                   :cwd (or (plist-get info :cwd)
                            (plist-get tr :worktree-path)
                            root)
                   :worktree-p (plist-get tr :worktree-p)
                   :title (plist-get tr :title)
                   :last-prompt (plist-get tr :last-prompt)
                   :transcript (plist-get tr :transcript)
                   :last-active (plist-get tr :last-active))
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
Nil means no usage is available: PID is not an integer, or the process
table holds no entry for it (a dead process, so a caller can tell it
apart from a live but idle one).  SNAPSHOT is a table from
`claude-code--process-snapshot'; one is built when omitted.  CPU is a
percentage that may be a lifetime average depending on the platform;
RSS is in kibibytes."
  (when (integerp pid)
    (let* ((snap (or snapshot (claude-code--process-snapshot)))
           (attrs (car snap))
           (children (cdr snap)))
      (when (gethash pid attrs)
        (let ((cpu 0.0) (rss 0) (stack (list pid)))
          (while stack
            (let* ((p (pop stack)) (a (gethash p attrs)))
              (when a
                (cl-incf cpu (or (alist-get 'pcpu a) 0.0))
                (cl-incf rss (or (alist-get 'rss a) 0))
                (setq stack (nconc (copy-sequence (gethash p children))
                                   stack)))))
          (cons cpu rss))))))

(defun claude-code--session-cwd (id)
  "Return the real working directory of the running instance for session ID.
Prefers the live `sessions/*.json' cwd (the actual worktree directory for a
worktree session), falls back to the registry `:cwd' (the project root the
instance was launched from), and is nil for an unknown id."
  (or (plist-get (gethash id (claude-code--live-status-table)) :cwd)
      (plist-get (gethash id claude-code--managed) :cwd)))


;;;; Operations

(cl-defun claude-code--build-args
    (&key session-id resume prompt worktree model mcp-args)
  "Build the argument list for the `claude' CLI.

When RESUME is non-nil it is a session id to resume, and it is returned as
\"-r ID\" ignoring all new-session arguments.

Otherwise a new session is described:
SESSION-ID is passed as \"--session-id\" so the caller can map the instance to
its session up front.  WORKTREE, when t, requests a new worktree (\"-w\"); when
a string, names it (\"-w NAME\").  MODEL sets \"--model\".  PROMPT, when a
non-empty string, is emitted last as a positional argument behind a \"--\"
option terminator.

MCP-ARGS is a list of extra CLI arguments (the MCP wiring built by
`claude-code--mcp-cli-args') placed with the other options, before the
terminator; this function keeps no MCP knowledge of its own."
  (if resume
      (append (list "-r" resume) mcp-args)
    (append (when session-id (list "--session-id" session-id))
            (when worktree
              (if (stringp worktree) (list "-w" worktree) (list "-w")))
            (when model (list "--model" model))
            mcp-args
            (unless (or (null prompt) (string-empty-p prompt))
              (list "--" prompt)))))

(defcustom claude-code-buffer-name-function #'claude-code--default-buffer-name
  "Function that seeds the name of the buffer hosting a new instance.
Called with the project root; must return a string.  This is only the
pre-title seed: once the instance reports a terminal title, Ghostel renames
the buffer via `claude-code--ghostel-buffer-name' (see
`claude-code--install-buffer-name-tracking').  Name clashes are resolved by
`generate-new-buffer'."
  :type 'function)

(defun claude-code--default-buffer-name (root)
  "Return a pre-title seed buffer name for an instance in ROOT."
  (format "*claude: %s*" (file-name-nondirectory (directory-file-name root))))

(defun claude-code--ghostel-buffer-name (title)
  "Name a managed instance buffer \"*claude: TITLE*\" from the terminal TITLE.
A buffer-local `ghostel-buffer-name-function' so Ghostel's own title tracking
drives the name — Claude sets the OSC 2 title, so no bookkeeping is needed
here.  Claude prefixes the title with a status indicator — a symbol glyph
\(a spinner frame while busy, an idle marker otherwise) and a space — in the
form \"<indicator> <title>\".  That leading run of symbol and whitespace
characters is stripped so only the title remains.  Declines (returns nil)
when nothing but the indicator is left, like `ghostel-buffer-name-by-title'."
  (when title
    (let ((clean (replace-regexp-in-string
                  "\\`[^[:alnum:][:space:]]+[[:space:]]+" "" title)))
      (unless (string= "" clean)
        (format "*claude: %s*" clean)))))

(defun claude-code--install-buffer-name-tracking (buffer)
  "Make BUFFER track its Claude terminal title as \"*claude: TITLE*\".
Installs `claude-code--ghostel-buffer-name' as a buffer-local
`ghostel-buffer-name-function'.  Must run after `ghostel-exec', whose
`ghostel-mode' switch would otherwise wipe the buffer-local binding."
  (with-current-buffer buffer
    (setq-local ghostel-buffer-name-function #'claude-code--ghostel-buffer-name)))

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

(defvar claude-code-last-instance-exit-hook nil
  "Hook run once the last managed instance has exited.
Lets a resource shared by every instance — the MCP server, say — be owned and
torn down by the layer that created it, without this one knowing about it.")

(defun claude-code--on-exit (buffer &optional _event)
  "Unregister the managed session hosted in BUFFER when its process exits.
Registered on `ghostel-exit-functions', which calls its functions with
\(BUFFER EVENT); the EVENT is unused here."
  (let (dead)
    (maphash (lambda (id plist)
               (when (eq (plist-get plist :buffer) buffer) (push id dead)))
             claude-code--managed)
    (dolist (id dead) (remhash id claude-code--managed))
    (when (zerop (hash-table-count claude-code--managed))
      (run-hooks 'claude-code-last-instance-exit-hook))))

(defun claude-code--register (id buffer origin cwd worktree)
  "Record instance ID hosted in BUFFER, launched from ORIGIN with CWD, WORKTREE."
  (add-hook 'ghostel-exit-functions #'claude-code--on-exit)
  (puthash id (list :buffer buffer :origin origin :cwd cwd :worktree worktree)
           claude-code--managed))

(defun claude-code--buffer (session)
  "Return SESSION's live buffer or signal a `user-error'."
  (let ((buffer (claude-code-session-buffer session)))
    (unless (buffer-live-p buffer)
      (user-error "Session %s has no live buffer" (claude-code-session-id session)))
    buffer))

(defun claude-code--launch (id project-root &rest opts)
  "Host a `claude' instance for session ID in a new buffer; return the buffer.
PROJECT-ROOT is the directory it is launched from and recorded as the instance's
origin.  OPTS are `:prompt', `:worktree' and `:model' as
`claude-code--build-args' takes them, or `:resume' ID to resume that session
rather than start it; the `:worktree' request is also recorded in the registry."
  (require 'ghostel)
  (require 'claude-code-mcp)
  (let* ((root (claude-code--normalize-root project-root))
         (args (apply #'claude-code--build-args
                      :session-id id
                      :mcp-args (claude-code--mcp-cli-args id)
                      opts))
         (default-directory (file-name-as-directory root))
         (buffer (generate-new-buffer
                  (funcall claude-code-buffer-name-function root))))
    (ghostel-exec buffer claude-code-cli args)
    (claude-code--install-buffer-name-tracking buffer)
    (claude-code--register id buffer root root (plist-get opts :worktree))
    buffer))

;;;###autoload
(cl-defun claude-code-spawn (project-root &key prompt worktree model)
  "Spawn a new Claude Code instance for PROJECT-ROOT; return its buffer.
PROMPT is an optional initial prompt.
WORKTREE requests a git worktree: t for an auto-named one, or a string to
name it.  MODEL sets the model.  The session id is generated internally and is
not exposed."
  (claude-code--launch (claude-code--new-uuid) project-root
                       :prompt prompt :worktree worktree :model model))

;;;###autoload
(defun claude-code-resume (project-root id)
  "Resume session ID for PROJECT-ROOT in a new instance; return its buffer.
When Emacs already manages a live instance for ID, focus and return that
instance rather than starting a second `claude' for the same session.  Refuses a
session a `claude' outside Emacs is running, so this never attaches a second
process to a session another one is already driving."
  (let* ((reg (gethash id claude-code--managed))
         (existing (and reg
                        (claude-code--session-process (plist-get reg :buffer))
                        (plist-get reg :buffer))))
    (cond
     (existing (pop-to-buffer existing) existing)
     ((claude-code--pid-live-p
       (plist-get (gethash id (claude-code--live-status-table)) :pid))
      (user-error "Session %s is running outside Emacs" id))
     (t (claude-code--launch id project-root :resume id)))))

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
    (claude-code--delete-transcript file)))

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
The new name is not cached: Claude records it as a `custom-title' line in the
transcript and the next refresh reads it back through
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


;;;; View
;;
;; A `tabulated-list-mode' buffer listing every session of a project, grouped by
;; status or by liveness (Emacs 30 `tabulated-list-groups' prints a header line
;; per group); a collapsed group simply contributes no entry rows.

(defcustom claude-code-refresh-interval 2
  "Seconds between automatic refreshes of a sessions view.
nil disables automatic refreshing.

Each refresh reparses the sessions files (a few ms even for ~100 instances, so
it is not cached) and takes one full snapshot of the system process table for
CPU/memory.  That snapshot dominates the cost — around 40 ms on a busy machine
with several hundred processes — so on a very busy host raise this interval
rather than adding caching or throttling machinery."
  :type '(choice (const :tag "Disabled" nil) number))

(defvar-local claude-code--project nil
  "Project root a sessions view is scoped to.")
(defvar-local claude-code--group-by 'status
  "How the sessions view groups rows: `status' or `state'.")
(defvar-local claude-code--collapsed nil
  "List of collapsed group names in a sessions view.
`claude-code-sessions-mode' seeds this with the \"dead\" group so it starts
folded.")
(defvar-local claude-code--marks nil
  "List of marked session ids in a sessions view.")
(defvar-local claude-code--session-table nil
  "Hash of session id -> struct for the rows currently displayed.")
(defvar-local claude-code--usage-table nil
  "Hash of session id -> (CPU . RSS) for the rows currently displayed.")
(defvar-local claude-code--refresh-timer nil
  "Repeating timer refreshing a sessions view, if any.")

;;;;; Formatting

(defun claude-code--status-display (session)
  "Return (STRING . FACE) describing SESSION's liveness and status."
  (pcase (claude-code--session-liveness session)
    ('alive (pcase (claude-code-session-status session)
              ("busy" (cons "busy" 'warning))
              ("idle" (cons "idle" 'success))
              ("waiting" (cons "waiting" 'error))
              ('nil (cons "alive" 'default))
              (raw (cons (format "unknown (%s)" raw) 'default))))
    ('external (cons "external" 'font-lock-comment-face))
    ('dead (cons "dead" 'shadow))))

(defun claude-code--worktree-label (session)
  "Return the worktree label for SESSION, empty for main-tree sessions."
  (if (claude-code-session-worktree-p session)
      (let ((cwd (claude-code-session-cwd session)))
        (if cwd (file-name-nondirectory (directory-file-name cwd)) ""))
    ""))

(defun claude-code--session-display-name (session)
  "Return SESSION's display name.
This is the single authority for a session's name, so it cannot drift: the
name is derived from the transcript on every query, never cached by this
package.  The sources, in order: the transcript TITLE (a user custom title
that `/rename' writes, else Claude's generated one), the opening prompt, and
finally the short session id."
  (or (claude-code-session-title session)
      (claude-code-session-last-prompt session)
      (string-limit (claude-code-session-id session) 8)))

(defun claude-code--format-relative-time (time &optional now)
  "Return a compact age string for TIME relative to NOW.
NOW defaults to the current time.  The empty string is returned when TIME is
nil."
  (if (null time)
      ""
    (let ((secs (max 0 (floor (- (float-time (or now (current-time)))
                                 (float-time time))))))
      (cond ((< secs 60) (format "%ds" secs))
            ((< secs 3600) (format "%dm" (/ secs 60)))
            ((< secs 86400) (format "%dh" (/ secs 3600)))
            ((< secs 604800) (format "%dd" (/ secs 86400)))
            (t (format "%dw" (/ secs 604800)))))))

(defun claude-code--format-session (session usage)
  "Return the column vector for SESSION.
USAGE is (CPU . RSS) or nil."
  (let ((status (claude-code--status-display session)))
    (vector (propertize (car status) 'face (cdr status))
            (propertize (claude-code--format-relative-time
                         (claude-code-session-last-active session))
                        'face 'shadow)
            (propertize (string-limit (claude-code-session-id session) 8)
                        'face 'shadow)
            (claude-code--worktree-label session)
            (if usage (format "%.1f" (car usage)) "")
            (if usage (format "%dM" (/ (cdr usage) 1024)) "")
            (claude-code--session-display-name session))))

;;;;; Grouping

(defun claude-code--group-key (session)
  "Return the group key of SESSION under the current grouping.
The key is the name of SESSION's liveness state, so external and dead sessions
form their own groups regardless of the grouping mode; only an alive session
splits out by status, and only when grouping by status."
  (let ((liveness (claude-code--session-liveness session)))
    (if (and (eq liveness 'alive) (eq claude-code--group-by 'status))
        (or (claude-code-session-status session) "alive")
      (symbol-name liveness))))

(defun claude-code--group-rank (key)
  "Return the display rank of group KEY; lower ranks come first."
  (or (alist-get key '(("waiting" . 0) ("busy" . 1) ("idle" . 2) ("alive" . 3)
                       ("external" . 8) ("dead" . 9))
                 nil nil #'equal)
      5))

(defun claude-code--group-less-p (a b)
  "Return non-nil when group A should sort before group B."
  (< (claude-code--group-rank a) (claude-code--group-rank b)))

(defun claude-code--group-header (key count collapsed)
  "Return the header line for group KEY with COUNT rows and COLLAPSED state."
  (propertize (format "%s %s (%d)"
                      (if collapsed "▸" "▾") (capitalize key) count)
              'claude-code-group key 'face 'bold))

(defun claude-code--num-sorter (get)
  "Return a tabulated-list sorter over usage values read with GET.
GET picks the compared number out of a (CPU . RSS) pair; a row with no usage
sorts lowest."
  (lambda (a b)
    (< (or (funcall get (gethash (car a) claude-code--usage-table)) -1)
       (or (funcall get (gethash (car b) claude-code--usage-table)) -1))))

(defun claude-code--entry-time (entry)
  "Return the last-active time of ENTRY's session as a float, 0 when unknown.
ENTRY is a tabulated-list entry whose car is the session id, looked up in
`claude-code--session-table'."
  (if-let* ((session (gethash (car entry) claude-code--session-table))
            (time (claude-code-session-last-active session)))
      (float-time time)
    0))

(defun claude-code--time-less-p (a b)
  "Order tabulated-list entries A and B by their session's last-active time.
A session without a known time sorts as oldest."
  (< (claude-code--entry-time a) (claude-code--entry-time b)))

(defun claude-code--tabulated-groups ()
  "Return the grouped rows for the current view, honouring collapse state."
  (let ((sessions (claude-code-sessions claude-code--project))
        (snapshot (claude-code--process-snapshot))
        (buckets (make-hash-table :test 'equal))
        (order '()))
    (clrhash claude-code--session-table)
    (clrhash claude-code--usage-table)
    (dolist (session sessions)
      (let ((id (claude-code-session-id session))
            (key (claude-code--group-key session)))
        (puthash id session claude-code--session-table)
        (when (and (claude-code-session-alive-p session)
                   (claude-code-session-pid session))
          (puthash id (claude-code--process-usage
                       (claude-code-session-pid session) snapshot)
                   claude-code--usage-table))
        (push key order)
        (push session (gethash key buckets))))
    (setq order (sort (delete-dups order) #'claude-code--group-less-p))
    (mapcar
     (lambda (key)
       (let* ((rows (nreverse (gethash key buckets)))
              (collapsed (and (member key claude-code--collapsed) t)))
         (cons (claude-code--group-header key (length rows) collapsed)
               (unless collapsed
                 (mapcar (lambda (s)
                           (list (claude-code-session-id s)
                                 (claude-code--format-session
                                  s (gethash (claude-code-session-id s)
                                             claude-code--usage-table))))
                         rows)))))
     order)))

;;;;; Marks and refresh

(defun claude-code--session-at-point ()
  "Return the session on the current line, or nil on a group header."
  (when-let* ((id (tabulated-list-get-id)))
    (gethash id claude-code--session-table)))

(defun claude-code--reapply-marks ()
  "Re-tag rows whose session id is in `claude-code--marks'."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when-let* ((s (claude-code--session-at-point)))
        (when (member (claude-code-session-id s) claude-code--marks)
          (tabulated-list-put-tag "*")))
      (forward-line 1))))

(defun claude-code--target-sessions (&optional liveness)
  "Return the marked sessions, or the session at point when none are marked.
LIVENESS, when given, keeps only the sessions in that state
\(`claude-code--session-liveness'), so a command's targets are exactly the ones
its model operation accepts."
  (let ((targets (if claude-code--marks
                     (delq nil (mapcar (lambda (id)
                                         (gethash id claude-code--session-table))
                                       claude-code--marks))
                   (when-let* ((s (claude-code--session-at-point))) (list s)))))
    (if liveness
        (seq-filter (lambda (s) (eq liveness (claude-code--session-liveness s)))
                    targets)
      targets)))

(defun claude-code--maybe-refresh (buffer)
  "Refresh BUFFER when it is live and visible."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer 'visible))
    (with-current-buffer buffer
      (let ((inhibit-message t))
        (claude-code-sessions-refresh)))))

(defun claude-code--cancel-refresh ()
  "Cancel the view's refresh timer."
  (when (timerp claude-code--refresh-timer)
    (cancel-timer claude-code--refresh-timer)))

;;;;; Commands

(defun claude-code-sessions-refresh ()
  "Recompute and redraw the sessions view."
  (interactive)
  (tabulated-list-print t)
  (claude-code--reapply-marks))

(defun claude-code-sessions-toggle-group ()
  "Collapse or expand the group at point.
Works whether point is on a group header or on one of the group's rows: in the
latter case the row's session determines the enclosing group."
  (interactive)
  (when-let* ((group (or (get-text-property (line-beginning-position)
                                            'claude-code-group)
                         (when-let* ((s (claude-code--session-at-point)))
                           (claude-code--group-key s)))))
    (if (member group claude-code--collapsed)
        (setq claude-code--collapsed (delete group claude-code--collapsed))
      (push group claude-code--collapsed))
    (claude-code-sessions-refresh)))

(defun claude-code-sessions-visit ()
  "Focus an alive session, offer to resume a dead one, or toggle a group."
  (interactive)
  (let ((session (claude-code--session-at-point)))
    (cond
     ((null session) (claude-code-sessions-toggle-group))
     ((claude-code-session-alive-p session) (claude-code-focus session))
     ((claude-code-session-external-p session)
      (user-error "Session runs outside Emacs; cannot attach"))
     ((y-or-n-p "Session is dead.  Resume it? ")
      (claude-code-resume claude-code--project (claude-code-session-id session))
      (claude-code-sessions-refresh)))))

(defun claude-code-sessions-mark ()
  "Mark the session on the current line."
  (interactive)
  (when-let* ((s (claude-code--session-at-point)))
    (cl-pushnew (claude-code-session-id s) claude-code--marks :test #'equal)
    (tabulated-list-put-tag "*" t)))

(defun claude-code-sessions-unmark ()
  "Unmark the session on the current line."
  (interactive)
  (when-let* ((s (claude-code--session-at-point)))
    (setq claude-code--marks (delete (claude-code-session-id s) claude-code--marks))
    (tabulated-list-put-tag " " t)))

(defun claude-code-sessions-kill ()
  "Kill the marked instances, or the one at point."
  (interactive)
  (let ((targets (claude-code--target-sessions 'alive)))
    (if (null targets)
        (user-error "No alive session selected")
      (when (yes-or-no-p (format "Kill %d instance(s)? " (length targets)))
        (mapc #'claude-code-kill targets)
        (setq claude-code--marks nil)
        (claude-code-sessions-refresh)))))

(defun claude-code-sessions-delete ()
  "Delete the marked dead sessions, or the one at point.
An external session is not a deletable target: a `claude' outside Emacs is
still running it."
  (interactive)
  (let ((targets (claude-code--target-sessions 'dead)))
    (if (null targets)
        (user-error "No dead session selected")
      (when (yes-or-no-p (format "Delete %d dead session(s)? " (length targets)))
        (mapc #'claude-code-delete targets)
        (setq claude-code--marks nil)
        (claude-code-sessions-refresh)))))

(defun claude-code-sessions-rename ()
  "Rename the session at point."
  (interactive)
  (when-let* ((s (claude-code--session-at-point)))
    (claude-code-rename s (read-string "New name: "))))

(defun claude-code-sessions-interrupt ()
  "Interrupt (SIGINT) the session at point."
  (interactive)
  (when-let* ((s (claude-code--session-at-point)))
    (claude-code-interrupt s)))

(defun claude-code-sessions-send ()
  "Send a line of text to the session at point."
  (interactive)
  (when-let* ((s (claude-code--session-at-point)))
    (claude-code-send-text s (read-string "Send: ") t)))

(defun claude-code-sessions-cycle-grouping ()
  "Toggle grouping between status and alive/dead state."
  (interactive)
  (setq claude-code--group-by
        (if (eq claude-code--group-by 'status) 'state 'status))
  (claude-code-sessions-refresh))

(defun claude-code-sessions-new (&optional args)
  "Spawn a new session, reading options from the transient ARGS."
  (interactive (list (transient-args 'claude-code-menu)))
  (let ((prompt (read-string "Initial prompt (empty for none): ")))
    (claude-code-spawn
     claude-code--project
     :prompt (unless (string-empty-p prompt) prompt)
     :worktree (and (member "--worktree" args) t)
     :model (transient-arg-value "--model=" args))
    (claude-code-sessions-refresh)))

;;;;; Mode

(defvar-keymap claude-code-sessions-mode-map
  :doc "Keymap for `claude-code-sessions-mode'."
  "g"   #'claude-code-sessions-refresh
  "RET" #'claude-code-sessions-visit
  "TAB" #'claude-code-sessions-toggle-group
  "n"   #'claude-code-sessions-new
  "k"   #'claude-code-sessions-kill
  "d"   #'claude-code-sessions-delete
  "r"   #'claude-code-sessions-rename
  "i"   #'claude-code-sessions-interrupt
  "s"   #'claude-code-sessions-send
  "m"   #'claude-code-sessions-mark
  "u"   #'claude-code-sessions-unmark
  "G"   #'claude-code-sessions-cycle-grouping
  "?"   #'claude-code-menu)

(define-derived-mode claude-code-sessions-mode tabulated-list-mode "Claude"
  "Major mode listing the Claude Code sessions of a project."
  (setq-local claude-code--session-table (make-hash-table :test 'equal))
  (setq-local claude-code--usage-table (make-hash-table :test 'equal))
  ;; Dead sessions are folded by default.  A fresh list keeps `toggle-group's
  ;; destructive `delete' from mutating shared state.
  (setq-local claude-code--collapsed (list "dead"))
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-format
              (vector '("Status" 9 t)
                      (list "Active" 8 #'claude-code--time-less-p :right-align t)
                      '("Id" 9 t)
                      '("Worktree" 14 t)
                      (list "CPU%" 6 (claude-code--num-sorter #'car)
                            :right-align t)
                      (list "Mem" 8 (claude-code--num-sorter #'cdr)
                            :right-align t)
                      ;; Name is last so it is never truncated and fills the
                      ;; remaining window width.
                      '("Name" 26 t)))
  ;; Reverse (`t') so the most recently active session heads each group.
  (setq-local tabulated-list-sort-key '("Active" . t))
  (setq-local tabulated-list-entries #'ignore)
  (setq-local tabulated-list-groups #'claude-code--tabulated-groups)
  (tabulated-list-init-header)
  (when claude-code-refresh-interval
    (setq-local claude-code--refresh-timer
                (run-at-time claude-code-refresh-interval
                             claude-code-refresh-interval
                             #'claude-code--maybe-refresh (current-buffer))))
  ;; Cancel the timer when the buffer dies or its major mode is replaced.
  ;; `change-major-mode-hook' runs before `kill-all-local-variables' wipes the
  ;; timer reference, so re-running the mode (or switching away) cancels the
  ;; old timer rather than orphaning it.  Both hooks and the
  ;; `ghostel-exit-functions' entry go through `add-hook', which de-duplicates.
  (add-hook 'kill-buffer-hook #'claude-code--cancel-refresh nil t)
  (add-hook 'change-major-mode-hook #'claude-code--cancel-refresh nil t))

;;;;; Transient

(transient-define-prefix claude-code-menu ()
  "Dispatch actions for the Claude sessions view."
  ["Spawn options"
   ("-w" "Worktree" "--worktree")
   ("-m" "Model" "--model=" :choices ("opus" "sonnet" "haiku" "fable"))]
  ["Spawn"
   ("n" "New session" claude-code-sessions-new)]
  [["Session"
    ("RET" "Focus / resume" claude-code-sessions-visit)
    ("r" "Rename" claude-code-sessions-rename)
    ("i" "Interrupt" claude-code-sessions-interrupt)
    ("s" "Send text" claude-code-sessions-send)]
   ["Manage"
    ("k" "Kill" claude-code-sessions-kill)
    ("d" "Delete dead" claude-code-sessions-delete)
    ("m" "Mark" claude-code-sessions-mark)
    ("u" "Unmark" claude-code-sessions-unmark)]
   ["View"
    ("G" "Cycle grouping" claude-code-sessions-cycle-grouping)
    ("TAB" "Toggle group" claude-code-sessions-toggle-group)
    ("g" "Refresh" claude-code-sessions-refresh)]])

;;;###autoload
(defun claude-code ()
  "Open the Claude sessions view for the current project."
  (interactive)
  (let* ((root (claude-code--normalize-root (project-root (project-current t))))
         (buffer (get-buffer-create
                  (format "*claude-sessions: %s*" (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-code-sessions-mode)
        (claude-code-sessions-mode))
      (setq claude-code--project root)
      (setq default-directory (file-name-as-directory root))
      (claude-code-sessions-refresh))
    (pop-to-buffer buffer)))

(provide 'claude-code)
;;; claude-code.el ends here
