;;; claude-code.el --- Orchestrate Claude Code sessions from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lautaro Emanuel

;; Author: Lautaro Emanuel
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (ghostel "0.58.0"))
;; Keywords: tools, processes
;; URL: https://github.com/emlautarom1/claude-code.el

;;; Commentary:

;; Orchestrate Claude Code CLI sessions per `project.el' project.  Emacs hosts
;; the instances it launches or attaches in `ghostel' terminal buffers, and a
;; view lists a project's sessions, alive, external or dead, and acts on them.

;;; Code:

(require 'cl-lib)
(require 'eldoc)
(require 'filenotify)
(require 'seq)
(require 'project)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'xdg)

;; Ghostel is loaded lazily, so the package compiles and tests without its
;; native module.
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function ghostel-mode "ghostel" ())
(declare-function ghostel-send-key "ghostel" (key-name &optional mods))
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function ghostel-send-C-c "ghostel" ())
(declare-function ghostel--update-directory "ghostel" (dir))
(defvar ghostel--process)
(defvar ghostel--last-directory)
(defvar ghostel-eval-cmds)
(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-file-name-equal-p "tramp" (vec1 vec2))
(defvar ghostel-kill-buffer-on-exit)
(defvar ghostel-buffer-name-function)
(defvar ghostel-notification-functions)
(defvar ghostel-program-status)
(defvar ghostel-program-status-functions)
(defvar ghostel-status-notify-states)
(defvar ghostel-semi-char-mode-map)
(defvar vc-deduce-backend-nonvc-modes)
(defvar desktop-save-buffer)
(defvar bookmark-make-record-function)

;; Loaded on launch, since `claude-code-mcp' itself requires this file.
(declare-function claude-code--mcp-wiring "claude-code-mcp" (buffer))


;;;; Customization

(defgroup claude-code nil
  "Orchestrate Claude Code CLI sessions from Emacs."
  :group 'tools
  :prefix "claude-code-")

(defcustom claude-code-cli "claude"
  "Executable used to launch the Claude Code CLI.
A bare name is searched for on the project's host: on variable `exec-path'
locally, on `tramp-remote-path' remotely.  A wrapper script must `exec' the
CLI, so the CLI runs under the wrapper's PID."
  :type 'string)

(defcustom claude-code-detachable 'remote
  "Which new instances are detachable by default.
A detachable instance runs under `claude-code-dtach' on its host, so closing its
buffer leaves it running.  `remote' makes an instance in a remote directory
detachable, t every instance, and nil none."
  :type '(choice (const :tag "Remote instances" remote)
                 (const :tag "Every instance" t)
                 (const :tag "None" nil)))

(defcustom claude-code-dtach "dtach"
  "Executable a detachable instance runs under.
Searched for on the instance's host as `claude-code-cli' is."
  :type 'string)

(defcustom claude-code-config-dir
  (let ((env (getenv "CLAUDE_CONFIG_DIR")))
    (if (member env '(nil "")) (expand-file-name "~/.claude") env))
  "Directory where Claude Code stores its state on this machine."
  :type 'directory)


;;;; Storage adapter
;;
;; Claude's on-disk state.
;;
;; A HOST is a remote prefix as `file-remote-p' returns it, or nil for this
;; machine.

(defvar claude-code--remote-config-envs (make-hash-table :test 'equal)
  "Hash of remote host -> (VALUE . HOME), its `CLAUDE_CONFIG_DIR' and home.
VALUE is nil where the variable is unset or empty.")

(defun claude-code--remote-config-env (host)
  "Return remote HOST's entry in `claude-code--remote-config-envs'."
  (or (gethash host claude-code--remote-config-envs)
      (let ((default-directory (concat host "/")))
        (with-temp-buffer
          (unless (eql 0 (process-file
                          "/bin/sh" nil t nil "-c"
                          "printf '%s\\n%s' \"$CLAUDE_CONFIG_DIR\" \"$HOME\""))
            (user-error "Cannot ask %s for its Claude config dir" host))
          (pcase-let ((`(,value ,home) (split-string (buffer-string) "\n")))
            (puthash host (cons (and (not (string-empty-p value)) value) home)
                     claude-code--remote-config-envs))))))

(defun claude-code--forget-remote-config-env (&optional vec)
  "Forget what the host of TRAMP connection VEC said, or every host without VEC."
  (dolist (host (hash-table-keys claude-code--remote-config-envs))
    (when (or (null vec)
              (tramp-file-name-equal-p vec (tramp-dissect-file-name host)))
      (remhash host claude-code--remote-config-envs))))

(add-hook 'tramp-cleanup-connection-hook
          #'claude-code--forget-remote-config-env)
(add-hook 'tramp-cleanup-all-connections-hook
          #'claude-code--forget-remote-config-env)

(defun claude-code--config-env (&optional host)
  "Return the `CLAUDE_CONFIG_DIR' an instance on HOST runs with, nil for unset."
  (if host
      (car (claude-code--remote-config-env host))
    (let ((env (let ((value (getenv "CLAUDE_CONFIG_DIR")))
                 (and (not (equal value "")) value)))
          (dir (directory-file-name (expand-file-name claude-code-config-dir))))
      ;; Any value, even ~/.claude, makes the CLI keep its global config in the
      ;; dir instead of ~/.claude.json, so an unset variable stays unset.
      (if (equal dir (directory-file-name (expand-file-name (or env "~/.claude"))))
          env
        dir))))

(defun claude-code--config-dir (&optional host)
  "Return the config dir of the `claude' on HOST, as a file name there."
  (if host
      (pcase-let ((`(,value . ,home) (claude-code--remote-config-env host)))
        (concat host (or value (concat (file-name-as-directory home) ".claude"))))
    (expand-file-name claude-code-config-dir)))

(defun claude-code--remote-home (host)
  "Return remote HOST's home directory, as a file name there."
  (cdr (claude-code--remote-config-env host)))

(defconst claude-code--encoded-cwd-limit 200
  "Length past which Claude cuts a project-directory name and appends a hash.")

(defun claude-code--utf16-units (string)
  "Return STRING as the UTF-16 code units JavaScript sees in it."
  (mapcan (lambda (char)
            (if (< char #x10000)
                (list char)
              (let ((offset (- char #x10000)))
                (list (+ #xD800 (ash offset -10))
                      (+ #xDC00 (logand offset #x3FF))))))
          (string-to-list string)))

(defun claude-code--cwd-hash (dir)
  "Return the base-36 hash Claude appends to DIR's cut project-directory name."
  (let ((hash 0))
    (dolist (unit (claude-code--utf16-units dir))
      (setq hash (logand (+ (* hash 31) unit) #xFFFFFFFF)))
    (let ((value (if (>= hash #x80000000) (- #x100000000 hash) hash))
          (digits '()))
      (while (progn (push (aref "0123456789abcdefghijklmnopqrstuvwxyz"
                                (% value 36))
                          digits)
                    (> (setq value (/ value 36)) 0)))
      (concat digits))))

(defun claude-code--encode-cwd (path)
  "Encode absolute PATH, on whatever host, into its Claude project-directory name.
The mapping is lossy: distinct directories can share a name."
  (let* ((dir (file-local-name (directory-file-name (expand-file-name path))))
         (name (concat (mapcar (lambda (unit)
                                 (if (or (<= ?a unit ?z) (<= ?A unit ?Z)
                                         (<= ?0 unit ?9))
                                     unit
                                   ?-))
                               (claude-code--utf16-units dir)))))
    (if (<= (length name) claude-code--encoded-cwd-limit)
        name
      (concat (substring name 0 claude-code--encoded-cwd-limit)
              "-" (claude-code--cwd-hash dir)))))

(defun claude-code--projects-dir (&optional host)
  "Return the directory holding every project's transcript directory on HOST."
  (expand-file-name "projects" (claude-code--config-dir host)))

(defconst claude-code--worktrees-dir ".claude/worktrees"
  "Where a `--worktree=NAME' checkout lands, relative to the repository root.")

(defun claude-code--worktree-path (root name)
  "Return the checkout `--worktree=NAME' builds under ROOT."
  (expand-file-name (concat claude-code--worktrees-dir "/"
                            (string-replace "/" "+" name))
                    root))

(defun claude-code--worktree-name (dir)
  "Return the name of the worktree whose checkout is directory DIR.
A `+', which no name may contain, is a `/' the CLI flattened."
  (string-replace "+" "/" (file-name-nondirectory dir)))

(defun claude-code--worktree-names (root)
  "Return the names of the worktrees Claude keeps under ROOT."
  (let ((dir (expand-file-name claude-code--worktrees-dir root)))
    (when (file-directory-p dir)
      (mapcar #'claude-code--worktree-name
              (seq-filter #'file-directory-p
                          (directory-files
                           dir t directory-files-no-dot-files-regexp t))))))

(defun claude-code--worktree-parent (root)
  "Return (PARENT . NAME) when ROOT is a worktree Claude built, else nil.
ROOT is a normalised project root."
  (and-let* ((name (claude-code--worktree-name root))
             ((not (string-empty-p name)))
             ;; The CLI flattens a `/' in NAME and never nests checkouts, so
             ;; one sits exactly three directories below its parent.
             (up1 (file-name-parent-directory root))
             (up2 (file-name-parent-directory up1))
             (up3 (file-name-parent-directory up2))
             (parent (directory-file-name up3))
             ((equal (claude-code--worktree-path parent name) root)))
    (cons parent name)))

(defun claude-code--sessions-dir (&optional host)
  "Return the directory holding one file per running `claude' process on HOST."
  (expand-file-name "sessions" (claude-code--config-dir host)))

(defun claude-code--read-session-file (file)
  "Return what sessions/ FILE says of its `claude' process, or nil."
  ;; Claude rewrites the file in place, so a read can catch it half-written.
  (when-let* ((obj (ignore-errors
                     (with-temp-buffer
                       (insert-file-contents file)
                       (json-parse-buffer :object-type 'hash-table))))
              ((hash-table-p obj))
              (session (gethash "sessionId" obj))
              ((stringp session)))
    (let ((cwd (gethash "cwd" obj)))
      (list :session session
            :cwd (and (stringp cwd) (concat (file-remote-p file) cwd))
            :status (gethash "status" obj)
            :waiting-for (gethash "waitingFor" obj)))))

(defconst claude-code--session-file-re "\\`[0-9]+\\.json\\'"
  "Matches the name of a sessions/ file, which is its process's PID.")

(defun claude-code--live-table (&optional host)
  "Parse the per-process files under HOST's sessions/ into a hash keyed by PID."
  (let ((dir (claude-code--sessions-dir host))
        (table (make-hash-table)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t claude-code--session-file-re))
        (when-let* ((info (claude-code--read-session-file file)))
          (puthash (string-to-number (file-name-base file)) info table))))
    table))

(defun claude-code--watch-sessions-dir (callback)
  "Watch this machine's sessions/, calling CALLBACK with a PID on each change.
Return the watch descriptor, or nil while there is no sessions/ yet."
  (let ((dir (claude-code--sessions-dir)))
    (when (file-directory-p dir)
      (file-notify-add-watch
       dir '(change)
       (lambda (event)
         (let ((name (file-name-nondirectory (nth 2 event))))
           (when (and (memq (nth 1 event) '(created changed deleted))
                      (string-match-p claude-code--session-file-re name))
             (funcall callback (string-to-number (file-name-base name))))))))))

(defun claude-code--pid-info (pid &optional host)
  "Return what sessions/ says of the `claude' process PID on HOST, or nil."
  (and (integerp pid)
       (claude-code--read-session-file
        (expand-file-name (format "%d.json" pid)
                          (claude-code--sessions-dir host)))))

(defun claude-code--pid-cwd (pid &optional host)
  "Return the directory the `claude' process PID on HOST works in, or nil."
  (plist-get (claude-code--pid-info pid host) :cwd))

(defvar claude-code--transcript-cache (make-hash-table :test 'equal)
  "Cache mapping a transcript file to (MTIME . FIELDS).")

(defun claude-code--json-line-at-point ()
  "Return the line point is on parsed as JSON, or nil when it does not parse.
Moves point to the start of the line."
  (goto-char (line-beginning-position))
  (ignore-errors
    (json-parse-string
     (buffer-substring-no-properties (point) (line-end-position)))))

(defun claude-code--json-line-field (literal field &optional predicate)
  "Return FIELD from the newest line in the current buffer containing LITERAL.
The line must parse as JSON with a non-nil top-level FIELD and, when PREDICATE
is given, satisfy it, called with the parsed line.  Return nil when none does.
Point is moved."
  (goto-char (point-max))
  (let (result)
    (while (and (not result) (search-backward literal nil t))
      (when-let* ((obj (claude-code--json-line-at-point))
                  ((or (null predicate) (funcall predicate obj))))
        (setq result (gethash field obj))))
    result))

(defconst claude-code--program-entrypoints '("sdk-cli" "sdk-py" "sdk-ts")
  "The `entrypoint' stamps the CLI itself takes to mean a program is driving it.")

(defun claude-code--interactive-transcript-p ()
  "Return non-nil unless a program drove every invocation in the current buffer.
Point is moved."
  (goto-char (point-min))
  (let (stamped person)
    (while (and (not person) (search-forward "\"entrypoint\"" nil t))
      (when-let* ((obj (claude-code--json-line-at-point))
                  (entrypoint (gethash "entrypoint" obj)))
        (setq stamped t)
        (unless (member entrypoint claude-code--program-entrypoints)
          (setq person t)))
      (forward-line 1))
    (or person (not stamped))))

(defun claude-code--read-worktree-binding (&optional host)
  "Return the worktree binding recorded in the transcript in the current buffer.
A plist (:name NAME :path PATH :bound FLAG), nil for a session that never ran
in a worktree.  PATH is a file name on HOST, the transcript's.  FLAG is non-nil
while the session is still in the worktree."
  ;; Claude writes a `worktree-state' line with a null binding when the session
  ;; leaves its worktree.
  (when-let* ((latest (claude-code--json-line-field "\"worktree-state\""
                                                    "worktreeSession"))
              (named (claude-code--json-line-field "\"worktreeName\""
                                                   "worktreeSession"))
              ((hash-table-p named)))
    (let ((name (gethash "worktreeName" named))
          (path (gethash "worktreePath" named)))
      (when (stringp name)
        (list :name name
              :path (and (stringp path) (concat host path))
              :bound (hash-table-p latest))))))

(defconst claude-code--recap-chrome " (disable recaps in /config)"
  "Trailing text the CLI appends to a process's first few recaps.")

(defun claude-code--read-recap ()
  "Return the newest recap in the transcript in the current buffer, or nil.
Point is moved."
  (when-let* ((recap (claude-code--json-line-field
                      "\"away_summary\"" "content"
                      ;; Other line types carry a top-level `content' too.
                      (lambda (obj) (equal (gethash "subtype" obj)
                                           "away_summary"))))
              ((stringp recap))
              (text (string-remove-suffix claude-code--recap-chrome recap))
              ((not (string-empty-p text))))
    text))

(defun claude-code--read-transcript-fields (file)
  "Read FILE's transcript fields from disk."
  (with-temp-buffer
    (insert-file-contents file)
    (list :interactive-p
          (claude-code--interactive-transcript-p)
          :title
          (or (claude-code--json-line-field "\"custom-title\"" "customTitle")
              (claude-code--json-line-field "\"ai-title\"" "aiTitle"))
          :last-prompt
          (claude-code--json-line-field "\"last-prompt\"" "lastPrompt")
          :recap
          (claude-code--read-recap)
          :worktree-binding
          (claude-code--read-worktree-binding (file-remote-p file))
          :last-active
          ;; Not the mtime: Claude appends untimestamped metadata long after
          ;; the conversation's last activity.
          (let ((ts (claude-code--json-line-field "\"timestamp\"" "timestamp")))
            (and (stringp ts) (ignore-errors (date-to-time ts)))))))

(defun claude-code--transcript-fields (file)
  "Return FILE's transcript fields, cached by mtime."
  (let ((mtime (file-attribute-modification-time (file-attributes file)))
        (cached (gethash file claude-code--transcript-cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let ((fields (cons :id (cons (file-name-base file)
                                    (claude-code--read-transcript-fields
                                     file)))))
        (plist-put fields :last-active (or (plist-get fields :last-active) mtime))
        (puthash file (cons mtime fields) claude-code--transcript-cache)
        fields))))

(defun claude-code--delete-transcript (file)
  "Remove transcript FILE from disk along with its cached fields."
  (delete-file file)
  (remhash file claude-code--transcript-cache))

(defun claude-code--project-transcripts (cwd)
  "Return transcript descriptors for project CWD and its worktrees.
Each descriptor is a plist with keys :id, :interactive-p, :title, :last-prompt,
:recap, :worktree-binding, :last-active and :transcript (absolute file)."
  (let* ((projects (claude-code--projects-dir (file-remote-p cwd)))
         (base (claude-code--encode-cwd cwd))
         (wt-prefix (concat base "--claude-worktrees-"))
         (result '()))
    (when (file-directory-p projects)
      (dolist (name (directory-files projects nil nil t))
        (when (or (equal name base) (string-prefix-p wt-prefix name))
          (let ((dir (expand-file-name name projects)))
            (when (file-directory-p dir)
              (dolist (file (directory-files dir t "\\.jsonl\\'"))
                (push (append (claude-code--transcript-fields file)
                              (list :transcript file))
                      result)))))))
    (nreverse result)))


;;;; Ghostel adapter
;;
;; Ghostel keeps the OSC 7501 reports Claude sends as program status records,
;; one per id: the empty id for the session, another for each subagent.

(defun claude-code--root-record (buffer)
  "Return the root program status record of BUFFER's terminal, or nil."
  (cdr (assoc "" (buffer-local-value 'ghostel-program-status buffer))))

(defun claude-code--root-status (buffer)
  "Return the root program status of BUFFER's terminal as (STATE . MSG), or nil."
  (when-let* ((record (claude-code--root-record buffer)))
    (cons (plist-get record :state) (plist-get record :msg))))

(defun claude-code--record-turn-end (record)
  "Return RECORD's turn end, (STATE . MSG) while it is `done' or `error'."
  (when (memq (plist-get record :state) '(done error))
    (cons (plist-get record :state) (plist-get record :msg))))


;;;; dtach adapter

(defconst claude-code--dtach-flags "-E -z -r ctrl_l"
  "The dtach flags every master and client runs with.
They leave the detach and suspend keys to Claude, and send a Ctrl-L on attach,
which makes Claude repaint the screen, but not an inline instance's scrollback,
when no dialog is open.")

(defconst claude-code--holding-script
  (concat
   "if [ -n \"$XDG_RUNTIME_DIR\" ]; then d=$XDG_RUNTIME_DIR/claude-code;"
   " else d=/tmp/claude-code-$(id -u); fi;"
   " (umask 077; mkdir -p \"$d\") && [ -O \"$d\" ] && [ ! -L \"$d\" ]"
   " && chmod 700 \"$d\""
   " || { printf 'claude-code: cannot hold instances in %s\\n' \"$d\" >&2;"
   " exit 1; };"
   " n=$1; shift; exec \"$0\" -c \"$d/$n\" " claude-code--dtach-flags " \"$@\"")
  "The `/bin/sh' script starting a detachable instance under dtach.
Called with dtach as $0, the socket's name, and the command.  The terminal
running it becomes the first client, so it answers Claude's startup probes.")

(defun claude-code--holding-command (dtach name command)
  "Return COMMAND run as a detachable instance under DTACH, on socket NAME."
  (append (list "/bin/sh" "-c" claude-code--holding-script dtach name)
          command))

(defconst claude-code--holder-args-re
  (rx bos (+ (not blank)) " -c "
      (group "/" (* (not blank)) "/claude-code" (? "-" (+ digit))
             "/" (+ (not (any blank "/"))))
      " " (literal claude-code--dtach-flags) " ")
  "Matches the command line of a master `claude-code--holding-script' started.")

(defun claude-code--holder-socket (args)
  "Return the socket named by ARGS, a dtach master's command line, or nil."
  (and (stringp args)
       (string-match claude-code--holder-args-re args)
       (match-string 1 args)))

(defun claude-code--holder (pid &optional host)
  "Return the dtach socket on HOST of the detachable instance PID, or nil.
On a remote HOST, TRAMP answers from its last `list-system-processes' there."
  (let ((default-directory (concat host "/")))
    (when-let* ((ppid (alist-get 'ppid (process-attributes pid))))
      (claude-code--holder-socket (alist-get 'args (process-attributes ppid))))))

(defun claude-code--attaching-command (dtach socket)
  "Return the command attaching a terminal through DTACH to SOCKET."
  (list "/bin/sh" "-c"
        ;; Claude's startup modes, which it does not reliably repeat for a new
        ;; client: bracketed paste, palette and focus reports, kitty keys.  Not
        ;; the alt screen, so a fullscreen instance repaints on the main one.
        (concat "printf '\\033[?2004h\\033[?2031h\\033[?1004h\\033[>5u';"
                " exec \"$0\" -a \"$1\" " claude-code--dtach-flags)
        dtach socket))

(defun claude-code--held-instance-ended-p (event)
  "Return non-nil when process EVENT of a dtach client says its instance ended."
  ;; The client exits 0 only when its master hangs up, which it does once the
  ;; instance ends.
  (equal event "finished\n"))


;;;; Model

(cl-defstruct (claude-code-session (:constructor claude-code-session--create)
                                   (:copier nil))
  "A Claude Code session, alive, external or dead.
ID is the session id.  ALIVE-P is non-nil when Emacs manages an instance
running it: BUFFER is then its Ghostel buffer, and PID its `claude' process on
the project's host, nil until reported.  STATUS is an alive session's \"idle\",
\"busy\", \"waiting\" or \"shell\", with WAITING-FOR set while waiting.
TURN-END is how its last turn ended, `done' or `error', with TURN-END-MESSAGE
Claude's message on it, if any.  EXTERNAL-P is non-nil when a `claude' outside
Emacs runs it, and HOLDER is then the dtach socket file of the detachable
instance running it, if any.  TITLE, LAST-PROMPT, RECAP and LAST-ACTIVE come
from the transcript, the file TRANSCRIPT, nil before Claude writes one.
WORKTREE names the session's worktree, nil for the main tree, and
WORKTREE-BINDING is the transcript's record of it."
  id status waiting-for turn-end turn-end-message alive-p pid buffer
  worktree worktree-binding title last-prompt recap transcript external-p
  last-active holder)

(defvar claude-code--managed (make-hash-table :test 'eq)
  "Hash of instance buffer -> plist describing the managed instance in it.
Keys: :origin, the normalized root it was launched from, whose host is the
instance's; :worktree, the worktree it was asked for; :session, the session it
runs, and :info, what sessions/ says of its process, both as last read;
:detachable, whether it is; and :named, (ID . ARGS) for the
`claude-code--transcript-session-args' a query last built for session ID.")

(defvar-local claude-code--pid nil
  "PID of the `claude' this buffer hosts, on its host; nil until reported.")

(defun claude-code--session-display-name (session)
  "Return SESSION's title, else its latest prompt, else its short id."
  (or (claude-code-session-title session)
      (claude-code-session-last-prompt session)
      (string-limit (claude-code-session-id session) 8)))

(defun claude-code--normalize-root (path)
  "Return PATH absolute and symlink-resolved, without a trailing slash."
  ;; Claude records cwds symlink-resolved.
  (directory-file-name (file-truename (expand-file-name path))))

(defun claude-code--session-process (buffer)
  "Return BUFFER's live Ghostel process, or nil."
  (and (buffer-live-p buffer)
       (let ((proc (buffer-local-value 'ghostel--process buffer)))
         (and (process-live-p proc) proc))))

(defun claude-code--instance-pid (buffer)
  "Return the PID of the `claude' process BUFFER hosts, or nil while unknown."
  (buffer-local-value 'claude-code--pid buffer))

(defun claude-code--origin-project (origin)
  "Return the project ORIGIN belongs to, its parent when ORIGIN is a worktree."
  (or (car (claude-code--worktree-parent origin)) origin))

(defun claude-code--under-root-p (dir root)
  "Return non-nil when DIR is project ROOT or a worktree of it."
  (or (equal dir root) (equal (claude-code--origin-project dir) root)))

(defun claude-code--entry-update (entry info)
  "Record INFO, what sessions/ says of ENTRY's process, in ENTRY; return ENTRY."
  ;; INFO is nil when the file is gone or caught half-written.
  (when info
    (plist-put entry :info info)
    (plist-put entry :session (plist-get info :session)))
  entry)

(defun claude-code--entry-host (entry)
  "Return the host of the instance registry ENTRY describes."
  (file-remote-p (plist-get entry :origin)))

(defun claude-code--instance-entry (buffer)
  "Return the registry entry of the managed instance BUFFER hosts, or nil.
A local entry is first refreshed from its sessions/ file; a remote one holds
what the last query read."
  (when-let* ((entry (gethash buffer claude-code--managed)))
    (if (claude-code--entry-host entry)
        entry
      (claude-code--entry-update
       entry (claude-code--pid-info (claude-code--instance-pid buffer))))))

(defun claude-code--pid-running-p (&optional host)
  "Return a predicate testing whether a PID is in HOST's current process table."
  (let ((pids (let ((default-directory (concat host "/")))
                (list-system-processes))))
    (if pids
        (lambda (pid) (memql pid pids))
      ;; The table could not be read.  Refusing a resume or delete costs less
      ;; than putting two processes on one session.
      #'always)))

(defun claude-code--running (&optional host live)
  "Return a hash of session id -> what runs it on HOST.
That is a managed instance's buffer, or the PID of a `claude' outside Emacs.
LIVE is HOST's `claude-code--live-table', when the caller has already read it."
  (let* ((live (or live (claude-code--live-table host)))
         (running-p (unless (hash-table-empty-p live)
                      (claude-code--pid-running-p host)))
         (instances (cl-loop for buffer being the hash-keys of claude-code--managed
                             using (hash-values entry)
                             when (equal (claude-code--entry-host entry) host)
                             collect (cons buffer entry)))
         (held (mapcar (lambda (instance)
                         (claude-code--instance-pid (car instance)))
                       instances))
         (running (make-hash-table :test 'equal)))
    (maphash (lambda (pid info)
               ;; A `claude' ended by SIGKILL leaves its sessions/ file behind.
               (when (and (not (memql pid held)) (funcall running-p pid))
                 (puthash (plist-get info :session) pid running)))
             live)
    (pcase-dolist (`(,buffer . ,entry) instances)
      (claude-code--entry-update
       entry (gethash (claude-code--instance-pid buffer) live))
      (when (claude-code--session-process buffer)
        (puthash (plist-get entry :session) buffer running)))
    running))

(defun claude-code--session-liveness (session)
  "Return SESSION's liveness: `alive', `external', or `dead'."
  (cond ((claude-code-session-alive-p session) 'alive)
        ((claude-code-session-external-p session) 'external)
        (t 'dead)))

(defun claude-code--binding-worktree (binding)
  "Return BINDING's worktree name while it is bound or its directory exists."
  (when (or (plist-get binding :bound)
            (when-let* ((path (plist-get binding :path)))
              (file-directory-p path)))
    (plist-get binding :name)))

(defun claude-code--resume-worktree (root binding)
  "Return the worktree name a resume of BINDING under ROOT must pass, or nil."
  ;; A bound session re-enters its worktree by itself.  A clean exit unbinds
  ;; one even when its worktree is kept.
  (when-let* (((not (plist-get binding :bound)))
              ;; Nil for a worktree that is gone, which the flag would rebuild.
              (name (claude-code--binding-worktree binding))
              ;; Claude can work in a worktree kept elsewhere, which
              ;; `--worktree=NAME' would not lead back to.
              (round-trip (claude-code--worktree-path root name))
              ((file-equal-p round-trip (plist-get binding :path))))
    name))

(defun claude-code--transcript-session-args (tr &optional reg)
  "Return `claude-code-session--create' arguments derived from descriptor TR.
TR is a transcript descriptor, or nil.  REG, a registry entry, names the
worktree when TR does not."
  (list :worktree-binding (plist-get tr :worktree-binding)
        :worktree (or (claude-code--binding-worktree
                       (plist-get tr :worktree-binding))
                      (plist-get reg :worktree))
        :title (plist-get tr :title)
        :last-prompt (plist-get tr :last-prompt)
        :recap (plist-get tr :recap)
        :transcript (plist-get tr :transcript)
        :last-active (plist-get tr :last-active)))

(defun claude-code--alive-session (buffer &optional args)
  "Return the alive `claude-code-session' for the managed instance BUFFER hosts.
ARGS are the `claude-code--transcript-session-args' of its transcript, nil
while it has none; the registry entry keeps them as :named."
  (let* ((entry (gethash buffer claude-code--managed))
         (id (plist-get entry :session))
         (info (plist-get entry :info))
         ;; A turn's report and its sessions/ rewrite arrive apart, so either
         ;; can lag: both must say the turn ended.
         (turn-end (and (member (plist-get info :status) '("idle" "shell"))
                        (claude-code--record-turn-end
                         (claude-code--root-record buffer)))))
    (when args
      (plist-put entry :named (cons id args)))
    (apply #'claude-code-session--create
           :id id :alive-p t
           :buffer buffer :pid (claude-code--instance-pid buffer)
           :status (plist-get info :status)
           :waiting-for (plist-get info :waiting-for)
           :turn-end (car turn-end)
           :turn-end-message (cdr turn-end)
           (or args (claude-code--transcript-session-args nil entry)))))

(defun claude-code--transcript-for (root id)
  "Return the transcript descriptor for session ID under ROOT, or nil."
  (seq-find (lambda (tr) (equal (plist-get tr :id) id))
            (and root (claude-code--project-transcripts root))))

(defun claude-code--instance-session (buffer)
  "Return the alive `claude-code-session' for the instance BUFFER hosts, or nil.
A remote instance's transcript fields are those the last query read."
  (when-let* ((entry (claude-code--instance-entry buffer)))
    (let ((id (plist-get entry :session)))
      (claude-code--alive-session
       buffer
       (if (claude-code--entry-host entry)
           (let ((named (plist-get entry :named)))
             (and (equal (car named) id) (cdr named)))
         (when-let* ((tr (claude-code--transcript-for
                          (claude-code--origin-project (plist-get entry :origin))
                          id)))
           (claude-code--transcript-session-args tr)))))))

(defun claude-code-project-sessions (project-root)
  "Return the list of `claude-code-session' structs for PROJECT-ROOT.
These are the sessions of its transcripts that a person drove or a managed
instance runs, and the sessions with no transcript there that a managed or
detachable instance runs under PROJECT-ROOT."
  (let* ((root (claude-code--normalize-root project-root))
         (host (file-remote-p root))
         (live (claude-code--live-table host))
         (running (claude-code--running host live))
         (holder (lambda (pid)
                   (when-let* ((socket (claude-code--holder pid host)))
                     (concat host socket))))
         (seen (make-hash-table :test 'equal))
         (sessions '()))
    (dolist (tr (claude-code--project-transcripts root))
      (let* ((id (plist-get tr :id))
             (runner (gethash id running)))
        (puthash id t seen)
        (when (or (bufferp runner) (plist-get tr :interactive-p))
          (push (if (bufferp runner)
                    (claude-code--alive-session
                     runner (claude-code--transcript-session-args tr))
                  (apply #'claude-code-session--create
                         :id id :alive-p nil :external-p (and runner t)
                         :holder (and runner (funcall holder runner))
                         (claude-code--transcript-session-args tr)))
                sessions))))
    ;; Claude writes no transcript before a session's first input.
    (maphash (lambda (id runner)
               (unless (gethash id seen)
                 (if (bufferp runner)
                     (when-let* ((origin (plist-get (gethash runner
                                                             claude-code--managed)
                                                    :origin))
                                 ((claude-code--under-root-p origin root)))
                       (push (claude-code--alive-session runner) sessions))
                   (when-let* ((cwd (plist-get (gethash runner live) :cwd))
                               ((claude-code--under-root-p cwd root))
                               (socket (funcall holder runner)))
                     (push (claude-code-session--create :id id :external-p t
                                                        :holder socket)
                           sessions)))))
             running)
    (nreverse sessions)))

(defvar claude-code--proc-children-p
  ;; A kernel without CONFIG_PROC_CHILDREN has /proc but not this file.
  (file-readable-p (format "/proc/%d/task/%d/children" (emacs-pid) (emacs-pid)))
  "Whether the system names a process's children, as Linux does under `/proc'.")

(defun claude-code--child-pids (pid)
  "Return the pids `/proc' names as children of PID's main thread."
  ;; `claude' forks its tool processes from its main thread.
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents (format "/proc/%d/task/%d/children" pid pid))
      (mapcar #'string-to-number (split-string (buffer-string) nil t)))))

(defun claude-code--process-snapshot (&optional host)
  "Return (ATTRS . CHILDREN) hashes of HOST's current process table.
ATTRS maps a pid to its `process-attributes', CHILDREN to its child pids."
  (let ((default-directory (concat host "/"))
        (attrs (make-hash-table :test 'eql))
        (children (make-hash-table :test 'eql)))
    (dolist (p (list-system-processes))
      (let ((a (process-attributes p)))
        (when a
          (puthash p a attrs)
          (when-let* ((ppid (alist-get 'ppid a)))
            (push p (gethash ppid children))))))
    (cons attrs children)))

(defun claude-code--process-usage (pid &optional snapshot)
  "Return (CPU . RSS) summed over PID's process subtree, or nil if PID is gone.
SNAPSHOT is a `claude-code--process-snapshot' to read PID in; without one, PID
is local.  CPU is a percentage, a lifetime average on some platforms; RSS is in
kibibytes."
  (when (integerp pid)
    (let* ((snap (or snapshot
                     (unless claude-code--proc-children-p
                       (claude-code--process-snapshot))))
           (attrs (if snap
                      (lambda (p) (gethash p (car snap)))
                    #'process-attributes))
           (children (if snap
                         ;; Shared with every later row, so the walk must not
                         ;; modify it.
                         (lambda (p) (gethash p (cdr snap)))
                       #'claude-code--child-pids))
           (cpu 0.0) (rss 0) (stack (list pid)) (found nil))
      ;; Only a found process queues children, so FOUND means PID itself ran.
      (while stack
        (let* ((p (pop stack)) (a (funcall attrs p)))
          (when a
            (setq found t)
            (let ((pcpu (alist-get 'pcpu a)))
              ;; On Linux this is CPU time over age, so a process younger than
              ;; a tick reads NaN or infinity.
              (when (and pcpu (< (abs pcpu) 1.0e+INF))
                (cl-incf cpu pcpu)))
            (cl-incf rss (or (alist-get 'rss a) 0))
            (setq stack (append (funcall children p) stack)))))
      (and found (cons cpu rss)))))

(defun claude-code--instance-cwd (buffer)
  "Return the directory the managed instance BUFFER hosts works in, or nil."
  (when-let* ((entry (claude-code--instance-entry buffer)))
    (let ((origin (plist-get entry :origin))
          (worktree (plist-get entry :worktree)))
      (or (plist-get (plist-get entry :info) :cwd)
          (if worktree (claude-code--worktree-path origin worktree) origin)))))

(defun claude-code--session-directory (session root)
  "Return the directory SESSION, listed under project ROOT, works in now."
  (or (pcase (claude-code--session-liveness session)
        ('alive (claude-code--instance-cwd (claude-code-session-buffer session)))
        ('external (let ((host (file-remote-p root)))
                     (claude-code--pid-cwd
                      (gethash (claude-code-session-id session)
                               (claude-code--running host))
                      host))))
      (let ((path (plist-get (claude-code-session-worktree-binding session)
                             :path)))
        (and path (file-directory-p path) path))
      root))


;;;; Operations

(cl-defun claude-code--build-args
    (&key session-id resume prompt name worktree model effort)
  "Return the argument list for the `claude' CLI.
A new session SESSION-ID starts with PROMPT, NAME, WORKTREE, MODEL and
EFFORT; the CLI reads a blank NAME as no name.  When RESUME is a session id,
that session resumes instead, inside WORKTREE when that is a string."
  (if resume
      (append (when (stringp worktree)
                (list (concat "--worktree=" worktree)))
              (list (concat "--resume=" resume)))
    (append (when session-id (list "--session-id" session-id))
            (when name (list (concat "--name=" name)))
            (when worktree
              (list (if (stringp worktree)
                        (concat "--worktree=" worktree)
                      "--worktree")))
            (when model (list "--model" model))
            (when effort (list "--effort" effort))
            (unless (or (null prompt) (string-empty-p prompt))
              (list "--" prompt)))))

(defcustom claude-code-buffer-name-function #'claude-code--default-buffer-name
  "Function returning the name for a new instance's buffer.
Called with the project root; the name need not be unique.  It holds until
Claude sets a terminal title."
  :type 'function)

(defun claude-code--default-buffer-name (root)
  "Return the buffer name for a new instance in ROOT."
  (format "*claude: %s*" (file-name-nondirectory (directory-file-name root))))

(defun claude-code--ghostel-buffer-name (title)
  "Return \"*claude: TITLE*\" for the terminal TITLE, minus Claude's status glyph.
Return nil when nothing but the glyph is left."
  (when title
    (let ((clean (replace-regexp-in-string
                  "\\`[^[:alnum:][:space:]]+[[:space:]]+" "" title)))
      (unless (string= "" clean)
        (format "*claude: %s*" clean)))))

(defvar-local claude-code--names-held nil
  "Names this instance buffer has held, newest first, as (NAME . SINCE).
SINCE is the `float-time' at which NAME was taken.")

(defun claude-code--record-name ()
  "Log the current buffer's name in `claude-code--names-held' when it changed."
  (unless (equal (buffer-name) (caar claude-code--names-held))
    (push (cons (buffer-name) (float-time)) claude-code--names-held)))

(defun claude-code--name-at (buffer time)
  "Return the name BUFFER held at TIME, or nil when it did not exist yet."
  (car (seq-find (lambda (held) (<= (cdr held) time))
                 (buffer-local-value 'claude-code--names-held buffer))))

(defvar-keymap claude-code-instance-mode-map
  ;; Declared with a parent so `define-derived-mode' does not adopt
  ;; `ghostel-semi-char-mode-map' as one, leaking terminal bindings into copy
  ;; and emacs mode.
  :parent (make-sparse-keymap)
  :doc "Keymap active in every buffer hosting a Claude instance.
Its bindings outrank minor modes and Ghostel's terminal bindings, but not what
Ghostel puts in `emulation-mode-map-alists', such as char mode's map.  A parent
of your own may replace the empty one.")

(defvar-local claude-code--instance-keys nil
  "Non-nil in buffers where `claude-code-instance-mode-map' is active.")

(defvar claude-code--sessions-changed-hook nil
  "Hook run when this machine's sessions may have changed.")

(defun claude-code--sessions-changed ()
  "Run `claude-code--sessions-changed-hook'."
  (with-demoted-errors "claude-code: reporting a change: %S"
    (run-hooks 'claude-code--sessions-changed-hook)))

(defun claude-code--follow-cwd ()
  "Hand Ghostel the directory this buffer's `claude' process works in.
Claude sends no OSC 7 report, so this feeds Ghostel's handler for one."
  (when-let* ((cwd (claude-code--instance-cwd (current-buffer)))
              ((not (equal (file-name-as-directory cwd) default-directory))))
    ;; Ghostel skips the directory it last took, even if the buffer has left it.
    (setq ghostel--last-directory nil)
    (ghostel--update-directory cwd)))

(defun claude-code--follow-directory (record-id old new)
  "Follow the instance's directory when its root record changes state.
A `ghostel-program-status-functions' entry taking RECORD-ID, OLD and NEW."
  (when (and (string-empty-p record-id)
             (not (eq (plist-get old :state) (plist-get new :state))))
    (claude-code--follow-cwd)))

(defun claude-code--on-root-status (record-id old new)
  "Report a change of the instance's turn end.
A `ghostel-program-status-functions' entry taking RECORD-ID, OLD and NEW."
  (when-let* (((string-empty-p record-id))
              ((not (equal (claude-code--record-turn-end old)
                           (claude-code--record-turn-end new))))
              (entry (gethash (current-buffer) claude-code--managed))
              ((not (claude-code--entry-host entry))))
    (claude-code--sessions-changed)))

(defconst claude-code--pid-report "claude-code-pid"
  "The `ghostel-eval-cmds' name an instance's launch wrapper reports under.")

(defun claude-code--report-pid (pid)
  "Record PID, a decimal string, as this instance buffer's `claude' process."
  (when (string-match-p "\\`[0-9]+\\'" pid)
    (setq claude-code--pid (string-to-number pid))
    ;; Only the wrapper's report, which precedes Claude's output, is trusted.
    (setq ghostel-eval-cmds nil)
    (when-let* ((entry (gethash (current-buffer) claude-code--managed))
                ((not (claude-code--entry-host entry))))
      (claude-code--sessions-changed))))

(defun claude-code--refuse-bookmark ()
  "Refuse to bookmark an instance buffer."
  (user-error "A Claude instance cannot be bookmarked"))

(define-derived-mode claude-code-instance-mode ghostel-mode "Claude"
  "Major mode for a Ghostel terminal hosting a Claude instance.

\\{claude-code-instance-mode-map}"
  :interactive nil
  (use-local-map ghostel-semi-char-mode-map)
  (setq-local claude-code--instance-keys t)
  ;; Ghostel's input-mode commands replace the local map, but not this alist.
  (setq-local minor-mode-overriding-map-alist
              (cons (cons 'claude-code--instance-keys
                          claude-code-instance-mode-map)
                    minor-mode-overriding-map-alist))
  (setq-local ghostel-buffer-name-function #'claude-code--ghostel-buffer-name)
  (setq-local ghostel-eval-cmds
              (list (list claude-code--pid-report #'claude-code--report-pid)))
  ;; Ghostel saves the command line, initial prompt included, in desktop and
  ;; bookmark files, and a bookmark would run it again in an unmanaged terminal.
  (setq-local desktop-save-buffer nil)
  (setq-local bookmark-make-record-function #'claude-code--refuse-bookmark)
  (claude-code--record-name)
  (add-hook 'buffer-list-update-hook #'claude-code--record-name nil t)
  (add-hook 'ghostel-program-status-functions #'claude-code--follow-directory
            90 t)
  (add-hook 'ghostel-program-status-functions #'claude-code--on-root-status
            90 t)
  (setq-local vc-deduce-backend-nonvc-modes t))

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
  "Hook run once the last managed instance's buffer has closed.")

(defvar-local claude-code--exit-event nil
  "The event this instance's terminal ended on, nil while it runs.")

(defun claude-code--runs-on-p (buffer)
  "Return non-nil when BUFFER's instance goes on running without BUFFER."
  (and (plist-get (gethash buffer claude-code--managed) :detachable)
       (not (claude-code--held-instance-ended-p
             (buffer-local-value 'claude-code--exit-event buffer)))
       (or (claude-code--session-process buffer)
           (claude-code--instance-pid buffer))))

(defun claude-code--on-buffer-kill ()
  "Unregister the instance hosted in the buffer being killed."
  (when-let* ((entry (gethash (current-buffer) claude-code--managed)))
    (when (claude-code--runs-on-p (current-buffer))
      (message "Detached %s: its instance runs on as an external session"
               (buffer-name)))
    (remhash (current-buffer) claude-code--managed)
    (when (zerop (hash-table-count claude-code--managed))
      (run-hook-wrapped 'claude-code-last-instance-exit-hook
                        (lambda (handler)
                          (condition-case err (funcall handler)
                            ((error quit)
                             (message "claude-code: last-instance hook %S signalled: %S"
                                      handler err)))
                          nil)))
    (unless (claude-code--entry-host entry)
      (claude-code--sessions-changed))))

(defun claude-code--report-exit (buffer event)
  "Record the EVENT BUFFER's terminal ended on, reporting an abnormal end.
The report quotes the terminal's last lines, which die with BUFFER."
  (with-current-buffer buffer (setq claude-code--exit-event event))
  (unless (or (equal event "finished\n") (claude-code--runs-on-p buffer))
    (message "%s" (string-join
                   (cons (concat (buffer-name buffer) " " (string-trim event))
                         ;; Ghostel's filter joins the lines it wrapped.
                         (last (split-string (with-current-buffer buffer
                                               (filter-buffer-substring
                                                (point-min) (point-max)))
                                             "\n" t "[ \t]+")
                               3))
                   "\n"))))

(defun claude-code--register (id buffer origin worktree &optional detachable)
  "Register the instance BUFFER hosts, launched on session ID from ORIGIN.
WORKTREE is its worktree request and DETACHABLE whether it is detachable."
  (with-current-buffer buffer
    (setq-local ghostel-kill-buffer-on-exit t)
    (add-hook 'ghostel-exit-functions #'claude-code--report-exit nil t)
    (add-hook 'kill-buffer-hook #'claude-code--on-buffer-kill nil t))
  (puthash buffer
           (list :origin origin
                 :worktree (and (stringp worktree) worktree)
                 :session id
                 :detachable detachable)
           claude-code--managed)
  (unless (file-remote-p origin)
    (claude-code--watch-sessions)
    (claude-code--sessions-changed)))

(defvar claude-code--sessions-watch nil
  "(DIR . DESCRIPTOR) of the watch on this machine's sessions/, or nil.")

(defun claude-code--watch-sessions ()
  "Watch this machine's sessions/ unless it is watched already."
  (let ((dir (claude-code--sessions-dir)))
    (unless (and (equal (car claude-code--sessions-watch) dir)
                 (file-notify-valid-p (cdr claude-code--sessions-watch)))
      (when claude-code--sessions-watch
        (file-notify-rm-watch (cdr claude-code--sessions-watch)))
      (setq claude-code--sessions-watch
            (when-let* ((watch (ignore-error file-notify-error
                                 (claude-code--watch-sessions-dir
                                  #'claude-code--on-session-file))))
              (cons dir watch))))))

(defun claude-code--on-session-file (pid)
  "React to a change of the sessions/ file of PID, a process on this machine."
  (when-let* ((buffer (seq-find
                       (lambda (buffer)
                         (and (eql (claude-code--instance-pid buffer) pid)
                              (not (claude-code--entry-host
                                    (gethash buffer claude-code--managed)))))
                       (hash-table-keys claude-code--managed))))
    (with-demoted-errors "claude-code: following a directory: %S"
      (with-current-buffer buffer (claude-code--follow-cwd))))
  (claude-code--sessions-changed))

(defun claude-code--buffer (session)
  "Return the buffer of SESSION's instance.
Signal a `user-error' when the instance no longer runs in Emacs."
  (let ((buffer (claude-code-session-buffer session)))
    (unless (claude-code--session-process buffer)
      (user-error "Session %s is not running in Emacs"
                  (claude-code-session-id session)))
    buffer))

(defcustom claude-code-renderer nil
  "Renderer to force Claude instances onto, or nil for Claude's `tui' setting.
`inline' leaves the scrollback and the mouse to Emacs; `fullscreen' is the
alt-screen renderer with virtualized scrollback."
  :type '(choice (const :tag "Default -- Claude's own `tui' setting" nil)
                 (const :tag "Inline -- classic main-screen renderer" inline)
                 (const :tag "Fullscreen -- alt-screen, virtualized scrollback"
                        fullscreen)))

(defun claude-code--renderer-env ()
  "Return the (NAME . VALUE) environment cells `claude-code-renderer' asks for.
Signal a `user-error' for an unknown value."
  (pcase claude-code-renderer
    ('nil '())
    ('inline '(("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN" . "1")))
    ('fullscreen '(("CLAUDE_CODE_NO_FLICKER" . "1")
                   ;; Unset: an inherited one is read first and forces inline.
                   ("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN")))
    (other (user-error "Unknown `claude-code-renderer': %S" other))))

(defun claude-code--apply-env (cells)
  "Set the (NAME . VALUE) CELLS in the environment Ghostel will spawn into.
Call it from `ghostel-pre-spawn-hook', which binds `process-environment'."
  ;; The binding shares entries with Emacs's own environment, which `setenv'
  ;; would otherwise edit in place.
  (setq process-environment (copy-sequence process-environment))
  (dolist (cell cells)
    (setenv (car cell) (cdr cell))))

(defun claude-code--resolve-executable (program)
  "Return the name the host of `default-directory' runs PROGRAM by.
Signal a `user-error' when that host has no such executable."
  (let ((host (file-remote-p default-directory))
        (bare (not (file-name-directory program))))
    (or (if bare
            ;; A remote search path ends in `default-directory', which must not
            ;; supply PROGRAM.
            (let ((default-directory (concat host "/")))
              (executable-find program t))
          (let ((file (expand-file-name (if (file-name-absolute-p program)
                                            (concat host program)
                                          program))))
            (and (file-executable-p file) (file-local-name file))))
        (user-error "Cannot find `%s'%s%s" program
                    (if host (concat " on " host) "")
                    (if bare
                        (format-message " in `%s'"
                                        (if host 'tramp-remote-path 'exec-path))
                      "")))))

(defun claude-code--reporting-command (program args)
  "Return the command running PROGRAM with ARGS that first reports its PID.
A `/bin/sh' sends `claude-code--pid-report' as an OSC 52 eval with its own PID,
then `exec's PROGRAM under that PID."
  (append (list "/bin/sh" "-c"
                (format "printf '\\033]52;e;%s %%s\\a' $$; exec \"$0\" \"$@\""
                        claude-code--pid-report)
                program)
          args))

(defun claude-code--start-terminal (buffer command env &optional pid)
  "Run COMMAND as the terminal of an instance in BUFFER, with ENV set.
ENV is a list of (NAME . VALUE) cells.  PID is the instance's when it is
already known, and then no report of it is awaited."
  ;; Ahead of the spawn: Ghostel refuses a mode change once the terminal
  ;; process is live.
  (with-current-buffer buffer
    (claude-code-instance-mode)
    (when pid
      (setq-local ghostel-eval-cmds nil
                  claude-code--pid pid)))
  ;; Set from the hook, in the instance's buffer, where `process-environment'
  ;; may be buffer-local.
  (let ((env-hook (lambda () (claude-code--apply-env env))))
    ;; The default value is the one Ghostel reads in the instance's own buffer.
    (set-default 'ghostel-pre-spawn-hook
                 (cons env-hook (default-value 'ghostel-pre-spawn-hook)))
    (unwind-protect
        (ghostel-exec buffer (car command) (cdr command))
      (set-default 'ghostel-pre-spawn-hook
                   (delq env-hook (default-value 'ghostel-pre-spawn-hook)))))
  (claude-code--install-notifications buffer))

(defun claude-code--launch (id project-root detachable &rest opts)
  "Host a `claude' instance for session ID in a new buffer; return the buffer.
PROJECT-ROOT is where it is launched from, except that a worktree Claude built
is swapped for its parent, with `:worktree' defaulting to its name.  A non-nil
DETACHABLE makes the instance detachable.  OPTS are the other keywords
`claude-code--build-args' takes."
  (require 'ghostel)
  (require 'claude-code-mcp)
  (let* (;; Resolved first so a bad value aborts before a buffer is created.
         (renderer-env (claude-code--renderer-env))
         (root (claude-code--normalize-root project-root))
         (tree (claude-code--worktree-parent root))
         (root (or (car tree) root))
         (worktree (or (plist-get opts :worktree) (cdr tree)))
         (default-directory (file-name-as-directory root))
         (program (claude-code--resolve-executable claude-code-cli))
         (dtach (and detachable
                     (condition-case err
                         (claude-code--resolve-executable claude-code-dtach)
                       (user-error
                        (user-error "%s, which a detachable instance needs (see `%s')"
                                    (error-message-string err)
                                    'claude-code-detachable)))))
         (config (claude-code--config-env (file-remote-p root)))
         (buffer (generate-new-buffer
                  (funcall claude-code-buffer-name-function root)))
         (mcp (claude-code--mcp-wiring buffer))
         (command (claude-code--reporting-command
                   program
                   (append (car mcp)
                           ;; The leading `:worktree' outranks the one in OPTS.
                           (apply #'claude-code--build-args
                                  :session-id id :worktree worktree opts)))))
    (claude-code--start-terminal
     buffer
     (if dtach
         (claude-code--holding-command dtach (claude-code--new-uuid) command)
       command)
     (append renderer-env
             (list (cons "CLAUDE_CONFIG_DIR" config))
             (cdr mcp)))
    (claude-code--register id buffer root worktree (and detachable t))
    buffer))

(defun claude-code--detachable-default (root)
  "Return whether `claude-code-detachable' makes an instance in ROOT detachable."
  (pcase claude-code-detachable
    ('remote (and (file-remote-p root) t))
    (value (and value t))))

;;;###autoload
(cl-defun claude-code-spawn (project-root
                             &key prompt name worktree model effort
                             (detachable (claude-code--detachable-default
                                          project-root)))
  "Spawn a new Claude Code instance for PROJECT-ROOT; return (ID . BUFFER).
ID is the new session's id.  PROMPT is an initial prompt and NAME the session's
display name.  WORKTREE requests a git worktree: t for one Claude names, or the
name of one to enter or create.  MODEL and EFFORT set the model and the effort
level (\"low\" to \"max\").  DETACHABLE defaults to what
`claude-code-detachable' says for PROJECT-ROOT."
  (let ((id (claude-code--new-uuid)))
    (cons id (claude-code--launch id project-root detachable
                                  :prompt prompt :name name :worktree worktree
                                  :model model :effort effort))))

(defun claude-code--resume (root id binding detachable)
  "Resume session ID under ROOT with worktree BINDING; return its buffer.
A new instance is detachable when DETACHABLE is non-nil."
  (let ((runner (gethash id (claude-code--running (file-remote-p root)))))
    (cond
     ((bufferp runner) runner)
     (runner (user-error "Session %s is running outside Emacs" id))
     (t (claude-code--launch
         id root detachable :resume id
         :worktree (claude-code--resume-worktree
                    (claude-code--normalize-root root) binding))))))

;;;###autoload
(cl-defun claude-code-resume (project-root id
                              &key (detachable (claude-code--detachable-default
                                                project-root)))
  "Resume session ID for PROJECT-ROOT in a new instance; return its buffer.
When an instance Emacs manages already runs ID, return its buffer instead.
Refuses a session a `claude' outside Emacs runs.  DETACHABLE defaults to what
`claude-code-detachable' says for PROJECT-ROOT."
  (let ((root (claude-code--normalize-root project-root)))
    (claude-code--resume
     project-root id
     (plist-get (claude-code--transcript-for root id) :worktree-binding)
     detachable)))

;;;###autoload
(defun claude-code-attach (project-root id &optional name)
  "Attach to the detachable instance running session ID; return its buffer.
PROJECT-ROOT is a project listing the session.  The new buffer is named after
NAME, when given, until Claude's next title.  When an instance Emacs manages
already runs ID, return its buffer."
  (require 'ghostel)
  (let* ((root (claude-code--normalize-root project-root))
         (host (file-remote-p root))
         (runner (gethash id (claude-code--running host)))
         (socket (and (integerp runner) (claude-code--holder runner host))))
    (cond
     ((bufferp runner) runner)
     ((null runner) (user-error "Session %s is not running" id))
     ((null socket) (user-error "Session %s is running outside Emacs" id))
     ((not (file-exists-p (concat host socket)))
      (user-error "Session %s has lost its socket %s and cannot be attached"
                  id socket))
     (t
      (let* ((default-directory (file-name-as-directory
                                 (or (claude-code--pid-cwd runner host) root)))
             (dtach (claude-code--resolve-executable claude-code-dtach))
             (buffer (generate-new-buffer
                      ;; Claude repeats no title on attach.
                      (or (and name (claude-code--ghostel-buffer-name name))
                          (funcall claude-code-buffer-name-function root)))))
        (claude-code--start-terminal
         buffer (claude-code--attaching-command dtach socket) nil runner)
        (claude-code--register id buffer root nil t)
        buffer)))))

(defun claude-code-kill (session)
  "Kill the process running SESSION, leaving the session dead."
  (let ((id (claude-code-session-id session)))
    (cond
     ((claude-code-session-alive-p session)
      (let* ((buffer (claude-code--buffer session))
             (entry (gethash buffer claude-code--managed))
             (pid (claude-code--instance-pid buffer)))
        (cond
         ((not (plist-get entry :detachable))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buffer)))
         ((not pid)
          (user-error "Session %s has not reported its process yet" id))
         ((not (zerop (signal-process pid 'SIGTERM
                                      (claude-code--entry-host entry))))
          (user-error "Could not signal process %d of session %s" pid id)))))
     ((not (claude-code-session-external-p session))
      (user-error "Session %s is not running" id))
     (t
      (let* ((host (file-remote-p (or (claude-code-session-transcript session)
                                      (claude-code-session-holder session))))
             (runner (gethash id (claude-code--running host))))
        (cond
         ((bufferp runner)
          (user-error "Session %s runs in Emacs now; refresh to kill it" id))
         ((null runner) (user-error "Session %s is not running" id))
         ((not (zerop (signal-process runner 'SIGTERM host)))
          (user-error "Could not signal process %d of session %s"
                      runner id))))))))

(defun claude-code-detach (session)
  "Close alive SESSION's buffer, leaving its detachable instance running."
  (let ((buffer (claude-code--buffer session)))
    (unless (plist-get (gethash buffer claude-code--managed) :detachable)
      (user-error "Session %s is not detachable: closing it would kill it"
                  (claude-code-session-id session)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun claude-code-delete (session)
  "Delete dead SESSION's transcript from disk."
  (let* ((id (claude-code-session-id session))
         (file (claude-code-session-transcript session))
         (runner (gethash id (claude-code--running
                              (and file (file-remote-p file))))))
    (when (or (claude-code-session-alive-p session) (bufferp runner))
      (user-error "Refusing to delete alive session %s; kill it first" id))
    (when (or (claude-code-session-external-p session) runner)
      (user-error "Session %s is running outside Emacs" id))
    (unless (and file (file-exists-p file))
      (user-error "No transcript on disk for session %s" id))
    (claude-code--delete-transcript file)))

(defun claude-code-send-text (session text &optional submit)
  "Send TEXT to SESSION's instance, submitting with RET when SUBMIT is non-nil.
Claude collapses a long or many-line TEXT into a placeholder and runs no slash
command in it."
  (require 'ghostel)
  (with-current-buffer (claude-code--buffer session)
    ;; Pasted, since a long TEXT typed with its RET leaves the RET a newline.
    ;; An empty paste can make Claude read an image off the clipboard.
    (unless (string-empty-p text)
      (ghostel-paste-string text))
    (when submit (ghostel-send-key "return"))))

(defun claude-code-rename (session name)
  "Rename SESSION to NAME by sending a /rename command to its instance."
  (claude-code-send-text session (format "/rename %s" name) t))

(defun claude-code-interrupt (session)
  "Interrupt SESSION's instance by sending it a Ctrl-C keystroke.
Two in quick succession while Claude is idle make it exit."
  (require 'ghostel)
  (with-current-buffer (claude-code--buffer session)
    (ghostel-send-C-c)))

(defcustom claude-code-export-config-dir
  (expand-file-name "claude-code-export/" (xdg-cache-home))
  "Config directory the `claude' exporting a local transcript runs with.
The CLI creates it, and keeps nothing there worth keeping.  An export on a
remote host runs with ~/.cache/claude-code-export/ there."
  :type 'directory)

(defvar claude-code--export-timeout 30
  "Seconds a transcript export may take before it is abandoned.")

(defconst claude-code--export-request-id "claude-code"
  "The id of the one control request a transcript export sends.")

(defconst claude-code--export-exit "claude-code-exit"
  "The type of the line `claude-code--export-command' prints as the CLI exits.")

(defun claude-code--export-config-dir (host)
  "Return the config dir an export on HOST runs with, as that host names it."
  (if host
      (file-name-concat (claude-code--remote-home host)
                        ".cache/claude-code-export/")
    (expand-file-name claude-code-export-config-dir)))

(defun claude-code--export-args (file)
  "Return the CLI arguments that export transcript FILE on request."
  ;; Answering `export_conversation' costs no API call.  `--safe-mode' keeps
  ;; the directory's hooks and MCP servers out but every built-in tool in, as
  ;; the export leaves out calls to a tool not loaded.  FILE goes as a path
  ;; because the export's own config dir knows no session ids.
  (list "-p" "--safe-mode" "--input-format" "stream-json"
        "--output-format" "stream-json" "--verbose"
        "--no-session-persistence" (concat "--resume=" file)))

(defun claude-code--export-command (program file)
  "Return the command with which PROGRAM exports transcript FILE.
A `/bin/sh' pipes the export request to PROGRAM and holds that pipe open until
a line arrives on its own input.  Once PROGRAM exits, the shell prints a line
of type `claude-code--export-exit' carrying its exit status, then its stderr."
  ;; The CLI reads no request from a terminal, which is all TRAMP gives a
  ;; remote process.  It drops a request whose input ends right after it, and
  ;; exits only once its input ends, which TRAMP cannot signal.  Its stderr
  ;; waits for the exit so it cannot split the one-line answer, and `cat'
  ;; keeps its stdout off a terminal, where it pads prompt rows to 80 columns.
  (append (list "/bin/sh" "-c"
                (concat "r=$1; shift; { printf '%s\\n' \"$r\"; read -r _; } | "
                        "{ e=$(\"$0\" \"$@\" 2>&1 >&3 3>&-); "
                        (format "printf '\\n{\"type\":\"%s\",\"status\":%%d}\\n%%s'"
                                claude-code--export-exit)
                        " $? \"$e\"; } 3>&1 2>&1 | cat")
                program
                (json-serialize
                 `((type . "control_request")
                   (request_id . ,claude-code--export-request-id)
                   (request (subtype . "export_conversation")))))
          (claude-code--export-args file)))

(defun claude-code--export-outcome (line)
  "Return what stdout LINE of a transcript export tells, or nil for nothing.
That is (text . TEXT) for the exported text, (error . MESSAGE) for a failure
the CLI reported, or (exit . STATUS) for the CLI's exit status."
  (when-let* ((obj (ignore-errors
                     (json-parse-string line :null-object nil
                                        :false-object nil)))
              ((hash-table-p obj)))
    (pcase (gethash "type" obj)
      ("control_response"
       (when-let* ((response (gethash "response" obj))
                   ((hash-table-p response))
                   ((equal (gethash "request_id" response)
                           claude-code--export-request-id)))
         (let* ((body (gethash "response" response))
                (text (and (hash-table-p body) (gethash "text" body))))
           (if (and (equal (gethash "subtype" response) "success")
                    (stringp text))
               (cons 'text text)
             (cons 'error (format "%s" (or (gethash "error" response)
                                           "malformed answer")))))))
      ("result"
       (when (gethash "is_error" obj)
         (let* ((errors (gethash "errors" obj))
                (message (if (and (vectorp errors) (> (length errors) 0))
                             (mapconcat (lambda (e) (format "%s" e)) errors "; ")
                           (format "%s" (gethash "subtype" obj)))))
           ;; For a transcript holding no conversation, the CLI names a
           ;; session id it made up.
           (cons 'error (if (string-prefix-p "No conversation found" message)
                            "No conversation to export"
                          message)))))
      ((pred (equal claude-code--export-exit))
       (let ((status (gethash "status" obj)))
         (and (integerp status) (cons 'exit status)))))))

(defun claude-code--export-file (session root)
  "Return SESSION's transcript file as it lies now, or signal a `user-error'.
ROOT is the project SESSION is listed under."
  (let ((id (claude-code-session-id session))
        (file (claude-code-session-transcript session)))
    (or (and file (file-exists-p file) file)
        ;; Claude can move a transcript to another project directory.
        (plist-get (claude-code--transcript-for
                    (claude-code--normalize-root root) id)
                   :transcript)
        (user-error "No transcript on disk for session %s" id))))

(defun claude-code--export-settle (proc)
  "Mark PROC's export settled; return non-nil unless it already was."
  (unless (process-get proc 'claude-code-settled)
    (process-put proc 'claude-code-settled t)))

(defun claude-code--export-terminate (proc)
  "Send SIGTERM to export PROC's process group, a hung CLI under its shell too."
  (signal-process (- (process-id proc)) 'SIGTERM))

(defun claude-code--export-cancel (proc)
  "Abandon the export PROC runs, calling neither of its callbacks."
  (when (and (claude-code--export-settle proc) (process-live-p proc))
    (claude-code--export-terminate proc)))

(defun claude-code-export-transcript (session root on-text &optional on-error)
  "Export SESSION's transcript as text; return the exporting process.
ROOT is the project SESSION is listed under.  ON-TEXT is called with the text,
or ON-ERROR, `message' by default, with why there is none.  Signals a
`user-error' when SESSION has no transcript on disk or its host cannot run the
CLI.  The text is the conversation as Claude's export lays it out, 80 columns
wide and without MCP tool calls."
  (let* ((file (claude-code--export-file session root))
         (on-error (or on-error (lambda (msg) (message "%s" msg))))
         ;; Claude prints a tool's path under its cwd relative to it.
         (default-directory (file-name-as-directory
                             (claude-code--session-directory session root)))
         ;; A `claude -p' registers in sessions/ as running the session it
         ;; resumes, so the export gets a config dir of its own.
         (process-environment
          (cons (concat "CLAUDE_CONFIG_DIR="
                        (claude-code--export-config-dir
                         (file-remote-p default-directory)))
                process-environment))
         (pending '())
         (released nil)
         (status nil)
         (stderr '())
         (proc
          (make-process
           :name "claude-code-export" :noquery t :file-handler t
           :command (claude-code--export-command
                     (claude-code--resolve-executable claude-code-cli)
                     (file-local-name file))
           :connection-type 'pipe
           :filter
           (lambda (proc chunk)
             ;; The answer is one line, as long as the transcript.
             (let ((start 0) newline)
               (while (and (not status)
                           (setq newline (string-search "\n" chunk start)))
                 (push (substring chunk start newline) pending)
                 (let ((outcome (claude-code--export-outcome
                                 (apply #'concat (nreverse pending)))))
                   (setq pending '())
                   ;; The shell holds the CLI's input open until a line comes.
                   (when (and outcome (not released) (process-live-p proc))
                     (setq released t)
                     (process-send-string proc "\n"))
                   (pcase outcome
                     (`(exit . ,code) (setq status code))
                     (`(,kind . ,value)
                      (when (claude-code--export-settle proc)
                        (funcall (if (eq kind 'text) on-text on-error)
                                 value)))))
                 (setq start (1+ newline)))
               (if status
                   (push (substring chunk start) stderr)
                 (push (substring chunk start) pending))))
           :sentinel
           (lambda (proc event)
             (unless (process-live-p proc)
               (cancel-timer (process-get proc 'claude-code-timer))
               (when (claude-code--export-settle proc)
                 (funcall on-error
                          (if status
                              (let ((text (string-trim
                                           (apply #'concat (nreverse stderr)))))
                                (format "%s exited with status %d and no transcript%s"
                                        claude-code-cli status
                                        (if (string-empty-p text)
                                            ""
                                          (concat ": " text))))
                            (format "%s ended with no transcript: %s"
                                    claude-code-cli (string-trim event))))))))))
    ;; TRAMP picks a remote process's coding system itself.
    (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
    ;; Kept after the answer, to end a CLI that hangs once its input closes.
    (process-put proc 'claude-code-timer
                 (run-at-time claude-code--export-timeout nil
                              (lambda ()
                                (when (process-live-p proc)
                                  (claude-code--export-terminate proc))
                                (when (claude-code--export-settle proc)
                                  (funcall on-error
                                           (format "Export timed out after %ss"
                                                   claude-code--export-timeout))))))
    proc))


;;;; Notifications

;; `notifications' needs a D-Bus build, so it is required where it is used.
(declare-function notifications-notify "notifications" (&rest params))
(declare-function dbus-call-method-asynchronously "dbus"
                  (bus service path interface method handler &rest args))
(defvar notifications-service)
(defvar notifications-path)
(defvar notifications-interface)
(defvar notifications-close-notification-method)

(defcustom claude-code-notify-function #'claude-code-notify-desktop
  "Function announcing that an instance wants the user's attention, or nil.
Called with the instance's `claude-code-session' and the message to show."
  :type '(choice (const :tag "Disabled" nil) function))

(defcustom claude-code-notify-desktop-entry "emacs"
  "Basename of the desktop entry this Emacs runs as.
A click on a notification raises the application it names, so it must match
an installed desktop file for the click to reach Emacs."
  :type 'string)

(defcustom claude-code-notify-urgency 'critical
  "Urgency `claude-code-notify-desktop' sends with every notification."
  :type '(choice (const :tag "Low -- listed, never bannered" low)
                 (const :tag "Normal -- times out, hidden by fullscreen" normal)
                 (const :tag "Critical -- shows over fullscreen, stays up" critical)))

(defvar claude-code--notify-activation-window 1.0
  "Seconds a dismissed notification waits for the desktop to raise Emacs.")

(defvar claude-code--notify-claim nil
  "The activation window claimed by the first close of a burst, or nil.
A cons (WATCH . TIMER), where WATCH is nil when Emacs already held focus.")

(defun claude-code--frame-focused-p (frame)
  "Non-nil when FRAME is on screen and holds input focus."
  ;; A minimized frame keeps the focus state it was left with.
  (and (eq (frame-visible-p frame) t) (eq (frame-focus-state frame) t)))

(defun claude-code--focused-p ()
  "Non-nil when any frame has input focus."
  (seq-some #'claude-code--frame-focused-p (frame-list)))

(defun claude-code--on-screen-p (buffer)
  "Non-nil when BUFFER is displayed on a frame holding input focus."
  (seq-some (lambda (window)
              (claude-code--frame-focused-p (window-frame window)))
            (get-buffer-window-list buffer nil t)))

(defun claude-code--notify (buffer body)
  "Announce BODY from BUFFER's instance via `claude-code-notify-function'."
  (when-let* (((and claude-code-notify-function
                    (claude-code--session-process buffer)
                    (not (claude-code--on-screen-p buffer))))
              (session (claude-code--instance-session buffer)))
    (funcall claude-code-notify-function session body)))

(defvar claude-code--notify-settle 0.5
  "Seconds a reported state must hold before it is announced.
It must give Claude time to rewrite its sessions/ status after the report.")

(defvar-local claude-code--working-since nil
  "When the instance in this buffer set to work after resting, or nil.")

(defvar-local claude-code--pending nil
  "The timer announcing the root state of this buffer's instance, or nil.")

(defun claude-code--install-notifications (buffer)
  "Announce BUFFER's instance from its status reports, in Ghostel's place."
  (with-current-buffer buffer
    (setq-local ghostel-notification-functions nil)
    (setq-local ghostel-status-notify-states nil)
    (add-hook 'ghostel-program-status-functions #'claude-code--on-status nil t)
    (add-hook 'window-buffer-change-functions #'claude-code--schedule-seen
              nil t))
  (add-function :after after-focus-change-function
                #'claude-code--schedule-seen))

(defun claude-code--on-status (record-id old new)
  "Track the current buffer's status record RECORD-ID changing from OLD to NEW."
  ;; "" is the root record, which speaks for the session.
  (when (string-empty-p record-id)
    (let ((state (plist-get new :state)))
      (unless (eq state (plist-get old :state))
        (pcase state
          ('working (unless claude-code--working-since
                      (setq claude-code--working-since (float-time))))
          ((or 'idle 'nil) (setq claude-code--working-since nil)))
        (when claude-code--pending
          (cancel-timer claude-code--pending))
        (setq claude-code--pending
              (when (memq state '(done blocked error))
                (let ((buffer (current-buffer))
                      (reported (float-time)))
                  (run-at-time claude-code--notify-settle nil
                               (lambda ()
                                 (claude-code--announce buffer state
                                                        reported))))))
        (claude-code--close-posted)))))

(defun claude-code--announce (buffer state reported)
  "Announce BUFFER's instance entering root STATE, reported at time REPORTED."
  (when (and (claude-code--session-process buffer)
             ;; Claude's sessions/ status reads `shell' while a background shell
             ;; task runs, monitors included, and the task can start the next
             ;; turn.  A remote status is only as fresh as the last query.
             (not (and (eq state 'done)
                       (let ((entry (claude-code--instance-entry buffer)))
                         (and (not (claude-code--entry-host entry))
                              (equal (plist-get (plist-get entry :info) :status)
                                     "shell"))))))
    (with-current-buffer buffer
      (let ((since claude-code--working-since))
        (unless (eq state 'blocked)
          (setq claude-code--working-since nil))
        (claude-code--notify
         buffer (or (cdr (claude-code--root-status buffer))
                    (claude-code--status-message state since reported)))))))

(defun claude-code--status-message (state since reported)
  "Return the body announcing root STATE, reported at time REPORTED.
SINCE is when the stretch of work it ends began, or nil."
  (pcase state
    ('done (if (and since (>= (- reported since) 1))
               (format "Finished after %s"
                       (format-seconds "%hh %mm %z%ss%x" (- reported since)))
             "Finished"))
    ('blocked "Waiting for you")
    ('error "Stopped on an error")))

(defun claude-code--notify-retire ()
  "Release the activation window, if one is claimed."
  (when-let* ((claim claude-code--notify-claim))
    (setq claude-code--notify-claim nil)
    (when (car claim)
      (remove-function after-focus-change-function (car claim)))
    (cancel-timer (cdr claim))))

(defun claude-code--display-frames ()
  "Return the frames a jump may land on: this display's, the selected one first.
A minimized frame counts; an invisible one does not."
  (let ((here (selected-frame)))
    (cons here (seq-filter (lambda (frame)
                             (and (frame-visible-p frame)
                                  (eq (frame-terminal frame)
                                      (frame-terminal here))))
                           (remq here (frame-list))))))

(defun claude-code--tab-shows-p (tab buffer frame)
  "Non-nil when TAB, a background tab of FRAME, shows BUFFER."
  (when-let* ((ws (alist-get 'ws tab))
              ;; WS names buffers as of when TAB was left.  Selecting TAB brings
              ;; back those buffers if its window configuration belongs to
              ;; FRAME, else whichever buffers hold those names now.
              (name (let ((wc (alist-get 'wc tab))
                          (time (alist-get 'time tab)))
                      (if (and time
                               (window-configuration-p wc)
                               (eq (window-configuration-frame wc) frame))
                          (claude-code--name-at buffer time)
                        (buffer-name buffer)))))
    (member name (window-state-buffers ws))))

(defun claude-code--tab-showing (buffer frame)
  "Return the background tab of FRAME showing BUFFER, or nil.
When several do, the one left most recently."
  ;; `tab-bar-tabs' would rename an unselected FRAME's current tab after the
  ;; selected frame's buffer.
  (car (sort (seq-filter (lambda (tab)
                           (claude-code--tab-shows-p tab buffer frame))
                         (frame-parameter frame 'tabs))
             :key (lambda (tab) (alist-get 'time tab 0))
             :reverse t)))

(defun claude-code--instance-place (buffer)
  "Return where BUFFER is displayed: a window, (FRAME . TAB), or nil."
  (let ((frames (claude-code--display-frames)))
    (or (seq-some (lambda (frame) (get-buffer-window buffer frame)) frames)
        (seq-some (lambda (frame)
                    (when-let* ((tab (claude-code--tab-showing buffer frame)))
                      (cons frame tab)))
                  frames))))

(defun claude-code--jump-to (buffer)
  "Select a window showing BUFFER, in whatever tab and frame, or pop it up."
  (pcase (claude-code--instance-place buffer)
    ((and (pred windowp) window)
     (unless (eq (window-frame window) (selected-frame))
       (select-frame-set-input-focus (window-frame window)))
     (select-window window))
    (`(,frame . ,tab)
     (unless (eq frame (selected-frame))
       (select-frame-set-input-focus frame))
     ;; `tab-bar-select-tab' numbers tabs as `tab-bar-tabs-function' lists them.
     (when-let* ((index (seq-position (funcall tab-bar-tabs-function) tab #'eq)))
       (let ((inhibit-message t))
         (tab-bar-select-tab (1+ index))))
     (if-let* ((window (get-buffer-window buffer)))
         (select-window window)
       (pop-to-buffer buffer)))
    (_ (pop-to-buffer buffer))))

(defun claude-code--notify-show (buffer)
  "Display the instance BUFFER hosts, unless it has exited by then."
  ;; Not inside the D-Bus handler or focus hook that asked for it.
  (run-at-time 0 nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (claude-code--jump-to buffer)))))

(defun claude-code--notify-follow (buffer)
  "Display BUFFER's instance if its notification was the one clicked."
  ;; A click dismisses the notifications grouped with it too, so only the
  ;; first close of a burst counts.
  (unless claude-code--notify-claim
    (let ((expiry (run-at-time claude-code--notify-activation-window nil
                               #'claude-code--notify-retire)))
      (if (claude-code--focused-p)
          ;; With no raise coming, a wave-away jumps too.
          (progn
            (setq claude-code--notify-claim (cons nil expiry))
            (claude-code--notify-show buffer))
        (let (watch)
          ;; Only a click raises Emacs.  The claim outlives the watch, so a
          ;; close arriving behind the raise cannot jump again.
          (setq watch (lambda ()
                        (when (claude-code--focused-p)
                          (remove-function after-focus-change-function watch)
                          (claude-code--notify-show buffer))))
          (setq claude-code--notify-claim (cons watch expiry))
          (add-function :after after-focus-change-function watch))))))

(defvar-local claude-code--posted nil
  "Desktop notifications posted for the instance in this buffer, still up.")

(defvar-local claude-code--close-count 0
  "How many times `claude-code--close-posted' has run in this buffer.")

(defun claude-code--close-notification (notification)
  "Ask the desktop to close NOTIFICATION, without waiting for its answer."
  ;; An error escaping `kill-buffer-hook' would keep the buffer alive.
  (with-demoted-errors "claude-code: closing a notification: %S"
    ;; Waiting inside Ghostel's status hook would let Ghostel handle newer
    ;; terminal output ahead of older output still queued.
    (dbus-call-method-asynchronously
     :session notifications-service notifications-path notifications-interface
     notifications-close-notification-method nil :uint32 notification)))

(defun claude-code--close-posted ()
  "Close the desktop notifications still up for this buffer's instance."
  (cl-incf claude-code--close-count)
  (mapc #'claude-code--close-notification claude-code--posted)
  (setq claude-code--posted nil))

(defvar claude-code--seen-timer nil
  "The timer about to close the notifications of instances in sight, or nil.")

(defun claude-code--schedule-seen (&rest _)
  "Close the notifications of every instance in sight, from a timer."
  (unless claude-code--seen-timer
    (setq claude-code--seen-timer
          (run-at-time 0 nil #'claude-code--close-seen))))

(defun claude-code--close-seen ()
  "Close the notifications of every managed instance now on screen."
  (setq claude-code--seen-timer nil)
  (dolist (buffer (hash-table-keys claude-code--managed))
    (when (and (buffer-live-p buffer)
               (claude-code--on-screen-p buffer))
      (with-current-buffer buffer (claude-code--close-posted)))))

(defun claude-code--unwatch-focus ()
  "Stop closing notifications on focus changes, once no instance is left."
  (remove-function after-focus-change-function #'claude-code--schedule-seen))

(add-hook 'claude-code-last-instance-exit-hook #'claude-code--unwatch-focus)

(defun claude-code-notify-desktop (session body)
  "Post BODY as a desktop notification that jumps to SESSION when clicked."
  (require 'notifications)
  (let* ((buffer (claude-code-session-buffer session))
         (live (buffer-live-p buffer))
         (count (and live (buffer-local-value 'claude-code--close-count buffer)))
         (posted
          (notifications-notify
           :title (claude-code--session-display-name session)
           :body body
           :desktop-entry claude-code-notify-desktop-entry
           :urgency claude-code-notify-urgency
           :on-close (lambda (notification reason)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (setq claude-code--posted
                                 (delq notification claude-code--posted))))
                       ;; A click closes it as `dismissed', like a wave-away.
                       (when (eq reason 'dismissed)
                         (claude-code--notify-follow buffer))))))
    ;; While posting waits on D-Bus, the buffer can close its notifications
    ;; or be killed.
    (when live
      (if (and (buffer-live-p buffer)
               (= count (buffer-local-value 'claude-code--close-count buffer)))
          (with-current-buffer buffer
            (push posted claude-code--posted)
            (add-hook 'kill-buffer-hook #'claude-code--close-posted nil t))
        (claude-code--close-notification posted)))))


;;;; View

(defvar-local claude-code--project nil
  "Project root a sessions view is scoped to.")
(defvar-local claude-code--group-by 'state
  "How the sessions view groups rows: `state' (liveness) or `status'.")
(defvar-local claude-code--collapsed nil
  "List of collapsed group names in a sessions view.")
(defvar-local claude-code--marks nil
  "List of the row keys of the marked rows in a sessions view.")
(defvar-local claude-code--session-table nil
  "Hash of row key -> struct for every row `claude-code--read-view' read.")
(defvar-local claude-code--usage-table nil
  "Hash of row key -> (CPU . RSS) for the alive rows `claude-code--read-view' read.")
(defvar-local claude-code--stale nil
  "Non-nil when a change reached a sessions view while no window showed it.")

;;;;; Formatting

(defun claude-code--row-key (session)
  "Return the key of SESSION's row: its instance's buffer, or else its id."
  ;; An instance keeps its row across `/clear', `/resume' and `/branch'.
  (or (claude-code-session-buffer session) (claude-code-session-id session)))

(defun claude-code--status-display (session)
  "Return (STRING . FACE) describing SESSION's liveness and status."
  (pcase (claude-code--session-liveness session)
    ('alive (pcase (claude-code-session-status session)
              ("busy" (cons "busy" 'warning))
              ("shell" (cons "shell" 'success))
              ("idle" (cons "idle" 'success))
              ("waiting" (cons "waiting" 'error))
              ('nil (cons "alive" 'default))
              (raw (cons (format "unknown (%s)" raw) 'default))))
    ('external (cons "external" 'font-lock-comment-face))
    ('dead (cons "dead" 'shadow))))

(defun claude-code--format-relative-time (time now)
  "Return a compact age string for TIME relative to NOW.
The empty string is returned when TIME is nil."
  (if (null time)
      ""
    (let ((secs (max 0 (floor (- (float-time now)
                                 (float-time time))))))
      (cond ((< secs 60) (format "%ds" secs))
            ((< secs 3600) (format "%dm" (/ secs 60)))
            ((< secs 86400) (format "%dh" (/ secs 3600)))
            ((< secs 604800) (format "%dd" (/ secs 86400)))
            (t (format "%dw" (/ secs 604800)))))))

(defun claude-code--turn-end-glyph (session)
  "Return the glyph for SESSION's turn end, or nil for none."
  (pcase (claude-code-session-turn-end session)
    ('done (propertize "✓" 'face 'success 'help-echo "Turn finished"))
    ('error (propertize "✗" 'face 'error 'help-echo "Turn failed"))))

(defconst claude-code--attachable-glyph
  (propertize "⇄" 'help-echo "Detached instance: RET attaches it")
  "The glyph following an attachable external session's status.")

(defun claude-code--format-session (session usage now)
  "Return the column vector for SESSION.
USAGE is (CPU . RSS) or nil.  NOW anchors the Active column's age."
  (let ((status (claude-code--status-display session))
        (glyph (if (claude-code-session-holder session)
                   claude-code--attachable-glyph
                 (claude-code--turn-end-glyph session))))
    (vector (concat (propertize (car status) 'face (cdr status))
                    (and glyph (concat " " glyph)))
            (propertize (claude-code--format-relative-time
                         (claude-code-session-last-active session) now)
                        'face 'shadow)
            (propertize (string-limit (claude-code-session-id session) 8)
                        'face 'shadow)
            (or (claude-code-session-worktree session) "")
            (if usage (format "%.1f" (car usage)) "")
            (if usage (format "%dM" (/ (cdr usage) 1024)) "")
            (claude-code--session-display-name session))))

;;;;; Grouping

(defun claude-code--status-key (session)
  "Return the name of SESSION's status, or of its liveness when it has none."
  (let ((liveness (claude-code--session-liveness session)))
    (if (eq liveness 'alive)
        (or (claude-code-session-status session) "alive")
      (symbol-name liveness))))

(defun claude-code--group-key (session)
  "Return the group key of SESSION under the current grouping."
  (if (eq claude-code--group-by 'status)
      (claude-code--status-key session)
    (symbol-name (claude-code--session-liveness session))))

(defun claude-code--group-rank (key)
  "Return the display rank of group KEY; lower ranks come first."
  (or (alist-get key '(("waiting" . 0) ("idle" . 1) ("shell" . 2) ("busy" . 3)
                       ("alive" . 4) ("external" . 8) ("dead" . 9))
                 nil nil #'equal)
      5))

(defun claude-code--group-less-p (a b)
  "Return non-nil when group A should sort before group B."
  (< (claude-code--group-rank a) (claude-code--group-rank b)))

(defun claude-code--group-header (key sessions collapsed)
  "Return the header line for group KEY holding SESSIONS.
A COLLAPSED group's header also counts the marks, turn ends and attachable
sessions it hides."
  (let ((counts
         (when collapsed
           (cl-loop for (label . pred)
                    in `(("marked" . ,(lambda (s)
                                        (member (claude-code--row-key s)
                                                claude-code--marks)))
                         ("done" . ,(lambda (s)
                                      (eq (claude-code-session-turn-end s) 'done)))
                         ("error" . ,(lambda (s)
                                       (eq (claude-code-session-turn-end s) 'error)))
                         ("attachable" . ,#'claude-code-session-holder))
                    for n = (seq-count pred sessions)
                    unless (zerop n) collect (format "%d %s" n label)))))
    (propertize (format "%s %s (%s)" (if collapsed "▸" "▾") (capitalize key)
                        (string-join (cons (number-to-string (length sessions))
                                           counts)
                                     ", "))
                'claude-code-group key 'face 'bold)))

(defun claude-code--num-sorter (get)
  "Return a tabulated-list sorter over usage values read with GET.
GET picks the compared number out of a (CPU . RSS) pair; a row with no usage
sorts lowest."
  (lambda (a b)
    (< (or (funcall get (gethash (car a) claude-code--usage-table)) -1)
       (or (funcall get (gethash (car b) claude-code--usage-table)) -1))))

(defun claude-code--entry-time (entry)
  "Return the last-active time of ENTRY's session as a float, infinity if unknown."
  (if-let* ((session (gethash (car entry) claude-code--session-table))
            (time (claude-code-session-last-active session)))
      (float-time time)
    ;; No time means no transcript yet: the session is the newest.
    1.0e+INF))

(defun claude-code--time-less-p (a b)
  "Order tabulated-list entries A and B by their session's last-active time."
  (< (claude-code--entry-time a) (claude-code--entry-time b)))

(defun claude-code--status-order (entry)
  "Return ENTRY's position in the Status column's order, lowest most urgent."
  (let* ((session (gethash (car entry) claude-code--session-table))
         (turn-end (claude-code-session-turn-end session)))
    (list (claude-code--group-rank (claude-code--status-key session))
          (cond ((claude-code-session-holder session) 2)
                ((eq turn-end 'error) 0)
                ((eq turn-end 'done) 1)
                (t 3))
          (- (claude-code--entry-time entry)))))

(defun claude-code--status-less-p (a b)
  "Order tabulated-list entries A and B most urgent first."
  (value< (claude-code--status-order a) (claude-code--status-order b)))

(defun claude-code--read-view ()
  "Read the current view's sessions and their usage into its tables.
Also prune `claude-code--marks' to the rows read."
  (let* ((sessions (claude-code-project-sessions claude-code--project))
         (host (file-remote-p claude-code--project))
         ;; One table shared by every row, and built only where a subtree
         ;; cannot be sampled on its own.
         (snapshot (when (and (or host (not claude-code--proc-children-p))
                              (seq-some #'claude-code-session-pid sessions))
                     (claude-code--process-snapshot host))))
    (setq claude-code--stale nil)
    (clrhash claude-code--session-table)
    (clrhash claude-code--usage-table)
    (dolist (session sessions)
      (let ((row (claude-code--row-key session)))
        (puthash row session claude-code--session-table)
        (when (and (claude-code-session-alive-p session)
                   (claude-code-session-pid session))
          (puthash row (claude-code--process-usage
                        (claude-code-session-pid session) snapshot)
                   claude-code--usage-table))))
    (setq claude-code--marks
          (seq-filter (lambda (row) (gethash row claude-code--session-table))
                      claude-code--marks))))

(defun claude-code--tabulated-groups ()
  "Return the grouped rows of the view's last read, honouring collapse state."
  (let ((now (current-time))
        (buckets (make-hash-table :test 'equal))
        (order '()))
    (maphash (lambda (_row session)
               (let ((key (claude-code--group-key session)))
                 (push key order)
                 (push session (gethash key buckets))))
             claude-code--session-table)
    (setq order (sort (delete-dups order) #'claude-code--group-less-p))
    (mapcar
     (lambda (key)
       (let ((rows (nreverse (gethash key buckets)))
             (collapsed (member key claude-code--collapsed)))
         (cons (claude-code--group-header key rows collapsed)
               (unless collapsed
                 (mapcar (lambda (s)
                           (let ((row (claude-code--row-key s)))
                             (list row
                                   (claude-code--format-session
                                    s (gethash row claude-code--usage-table)
                                    now))))
                         rows)))))
     order)))

;;;;; Marks and refresh

(defun claude-code--session-at-point ()
  "Return the session on the current line, or nil on a group header."
  (when-let* ((id (tabulated-list-get-id)))
    (gethash id claude-code--session-table)))

(defun claude-code--eldoc-session (&rest _)
  "Return the turn end's message and the recap of the session at point, or nil."
  (when-let* ((session (claude-code--session-at-point))
              (parts (delq nil (list (claude-code-session-turn-end-message session)
                                     (claude-code-session-recap session)))))
    (string-join parts "\n\n")))

(defun claude-code--group-at-point ()
  "Return the key of the group the current line belongs to, or nil."
  (or (get-text-property (line-beginning-position) 'claude-code-group)
      (when-let* ((s (claude-code--session-at-point)))
        (claude-code--group-key s))))

(defun claude-code--goto-line-where (predicate)
  "Move point to the first line PREDICATE, called at its start, accepts.
Return nil and leave point alone when no line matches."
  (when-let* ((pos (save-excursion
                     (goto-char (point-min))
                     (catch 'found
                       (while (not (eobp))
                         (when (funcall predicate) (throw 'found (point)))
                         (forward-line 1))))))
    (goto-char pos)))

(defun claude-code--goto-group (key)
  "Move point to the header line of group KEY, when that group is displayed."
  (and key
       (claude-code--goto-line-where
        (lambda () (equal key (get-text-property (point) 'claude-code-group))))))

(defun claude-code--print-entry (id cols)
  "Print the row for ID with COLS, tagging it when ID is in `claude-code--marks'."
  (let ((start (point)))
    (tabulated-list-print-entry id cols)
    (put-text-property start (point) 'claude-code-session
                       (claude-code-session-id
                        (gethash id claude-code--session-table))))
  ;; Tagging here keeps marks through tabulated-list's own reprints.
  (when (member id claude-code--marks)
    (save-excursion
      (forward-line -1)
      (tabulated-list-put-tag "*"))))

(defun claude-code--target-sessions (&rest liveness)
  "Return the marked sessions, or the session at point when none are marked.
LIVENESS, when given, are the liveness states to keep."
  (let ((targets (if claude-code--marks
                     (delq nil (mapcar (lambda (row)
                                         (gethash row claude-code--session-table))
                                       claude-code--marks))
                   (when-let* ((s (claude-code--session-at-point))) (list s)))))
    (if liveness
        (seq-filter (lambda (s) (memq (claude-code--session-liveness s) liveness))
                    targets)
      targets)))

(defun claude-code--act-on (targets operation done)
  "Call OPERATION on each session in TARGETS, then update the views on their host.
A target OPERATION refuses with a `user-error' is skipped and stays marked; the
refusals are reported after DONE, the verb for the targets acted on."
  (let ((acted '())
        (refused '()))
    (unwind-protect
        (dolist (session targets)
          (condition-case err
              (progn (funcall operation session)
                     (push (claude-code--row-key session) acted))
            (user-error (push (error-message-string err) refused))))
      (claude-code--drop-marks acted)
      (claude-code--refresh-views (file-remote-p claude-code--project)))
    (when refused
      (message "%s %d, refused %d: %s" done (length acted) (length refused)
               (string-join (nreverse refused) "; ")))))

(defun claude-code--view-outdated-p ()
  "Return non-nil when Emacs knows a remote view no longer shows its instances."
  (when (file-remote-p claude-code--project)
    (or (seq-some
         (lambda (session)
           (let ((buffer (claude-code-session-buffer session)))
             (or (not (claude-code--session-process buffer))
                 (not (eql (claude-code-session-pid session)
                           (claude-code--instance-pid buffer)))
                 (not (equal (and (claude-code-session-turn-end session)
                                  (cons (claude-code-session-turn-end session)
                                        (claude-code-session-turn-end-message
                                         session)))
                             (claude-code--record-turn-end
                              (claude-code--root-record buffer)))))))
         (seq-filter #'claude-code-session-alive-p
                     (hash-table-values claude-code--session-table)))
        (cl-loop for buffer being the hash-keys of claude-code--managed
                 using (hash-values entry)
                 thereis (and (claude-code--session-process buffer)
                              (claude-code--under-root-p (plist-get entry :origin)
                                                         claude-code--project)
                              (not (gethash buffer
                                            claude-code--session-table)))))))

(defun claude-code--offer-refresh ()
  "Offer to read an outdated view again instead of acting on it.
Accepting refreshes the view and signals a `user-error' to abort the caller."
  (when (and (claude-code--view-outdated-p)
             (yes-or-no-p
              (format "Sessions on %s changed since this view was read.  \
Refresh instead? "
                      (file-remote-p claude-code--project 'host))))
    (claude-code--refresh-view)
    (user-error "Refreshed the view; nothing was done")))

(defun claude-code--instance-at-point ()
  "Return the alive session on the current line, or signal a `user-error'."
  (let* ((session (or (claude-code--session-at-point)
                      (user-error "No session on this line")))
         (id (claude-code-session-id session)))
    (cond
     ;; A remote view's row can still read alive after its instance left.
     ((claude-code--session-process (claude-code-session-buffer session)) session)
     ((claude-code-session-external-p session)
      (user-error "Session %s is running outside Emacs" id))
     ((claude-code-session-alive-p session)
      (user-error "Session %s has left Emacs; press g to refresh" id))
     (t (user-error "Session %s is not alive; press RET to resume it" id)))))

;;;;; Commands

(defun claude-code--show (buffer)
  "Display and select BUFFER in its own window or a sessions view's, else another.
Only windows on the selected frame count, the selected one first, and a
dedicated view window is never taken."
  (let* ((views (claude-code--views))
         ;; Shown twice, the terminal would take the smaller window's size.
         (window (or (get-buffer-window buffer)
                     (seq-find (lambda (w)
                                 (and (memq (window-buffer w) views)
                                      (not (window-dedicated-p w))))
                               (window-list nil 'nomini)))))
    (pop-to-buffer buffer (if window
                              `(display-buffer-use-some-window
                                (some-window . ,(lambda (&rest _) window)))
                            t))))

(defun claude-code--ensure-sessions-mode ()
  "Signal a `user-error' unless the current buffer is a sessions view."
  (unless (derived-mode-p 'claude-code-sessions-mode)
    (user-error "Not in a Claude sessions buffer")))

(defun claude-code--line-key ()
  "Return what names the current line across a reprint, or nil."
  (if-let* ((id (tabulated-list-get-id)))
      (cons 'row id)
    (when-let* ((group (get-text-property (line-beginning-position)
                                          'claude-code-group)))
      (cons 'group group))))

(defun claude-code--line-session ()
  "Return the id of the session on the current line, or nil on a group header."
  (get-text-property (line-beginning-position) 'claude-code-session))

(defun claude-code--row-place (pos)
  "Return POS as (KEY SESSION LINE . COLUMN)."
  (save-excursion
    (goto-char pos)
    (cons (claude-code--line-key)
          (cons (claude-code--line-session)
                (cons (line-number-at-pos) (current-column))))))

(defun claude-code--row-pos (place)
  "Return the position `claude-code--row-place' PLACE names in the reprint."
  (pcase-let ((`(,key ,session ,line . ,column) place))
    (save-excursion
      (unless (or (and key (claude-code--goto-line-where
                            (lambda () (equal (claude-code--line-key) key))))
                  ;; The key changes as a session gains or loses an instance.
                  (and session (claude-code--goto-line-where
                                (lambda ()
                                  (equal (claude-code--line-session) session)))))
        (goto-char (point-min))
        (forward-line (1- line)))
      (move-to-column column)
      (point))))

(defun claude-code--redraw (&optional group)
  "Reprint the view's last read, keeping every window showing it on its row.
GROUP, when given, puts point on that group's header instead."
  (let ((windows (mapcar (lambda (window)
                           (list window
                                 (claude-code--row-place (window-point window))
                                 (claude-code--row-place (window-start window))))
                         (get-buffer-window-list nil nil t)))
        (here (claude-code--row-place (point))))
    (tabulated-list-print)
    (goto-char (claude-code--row-pos here))
    (pcase-dolist (`(,window ,place ,start) windows)
      (set-window-point window (claude-code--row-pos place))
      (set-window-start window (claude-code--row-pos start) t)))
  (claude-code--goto-group group))

(defun claude-code--refresh-view (&rest _)
  "Read the current view's project again and redraw the view."
  (claude-code--read-view)
  (claude-code--redraw))

(defun claude-code-sessions-refresh ()
  "Read the sessions again and redraw the view."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (unless (file-remote-p claude-code--project)
    (claude-code--watch-sessions))
  (claude-code--refresh-view))

(defun claude-code--views ()
  "Return every sessions-view buffer that names a project, displayed or not."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'claude-code-sessions-mode)
                       claude-code--project)))
              (buffer-list)))

(defun claude-code--update-view ()
  "Refresh the current view while a window shows it, else once one does.
A remote view out of sight is left as it is."
  (cond ((get-buffer-window-list nil nil t) (claude-code--refresh-view))
        ;; Catching up runs in redisplay; a remote read there would hang Emacs.
        ((not (file-remote-p claude-code--project))
         (setq claude-code--stale t))))

(defun claude-code--redraw-if-stale (window)
  "Refresh the current view if WINDOW now shows it and a change reached it."
  ;; Also called for a window that has just stopped showing this view.
  (when (and claude-code--stale (eq (window-buffer window) (current-buffer)))
    (claude-code--refresh-view)))

(defun claude-code--refresh-views (&optional host)
  "Update every view of a project on HOST, this machine when nil."
  (dolist (buffer (claude-code--views))
    (with-current-buffer buffer
      (when (equal (file-remote-p claude-code--project) host)
        (claude-code--update-view)))))

(add-hook 'claude-code--sessions-changed-hook #'claude-code--refresh-views)

(defun claude-code--drop-marks (rows)
  "Unmark the rows whose keys are ROWS in every sessions view."
  (dolist (buffer (claude-code--views))
    (with-current-buffer buffer
      (setq claude-code--marks
            (cl-set-difference claude-code--marks rows :test #'equal)))))

(defun claude-code-sessions-toggle-group ()
  "Collapse or expand the group the current line belongs to."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (when-let* ((group (claude-code--group-at-point)))
    (if (member group claude-code--collapsed)
        (setq claude-code--collapsed (delete group claude-code--collapsed))
      (push group claude-code--collapsed))
    (claude-code--redraw group)))

(defun claude-code--visit-session (session display)
  "Show SESSION's instance through DISPLAY, attaching or resuming it as needed.
The instance the row was drawn for is shown while it runs, even once it has
moved onto another session."
  (let* ((drawn (claude-code-session-buffer session))
         (id (claude-code-session-id session))
         (buffer (cond
                  ((claude-code--session-process drawn) drawn)
                  ((claude-code-session-alive-p session)
                   (user-error "Session %s has left Emacs; press g to refresh"
                               id))
                  ((claude-code-session-holder session)
                   (claude-code-attach claude-code--project id
                                       (claude-code--session-display-name
                                        session)))
                  (t (claude-code--resume
                      claude-code--project id
                      (claude-code-session-worktree-binding session)
                      (claude-code--detachable-default
                       claude-code--project))))))
    (unless (and (eq buffer drawn)
                 (equal (plist-get (claude-code--instance-entry buffer) :session)
                        id))
      (claude-code--refresh-views (file-remote-p claude-code--project)))
    (funcall display buffer)))

(defun claude-code-sessions-visit ()
  "Visit the session at point, preferring the selected window, or toggle a group.
An attachable session is attached first, and a dead one resumed."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (if-let* ((session (claude-code--session-at-point)))
      (claude-code--visit-session session #'claude-code--show)
    (claude-code-sessions-toggle-group)))

(defun claude-code-sessions-visit-other-window ()
  "Visit the session at point in a window other than the selected one.
An attachable session is attached first, and a dead one resumed."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (claude-code--visit-session (or (claude-code--session-at-point)
                                  (user-error "No session on this line"))
                              #'switch-to-buffer-other-window))

(defcustom claude-code-vc-function #'vc-dir
  "Function called with a directory to show its version-control status.
`magit-status' fits too."
  :type 'function)

(defun claude-code-sessions-vc ()
  "Show the version-control status of the tree the session at point works in."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (funcall claude-code-vc-function
           (file-name-as-directory
            (claude-code--session-directory
             (or (claude-code--session-at-point)
                 (user-error "No session on this line"))
             claude-code--project))))

(defun claude-code-sessions-mark ()
  "Mark the session on the current line."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (when-let* ((s (claude-code--session-at-point)))
    (cl-pushnew (claude-code--row-key s) claude-code--marks :test #'equal)
    (tabulated-list-put-tag "*" t)))

(defun claude-code-sessions-unmark ()
  "Unmark the session on the current line."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (when-let* ((s (claude-code--session-at-point)))
    (setq claude-code--marks (delete (claude-code--row-key s) claude-code--marks))
    (tabulated-list-put-tag " " t)))

(defun claude-code--confirm (verb targets)
  "Ask whether to VERB the sessions TARGETS."
  (yes-or-no-p
   (format "%s %s? " verb
           (mapconcat (lambda (session)
                        (format "\"%s\"" (truncate-string-to-width
                                          (claude-code--session-display-name
                                           session)
                                          40 nil nil "…")))
                      targets ", "))))

(defun claude-code-sessions-kill ()
  "Kill the processes of the marked running sessions, or of the one at point."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (claude-code--offer-refresh)
  (let ((targets (claude-code--target-sessions 'alive 'external)))
    (if (null targets)
        (user-error "No running session selected")
      (when (claude-code--confirm "Kill" targets)
        (claude-code--act-on targets #'claude-code-kill "Killed")))))

(defun claude-code-sessions-detach ()
  "Detach the marked alive sessions, or the one at point."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (claude-code--offer-refresh)
  (let ((targets (claude-code--target-sessions 'alive)))
    (if (null targets)
        (user-error "No alive session selected")
      (claude-code--act-on targets #'claude-code-detach "Detached"))))

(defun claude-code-sessions-delete ()
  "Delete the marked dead sessions, or the one at point."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (claude-code--offer-refresh)
  (let ((targets (claude-code--target-sessions 'dead)))
    (if (null targets)
        (user-error "No dead session selected")
      (when (claude-code--confirm "Delete" targets)
        (claude-code--act-on targets #'claude-code-delete "Deleted")))))

(defun claude-code-sessions-rename ()
  "Rename the alive session at point."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (let ((session (claude-code--instance-at-point)))
    (claude-code-rename session (read-string "New name: "))))

(defun claude-code-sessions-interrupt ()
  "Interrupt the alive session at point."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (claude-code-interrupt (claude-code--instance-at-point)))

(defun claude-code-sessions-send ()
  "Send a line of text to the alive session at point."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (let ((session (claude-code--instance-at-point)))
    (claude-code-send-text session (read-string "Send: ") t)))

(defun claude-code-sessions-cycle-grouping ()
  "Toggle grouping between liveness and status."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (setq claude-code--group-by
        (if (eq claude-code--group-by 'status) 'state 'status))
  (claude-code--redraw))

(defun claude-code-sessions-transcript ()
  "Show the transcript of the session at point beside the view."
  (interactive nil claude-code-sessions-mode)
  (claude-code--ensure-sessions-mode)
  (display-buffer
   (claude-code--transcript-export
    (or (claude-code--session-at-point) (user-error "No session on this line"))
    claude-code--project)
   '((display-buffer-reuse-window
      display-buffer-reuse-mode-window
      display-buffer-in-direction)
     (mode . claude-code-transcript-mode)
     (direction . right))))

;;;;; Transcripts

(defvar-local claude-code--transcript-session nil
  "The session whose transcript this buffer shows.")

(defvar-local claude-code--transcript-root nil
  "The project root `claude-code--transcript-session' is listed under.")

(defvar-local claude-code--transcript-export nil
  "The export this buffer awaits, or nil.")

(defun claude-code--text-place (pos)
  "Return POS as (LINE . COLUMN), or nil when it is the end of the buffer."
  (unless (= pos (point-max))
    (save-excursion
      (goto-char pos)
      (cons (line-number-at-pos) (current-column)))))

(defun claude-code--text-pos (place)
  "Return the position `claude-code--text-place' PLACE names."
  (if place
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- (car place)))
        (move-to-column (cdr place))
        (point))
    (point-max)))

(defun claude-code--transcript-fill (text)
  "Replace the current buffer's text with TEXT, keeping every place in it.
A point at the end stays at the end, and any other keeps its line and column."
  (let ((windows (mapcar (lambda (window)
                           (list window
                                 (claude-code--text-place (window-point window))
                                 (claude-code--text-place (window-start window))))
                         (get-buffer-window-list nil nil t)))
        (here (claude-code--text-place (point)))
        (inhibit-read-only t))
    (erase-buffer)
    (insert text)
    (goto-char (claude-code--text-pos here))
    (pcase-dolist (`(,window ,place ,start) windows)
      (set-window-point window (claude-code--text-pos place))
      (set-window-start window
                        (if place
                            (claude-code--text-pos start)
                          (save-excursion
                            (goto-char (point-max))
                            (forward-line (- 1 (window-body-height window)))
                            (point)))
                        t))))

(defun claude-code--transcript-buffer (id)
  "Return the buffer showing session ID's transcript, or nil."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'claude-code-transcript-mode)
                     claude-code--transcript-session
                     (equal (claude-code-session-id
                             claude-code--transcript-session)
                            id))))
            (buffer-list)))

(defun claude-code--transcript-export (session root)
  "Export SESSION's transcript, listed under ROOT, into its buffer; return it."
  (let* ((id (claude-code-session-id session))
         (answer (lambda (fn)
                   (lambda (arg)
                     (with-current-buffer (claude-code--transcript-buffer id)
                       (setq claude-code--transcript-export nil
                             mode-line-process nil)
                       (funcall fn arg)))))
         ;; Before the buffer, so a refused export leaves no empty one behind.
         (proc (claude-code-export-transcript
                session root
                (funcall answer #'claude-code--transcript-fill)
                (funcall answer (lambda (msg)
                                  (message "%s: %s" (buffer-name) msg)))))
         (buffer (or (claude-code--transcript-buffer id)
                     (with-current-buffer
                         (generate-new-buffer
                          (format "*claude-transcript: %s*"
                                  (truncate-string-to-width
                                   (claude-code--session-display-name session)
                                   40 nil nil "…")))
                       (claude-code-transcript-mode)
                       (current-buffer)))))
    (with-current-buffer buffer
      (when claude-code--transcript-export
        (claude-code--export-cancel claude-code--transcript-export))
      (setq claude-code--transcript-session session
            claude-code--transcript-root root
            claude-code--transcript-export proc
            mode-line-process ":exporting"))
    buffer))

(defun claude-code--transcript-revert (&rest _)
  "Export this buffer's session again; its `revert-buffer-function'."
  (claude-code--transcript-export claude-code--transcript-session
                                  claude-code--transcript-root))

(defun claude-code--transcript-abandon ()
  "Abandon the export this buffer awaits, as it is killed or changes mode."
  (when claude-code--transcript-export
    (claude-code--export-cancel claude-code--transcript-export)))

(define-derived-mode claude-code-transcript-mode special-mode "Claude Transcript"
  "Major mode showing a session's transcript as Claude exports it.
\\<claude-code-transcript-mode-map>\\[revert-buffer] exports it again.

\\{claude-code-transcript-mode-map}"
  :interactive nil
  (buffer-disable-undo)
  ;; Claude already wraps the export.
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'claude-code--transcript-revert)
  (add-hook 'change-major-mode-hook #'claude-code--transcript-abandon nil t)
  (add-hook 'kill-buffer-hook #'claude-code--transcript-abandon nil t))

;;;;; Mode

(defvar-keymap claude-code-sessions-mode-map
  :doc "Keymap for `claude-code-sessions-mode'."
  "g"   #'claude-code-sessions-refresh
  "RET" #'claude-code-sessions-visit
  "o"   #'claude-code-sessions-visit-other-window
  "TAB" #'claude-code-sessions-toggle-group
  "c"   #'claude-code-spawn-menu
  "k"   #'claude-code-sessions-kill
  "x"   #'claude-code-sessions-detach
  "d"   #'claude-code-sessions-delete
  "r"   #'claude-code-sessions-rename
  "i"   #'claude-code-sessions-interrupt
  "s"   #'claude-code-sessions-send
  "t"   #'claude-code-sessions-transcript
  "v"   #'claude-code-sessions-vc
  "m"   #'claude-code-sessions-mark
  "u"   #'claude-code-sessions-unmark
  "G"   #'claude-code-sessions-cycle-grouping)

(define-derived-mode claude-code-sessions-mode tabulated-list-mode "Claude Sessions"
  "Major mode listing the Claude Code sessions of a project.

\\{claude-code-sessions-mode-map}"
  (setq-local claude-code--session-table (make-hash-table :test 'equal))
  (setq-local claude-code--usage-table (make-hash-table :test 'equal))
  ;; Fresh, since `claude-code-sessions-toggle-group' deletes from it in place.
  (setq-local claude-code--collapsed (list "dead"))
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-printer #'claude-code--print-entry)
  (setq-local tabulated-list-format
              (vector (list "Status" 10 #'claude-code--status-less-p)
                      (list "Active" 8 #'claude-code--time-less-p :right-align t)
                      '("Id" 9 t)
                      '("Worktree" 14 t)
                      (list "CPU%" 6 (claude-code--num-sorter #'car)
                            :right-align t)
                      (list "Mem" 8 (claude-code--num-sorter #'cdr)
                            :right-align t)
                      ;; Last, so it fills the remaining width untruncated.
                      '("Name" 26 t)))
  ;; A fresh list: `tabulated-list' reverses a sort by mutating its key.
  (setq-local tabulated-list-sort-key (list "Status"))
  ;; Not a function: `C-u -1 S' sorts this value directly.
  (setq-local tabulated-list-entries nil)
  (setq-local tabulated-list-groups #'claude-code--tabulated-groups)
  (setq-local revert-buffer-function #'claude-code--refresh-view)
  (add-hook 'eldoc-documentation-functions #'claude-code--eldoc-session nil t)
  (add-hook 'window-buffer-change-functions #'claude-code--redraw-if-stale nil t)
  (tabulated-list-init-header))

;;;;; Entry points

(defun claude-code--current-project ()
  "Return (ROOT . WORKTREE) for the current buffer's commands to act on.
A Claude worktree resolves to its parent project, WORKTREE naming it.  Prompts
for a project when the buffer has none."
  ;; Set by `project-switch-project', whose choice outranks the buffer's own.
  (or (unless project-current-directory-override
        (if claude-code--project
            (cons claude-code--project nil)
          (claude-code--instance-project)))
      (let ((root (claude-code--normalize-root
                   (project-root (project-current t)))))
        (or (claude-code--worktree-parent root) (cons root nil)))))

(defun claude-code--instance-project ()
  "Return (ROOT . WORKTREE) for the instance hosted in this buffer, or nil."
  (when-let* ((origin (plist-get (gethash (current-buffer) claude-code--managed)
                                 :origin)))
    (let ((root (claude-code--origin-project origin))
          (here (claude-code--worktree-parent
                 (claude-code--normalize-root default-directory))))
      (cons root (and (equal (car here) root) (cdr here))))))

(defun claude-code--project-root ()
  "Return the project root the current buffer's commands should act on."
  (car (claude-code--current-project)))

(defun claude-code--args-worktree (args)
  "Return the worktree ARGS ask for: a name, t for an unnamed one, or nil."
  (cond ((member "--worktree" args) t)
        ((seq-some (lambda (arg)
                     (and (stringp arg)
                          (string-prefix-p "--worktree=" arg)
                          (let ((name (substring arg (length "--worktree="))))
                            ;; The CLI rejects an empty name.
                            (if (string-empty-p name) t name))))
                   args))))

(defun claude-code--spawn-session (root &optional args)
  "Create a session for ROOT with the options in ARGS and display it."
  (interactive (if transient-current-command
                   (list (or (transient-scope) (claude-code--project-root))
                         (transient-args transient-current-command))
                 (list (claude-code--project-root))))
  (let ((instance (apply #'claude-code-spawn
                         root
                         :name (transient-arg-value "--name=" args)
                         :worktree (claude-code--args-worktree args)
                         :model (transient-arg-value "--model=" args)
                         :effort (transient-arg-value "--effort=" args)
                         ;; Outside the menu, `claude-code-spawn' picks it.
                         (and transient-current-command
                              (list :detachable
                                    (transient-arg-value "--detached" args))))))
    (claude-code--refresh-views (file-remote-p root))
    (claude-code--show (cdr instance))))

;; Keep the suffix out of `M-x'.
(put 'claude-code--spawn-session 'completion-predicate #'transient--suffix-only)

(defconst claude-code--worktree-auto "(auto)"
  "The completion candidate standing for a worktree Claude names itself.")

(defclass claude-code--worktree-infix (transient-option) ()
  "A worktree request: none, one Claude names, or one the user names.
The empty value requests the one Claude names.")

(cl-defmethod transient-infix-value ((obj claude-code--worktree-infix))
  "Return the `--worktree' argument OBJ asks for, or nil for none."
  (and-let* ((value (oref obj value)))
    (if (equal value "") "--worktree" (concat "--worktree=" value))))

(cl-defmethod transient-init-value ((obj claude-code--worktree-infix))
  "Read OBJ's value back out of the prefix's, whichever argument spells it."
  (oset obj value
        (pcase (claude-code--args-worktree (oref transient--prefix value))
          ('t "")
          (name name))))

(cl-defmethod transient-format-value ((obj claude-code--worktree-infix))
  "Label OBJ's unnamed request, which has no value of its own to show."
  (if (equal (oref obj value) "")
      (concat (propertize "--worktree" 'face 'transient-argument)
              (propertize (concat " " claude-code--worktree-auto)
                          'face 'transient-value))
    (cl-call-next-method)))

(defun claude-code--read-worktree (prompt initial-input history)
  "Read a worktree name with PROMPT, INITIAL-INPUT and HISTORY.
`claude-code--worktree-auto' reads as the empty string."
  (let* ((root (transient-scope))
         (choice (completing-read
                  prompt
                  (cons claude-code--worktree-auto
                        (remove claude-code--worktree-auto
                                (and root (claude-code--worktree-names root))))
                  nil nil initial-input history)))
    (if (equal choice claude-code--worktree-auto) "" choice)))

(defun claude-code--seed-menu (obj worktree detached)
  "Add requests for WORKTREE and DETACHED to the value menu OBJ opens with."
  ;; Unbound, `transient-init-value' falls back to the pinned or default value.
  (slot-makeunbound obj 'init-value)
  (transient-init-value obj)
  (oset obj value (append (and worktree (list (concat "--worktree=" worktree)))
                          (and detached (list "--detached"))
                          (oref obj value))))

;;;###autoload
(transient-define-prefix claude-code-spawn-menu ()
  "Create a new session for a project, with options."
  ["Arguments"
   ;; A name belongs to one session, and the worktree is seeded per invocation.
   ("-n" "Name" "--name=" :unsavable t)
   ("-w" "Worktree" "--worktree="
    :class claude-code--worktree-infix
    :reader claude-code--read-worktree
    :allow-empty t
    :unsavable t)
   ("-m" "Model" "--model=" :choices ("opus" "sonnet" "haiku" "fable"))
   ("-e" "Effort" "--effort=" :choices ("low" "medium" "high" "xhigh" "max"))
   ;; Seeded from `claude-code-detachable' per invocation.
   ("-d" "Detached" "--detached" :unsavable t)]
  ["Create"
   ("c" "New session" claude-code--spawn-session)]
  (interactive)
  (pcase-let* ((`(,root . ,worktree) (claude-code--current-project))
               (detached (claude-code--detachable-default root)))
    ;; `:init-value' outranks a value pinned with `transient-set'.
    (apply #'transient-setup 'claude-code-spawn-menu nil nil
           :scope root
           (and (or worktree detached)
                (list :init-value
                      (lambda (obj)
                        (claude-code--seed-menu obj worktree detached)))))))

;;;###autoload
(defun claude-code-sessions ()
  "Open the Claude sessions view for the current project."
  (interactive)
  (let* ((root (claude-code--project-root))
         ;; Found by project, not by name: two projects can share a basename.
         (buffer (or (seq-find (lambda (view)
                                 (equal (buffer-local-value 'claude-code--project
                                                            view)
                                        root))
                               (claude-code--views))
                     (generate-new-buffer
                      (format "*claude-sessions: %s*"
                              (file-name-nondirectory root))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-code-sessions-mode)
        (claude-code-sessions-mode))
      (setq claude-code--project root)
      (setq default-directory (file-name-as-directory root))
      ;; Where `ibuffer' and completion annotators find a fileless buffer's
      ;; directory; unabbreviated, or ibuffer's filename filters miss it.
      (setq list-buffers-directory default-directory)
      (claude-code-sessions-refresh))
    (pop-to-buffer buffer)))

(provide 'claude-code)
;;; claude-code.el ends here
