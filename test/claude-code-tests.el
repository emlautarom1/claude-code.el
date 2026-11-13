;;; claude-code-tests.el --- Tests for claude-code -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT suite for claude-code.el.  Run with `make test'.

;;; Code:

(require 'ert)
;; Ahead of `ert-x', which defines its `mock' method only over a loaded TRAMP.
(require 'tramp)
(require 'ert-x)
(require 'seq)
(require 'cl-lib)
(require 'claude-code)

;; Stand-ins for Ghostel's own definitions, since tests run without it loaded.
(defvar ghostel-kill-buffer-on-exit)
(defvar ghostel-pre-spawn-hook nil)

;; `claude-code-instance-mode' derives from `ghostel-mode' and installs
;; `ghostel-semi-char-mode-map', so entering it needs both to exist.  An
;; integration test may `require' Ghostel later in the same Emacs, and Ghostel
;; defines each of these with a form that leaves an already-bound name alone --
;; so a stand-in is only safe where the real definition can still take effect
;; over it.  `ghostel-mode' is safe because `defun' overwrites.
;; `ghostel-semi-char-mode-map' is safe because Ghostel fills its map in place
;; (`ghostel--rebuild-semi-char-keymap' ends in a `setcdr'), which reaches this
;; object and gives it the real bindings and the `ghostel-mode-map' parent that
;; carries the `C-c' prefix.  Nothing else may be stubbed here on those terms:
;; a stub `ghostel-mode-map' in particular would stay empty and strand that
;; prefix, which is why the stand-in below is a plain function -- a
;; `define-derived-mode' would define one.
(unless (featurep 'ghostel)
  (defvar ghostel-semi-char-mode-map (make-sparse-keymap))
  (defun ghostel-mode ()
    "Stand-in for Ghostel's major mode, reproducing what it owes its caller."
    (kill-all-local-variables)
    (setq major-mode 'ghostel-mode)
    (setq mode-name "Ghostel")
    (use-local-map ghostel-semi-char-mode-map)))

(defvar claude-code-tests--fixtures
  (expand-file-name
   "fixtures" (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding real, redacted fixture data.")

(defconst claude-code-tests--uuid-re
  (concat "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}"
          "-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'")
  "Regexp matching a version-4 UUID as `claude-code--new-uuid' formats one.")

(defmacro claude-code-tests--with-fixtures (&rest body)
  "Run BODY with `claude-code-config-dir' pointed at the fixtures.
Clears the transcript cache first so tests do not leak into each other."
  (declare (indent 0))
  `(let ((claude-code-config-dir claude-code-tests--fixtures))
     (clrhash claude-code--transcript-cache)
     ,@body))

(defmacro claude-code-tests--with-registry (&rest body)
  "Run BODY with `claude-code--managed' rebound to an empty registry.
Instances a test registers are therefore invisible to every other test, and
registering one neither watches a sessions/ directory nor updates a view of
the Emacs running the suite."
  (declare (indent 0))
  `(let ((claude-code--managed (make-hash-table))
         (claude-code--sessions-changed-hook nil))
     (cl-letf (((symbol-function 'claude-code--watch-sessions) #'ignore))
       ,@body)))

(defmacro claude-code-tests--with-managed-buffer (spec &rest body)
  "Run BODY with a fresh buffer bound and an empty managed registry.
SPEC is VAR or (VAR PID): the buffer is bound to VAR and carries the reported
PID, 4242 by default, with no live process and no program status record, as
an instance's terminal would.  It is killed afterwards even when BODY already
killed it."
  (declare (indent 1))
  (pcase-let ((`(,var ,pid) (if (consp spec) spec (list spec 4242))))
    `(claude-code-tests--with-registry
       (let ((,var (generate-new-buffer " *cc-test*")))
         (with-current-buffer ,var
           (setq-local claude-code--pid ,pid
                       ghostel--process nil
                       ghostel-program-status nil))
         (unwind-protect (progn ,@body)
           (when (buffer-live-p ,var) (kill-buffer ,var)))))))

(defun claude-code-tests--instance (id)
  "Return the buffer of the managed instance running session ID, or nil."
  (seq-find (lambda (buffer)
              (equal (plist-get (gethash buffer claude-code--managed) :session)
                     id))
            (hash-table-keys claude-code--managed)))

(defun claude-code-tests--entry (id)
  "Return the registry entry of the instance running session ID, or nil."
  (gethash (claude-code-tests--instance id) claude-code--managed))

(defmacro claude-code-tests--with-config (&rest body)
  "Run BODY with `claude-code-config-dir' a scratch directory holding sessions/.
The directory is removed afterwards."
  (declare (indent 0))
  `(let ((claude-code-config-dir (make-temp-file "cc-config" t)))
     (unwind-protect
         (progn (make-directory (claude-code--sessions-dir))
                ,@body)
       (delete-directory claude-code-config-dir t))))

(defun claude-code-tests--write-session-file (pid content)
  "Write CONTENT as sessions/PID.json under `claude-code-config-dir'.
CONTENT is a string, or a session id to name in an otherwise minimal file."
  (with-temp-file (expand-file-name (format "%d.json" pid)
                                    (claude-code--sessions-dir))
    (insert (if (string-prefix-p "{" content)
                content
              (format "{\"pid\":%d,\"sessionId\":\"%s\",\"status\":\"idle\"}"
                      pid content)))))

(defmacro claude-code-tests--with-live-pids (pids &rest body)
  "Run BODY with exactly the pids in PIDS reading as live processes.
Pinning the process table keeps a fixture pid that happens to be live on the
host from classifying its session as external, or from lending it a real
subtree.  The table also holds Emacs's own pid, as a real one would: an empty
table is one that could not be read.  Every pinned pid parents to 0 and has no
children, so no pid is its own ancestor and a subtree walk always terminates."
  (declare (indent 1))
  (let ((live (gensym "live")))
    `(let ((,live (cons (emacs-pid) ,pids)))
       (cl-letf (((symbol-function 'list-system-processes) (lambda () ,live))
                 ((symbol-function 'claude-code--child-pids) #'ignore)
                 ((symbol-function 'process-attributes)
                  (lambda (p) (and (memql p ,live) '((ppid . 0))))))
         ,@body))))

(defmacro claude-code-tests--in-view (&rest body)
  "Run BODY in a temp buffer with the sessions view enabled.
A refresh there watches no sessions/ directory."
  (declare (indent 0))
  `(with-temp-buffer
     (cl-letf (((symbol-function 'claude-code--watch-sessions) #'ignore))
       (claude-code-sessions-mode)
       ,@body)))

(defun claude-code-tests--await (pred timeout)
  "Pump events until PRED is non-nil or TIMEOUT seconds elapse; return PRED."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.2)
      (sleep-for 0.1))
    (funcall pred)))

(defun claude-code-tests--proc-strings (pid file)
  "Return the NUL-separated strings of `/proc/PID/FILE', or nil if unreadable."
  (let ((path (format "/proc/%d/%s" pid file)))
    (when (file-readable-p path)
      (with-temp-buffer
        (insert-file-contents-literally path)
        (split-string (buffer-string) "\0" t)))))

(defmacro claude-code-tests--without-requiring (features &rest body)
  "Run BODY with a `require' of any feature in FEATURES a no-op.
Every other feature still loads normally.  Shadowing `features' itself would
not do: it is not a special variable, so under lexical binding the binding is
invisible to `require'."
  (declare (indent 1))
  (let ((orig (gensym "orig")))
    `(let ((,orig (symbol-function 'require)))
       (cl-letf (((symbol-function 'require)
                  (lambda (feat &rest args)
                    (unless (memq feat ,features) (apply ,orig feat args)))))
         ,@body))))

(defmacro claude-code-tests--with-executable (dir name &rest body)
  "Run BODY with DIR a fresh directory holding an executable file NAME."
  (declare (indent 2))
  (let ((file (gensym "file")))
    `(ert-with-temp-directory ,dir
       (let ((,file (expand-file-name ,name ,dir)))
         (write-region "#!/bin/sh\n" nil ,file)
         (set-file-modes ,file #o700))
       ,@body)))

(defmacro claude-code-tests--on-mock-host (dirs &rest body)
  "Run BODY in a remote `default-directory' whose host also searches DIRS.
The host is TRAMP's `mock' method from `ert-x', a local shell behind the remote
file handlers, so it shares Emacs's file system.  TRAMP reads
`tramp-remote-path' once per connection, so the connection is dropped on the
way in and on the way out.  Skips when the method is unavailable or cannot
connect."
  (declare (indent 1))
  `(progn
     (skip-unless (and ert-remote-temporary-file-directory
                       (equal (file-remote-p ert-remote-temporary-file-directory
                                             'method)
                              "mock")))
     (let ((default-directory ert-remote-temporary-file-directory)
           (tramp-remote-path (append ,dirs tramp-remote-path)))
       (tramp-cleanup-connection (tramp-dissect-file-name default-directory) t t)
       (unwind-protect
           (progn
             (skip-unless (ignore-errors (file-directory-p default-directory)))
             ,@body)
         (tramp-cleanup-connection
          (tramp-dissect-file-name default-directory) t t)))))

(defmacro claude-code-tests--recording-ghostel (calls &rest body)
  "Run BODY with Ghostel paste/key stubbed to push onto CALLS.
Each call pushes (paste STR) or (key NAME).  Every live buffer has a running
terminal, and Ghostel's native module is absent under test, so requiring it is
a no-op."
  (declare (indent 1))
  `(claude-code-tests--without-requiring '(ghostel)
     (cl-letf (((symbol-function 'ghostel-paste-string)
                (lambda (s) (push (list 'paste s) ,calls)))
               ((symbol-function 'ghostel-send-key)
                (lambda (k &rest _) (push (list 'key k) ,calls)))
               ((symbol-function 'claude-code--session-process) #'buffer-live-p))
       ,@body)))

(defmacro claude-code-tests--recording-launch (execs &rest body)
  "Run BODY with the launch path stubbed, pushing (BUFFER ARGS ENV PROGRAM).
Each launch is pushed onto EXECS.  PROGRAM and ARGS are what the PID-reporting
wrapper `exec's.  ENV is what the instance would have inherited, modelling
only the two things that decide it: the pre-spawn hook runs in the instance's
buffer, over a `process-environment' sharing its tail with Emacs's own.  Each
launch's buffer gets a PID of its own, as the wrapper reports it, no live
process and no program status record.
Neither Ghostel's native module nor the MCP server is wanted under test, so
requiring either is a no-op, MCP adds no arguments and no environment, and
`claude-code-cli' is launched as named.  The focus hook a launch watches is
bound around BODY, and every buffer a launch hosted is killed afterwards,
however BODY exits."
  (declare (indent 1))
  (let ((hosted (gensym "hosted")))
    `(let ((,hosted '()))
       (claude-code-tests--without-requiring '(ghostel claude-code-mcp)
         (cl-letf ((after-focus-change-function after-focus-change-function)
                   ((symbol-function 'claude-code--mcp-wiring) #'ignore)
                   ((symbol-function 'claude-code--resolve-executable)
                    #'identity)
                   ((symbol-function 'ghostel-exec)
                    (lambda (buffer _shell args)
                      (push buffer ,hosted)
                      (with-current-buffer buffer
                        (setq-local claude-code--pid (+ 5000 (length ,hosted))
                                    ghostel--process nil
                                    ghostel-program-status nil))
                      (push (list buffer (nthcdr 3 args)
                                  (with-current-buffer buffer
                                    (let ((process-environment
                                           (append '("INSIDE_EMACS=ghostel")
                                                   process-environment)))
                                      (run-hooks 'ghostel-pre-spawn-hook)
                                      process-environment))
                                  (nth 2 args))
                            ,execs))))
           (unwind-protect (progn ,@body)
             (dolist (buffer ,hosted)
               (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(defmacro claude-code-tests--with-child-env (child-env &rest body)
  "Run BODY over a stubbed launch path with CHILD-ENV bound to a reader.
CHILD-ENV names a function of one variable name returning what the instance of
the latest launch inherited."
  (declare (indent 1))
  (let ((execs (gensym "execs")))
    `(claude-code-tests--with-registry
       (let ((,execs '()))
         (claude-code-tests--recording-launch ,execs
           (cl-flet ((,child-env (name)
                       (let ((process-environment (nth 2 (car ,execs))))
                         (getenv name))))
             ,@body))))))

;;;; Storage adapter

(ert-deftest claude-code-test-encode-cwd ()
  "Encoding names a directory exactly as Claude does.
Every expected name under /tmp/cc-probe-enc is one CLI v2.1.304 created
under projects/ for that directory."
  (should (equal (claude-code--encode-cwd
                  "/home/emlautarom1/Development/Elisp/claude-code.el")
                 "-home-emlautarom1-Development-Elisp-claude-code-el"))
  ;; A leading dot (dotfile dir) yields a doubled hyphen.
  (should (equal (claude-code--encode-cwd "/home/emlautarom1/.dotfiles")
                 "-home-emlautarom1--dotfiles"))
  ;; A trailing slash (as `project-root' returns) must not add a trailing dash.
  (should (equal (claude-code--encode-cwd "/home/x/proj/")
                 "-home-x-proj"))
  ;; Everything but an ASCII letter or digit is a hyphen, one per UTF-16 code
  ;; unit: the emoji outside the BMP takes two.
  (should (equal (claude-code--encode-cwd "/tmp/cc-probe-enc/my_project dir/a+b")
                 "-tmp-cc-probe-enc-my-project-dir-a-b"))
  (should (equal (claude-code--encode-cwd "/tmp/cc-probe-enc/café/😀")
                 "-tmp-cc-probe-enc-caf----"))
  ;; A name of 200 is kept whole; one more character cuts it and appends the
  ;; hash of the whole directory.
  (let ((dir (concat "/tmp/cc-probe-enc/" (make-string 182 ?x))))
    (should (equal (claude-code--encode-cwd dir)
                   (concat "-tmp-cc-probe-enc-" (make-string 182 ?x))))
    (should (equal (claude-code--encode-cwd (concat dir "y"))
                   (concat "-tmp-cc-probe-enc-" (make-string 182 ?x)
                           "-kcmpb5"))))
  ;; A hash that folds negative is taken absolute, and the emoji's surrogate
  ;; pair is what it hashes.
  (should (equal (claude-code--encode-cwd
                  (concat "/tmp/cc-probe-enc/😀/neg4/" (make-string 190 ?d)))
                 (concat "-tmp-cc-probe-enc----neg4-" (make-string 174 ?d)
                         "-wso8zt"))))

(ert-deftest claude-code-test-worktree-parent ()
  "A checkout `--worktree=NAME' built resolves to the project it was built from.
The reconstruction is the test, so a path that merely looks the part resolves
to nothing."
  (should (equal (claude-code--worktree-parent
                  "/home/me/proj/.claude/worktrees/feat")
                 '("/home/me/proj" . "feat")))
  ;; The name comes back as the user wrote it: these are real path components,
  ;; not the lossy transcript-directory encoding.  The CLI flattens a `/' to
  ;; `+' rather than nesting, so three directories is the whole depth.
  (should (equal (claude-code--worktree-parent
                  "/home/me/proj/.claude/worktrees/my.feat")
                 '("/home/me/proj" . "my.feat")))
  (should (equal (claude-code--worktree-parent
                  "/home/me/proj/.claude/worktrees/team+feat")
                 '("/home/me/proj" . "team/feat")))
  (should-not (claude-code--worktree-parent "/home/me/proj/.claude/worktrees"))
  (should-not (claude-code--worktree-parent
               "/home/me/proj/.claude/worktrees/feat/nested"))
  (should-not (claude-code--worktree-parent "/home/me/proj/.claude"))
  (should-not (claude-code--worktree-parent "/home/me/proj"))
  ;; A worktree kept somewhere else is a project in its own right: it files its
  ;; transcripts under itself, so no parent's view would list them.
  (should-not (claude-code--worktree-parent "/home/me/checkouts/feat"))
  ;; Walking off the top of the filesystem answers nothing rather than erroring.
  (should-not (claude-code--worktree-parent "/home"))
  (should-not (claude-code--worktree-parent "/")))

(ert-deftest claude-code-test-sessions-dir-parsing ()
  "Each sessions/<pid>.json naming a session describes that pid's process."
  (claude-code-tests--with-fixtures
    (let ((table (claude-code--live-table)))
      (pcase-dolist (`(,pid ,key ,value)
                     '((1001 :session "11111111-1111-4111-8111-111111111111")
                       (1001 :cwd "/home/test/proj")
                       (1001 :status "busy")
                       (1003 :cwd "/home/test/proj/.claude/worktrees/feat")
                       (1003 :status "waiting")
                       (1003 :waiting-for "permission prompt")
                       (1006 :status "shell")))
        (should (equal (plist-get (gethash pid table) key) value)))
      ;; A file with no status field is still read.
      (should (gethash 1004 table))
      (should-not (plist-get (gethash 1004 table) :status))
      (should (equal (claude-code--pid-info 1003) (gethash 1003 table)))
      (should-not (claude-code--pid-info 999999))
      (should-not (claude-code--pid-info nil))))
  (claude-code-tests--with-config
    (claude-code-tests--write-session-file 10 "kept")
    ;; Caught mid-rewrite, naming no session, and a companion key file.
    (claude-code-tests--write-session-file 11 "{\"pid\":11,\"sessionId\":")
    (claude-code-tests--write-session-file 12 "{\"pid\":12,\"sessionId\":null}")
    (with-temp-file (expand-file-name "13.0a1b.key" (claude-code--sessions-dir))
      (insert "{\"sessionId\":\"key\"}"))
    (let ((table (claude-code--live-table)))
      (should (equal (hash-table-keys table) '(10)))
      (should (equal (plist-get (gethash 10 table) :session) "kept")))
    (should-not (claude-code--pid-info 11))
    (should-not (claude-code--pid-info 12))))

(defmacro claude-code-tests--with-transcript (var lines mtime &rest body)
  "Bind VAR to a temp .jsonl holding LINES with file mtime MTIME, run BODY.
LINES is a list of strings (one JSON object per line).  The transcript cache is
cleared first and the temp file deleted afterwards."
  (declare (indent 3))
  `(let ((,var (make-temp-file "cc-transcript" nil ".jsonl")))
     (unwind-protect
         (progn
           (clrhash claude-code--transcript-cache)
           (with-temp-file ,var
             (dolist (line ,lines) (insert line "\n")))
           (set-file-times ,var ,mtime)
           ,@body)
       (delete-file ,var))))

(ert-deftest claude-code-test-transcript-fields ()
  "A transcript field is the newest top-level value its line type sets."
  (let ((mtime 1800000000)
        (stamp (date-to-time "2026-06-10T13:23:27.697Z"))
        (asked "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"q\"},\"timestamp\":\"2026-06-10T13:20:00.000Z\"}")
        (answered "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[]},\"timestamp\":\"2026-06-10T13:23:27.697Z\"}")
        (snapshot "{\"type\":\"file-history-snapshot\",\"messageId\":\"m1\",\"snapshot\":{\"trackedFileBackups\":{},\"timestamp\":\"2026-06-10T13:23:40.000Z\"},\"isSnapshotUpdate\":false}")
        (ai-title "{\"type\":\"ai-title\",\"aiTitle\":\"generated\"}")
        (custom-title "{\"type\":\"custom-title\",\"customTitle\":\"renamed\"}")
        (recap "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"real\"}"))
    (pcase-dolist
        (`(,label ,field ,expected . ,lines)
         `(("newest timestamp, past later metadata" :last-active ,stamp
            ,asked ,answered "{\"type\":\"last-prompt\",\"lastPrompt\":\"q\"}")
           ("a nested timestamp is not the line's" :last-active ,stamp
            ,answered ,snapshot)
           ("no timestamped line" :last-active ,mtime ,ai-title)
           ("only a snapshot's nested timestamp" :last-active ,mtime ,snapshot)
           ("custom title written first" :title "renamed" ,custom-title ,ai-title)
           ("custom title written last" :title "renamed" ,ai-title ,custom-title)
           ("a message quoting the custom-title literal" :title "generated"
            ,ai-title
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"custom-title\"},\"timestamp\":\"2026-06-10T13:23:27.697Z\"}")
           ("newest prompt, past a rewind" :last-prompt "second"
            "{\"type\":\"last-prompt\",\"lastPrompt\":\"first\"}"
            "{\"type\":\"last-prompt\",\"lastPrompt\":\"second\"}"
            "{\"type\":\"last-prompt\",\"leafUuid\":\"00000000-0000-0000-0000-000000000000\",\"explicit\":true}")
           ("newest recap" :recap "real"
            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"older\"}"
            ,recap)
           ("other lines carrying content or the literal" :recap "real"
            ,recap
            "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"content\":\"queued prompt\",\"meta\":{\"away_summary\":true}}"
            "{\"type\":\"system\",\"subtype\":\"local_command\",\"content\":\"<local-command-stdout>away_summary</local-command-stdout>\"}"
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"away_summary\"},\"timestamp\":\"2026-06-10T13:23:27.697Z\"}")
           ("never recapped" :recap nil ,ai-title)
           ("null recap" :recap nil
            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":null}")
           ("empty recap" :recap nil
            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"\"}")))
      (ert-info (label :prefix "Row: ")
        (claude-code-tests--with-transcript file lines mtime
          (should (funcall (if (eq field :last-active) #'time-equal-p #'equal)
                           (plist-get (claude-code--transcript-fields file) field)
                           expected)))))
    ;; A transcript changed on disk since it was read is read again.
    (claude-code-tests--with-transcript file (list ai-title) mtime
      (should (equal (plist-get (claude-code--transcript-fields file) :title)
                     "generated"))
      (write-region (concat custom-title "\n") nil file t)
      (set-file-times file (+ mtime 100))
      (should (equal (plist-get (claude-code--transcript-fields file) :title)
                     "renamed")))))

(defun claude-code-tests--stamped-line (entrypoint content)
  "Return a transcript `user\=' line stamped ENTRYPOINT and carrying CONTENT.
ENTRYPOINT nil writes no stamp; a non-string one is inserted verbatim, which is
how a JSON `null\=' is spelled."
  (format "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"%s\"}%s,\"timestamp\":\"2026-06-10T13:20:00.000Z\"}"
          content
          (pcase entrypoint
            ('nil "")
            ((pred stringp) (format ",\"entrypoint\":\"%s\"" entrypoint))
            (raw (format ",\"entrypoint\":%s" raw)))))

(ert-deftest claude-code-test-transcript-interactive-p ()
  "A session is listed unless a program drove every invocation of it.
Claude stamps each line with the `entrypoint\=' of the process that wrote it, per
invocation rather than per session, so the rule names the three stamps a
program writes and treats every other one -- terminal, IDE, desktop, remote --
as a person."
  (let ((interactive-p
         (lambda (&rest lines)
           (claude-code-tests--with-transcript file lines 1800000000
             (plist-get (claude-code--transcript-fields file)
                        :interactive-p)))))
    ;; Each of the three program stamps rules a session out on its own.
    (dolist (stamp '("sdk-py" "sdk-cli" "sdk-ts"))
      (should-not (funcall interactive-p
                           (claude-code-tests--stamped-line stamp "go")
                           (claude-code-tests--stamped-line stamp "and again"))))
    ;; Every other surface has a person behind it, including the ones that are
    ;; not a terminal at all -- naming the programs is what keeps them listed.
    (dolist (stamp '("cli" "claude-vscode" "claude-desktop" "ssh-remote"
                     "remote_mobile" "claude-in-teams" "a-stamp-added-later"))
      (should (funcall interactive-p
                       (claude-code-tests--stamped-line stamp "hello"))))
    ;; The stamp is per invocation: one human-driven line anywhere redeems a
    ;; session a program started, wherever in the transcript it falls.
    (should (funcall interactive-p
                     (claude-code-tests--stamped-line "sdk-cli" "say ok")
                     (claude-code-tests--stamped-line "cli" "now tell me why")
                     (claude-code-tests--stamped-line "sdk-cli" "again")))
    ;; No stamp at all -- a transcript predating the field -- is listed, and so
    ;; is one whose stamp is JSON null: that arrives as a symbol, matches no
    ;; program name, and so reads as a person's rather than hiding a session.
    (should (funcall interactive-p (claude-code-tests--stamped-line nil "hi")))
    (should (funcall interactive-p (claude-code-tests--stamped-line 'null "hi")))
    ;; The scan finds its lines by a literal, and a nested `entrypoint' spells
    ;; that literal exactly; only the parsed top-level key may decide.  Without
    ;; the parse the first case reads as a person's and the second as a
    ;; program's, which is backwards in both.
    (should-not (funcall interactive-p
                         "{\"type\":\"x\",\"meta\":{\"entrypoint\":\"cli\"}}"
                         (claude-code-tests--stamped-line "sdk-py" "go")))
    (should (funcall interactive-p
                     "{\"type\":\"x\",\"meta\":{\"entrypoint\":\"sdk-py\"}}"))
    ;; Both stamps on one line, the nested one first: reaching the top-level
    ;; key means reading past a nested match rather than moving to the next
    ;; line, and getting this wrong hides a session a person drove.
    (should (funcall interactive-p
                     (claude-code-tests--stamped-line "sdk-py" "go")
                     (concat "{\"type\":\"user\",\"meta\":{\"entrypoint\":\"sdk-py\"},"
                             "\"entrypoint\":\"cli\"}")))))

(ert-deftest claude-code-test-project-sessions-from-disk ()
  "A project lists the sessions a person drove there or in its worktrees."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      (let ((root "/home/test/proj")
            (program "88888888-8888-4888-8888-888888888888")
            (ids (lambda (dir)
                   (mapcar #'claude-code-session-id
                           (claude-code-project-sessions dir)))))
        (claude-code-tests--with-live-pids '()
          (let* ((sessions (claude-code-project-sessions root))
                 (session (lambda (id)
                            (claude-code-tests--find-session sessions id))))
            ;; From its own transcript directory and its worktrees'.
            (dolist (id '("11111111-1111-4111-8111-111111111111"
                          "22222222-2222-4222-8222-222222222222"
                          "44444444-4444-4444-8444-444444444444"
                          "99999999-9999-4999-8999-999999999999"
                          "33333333-3333-4333-8333-333333333333"
                          "55555555-5555-4555-8555-555555555555"
                          "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
              (should (funcall session id)))
            (dolist (s sessions)
              (should (eq (claude-code--session-liveness s) 'dead)))
            ;; Neither a `Task' subagent's transcript nor a program's session.
            (should-not (funcall session "agent-a1b2c3d4e5f60718"))
            (should-not (funcall session program))
            (pcase-dolist (`(,id ,title)
                           '(("11111111-1111-4111-8111-111111111111"
                              "Understand the project layout")
                             ("22222222-2222-4222-8222-222222222222"
                              "My renamed session")
                             ("33333333-3333-4333-8333-333333333333"
                              "Renamed worktree")))
              (should (equal (claude-code-session-title (funcall session id))
                             title)))
            (should (time-equal-p
                     (claude-code-session-last-active
                      (funcall session "11111111-1111-4111-8111-111111111111"))
                     (date-to-time "2026-06-10T13:23:27.697Z")))
            ;; The worktree is the one the binding names, as the user wrote it.
            (pcase-dolist (`(,id ,worktree)
                           '(("33333333-3333-4333-8333-333333333333" "feat")
                             ("55555555-5555-4555-8555-555555555555" "my.feat")
                             ("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" nil)
                             ("44444444-4444-4444-8444-444444444444" nil)))
              (should (equal (claude-code-session-worktree (funcall session id))
                             worktree)))
            (let ((never (funcall session "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
                  (left (funcall session "44444444-4444-4444-8444-444444444444")))
              (should-not (claude-code-session-worktree-binding never))
              ;; Its worktree is gone, but the binding still names it.
              (should (equal (plist-get (claude-code-session-worktree-binding left)
                                        :name)
                             "left"))))
          (let ((ids (funcall ids (concat root "/.claude/worktrees/feat"))))
            (should (member "33333333-3333-4333-8333-333333333333" ids))
            (should-not (member "11111111-1111-4111-8111-111111111111" ids))
            (should-not (member "55555555-5555-4555-8555-555555555555" ids))))
        (claude-code-tests--with-live-pids '(1005)
          (should-not (member program (funcall ids root))))
        ;; Not from a sibling project whose directory name extends its own.
        (claude-code-tests--with-config
          (pcase-dolist (`(,dir ,id) '(("-home-test-proj" "mine")
                                       ("-home-test-proj2" "sibling")))
            (let ((dir (expand-file-name dir (claude-code--projects-dir))))
              (make-directory dir t)
              (write-region (claude-code-tests--stamped-line "cli" "hi") nil
                            (expand-file-name (concat id ".jsonl") dir))))
          (claude-code-tests--with-live-pids '()
            (let ((ids (funcall ids root)))
              (should (member "mine" ids))
              (should-not (member "sibling" ids)))))
        (should (claude-code--transcript-for root program))
        ;; An instance Emacs manages is listed whatever drove its session.
        (claude-code-tests--with-live-pids '()
          (claude-code-tests--with-managed-buffer buf
            (let ((proc (make-pipe-process :name "cc-test-instance" :noquery t)))
              (unwind-protect
                  (progn
                    (with-current-buffer buf (setq-local ghostel--process proc))
                    (claude-code--register program buf root nil)
                    (let ((s (claude-code-tests--find-session
                              (claude-code-project-sessions root) program)))
                      (should (claude-code-session-alive-p s))
                      (should (equal (claude-code-session-title s)
                                     "Security review fan-out"))))
                (delete-process proc)))))))))

(ert-deftest claude-code-test-resume-worktree-flag ()
  "Resuming passes `--worktree=NAME' only back to a worktree the session left.
NAME must also rebuild the recorded path, or the flag would build a fresh
checkout rather than return to the work."
  (ert-with-temp-directory config
    (let* ((claude-code-config-dir config)
           (root (file-truename (make-temp-file "cc-root" t)))
           (id "77777777-7777-4777-8777-777777777777")
           (transcript (expand-file-name
                        (concat "projects/" (claude-code--encode-cwd root)
                                "/" id ".jsonl")
                        config))
           (json (lambda (s) (if s (format "\"%s\"" s) "null")))
           (bound (lambda (name path)
                    (format "{\"type\":\"worktree-state\",\"worktreeSession\":{\"worktreeName\":%s,\"worktreePath\":%s},\"sessionId\":\"%s\"}"
                            (funcall json name)
                            (funcall json (and path (concat root path)))
                            id)))
           (left (format "{\"type\":\"worktree-state\",\"worktreeSession\":null,\"sessionId\":\"%s\"}"
                         id)))
      (unwind-protect
          (pcase-dolist
              (`(,label ,dir ,flag . ,lines)
               `(("left a worktree still on disk" ".claude/worktrees/feat" "feat"
                  ,(funcall bound "feat" "/.claude/worktrees/feat") ,left)
                 ("still in its worktree" ".claude/worktrees/feat" nil
                  ,(funcall bound "feat" "/.claude/worktrees/feat"))
                 ("left a worktree since removed" nil nil
                  ,(funcall bound "feat" "/.claude/worktrees/feat") ,left)
                 ("left one kept elsewhere" "elsewhere/feat" nil
                  ,(funcall bound "feat" "/elsewhere/feat") ,left)
                 ("a name with a slash" ".claude/worktrees/team+feat" "team/feat"
                  ,(funcall bound "team/feat" "/.claude/worktrees/team+feat") ,left)
                 ("another spelling of the path" ".claude/worktrees/feat" "feat"
                  ,(funcall bound "feat" "/./.claude/worktrees/feat") ,left)
                 ("a null path" ".claude/worktrees/feat" nil
                  ,(funcall bound "feat" nil) ,left)
                 ("a null name" ".claude/worktrees/feat" nil
                  ,(funcall bound nil "/.claude/worktrees/feat") ,left)))
            (ert-info (label :prefix "Row: ")
              (delete-directory root t)
              (make-directory (if dir (expand-file-name dir root) root) t)
              (make-directory (file-name-directory transcript) t)
              (with-temp-file transcript
                (dolist (line lines) (insert line "\n")))
              (clrhash claude-code--transcript-cache)
              (dolist (resume (list (lambda () (claude-code-resume root id))
                                    ;; RET on its dead row in a view of ROOT.
                                    (lambda ()
                                      (claude-code-tests--in-view
                                        (setq claude-code--project root)
                                        (claude-code--visit-session
                                         (claude-code-tests--find-session
                                          (claude-code-project-sessions root) id)
                                         #'ignore)))))
                (claude-code-tests--with-registry
                  (let ((execs '()))
                    (should (member id (mapcar #'claude-code-session-id
                                               (claude-code-project-sessions root))))
                    (claude-code-tests--recording-launch execs
                      (funcall resume))
                    (let ((args (nth 1 (car execs))))
                      (should (member (concat "--resume=" id) args))
                      (if flag
                          (should (member (concat "--worktree=" flag) args))
                        (should-not (seq-find (lambda (arg)
                                                (string-prefix-p "--worktree" arg))
                                              args)))))))))
        (delete-directory root t)))))

(ert-deftest claude-code-test-remote-project-reads-its-host ()
  "A remote project is read with its host's config dir and process table."
  (let ((claude-code--remote-config-envs (make-hash-table :test 'equal))
        (asked 0))
    ;; A host that cannot be asked is an error, and is asked again next time.
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _) (cl-incf asked) 1)))
      (dotimes (_ 2)
        (should-error (claude-code--config-dir "/ssh:cc-test-host:")
                      :type 'user-error)))
    (should (= asked 2)))
  (ert-with-temp-directory home
    (ert-with-temp-directory config
      (copy-directory claude-code-tests--fixtures config nil nil t)
      (claude-code-tests--with-config
        (claude-code-tests--with-registry
          ;; Pid 1002 runs on the remote host, and nothing runs here.
          (cl-letf (((symbol-function 'list-system-processes)
                     (lambda ()
                       (if (file-remote-p default-directory) '(1 1002) '(1)))))
            (claude-code-tests--on-mock-host nil
              (let* ((claude-code--remote-config-envs
                      (make-hash-table :test 'equal))
                     (host (file-remote-p default-directory))
                     (default (concat host (expand-file-name ".claude" home)))
                     (base tramp-remote-process-environment)
                     (tramp-remote-process-environment base)
                     (connect
                      (lambda (entry)
                        ;; A new connection, so the host is asked anew.
                        (setq tramp-remote-process-environment
                              (append (list entry
                                            (concat "HOME="
                                                    (directory-file-name home)))
                                      base))
                        (tramp-cleanup-connection (tramp-dissect-file-name host)
                                                  t t))))
                (pcase-dolist (`(,entry ,env ,dir)
                               `(("CLAUDE_CONFIG_DIR=/cc/config" "/cc/config"
                                  ,(concat host "/cc/config"))
                                 ("CLAUDE_CONFIG_DIR" nil ,default)
                                 ("CLAUDE_CONFIG_DIR=" nil ,default)))
                  (ert-info (entry :prefix "Host has: ")
                    (funcall connect entry)
                    (should (equal (claude-code--config-dir host) dir))
                    (should (equal (claude-code--config-env host) env))))
                (funcall connect (concat "CLAUDE_CONFIG_DIR="
                                         (directory-file-name config)))
                (let* ((root (concat host "/home/test/proj"))
                       (external "22222222-2222-4222-8222-222222222222")
                       (execs '())
                       ;; Asked from here, so only the code can name the host.
                       (default-directory temporary-file-directory)
                       (sessions (claude-code-project-sessions root))
                       (s (claude-code-tests--find-session sessions external))
                       (dotted (claude-code-tests--find-session
                                sessions "55555555-5555-4555-8555-555555555555")))
                  (should s)
                  (should dotted)
                  (should (claude-code-session-external-p s))
                  (should (equal (claude-code--session-directory s root) root))
                  (should (equal (file-remote-p
                                  (claude-code-session-transcript dotted))
                                 host))
                  (should (equal (plist-get (claude-code-session-worktree-binding
                                             dotted)
                                            :path)
                                 (concat root "/.claude/worktrees/my.feat")))
                  (claude-code-tests--recording-launch execs
                    (should-error (claude-code-resume root external)
                                  :type 'user-error))
                  (should-not execs)
                  ;; Refused by the host's process table, not by a flag.
                  (should-error (claude-code-delete
                                 (claude-code-session--create
                                  :id external
                                  :transcript (claude-code-session-transcript s)))
                                :type 'user-error)
                  (should (file-exists-p
                           (claude-code-session-transcript s))))))))))))

;;;; Model

(defun claude-code-tests--find-session (sessions id)
  "Return the session in SESSIONS whose id is ID."
  (seq-find (lambda (s) (equal (claude-code-session-id s) id)) sessions))

(defmacro claude-code-tests--with-scratch-fixtures (&rest body)
  "Run BODY with `claude-code-config-dir' a scratch copy of the fixtures.
A transcript BODY deletes is gone from the copy alone."
  (declare (indent 0))
  `(let ((claude-code-config-dir (make-temp-file "cc-fixtures" t)))
     (unwind-protect
         (progn
           (copy-directory claude-code-tests--fixtures
                           (file-name-as-directory claude-code-config-dir)
                           nil nil t)
           (clrhash claude-code--transcript-cache)
           ,@body)
       (delete-directory claude-code-config-dir t))))

(ert-deftest claude-code-test-sessions-liveness-is-keyed-by-id ()
  "A session's liveness follows what runs its id, under either root listing it.
A dead session keeps what its transcript says, and only its binding names its
worktree."
  (let ((parent "/home/test/proj")
        (worktree "/home/test/proj/.claude/worktrees/feat")
        (wt-id "33333333-3333-4333-8333-333333333333"))
    (claude-code-tests--with-fixtures
      (claude-code-tests--with-registry
        (claude-code-tests--with-live-pids '()
          (let ((ss (claude-code-project-sessions parent)))
            (cl-flet ((session (id) (claude-code-tests--find-session ss id)))
              (should-not (seq-some #'claude-code-session-alive-p ss))
              (should-not (seq-some #'claude-code-session-external-p ss))
              (should-not (seq-some #'claude-code-session-status ss))
              (should-not (seq-some #'claude-code-session-turn-end ss))
              (let ((s (session "11111111-1111-4111-8111-111111111111")))
                (should (equal (claude-code-session-title s)
                               "Understand the project layout"))
                (should (equal (claude-code-session-last-prompt s) "first prompt"))
                (should (time-equal-p (claude-code-session-last-active s)
                                      (date-to-time "2026-06-10T13:23:27.697Z")))
                (should (file-exists-p (claude-code-session-transcript s))))
              (should (equal (claude-code-session-worktree (session wt-id)) "feat"))
              ;; As written, not as the directory token flattens it.
              (should (equal (claude-code-session-worktree
                              (session "55555555-5555-4555-8555-555555555555"))
                             "my.feat"))
              ;; Its worktree was removed on exit, so a resume lands in the
              ;; parent tree; the binding rides along for the resume to read.
              (let ((s (session "44444444-4444-4444-8444-444444444444")))
                (should-not (claude-code-session-worktree s))
                (should (equal (plist-get (claude-code-session-worktree-binding s)
                                          :name)
                               "left")))
              ;; Started inside a worktree directory, with no binding.
              (let ((s (session "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")))
                (should s)
                (should-not (claude-code-session-worktree s))
                (should-not (claude-code-session-worktree-binding s))))))
        ;; sessions/1003.json runs the worktree session.
        (claude-code-tests--with-live-pids '(1003)
          (dolist (root (list parent worktree))
            (should (eq 'external
                        (claude-code--session-liveness
                         (claude-code-tests--find-session
                          (claude-code-project-sessions root) wt-id)))))))
      ;; Launched from one root and listed under the other.  No pid is live, so
      ;; only the registry can make it alive.
      (pcase-dolist (`(,origin . ,root) (list (cons parent worktree)
                                              (cons worktree parent)))
        (claude-code-tests--with-managed-buffer (buf 1003)
          (claude-code--register wt-id buf origin nil)
          (cl-letf (((symbol-function 'claude-code--session-process)
                     (lambda (b) (eq b buf))))
            (claude-code-tests--with-live-pids '()
              (let* ((ss (claude-code-project-sessions root))
                     (s (claude-code-tests--find-session ss wt-id)))
                (should (claude-code-session-alive-p s))
                (should (eq (claude-code-session-buffer s) buf))
                (should (eql (claude-code-session-pid s) 1003))
                (should (equal (claude-code-session-status s) "waiting"))
                (should (equal (claude-code-session-waiting-for s)
                               "permission prompt"))
                (should (equal (claude-code-session-title s) "Renamed worktree"))
                (should (= 1 (seq-count (lambda (x)
                                          (equal (claude-code-session-id x) wt-id))
                                        ss)))))))))))

(ert-deftest claude-code-test-sessions-list-a-launched-instance-before-its-transcript ()
  "An instance with no transcript yet is listed under the project it runs in.
One launched inside a worktree belongs to the parent project too, and a named
worktree request labels it until Claude writes the name down."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer (inside nil)
      (claude-code-tests--with-managed-buffer (named 4242)
        (claude-code-tests--with-managed-buffer (auto 4243)
          (let ((parent "/home/test/proj")
                (worktree "/home/test/proj/.claude/worktrees/feat"))
            (claude-code--register "inside" inside worktree nil)
            (claude-code--register "named" named parent "my.feat")
            (claude-code--register "auto" auto parent t)
            (cl-letf (((symbol-function 'claude-code--session-process)
                       (lambda (b) (memq b (list inside named auto)))))
              (claude-code-tests--with-live-pids '()
                (dolist (root (list parent worktree))
                  (let ((s (claude-code-tests--find-session
                            (claude-code-project-sessions root) "inside")))
                    (should (claude-code-session-alive-p s))
                    (should (eq (claude-code-session-buffer s) inside))
                    ;; Its pid is not reported yet.
                    (should-not (claude-code-session-pid s))
                    (should-not (claude-code-session-status s))))
                (should-not (claude-code-tests--find-session
                             (claude-code-project-sessions "/home/other")
                             "inside"))
                (let ((ss (claude-code-project-sessions parent)))
                  (should (equal (claude-code-session-worktree
                                  (claude-code-tests--find-session ss "named"))
                                 "my.feat"))
                  (should-not (claude-code-session-worktree
                               (claude-code-tests--find-session ss "auto"))))
                ;; Not one launched beside it, from a directory extending its name.
                (claude-code--register "old" inside "/home/test/proj-old" nil)
                (should-not (claude-code-tests--find-session
                             (claude-code-project-sessions parent) "old"))))))))))

(ert-deftest claude-code-test-instance-state-follows-its-sessions-file ()
  "An instance takes its session and status from its sessions/ file.
Its turn end is its root record's `done' or `error' while it rests, and a file
caught mid-rewrite or gone leaves it on the session last read."
  (claude-code-tests--with-config
    (claude-code-tests--with-managed-buffer (buf 70)
      (claude-code--register "launched" buf "/r" nil)
      (cl-letf (((symbol-function 'claude-code--session-process)
                 (lambda (b) (eq b buf))))
        (cl-flet ((session (id)
                    (claude-code-tests--find-session
                     (claude-code-project-sessions "/r") id))
                  (report (records)
                    (with-current-buffer buf
                      (setq ghostel-program-status records))))
          (report '(("" :state done)))
          (let ((s (session "launched")))
            (should (claude-code-session-alive-p s))
            (should (eq (claude-code-session-buffer s) buf))
            (should-not (claude-code-session-status s))
            (should-not (claude-code-session-turn-end s)))
          (pcase-dolist (`(,status ,records ,turn-end ,message)
                         '(("idle" (("" :state done)) done nil)
                           ("shell" (("" :state done :msg "m")) done "m")
                           ("idle" (("" :state error :msg "There's an issue"))
                            error "There's an issue")
                           ("busy" (("" :state done :msg "m")) nil nil)
                           ("waiting" (("" :state done :msg "m")) nil nil)
                           ("idle" (("" :state working)) nil nil)
                           ("idle" (("" :state blocked :msg "approve")) nil nil)
                           ("idle" nil nil nil)
                           ("idle" (("a93609d08ab42add7" :state error :msg "sub")
                                    ("" :state working))
                            nil nil)))
            (claude-code-tests--write-session-file
             70 (json-serialize (list :pid 70 :sessionId "cleared"
                                      :status status)))
            (report records)
            (should-not (session "launched"))
            (let ((s (session "cleared")))
              (should (claude-code-session-alive-p s))
              (should (eq (claude-code-session-buffer s) buf))
              (should (equal (claude-code-session-status s) status))
              (should (eq (claude-code-session-turn-end s) turn-end))
              (should (equal (claude-code-session-turn-end-message s) message))))
          (claude-code-tests--write-session-file 70 "{\"pid\":70,\"sessi")
          (should (eq (claude-code-session-buffer (session "cleared")) buf))
          (delete-file (expand-file-name "70.json" (claude-code--sessions-dir)))
          (should (eq (claude-code-session-buffer (session "cleared")) buf))
          (should-not (session "launched")))))))

(ert-deftest claude-code-test-sessions-run-outside-emacs ()
  "A session run outside Emacs is external: resume and delete refuse it.
Its pid counts only on its own host, and a process table that cannot be read
counts every pid as running."
  (claude-code-tests--with-scratch-fixtures
    ;; sessions/1002.json runs this session.
    (let ((id "22222222-2222-4222-8222-222222222222")
          (root "/home/test/proj"))
      (cl-flet ((liveness ()
                  (claude-code--session-liveness
                   (claude-code-tests--find-session
                    (claude-code-project-sessions root) id))))
        (claude-code-tests--with-registry
          (claude-code-tests--with-live-pids '(1002)
            (should (eq (liveness) 'external)))
          (claude-code-tests--with-live-pids '()
            (should (eq (liveness) 'dead))))
        ;; An instance on another host holding the same pid hides nothing here.
        (claude-code-tests--with-managed-buffer (remote 1002)
          (claude-code--register "remote" remote
                                 (concat "/ssh:cc-test-host:" root) nil)
          (cl-letf (((symbol-function 'claude-code--session-process)
                     (lambda (b) (eq b remote))))
            (claude-code-tests--with-live-pids '(1002)
              (should (eq (liveness) 'external)))))
        ;; Emacs's instance runs it while its terminal process lives.
        (claude-code-tests--with-managed-buffer (buf nil)
          (claude-code--register id buf root nil)
          (claude-code-tests--with-live-pids '()
            (should (eq (liveness) 'dead))
            (cl-letf (((symbol-function 'claude-code--session-process)
                       (lambda (b) (eq b buf))))
              (should (eq (liveness) 'alive)))))
        (claude-code-tests--with-registry
          (cl-letf (((symbol-function 'list-system-processes) #'ignore))
            (let* ((s (claude-code-tests--find-session
                       (claude-code-project-sessions root) id))
                   (transcript (claude-code-session-transcript s))
                   (execs '()))
              (should (eq (claude-code--session-liveness s) 'external))
              (claude-code-tests--recording-launch execs
                (should-error (claude-code-resume root id) :type 'user-error))
              (should-not execs)
              ;; A struct from before the table went unreadable says dead.
              (should-error (claude-code-delete
                             (claude-code-session--create
                              :id id :transcript transcript))
                            :type 'user-error)
              (should (file-exists-p transcript)))))))))

(ert-deftest claude-code-test-sessions-follow-an-instance-across-a-clear ()
  "A `/clear' moves an instance onto the session its sessions/ file names.
The session it left is dead: a resume of it starts an instance of its own, and
it can be deleted.  Here pid 1001 was launched on 22222222 and its file now
names 11111111."
  (claude-code-tests--with-scratch-fixtures
    (claude-code-tests--with-managed-buffer (buf 1001)
      (let ((root "/home/test/proj")
            (left "22222222-2222-4222-8222-222222222222")
            (now "11111111-1111-4111-8111-111111111111")
            (execs '()))
        (claude-code--register left buf root nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          (claude-code-tests--with-live-pids '(1001)
            (let* ((ss (claude-code-project-sessions root))
                   (current (claude-code-tests--find-session ss now))
                   (abandoned (claude-code-tests--find-session ss left)))
              (should (claude-code-session-alive-p current))
              (should (eq (claude-code-session-buffer current) buf))
              (should (equal (claude-code-session-status current) "busy"))
              (should (eq 'dead (claude-code--session-liveness abandoned)))
              (should-not (seq-some #'claude-code-session-external-p ss))
              (claude-code-tests--recording-launch execs
                (should-not (eq (claude-code-resume root left) buf))
                (should (member (concat "--resume=" left) (nth 1 (car execs)))))
              (claude-code-delete abandoned)
              (should-not (file-exists-p
                           (claude-code-session-transcript abandoned))))))))))

(ert-deftest claude-code-test-remote-instance-answers-from-the-last-query ()
  "What hooks ask of a remote instance comes from the last query, not its host.
Asking the host from a status hook or a timer would stall Emacs on the network.
The status that query read is as stale, so a `shell' one holds back no
announcement."
  (claude-code-tests--with-scratch-fixtures
    (claude-code-tests--with-managed-buffer (buf 70)
      (claude-code-tests--on-mock-host nil
        (let* ((host (file-remote-p default-directory))
               (claude-code--remote-config-envs (make-hash-table :test 'equal))
               (root (concat host "/home/test/proj"))
               (id "33333333-3333-4333-8333-333333333333")
               (announced 0)
               (claude-code-notify-function
                (lambda (_session _body) (cl-incf announced)))
               (default-directory temporary-file-directory))
          (puthash host (cons claude-code-config-dir "/home/test")
                   claude-code--remote-config-envs)
          (claude-code--register id buf root nil)
          (cl-letf (((symbol-function 'claude-code--session-process)
                     (lambda (b) (eq b buf))))
            (cl-flet ((report (cwd status)
                        (claude-code-tests--write-session-file
                         70 (json-serialize (list :pid 70 :sessionId id
                                                  :cwd cwd :status status)))))
              (claude-code-tests--with-live-pids '()
                (report "/w" "shell")
                (let ((s (claude-code-tests--find-session
                          (claude-code-project-sessions root) id)))
                  ;; The host moves on; only a read of it would see that.
                  (report "/x" "busy")
                  (delete-file (claude-code-session-transcript s)))
                (should (equal (claude-code--instance-cwd buf) (concat host "/w")))
                (let ((s (claude-code--instance-session buf)))
                  (should (equal (claude-code-session-title s) "Renamed worktree"))
                  (should (equal (claude-code-session-worktree s) "feat"))
                  (should (equal (claude-code-session-status s) "shell")))
                (claude-code--announce buf 'done 1000.0)
                (should (= announced 1))
                ;; Once a query sees a `/clear', the session left behind lends
                ;; the new one nothing.
                (claude-code-tests--write-session-file 70 "cleared")
                (claude-code-project-sessions root)
                (let ((s (claude-code--instance-session buf)))
                  (should (equal (claude-code-session-id s) "cleared"))
                  (should-not (claude-code-session-title s))
                  (should-not (claude-code-session-worktree s)))))))))))

(ert-deftest claude-code-test-session-directory ()
  "A session works where the process running it is now, else in its worktree.
Emacs's instance works where its sessions/ file says, else in the worktree it
asked for, else where it was launched; one outside Emacs, where its pid's
sessions/ file says.  With no process, the binding's worktree counts while it
is on disk, and the root otherwise."
  (let* ((root (file-truename (make-temp-file "cc-root" t)))
         (feat (claude-code--worktree-path root "feat"))
         (wt "33333333-3333-4333-8333-333333333333")
         (fixture-feat "/home/test/proj/.claude/worktrees/feat")
         (dir (lambda (&rest slots)
                (claude-code--session-directory
                 (apply #'claude-code-session--create slots) root))))
    (unwind-protect
        (claude-code-tests--with-fixtures
          (make-directory feat t)
          (claude-code-tests--with-managed-buffer (buf 1003)
            (claude-code-tests--with-managed-buffer (new 4242)
              ;; sessions/1003.json runs session 33333333 in its worktree.
              (claude-code--register "cleared" buf root nil)
              (should (equal (funcall dir :id "cleared" :alive-p t :buffer buf)
                             fixture-feat))
              ;; No sessions/4242.json yet.
              (claude-code--register "new" new feat nil)
              (should (equal (funcall dir :id "new" :alive-p t :buffer new) feat))
              (claude-code--register "new" new root "team/feat")
              (should (equal (funcall dir :id "new" :alive-p t :buffer new)
                             (claude-code--worktree-path root "team/feat")))
              ;; A row still drawn alive whose instance has gone.
              (kill-buffer new)
              (should (equal (funcall dir :id wt :alive-p t :buffer new) root))))
          (claude-code-tests--with-registry
            (claude-code-tests--with-live-pids '(1003)
              (should (equal (funcall dir :id wt :external-p t) fixture-feat))))
          (should (equal (funcall dir :id wt :worktree-binding
                                  (list :name "feat" :path feat :bound nil))
                         feat))
          (should (equal (funcall dir :id wt :worktree-binding
                                  (list :name "gone" :bound t
                                        :path (claude-code--worktree-path
                                               root "gone")))
                         root))
          (should (equal (funcall dir :id wt) root)))
      (delete-directory root t))))

(ert-deftest claude-code-test-normalize-root ()
  "Root normalisation resolves symlinks so a symlinked root matches Claude's cwd."
  (let* ((real (make-temp-file "cc-real" t))
         (link (make-temp-name
                (expand-file-name "cc-link" temporary-file-directory))))
    (unwind-protect
        (progn
          (make-symbolic-link (directory-file-name real) link)
          ;; The symlinked path resolves to the real directory...
          (should (equal (claude-code--normalize-root link)
                         (directory-file-name (file-truename real))))
          ;; ...which is not what a bare `expand-file-name' would have produced.
          (should-not (equal (claude-code--normalize-root link)
                             (directory-file-name (expand-file-name link)))))
      (when (file-symlink-p link) (delete-file link))
      (delete-directory real t))))


;;;; Operations

(ert-deftest claude-code-test-cli-arguments ()
  "Spawn and resume hand the CLI their options, after the MCP wiring's own."
  (claude-code-tests--with-config
    (claude-code-tests--with-registry
      (let ((execs '())
            (claude-code-cli "claude-code-tests-cli")
            (mcp '("--mcp-config" "wiring")))
        (claude-code-tests--recording-launch execs
          (cl-letf (((symbol-function 'claude-code--mcp-wiring)
                     (lambda (_buffer) (list mcp))))
            (cl-flet ((launched ()
                        ;; The session's own arguments to the CLI just run.
                        (pcase-let ((`(,_ ,args ,_ ,program) (car execs)))
                          (should (equal program claude-code-cli))
                          (should (equal (seq-take args (length mcp)) mcp))
                          (nthcdr (length mcp) args)))
                      (value (flag args) (cadr (member flag args))))
              (let* ((id (car (claude-code-spawn "/r" :prompt "hi")))
                     (args (launched)))
                (should (equal (value "--session-id" args) id))
                (should (equal (last args 2) '("--" "hi"))))
              (claude-code-spawn "/r" :prompt "")
              (should-not (seq-intersection (launched) '("--" "")))
              ;; "--" keeps the prompt off `--worktree', which takes an
              ;; optional name.
              (claude-code-spawn "/r" :worktree t :prompt "hi")
              (let ((args (launched)))
                (should (member "--worktree" args))
                (should (equal (last args 2) '("--" "hi"))))
              ;; A name rides in its flag's own argument, so one the CLI would
              ;; read as a flag of its own still names the worktree.
              (dolist (name '("feat" "--ax-screen-reader"))
                (claude-code-spawn "/r" :worktree name)
                (should (member (concat "--worktree=" name) (launched)))
                (should-not (member name (launched))))
              ;; An empty name is passed on too: the CLI reads it as none.
              (dolist (name '("a long name" ""))
                (claude-code-spawn "/r" :name name)
                (should (member (concat "--name=" name) (launched))))
              (claude-code-spawn "/r" :model "opus" :effort "xhigh")
              (let ((args (launched)))
                (should (equal (value "--model" args) "opus"))
                (should (equal (value "--effort" args) "xhigh")))
              (claude-code-resume "/r" "resumed")
              (let ((args (launched)))
                (should (member "--resume=resumed" args))
                (should-not (member "--session-id" args))))))))))

(ert-deftest claude-code-test-launch-starts-only-a-runnable-instance ()
  "A launch runs the CLI behind its PID report, under dtach when detachable.
A CLI or a dtach the host lacks refuses the launch before anything starts."
  (claude-code-tests--with-executable bin "claude-code-tests-cli"
    (let* ((cli (expand-file-name "claude-code-tests-cli" bin))
           (dtach (expand-file-name "claude-code-tests-dtach" bin))
           (wrapper (claude-code--reporting-command cli nil))
           (resolve (symbol-function 'claude-code--resolve-executable))
           (exec-path (list bin))
           (claude-code-cli "claude-code-tests-cli")
           (claude-code-dtach "claude-code-tests-dtach")
           (buffers (buffer-list))
           (execs '())
           (raws '()))
      (copy-file cli dtach)
      (claude-code-tests--with-registry
        (claude-code-tests--recording-launch execs
          (let ((recorded (symbol-function 'ghostel-exec)))
            (cl-letf (((symbol-function 'claude-code--resolve-executable)
                       resolve)
                      ((symbol-function 'claude-code--mcp-wiring)
                       (lambda (_buffer) '(("--mcp-marker"))))
                      ((symbol-function 'ghostel-exec)
                       (lambda (buffer program args)
                         (push (cons program args) raws)
                         (funcall recorded buffer program args))))
              (let ((claude-code-cli "claude-code-tests-none"))
                (should-error (claude-code-spawn "/r" :detachable nil)
                              :type 'user-error))
              (let ((claude-code-dtach "claude-code-tests-none"))
                (should (string-search
                         "claude-code-detachable"
                         (cadr (should-error
                                (claude-code-spawn "/r" :detachable t)
                                :type 'user-error)))))
              (should-not raws)
              (should-not (seq-difference (buffer-list) buffers))
              (should (hash-table-empty-p claude-code--managed))
              (let* ((id (car (claude-code-spawn "/r" :detachable nil)))
                     (raw (car raws)))
                (should (eql (cl-search wrapper raw :test #'equal) 0))
                (should-not (member dtach raw))
                (should (member "--mcp-marker" raw))
                (should-not (plist-get (claude-code-tests--entry id)
                                       :detachable)))
              (let* ((id (car (claude-code-spawn "/r" :detachable t)))
                     (raw (car raws))
                     (start (cl-search wrapper raw :test #'equal))
                     (holding (seq-take raw start))
                     (socket (seq-find (lambda (arg)
                                         (string-match-p
                                          claude-code-tests--uuid-re arg))
                                       holding)))
                (should (equal holding
                               (claude-code--holding-command dtach socket nil)))
                (should-not (equal socket id))
                (should (member "--mcp-marker" raw))
                (should (plist-get (claude-code-tests--entry id)
                                   :detachable)))
              (claude-code-tests--with-config
                (claude-code-resume "/r" "resumed" :detachable t))
              (should (member dtach (car raws)))
              (should (plist-get (claude-code-tests--entry "resumed")
                                 :detachable)))))))))

(ert-deftest claude-code-test-launch-hands-over-the-config-env ()
  "An instance runs in the config dir Emacs reads for its host.
`CLAUDE_CONFIG_DIR' names it, and is left unset where the CLI's default does."
  (claude-code-tests--with-child-env child-env
    ;; An empty variable is unset for the instance too: the CLI reads some of
    ;; its paths off an empty one.
    (dolist (unset '("CLAUDE_CONFIG_DIR" "CLAUDE_CONFIG_DIR="))
      (let ((process-environment (cons unset process-environment))
            (claude-code-config-dir "~/.claude"))
        (claude-code-spawn "/r")
        (should-not (child-env "CLAUDE_CONFIG_DIR"))))
    (let ((process-environment (cons "CLAUDE_CONFIG_DIR" process-environment))
          (claude-code-config-dir "~/cc-config"))
      (claude-code-spawn "/r")
      (should (equal (child-env "CLAUDE_CONFIG_DIR")
                     (expand-file-name "~/cc-config"))))
    (let ((process-environment (cons "CLAUDE_CONFIG_DIR=/cc/local"
                                     process-environment))
          (claude-code-config-dir "/cc/local"))
      (claude-code-spawn "/r")
      (should (equal (child-env "CLAUDE_CONFIG_DIR") "/cc/local")))
    ;; A remote instance gets its host's own value, unset included.  Emacs's
    ;; own variable is left alone: TRAMP hands a binding of it to the host.
    (let ((claude-code-config-dir "/cc/local"))
      (pcase-dolist (`(,entry ,value) '(("CLAUDE_CONFIG_DIR" nil)
                                        ("CLAUDE_CONFIG_DIR=/cc/remote"
                                         "/cc/remote")))
        (let ((tramp-remote-process-environment
               (cons entry tramp-remote-process-environment))
              (claude-code--remote-config-envs (make-hash-table :test 'equal)))
          (claude-code-tests--on-mock-host nil
            (claude-code-spawn default-directory)
            (should (equal (child-env "CLAUDE_CONFIG_DIR") value))))))))

(ert-deftest claude-code-test-resolve-executable-here ()
  "On this machine a bare name is found on `exec-path', a file name as a file."
  (claude-code-tests--with-executable dir "claude-code-tests-cli"
    (cl-flet ((resolve (name) (claude-code--resolve-executable name)))
      (let ((cli (expand-file-name "claude-code-tests-cli" dir)))
        (let ((exec-path (list dir))
              (default-directory "/"))
          (should (equal (resolve "claude-code-tests-cli") cli)))
        (let ((exec-path '())
              (default-directory dir))
          (should (equal (resolve "./claude-code-tests-cli") cli))
          (should (equal (resolve cli) cli))
          (dolist (missing '("claude-code-tests-cli" "./claude-code-tests-none"
                             "/claude-code-tests/cli"))
            (should-error (resolve missing) :type 'user-error)))))))

(ert-deftest claude-code-test-resolve-executable-on-the-host ()
  "A remote project runs the CLI its host has, by the host's path and files."
  (claude-code-tests--with-executable dir "claude-code-tests-cli"
    (cl-flet ((resolve (name) (claude-code--resolve-executable name)))
      (let ((cli (expand-file-name "claude-code-tests-cli" dir))
            (real (symbol-function 'claude-code--resolve-executable))
            ;; A home of its own sets the host's file names apart from Emacs's.
            (tramp-remote-process-environment
             (cons (concat "HOME=" (directory-file-name dir))
                   tramp-remote-process-environment)))
        (let ((exec-path (list dir)))
          (claude-code-tests--on-mock-host nil
            (should-error (resolve "claude-code-tests-cli") :type 'user-error)
            ;; TRAMP appends `default-directory' to the host's search path, and
            ;; a project's own executable is not the CLI.
            (let ((default-directory (concat (file-remote-p default-directory)
                                             dir)))
              (should-error (resolve "claude-code-tests-cli") :type 'user-error))
            (should (equal (resolve "~/claude-code-tests-cli") cli))
            (should-error (resolve "~/claude-code-tests-none") :type 'user-error)))
        (let ((exec-path '())
              (claude-code-cli "claude-code-tests-cli")
              (claude-code--remote-config-envs (make-hash-table :test 'equal))
              (execs '()))
          (claude-code-tests--on-mock-host (list dir)
            (should (equal (resolve "claude-code-tests-cli") cli))
            (let ((root default-directory)
                  ;; The caller's own directory is local: only the root may
                  ;; decide the host.
                  (default-directory temporary-file-directory))
              (claude-code-tests--with-registry
                (claude-code-tests--recording-launch execs
                  (cl-letf (((symbol-function 'claude-code--resolve-executable)
                             real))
                    (claude-code-spawn root :detachable nil)
                    (should (equal (nth 3 (car execs)) cli))))))))))))

(defun claude-code-tests--terminal (buffer)
  "Give BUFFER a live terminal process, which goes when BUFFER does."
  (with-current-buffer buffer
    (setq-local ghostel--process
                (make-pipe-process :name "cc-terminal" :buffer buffer
                                   :noquery t :sentinel #'ignore))))

(ert-deftest claude-code-test-an-instance-ends-with-its-terminal ()
  "An alive struct reaches its instance only while the terminal runs.
Closing the buffer of a detachable instance that started announces that it runs
on; any other abnormal end is reported with the terminal's last line."
  (let ((reported '()))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) reported))))
      ;; (DETACHABLE PID EVENT RUNS-ON EXIT-REPORTED), with no EVENT for a
      ;; buffer closed while its terminal runs.
      (pcase-dolist (`(,detachable ,pid ,event ,runs-on ,exit-reported)
                     '((t 77 nil t nil)
                       (t 77 "exited abnormally with code 255\n" t nil)
                       (t 77 "finished\n" nil nil)
                       (t nil "exited abnormally with code 1\n" nil t)
                       (nil 77 nil nil nil)
                       (nil 77 "exited abnormally with code 1\n" nil t)
                       (nil 77 "finished\n" nil nil)))
        (setq reported '())
        (claude-code-tests--with-managed-buffer (buf pid)
          (let ((session (claude-code-session--create :id "i" :alive-p t
                                                      :buffer buf))
                (name (buffer-name buf)))
            (claude-code--register "i" buf "/r" nil detachable)
            (with-current-buffer buf
              (insert "starting\n\n"
                      "claude-code: cannot hold instances in /x  \n\n"))
            (claude-code-tests--terminal buf)
            (should (eq (claude-code--buffer session) buf))
            ;; As Ghostel ends a terminal: the process is gone, then the exit
            ;; hooks run, then the buffer is killed.
            (when event
              (delete-process (buffer-local-value 'ghostel--process buf))
              (should (buffer-live-p buf))
              (should-error (claude-code--buffer session) :type 'user-error)
              (with-current-buffer buf
                (run-hook-with-args 'ghostel-exit-functions buf event)))
            (kill-buffer buf)
            (should (hash-table-empty-p claude-code--managed))
            (should (eq runs-on
                        (and (seq-find (lambda (m) (string-search "runs on" m))
                                       reported)
                             t)))
            (should (eq exit-reported
                        (and (seq-find
                              (lambda (m)
                                (and (string-search name m)
                                     (string-search "cannot hold instances in /x"
                                                    m)))
                              reported)
                             t)))))))))

(ert-deftest claude-code-test-kill-and-detach-a-detachable-instance ()
  "A detachable instance is killed by signal and detached by closing its buffer.
Once detached, its stale alive struct drives nothing.  Detaching refuses an
instance that would die with its buffer, and an external session."
  (let ((signals '())
        (refused nil)
        (driven '()))
    (claude-code-tests--without-requiring '(ghostel)
      (cl-letf (((symbol-function 'signal-process)
                 (lambda (pid signal &optional host)
                   (push (list pid signal host) signals)
                   (if refused -1 0)))
                ((symbol-function 'ghostel-paste-string)
                 (lambda (s) (push s driven)))
                ((symbol-function 'ghostel-send-key)
                 (lambda (key &rest _) (push key driven)))
                ((symbol-function 'ghostel-send-C-c)
                 (lambda () (push 'C-c driven))))
        (claude-code-tests--with-managed-buffer (buf 77)
          (claude-code--register "d" buf "/ssh:box:/r" nil t)
          (claude-code-tests--terminal buf)
          (let ((session (claude-code-session--create :id "d" :alive-p t
                                                      :buffer buf)))
            (claude-code-kill session)
            (should (equal signals '((77 SIGTERM "/ssh:box:"))))
            (should (buffer-live-p buf))
            (setq refused t)
            (should-error (claude-code-kill session) :type 'user-error)
            (setq refused nil
                  signals '())
            (with-current-buffer buf (setq-local claude-code--pid nil))
            (should-error (claude-code-kill session) :type 'user-error)
            (claude-code-detach session)
            (should-not (buffer-live-p buf))
            (should (hash-table-empty-p claude-code--managed))
            (dolist (operation (list #'claude-code-kill #'claude-code-detach
                                     (lambda (s) (claude-code-rename s "n"))
                                     (lambda (s) (claude-code-send-text s "t"))
                                     #'claude-code-interrupt))
              (should-error (funcall operation session) :type 'user-error))))
        (claude-code-tests--with-managed-buffer buf
          (claude-code--register "n" buf "/r" nil)
          (claude-code-tests--terminal buf)
          (should-error (claude-code-detach
                         (claude-code-session--create :id "n" :alive-p t
                                                      :buffer buf))
                        :type 'user-error)
          (should (buffer-live-p buf)))
        (should-error (claude-code-detach
                       (claude-code-session--create :id "e" :external-p t))
                      :type 'user-error)))
    (should-not signals)
    (should-not driven)))

(defmacro claude-code-tests--holding (spec &rest body)
  "Run BODY with a scratch runtime dir and a dtach that records its arguments.
SPEC is (RUNTIME DTACH ARGS): RUNTIME is bound to a fresh directory that
`$XDG_RUNTIME_DIR' names, DTACH to an executable that writes each argument it
gets on a line of the file ARGS, then runs the command behind dtach's six."
  (declare (indent 1))
  (pcase-let ((`(,runtime ,dtach ,args) spec))
    `(ert-with-temp-directory ,runtime
       (let* ((,dtach (expand-file-name "dtach" ,runtime))
              (,args (expand-file-name "args" ,runtime))
              (process-environment
               (append (list (concat "XDG_RUNTIME_DIR="
                                     (directory-file-name ,runtime))
                             (concat "CC_ARGS=" ,args))
                       process-environment)))
         (write-region (concat "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CC_ARGS\"\n"
                               "shift 6\nexec \"$@\"\n")
                       nil ,dtach)
         (set-file-modes ,dtach #o700)
         ,@body))))

(ert-deftest claude-code-test-wrappers-hold-report-and-attach ()
  "The shell wrappers hold an instance in dtach, report its PID and attach it.
A real `/bin/sh' runs each, over a dtach that records its arguments."
  (claude-code-tests--holding (runtime dtach args)
    (let ((dir (expand-file-name "claude-code" runtime)))
      (cl-flet ((run (command)
                  (with-temp-buffer
                    (cons (apply #'call-process (car command) nil t nil
                                 (cdr command))
                          (buffer-string))))
                (dtach-args ()
                  (when (file-exists-p args)
                    (with-temp-buffer
                      (insert-file-contents args)
                      (split-string (buffer-string) "\n" t)))))
        ;; Another user could have planted the directory, and every socket in
        ;; it attaches a terminal running Claude.
        (ert-with-temp-directory elsewhere
          (make-symbolic-link elsewhere dir)
          (should (eql (car (run (claude-code--holding-command
                                  dtach "s" '("true"))))
                       1))
          (should-not (dtach-args))
          (delete-file dir))
        (let* ((socket (expand-file-name "sock" dir))
               (output (cdr (run (claude-code--holding-command
                                  dtach "sock"
                                  (claude-code--reporting-command
                                   "/bin/sh"
                                   '("-c" "printf '%s\\n' $$ \"$(umask)\" \"$@\""
                                     "zero" "a b" "c'd"))))))
               (master (string-join (cons dtach (dtach-args)) " ")))
          (should (equal (cadr (member "-c" (dtach-args))) socket))
          (should (= (file-modes dir) #o700))
          (should (string-match "\e]52;e;\\([^\a]*\\)\a" output))
          (let* ((payload (match-string 1 output))
                 (lines (split-string (substring output (match-end 0)) "\n" t)))
            (pcase-let ((`(,pid ,umask . ,program-args) lines))
              (should (= (string-to-number umask 8)
                         (logand #o777 (lognot (default-file-modes)))))
              (should (equal program-args '("a b" "c'd")))
              ;; Dispatched as Ghostel dispatches an OSC 52 eval.
              (with-temp-buffer
                (claude-code-instance-mode)
                (cl-flet ((report (payload)
                            (let ((parts (split-string-and-unquote payload)))
                              (apply (cadr (assoc (car parts) ghostel-eval-cmds))
                                     (cdr parts)))))
                  ;; The terminal evaluates the report and nothing else.
                  (should (equal (mapcar #'car ghostel-eval-cmds)
                                 (list claude-code--pid-report)))
                  (report (concat claude-code--pid-report " x"))
                  (should-not claude-code--pid)
                  (report payload)
                  (should (eql claude-code--pid (string-to-number pid)))
                  (should-not ghostel-eval-cmds)))))
          ;; Only a master the holding command started names its socket.
          (should (equal (claude-code--holder-socket master) socket))
          (let ((fallback
                 "/tmp/claude-code-1000/0b6f2c8e-1d2a-4c3b-9e4f-5a6b7c8d9e0f"))
            (should (equal (claude-code--holder-socket
                            (string-replace socket fallback master))
                           fallback)))
          (should-not (claude-code--holder-socket
                       (string-replace socket "/tmp/mine/claude.sock" master)))
          (should-not (claude-code--holder-socket
                       (concat dtach " -c " socket " -z claude")))
          (should-not (claude-code--holder-socket nil))
          (let ((output (cdr (run (claude-code--attaching-command
                                   dtach socket)))))
            (should (string-search "\e[?2004h" output))
            (should (equal (cadr (member "-a" (dtach-args))) socket))))))))

(defun claude-code-tests--master-args (socket)
  "Return the command line of the dtach master holding an instance on SOCKET."
  (format "/usr/bin/dtach -c %s %s /bin/sh -c claude"
          socket claude-code--dtach-flags))

(defmacro claude-code-tests--with-processes (table &rest body)
  "Run BODY with TABLE, an alist of (PID PPID ARGS), the process table here.
Here is the host of `default-directory' on entry.  Every pid in TABLE is live
there, as is Emacs's own, and nothing but init runs on any other host."
  (declare (indent 1))
  (let ((rows (gensym "rows"))
        (host (gensym "host")))
    `(let ((,rows ,table)
           (,host (file-remote-p default-directory)))
       (cl-letf (((symbol-function 'list-system-processes)
                  (lambda ()
                    (if (equal (file-remote-p default-directory) ,host)
                        (cons (emacs-pid) (mapcar #'car ,rows))
                      (list 1))))
                 ((symbol-function 'process-attributes)
                  (lambda (pid)
                    (when-let* (((equal (file-remote-p default-directory) ,host))
                                (row (assq pid ,rows)))
                      (list (cons 'ppid (nth 1 row)) (cons 'args (nth 2 row)))))))
         ,@body))))

(ert-deftest claude-code-test-sessions-name-the-holder-of-a-held-instance ()
  "An external session a detachable instance runs names its socket on its host.
It does so from its transcript, and before Claude writes one when sessions/
places the instance in the project or a worktree of it."
  (cl-flet ((socket (n) (format "/run/user/1000/claude-code/%s" n))
            (find (sessions id)
              (seq-find (lambda (s) (equal (claude-code-session-id s) id))
                        sessions)))
    (claude-code-tests--with-fixtures
      (claude-code-tests--with-registry
        ;; 22222222 runs held, 33333333 unheld, and 88888888, which a program
        ;; drove, held.
        (claude-code-tests--with-processes
            `((1002 900 "claude") (900 1 ,(claude-code-tests--master-args
                                           (socket "a")))
              (1003 1 "claude")
              (1005 901 "claude") (901 1 ,(claude-code-tests--master-args
                                           (socket "b"))))
          (let* ((held "22222222-2222-4222-8222-222222222222")
                 (sessions (claude-code-project-sessions "/home/test/proj")))
            (should (equal (claude-code-session-holder (find sessions held))
                           (socket "a")))
            (dolist (session sessions)
              (unless (equal (claude-code-session-id session) held)
                (should-not (claude-code-session-holder session))))
            (should-not (find sessions
                              "88888888-8888-4888-8888-888888888888"))))))
    (claude-code-tests--with-config
      (claude-code-tests--with-registry
        ;; (PID ID CWD HELD)
        (let ((rows '((2001 "root" "/home/test/proj" t)
                      (2002 "wt" "/home/test/proj/.claude/worktrees/feat" t)
                      (2003 "other" "/home/other" t)
                      (2004 "unheld" "/home/test/proj" nil)
                      (2005 "no-cwd" nil t))))
          (pcase-dolist (`(,pid ,id ,cwd ,_) rows)
            (claude-code-tests--write-session-file
             pid (if cwd
                     (format "{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\"}"
                             pid id cwd)
                   id)))
          (let ((table (mapcan (pcase-lambda (`(,pid ,_ ,_ ,held))
                                 (if held
                                     (list (list pid (+ pid 1000) "claude")
                                           (list (+ pid 1000) 1
                                                 (claude-code-tests--master-args
                                                  (socket pid))))
                                   (list (list pid 1 "claude"))))
                               rows)))
            (cl-flet ((check (host)
                        (let* ((root (concat host "/home/test/proj"))
                               (feat (concat root "/.claude/worktrees/feat"))
                               (sessions (claude-code-project-sessions root)))
                          (should (equal (sort (mapcar #'claude-code-session-id
                                                       sessions)
                                               #'string<)
                                         '("root" "wt")))
                          (dolist (session sessions)
                            (should (claude-code-session-external-p session))
                            (should-not (claude-code-session-transcript session))
                            (should-not (claude-code-session-worktree session)))
                          (should (equal (claude-code-session-holder
                                          (find sessions "wt"))
                                         (concat host (socket 2002))))
                          (should (equal (mapcar #'claude-code-session-id
                                                 (claude-code-project-sessions
                                                  feat))
                                         '("wt"))))))
              (claude-code-tests--with-processes table
                (check nil))
              ;; The same instances on a remote host, whose config dir is this
              ;; one.
              (let ((tramp-remote-process-environment
                     (cons (concat "CLAUDE_CONFIG_DIR=" claude-code-config-dir)
                           tramp-remote-process-environment))
                    (claude-code--remote-config-envs
                     (make-hash-table :test 'equal)))
                (claude-code-tests--on-mock-host nil
                  (let ((host (file-remote-p default-directory)))
                    (claude-code-tests--with-processes table
                      (let ((default-directory temporary-file-directory))
                        (check host)))))))))))))

(defmacro claude-code-tests--attaching (execs &rest body)
  "Run BODY with `ghostel-exec' stubbed to push (BUFFER PROGRAM ARGS) onto EXECS.
The terminal it starts runs until its buffer is killed, and every buffer an
attach hosted is killed afterwards."
  (declare (indent 1))
  `(claude-code-tests--without-requiring '(ghostel)
     (cl-letf (((symbol-function 'ghostel-exec)
                (lambda (buffer program args)
                  (with-current-buffer buffer
                    (setq-local ghostel-program-status nil))
                  (claude-code-tests--terminal buffer)
                  (push (list buffer program args) ,execs)))
               (after-focus-change-function after-focus-change-function))
       (unwind-protect (progn ,@body)
         (dolist (exec ,execs)
           (when (buffer-live-p (car exec)) (kill-buffer (car exec))))))))

(ert-deftest claude-code-test-attach-a-held-instance ()
  "Attaching hosts a held instance's session in a buffer running dtach's client.
Only a session a detachable instance runs, whose socket is still there, can be
attached, and a remote one is found and attached on its host."
  (claude-code-tests--with-executable bin "dtach"
    (let* ((claude-code-dtach (expand-file-name "dtach" bin))
           (sockets (expand-file-name "claude-code" bin))
           (socket (expand-file-name "0b6f2c8e-1d2a-4c3b-9e4f-5a6b7c8d9e0f"
                                     sockets))
           (gone (expand-file-name "00000000-1d2a-4c3b-9e4f-5a6b7c8d9e0f"
                                   sockets))
           (id "33333333-3333-4333-8333-333333333333")
           (cwd "/home/test/proj/.claude/worktrees/feat/")
           (held `((1003 900 "claude")
                   (900 1 ,(claude-code-tests--master-args socket)))))
      (make-directory sockets)
      (write-region "" nil socket)
      (claude-code-tests--with-fixtures
        (claude-code-tests--with-registry
          (let ((execs '()))
            (claude-code-tests--attaching execs
              ;; No process runs it, an unheld `claude' does, and its socket
              ;; is gone.
              (dolist (table `(() ((1003 1 "claude"))
                               ((1003 900 "claude")
                                (900 1 ,(claude-code-tests--master-args gone)))))
                (claude-code-tests--with-processes table
                  (should-error (claude-code-attach "/home/test/proj" id)
                                :type 'user-error)))
              (should-not execs)
              (claude-code-tests--with-processes held
                (let ((buffer (claude-code-attach "/home/test/proj" id)))
                  (pcase-let ((`(,exec-buffer ,program ,args) (car execs)))
                    (should (eq exec-buffer buffer))
                    (should (equal (cons program args)
                                   (claude-code--attaching-command
                                    claude-code-dtach socket))))
                  (with-current-buffer buffer
                    (should (equal default-directory cwd))
                    (should (eql claude-code--pid 1003))
                    (should-not ghostel-eval-cmds))
                  (should (plist-get (claude-code-tests--entry id) :detachable))
                  (let ((session (seq-find
                                  (lambda (s)
                                    (equal (claude-code-session-id s) id))
                                  (claude-code-project-sessions
                                   "/home/test/proj"))))
                    (should (claude-code-session-alive-p session))
                    (should (eq (claude-code-session-buffer session) buffer)))
                  (should (eq (claude-code-attach "/home/test/proj" id) buffer))
                  (should (= (length execs) 1))))))))
      ;; The fixtures again, on a remote host whose config dir they are.
      (let ((tramp-remote-process-environment
             (cons (concat "CLAUDE_CONFIG_DIR=" claude-code-tests--fixtures)
                   tramp-remote-process-environment))
            (claude-code--remote-config-envs (make-hash-table :test 'equal))
            (execs '()))
        (claude-code-tests--with-registry
          (claude-code-tests--attaching execs
            (claude-code-tests--on-mock-host nil
              (let ((host (file-remote-p default-directory))
                    (exists (symbol-function 'file-exists-p))
                    (checked '()))
                (claude-code-tests--with-processes held
                  ;; Asked from here, so only the code can name the host.
                  (let ((default-directory temporary-file-directory))
                    (cl-letf (((symbol-function 'file-exists-p)
                               (lambda (file)
                                 (push file checked)
                                 (funcall exists file))))
                      (should (equal (buffer-local-value
                                      'default-directory
                                      (claude-code-attach
                                       (concat host "/home/test/proj") id))
                                     (concat host cwd))))))
                ;; The mock host shares this file system: only the name asked
                ;; about shows the socket was looked for on the host.
                (should (member (concat host socket) checked))))))))))

(ert-deftest claude-code-test-local-instance-follows-its-directory-and-reports-changes ()
  "A local instance follows the directory sessions/ names and reports its changes.
A remote instance sharing its PID is neither followed nor reported."
  (claude-code-tests--with-registry
    (claude-code-tests--with-config
      (let ((wt "/r/.claude/worktrees/feat")
            (local (generate-new-buffer " *cc-local*"))
            (remote (generate-new-buffer " *cc-remote*"))
            (taken '())
            (changed nil))
        (add-hook 'claude-code--sessions-changed-hook (lambda () (setq changed t)))
        (cl-flet ((reported () (prog1 changed (setq changed nil)))
                  (followed () (prog1 taken (setq taken nil)))
                  (status (buffer id new)
                    (with-current-buffer buffer
                      (let ((old (cdr (assoc id ghostel-program-status))))
                        (setf (alist-get id ghostel-program-status nil t #'equal)
                              new)
                        (run-hook-with-args 'ghostel-program-status-functions
                                            id old new))))
                  (report-pid (buffer pid)
                    (with-current-buffer buffer
                      (funcall (cadr (assoc claude-code--pid-report
                                            ghostel-eval-cmds))
                               pid)))
                  (rewrite (status)
                    (claude-code-tests--write-session-file
                     4242 (format "{\"sessionId\":\"id\",\"status\":\"%s\",\"cwd\":\"%s\"}"
                                  status wt))
                    (claude-code--on-session-file 4242))
                  (turn-end ()
                    (claude-code-session-turn-end
                     (claude-code--instance-session local))))
          (unwind-protect
              (cl-letf (((symbol-function 'ghostel--update-directory)
                         ;; As Ghostel does, skipping the directory it last took.
                         (lambda (dir)
                           (unless (equal dir ghostel--last-directory)
                             (push (cons (current-buffer) dir) taken)
                             (setq ghostel--last-directory dir
                                   default-directory (file-name-as-directory
                                                      dir))))))
                (pcase-dolist (`(,buffer . ,dir) `((,local . "/r/")
                                                   (,remote . "/ssh:cc-test-host:/r/")))
                  (with-current-buffer buffer
                    (claude-code-instance-mode)
                    (setq-local ghostel--last-directory nil
                                ghostel-program-status nil)
                    (setq default-directory dir)))
                ;; No instance has reported PID 4242 yet.
                (rewrite "busy")
                (should (reported))
                (should-not (followed))
                ;; Nothing a remote instance does is reported for this machine.
                (claude-code--register "id" remote "/ssh:cc-test-host:/r" nil)
                (report-pid remote "4242")
                (status remote "" '(:state done))
                (should-not (reported))
                ;; Nor is anything an unregistered terminal does.
                (status local "" '(:state working))
                (should-not (reported))
                (should-not (followed))
                (claude-code--register "id" local "/r" nil)
                (should (reported))
                (report-pid local "4242")
                (should (reported))
                ;; Only a change of the root record's state follows the cwd.
                (status local "" '(:state working :msg "m"))
                (status local "a93609d08ab42add7" '(:state error))
                (should-not (followed))
                (status local "" '(:state blocked))
                (should (equal (followed) (list (cons local wt))))
                (status local "" '(:state working))
                (should-not (followed))
                (should-not (reported))
                ;; Whichever of a turn end's two signals comes last shows it.
                (let ((ended (lambda () (status local "" '(:state done))))
                      (rested (lambda () (rewrite "idle"))))
                  (dolist (order (list (list ended rested) (list rested ended)))
                    (status local "" '(:state working))
                    (rewrite "busy")
                    (reported)
                    (funcall (car order))
                    (should (reported))
                    (should-not (turn-end))
                    (funcall (cadr order))
                    (should (reported))
                    (should (eq (turn-end) 'done))))
                (status local "" '(:state done :msg "m"))
                (should (reported))
                ;; A `let' unwound over the last follow put the buffer back on
                ;; the root, while Ghostel's record still names the worktree.
                (with-current-buffer local (setq default-directory "/r/"))
                (rewrite "idle")
                (should (equal (followed) (list (cons local wt))))
                (should (reported))
                (kill-buffer local)
                (should (reported))
                ;; The remote PID names a process on its host, not the one this
                ;; machine's sessions/ file describes: off its directory, the
                ;; remote buffer is still not followed.
                (with-current-buffer remote
                  (setq default-directory "/ssh:cc-test-host:/"))
                (rewrite "idle")
                (should-not (followed))
                (should (reported))
                (kill-buffer remote)
                (should-not (reported)))
            (dolist (buffer (list local remote))
              (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(ert-deftest claude-code-test-closing-instances-retires-them-and-the-last-runs-the-hook ()
  "Closing an instance retires it, and closing the last runs the exit hook once.
The process exiting closes it whatever the user's `ghostel-kill-buffer-on-exit',
and a signalling handler costs neither the kill nor the handlers behind it."
  (claude-code-tests--with-registry
    (let* ((execs '())
           (ran 0)
           (messages '())
           (claude-code-last-instance-exit-hook
            (list (lambda () (error "Boom"))
                  (lambda () (signal 'quit nil))
                  (lambda () (cl-incf ran))))
           (ghostel-kill-buffer-on-exit nil)
           (stranger (generate-new-buffer " *cc-stranger*")))
      (unwind-protect
          (claude-code-tests--recording-launch execs
            (cl-letf (((symbol-function 'message)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) messages))))
              (pcase-let* ((`(,a-id . ,a) (claude-code-spawn "/r"))
                           (b (cdr (claude-code-spawn "/r"))))
                ;; As `ghostel--sentinel' closes a terminal whose process exited.
                (with-current-buffer a
                  (when ghostel-kill-buffer-on-exit (kill-buffer a)))
                (should-not (buffer-live-p a))
                (should-not (claude-code-tests--instance a-id))
                (should (= ran 0))
                ;; Caught so an escaping `quit' fails this test rather than
                ;; ending it as an ERT `QUIT', which leaves the run green.
                (should-not (condition-case err (progn (kill-buffer b) nil)
                              ((error quit) err)))
                (should-not (buffer-live-p b))
                (should (hash-table-empty-p claude-code--managed))
                (should (= ran 1))
                (should (seq-some (lambda (m) (string-match-p "last-instance hook" m))
                                  messages))
                ;; A buffer with no entry, a stranger or one already retired.
                (with-current-buffer stranger (claude-code--on-buffer-kill))
                (should (= ran 1)))))
        (kill-buffer stranger)))))

(ert-deftest claude-code-test-launch-environment-reaches-only-the-instance ()
  "A launch's environment reaches its instance and leaves Emacs's own alone.
It arrives from a calling buffer holding a local `process-environment', as
`envrc' makes it, or a local `ghostel-pre-spawn-hook', with or without `t'."
  (claude-code-tests--with-registry
    (let ((execs '())
          (asked nil)
          (ghostel-pre-spawn-hook (list #'ignore)))
      (claude-code-tests--recording-launch execs
        (cl-letf (((symbol-function 'claude-code--mcp-wiring)
                   (lambda (buffer)
                     (setq asked buffer)
                     (list nil (cons "CC_TEST_MCP" "sock")))))
          (dolist (setup (list #'ignore
                               (lambda ()
                                 (setq-local process-environment
                                             (copy-sequence process-environment)))
                               (lambda ()
                                 (setq-local ghostel-pre-spawn-hook (list #'always)))
                               (lambda ()
                                 (setq-local ghostel-pre-spawn-hook
                                             (list #'always t)))))
            (with-temp-buffer
              (funcall setup)
              (let ((local ghostel-pre-spawn-hook)
                    (buffer (cdr (claude-code-spawn "/r"))))
                ;; Asked about the instance's buffer, already in the directory
                ;; the instance runs in: that tells it whether it is remote.
                (should (eq asked buffer))
                (should (equal (buffer-local-value 'default-directory buffer)
                               "/r/"))
                (should (equal (let ((process-environment (nth 2 (car execs))))
                                 (getenv "CC_TEST_MCP"))
                               "sock"))
                (should-not (getenv "CC_TEST_MCP"))
                (should (equal (default-value 'ghostel-pre-spawn-hook)
                               (list #'ignore)))
                (should (equal ghostel-pre-spawn-hook local))))))))))

(ert-deftest claude-code-test-spawn-and-resume-launch-a-registered-instance ()
  "Spawn and resume launch an instance registered under its session id.
One launched from a Claude worktree starts from the worktree's parent, asking
for that worktree unless the caller asked for another."
  (let ((watch (symbol-function 'claude-code--watch-sessions)))
    (claude-code-tests--with-config
      (claude-code-tests--with-registry
        (let ((execs '())
              (wt "/r/.claude/worktrees/feat"))
          (claude-code-tests--recording-launch execs
            (let ((recorded (symbol-function 'ghostel-exec)))
              (cl-letf (((symbol-function 'ghostel-exec)
                         (lambda (buffer &rest args)
                           ;; Ghostel refuses a mode change once the terminal runs.
                           (should (eq (buffer-local-value 'major-mode buffer)
                                       'claude-code-instance-mode))
                           (apply recorded buffer args))))
                (cl-flet ((session (buffer) (claude-code--instance-session buffer))
                          (args () (nth 1 (car execs))))
                  (pcase-let ((`(,id . ,buffer) (claude-code-spawn "/r")))
                    (should (eq buffer (car (car execs))))
                    (should (string-match-p claude-code-tests--uuid-re id))
                    (should-not (equal (car (claude-code-spawn "/r")) id))
                    (should (equal (claude-code-session-id (session buffer)) id))
                    ;; A status its terminal reports is announced.
                    (claude-code-tests--terminal buffer)
                    (let* ((announced '())
                           (claude-code-notify-function
                            (lambda (session _body)
                              (push (claude-code-session-id session) announced))))
                      (claude-code-tests--report buffer 'working)
                      (claude-code-tests--report buffer 'done)
                      (should (claude-code-tests--await (lambda () announced) 2))
                      (should (equal announced (list id)))))
                  ;; A sessions/ the system refuses to watch costs the launch
                  ;; nothing: the instance runs whether or not it is watched.
                  (cl-letf (((symbol-function 'claude-code--watch-sessions) watch)
                            ((symbol-function 'file-notify-add-watch)
                             (lambda (&rest _)
                               (signal 'file-notify-error '("No space left")))))
                    (let ((claude-code--sessions-watch nil))
                      (should (session (cdr (claude-code-spawn "/r"))))))
                  (let ((buffer (claude-code-resume "/r" "given-id")))
                    (should (eq buffer (car (car execs))))
                    (should (equal (claude-code-session-id (session buffer))
                                   "given-id"))
                    (should-not (claude-code-session-worktree (session buffer))))
                  (pcase-dolist (`(,request ,flag ,worktree)
                                 '((nil "--worktree=feat" "feat")
                                   ("other" "--worktree=other" "other")
                                   (t "--worktree" nil)))
                    (let ((buffer (cdr (claude-code-spawn wt :worktree request))))
                      (should (member flag (args)))
                      (should (equal (buffer-local-value 'default-directory buffer)
                                     "/r/"))
                      (should (equal (claude-code-session-worktree (session buffer))
                                     worktree))))
                  (let ((buffer (claude-code-resume wt "wt-id")))
                    (should (member "--worktree=feat" (args)))
                    (should (equal (buffer-local-value 'default-directory buffer)
                                   "/r/"))))))))))))

(ert-deftest claude-code-test-resume-launches-only-what-nothing-runs ()
  "Resume launches a session no process runs.
One a `claude' outside Emacs runs is refused, and one an instance Emacs manages
runs returns that instance."
  (claude-code-tests--with-config
    (claude-code-tests--with-registry
      (let ((execs '())
            (id "22222222-2222-4222-8222-222222222222"))
        (claude-code-tests--write-session-file 1002 id)
        (claude-code-tests--recording-launch execs
          (cl-letf (((symbol-function 'claude-code--session-process)
                     #'buffer-live-p))
            (claude-code-tests--with-live-pids '(1002)
              (should-error (claude-code-resume "/r" id) :type 'user-error))
            (should-not execs)
            (claude-code-tests--with-live-pids '()
              (let ((buffer (claude-code-resume "/r" id)))
                (should (eq (claude-code-resume "/r" id) buffer))
                (should (= (length execs) 1))))))))))

(defmacro claude-code-tests--signalling (signals result &rest body)
  "Run BODY with `signal-process' pushing (PID SIGCODE REMOTE) onto SIGNALS.
Every call returns RESULT, 0 for a delivered signal."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'signal-process)
              (lambda (pid sigcode &optional remote)
                (push (list pid sigcode remote) ,signals)
                ,result)))
     ,@body))

(ert-deftest claude-code-test-operations-drive-only-the-instance-running-the-session ()
  "Operations reach the instance in the session's buffer, only while it runs."
  (claude-code-tests--with-managed-buffer a
    (claude-code-tests--with-managed-buffer b
      (let ((calls '())
            (session (claude-code-session--create
                      :id "s" :alive-p t :buffer a)))
        (cl-flet ((sent (operation &rest args)
                    (setq calls '())
                    (apply operation session args)
                    (reverse calls)))
          (claude-code-tests--recording-ghostel calls
            (claude-code--register "s" a "/r" nil)
            ;; Pasted, never typed, whatever its length or lines; RET follows
            ;; only a submit.
            (should (equal (sent #'claude-code-send-text "hello")
                           '((paste "hello"))))
            (dolist (text (list "hi" (make-string 100 ?x) "a\nb"))
              (should (equal (sent #'claude-code-send-text text t)
                             `((paste ,text) (key "return")))))
            (should (equal (sent #'claude-code-send-text "" t)
                           '((key "return"))))
            (let ((renamed (sent #'claude-code-rename "My Name")))
              (should (equal (last renamed) '((key "return"))))
              (should (equal (mapconcat #'cadr (butlast renamed) "")
                             "/rename My Name")))
            (claude-code-kill session)
            (should-not (buffer-live-p a))
            (should-not (claude-code-tests--instance "s"))
            (should-error (claude-code-kill
                           (claude-code-session--create :id "d"))
                          :type 'user-error)
            ;; A resume hosts the session in B: the struct naming A drives
            ;; nothing, and B goes on running it.
            (claude-code--register "s" b "/r" nil)
            (setq calls '())
            (dolist (operation
                     (list #'claude-code-kill
                           (lambda (s) (claude-code-rename s "n"))
                           (lambda (s) (claude-code-send-text s "t" t))))
              (should-error (funcall operation session) :type 'user-error))
            (should-not calls)
            (should (eq (claude-code-tests--instance "s") b))
            (should (buffer-live-p b))))))))

(ert-deftest claude-code-test-kill-and-delete-recheck-the-session-by-id ()
  "Kill and delete act on what runs the session's id now, not on the struct."
  (let ((file (make-temp-file "cc-transcript" nil ".jsonl"))
        (signals '())
        (external (claude-code-session--create
                   :id "22222222-2222-4222-8222-222222222222" :external-p t
                   :transcript "/home/test/proj/2222.jsonl")))
    (cl-flet ((dead (id) (claude-code-session--create :id id :transcript file)))
      (unwind-protect
          (claude-code-tests--with-fixtures
            (claude-code-tests--with-managed-buffer buf
              (cl-letf (((symbol-function 'claude-code--session-process)
                         #'buffer-live-p))
                (claude-code-tests--signalling signals 0
                  ;; sessions/ names pid 1002 as running 22222222.
                  (claude-code-tests--with-live-pids '(1002)
                    (claude-code-kill external)
                    (should (equal signals '((1002 SIGTERM nil))))
                    (setq signals '())
                    (should-error (claude-code-delete
                                   (dead (claude-code-session-id external)))
                                  :type 'user-error))
                  (claude-code-tests--with-live-pids '()
                    (should-error (claude-code-kill external) :type 'user-error)
                    ;; An instance Emacs manages has resumed the session since.
                    (claude-code--register "resumed" buf "/home/test/proj" nil)
                    (should-error (claude-code-kill
                                   (claude-code-session--create
                                    :id "resumed" :external-p t
                                    :transcript "/home/test/proj/r.jsonl"))
                                  :type 'user-error)
                    (should (buffer-live-p buf))
                    (should-error (claude-code-delete (dead "resumed"))
                                  :type 'user-error)
                    (should-error (claude-code-delete
                                   (claude-code-session--create
                                    :id "a" :alive-p t :transcript file))
                                  :type 'user-error)
                    (should-error (claude-code-delete
                                   (claude-code-session--create
                                    :id "e" :external-p t :transcript file))
                                  :type 'user-error)
                    (should (file-exists-p file))
                    (should-not signals)
                    (claude-code-delete (dead "gone"))
                    (should-not (file-exists-p file))
                    (should-error (claude-code-delete (dead "gone"))
                                  :type 'user-error)))
                (claude-code-tests--signalling signals -1
                  (claude-code-tests--with-live-pids '(1002)
                    (should-error (claude-code-kill external)
                                  :type 'user-error))))))
        (when (file-exists-p file) (delete-file file))))))

(ert-deftest claude-code-test-kill-signals-on-the-sessions-host ()
  "An external session is signalled on its transcript's or holder's host."
  (pcase-dolist (`(,transcript ,holder ,host)
                 '(("/ssh:box:/home/me/proj/e.jsonl" nil "/ssh:box:")
                   (nil "/ssh:box:/run/s" "/ssh:box:")
                   (nil "/run/s" nil)))
    (claude-code-tests--with-registry
      (let ((signals '())
            (asked 'none))
        (cl-letf (((symbol-function 'claude-code--running)
                   (lambda (host)
                     (setq asked host)
                     (let ((running (make-hash-table :test 'equal)))
                       (puthash "e" 31 running)
                       running))))
          (claude-code-tests--signalling signals 0
            (claude-code-kill (claude-code-session--create
                               :id "e" :external-p t
                               :transcript transcript :holder holder))))
        (should (equal asked host))
        (should (equal signals `((31 SIGTERM ,host))))))))

(defconst claude-code-tests--export-answer
  (concat "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\","
          "\"request_id\":\"claude-code\",\"response\":{\"text\":"
          "\"\\n● Because you asked.\\n  Twice.\","
          "\"default_filename\":\"conversation-2026-10-28-203102.txt\"}}}")
  "The CLI's answer to an export request, as v2.1.304 prints it.")

(defmacro claude-code-tests--with-fake-cli (vars script &rest body)
  "Run BODY with `claude-code-cli' a shell script running SCRIPT.
VARS is (SESSION ROOT LOG): SESSION a dead session whose transcript is on
disk, ROOT a fresh directory it is listed under, and LOG the file SCRIPT may
reach as \"$0.log\".  The export's config dir lies inside ROOT, and
everything is deleted afterwards.  SCRIPT ends in `exec cat', so an export it
answers lasts until its input closes."
  (declare (indent 2))
  (pcase-let ((`(,session ,root ,log) vars))
    `(let* ((,root (file-truename (make-temp-file "cc-export" t)))
            (claude-code-cli (expand-file-name "claude" ,root))
            (,log (concat claude-code-cli ".log"))
            (claude-code-export-config-dir (expand-file-name "config/" ,root))
            (,session (claude-code-session--create
                       :id "export" :transcript (expand-file-name "t.jsonl" ,root))))
       (unwind-protect
           (progn
             (write-region "" nil (claude-code-session-transcript ,session))
             (write-region (concat "#!/bin/sh\n" ,script) nil claude-code-cli)
             (set-file-modes claude-code-cli #o700)
             ,@body)
         (delete-directory ,root t)))))

(defun claude-code-tests--export-processes ()
  "Return the processes an export started that have not been cleaned up."
  (seq-filter (lambda (proc)
                (string-prefix-p "claude-code-export" (process-name proc)))
              (process-list)))

(defun claude-code-tests--export (session root)
  "Export SESSION under ROOT; return (CALLS . PROCESS) once the process ends.
CALLS lists every callback call in order, as (text TEXT) or (error MESSAGE),
so a second call shows up rather than slipping by.  Asserting here rather than
in a callback matters: a failed `should' inside a process filter aborts the
batch run."
  (let* ((calls '())
         (proc (claude-code-export-transcript
                session root
                (lambda (text) (push (list 'text text) calls))
                (lambda (msg) (push (list 'error msg) calls)))))
    (claude-code-tests--await (lambda () (not (process-live-p proc))) 5)
    (cons (reverse calls) proc)))

(defconst claude-code-tests--record-pid "echo $$ > \"$0.pid\"\n"
  "A fake CLI's line recording its PID for `claude-code-tests--cli-gone-p'.")

(defun claude-code-tests--cli-gone-p (cli)
  "Return non-nil once the fake CLI that recorded its PID beside CLI has ended."
  (let ((pid (with-temp-buffer
               (insert-file-contents (concat cli ".pid"))
               (string-to-number (buffer-string)))))
    (claude-code-tests--await
     (lambda ()
       (member (alist-get 'state (process-attributes pid)) '(nil "Z")))
     5)))

(ert-deftest claude-code-test-export-hands-over-the-transcript ()
  "An export hands over the whole answer for the transcript where it lies now."
  (claude-code-tests--with-fake-cli (session root log)
      (concat "read -r request\n"
              "{ pwd; printf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$request\" \"$@\"; }"
              " > \"$0.log\"\n"
              "echo 'not json'\n"
              "echo '{\"type\":\"control_response\",\"response\":"
              "{\"subtype\":\"success\",\"request_id\":\"other\","
              "\"response\":{\"text\":\"not ours\"}}}'\n"
              "head -c 100000 \"$0.answer\"\n"
              "echo 'Warning: mid-answer' >&2\n"
              "tail -c +100001 \"$0.answer\"\n"
              "exec cat >/dev/null\n")
    (let* ((claude-code-config-dir (expand-file-name "dot-claude/" root))
           ;; Where Claude moved the transcript the session recorded.
           (moved (expand-file-name
                   (concat (claude-code-session-id session) ".jsonl")
                   (claude-code-tests--project-dir root)))
           (text (apply #'concat (make-list 30000 "● ─── text\n")))
           ;; `json-serialize' hands back the UTF-8 bytes themselves.
           (answer (concat (json-serialize
                            `((type . "control_response")
                              (response (subtype . "success")
                                        (request_id . "claude-code")
                                        (response (text . ,text)))))
                           "\n")))
      (should (> (length answer) (* 4 read-process-output-max)))
      (let ((coding-system-for-write 'no-conversion))
        (write-region answer nil (concat claude-code-cli ".answer")))
      (make-directory (file-name-directory moved) t)
      (rename-file (claude-code-session-transcript session) moved)
      (pcase-let ((`(,calls . ,proc) (claude-code-tests--export session root)))
        (should (equal calls `((text ,text))))
        ;; It exits by itself once its input is closed.
        (should (eq (process-status proc) 'exit))
        (should-not (claude-code-tests--export-processes)))
      (pcase-let ((`(,cwd ,config ,request . ,argv)
                   (with-temp-buffer
                     (insert-file-contents log)
                     (split-string (buffer-string) "\n" t))))
        (should (equal cwd root))
        (should (equal config (expand-file-name claude-code-export-config-dir)))
        (should (equal (alist-get 'subtype
                                  (alist-get 'request
                                             (json-parse-string
                                              request :object-type 'alist)))
                       "export_conversation"))
        (should (member (concat "--resume=" moved) argv))
        (should (member "--no-session-persistence" argv))
        (should (member "--safe-mode" argv))
        (dolist (flag '("--input-format" "--output-format"))
          (should (equal (cadr (member flag argv)) "stream-json"))))
      (should-error (claude-code-export-transcript
                     (claude-code-session--create :id "new") root
                     #'ignore #'ignore)
                    :type 'user-error)
      (should-not (claude-code-tests--export-processes)))))

(ert-deftest claude-code-test-export-reports-why-there-is-no-transcript ()
  "An export the CLI cannot answer reports why, once, and leaves no process."
  (pcase-dolist (`(,script ,needles . ,options)
                 `(;; The CLI's own account: an error answer or a failed result.
                   (,(concat "read -r r\n"
                             "echo '{\"type\":\"control_response\",\"response\":"
                             "{\"subtype\":\"error\",\"request_id\":\"claude-code\","
                             "\"error\":\"Unsupported control request subtype: "
                             "export_conversation\"}}'\n"
                             "exec cat >/dev/null\n")
                    ("Unsupported control request subtype: export_conversation"))
                   (,(concat "read -r r\n"
                             "echo '{\"type\":\"result\",\"subtype\":"
                             "\"error_during_execution\",\"is_error\":true,"
                             "\"errors\":[\"No conversation found with session ID: 0f\"]}'\n"
                             "exit 1\n")
                    ("No conversation to export"))
                   ;; A success answer carrying no text.
                   (,(concat "read -r r\n"
                             "echo '{\"type\":\"control_response\",\"response\":"
                             "{\"subtype\":\"success\",\"request_id\":\"claude-code\","
                             "\"response\":{}}}'\n"
                             "exec cat >/dev/null\n")
                    ())
                   ;; No answer at all: the exit status and the whole stderr.
                   (,(concat "echo \"error: unknown option '--frobnicate'\""
                             " >&2\n"
                             "exit 1\n")
                    ("status 1" "unknown option '--frobnicate'"))
                   ;; More than a pipe holds.
                   (,(concat "read -r r\n"
                             "head -c 300000 /dev/zero | tr '\\0' x >&2\n"
                             "echo ' last words' >&2\n"
                             "exit 1\n")
                    ("status 1"
                     ,(concat (make-string 300000 ?x) " last words")))
                   (,(concat "read -r r\n" "echo one >&2\n" "echo two >&2\n"
                             "exit 2\n")
                    ("status 2" "one\ntwo")
                    :read-max 7)
                   (,(concat "read -r r\n" "exit 0\n")
                    ("status 0"))
                   (,(concat "read -r r\n" "printf partial\n" "exit 1\n")
                    ("status 1"))
                   ;; Lines answering nothing leave the exit to tell.
                   (,(concat "read -r r\n"
                             "echo '[1]'\n"
                             "echo '{\"type\":\"result\",\"subtype\":\"success\","
                             "\"is_error\":false}'\n"
                             "echo '{\"type\":\"system\",\"subtype\":\"init\"}'\n"
                             "exit 3\n")
                    ("status 3"))
                   (,(concat "read -r r\n" "kill -TERM 0\n"
                             "exec cat >/dev/null\n")
                    ("terminated"))))
    (claude-code-tests--with-fake-cli (session root _log) script
      (ert-info (script :prefix "CLI: ")
        (pcase-let ((`(,calls . ,proc)
                     (let ((read-process-output-max
                            (or (plist-get options :read-max)
                                read-process-output-max)))
                       (claude-code-tests--export session root))))
          (should (equal (mapcar #'car calls) '(error)))
          (dolist (needle needles)
            (should (string-search needle (cadr (car calls)))))
          (should-not (process-live-p proc))
          (should-not (claude-code-tests--export-processes)))))))

(ert-deftest claude-code-test-export-always-ends-its-cli ()
  "An export hears only its first outcome, and its CLI ends however it settles."
  (let ((answer (concat "echo '" claude-code-tests--export-answer "'\n")))
    (pcase-dolist (`(,script ,timeout ,cancel ,heard)
                   `(;; Never answers.
                     (,(concat "read -r r\n" claude-code-tests--record-pid
                               "exec sleep 100\n")
                      0.5 nil (error))
                     ;; Answers, then outlives its closed input.
                     (,(concat "read -r r\n" answer
                               claude-code-tests--record-pid "exec sleep 100\n")
                      0.5 nil (text))
                     ;; Cancelled before it answers.
                     (,(concat "read -r r\n" claude-code-tests--record-pid
                               "sleep 0.3\n" answer "exec sleep 100\n")
                      30 t ())))
      (claude-code-tests--with-fake-cli (session root _log) script
        (let* ((claude-code--export-timeout timeout)
               (calls '())
               (proc (claude-code-export-transcript
                      session root
                      (lambda (_) (push 'text calls))
                      (lambda (_) (push 'error calls)))))
          (when cancel
            (should (claude-code-tests--await
                     (lambda () (file-exists-p (concat claude-code-cli ".pid")))
                     5))
            (claude-code--export-cancel proc))
          (should (claude-code-tests--await
                   (lambda () (not (process-live-p proc))) 5))
          ;; Room for an outcome heard after the first.
          (claude-code-tests--await
           (lambda () (> (length calls) (length heard))) 0.3)
          (should (equal calls heard))
          (should (eq (process-status proc) 'signal))
          (should-not (claude-code-tests--export-processes))
          (should (claude-code-tests--cli-gone-p claude-code-cli)))))))

(ert-deftest claude-code-test-export-transcript-on-a-remote-host ()
  "A remote session exports on its host, over a pipe, with a config dir there."
  (dolist (direct '(nil t))
    (let ((connection-local-profile-alist
           (copy-tree connection-local-profile-alist))
          (connection-local-criteria-alist
           (copy-tree connection-local-criteria-alist)))
      (connection-local-set-profile-variables
       'claude-code-tests--direct-async
       `((tramp-direct-async-process . ,direct)))
      (connection-local-set-profiles '(:application tramp :protocol "mock")
                                     'claude-code-tests--direct-async)
      (claude-code-tests--with-fake-cli (session root log)
          (concat "read -r request\n"
                  "out=pipe; [ -t 1 ] && out=terminal\n"
                  "{ pwd; printf '%s\\n' \"$out\" \"$CLAUDE_CONFIG_DIR\" \"$@\"; }"
                  " > \"$0.log\"\n"
                  "echo '" claude-code-tests--export-answer "'\n"
                  "exec cat >/dev/null\n")
        (claude-code-tests--on-mock-host nil
          (let* ((host (file-remote-p default-directory))
                 (claude-code--remote-config-envs (make-hash-table :test 'equal))
                 (file (claude-code-session-transcript session))
                 (remote (claude-code-session--create
                          :id "export" :transcript (concat host file))))
            (puthash host (cons nil "/cc/home") claude-code--remote-config-envs)
            (pcase-let ((`(,calls . ,proc)
                         (claude-code-tests--export remote (concat host root))))
              (should (equal calls '((text "\n● Because you asked.\n  Twice."))))
              (should-not (process-live-p proc))
              ;; Only TRAMP's own shell knows the remote PID.
              (should (eq (null (process-get proc 'remote-pid)) direct))
              (pcase-let ((`(,cwd ,stdout ,config . ,argv)
                           (with-temp-buffer
                             (insert-file-contents log)
                             (split-string (buffer-string) "\n" t))))
                (should (equal cwd root))
                (should (equal stdout "pipe"))
                (should (equal config "/cc/home/.cache/claude-code-export/"))
                (should (member (concat "--resume=" file) argv))
                (should (member "--no-session-persistence" argv))))))))))
;;;; Notifications

(defmacro claude-code-tests--holding-timers (run &rest body)
  "Run BODY with every timer it starts held until RUN runs it.
RUN names a function of no arguments, bound over BODY, that runs the timers
held and not cancelled, oldest first, and returns how many it ran."
  (declare (indent 1))
  (let ((held (gensym "held")))
    `(let ((,held '()))
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (_secs _repeat fn &rest args)
                    (car (push (lambda () (apply fn args)) ,held))))
                 ((symbol-function 'cancel-timer)
                  (lambda (timer) (setq ,held (delq timer ,held)))))
         (cl-flet ((,run ()
                     (let ((due (reverse ,held)))
                       (setq ,held '())
                       (mapc #'funcall due)
                       (length due))))
           ,@body)))))

(defun claude-code-tests--report (buffer state &rest props)
  "Report root STATE with PROPS to BUFFER's terminal, as Ghostel does.
The root record becomes the report, a nil STATE removing it, and
`ghostel-program-status-functions' runs in BUFFER on the record replaced and
the new one."
  (with-current-buffer buffer
    (let ((old (cdr (assoc "" ghostel-program-status)))
          (new (and state `(:state ,state ,@props))))
      (setq ghostel-program-status (and new (list (cons "" new))))
      (run-hook-with-args 'ghostel-program-status-functions "" old new))))

(defmacro claude-code-tests--with-instance (spec &rest body)
  "Run BODY with a managed instance whose terminal runs and reports its status.
SPEC is (VAR PID SESSION ORIGIN): VAR is bound to the buffer, which carries
PID and is registered on SESSION, launched from ORIGIN.  Its terminal is a pipe
process, deleted afterwards, and the focus watch it installs is unwound."
  (declare (indent 1))
  (pcase-let ((`(,var ,pid ,session ,origin) spec)
              (process (gensym "process")))
    `(claude-code-tests--with-managed-buffer (,var ,pid)
       (let ((,process (make-pipe-process :name "cc-terminal" :buffer nil
                                          :noquery t))
             (after-focus-change-function #'ignore))
         (unwind-protect
             (progn
               (with-current-buffer ,var (setq-local ghostel--process ,process))
               (claude-code--register ,session ,var ,origin nil)
               (claude-code--install-notifications ,var)
               ,@body)
           (delete-process ,process))))))

(ert-deftest claude-code-test-status-reports-announce-what-still-holds ()
  "A root state is announced once it has held through the settle, if unseen."
  (claude-code-tests--with-config
    (claude-code-tests--with-instance (buf 4242 "id" "/r")
      (let* ((announced 0)
             (claude-code-notify-function (lambda (&rest _) (cl-incf announced)))
             (focus nil)
             (visible t)
             (elsewhere (window-buffer)))
        (claude-code-tests--write-session-file 4242 "id")
        (cl-letf (((symbol-function 'frame-focus-state)
                   (lambda (&rest _) focus))
                  ((symbol-function 'frame-visible-p)
                   (lambda (&rest _) visible)))
          (claude-code-tests--holding-timers settle
            (cl-flet ((announces (&rest reports)
                        (setq announced 0)
                        (dolist (report reports)
                          (apply #'claude-code-tests--report buf report))
                        ;; Nothing is announced before the state has held.
                        (should (= announced 0))
                        (settle)
                        announced))
              ;; A subagent's records speak for no session.
              (with-current-buffer buf
                (run-hook-with-args 'ghostel-program-status-functions
                                    "a93609d08ab42add7" nil '(:state blocked))
                (run-hook-with-args 'ghostel-program-status-functions
                                    "a93609d08ab42add7"
                                    '(:state blocked) '(:state done)))
              (should (= (settle) 0))
              (pcase-dolist (`(,count . ,reports)
                             '(;; A report repeating the state asks nothing new.
                               (1 (blocked :kind permission)
                                  (blocked :kind permission :msg "m"))
                               (1 (working) (error :msg "m"))
                               (1 (working) (done))
                               ;; A prompt resolved, or a done acknowledged,
                               ;; during the wait asks for nothing any more.
                               (0 (blocked :kind permission) (working))
                               (0 (done) (nil))
                               ;; Left and entered again, it is announced once.
                               (1 (working) (done) (working) (done))))
                (ert-info ((format "Reports: %S" reports))
                  (should (= (apply #'announces reports) count))))
              ;; A done while a background shell command runs ends no turn;
              ;; the turn its completion starts does.
              (claude-code-tests--write-session-file
               4242 "{\"sessionId\":\"id\",\"status\":\"shell\"}")
              (should (= (announces '(working) '(done)) 0))
              (claude-code-tests--write-session-file 4242 "id")
              (should (= (announces '(working) '(done)) 1))
              ;; An instance shown on a focused frame needs no announcement;
              ;; a focus state that is unknown, or none, is no focus, and
              ;; neither is the one a minimized frame was left with.
              (save-window-excursion
                (pcase-dolist (`(,shown ,state ,count ,frame)
                               `((,buf t 0 t) (,buf unknown 1 t) (,buf nil 1 t)
                                 (,buf t 1 icon) (,elsewhere t 1 t)))
                  (set-window-buffer (selected-window) shown)
                  (setq focus state
                        visible frame)
                  (ert-info ((format "%s shown, focus %s, frame visible %s"
                                     shown state frame))
                    (should (= (announces '(working) '(done)) count)))))
              ;; An instance that exits during the wait.
              (claude-code-tests--report buf 'working)
              (claude-code-tests--report buf 'done)
              (delete-process (buffer-local-value 'ghostel--process buf))
              (setq announced 0)
              (should (= (settle) 1))
              (should (= announced 0)))))))))

(ert-deftest claude-code-test-notifications-close-once-stale ()
  "A notification closes once its instance leaves the state, is seen, or dies."
  (claude-code-tests--with-managed-buffer buf
    (claude-code-tests--with-managed-buffer (other 4243)
      (let ((after-focus-change-function #'ignore)
            (claude-code--seen-timer nil)
            (posts '()) (closed '()) (inside nil) (failing nil) (focus nil))
        (dolist (buffer (list buf other))
          (claude-code--register "id" buffer "/r" nil)
          (claude-code--install-notifications buffer))
        (cl-letf (((symbol-function 'notifications-notify)
                   (lambda (&rest params)
                     (when inside (funcall (prog1 inside (setq inside nil))))
                     (push (cons (1+ (length posts)) params) posts)
                     (caar posts)))
                  ((symbol-function 'dbus-call-method-asynchronously)
                   (lambda (&rest args)
                     (push (car (last args)) closed)
                     (when failing (error "No connection to bus"))))
                  ((symbol-function 'frame-focus-state)
                   (lambda (&rest _) focus)))
          (cl-flet ((post (buffer &optional during)
                      "Post for BUFFER's instance, running DURING mid-post."
                      (setq inside during)
                      (claude-code-notify-desktop
                       (claude-code-session--create :id "id" :buffer buffer)
                       "body")
                      (caar posts))
                    (expire (id)
                      (funcall (plist-get (alist-get id posts) :on-close)
                               id 'expired))
                    (show (buffer)
                      (set-window-buffer (selected-window) buffer)
                      (setq focus t)
                      (funcall after-focus-change-function)))
            ;; Unloaded, `notifications' leaves its D-Bus names to be bound.
            (dlet ((notifications-service nil)
                   (notifications-path nil)
                   (notifications-interface nil)
                   (notifications-close-notification-method nil))
              (claude-code-tests--without-requiring '(notifications)
                (claude-code-tests--holding-timers run-timers
                  (save-window-excursion
                    (let ((theirs (post other)))
                      ;; The root leaving the state announced closes what is
                      ;; still up for it; a new message for it closes nothing.
                      (claude-code-tests--report buf 'done)
                      (let ((one (post buf)) (two (post buf)) (three (post buf)))
                        (expire two)
                        (claude-code-tests--report buf 'done :msg "m")
                        (should (null closed))
                        (claude-code-tests--report buf 'working)
                        (should (equal (sort closed) (list one three))))
                      ;; Coming into sight -- a window taking the instance, or
                      ;; its frame taking focus -- closes them from one run
                      ;; for a burst of changes, sparing an instance out of
                      ;; sight.
                      (claude-code-tests--report buf 'done)
                      (run-timers)
                      (setq focus t closed '())
                      (let ((up (post buf)))
                        (set-window-buffer (selected-window) buf)
                        ;; As redisplay runs it for a window that took BUF.
                        (with-current-buffer buf
                          (run-hook-with-args 'window-buffer-change-functions
                                              (selected-window)))
                        (should (null closed))
                        (should (= (run-timers) 1))
                        (should (equal closed (list up))))
                      (setq focus nil closed '())
                      (let ((up (post buf)))
                        (show buf)
                        (funcall after-focus-change-function)
                        (should (null closed))
                        (should (= (run-timers) 1))
                        (should (equal closed (list up))))
                      ;; Either happening while a post waits on D-Bus closes
                      ;; the notification once it is up.
                      (setq focus nil closed '())
                      (let ((up (post buf (lambda ()
                                            (claude-code-tests--report
                                             buf 'working)))))
                        (should (equal closed (list up))))
                      (setq focus nil closed '())
                      (let ((up (post buf (lambda () (show buf) (run-timers)))))
                        (should (equal closed (list up))))
                      ;; Another instance coming into sight leaves it up, for
                      ;; the kill of its own to close -- even when closing
                      ;; fails, which must not keep the buffer alive.
                      (setq focus nil closed '())
                      (let ((up (post buf (lambda () (show other) (run-timers)))))
                        (should (equal closed (list theirs)))
                        (expire (post buf))
                        (setq closed '() failing t)
                        ;; ERT debugs every error; a session left to run would not.
                        (let ((debug-on-error nil))
                          (kill-buffer buf))
                        (setq failing nil)
                        (should-not (buffer-live-p buf))
                        (should (equal closed (list up))))
                      ;; A kill while a post waits closes it once up.
                      (setq closed '())
                      (let ((up (post other (lambda () (kill-buffer other)))))
                        (should (equal closed (list up)))))))))))))))

(ert-deftest claude-code-test-announcement-carries-the-session-the-instance-runs ()
  "An announcement hands over the session its instance runs when it is made."
  (claude-code-tests--with-fixtures
    ;; (PID LAUNCHED-ON ORIGIN RUNS STATUS TITLE): the instance with PID,
    ;; launched on session LAUNCHED-ON from ORIGIN, finishes a turn of session
    ;; RUNS, nil when that is not announced.  A nil STATUS is not checked.
    (pcase-dolist (`(,pid ,launched ,origin ,runs ,status ,title)
                   '(;; sessions/1001.json names the session it runs now.
                     (1001 "launched" "/home/test/proj"
                           "11111111-1111-4111-8111-111111111111" "busy"
                           "Understand the project layout")
                     ;; The transcript is filed under a sibling worktree, which
                     ;; only the parent project lists.
                     (4242 "55555555-5555-4555-8555-555555555555"
                           "/home/test/proj/.claude/worktrees/feat"
                           "55555555-5555-4555-8555-555555555555" nil
                           "Dotted worktree")
                     ;; sessions/1006.json reads `shell': its own background
                     ;; command keeps the turn going.
                     (1006 "launched" "/home/test/proj" nil nil nil)))
      (claude-code-tests--with-instance (buf pid launched origin)
        (let* ((announced '())
               (claude-code-notify-function
                (lambda (session _body) (push session announced))))
          (claude-code-tests--holding-timers settle
            (claude-code-tests--report buf 'working)
            (claude-code-tests--report buf 'done)
            (settle))
          (ert-info ((format "Instance %d" pid))
            (if (not runs)
                (should (null announced))
              (should (= (length announced) 1))
              (let ((session (car announced)))
                (should (equal (claude-code-session-id session) runs))
                (should (claude-code-session-alive-p session))
                (should (eq (claude-code-session-buffer session) buf))
                (when status
                  (should (equal (claude-code-session-status session) status)))
                (should (equal (claude-code-session-title session) title))))))))))

;;;; View

(ert-deftest claude-code-test-current-project-resolution ()
  "Each kind of buffer names the project and worktree its commands act on.
A directory `project-switch-project' picked outranks them all, and a worktree
Claude built resolves to its parent, naming the worktree."
  (let ((proj (claude-code--normalize-root "/home/test/proj"))
        (other (claude-code--normalize-root "/home/test/other"))
        (asked nil))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&optional _prompt dir)
                 (setq asked t)
                 (or dir project-current-directory-override default-directory)))
              ((symbol-function 'project-root) #'identity))
      (with-temp-buffer
        (setq default-directory "/home/test/proj/")
        (should (equal (claude-code--current-project) (list proj)))
        (setq default-directory "/home/test/proj/.claude/worktrees/my.feat/")
        (should (equal (claude-code--current-project) (cons proj "my.feat"))))
      ;; A view is taken at its word, worktree or not.
      (claude-code-tests--in-view
        (setq claude-code--project "/home/test/proj/.claude/worktrees/feat"
              asked nil)
        (should (equal (claude-code--current-project)
                       '("/home/test/proj/.claude/worktrees/feat")))
        (should-not asked)
        (let ((project-current-directory-override "/home/test/other/"))
          (should (equal (claude-code--current-project) (list other)))))
      ;; An instance acts on the project it was launched from, naming the
      ;; worktree of that project it works in now and no other checkout.
      (claude-code-tests--with-managed-buffer buf
        (with-current-buffer buf
          (pcase-dolist (`(,origin ,here ,project)
                         '(("/home/test/proj" "/home/test/proj/"
                            ("/home/test/proj"))
                           ("/home/test/proj" "/home/test/proj/.claude/worktrees/feat/"
                            ("/home/test/proj" . "feat"))
                           ;; Launched from a worktree, Claude built a sibling.
                           ("/home/test/proj/.claude/worktrees/feat"
                            "/home/test/proj/.claude/worktrees/fix/"
                            ("/home/test/proj" . "fix"))
                           ("/home/test/proj" "/home/test/checkouts/feat/"
                            ("/home/test/proj"))
                           ("/home/test/proj" "/home/test/other/.claude/worktrees/feat/"
                            ("/home/test/proj"))))
            (claude-code--register "id" buf origin nil)
            (setq default-directory here
                  asked nil)
            (should (equal (claude-code--current-project) project))
            (should-not asked))
          (let ((project-current-directory-override
                 "/home/test/other/.claude/worktrees/feat/"))
            (should (equal (claude-code--current-project) (cons other "feat")))))))))

(ert-deftest claude-code-test-spawn-menu-spawns-what-it-was-set-to ()
  "The spawn menu spawns in its own scope, with the options set in it."
  (let ((spawned nil))
    (claude-code-tests--with-config
      (claude-code-tests--with-registry
        (claude-code-tests--in-view
          (cl-letf (((symbol-function 'claude-code-spawn)
                     (lambda (&rest args)
                       (setq spawned args)
                       (cons "id" (current-buffer))))
                    ((symbol-function 'transient-scope)
                     (lambda (&rest _) "/scoped"))
                    ((symbol-function 'transient-args)
                     (lambda (_)
                       '("--worktree" "--model=opus" "--effort=xhigh"
                         "--name=n"))))
            (setq claude-code--project "/r")
            (let ((transient-current-command 'claude-code-spawn-menu))
              (save-window-excursion
                (call-interactively #'claude-code--spawn-session)))))))
    (should (equal (car spawned) "/scoped"))
    (pcase-dolist (`(,key ,value) '((:worktree t) (:model "opus")
                                    (:effort "xhigh") (:name "n")))
      (should (equal (plist-get (cdr spawned) key) value)))))

(ert-deftest claude-code-test-batch-commands-settle-their-marks ()
  "Batch commands act only on marks their operation accepts, and consume them.
A declined confirmation acts on nothing.  A refusal leaves its mark armed
without ending the batch; a real fault ends it.  A mark follows an instance
onto its next session and never outlives its row."
  (let* ((instance (generate-new-buffer " *cc-instance*"))
         (view (generate-new-buffer " *cc-view*"))
         ;; A worktree's sessions belong to two roots, so a view of the
         ;; worktree lists the same rows.
         (sibling (generate-new-buffer " *cc-view-sibling*"))
         (row (lambda (id &rest slots)
                (apply #'claude-code-session--create :id id slots)))
         (sessions (list (funcall row "a" :alive-p t)
                         (funcall row "b" :external-p t)
                         (funcall row "c" :external-p t)
                         (funcall row "i1" :alive-p t :buffer instance)
                         (funcall row "d") (funcall row "e") (funcall row "f")))
         (acted '()) (detached '()) (confirm t)
         (refuse nil) (fault nil) (reported nil)
         (operation (lambda (session)
                      (let ((id (claude-code-session-id session)))
                        (cond ((equal id refuse)
                               (user-error "Session %s refused" id))
                              ((equal id fault)
                               (signal 'file-error (list "Permission denied" id))))
                        (push id acted))))
         (ids (lambda (&rest liveness)
                (sort (mapcar #'claude-code-session-id
                              (apply #'claude-code--target-sessions liveness)))))
         (mark (lambda (&rest rows)
                 (dolist (id rows)
                   (should (claude-code--goto-line-where
                            (lambda () (equal id (claude-code--line-session)))))
                   (claude-code-sessions-mark)))))
    (unwind-protect
        (claude-code-tests--with-registry
          (cl-letf* ((real (symbol-function 'claude-code-project-sessions))
                     ;; A view of the Emacs running the suite reads its own.
                     ((symbol-function 'claude-code-project-sessions)
                      (lambda (root)
                        (if (string-prefix-p "/home/test/" root)
                            sessions
                          (funcall real root))))
                     ((symbol-function 'claude-code-kill) operation)
                     ((symbol-function 'claude-code-delete) operation)
                     ((symbol-function 'claude-code-detach)
                      (lambda (session)
                        (push (claude-code-session-id session) detached)))
                     ((symbol-function 'yes-or-no-p) (lambda (_) confirm))
                     ((symbol-function 'message)
                      (lambda (fmt &rest args)
                        (when fmt (setq reported (apply #'format fmt args))))))
            (pcase-dolist (`(,buffer . ,root)
                           `((,sibling . "/home/test/proj/.claude/worktrees/feat")
                             (,view . "/home/test/proj")))
              (with-current-buffer buffer
                (claude-code-sessions-mode)
                (setq claude-code--project root
                      claude-code--collapsed nil)
                (claude-code-sessions-refresh)
                (funcall mark "a" "b" "c" "i1" "d" "e" "f")))
            (with-current-buffer view
              (should (equal (funcall ids 'alive 'external) '("a" "b" "c" "i1")))
              (should (equal (funcall ids 'dead) '("d" "e" "f")))
              ;; `/clear' moves the instance onto i2: its mark follows it, and
              ;; the session it left is an unmarked dead row.
              (setq sessions
                    (append (list (funcall row "i2" :alive-p t :buffer instance)
                                  (funcall row "i1"))
                            (seq-remove (lambda (s)
                                          (equal (claude-code-session-id s) "i1"))
                                        sessions)))
              (claude-code-sessions-refresh)
              (should (equal (funcall ids 'alive) '("a" "i2")))
              (should (equal (funcall ids 'dead) '("d" "e" "f")))
              (setq confirm nil)
              (claude-code-sessions-kill)
              (claude-code-sessions-delete)
              (should-not acted)
              (should (equal (funcall ids) '("a" "b" "c" "d" "e" "f" "i2")))
              (setq confirm t
                    refuse "b")
              (claude-code-sessions-kill)
              (should (equal (sort acted) '("a" "c" "i2")))
              (should (string-match-p "Session b refused" reported))
              (should (equal (funcall ids) '("b" "d" "e" "f")))
              (with-current-buffer sibling
                (should (equal (funcall ids) '("b" "d" "e" "f"))))
              (setq acted '()
                    refuse "e")
              (claude-code-sessions-delete)
              (should (equal (sort acted) '("d" "f")))
              (should (string-match-p "Session e refused" reported))
              (should (equal (funcall ids) '("b" "e")))
              (with-current-buffer sibling
                (should (equal (funcall ids) '("b" "e"))))
              ;; A read that misses a marked row drops its mark for good.
              (let ((all sessions))
                (setq sessions (seq-remove (lambda (s)
                                             (equal (claude-code-session-id s) "e"))
                                           all))
                (claude-code-sessions-refresh)
                (setq sessions all)
                (claude-code-sessions-refresh))
              (should (equal (funcall ids) '("b")))
              ;; A real fault escapes the batch, yet what it acted on is unmarked.
              (setq acted '()
                    refuse nil
                    fault "e")
              (funcall mark "d" "e" "f")
              (should-error (claude-code-sessions-delete) :type 'file-error)
              (should (= (length acted) 1))
              (should (equal (funcall ids 'dead)
                             (remove (car acted) '("d" "e" "f"))))
              ;; Detaching kills nothing.
              (setq acted '())
              (funcall mark "a")
              (claude-code-sessions-detach)
              (should (equal detached '("a")))
              (should-not acted))))
      (mapc #'kill-buffer (list view sibling instance)))))

;;;; Integration (real Ghostel + real `claude')
;;
;; These exercise the live spawn/kill lifecycle against an actual `claude'
;; process, so they need Ghostel's native module, network access, and a
;; logged-in CLI.  `make test' and CI never run them: they skip unless
;; CLAUDE_CODE_INTEGRATION is set (use `make integration').
;;
;; BEFORE DEBUGGING SPAWNING, read the nesting-env-var gotcha in CLAUDE.md — it
;; is why `claude-code-tests--with-top-level-env' exists.

(defconst claude-code-tests--nesting-env-vars
  '("CLAUDECODE" "CLAUDE_CODE_CHILD_SESSION" "CLAUDE_CODE_ENTRYPOINT"
    "CLAUDE_CODE_SSE_PORT" "CLAUDE_CODE_SSE_URL" "CLAUDE_CODE_SESSION_ID")
  "Runtime variables a parent `claude' sets to mark nested children.")

(defmacro claude-code-tests--with-top-level-env (&rest body)
  "Run BODY with the Claude nesting markers removed from the environment.
This lets a spawned `claude' start a real top-level session even when the
tests themselves run inside a Claude Code session."
  (declare (indent 0))
  `(let ((process-environment
          (seq-remove
           (lambda (entry)
             (seq-some (lambda (var) (string-prefix-p (concat var "=") entry))
                       claude-code-tests--nesting-env-vars))
           process-environment)))
     ,@body))

(defun claude-code-tests--project-dir (cwd)
  "Return the transcript directory under `claude-code-config-dir' for CWD."
  (expand-file-name (claude-code--encode-cwd cwd) (claude-code--projects-dir)))

(defmacro claude-code-tests--with-registered-pty (buffer fired &rest body)
  "Run BODY with BUFFER a registered instance on a real pty, FIRED its exit count.
FIRED counts `claude-code-last-instance-exit-hook' runs.  `cat' just holds the
pty open; no `claude' is involved.  The registry and the hook are private to
the run."
  (declare (indent 2))
  `(claude-code-tests--with-registry
     (let* ((,fired 0)
            (claude-code-last-instance-exit-hook
             (list (lambda () (cl-incf ,fired))))
            (,buffer (generate-new-buffer " *cc-integration-pty*")))
       (unwind-protect
           (progn (ghostel-exec ,buffer "cat" nil)
                  (claude-code--register "pty-id" ,buffer "/tmp" nil)
                  ,@body)
         (when (buffer-live-p ,buffer)
           (let ((kill-buffer-query-functions nil)) (kill-buffer ,buffer)))))))

(ert-deftest claude-code-test-integration-instance-exit ()
  "A real terminal's instance retires once, whether buffer or process ends first.
A process exit kills the buffer without asking, whatever the user set for
Ghostel terminals: keeping a dead one would leave its instance registered."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let ((ghostel-kill-buffer-on-exit nil)
        (ghostel-query-before-killing t))
    (dolist (ends-first '(buffer process))
      (claude-code-tests--with-registered-pty buffer fired
        (let ((asked nil))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) (setq asked t)))
                    ((symbol-function 'y-or-n-p)
                     (lambda (&rest _) (setq asked t))))
            (should (claude-code--session-process buffer))
            (pcase-exhaustive ends-first
              ;; The user closes the buffer, confirming if asked.
              ('buffer (kill-buffer buffer))
              ('process
               (signal-process (buffer-local-value 'ghostel--pid buffer) 'SIGTERM)
               (should (claude-code-tests--await
                        (lambda () (not (buffer-live-p buffer))) 5))
               (should-not asked)))
            ;; Give a second report the chance to arrive that it must not take.
            (claude-code-tests--await (lambda () (> fired 1)) 0.5)
            (should (= fired 1))))))))

(ert-deftest claude-code-test-integration-detach-and-attach ()
  "A detachable instance outlives its buffer, is attached again, then killed.
Real dtach and Ghostel hold a stand-in `claude' that files a sessions/ entry
and a transcript as the CLI would, then sleeps under its PID."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (skip-unless (executable-find "dtach"))
  (require 'ghostel)
  (ert-with-temp-directory dir
    (let* ((root (directory-file-name (file-truename dir)))
           (cli (expand-file-name "claude" dir))
           (claude-code-cli cli)
           (claude-code-config-dir (expand-file-name "config" dir))
           (process-environment
            (append (list (concat "XDG_RUNTIME_DIR=" root)
                          (concat "CC_ENC=" (claude-code--encode-cwd root)))
                    process-environment))
           (after-focus-change-function after-focus-change-function)
           (session (lambda (id)
                      (claude-code-tests--find-session
                       (claude-code-project-sessions root) id)))
           pid)
      (write-region
       (concat "#!/bin/sh\n"
               "while [ $# -gt 0 ]; do [ \"$1\" = --session-id ] && id=$2; shift; done\n"
               "c=$CLAUDE_CONFIG_DIR\n"
               "mkdir -p \"$c/sessions\" \"$c/projects/$CC_ENC\"\n"
               "printf '{\"type\":\"user\",\"entrypoint\":\"cli\",\"timestamp\":"
               "\"2026-11-08T00:00:00.000Z\"}\\n' > \"$c/projects/$CC_ENC/$id.jsonl\"\n"
               "printf '{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\","
               "\"status\":\"idle\"}' $$ \"$id\" \"$PWD\" > \"$c/sessions/$$.json\"\n"
               "exec sleep 600\n")
       nil cli)
      (set-file-modes cli #o700)
      (claude-code-tests--with-registry
        (unwind-protect
            (pcase-let ((`(,id . ,buffer)
                         (claude-code-spawn root :detachable t)))
              (should (claude-code-tests--await
                       (lambda ()
                         (when-let* ((reported (buffer-local-value
                                                'claude-code--pid buffer)))
                           (claude-code--pid-info reported)))
                       10))
              (setq pid (buffer-local-value 'claude-code--pid buffer))
              (should (claude-code-session-alive-p (funcall session id)))
              ;; Closing the buffer detaches: the instance runs on, external
              ;; and attachable.
              (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))
              ;; Give it the chance to die that it must not take.
              (claude-code-tests--await (lambda () (not (process-attributes pid))) 1)
              (should (process-attributes pid))
              (let ((external (funcall session id)))
                (should (claude-code-session-external-p external))
                (should (claude-code-session-holder external)))
              ;; Attaching makes it alive again, in a buffer of its own.
              (let ((attached (claude-code-attach root id)))
                (should (claude-code-tests--await
                         (lambda () (claude-code--session-process attached)) 5))
                ;; dtach's client stays only once it has connected, so give it
                ;; the chance to fail that it must not take.
                (claude-code-tests--await
                 (lambda () (not (claude-code--session-process attached))) 1)
                (should (claude-code--session-process attached))
                (should (eql (buffer-local-value 'claude-code--pid attached) pid))
                (let ((alive (funcall session id)))
                  (should (claude-code-session-alive-p alive))
                  (should (eq (claude-code-session-buffer alive) attached))
                  ;; Killing it ends the instance, and its buffer with it.
                  (claude-code-kill alive))
                (should (claude-code-tests--await
                         (lambda () (not (buffer-live-p attached))) 10))
                (should-not (process-attributes pid))))
          ;; dtach's master and clients name the socket under ROOT, and the
          ;; master's end takes the instance with it.
          (dolist (process (list-system-processes))
            (when (string-search root (or (alist-get 'args
                                                     (process-attributes process))
                                          ""))
              (signal-process process 'SIGKILL))))))))

(ert-deftest claude-code-test-integration-export-transcript ()
  "A real CLI exports a transcript's whole conversation, in order.
The fixture chains its messages by uuid, as Claude writes them; the CLI
follows that chain, so without it only the last message would export.  The
`Write' call is one the CLI leaves out unless the tool is loaded.  The
transcript is left as it was, and the export's config dir holds no sessions/
entry once it has ended."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (let* ((id "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
         (root (file-truename (make-temp-file "cc-export" t)))
         (claude-code-export-config-dir (expand-file-name "config/" root))
         (file (expand-file-name (concat "export/" id ".jsonl")
                                 claude-code-tests--fixtures))
         (before (with-temp-buffer
                   (insert-file-contents-literally file)
                   (buffer-string)))
         (session (claude-code-session--create :id id :transcript file)))
    (unwind-protect
        (claude-code-tests--with-top-level-env
          (pcase-let ((`(,calls . ,proc) (claude-code-tests--export session root)))
            (should (eq (process-status proc) 'exit))
            (should (= (length calls) 1))
            (should (eq (car (car calls)) 'text))
            (let ((text (cadr (car calls))) (pos 0))
              (dolist (part '("say ok" "Write(/home/test/proj/notes.txt)" "ok"
                              "now tell me why" "Because you asked."))
                (setq pos (string-search part text pos))
                (should pos)
                (cl-incf pos (length part))))
            (should (equal (with-temp-buffer
                             (insert-file-contents-literally file)
                             (buffer-string))
                           before))
            (should-not (directory-files
                         (expand-file-name "sessions" claude-code-export-config-dir)
                         nil "\\.json\\'"))))
      (delete-directory root t))))

(ert-deftest claude-code-test-integration-clear ()
  "A real `/clear' moves an instance onto a new session, and the model follows.
The new session is alive in the same buffer and the one it left is dead, so it
can be deleted.  No prompt is sent, so no model turn runs.  A session never
prompted has no transcript, and a `/clear' writes its own lines under the
session it starts, so the session left behind with a transcript is the one the
first of two `/clear's started."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         (ids '())
         buffer pid)
    (cl-labels ((row-of (id)
                  (claude-code-tests--find-session
                   (claude-code-project-sessions root) id))
                (running ()
                  ;; The row of the session the instance runs now.
                  (seq-find (lambda (s) (eq (claude-code-session-buffer s) buffer))
                            (claude-code-project-sessions root)))
                (clear ()
                  (claude-code-send-text (running) "/clear" t)
                  (let ((now (claude-code-tests--await
                              (lambda ()
                                (when-let* ((s (running))
                                            (now (claude-code-session-id s)))
                                  (and (not (member now ids)) now)))
                              30)))
                    (should now)
                    (push now ids))))
      (unwind-protect
          (claude-code-tests--with-top-level-env
            (let ((instance (claude-code-spawn root)))
              (push (car instance) ids)
              (setq buffer (cdr instance)))
            (should (claude-code-tests--await
                     (lambda () (setq pid (claude-code--instance-pid buffer)))
                     10))
            ;; Ready for input once it reads idle.
            (should (claude-code-tests--await
                     (lambda ()
                       (when-let* ((s (running)))
                         (equal (claude-code-session-status s) "idle")))
                     45))
            (clear)
            ;; Claude writes the transcript shortly after the switch.
            (should (claude-code-tests--await
                     (lambda ()
                       (when-let* ((s (row-of (car ids))))
                         (claude-code-session-transcript s)))
                     15))
            (clear)
            (pcase-let ((`(,current ,left ,launched) ids))
              (let ((row (row-of current))
                    (gone (row-of left))
                    (first (row-of launched)))
                (should (claude-code-session-alive-p row))
                (should (eq (claude-code-session-buffer row) buffer))
                (should-not (claude-code-session-alive-p gone))
                (should-not (claude-code-session-external-p gone))
                (should-not (and first (claude-code-session-alive-p first)))
                (claude-code-delete gone)
                (should-not (file-exists-p
                             (claude-code-session-transcript gone))))))
        (when (buffer-live-p buffer)
          (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
        (when (and pid (process-attributes pid))
          (ignore-errors (signal-process pid 'SIGKILL)))
        (dolist (id ids)
          (let ((base (expand-file-name
                       id (claude-code-tests--project-dir default-directory))))
            (when (file-exists-p (concat base ".jsonl"))
              (delete-file (concat base ".jsonl")))
            (when (file-directory-p base)
              (delete-directory base t))))))))

(provide 'claude-code-tests)
;;; claude-code-tests.el ends here
