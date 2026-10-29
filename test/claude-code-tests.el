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
(defvar vc-deduce-backend-nonvc-modes)

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
Instances a test registers are therefore invisible to every other test."
  (declare (indent 0))
  `(let ((claude-code--managed (make-hash-table)))
     ,@body))

(defmacro claude-code-tests--with-managed-buffer (spec &rest body)
  "Run BODY with a fresh buffer bound and an empty managed registry.
SPEC is VAR or (VAR PID): the buffer is bound to VAR and carries
`ghostel--pid' PID, 4242 by default, with no live process and no program
status record, as a Ghostel terminal would.  It is killed afterwards even when
BODY already killed it."
  (declare (indent 1))
  (pcase-let ((`(,var ,pid) (if (consp spec) spec (list spec 4242))))
    `(claude-code-tests--with-registry
       (let ((,var (generate-new-buffer " *cc-test*")))
         (with-current-buffer ,var
           (setq-local ghostel--pid ,pid
                       ghostel--process nil
                       ghostel-program-status nil))
         (unwind-protect (progn ,@body)
           (when (buffer-live-p ,var) (kill-buffer ,var)))))))

(defun claude-code-tests--entry (id)
  "Return the registry entry of the instance running session ID, or nil."
  (seq-find (lambda (entry) (equal (plist-get entry :session) id))
            (hash-table-values claude-code--managed)))

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

(defun claude-code-tests--listening-p (port)
  "Return non-nil when something accepts a loopback connection on PORT.
Asked of the OS rather than of Emacs, so a listener the package forgot about
still counts."
  (when-let* ((proc (ignore-errors
                      (make-network-process :name "cc-port-probe"
                                            :host "127.0.0.1" :service port))))
    (delete-process proc)
    t))

(defmacro claude-code-tests--with-live-pids (pids &rest body)
  "Run BODY with exactly the pids in PIDS reading as live processes.
Pinning the process table keeps a fixture pid that happens to be live on the
host from classifying its session as external, or from lending it a real
subtree.  Every pinned pid parents to 0 and has no children, so no pid is its
own ancestor and a subtree walk always terminates."
  (declare (indent 1))
  (let ((live (gensym "live")))
    `(let ((,live ,pids))
       (cl-letf (((symbol-function 'list-system-processes) (lambda () ,live))
                 ((symbol-function 'claude-code--child-pids) #'ignore)
                 ((symbol-function 'process-attributes)
                  (lambda (p) (and (memql p ,live) '((ppid . 0))))))
         ,@body))))

(defmacro claude-code-tests--in-view (&rest body)
  "Run BODY in a temp buffer with the sessions view enabled."
  (declare (indent 0))
  `(with-temp-buffer
     (claude-code-sessions-mode)
     ,@body))

(defmacro claude-code-tests--in-fixture-view (pids &rest body)
  "Run BODY in a printed sessions view over the fixtures, PIDS reading as live.
The empty registry means Emacs manages none of them, so a pinned pid makes its
session external and every other fixture session dead."
  (declare (indent 1))
  `(claude-code-tests--with-fixtures
     (let ((buf (generate-new-buffer " *cc-view-test*")))
       (unwind-protect
           (with-current-buffer buf
             (claude-code-tests--with-registry
               (claude-code-tests--with-live-pids ,pids
                 (claude-code-sessions-mode)
                 (setq claude-code--project "/home/test/proj")
                 (claude-code-sessions-refresh)
                 ,@body)))
         (kill-buffer buf)))))

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

(defun claude-code-tests--goto-session (id)
  "Move point to the row of session ID in the view."
  (claude-code--goto-line-where (lambda () (equal id (tabulated-list-get-id)))))

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
Each call pushes (paste STR) or (key NAME).  Ghostel's native module is absent
under test, so requiring it is a no-op."
  (declare (indent 1))
  `(claude-code-tests--without-requiring '(ghostel)
     (cl-letf (((symbol-function 'ghostel-paste-string)
                (lambda (s) (push (list 'paste s) ,calls)))
               ((symbol-function 'ghostel-send-key)
                (lambda (k &rest _) (push (list 'key k) ,calls))))
       ,@body)))

(defmacro claude-code-tests--recording-launch (execs &rest body)
  "Run BODY with the launch path stubbed, pushing (BUFFER ARGS ENV PROGRAM).
Each launch is pushed onto EXECS.  ENV is what the instance would have
inherited, modelling only the two things that decide it: the pre-spawn hook
runs in the instance's buffer, over a `process-environment' sharing its tail
with Emacs's own.  Each launch's buffer gets a `ghostel--pid' of its own, as
Ghostel gives it, and no live process.
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
                    (lambda (buffer program args)
                      (push buffer ,hosted)
                      (with-current-buffer buffer
                        (setq-local ghostel--pid (+ 5000 (length ,hosted)))
                        (setq-local ghostel--process nil))
                      (push (list buffer args
                                  (with-current-buffer buffer
                                    (let ((process-environment
                                           (append '("INSIDE_EMACS=ghostel")
                                                   process-environment)))
                                      (run-hooks 'ghostel-pre-spawn-hook)
                                      process-environment))
                                  program)
                            ,execs))))
           (unwind-protect (progn ,@body)
             (dolist (buffer ,hosted)
               (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(defconst claude-code-tests--alt-screen "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"
  "The renderer variable the CLI reads before the other and before `tui'.")

(defconst claude-code-tests--no-flicker "CLAUDE_CODE_NO_FLICKER"
  "The renderer variable asking for the alt-screen renderer.")

(defmacro claude-code-tests--with-renderer-launch (child-env &rest body)
  "Run BODY over a stubbed launch path, both renderer variables pinned to \"0\".
CHILD-ENV names a function of one variable name, bound over BODY, returning
what the instance of the latest launch inherited; \"0\" therefore reads as an
inheritance the launch left alone.  Pinning them keeps the test off whatever
the developer exports."
  (declare (indent 1))
  (let ((execs (gensym "execs")))
    `(claude-code-tests--with-registry
       (let ((,execs '())
             (process-environment
              (append (list (concat claude-code-tests--alt-screen "=0")
                            (concat claude-code-tests--no-flicker "=0"))
                      (copy-sequence process-environment))))
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

(ert-deftest claude-code-test-project-transcripts-under-a-cut-name ()
  "A project whose directory name Claude cut still lists its transcripts.
The directory is named as CLI v2.1.304 named it for that cwd."
  (let* ((config (make-temp-file "cc-config" t))
         (claude-code-config-dir config)
         (cwd (concat "/tmp/cc-probe-enc/" (make-string 182 ?x) "y"))
         (dir (expand-file-name (concat "projects/-tmp-cc-probe-enc-"
                                        (make-string 182 ?x) "-kcmpb5")
                                config))
         (id "11111111-1111-4111-8111-111111111111"))
    (unwind-protect
        (progn
          (make-directory dir t)
          (with-temp-file (expand-file-name (concat id ".jsonl") dir)
            (insert "{\"type\":\"last-prompt\",\"lastPrompt\":\"hi\"}\n"))
          (should (equal (mapcar (lambda (tr) (plist-get tr :id))
                                 (claude-code--project-transcripts cwd))
                         (list id))))
      (delete-directory config t))))

(ert-deftest claude-code-test-live-table ()
  "Every sessions/ file is parsed and keyed by the PID that names it."
  (claude-code-tests--with-fixtures
    (let ((table (claude-code--live-table)))
      (should (= (hash-table-count table) 6))
      (let ((p1 (gethash 1001 table)))
        (should (equal (plist-get p1 :session)
                       "11111111-1111-4111-8111-111111111111"))
        (should (equal (plist-get p1 :cwd) "/home/test/proj"))
        (should (equal (plist-get p1 :status) "busy"))
        (should-not (plist-get p1 :shell-p))
        ;; The parser exposes only :session, :cwd, :status, :waiting-for and
        ;; :shell-p.
        (should (null (plist-get p1 :name))))
      (let ((p3 (gethash 1003 table)))
        (should (equal (plist-get p3 :status) "waiting"))
        (should (equal (plist-get p3 :waiting-for) "permission prompt")))
      ;; A file without a status field yields nil, not an error.
      (should (null (plist-get (gethash 1004 table) :status)))
      ;; Claude's `shell' (between turns, a background command running) is
      ;; busy, and flagged as such.
      (let ((p6 (gethash 1006 table)))
        (should (equal (plist-get p6 :status) "busy"))
        (should (plist-get p6 :shell-p)))
      ;; `claude-code--pid-info' reads one process's file the same way.
      (should (equal (claude-code--pid-info 1003) (gethash 1003 table)))
      (should-not (claude-code--pid-info 999999))
      (should-not (claude-code--pid-info nil)))))

(ert-deftest claude-code-test-live-table-skips-what-names-no-session ()
  "Only a `<pid>.json' naming a session describes a running process.
A file caught mid-rewrite, one whose `sessionId' is not a string, and the
companion `<pid>.<sha256>.key' all describe nothing."
  (claude-code-tests--with-config
    (claude-code-tests--write-session-file 10 "kept")
    (claude-code-tests--write-session-file 11 "{\"pid\":11,\"sessionId\":")
    (claude-code-tests--write-session-file 12 "{\"pid\":12,\"sessionId\":null}")
    (with-temp-file (expand-file-name "13.0a1b.key" (claude-code--sessions-dir))
      (insert "{\"sessionId\":\"key\"}"))
    (let ((table (claude-code--live-table)))
      (should (equal (hash-table-keys table) '(10)))
      (should (equal (plist-get (gethash 10 table) :session) "kept")))
    (should-not (claude-code--pid-info 11))
    (should-not (claude-code--pid-info 12))))

(ert-deftest claude-code-test-pid-cwd ()
  "A process's working directory is read off its own sessions/ file, by pid."
  (claude-code-tests--with-fixtures
    (should (equal (claude-code--pid-cwd 1003)
                   "/home/test/proj/.claude/worktrees/feat"))
    (should (equal (claude-code--pid-cwd 1001) "/home/test/proj"))
    ;; No file for the pid, or no pid at all, is no directory, not an error.
    (should-not (claude-code--pid-cwd 999999))
    (should-not (claude-code--pid-cwd nil))))

(ert-deftest claude-code-test-project-transcripts ()
  "Transcripts of the project and its worktrees are enumerated."
  (claude-code-tests--with-fixtures
    (let* ((ts (claude-code--project-transcripts "/home/test/proj"))
           (by-id (lambda (id)
                    (seq-find (lambda (d) (equal (plist-get d :id) id)) ts))))
      ;; Every transcript is described, a program's included -- the model is
      ;; what decides which of them the user is shown.  A worktree directory
      ;; contributes its transcripts to the parent whatever they hold, which is
      ;; what membership by directory prefix means.
      (should (= (length ts) 8))
      (let ((s1 (funcall by-id "11111111-1111-4111-8111-111111111111")))
        ;; With no custom title, the LAST ai-title wins over earlier ones.
        (should (equal (plist-get s1 :title) "Understand the project layout"))
        (should (equal (plist-get s1 :last-prompt) "first prompt"))
        ;; Last-active is the newest timestamped (assistant) line, even though an
        ;; untimestamped ai-title line follows it -- not the file mtime.
        (should (time-equal-p (plist-get s1 :last-active)
                              (date-to-time "2026-06-10T13:23:27.697Z"))))
      (let ((s2 (funcall by-id "22222222-2222-4222-8222-222222222222")))
        ;; A custom title supplies the title even with no ai-title line.
        (should (equal (plist-get s2 :title) "My renamed session"))
        (should (equal (plist-get s2 :last-prompt) "another task here"))
        (should (string-prefix-p "Goal was extending the consult keybindings"
                                 (plist-get s2 :recap))))
      (let ((s3 (funcall by-id "33333333-3333-4333-8333-333333333333")))
        ;; A user custom title takes precedence over Claude's ai-title.
        (should (equal (plist-get s3 :title) "Renamed worktree")))
      (let ((s5 (funcall by-id "55555555-5555-4555-8555-555555555555")))
        ;; The directory token flattened the dot in "my.feat"; the binding is
        ;; what carries the name Claude was given, and the only thing that does.
        (should (equal (plist-get s5 :worktree-binding)
                       '(:name "my.feat"
                         :path "/home/test/proj/.claude/worktrees/my.feat"
                         :bound t))))
      ;; A session started from inside a worktree directory, with no worktree
      ;; of its own: Claude bound it to none, so nothing here names one.
      (let ((sa (funcall by-id "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")))
        (should (equal (plist-get sa :title) "Started inside the worktree"))
        (should (null (plist-get sa :worktree-binding)))))))

(ert-deftest claude-code-test-worktree-binding ()
  "A transcript's worktree binding survives the session leaving the worktree.
Claude clears the binding to null when a session leaves -- which is what a
clean exit does, even when the user keeps the worktree -- so the newest
`worktree-state' line answers whether the session is still there, and the
newest one that carries a binding answers which worktree it was."
  (claude-code-tests--with-fixtures
    (let ((binding (lambda (id dir)
                     (plist-get (claude-code--transcript-fields
                                 (expand-file-name
                                  (concat id ".jsonl")
                                  (expand-file-name
                                   (concat "projects/" dir)
                                   claude-code-tests--fixtures)))
                                :worktree-binding))))
      ;; Still in its worktree.
      (should (equal (funcall binding "33333333-3333-4333-8333-333333333333"
                              "-home-test-proj--claude-worktrees-feat")
                     '(:name "feat"
                       :path "/home/test/proj/.claude/worktrees/feat"
                       :bound t)))
      ;; Left it: the transcript has moved back under the parent project and
      ;; the binding reads as cleared, but it still names the worktree.
      (should (equal (funcall binding "44444444-4444-4444-8444-444444444444"
                              "-home-test-proj")
                     '(:name "left"
                       :path "/home/test/proj/.claude/worktrees/left"
                       :bound nil)))
      ;; Never had one.
      (should-not (funcall binding "11111111-1111-4111-8111-111111111111"
                           "-home-test-proj")))))

(ert-deftest claude-code-test-worktree-binding-needs-the-directory ()
  "A binding names a worktree only while the worktree is there to go back to.
Claude\='s word is enough for a session it still holds; for one that left, the
name outlives the directory, so the label follows the directory."
  (let* ((root (file-truename (make-temp-file "cc-root" t)))
         (dir (expand-file-name ".claude/worktrees/feat" root))
         (live (list :name "feat" :path dir :bound nil))
         (gone (list :name "feat" :path (expand-file-name "nope" root)
                     :bound nil))
         (bound (list :name "feat" :path dir :bound t)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (should (equal (claude-code--binding-worktree live) "feat"))
          (should-not (claude-code--binding-worktree gone))
          (should-not (claude-code--binding-worktree nil))
          ;; The label stands for a bound session with no directory at all,
          ;; which is Claude's to clear on the next resume, not ours to guess.
          (should (equal (claude-code--binding-worktree
                          (list :name "feat" :path nil :bound t))
                         "feat"))
          ;; A binding Claude still holds needs no flag -- it re-enters the
          ;; worktree itself -- and one whose worktree is gone must not get
          ;; one, since `--worktree' would build a fresh checkout.
          (should (equal (claude-code--resume-worktree root live) "feat"))
          (should-not (claude-code--resume-worktree root bound))
          (should-not (claude-code--resume-worktree root gone))
          (should-not (claude-code--resume-worktree root nil)))
      (delete-directory root t))))

(ert-deftest claude-code-test-resume-worktree-must-round-trip ()
  "The flag is withheld unless the name resolves back to the recorded worktree.
`--worktree=NAME\=' always means ROOT/.claude/worktrees/NAME, while Claude
records only a base name, so a worktree kept anywhere else -- one made with
`git worktree add\=' and entered, or placed by a `WorktreeCreate\=' hook -- would
have the flag build a fresh checkout beside the work rather than return to it."
  (let* ((root (file-truename (make-temp-file "cc-root" t)))
         (inside (expand-file-name ".claude/worktrees/feat" root))
         (outside (expand-file-name "elsewhere/feat" root)))
    (unwind-protect
        (progn
          (make-directory inside t)
          (make-directory outside t)
          (should (equal (claude-code--resume-worktree
                          root (list :name "feat" :path inside :bound nil))
                         "feat"))
          ;; Same name, same repository, a directory that exists -- and still
          ;; no flag, because the flag would not land there.
          (should-not (claude-code--resume-worktree
                       root (list :name "feat" :path outside :bound nil)))
          ;; A symlinked spelling of the same directory still round-trips.
          (should (equal (claude-code--resume-worktree
                          (file-name-as-directory root)
                          (list :name "feat"
                                :path (concat root "/./.claude/worktrees/feat")
                                :bound nil))
                         "feat")))
      (delete-directory root t))))

(ert-deftest claude-code-test-worktree-binding-drops-non-strings ()
  "A binding field that is not a string is dropped rather than passed on.
JSON null arrives as a symbol, and one reaching `file-directory-p\=' or the CLI
would cost the whole view rather than the one session."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"worktree-state\",\"worktreeSession\":{\"worktreeName\":\"feat\",\"worktreePath\":null},\"sessionId\":\"x\"}"
        "{\"type\":\"worktree-state\",\"worktreeSession\":null,\"sessionId\":\"x\"}")
      1800000000
    (let ((binding (plist-get (claude-code--transcript-fields file)
                              :worktree-binding)))
      (should (equal binding '(:name "feat" :path nil :bound nil)))
      ;; The cleared binding has no directory to check, so neither the label
      ;; nor the flag can be had -- and neither signals.
      (should-not (claude-code--binding-worktree binding))
      (should-not (claude-code--resume-worktree "/r" binding))))
  ;; A name that is not a string leaves no binding at all.
  (claude-code-tests--with-transcript file
      '("{\"type\":\"worktree-state\",\"worktreeSession\":{\"worktreeName\":null,\"worktreePath\":\"/w\"},\"sessionId\":\"x\"}")
      1800000000
    (should-not (plist-get (claude-code--transcript-fields file)
                           :worktree-binding))))

(ert-deftest claude-code-test-worktree-dir-belongs-to-two-roots ()
  "A worktree's transcript directory is listed by the worktree root too.
Encoding the worktree path yields exactly the parent's encoded directory plus
the worktree prefix, so one directory is the parent project's worktree
directory and the worktree project's own.  Both roots therefore list the same
transcript -- which is why nothing may key a session on the root it was asked
about, and why `claude-code--current-project' hands a worktree buffer the
parent: only the parent lists the sessions Claude has refiled."
  (should (equal (claude-code--encode-cwd
                  "/home/test/proj/.claude/worktrees/feat")
                 (concat (claude-code--encode-cwd "/home/test/proj")
                         "--claude-worktrees-feat")))
  (claude-code-tests--with-fixtures
    (let ((ts (claude-code--project-transcripts
               "/home/test/proj/.claude/worktrees/feat")))
      (should (= (length ts) 1))
      (should (equal (plist-get (car ts) :id)
                     "33333333-3333-4333-8333-333333333333")))))

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
                 '("/home/me/proj" . "team+feat")))
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

(ert-deftest claude-code-test-worktree-names ()
  "The names offered for a worktree are the directories Claude keeps under root."
  (let ((root (file-truename (make-temp-file "cc-root" t))))
    (unwind-protect
        (progn
          (should-not (claude-code--worktree-names root))
          (make-directory (claude-code--worktree-path root "feat") t)
          (make-directory (claude-code--worktree-path root "my.feat") t)
          ;; A file among them is not a checkout.
          (with-temp-file (claude-code--worktree-path root "stray") (insert "x"))
          (should (equal (sort (claude-code--worktree-names root) #'string<)
                         '("feat" "my.feat"))))
      (delete-directory root t))))

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

(ert-deftest claude-code-test-transcript-fields-last-active ()
  "`:last-active' is the newest timestamped line, ignoring mtime and metadata."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"q\"},\"timestamp\":\"2026-06-10T13:20:00.000Z\"}"
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[]},\"timestamp\":\"2026-06-10T13:23:27.697Z\"}"
        "{\"type\":\"last-prompt\",\"lastPrompt\":\"q\"}")
      1800000000
    (should (time-equal-p
             (plist-get (claude-code--transcript-fields file) :last-active)
             (date-to-time "2026-06-10T13:23:27.697Z")))))

(ert-deftest claude-code-test-transcript-fields-last-active-fallback ()
  "With no timestamped line at all, `:last-active' falls back to the file mtime."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"ai-title\",\"aiTitle\":\"stub\"}"
        "{\"type\":\"agent-name\",\"agentName\":\"orphan\"}")
      1800000000
    (should (time-equal-p
             (plist-get (claude-code--transcript-fields file) :last-active)
             1800000000))))

(ert-deftest claude-code-test-transcript-fields-last-active-embedded-timestamp ()
  "A nested `timestamp' in a `file-history-snapshot' line is not mistaken for one."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"q\"},\"timestamp\":\"2026-06-10T13:23:27.697Z\"}"
        "{\"type\":\"file-history-snapshot\",\"messageId\":\"m1\",\"snapshot\":{\"trackedFileBackups\":{},\"timestamp\":\"2026-06-10T13:23:40.000Z\"},\"isSnapshotUpdate\":false}")
      1800000000
    (should (time-equal-p
             (plist-get (claude-code--transcript-fields file) :last-active)
             (date-to-time "2026-06-10T13:23:27.697Z")))))

(ert-deftest claude-code-test-transcript-fields-title-quoted-in-a-message ()
  "A message quoting a field's name is not mistaken for the line that sets it.
The backward scan picks lines by a literal, so the conversation's own text can
put that literal in its way; the parsed top-level key is what decides."
  (claude-code-tests--with-transcript file
      ;; The message is exactly the literal the title scan searches for, so the
      ;; scan reaches this line first and has to reject it on the parsed keys.
      '("{\"type\":\"ai-title\",\"aiTitle\":\"real\"}"
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"custom-title\"},\"timestamp\":\"2026-06-10T13:23:27.697Z\"}")
      1800000000
    (should (equal (plist-get (claude-code--transcript-fields file) :title)
                   "real"))))

(ert-deftest claude-code-test-transcript-fields-recap ()
  "`:recap' is the newest `away_summary', stripped of the CLI's `/config' note.
Claude writes one every time the user comes back to a session, so a long
conversation carries several and only the last one describes where it stands."
  (let ((recap (lambda (&rest lines)
                 (claude-code-tests--with-transcript file lines 1800000000
                   (plist-get (claude-code--transcript-fields file) :recap)))))
    ;; A session Claude never recapped has none.
    (should-not (funcall recap "{\"type\":\"ai-title\",\"aiTitle\":\"t\"}"))
    ;; The newest wins, and the trailing `/config' note is not part of it.
    (should (equal (funcall recap
                            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"Older recap. (disable recaps in /config)\"}"
                            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"Newest recap.\"}")
                   "Newest recap."))
    (should (equal (funcall recap
                            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"Goal was X. (disable recaps in /config)\"}")
                   "Goal was X."))
    ;; A recap that is nothing but the note reads as no recap, not as "".
    (should-not (funcall recap
                         "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\" (disable recaps in /config)\"}"))
    ;; A field that is not a string is dropped rather than trusted: JSON null
    ;; arrives as a symbol, and one of those reaching `string-remove-suffix'
    ;; would signal and take the whole view down with it.
    (should-not (funcall recap
                         "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":null}"))
    (should-not (funcall recap
                         "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"\"}"))
    ;; `content' is the one field name other line types also carry at the top
    ;; level, so the scan settles a match on `subtype' as well.  Both of these
    ;; sit newer than the recap and hold text of their own to mistake for one.
    (should (equal (funcall recap
                            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"real\"}"
                            "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"content\":\"queued prompt\",\"meta\":{\"away_summary\":true}}"
                            "{\"type\":\"system\",\"subtype\":\"local_command\",\"content\":\"<local-command-stdout>away_summary</local-command-stdout>\"}")
                   "real"))
    ;; The conversation's own text never reaches that check: JSON escapes the
    ;; quotes in a quoted token, so the literal the scan searches for is not
    ;; what ends up on the line.
    (should (equal (funcall recap
                            "{\"type\":\"system\",\"subtype\":\"away_summary\",\"content\":\"real\"}"
                            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"away_summary\"},\"timestamp\":\"2026-06-10T13:23:27.697Z\"}")
                   "real"))))

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

(ert-deftest claude-code-test-sessions-omit-a-programs-session ()
  "A session a program drove is dropped by the model, not by the adapter."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      (let ((agent "88888888-8888-4888-8888-888888888888")
            (resumed "99999999-9999-4999-8999-999999999999"))
        (let ((ids (mapcar #'claude-code-session-id
                           (claude-code-project-sessions "/home/test/proj"))))
          (should-not (member agent ids))
          ;; A one-shot the user resumed interactively is theirs.
          (should (member resumed ids)))
        ;; A running one is left out too, which is the point: a fan-out puts
        ;; two dozen live `claude' processes under the project at once, and an
        ;; External group listing them is the same noise as a Dead one.
        (claude-code-tests--with-live-pids '(1005)
          (should-not (member agent
                              (mapcar #'claude-code-session-id
                                      (claude-code-project-sessions
                                       "/home/test/proj")))))
        ;; The descriptor is still there for `claude-code-resume' to read the
        ;; worktree binding out of.
        (should (claude-code--transcript-for "/home/test/proj" agent))))))

(ert-deftest claude-code-test-sessions-keep-a-managed-instance ()
  "An instance Emacs manages is listed whatever its transcript is stamped with.
This is what an Emacs that inherited `CLAUDE_CODE_ENTRYPOINT\=' from a program
rests on: every session it spawns carries that stamp."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let ((agent "88888888-8888-4888-8888-888888888888"))
        (claude-code--register agent buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          (let ((s (claude-code-tests--find-session
                    (claude-code-project-sessions "/home/test/proj") agent)))
            (should s)
            (should (claude-code-session-alive-p s))
            ;; With its transcript, so the row is named rather than falling
            ;; back to the bare id the registry alone could offer.
            (should (equal (claude-code--session-display-name s)
                           "Security review fan-out"))))))))

(ert-deftest claude-code-test-sidechains-are-not-sessions ()
  "A `Task\=' subagent writes under <sessionId>/subagents/ and is never a session.
The listing matches one directory level, so those transcripts are out of reach
without filtering; making it recursive would put every subagent in the view."
  (claude-code-tests--with-fixtures
    (let ((ids (mapcar (lambda (d) (plist-get d :id))
                       (claude-code--project-transcripts "/home/test/proj"))))
      (should-not (member "agent-a1b2c3d4e5f60718" ids)))))

(ert-deftest claude-code-test-transcript-fields-custom-title-wins ()
  "A `custom-title' outranks an `ai-title', whichever came last."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"custom-title\",\"customTitle\":\"renamed\"}"
        "{\"type\":\"ai-title\",\"aiTitle\":\"generated\"}")
      1800000000
    (should (equal (plist-get (claude-code--transcript-fields file) :title)
                   "renamed"))))

(ert-deftest claude-code-test-transcript-fields-last-prompt ()
  "`:last-prompt' is the latest prompt, not the opening one.
A rewind writes a `last-prompt' line with no `lastPrompt', which is passed over."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"What does the proposed format mean?\"},\"timestamp\":\"2026-10-26T22:58:41.112Z\"}"
        "{\"type\":\"last-prompt\",\"lastPrompt\":\"What does the proposed format mean?\",\"leafUuid\":\"c52990d4-bdd7-4420-a4c2-c112963d313b\",\"sessionId\":\"11111111-1111-4111-8111-111111111111\"}"
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"What does the proposed display format mean?\"},\"timestamp\":\"2026-10-26T23:00:52.397Z\"}"
        "{\"type\":\"last-prompt\",\"lastPrompt\":\"What does the proposed display format mean?\",\"leafUuid\":\"9a385cbb-0463-4a24-8d15-226acdb81c96\",\"sessionId\":\"11111111-1111-4111-8111-111111111111\"}"
        "{\"type\":\"last-prompt\",\"leafUuid\":\"00000000-0000-0000-0000-000000000000\",\"explicit\":true,\"sessionId\":\"11111111-1111-4111-8111-111111111111\"}")
      1800000000
    (should (equal (plist-get (claude-code--transcript-fields file) :last-prompt)
                   "What does the proposed display format mean?"))))

(ert-deftest claude-code-test-transcript-fields-last-active-snapshot-only ()
  "With only `file-history-snapshot' lines, last-active falls back to the mtime."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"file-history-snapshot\",\"messageId\":\"m1\",\"snapshot\":{\"trackedFileBackups\":{},\"timestamp\":\"2026-06-10T13:23:40.000Z\"},\"isSnapshotUpdate\":false}")
      1800000000
    (should (time-equal-p
             (plist-get (claude-code--transcript-fields file) :last-active)
             1800000000))))

;;;; Model

(defun claude-code-tests--find-session (sessions id)
  "Return the session in SESSIONS whose id is ID."
  (seq-find (lambda (s) (equal (claude-code-session-id s) id)) sessions))

(ert-deftest claude-code-test-sessions-all-dead ()
  "With nothing managed, every transcript is a dead session."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      (let ((ss (claude-code-project-sessions "/home/test/proj")))
        (should (= (length ss) 7))
        (should-not (seq-some #'claude-code-session-alive-p ss))
        (let ((s1 (claude-code-tests--find-session
                   ss "11111111-1111-4111-8111-111111111111")))
          ;; Dead sessions carry no live status, but keep every
          ;; transcript-derived field.
          (should (null (claude-code-session-status s1)))
          (should (equal (claude-code-session-title s1)
                         "Understand the project layout"))
          (should (equal (claude-code-session-last-prompt s1) "first prompt"))
          (should (time-equal-p (claude-code-session-last-active s1)
                                (date-to-time "2026-06-10T13:23:27.697Z")))
          (should (equal (file-name-base (claude-code-session-transcript s1))
                         "11111111-1111-4111-8111-111111111111"))
          (should (file-exists-p (claude-code-session-transcript s1))))
        ;; The worktree transcript shows up under the parent project.
        (should (equal (claude-code-session-worktree
                        (claude-code-tests--find-session
                         ss "33333333-3333-4333-8333-333333333333"))
                       "feat"))
        ;; A genuinely dead worktree (no sessions/*.json) still labels with its
        ;; own worktree, not the parent project -- and the binding names it as
        ;; the user wrote it, where the directory token flattened the dot.
        (let ((solo (claude-code-tests--find-session
                     ss "55555555-5555-4555-8555-555555555555")))
          (should (equal (claude-code-session-worktree solo) "my.feat")))
        ;; A session whose worktree was removed on the way out is labelled with
        ;; no worktree: it belongs to the parent tree now, and that is where a
        ;; resume of it lands.  The binding rides along regardless, since that
        ;; is what the resume path reads instead of going back to disk.
        (let ((left (claude-code-tests--find-session
                     ss "44444444-4444-4444-8444-444444444444")))
          (should-not (claude-code-session-worktree left))
          (should (equal (claude-code-session-worktree-binding left)
                         '(:name "left"
                           :path "/home/test/proj/.claude/worktrees/left"
                           :bound nil))))
        ;; Started from inside a worktree directory: the directory is what puts
        ;; it in this listing, and the missing binding is what leaves it blank.
        (let ((inside (claude-code-tests--find-session
                       ss "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")))
          (should inside)
          (should-not (claude-code-session-worktree inside))
          (should-not (claude-code-session-worktree-binding inside)))))))

(ert-deftest claude-code-test-sessions-worktree-before-transcript ()
  "A named spawn labels its worktree before Claude creates the directory.
The registry stands in with the name that was asked for; an auto-named request
carries no name, so it stays blank."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer (named-buf 4242)
      (claude-code-tests--with-managed-buffer (auto-buf 4243)
        (let ((named "66666666-6666-4666-8666-666666666666")
              (auto "77777777-7777-4777-8777-777777777777"))
          (claude-code--register named named-buf "/home/test/proj" "my.feat")
          (claude-code--register auto auto-buf "/home/test/proj" t)
          (cl-letf (((symbol-function 'claude-code--session-process)
                     (lambda (b) (memq b (list named-buf auto-buf)))))
            (let ((ss (claude-code-project-sessions "/home/test/proj")))
              (should (equal (claude-code-session-worktree
                              (claude-code-tests--find-session ss named))
                             "my.feat"))
              (should-not (claude-code-session-worktree
                           (claude-code-tests--find-session ss auto))))))))))

(ert-deftest claude-code-test-sessions-list-an-instance-launched-from-a-worktree ()
  "An instance with no transcript yet is listed under its launch root's project.
Launched from inside a worktree, that is the parent project, which is the one
the views name; the worktree itself still lists it too."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let ((id "66666666-6666-4666-8666-666666666666")
            (worktree "/home/test/proj/.claude/worktrees/feat"))
        (claude-code--register id buf worktree nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          (dolist (root (list "/home/test/proj" worktree))
            (should (claude-code-session-alive-p
                     (claude-code-tests--find-session
                      (claude-code-project-sessions root) id))))
          (should-not (claude-code-tests--find-session
                       (claude-code-project-sessions "/home/other") id)))))))

(ert-deftest claude-code-test-sessions-with-alive ()
  "A managed live instance becomes the alive session, without duplication."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer (buf 1001)
      (let ((id "11111111-1111-4111-8111-111111111111"))
        (claude-code--register id buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          (let* ((ss (claude-code-project-sessions "/home/test/proj"))
                 (s1 (claude-code-tests--find-session ss id)))
            (should (= (length ss) 7))
            (should (claude-code-session-alive-p s1))
            (should (eq (claude-code-session-buffer s1) buf))
            (should (= (claude-code-session-pid s1) 1001))
            ;; Alive status comes from the live sessions file; the display
            ;; name comes from the transcript title.
            (should (equal (claude-code-session-status s1) "busy"))
            (should (equal (claude-code-session-title s1)
                           "Understand the project layout"))
            (should (equal (claude-code--session-display-name s1)
                           "Understand the project layout"))))))))

(ert-deftest claude-code-test-sessions-carry-the-status-modifier ()
  "An alive session's modifier is its root record's `done' or `error'.
It lasts exactly as long as the record: any other state, or no record once
Ghostel dropped it on input, leaves none, and a subagent's record never
counts.  A session Emacs does not run has no record to read."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let ((id "11111111-1111-4111-8111-111111111111"))
        (claude-code--register id buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          (pcase-dolist (`(,records ,modifier ,message)
                         '(((("" :state done)) done nil)
                           ((("" :state done :msg "m")) done "m")
                           ((("" :state error :msg "There's an issue"))
                            error "There's an issue")
                           ((("" :state working)) nil nil)
                           ((("" :state blocked :kind permission :msg "approve"))
                            nil nil)
                           ((("" :state idle)) nil nil)
                           (nil nil nil)
                           ((("a93609d08ab42add7" :state error :msg "sub")
                             ("" :state working))
                            nil nil)))
            (with-current-buffer buf (setq ghostel-program-status records))
            (dolist (s (claude-code-project-sessions "/home/test/proj"))
              (if (equal (claude-code-session-id s) id)
                  (progn
                    (should (eq (claude-code-session-modifier s) modifier))
                    (should (equal (claude-code-session-modifier-message s)
                                   message)))
                (should-not (claude-code-session-modifier s))))))))))

(ert-deftest claude-code-test-sessions-alive-from-another-root ()
  "Aliveness is keyed by session id, not by the root the query used.
Both roots list the worktree session
\(`claude-code-test-worktree-dir-belongs-to-two-roots') while the registry
records only one of them, and under either the session must read alive -- a dead
row would offer a running session's transcript up for deletion.  No pid reads as
live here, so only the registry can be making it alive."
  (let ((id "33333333-3333-4333-8333-333333333333")
        (parent "/home/test/proj")
        (worktree "/home/test/proj/.claude/worktrees/feat"))
    ;; Launched from the parent (a `-w' spawn), queried from the worktree; then
    ;; launched from the worktree (spawned from a buffer inside it), queried
    ;; from the parent, the view worktree sessions belong to.
    (dolist (case (list (cons parent worktree) (cons worktree parent)))
      (claude-code-tests--with-fixtures
        (claude-code-tests--with-managed-buffer (buf 1003)
          (claude-code-tests--with-live-pids '()
            (claude-code--register id buf (car case) nil)
            (cl-letf (((symbol-function 'claude-code--session-process)
                       (lambda (b) (eq b buf))))
              (let ((s (claude-code-tests--find-session
                        (claude-code-project-sessions (cdr case)) id)))
                (should (claude-code-session-alive-p s))
                (should (eq 'alive (claude-code--session-liveness s)))
                (should (eq (claude-code-session-buffer s) buf))
                (should (= (claude-code-session-pid s) 1003))
                ;; A row Emacs owns carries its live status, so the view can
                ;; act on it: focus, kill, rename and send all work.
                (should (equal (claude-code-session-status s) "waiting"))
                (should (equal (claude-code-session-waiting-for s)
                               "permission prompt"))))))))))

(ert-deftest claude-code-test-sessions-external-from-another-root ()
  "The external flag is root-independent, so no root reads a live session dead.
Nothing Emacs manages runs this session, its sessions/ pid is live, and the
query is rooted at the worktree rather than the parent."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      ;; Session 33333333 has sessions/1003.json (pid 1003).
      (claude-code-tests--with-live-pids '(1003)
        (let ((s (claude-code-tests--find-session
                  (claude-code-project-sessions
                   "/home/test/proj/.claude/worktrees/feat")
                  "33333333-3333-4333-8333-333333333333")))
          (should (eq 'external (claude-code--session-liveness s))))))))

(defconst claude-code-tests--process-tree
  '((100 . ((ppid . 1) (pcpu . 1.0) (rss . 1000)))
    (101 . ((ppid . 100) (pcpu . 2.0) (rss . 2000)))
    (102 . ((ppid . 100) (pcpu . 3.0) (rss . 3000)))
    (103 . ((ppid . 102) (pcpu . 4.0) (rss . 4000)))
    (200 . ((ppid . 1) (pcpu . 9.0) (rss . 9000))))
  "A process forest for the usage tests.
100 branches and 102 has a child of its own, so a subtree walk has to cope
with a node whose children are queued behind a sibling's.")

(defmacro claude-code-tests--with-process-tree (tree &rest body)
  "Run BODY with the system process table stubbed to TREE.
TREE is an alist of (PID . ATTRIBUTES); the `ppid' entries make it a forest,
and both ways of finding a process's children read it."
  (declare (indent 1))
  (let ((forest (gensym "forest")))
    `(let ((,forest ,tree))
       (cl-letf (((symbol-function 'list-system-processes)
                  (lambda () (mapcar #'car ,forest)))
                 ((symbol-function 'process-attributes)
                  (lambda (p) (alist-get p ,forest)))
                 ((symbol-function 'claude-code--child-pids)
                  (lambda (p) (cl-loop for (child . attrs) in ,forest
                                       when (eql p (alist-get 'ppid attrs))
                                       collect child))))
         ,@body))))

(ert-deftest claude-code-test-process-usage ()
  "Usage sums the pcpu/rss of a PID's whole subtree, however children are found."
  (claude-code-tests--with-process-tree claude-code-tests--process-tree
    ;; Both sources of children: named per process, and read off a whole-table
    ;; snapshot.  Neither may change what a subtree sums to.
    (dolist (per-process '(t nil))
      (let ((claude-code--proc-children-p per-process))
        (should (equal (claude-code--process-usage 100) '(10.0 . 10000)))
        ;; A leaf sums to itself, not to its parent's subtree.
        (should (equal (claude-code--process-usage 200) '(9.0 . 9000)))
        ;; A non-integer pid yields nil.
        (should (null (claude-code--process-usage nil)))
        ;; So does a pid no process runs under: one that died before it was
        ;; sampled must read as unknown, not as an idle 0.
        (should (null (claude-code--process-usage 999999)))))))

(ert-deftest claude-code-test-process-usage-snapshot-survives-a-walk ()
  "A shared snapshot sums every subtree, not just the first one walked.
The view builds one snapshot and hands it to every row, so a walk that spliced
the snapshot's own child lists would leave later rows reading a tree it had
rewritten -- here 102 would inherit 101 and sum 9.0 instead of 7.0."
  (claude-code-tests--with-process-tree claude-code-tests--process-tree
    (let ((claude-code--proc-children-p nil)
          (snapshot (claude-code--process-snapshot)))
      (should (equal (claude-code--process-usage 100 snapshot) '(10.0 . 10000)))
      (should (equal (claude-code--process-usage 102 snapshot) '(7.0 . 7000)))
      (should (equal (claude-code--process-usage 100 snapshot) '(10.0 . 10000))))))

(ert-deftest claude-code-test-child-pids ()
  "`claude-code--child-pids' names the children of a live process."
  (skip-unless claude-code--proc-children-p)
  (let ((proc (start-process "cc-test-child" nil "sleep" "30")))
    (unwind-protect
        (progn
          (should (memql (process-id proc) (claude-code--child-pids (emacs-pid))))
          ;; A pid no process runs under has no children, and does not error.
          (should (null (claude-code--child-pids 999999))))
      (delete-process proc))))

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

(ert-deftest claude-code-test-session-liveness ()
  "Liveness is a three-way classification: alive, external, or dead."
  (should (eq 'alive (claude-code--session-liveness
                      (claude-code-session--create :alive-p t))))
  ;; An unmanaged session whose process runs elsewhere is external, not dead.
  (should (eq 'external (claude-code--session-liveness
                         (claude-code-session--create
                          :alive-p nil :external-p t))))
  (should (eq 'dead (claude-code--session-liveness
                     (claude-code-session--create :alive-p nil)))))

(ert-deftest claude-code-test-running ()
  "Each running session maps to the PID of the live `claude' running it.
A managed instance counts while its buffer's process lives, file or not; any
other PID while it is a running process."
  (claude-code-tests--with-fixtures
    ;; Session 22222222 has sessions/1002.json (pid 1002).
    (let ((id "22222222-2222-4222-8222-222222222222"))
      (claude-code-tests--with-registry
        (claude-code-tests--with-live-pids '(1002)
          (should (eql (gethash id (claude-code--running)) 1002)))
        (claude-code-tests--with-live-pids '()
          (should-not (gethash id (claude-code--running)))))
      (claude-code-tests--with-managed-buffer buf
        (claude-code--register "launched" buf "/home/test/proj" nil)
        (claude-code-tests--with-live-pids '()
          (should-not (gethash "launched" (claude-code--running)))
          (cl-letf (((symbol-function 'claude-code--session-process)
                     (lambda (b) (eq b buf))))
            (should (eql (gethash "launched" (claude-code--running)) 4242))))))))

(ert-deftest claude-code-test-sessions-follow-an-instance-across-a-clear ()
  "An instance runs the session its sessions/ file names, not its launch id.
A `/clear' moves it onto a new session: that one is alive in its buffer with
its live status, while the session it left is dead -- resumable and deletable
-- and nothing reads as external.  Here pid 1001 was launched on session
22222222 and its file now names 11111111."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer (buf 1001)
      (let ((left "22222222-2222-4222-8222-222222222222")
            (now "11111111-1111-4111-8111-111111111111")
            (execs '())
            (deleted '()))
        (claude-code--register left buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf)))
                  ((symbol-function 'claude-code--delete-transcript)
                   (lambda (file) (push file deleted))))
          (claude-code-tests--with-live-pids '(1001)
            (let* ((ss (claude-code-project-sessions "/home/test/proj"))
                   (current (claude-code-tests--find-session ss now))
                   (abandoned (claude-code-tests--find-session ss left)))
              (should (eq 'alive (claude-code--session-liveness current)))
              (should (eq (claude-code-session-buffer current) buf))
              (should (equal (claude-code-session-status current) "busy"))
              (should (eq 'dead (claude-code--session-liveness abandoned)))
              (should-not (seq-some #'claude-code-session-external-p ss))
              (should (equal (plist-get (gethash 1001 claude-code--managed)
                                        :session)
                             now))
              (let ((running (claude-code--running)))
                (should (eql (gethash now running) 1001))
                (should-not (gethash left running)))
              (claude-code-delete abandoned)
              (should (equal deleted
                             (list (claude-code-session-transcript abandoned))))
              ;; A resume starts an instance of its own rather than handing
              ;; back the one that left the session.
              (claude-code-tests--recording-launch execs
                (should-not (eq (claude-code-resume "/home/test/proj" left)
                                buf))
                (should (member (concat "--resume=" left)
                                (nth 1 (car execs))))))))))))

(ert-deftest claude-code-test-instance-keeps-its-session-while-unreadable ()
  "An instance whose sessions/ file cannot be read runs the session last read.
Claude rewrites the file in place and removes it as the process exits, so a
read can find it partial or gone while the instance is still running."
  (claude-code-tests--with-config
    (claude-code-tests--with-managed-buffer (buf 70)
      (claude-code--register "launched" buf "/r" nil)
      (cl-letf (((symbol-function 'claude-code--session-process)
                 (lambda (b) (eq b buf))))
        (should (eql (gethash "launched" (claude-code--running)) 70))
        (claude-code-tests--write-session-file 70 "cleared")
        (should (eql (gethash "cleared" (claude-code--running)) 70))
        (claude-code-tests--write-session-file 70 "{\"pid\":70,\"sessi")
        (should (eql (gethash "cleared" (claude-code--running)) 70))
        (delete-file (expand-file-name "70.json" (claude-code--sessions-dir)))
        (should (eql (gethash "cleared" (claude-code--running)) 70))
        (should-not (gethash "launched" (claude-code--running)))))))

(ert-deftest claude-code-test-external-session ()
  "An unmanaged transcript with a live sessions PID is external, else dead."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      ;; Session 22222222 has sessions/1002.json (pid 1002).  When Emacs does
      ;; not manage it but that pid is live, it is external, not dead.
      (claude-code-tests--with-live-pids '(1002)
        (let ((s (claude-code-tests--find-session
                  (claude-code-project-sessions "/home/test/proj")
                  "22222222-2222-4222-8222-222222222222")))
          (should-not (claude-code-session-alive-p s))
          (should (claude-code-session-external-p s))
          (should (eq 'external (claude-code--session-liveness s)))
          ;; The display name comes from the transcript (its `custom-title'),
          ;; regardless of liveness.
          (should (equal (claude-code--session-display-name s)
                         "My renamed session"))))
      (claude-code-tests--with-live-pids '()
        (let ((s (claude-code-tests--find-session
                  (claude-code-project-sessions "/home/test/proj")
                  "22222222-2222-4222-8222-222222222222")))
          (should-not (claude-code-session-external-p s))
          (should (eq 'dead (claude-code--session-liveness s)))
          (should (equal (claude-code--session-display-name s)
                         "My renamed session"))))
      (claude-code-tests--with-live-pids '()
        (let ((s (claude-code-tests--find-session
                  (claude-code-project-sessions "/home/test/proj")
                  "55555555-5555-4555-8555-555555555555")))
          (should (eq 'dead (claude-code--session-liveness s)))
          (should (equal (claude-code--session-display-name s)
                         "Dotted worktree")))))))

(ert-deftest claude-code-test-instance-cwd ()
  "An instance's cwd is its sessions/ file's, else its launch root.
Only an instance Emacs manages has one."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      ;; sessions/1003.json works in its worktree, not the root it was
      ;; launched from.
      (puthash 1003 (list :origin "/home/test/proj") claude-code--managed)
      (should (equal (claude-code--instance-cwd 1003)
                     "/home/test/proj/.claude/worktrees/feat"))
      ;; Before that file exists, the launch root stands in.
      (puthash 4242 (list :origin "/home/x/proj") claude-code--managed)
      (should (equal (claude-code--instance-cwd 4242) "/home/x/proj"))
      ;; A process Emacs does not manage gets nothing, sessions/ file or not.
      (should (null (claude-code--instance-cwd 1001)))
      (should (null (claude-code--instance-cwd nil))))))

(ert-deftest claude-code-test-session-directory ()
  "A session works where the process running it is now, else in its worktree.
Emacs's instance is found by pid, and works where it was launched until its
sessions/ file says otherwise; one outside Emacs, by the pid sessions/ files its
session under.  With no process, the worktree the binding names counts while it
is on disk -- the one the Worktree column shows -- and the root otherwise."
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
          (claude-code-tests--with-registry
            ;; sessions/1003.json runs session 33333333 in its worktree.
            (puthash 1003 (list :origin root) claude-code--managed)
            (should (equal (funcall dir :id "cleared" :alive-p t :pid 1003)
                           fixture-feat))
            ;; No sessions/4242.json yet.
            (puthash 4242 (list :origin feat) claude-code--managed)
            (should (equal (funcall dir :id "new" :alive-p t :pid 4242) feat)))
          (claude-code-tests--with-live-pids '(1003)
            (should (equal (funcall dir :id wt :external-p t) fixture-feat)))
          ;; A row still drawn alive whose process has gone.
          (should (equal (funcall dir :id wt :alive-p t :pid 999999) root))
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


;;;; Operations

(ert-deftest claude-code-test-build-args-new ()
  "New-session argument lists place the prompt last behind a \"--\" terminator."
  (should (equal (claude-code--build-args :session-id "ID")
                 '("--session-id" "ID")))
  (should (equal (claude-code--build-args :session-id "ID" :prompt "hello")
                 '("--session-id" "ID" "--" "hello")))
  (should (equal (claude-code--build-args
                  :session-id "ID" :model "opus" :prompt "hi")
                 '("--session-id" "ID" "--model" "opus" "--" "hi")))
  (should (equal (claude-code--build-args :session-id "ID" :effort "xhigh")
                 '("--session-id" "ID" "--effort" "xhigh")))
  (should (equal (claude-code--build-args
                  :session-id "ID" :model "opus" :effort "low" :prompt "hi")
                 '("--session-id" "ID" "--model" "opus" "--effort" "low"
                   "--" "hi")))
  (should (equal (claude-code--build-args :session-id "ID" :name "a long name")
                 '("--session-id" "ID" "--name=a long name")))
  ;; A name is passed on as it came, an empty one included: it is the CLI that
  ;; reads that as no name.
  (should (equal (claude-code--build-args :session-id "ID" :name "")
                 '("--session-id" "ID" "--name=")))
  (should (equal (claude-code--build-args :session-id "ID" :worktree t)
                 '("--session-id" "ID" "--worktree")))
  (should (equal (claude-code--build-args :session-id "ID" :worktree "feat")
                 '("--session-id" "ID" "--worktree=feat")))
  ;; The name rides in the same argument as the flag, so one the CLI would
  ;; otherwise read as a flag of its own still names the worktree.
  (should (equal (claude-code--build-args :session-id "ID"
                                          :worktree "--ax-screen-reader")
                 '("--session-id" "ID" "--worktree=--ax-screen-reader")))
  ;; A worktree prompt is kept off `--worktree' (which takes an optional name)
  ;; by "--".
  (should (equal (claude-code--build-args :session-id "ID" :worktree t
                                          :prompt "hi")
                 '("--session-id" "ID" "--worktree" "--" "hi")))
  (should (equal (claude-code--build-args
                  :session-id "ID" :name "review" :worktree "feat"
                  :model "opus" :effort "low" :prompt "hi")
                 '("--session-id" "ID" "--name=review" "--worktree=feat"
                   "--model" "opus" "--effort" "low" "--" "hi")))
  ;; Empty prompt is dropped (and so is the terminator).
  (should (equal (claude-code--build-args :session-id "ID" :prompt "")
                 '("--session-id" "ID"))))

(ert-deftest claude-code-test-build-args-resume ()
  "Resume takes \"--resume=ID\" and a worktree, and ignores everything else."
  (should (equal (claude-code--build-args :resume "ID") '("--resume=ID")))
  (should (equal (claude-code--build-args :resume "ID" :prompt "x" :model "opus"
                                          :effort "high" :name "review")
                 '("--resume=ID")))
  (should (equal (claude-code--build-args :resume "ID" :session-id "ID")
                 '("--resume=ID")))
  ;; A named worktree leads, as the CLI's own parting recipe writes it.
  (should (equal (claude-code--build-args :resume "ID" :worktree "my.feat")
                 '("--worktree=my.feat" "--resume=ID")))
  ;; Only a name means anything here: there is no auto-naming a worktree a
  ;; resume is meant to return to.
  (should (equal (claude-code--build-args :resume "ID" :worktree t)
                 '("--resume=ID"))))

(ert-deftest claude-code-test-launch-passes-the-mcp-arguments ()
  "The MCP arguments reach the CLI ahead of the session's own."
  (claude-code-tests--with-registry
    (let ((execs '())
          (claude-code-cli "claude"))
      (claude-code-tests--recording-launch execs
        (cl-letf (((symbol-function 'claude-code--mcp-wiring)
                   (lambda (_buffer) '(("--mcp-config=x" "--allowedTools" "y")))))
          (let ((id (car (claude-code-spawn "/r" :prompt "hi"))))
            (should (equal (nth 3 (car execs)) "claude"))
            (should (equal (nth 1 (car execs))
                           (list "--mcp-config=x" "--allowedTools" "y"
                                 "--session-id" id "--" "hi")))))))))

(ert-deftest claude-code-test-launch-refuses-a-missing-cli ()
  "A CLI that cannot be found stops the launch before it starts anything.
The shell would otherwise exit at once in a buffer that dies with it, leaving
the caller an id for an instance that never ran."
  (claude-code-tests--with-registry
    (let ((execs '())
          (mcp-calls 0)
          (buffers (buffer-list))
          (resolve (symbol-function 'claude-code--resolve-executable))
          (claude-code-cli "claude-code-tests-cli")
          (exec-path '()))
      (claude-code-tests--recording-launch execs
        (cl-letf (((symbol-function 'claude-code--mcp-wiring)
                   (lambda (_buffer) (cl-incf mcp-calls) nil))
                  ((symbol-function 'claude-code--resolve-executable) resolve))
          (should-error (claude-code-spawn "/r") :type 'user-error))
        (should (null execs))
        (should (zerop mcp-calls))
        (should-not (seq-difference (buffer-list) buffers))))))

(ert-deftest claude-code-test-launch-finds-the-cli-on-the-project-host ()
  "A remote project's instance runs the CLI its own host has.
What Ghostel is handed is the name that host's shell runs."
  (claude-code-tests--with-executable dir "claude-code-tests-cli"
    (claude-code-tests--with-registry
      (let ((execs '())
            (resolve (symbol-function 'claude-code--resolve-executable))
            (claude-code-cli "claude-code-tests-cli")
            (exec-path '()))
        (claude-code-tests--on-mock-host (list dir)
          (let ((root default-directory)
                ;; The caller's own directory is local: only the root may
                ;; decide the host.
                (default-directory temporary-file-directory))
            (claude-code-tests--recording-launch execs
              (cl-letf (((symbol-function 'claude-code--resolve-executable)
                         resolve))
                (claude-code-spawn root)
                (should (equal (nth 3 (car execs))
                               (expand-file-name claude-code-cli dir)))))))))))

(ert-deftest claude-code-test-resolve-executable-searches-exec-path ()
  "A bare name is found on `exec-path' and comes back as the file it names."
  (claude-code-tests--with-executable dir "claude-code-tests-cli"
    (let ((exec-path (list dir)))
      (should (equal (claude-code--resolve-executable "claude-code-tests-cli")
                     (expand-file-name "claude-code-tests-cli" dir))))))

(ert-deftest claude-code-test-resolve-executable-takes-a-file-name ()
  "A name with a directory is a file, a relative one under `default-directory'."
  (claude-code-tests--with-executable dir "cli"
    (let ((exec-path '())
          (default-directory dir)
          (cli (expand-file-name "cli" dir)))
      (should (equal (claude-code--resolve-executable "./cli") cli))
      (should (equal (claude-code--resolve-executable cli) cli)))))

(ert-deftest claude-code-test-resolve-executable-refuses-a-missing-one ()
  "No executable by the name is a `user-error' naming where it was sought."
  (let ((exec-path '()))
    (should (string-match-p
             "in .exec-path."
             (cadr (should-error
                    (claude-code--resolve-executable "claude-code-tests-cli")
                    :type 'user-error))))
    (should-error (claude-code--resolve-executable "/claude-code-tests/cli")
                  :type 'user-error)
    (claude-code-tests--on-mock-host nil
      (should (string-match-p
               "on /mock:.* in .tramp-remote-path."
               (cadr (should-error
                      (claude-code--resolve-executable "claude-code-tests-cli")
                      :type 'user-error)))))))

(ert-deftest claude-code-test-resolve-executable-searches-the-host-path ()
  "A remote `default-directory' searches its host's path, not Emacs's.
The answer is the name that host runs, without TRAMP's prefix."
  (claude-code-tests--with-executable dir "claude-code-tests-cli"
    (let ((exec-path '()))
      (claude-code-tests--on-mock-host (list dir)
        (should (equal (claude-code--resolve-executable "claude-code-tests-cli")
                       (expand-file-name "claude-code-tests-cli" dir)))))
    (let ((exec-path (list dir)))
      (claude-code-tests--on-mock-host nil
        (should-error (claude-code--resolve-executable "claude-code-tests-cli")
                      :type 'user-error)))))

(ert-deftest claude-code-test-resolve-executable-ignores-the-project-directory ()
  "A bare name never resolves to a file in a remote `default-directory'.
TRAMP appends that directory to the host's search path, and a project's own
executable is not the CLI."
  (claude-code-tests--with-executable dir "claude-code-tests-cli"
    (claude-code-tests--on-mock-host nil
      (let ((default-directory (concat (file-remote-p default-directory) dir)))
        (should-error (claude-code--resolve-executable "claude-code-tests-cli")
                      :type 'user-error)))))

(ert-deftest claude-code-test-resolve-executable-takes-a-host-file-name ()
  "An absolute name under a remote `default-directory' is a file on its host."
  (claude-code-tests--with-executable dir "cli"
    ;; A home of its own sets the host's file names apart from Emacs's.
    (let ((tramp-remote-process-environment
           (cons (concat "HOME=" (directory-file-name dir))
                 tramp-remote-process-environment)))
      (claude-code-tests--on-mock-host nil
        (should (equal (claude-code--resolve-executable "~/cli")
                       (expand-file-name "cli" dir)))
        (should-error (claude-code--resolve-executable "~/cli-none")
                      :type 'user-error)))))

(ert-deftest claude-code-test-new-uuid ()
  "Generated ids are valid, distinct version-4 UUIDs."
  (should (string-match-p claude-code-tests--uuid-re (claude-code--new-uuid)))
  (should-not (equal (claude-code--new-uuid) (claude-code--new-uuid))))

(ert-deftest claude-code-test-default-buffer-name ()
  "The pre-title seed name is derived from the project directory name."
  (should (equal (claude-code--default-buffer-name "/home/x/proj")
                 "*claude: proj*"))
  ;; A trailing slash adds no trailing hyphen/segment.
  (should (equal (claude-code--default-buffer-name "/home/x/proj/")
                 "*claude: proj*")))

(ert-deftest claude-code-test-ghostel-buffer-name ()
  "The Ghostel title tracker names the buffer after the terminal title."
  (should (equal (claude-code--ghostel-buffer-name "My title")
                 "*claude: My title*"))
  ;; Claude prefixes the title with a status indicator glyph and a space in
  ;; the form "<indicator> <title>"; the leading symbol/whitespace run is
  ;; stripped.  The glyph varies (idle marker or any spinner frame), so the
  ;; strip must not hardcode code points.
  (should (equal (claude-code--ghostel-buffer-name "✳ Understand the layout")
                 "*claude: Understand the layout*"))
  (should (equal (claude-code--ghostel-buffer-name "⠋ Working on it")
                 "*claude: Working on it*"))
  ;; A multi-glyph indicator and repeated spaces collapse away too.
  (should (equal (claude-code--ghostel-buffer-name "✳⠋  Doing things")
                 "*claude: Doing things*"))
  ;; A title with no indicator prefix is left untouched — nothing is chopped.
  (should (equal (claude-code--ghostel-buffer-name "Plain title")
                 "*claude: Plain title*"))
  ;; An indicator with no title yet declines, like an empty title.
  (should (null (claude-code--ghostel-buffer-name "✳ ")))
  ;; An empty or absent title declines the rename (nil), as Ghostel expects.
  (should (null (claude-code--ghostel-buffer-name "")))
  (should (null (claude-code--ghostel-buffer-name nil))))

(ert-deftest claude-code-test-instance-mode ()
  "The instance mode is a Ghostel terminal that names itself after the title."
  (with-temp-buffer
    (claude-code-instance-mode)
    (should (derived-mode-p 'ghostel-mode))
    (should (local-variable-p 'ghostel-buffer-name-function))
    (should (eq ghostel-buffer-name-function
                #'claude-code--ghostel-buffer-name))))

(ert-deftest claude-code-test-instance-mode-logs-the-names-it-holds ()
  "An instance buffer records each name it takes, and when it took it.
`rename-buffer' runs the buffer's `buffer-list-update-hook'.  So does a buffer
created while the instance is current, which logs nothing: the name stands."
  (let ((now 100.0)
        (buf (generate-new-buffer " *cc-seed*")))
    (unwind-protect
        (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now)))
          (with-current-buffer buf
            (claude-code-instance-mode)
            (setq now 101.0)
            (kill-buffer (generate-new-buffer " *cc-noise*"))
            (setq now 102.0)
            (rename-buffer " *cc-startup*")
            (setq now 103.0)
            (rename-buffer " *cc-topic*")
            (should (equal claude-code--names-held
                           '((" *cc-topic*" . 103.0)
                             (" *cc-startup*" . 102.0)
                             (" *cc-seed*" . 100.0)))))
          (should-not (claude-code--name-at buf 99.0))
          (should (equal (claude-code--name-at buf 100.0) " *cc-seed*"))
          (should (equal (claude-code--name-at buf 102.5) " *cc-startup*"))
          (should (equal (claude-code--name-at buf 104.0) " *cc-topic*")))
      (kill-buffer buf))))

(ert-deftest claude-code-test-instance-mode-leaves-ghostel-the-local-map ()
  "The mode's own bindings sit above Ghostel's map rather than replacing it.
A binding is checked by what it resolves to, not by the shape of the alist
carrying it: a gate left nil would leave that shape intact and every binding
dead."
  (with-temp-buffer
    (claude-code-instance-mode)
    (should (eq (current-local-map) ghostel-semi-char-mode-map))
    (should claude-code--instance-keys)
    (should (local-variable-p 'minor-mode-overriding-map-alist))
    (should (eq (alist-get 'claude-code--instance-keys
                           minor-mode-overriding-map-alist)
                claude-code-instance-mode-map))
    (keymap-set claude-code-instance-mode-map "C-c M-z" #'ignore)
    (unwind-protect
        (should (eq (key-binding (kbd "C-c M-z")) #'ignore))
      (keymap-unset claude-code-instance-mode-map "C-c M-z" t))))

(ert-deftest claude-code-test-instance-mode-map-keeps-its-parent ()
  "Entering the mode leaves the map's parent to whoever set it."
  (let ((original (keymap-parent claude-code-instance-mode-map))
        (mine (make-sparse-keymap)))
    (should original)
    (unwind-protect
        (progn
          (set-keymap-parent claude-code-instance-mode-map mine)
          (with-temp-buffer (claude-code-instance-mode))
          (should (eq (keymap-parent claude-code-instance-mode-map) mine)))
      (set-keymap-parent claude-code-instance-mode-map original))))

(ert-deftest claude-code-test-mode-lighters ()
  "The two modes name themselves apart in the mode line."
  (should (equal (with-temp-buffer (claude-code-instance-mode) mode-name)
                 "Claude"))
  (should (equal (with-temp-buffer (claude-code-sessions-mode) mode-name)
                 "Claude Sessions")))

(ert-deftest claude-code-test-instance-mode-is-not-a-command ()
  "The mode is not offered to `M-x': there is no buffer it is right to enter.
Its parent turns a buffer over to a terminal that is not there -- clearing the
local variables, disabling undo, and making it read-only -- with nothing to
undo any of it."
  (should (fboundp 'claude-code-instance-mode))
  (should-not (commandp 'claude-code-instance-mode)))

(ert-deftest claude-code-test-instance-mode-follows-its-directory ()
  "VC's whole-repository commands act on an instance buffer's directory.
They deduce a backend from `default-directory' only in the modes
`vc-deduce-backend-nonvc-modes' names, which the mode answers for itself
alone."
  (require 'vc)
  (let ((root (file-truename (make-temp-file "cc-root" t)))
        (global (default-value 'vc-deduce-backend-nonvc-modes)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-buffer
            (claude-code-instance-mode)
            (setq default-directory (file-name-as-directory root))
            (should (eq (vc-deduce-backend) 'Git)))
          (should (equal (default-value 'vc-deduce-backend-nonvc-modes) global)))
      (delete-directory root t))))

(ert-deftest claude-code-test-follow-directory ()
  "Ghostel is handed the instance's directory as the root record changes state.
Driven through the hook as Ghostel runs it, so the mode's wiring is what is
under test.  A subagent's record, or a report leaving the state as it was,
reads nothing."
  (let ((handed '()))
    (claude-code-tests--with-fixtures
      (cl-letf (((symbol-function 'ghostel--update-directory)
                 (lambda (dir) (push dir handed))))
        (with-temp-buffer
          (claude-code-instance-mode)
          ;; sessions/1003.json runs in the fixture project's worktree.
          (setq-local ghostel--pid 1003)
          (let ((report (lambda (id old new)
                          (run-hook-with-args 'ghostel-program-status-functions
                                              id old new))))
            (funcall report "a93609d08ab42add7" nil '(:state working))
            (funcall report "" '(:state working) '(:state working :msg "m"))
            (should-not handed)
            (funcall report "" nil '(:state idle))
            (funcall report "" '(:state idle) '(:state working))
            (should (equal handed (make-list
                                   2 "/home/test/proj/.claude/worktrees/feat")))
            ;; A process with no sessions/ file hands over nothing.
            (setq handed nil ghostel--pid 999999)
            (funcall report "" '(:state working) '(:state done))
            (should-not handed)))))))

(ert-deftest claude-code-test-buffer-kill-unregisters ()
  "An instance's buffer dying removes its registry entry."
  (claude-code-tests--with-managed-buffer buf
    (claude-code--register "id-1" buf "/r" nil)
    (kill-buffer buf)
    (should (zerop (hash-table-count claude-code--managed)))))

(ert-deftest claude-code-test-buffer-kill-runs-last-instance-hook-on-transition ()
  "The hook fires exactly when a managed kill empties the registry.
Unmanaged terminals never fire it — not even while the registry is empty, the
steady state once every instance has exited."
  (claude-code-tests--with-managed-buffer buf
    (claude-code-tests--with-managed-buffer stranger
      (let* ((fired 0)
             (claude-code-last-instance-exit-hook
              (list (lambda () (cl-incf fired)))))
        ;; Empty registry: an unmanaged terminal must not fire the hook.
        (with-current-buffer stranger (claude-code--on-buffer-kill))
        (should (= fired 0))
        ;; Non-empty registry, unmanaged terminal: still nothing.
        (puthash 4242 (list :buffer buf :origin "/r") claude-code--managed)
        (with-current-buffer stranger (claude-code--on-buffer-kill))
        (should (= fired 0))
        ;; The managed kill that empties the registry fires it once.
        (with-current-buffer buf (claude-code--on-buffer-kill))
        (should (= fired 1))
        ;; A repeat report for the same buffer does not fire it again.
        (with-current-buffer buf (claude-code--on-buffer-kill))
        (should (= fired 1))))))

(ert-deftest claude-code-test-buffer-kill-survives-a-failing-hook ()
  "A signalling handler costs neither the kill nor the handlers behind it.
`kill-buffer' propagates a signal out of `kill-buffer-hook' and abandons the
kill, which would leave a live instance nothing holds a registration for.  The
handler behind it must still run: `claude-code-mcp-stop' sits there, and
skipping it leaves the MCP server listening with no instance left.  A `quit'
reaches both of those as readily as an `error' does, and clears more guards."
  (dolist (signaller (list (lambda () (error "boom"))
                           (lambda () (signal 'quit nil))))
    (claude-code-tests--with-managed-buffer buf
      (let* ((reached nil)
             (reported nil)
             (claude-code-last-instance-exit-hook
              (list signaller (lambda () (setq reached t)))))
        (claude-code--register "id-e" buf "/r" nil)
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (setq reported (apply #'format fmt args)))))
          ;; Caught so an escaping `quit' fails this test rather than ending it
          ;; as an ERT `QUIT', which leaves the run green.
          (condition-case nil (kill-buffer buf) ((error quit) nil)))
        (should-not (buffer-live-p buf))
        (should (zerop (hash-table-count claude-code--managed)))
        (should reached)
        ;; Skipping a handler silently would leave the failure invisible.
        (should (string-match-p "last-instance hook" (or reported "")))))))

(ert-deftest claude-code-test-process-exit-reaches-the-kill-hook ()
  "A process exit retires the instance however the user configured Ghostel.
Stands in for the one branch of `ghostel--sentinel' this depends on: it kills
the buffer with the buffer current, so the buffer-local setting decides.  No pty
runs here, which is the point -- CI has none."
  (dolist (global '(t nil))
    (claude-code-tests--with-managed-buffer buf
      (let* ((fired 0)
             (ghostel-kill-buffer-on-exit global)
             (claude-code-last-instance-exit-hook
              (list (lambda () (cl-incf fired)))))
        (claude-code--register "id-s" buf "/r" nil)
        (with-current-buffer buf
          (when ghostel-kill-buffer-on-exit (kill-buffer buf)))
        (should-not (buffer-live-p buf))
        (should (zerop (hash-table-count claude-code--managed)))
        (should (= fired 1))))))

(ert-deftest claude-code-test-launch-ties-the-instance-to-its-buffer ()
  "The launch path makes the buffer both die with its process and report it.
Losing either half strands the entry: with no kill hook nothing retires it, and
with no buffer-local setting a user's global nil leaves the buffer alive after
its process exits, so no kill is ever coming."
  (claude-code-tests--with-registry
    (let ((execs '()))
      (claude-code-tests--recording-launch execs
        (let* ((fired 0)
               (claude-code-last-instance-exit-hook
                (list (lambda () (cl-incf fired))))
               (ghostel-kill-buffer-on-exit nil)
               (buffer (cdr (claude-code-spawn "/r"))))
          (should (eq t (buffer-local-value 'ghostel-kill-buffer-on-exit buffer)))
          (should (memq #'claude-code--on-buffer-kill
                        (buffer-local-value 'kill-buffer-hook buffer)))
          (kill-buffer buffer)
          (should (zerop (hash-table-count claude-code--managed)))
          (should (= fired 1)))))))

(ert-deftest claude-code-test-launch-enters-the-mode-before-the-spawn ()
  "The buffer is in `claude-code-instance-mode' by the time Ghostel spawns.
Ghostel refuses a mode change once the terminal process is live, so a launch
that left it until afterwards could not switch at all."
  (claude-code-tests--with-registry
    (let ((execs '())
          (at-exec nil))
      (claude-code-tests--recording-launch execs
        (let ((recorded (symbol-function 'ghostel-exec)))
          (cl-letf (((symbol-function 'ghostel-exec)
                     (lambda (buffer &rest args)
                       (setq at-exec (buffer-local-value 'major-mode buffer))
                       (apply recorded buffer args))))
            (claude-code-spawn "/r")
            (should (eq at-exec 'claude-code-instance-mode))))))))

(ert-deftest claude-code-test-launch-shared-by-spawn-and-resume ()
  "Spawn and resume host their instance through one launch path.
Both reach `ghostel-exec' with the MCP arguments threaded in, register the
instance, and put the buffer in `claude-code-instance-mode'; only the CLI
argument list differs."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      (let ((execs '())
            (buffers '())
            (spawned nil))
        (claude-code-tests--recording-launch execs
          (setq spawned (claude-code-spawn "/r" :worktree "feat" :model "opus"))
          (push (cdr spawned) buffers)
          (push (claude-code-resume "/r" "given-id") buffers)
          (let* ((calls (reverse execs))
                 (spawn-args (nth 1 (nth 0 calls)))
                 (resume-args (nth 1 (nth 1 calls)))
                 (spawned-id (nth 1 spawn-args)))
            (should (= (length calls) 2))
            ;; Resume ignores new-session options; spawn keeps them behind the
            ;; generated session id.
            (should (equal resume-args
                           '("--resume=given-id")))
            (should (equal (nth 0 spawn-args) "--session-id"))
            (should (string-match-p claude-code-tests--uuid-re spawned-id))
            ;; Spawn hands back that id with the buffer hosting it.
            (should (equal (car spawned) spawned-id))
            (should (eq (cdr spawned) (nth 0 (nth 0 calls))))
            (should (equal spawn-args
                           (list "--session-id" spawned-id
                                 "--worktree=feat" "--model" "opus")))
            ;; Both registered, each under its own buffer's PID; only spawn
            ;; recorded a worktree.
            (should (= (hash-table-count claude-code--managed) 2))
            (dolist (buffer buffers)
              (should (eq (plist-get (gethash (claude-code--instance-pid buffer)
                                              claude-code--managed)
                                     :buffer)
                          buffer)))
            (should (null (plist-get (claude-code-tests--entry "given-id")
                                     :worktree)))
            (should (equal (plist-get (claude-code-tests--entry spawned-id)
                                      :worktree)
                           "feat"))
            ;; Title tracking and status reports survive on both buffers.
            (should (= (length buffers) 2))
            (dolist (id (list "given-id" spawned-id))
              (let ((buffer (plist-get (claude-code-tests--entry id) :buffer)))
                (should (memq buffer buffers))
                (should (eq (buffer-local-value 'major-mode buffer)
                            'claude-code-instance-mode))
                (should (eq (buffer-local-value 'ghostel-buffer-name-function
                                                buffer)
                            #'claude-code--ghostel-buffer-name))
                (should (memq #'claude-code--on-status
                              (buffer-local-value
                               'ghostel-program-status-functions buffer)))))))))))

(ert-deftest claude-code-test-launch-leaves-the-renderer-to-claude ()
  "A launch naming no renderer touches neither renderer variable.
A `ghostel-pre-spawn-hook' the user put there themselves also comes through
the launch as they left it."
  (claude-code-tests--with-renderer-launch child-env
    (should (null (default-value 'claude-code-renderer)))
    (unwind-protect
        (progn
          (add-hook 'ghostel-pre-spawn-hook #'ignore)
          (claude-code-spawn "/r")
          (should (equal (default-value 'ghostel-pre-spawn-hook) '(ignore))))
      (remove-hook 'ghostel-pre-spawn-hook #'ignore))
    (should (equal (child-env claude-code-tests--alt-screen) "0"))
    (should (equal (child-env claude-code-tests--no-flicker) "0"))))

(ert-deftest claude-code-test-launch-forces-the-inline-renderer ()
  "`inline' hands the instance CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN.
Emacs's own environment keeps the value it had, and the hook that delivered
the new one is retired with the launch that installed it, or it would force
the renderer on every later Ghostel terminal."
  (claude-code-tests--with-renderer-launch child-env
    (let ((claude-code-renderer 'inline))
      (claude-code-spawn "/r")
      (should (equal (child-env claude-code-tests--alt-screen) "1"))
      (should (equal (getenv claude-code-tests--alt-screen) "0"))
      (should-not (default-value 'ghostel-pre-spawn-hook)))))

(ert-deftest claude-code-test-launch-forces-the-fullscreen-renderer ()
  "`fullscreen' adds CLAUDE_CODE_NO_FLICKER and drops the inherited ALT-SCREEN.
ALT-SCREEN abbreviates CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN, which the CLI
reads first: an inherited one would override `fullscreen' outright, so adding
NO_FLICKER is not enough.  It is dropped for the child, not out of Emacs's own
list."
  (claude-code-tests--with-renderer-launch child-env
    (let ((process-environment
           (cons (concat claude-code-tests--alt-screen "=1")
                 (copy-sequence process-environment)))
          (claude-code-renderer 'fullscreen))
      (claude-code-spawn "/r")
      (should (equal (child-env claude-code-tests--no-flicker) "1"))
      (should-not (child-env claude-code-tests--alt-screen))
      (should (equal (getenv claude-code-tests--alt-screen) "1"))
      (should-not (default-value 'ghostel-pre-spawn-hook)))))

(ert-deftest claude-code-test-launch-renderer-outlives-buffer-locals ()
  "The renderer reaches the instance from a calling buffer holding either local.
A `let' on `process-environment' is invisible in the instance's buffer once
`envrc' or `buffer-env' has made it local, as they do in every project buffer.
`add-hook' has the matching trap: it writes the calling buffer's local value
of `ghostel-pre-spawn-hook' when one exists without the `t' marker, where
`run-hooks' in the instance's fresh buffer would never see it."
  (claude-code-tests--with-renderer-launch child-env
    (let ((claude-code-renderer 'inline))
      (with-temp-buffer
        (setq-local process-environment (copy-sequence process-environment))
        (claude-code-spawn "/r")
        (should (equal (child-env claude-code-tests--alt-screen) "1")))
      (dolist (local (list (list #'ignore) (list #'ignore t)))
        (with-temp-buffer
          (setq-local ghostel-pre-spawn-hook local)
          (claude-code-spawn "/r")
          (should (equal (child-env claude-code-tests--alt-screen) "1"))
          ;; Delivered through the default value, leaving the local alone.
          (should (equal ghostel-pre-spawn-hook local)))))))

(ert-deftest claude-code-test-launch-hands-the-mcp-environment-to-the-instance ()
  "The environment the MCP wiring asks for reaches the instance and only it.
It travels the renderer's route, so it arrives alongside a renderer's and
Emacs's own environment never sees it."
  (claude-code-tests--with-renderer-launch child-env
    (let ((wired nil))
      (cl-letf (((symbol-function 'claude-code--mcp-wiring)
                 (lambda (buffer)
                   (setq wired buffer)
                   (cons nil (list (cons "CC_TEST_MCP_TOKEN" "t0k"))))))
        (dolist (renderer '(nil inline))
          (let ((claude-code-renderer renderer))
            ;; The token is minted for the buffer that hosts the instance.
            (should (eq (cdr (claude-code-spawn "/r")) wired))
            (should (equal (child-env "CC_TEST_MCP_TOKEN") "t0k"))
            (should (equal (child-env claude-code-tests--alt-screen)
                           (if renderer "1" "0")))
            (should-not (getenv "CC_TEST_MCP_TOKEN"))
            (should-not (default-value 'ghostel-pre-spawn-hook))))))))

(ert-deftest claude-code-test-launch-rejects-an-unknown-renderer ()
  "A `claude-code-renderer' naming no renderer stops the launch building anything.
Its `defcustom' type only guards `setopt' and Customize, so a `setq' still
reaches here, and neither the MCP server nor the buffer would be registered for
shutdown."
  (claude-code-tests--with-registry
    (let ((execs '())
          (mcp-calls 0)
          (buffers (buffer-list)))
      (claude-code-tests--recording-launch execs
        (cl-letf (((symbol-function 'claude-code--mcp-wiring)
                   (lambda (_buffer) (cl-incf mcp-calls) nil)))
          (let ((claude-code-renderer 'tui))
            (should-error (claude-code-spawn "/r") :type 'user-error)))
        (should (null execs))
        (should (zerop mcp-calls))
        (should-not (seq-difference (buffer-list) buffers))
        (should-not (bound-and-true-p ghostel-pre-spawn-hook))))))

(ert-deftest claude-code-test-resume-returns-existing ()
  "Resuming an already-managed live session returns it and spawns nothing."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let ((spawned nil))
        (claude-code--register "id-x" buf "/r" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (and (eq b buf) 'proc)))
                  ((symbol-function 'ghostel-exec)
                   (lambda (&rest _) (setq spawned t))))
          (should (eq (claude-code-resume "/r" "id-x") buf))
          (should-not spawned)
          ;; No second registry entry was created for the same id.
          (should (= (hash-table-count claude-code--managed) 1)))))))

(ert-deftest claude-code-test-resume-refuses-external ()
  "Resuming a session a `claude' outside Emacs is running is refused.
Fixture session 22222222 has sessions/1002.json, so pinning pid 1002 live
makes it external."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      (let ((execs '()))
        (claude-code-tests--recording-launch execs
          (claude-code-tests--with-live-pids '(1002)
            (should-error (claude-code-resume
                           "/home/test/proj"
                           "22222222-2222-4222-8222-222222222222")
                          :type 'user-error))
          ;; Nothing was launched, and with that pid gone it resumes normally.
          (should (null execs))
          (claude-code-tests--with-live-pids '()
            (claude-code-resume "/home/test/proj"
                                "22222222-2222-4222-8222-222222222222"))
          (should (= (length execs) 1)))))))

(ert-deftest claude-code-test-resume-returns-to-the-worktree ()
  "Resuming a session that left a worktree behind names it with `--worktree'.
Claude drops the binding on a clean exit and moves the transcript back under
the parent project, so the resume is launched from the parent root and has to
carry the worktree itself.  Once that worktree is gone the flag must go too:
`--worktree' would build a fresh checkout rather than resume in none."
  (let* ((root (file-truename (make-temp-file "cc-root" t)))
         (id "88888888-8888-4888-8888-888888888888")
         (config (make-temp-file "cc-config" t))
         (worktree (expand-file-name ".claude/worktrees/left" root))
         (project (expand-file-name (concat "projects/"
                                            (claude-code--encode-cwd root))
                                    config))
         (claude-code-config-dir config))
    (unwind-protect
        (progn
          (make-directory worktree t)
          (make-directory project t)
          (with-temp-file (expand-file-name (concat id ".jsonl") project)
            (insert (format "{\"type\":\"worktree-state\",\"worktreeSession\":\
{\"worktreePath\":\"%s\",\"worktreeName\":\"left\"},\"sessionId\":\"%s\"}\n"
                            worktree id))
            (insert (format "{\"type\":\"worktree-state\",\"worktreeSession\":\
null,\"sessionId\":\"%s\"}\n" id)))
          (claude-code-tests--with-registry
            (let ((execs '()))
              (claude-code-tests--recording-launch execs
                (clrhash claude-code--transcript-cache)
                (claude-code-resume root id)
                (should (equal (nth 1 (car execs))
                               (list "--worktree=left" (concat "--resume=" id))))
                ;; The worktree the session named is gone: resume plainly.
                (delete-directory worktree t)
                (clrhash claude-code--transcript-cache)
                (clrhash claude-code--managed)
                (setq execs '())
                (claude-code-resume root id)
                (should (equal (nth 1 (car execs))
                               (list (concat "--resume=" id))))))))
      (delete-directory root t)
      (delete-directory config t))))

(ert-deftest claude-code-test-kill ()
  "Killing an alive session drops its registry entry and buffer, and reports it.
The entry goes because the buffer died, so the instance is registered through
`claude-code--register', which is what wires that up."
  (claude-code-tests--with-managed-buffer buf
    (let* ((fired 0)
           (claude-code-last-instance-exit-hook
            (list (lambda () (cl-incf fired)))))
      (claude-code--register "id-k" buf "/r" nil)
      (claude-code-kill (claude-code-session--create
                         :id "id-k" :alive-p t :buffer buf))
      (should (zerop (hash-table-count claude-code--managed)))
      (should-not (buffer-live-p buf))
      (should (= fired 1)))
    ;; A dead session cannot be killed.
    (should-error (claude-code-kill
                   (claude-code-session--create :id "d" :alive-p nil))
                  :type 'user-error)))

(ert-deftest claude-code-test-kill-leaves-a-relaunched-instance-registered ()
  "Killing a stale struct does not unregister the instance that replaced it.
The struct names the buffer it was built from; once that instance has exited and
a resume has hosted the same session in another buffer, the registry belongs to
the new one.  Dropping it by id alone would orphan a running instance -- live,
but invisible to every query and to `claude-code--on-buffer-kill'."
  (claude-code-tests--with-registry
    (let ((old (generate-new-buffer " *cc-old*"))
          (new (generate-new-buffer " *cc-new*")))
      (with-current-buffer old (setq-local ghostel--pid 1))
      (with-current-buffer new (setq-local ghostel--pid 2))
      (unwind-protect
          (progn
            (claude-code--register "id-r" old "/r" nil)
            (let* ((fired 0)
                   (claude-code-last-instance-exit-hook
                    (list (lambda () (cl-incf fired))))
                   (stale (claude-code-session--create
                           :id "id-r" :alive-p t :buffer old)))
              (kill-buffer old)
              (should (= fired 1))
              (claude-code--register "id-r" new "/r" nil)
              (claude-code-kill stale)
              (should (eq (plist-get (claude-code-tests--entry "id-r") :buffer)
                          new))
              (should (buffer-live-p new))))
        (dolist (buffer (list old new))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest claude-code-test-rename ()
  "Rename pastes exactly the /rename slash command, then submits."
  (claude-code-tests--with-managed-buffer buf
    (let ((calls '()))
      (claude-code-tests--recording-ghostel calls
        (claude-code-rename
         (claude-code-session--create :id "s" :alive-p t :buffer buf)
         "My Name"))
      (should (equal (reverse calls)
                     '((paste "/rename My Name") (key "return"))))
      ;; Renaming a dead session is refused.
      (should-error (claude-code-rename
                     (claude-code-session--create :id "d" :alive-p nil) "x")
                    :type 'user-error))))

(ert-deftest claude-code-test-send-text ()
  "Text is pasted, never typed, whatever its length; RET only when submitting."
  (claude-code-tests--with-managed-buffer buf
    (let ((calls '())
          (s (claude-code-session--create :id "s" :alive-p t :buffer buf)))
      (claude-code-tests--recording-ghostel calls
        ;; No submit: pasted, no RET.
        (setq calls nil)
        (claude-code-send-text s "hello")
        (should (equal (reverse calls) '((paste "hello"))))
        ;; Submit: pasted, then RET, whatever the text's length or lines.
        (dolist (text (list "hi" (make-string 100 ?x) "a\nb"))
          (setq calls nil)
          (claude-code-send-text s text t)
          (should (equal (reverse calls) `((paste ,text) (key "return")))))
        ;; Empty text: nothing is pasted, so a submit is the RET alone.
        (setq calls nil)
        (claude-code-send-text s "" t)
        (should (equal (reverse calls) '((key "return"))))))))

(ert-deftest claude-code-test-status-display-unknown ()
  "An unrecognised non-nil status is surfaced verbatim; nil stays `alive'."
  (should (equal (car (claude-code--status-display
                       (claude-code-session--create :alive-p t :status "frobbing")))
                 "unknown (frobbing)"))
  (should (equal (car (claude-code--status-display
                       (claude-code-session--create :alive-p t :status nil)))
                 "alive")))

(ert-deftest claude-code-test-delete-guards-and-happy-path ()
  "Delete removes a dead transcript but refuses unsafe deletions."
  (let ((file (make-temp-file "cc-transcript" nil ".jsonl")))
    (unwind-protect
        (claude-code-tests--with-fixtures
          (claude-code-tests--with-registry
            ;; Alive sessions cannot be deleted.
            (should-error (claude-code-delete
                           (claude-code-session--create :id "a" :alive-p t))
                          :type 'user-error)
            ;; Externally-running sessions cannot be deleted.
            (should-error (claude-code-delete
                           (claude-code-session--create
                            :id "b" :alive-p nil :external-p t :transcript file))
                          :type 'user-error)
            ;; A dead session with a transcript is deleted.
            (should (file-exists-p file))
            (claude-code-delete (claude-code-session--create
                                 :id "c" :alive-p nil :transcript file))
            (should-not (file-exists-p file))
            ;; A missing transcript errors rather than silently succeeding.
            (should-error (claude-code-delete
                           (claude-code-session--create
                            :id "d" :alive-p nil :transcript file))
                          :type 'user-error)))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest claude-code-test-delete-refuses-a-session-resumed-since-the-query ()
  "Delete re-checks by id instead of trusting the struct it is handed.
A struct's flags are only as fresh as the query that built it: resume the
session afterwards and the struct still says dead, while a `claude' is running
it.  Both the registry and the sessions/ pid are consulted by id, so neither a
resumed instance nor one started outside Emacs loses its transcript.  Any
unlink here is a hard failure, not a deleted fixture."
  (let ((file (make-temp-file "cc-transcript" nil ".jsonl")))
    (unwind-protect
        (claude-code-tests--with-fixtures
          (cl-letf (((symbol-function 'claude-code--delete-transcript)
                     (lambda (f) (error "Unlinked a running session's %s" f))))
            ;; Resumed since the query: the registry holds a live instance.
            (claude-code-tests--with-managed-buffer buf
              (claude-code--register "resumed" buf "/home/test/proj" nil)
              (cl-letf (((symbol-function 'claude-code--session-process)
                         (lambda (b) (eq b buf))))
                (should-error (claude-code-delete
                               (claude-code-session--create
                                :id "resumed" :alive-p nil :transcript file))
                              :type 'user-error)))
            ;; Started outside Emacs since the query: sessions/1002.json (pid
            ;; 1002) appeared for session 22222222.
            (claude-code-tests--with-registry
              (claude-code-tests--with-live-pids '(1002)
                (should-error
                 (claude-code-delete
                  (claude-code-session--create
                   :id "22222222-2222-4222-8222-222222222222"
                   :alive-p nil :transcript file))
                 :type 'user-error)))))
      (when (file-exists-p file) (delete-file file)))))

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
answers lasts until its input closes, and SIGTERM ends it whole."
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

(ert-deftest claude-code-test-export-transcript ()
  "An export asks the CLI for the text and hands it over, once.
It runs with its own config dir, in the directory the session works in, and
closes the CLI's input once answered, which is what lets the CLI exit.  Lines
that answer nothing of ours are passed over."
  (claude-code-tests--with-fake-cli (session root log)
      (concat "read -r request\n"
              "{ pwd; printf '%s\\n' \"$CLAUDE_CONFIG_DIR\" \"$request\" \"$@\"; }"
              " > \"$0.log\"\n"
              "echo 'not json'\n"
              "echo '{\"type\":\"control_response\",\"response\":"
              "{\"subtype\":\"success\",\"request_id\":\"other\","
              "\"response\":{\"text\":\"not ours\"}}}'\n"
              "echo '" claude-code-tests--export-answer "'\n"
              "exec cat >/dev/null\n")
    (pcase-let ((`(,calls . ,proc) (claude-code-tests--export session root)))
      (should (equal calls '((text "\n● Because you asked.\n  Twice."))))
      (should (eq (process-status proc) 'exit))
      (should (= (process-exit-status proc) 0))
      (should-not (claude-code-tests--export-processes))
      (let ((logged (with-temp-buffer
                      (insert-file-contents log)
                      (split-string (buffer-string) "\n" t))))
        (should (equal (nth 0 logged) root))
        (should (equal (nth 1 logged)
                       (expand-file-name claude-code-export-config-dir)))
        (should (equal (json-parse-string (nth 2 logged) :object-type 'alist)
                       '((type . "control_request")
                         (request_id . "claude-code")
                         (request (subtype . "export_conversation")))))
        (should (equal (nthcdr 3 logged)
                       (list "-p" "--safe-mode"
                             "--input-format" "stream-json"
                             "--output-format" "stream-json" "--verbose"
                             "--no-session-persistence"
                             (concat "--resume="
                                     (claude-code-session-transcript
                                      session)))))))))

(ert-deftest claude-code-test-export-transcript-reports-a-failure ()
  "An export the CLI cannot answer reports why, once, and leaves no process.
The CLI's own account comes first: an error answer, or a failed run's result,
which for a transcript holding no conversation names a session id the CLI made
up.  A CLI that dies with neither is described by its stderr, all of it, and
failing that by how it ended."
  (pcase-dolist (`(,script ,message)
                 `((,(concat "read -r r\n"
                             "echo '{\"type\":\"control_response\",\"response\":"
                             "{\"subtype\":\"error\",\"request_id\":\"claude-code\","
                             "\"error\":\"Unsupported control request subtype: "
                             "export_conversation\"}}'\n"
                             "exec cat >/dev/null\n")
                    "Unsupported control request subtype: export_conversation")
                   (,(concat "read -r r\n"
                             "echo 'No conversation found with session ID: 0f' >&2\n"
                             "echo '{\"type\":\"result\",\"subtype\":"
                             "\"error_during_execution\",\"is_error\":true,"
                             "\"errors\":[\"No conversation found with session ID: 0f\"]}'\n"
                             "exit 1\n")
                    "No conversation to export")
                   (,(concat "echo \"error: unknown option '--safe-mode'\" >&2\n"
                             "exit 1\n")
                    "%s ended with no transcript: error: unknown option '--safe-mode'")
                   ;; More than the pipe holds, so the CLI ends with the tail
                   ;; still unread.
                   (,(concat "read -r r\n"
                             "head -c 300000 /dev/zero | tr '\\0' x >&2\n"
                             "echo ' last words' >&2\n"
                             "exit 1\n")
                    ,(concat "%s ended with no transcript: "
                             (make-string 300000 ?x) " last words"))
                   (,(concat "read -r r\n" "exit 0\n")
                    "%s ended with no transcript: finished")))
    (claude-code-tests--with-fake-cli (session root _log) script
      (pcase-let ((`(,calls . ,proc) (claude-code-tests--export session root)))
        (should (equal calls
                       (list (list 'error (format message claude-code-cli)))))
        (should-not (process-live-p proc))
        (should-not (claude-code-tests--export-processes))))))

(ert-deftest claude-code-test-export-transcript-times-out ()
  "A CLI that never answers is given up on, reported, and terminated."
  (claude-code-tests--with-fake-cli (session root _log)
      "read -r r\nexec cat >/dev/null\n"
    (let ((claude-code--export-timeout 0.3))
      (pcase-let ((`(,calls . ,proc) (claude-code-tests--export session root)))
        (should (equal calls '((error "Export timed out after 0.3s"))))
        (should (eq (process-status proc) 'signal))
        (should-not (claude-code-tests--export-processes))))))

(ert-deftest claude-code-test-export-transcript-ends-a-lingering-cli ()
  "A CLI the closed input does not end is ended at the timeout, unheard."
  (claude-code-tests--with-fake-cli (session root _log)
      (concat "read -r r\n"
              "echo '" claude-code-tests--export-answer "'\n"
              "exec sleep 100\n")
    (let ((claude-code--export-timeout 0.5))
      (pcase-let ((`(,calls . ,proc) (claude-code-tests--export session root)))
        (should (equal calls '((text "\n● Because you asked.\n  Twice."))))
        (should (eq (process-status proc) 'signal))
        (should-not (claude-code-tests--export-processes))))))

(ert-deftest claude-code-test-export-transcript-cli-gone-before-asked ()
  "A request that cannot be written is signalled, and no callback follows."
  (claude-code-tests--with-fake-cli (session root _log)
      "read -r r\nexec cat >/dev/null\n"
    (let ((claude-code--export-timeout 0.3)
          (calls '()))
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (&rest _) (error "Process claude-code-export not running"))))
        (should-error (claude-code-export-transcript
                       session root
                       (lambda (text) (push text calls))
                       (lambda (msg) (push msg calls)))))
      (should (claude-code-tests--await
               (lambda () (not (claude-code-tests--export-processes))) 5))
      (claude-code-tests--await (lambda () calls) 0.5)
      (should-not calls))))

(ert-deftest claude-code-test-export-transcript-cancel ()
  "A cancelled export calls neither callback, and its process ends."
  (claude-code-tests--with-fake-cli (session root _log)
      (concat "read -r r\nsleep 0.3\n"
              "echo '" claude-code-tests--export-answer "'\n"
              "exec cat >/dev/null\n")
    (let* ((calls '())
           (proc (claude-code-export-transcript
                  session root
                  (lambda (text) (push text calls))
                  (lambda (msg) (push msg calls)))))
      (claude-code--export-cancel proc)
      (should (claude-code-tests--await (lambda () (not (process-live-p proc))) 5))
      (claude-code-tests--await (lambda () calls) 0.5)
      (should-not calls)
      (should-not (claude-code-tests--export-processes)))))

(ert-deftest claude-code-test-export-transcript-of-any-length ()
  "The answer is one line as long as the transcript, read in many pieces.
Multibyte text split across those pieces must come out whole."
  (claude-code-tests--with-fake-cli (session root log)
      "read -r r\ncat \"$0.log\"\nexec cat >/dev/null\n"
    (let ((text (apply #'concat (make-list 30000 "● ─── text\n"))))
      ;; `json-serialize' hands back the UTF-8 bytes themselves.
      (let ((coding-system-for-write 'no-conversion))
        (write-region (concat (json-serialize
                               `((type . "control_response")
                                 (response (subtype . "success")
                                           (request_id . "claude-code")
                                           (response (text . ,text)))))
                              "\n")
                      nil log))
      (should (> (file-attribute-size (file-attributes log))
                 (* 4 read-process-output-max)))
      (should (equal (car (claude-code-tests--export session root))
                     (list (list 'text text)))))))

(ert-deftest claude-code-test-export-outcome ()
  "Only an answer to our request, or a failed result, settles an export."
  (pcase-dolist (`(,line ,outcome)
                 `((,claude-code-tests--export-answer
                    (text . "\n● Because you asked.\n  Twice."))
                   (,(concat "{\"type\":\"control_response\",\"response\":"
                             "{\"subtype\":\"success\",\"request_id\":\"claude-code\","
                             "\"response\":{}}}")
                    (error . "malformed answer"))
                   (,(concat "{\"type\":\"result\",\"subtype\":"
                             "\"error_during_execution\",\"is_error\":true,"
                             "\"errors\":[]}")
                    (error . "error_during_execution"))
                   ("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}"
                    nil)
                   ("{\"type\":\"system\",\"subtype\":\"init\"}" nil)
                   ("[1]" nil)
                   ("Warning: something" nil)))
    (should (equal (claude-code--export-outcome line) outcome))))

(ert-deftest claude-code-test-export-file ()
  "An export reads the transcript where it lies now.
Claude moves a transcript after the directory it files the session under, so a
path the session recorded may be gone; the session's id finds it again."
  (claude-code-tests--with-fixtures
    (let ((id "99999999-9999-4999-8999-999999999999")
          (file (make-temp-file "cc-transcript" nil ".jsonl")))
      (unwind-protect
          (progn
            (should (equal (claude-code--export-file
                            (claude-code-session--create :id id :transcript file)
                            "/home/test/proj")
                           file))
            (should (equal (claude-code--export-file
                            (claude-code-session--create
                             :id id :transcript "/gone/x.jsonl")
                            "/home/test/proj")
                           (expand-file-name
                            (concat "projects/-home-test-proj/" id ".jsonl")
                            claude-code-tests--fixtures)))
            (should (equal (should-error (claude-code--export-file
                                          (claude-code-session--create :id "new")
                                          "/home/test/proj")
                                         :type 'user-error)
                           '(user-error "No transcript on disk for session new"))))
        (delete-file file)))))

;;;; Notifications

(defmacro claude-code-tests--capturing-timers (log &rest body)
  "Run BODY with `run-at-time' and `cancel-timer' recording onto LOG.
Scheduling records (scheduled SECS FN TIMER) and answers a TIMER of its own;
cancelling records (cancelled TIMER).  Nothing is really scheduled, so a test
reaches a timeout by funcalling the thunk it recorded -- and because a cancel
is recorded rather than ignored, a timer left running is visible to a test
instead of leaking silently."
  (declare (indent 1))
  (let ((seq (gensym "seq")))
    `(let ((,seq 0))
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (secs _repeat fn &rest _)
                    (let ((timer (list 'timer (cl-incf ,seq))))
                      (push (list 'scheduled secs fn timer) ,log)
                      timer)))
                 ((symbol-function 'cancel-timer)
                  (lambda (timer) (push (list 'cancelled timer) ,log))))
         ,@body))))

(defun claude-code-tests--scheduled-at (log secs)
  "Return the newest (scheduled SECS FN TIMER) entry in LOG, or nil."
  (seq-find (lambda (entry)
              (and (eq (nth 0 entry) 'scheduled) (equal (nth 1 entry) secs)))
            log))

(defun claude-code-tests--thunk-at (log secs)
  "Return the newest thunk LOG recorded as scheduled at SECS, or nil."
  (nth 2 (claude-code-tests--scheduled-at log secs)))

(defun claude-code-tests--timer-at (log secs)
  "Return the newest timer LOG recorded as scheduled at SECS, or nil."
  (nth 3 (claude-code-tests--scheduled-at log secs)))

(defun claude-code-tests--cancelled (log)
  "Return every timer LOG recorded as cancelled."
  (mapcar (lambda (entry) (nth 1 entry))
          (seq-filter (lambda (entry) (eq (nth 0 entry) 'cancelled)) log)))

(defmacro claude-code-tests--following (raised log &rest body)
  "Run BODY with a follow's surroundings stubbed, recording timers onto LOG.
RAISED is read on every check of whether the desktop raised Emacs, so a test
moves focus by setting it.  The focus hook and the claimed activation window
are bound per test, so a watcher never outlives the test that installed it."
  (declare (indent 2))
  `(let ((after-focus-change-function #'ignore)
         (claude-code--notify-claim nil))
     (cl-letf (((symbol-function 'claude-code--focused-p) (lambda () ,raised)))
       (claude-code-tests--capturing-timers ,log ,@body))))

(ert-deftest claude-code-test-install-notifications ()
  "An instance's buffer hands its status reports to the notification tracker.
Ghostel's announcement of them and its OSC 9/777 notifications are silenced
buffer-locally, so terminals this package does not manage keep the user's
handlers.  The status hook still runs its global entries -- the mode-line
indicator among them.  The buffer's window changes and every focus change
watch for the instance being seen."
  (claude-code-tests--with-managed-buffer buf
    (let ((after-focus-change-function #'ignore))
      (claude-code--install-notifications buf)
      (with-current-buffer buf
        (should (local-variable-p 'ghostel-notification-functions))
        (should (null ghostel-notification-functions))
        (should (local-variable-p 'ghostel-status-notify-states))
        (should (null ghostel-status-notify-states))
        (should (memq #'claude-code--on-status ghostel-program-status-functions))
        (should (memq t ghostel-program-status-functions))
        (should (local-variable-p 'window-buffer-change-functions))
        (should (memq #'claude-code--schedule-seen
                      window-buffer-change-functions)))
      (should-not (memq #'claude-code--on-status
                        (default-value 'ghostel-program-status-functions)))
      (should (advice-function-member-p #'claude-code--schedule-seen
                                        after-focus-change-function)))))

(defmacro claude-code-tests--reporting (buf log now &rest body)
  "Run BODY in BUF as its status reports arrive, recording timers onto LOG.
NOW is read as the time on every clock reading, so a test moves time by
setting it.  BUF starts with no status record and no notification up."
  (declare (indent 3))
  `(with-current-buffer ,buf
     (setq-local ghostel-program-status nil)
     (cl-letf (((symbol-function 'float-time) (lambda (&rest _) ,now)))
       (claude-code-tests--capturing-timers ,log ,@body))))

(defun claude-code-tests--status (buf state &rest props)
  "Report root STATE with PROPS to the instance in BUF, as Ghostel would.
BUF's root record becomes the report -- a nil STATE removes it -- and
`claude-code--on-status' is handed the record it replaced and the new one,
with BUF current."
  (with-current-buffer buf
    (let ((old (cdr (assoc "" ghostel-program-status)))
          (new (and state `(:state ,state ,@props))))
      (setq ghostel-program-status (and new (list (cons "" new))))
      (claude-code--on-status "" old new))))

(defun claude-code-tests--live-timers (log)
  "Return the thunks LOG recorded as scheduled and never cancelled."
  (let ((cancelled (claude-code-tests--cancelled log)))
    (mapcar (lambda (entry) (nth 2 entry))
            (seq-filter (lambda (entry)
                          (and (eq (nth 0 entry) 'scheduled)
                               (not (member (nth 3 entry) cancelled))))
                        log))))

(ert-deftest claude-code-test-on-status-announces-the-root-only ()
  "Only the root record entering `done', `blocked' or `error' is announced.
A child record is a subagent, whose state says nothing about whether the
session needs the user; a report repeating the root's state asks nothing new.
The announcement waits out `claude-code--notify-settle'."
  (claude-code-tests--with-managed-buffer buf
    (let ((log '()) (now 100.0))
      (claude-code-tests--reporting buf log now
        (claude-code--on-status "a93609d08ab42add7" nil
                                '(:state blocked :kind question))
        (claude-code--on-status "a93609d08ab42add7"
                                '(:state blocked :kind question)
                                '(:state done))
        (claude-code-tests--status buf 'working)
        (should (null (claude-code-tests--live-timers log)))
        (claude-code-tests--status buf 'blocked :kind 'permission)
        (claude-code-tests--status buf 'blocked :kind 'permission :msg "m")
        (should (= (length (claude-code-tests--live-timers log)) 1))
        (should (claude-code-tests--thunk-at log claude-code--notify-settle))))))

(defmacro claude-code-tests--announcing (buf shell seen &rest body)
  "Run BODY with BUF a running instance, announcing onto SEEN.
SHELL is read as whether the sessions/ status of BUF's process reports a
background shell command, so a test moves it by setting it.  Each announcement
pushes its body."
  (declare (indent 3))
  `(cl-letf (((symbol-function 'claude-code--session-process)
              (lambda (b) (eq b ,buf)))
             ((symbol-function 'claude-code--pid-info)
              (lambda (pid)
                (and (eql pid (claude-code--instance-pid ,buf))
                     (list :shell-p ,shell))))
             ((symbol-function 'claude-code--notify)
              (lambda (_buffer body) (push body ,seen))))
     ,@body))

(defun claude-code-tests--settle (log)
  "Fire the one announcement LOG holds pending."
  (let ((pending (claude-code-tests--live-timers log)))
    (should (= (length pending) 1))
    (funcall (car pending))))

(ert-deftest claude-code-test-announce-times-the-stretch-of-work ()
  "A finished turn is announced with how long the instance worked for it.
The stretch is timed from the root setting to work after resting to the
moment `done' was reported, not to the end of the settling wait."
  (claude-code-tests--with-managed-buffer buf
    (let ((log '()) (seen '()) (now 1000.0) (shell nil))
      (claude-code-tests--announcing buf shell seen
        (claude-code-tests--reporting buf log now
          (claude-code-tests--status buf 'working)
          (setq now 1252.0)
          (claude-code-tests--status buf 'done)
          (setq now 1252.5)
          (claude-code-tests--settle log)
          (should (equal seen '("Finished after 4m 12s")))
          (should-not claude-code--working-since))))))

(ert-deftest claude-code-test-announce-waits-out-a-background-shell ()
  "A `done' with a background shell command still running is no finished turn.
Claude reports the turn done, but its sessions/ status reads `shell' until the
command's completion has started and ended the next turn; only that `done'
is announced, and the stretch it times includes the command."
  (claude-code-tests--with-managed-buffer buf
    (let ((log '()) (seen '()) (now 1000.0) (shell t))
      (claude-code-tests--announcing buf shell seen
        (claude-code-tests--reporting buf log now
          (claude-code-tests--status buf 'working)
          (setq now 1003.0)
          (claude-code-tests--status buf 'done)
          (claude-code-tests--settle log)
          (should (null seen))
          (should (= claude-code--working-since 1000.0))
          ;; The command completes and starts the next turn by itself.
          (setq now 1020.0 log '())
          (claude-code-tests--status buf 'working)
          (setq now 1021.0 shell nil)
          (claude-code-tests--status buf 'done)
          (claude-code-tests--settle log)
          (should (equal seen '("Finished after 21s"))))))))

(ert-deftest claude-code-test-announce-only-what-still-holds ()
  "A state the root leaves during the settling wait is never announced.
A permission prompt resolved without the user, or a `done' the user already
acknowledged by typing, has nothing left to ask for, and a state left and
re-entered inside the wait is announced once.  An instance that exited by then
announces nothing."
  (claude-code-tests--with-managed-buffer buf
    (let ((log '()) (seen '()) (now 1000.0) (shell nil))
      (claude-code-tests--announcing buf shell seen
        (claude-code-tests--reporting buf log now
          (claude-code-tests--status buf 'blocked :kind 'permission)
          (claude-code-tests--status buf 'working)
          (claude-code-tests--status buf 'done)
          (claude-code-tests--status buf nil)
          (should (null (claude-code-tests--live-timers log)))
          (claude-code-tests--status buf 'working)
          (claude-code-tests--status buf 'done)
          (claude-code-tests--status buf 'working)
          (claude-code-tests--status buf 'done)
          (claude-code-tests--settle log)
          (should (equal seen '("Finished")))
          (with-temp-buffer
            (claude-code--announce (current-buffer) 'done now))
          (should (equal seen '("Finished"))))))))

(ert-deftest claude-code-test-announce-reads-its-own-process ()
  "Whether a background shell keeps the turn going is read by the instance's PID.
Pid 1006's sessions/ file reads `shell' and pid 1001's does not."
  (claude-code-tests--with-fixtures
    (dolist (case '((1006 . nil) (1001 . ("Finished"))))
      (claude-code-tests--with-managed-buffer (buf (car case))
        (let ((seen '()))
          (cl-letf (((symbol-function 'claude-code--session-process)
                     (lambda (b) (eq b buf)))
                    ((symbol-function 'claude-code--notify)
                     (lambda (_buffer body) (push body seen))))
            (claude-code--announce buf 'done 1000.0)
            (should (equal seen (cdr case)))))))))

(ert-deftest claude-code-test-announce-shows-claude-s-message ()
  "Claude's own message is the body whenever it sent one.
A `blocked' report says what the instance waits on and keeps the stretch of
work going; an `error' says what failed and ends it."
  (claude-code-tests--with-managed-buffer buf
    (let ((log '()) (seen '()) (now 1000.0) (shell nil))
      (claude-code-tests--announcing buf shell seen
        (claude-code-tests--reporting buf log now
          (claude-code-tests--status buf 'working)
          (claude-code-tests--status buf 'blocked :kind 'permission
                                     :msg "approve Write: /tmp/x")
          (claude-code-tests--settle log)
          (should (equal seen '("approve Write: /tmp/x")))
          (should (= claude-code--working-since 1000.0))
          (setq log '())
          (claude-code-tests--status buf 'error :msg "There's an issue")
          (claude-code-tests--settle log)
          (should (equal (car seen) "There's an issue"))
          (should-not claude-code--working-since))))))

(ert-deftest claude-code-test-on-status-ends-the-stretch-at-rest ()
  "An interrupt or an acknowledged record ends the stretch of work.
Claude reports an interrupted turn `idle'; Ghostel drops a `done' the user
acknowledged by typing, which reaches the hook as no record at all."
  (claude-code-tests--with-managed-buffer buf
    (let ((log '()) (now 1000.0))
      (claude-code-tests--reporting buf log now
        (dolist (rest '(idle nil))
          (claude-code-tests--status buf 'working)
          (should (= claude-code--working-since 1000.0))
          (claude-code-tests--status buf rest)
          (should-not claude-code--working-since))))))

(ert-deftest claude-code-test-on-status-closes-what-it-announced ()
  "A notification closes once the root leaves the state it announced.
A permission the user granted in the terminal, or a `done' acknowledged there,
leaves a banner that asks for nothing."
  (claude-code-tests--with-managed-buffer buf
    (let ((log '()) (now 1000.0) (closed '()))
      (cl-letf (((symbol-function 'claude-code--close-notification)
                 (lambda (id) (push id closed))))
        (claude-code-tests--reporting buf log now
          (claude-code-tests--status buf 'blocked :kind 'permission)
          (setq claude-code--posted (list 7))
          ;; The prompt's message changes; the state it announced holds.
          (claude-code-tests--status buf 'blocked :kind 'permission :msg "m")
          (should (null closed))
          (claude-code-tests--status buf 'working)
          (should (equal closed '(7)))
          (should (null claude-code--posted)))))))

(ert-deftest claude-code-test-seeing-an-instance-closes-its-notifications ()
  "Notifications close once their instance is on screen, from a timer.
A burst of window and focus changes schedules one close, which spares the
instances still out of sight."
  (claude-code-tests--with-managed-buffer seen
    (claude-code-tests--with-managed-buffer (hidden 4243)
      (let ((log '()) (closed '()) (claude-code--seen-timer nil)
            (gone (generate-new-buffer " *cc-gone*")))
        (claude-code--register "id-1" seen "/home/test/proj" nil)
        (claude-code--register "id-2" hidden "/home/test/proj" nil)
        ;; An entry whose buffer died without retiring it is skipped.
        (puthash 4244 (list :buffer gone :session "id-3") claude-code--managed)
        (kill-buffer gone)
        (with-current-buffer seen (setq claude-code--posted (list 1 2)))
        (with-current-buffer hidden (setq claude-code--posted (list 3)))
        (cl-letf (((symbol-function 'claude-code--close-notification)
                   (lambda (id) (push id closed)))
                  ((symbol-function 'claude-code--on-screen-p)
                   (lambda (buffer) (eq buffer seen))))
          (claude-code-tests--capturing-timers log
            (claude-code--schedule-seen (selected-window))
            (claude-code--schedule-seen)
            (should (= (length (claude-code-tests--live-timers log)) 1))
            (should (null closed))
            (funcall (claude-code-tests--thunk-at log 0))
            (should (equal (sort closed #'<) '(1 2)))
            (should (null (buffer-local-value 'claude-code--posted seen)))
            (should (equal (buffer-local-value 'claude-code--posted hidden)
                           '(3)))
            (should-not claude-code--seen-timer)))))))

(ert-deftest claude-code-test-last-exit-stops-watching-focus ()
  "Focus changes stop being watched once the last instance exits."
  (claude-code-tests--with-managed-buffer buf
    (let ((after-focus-change-function #'ignore))
      (claude-code--register "id-1" buf "/home/test/proj" nil)
      (claude-code--install-notifications buf)
      (should (advice-function-member-p #'claude-code--schedule-seen
                                        after-focus-change-function))
      (kill-buffer buf)
      (should-not (advice-function-member-p #'claude-code--schedule-seen
                                            after-focus-change-function)))))

(ert-deftest claude-code-test-close-notification-does-not-wait ()
  "A close asks for no answer, so nothing waits on D-Bus for one.
A close that cannot be sent is only reported."
  (skip-unless (featurep 'dbusbind))
  (require 'notifications)
  (let ((sent '()))
    (cl-letf (((symbol-function 'dbus-call-method-asynchronously)
               (lambda (&rest args)
                 (push args sent)
                 (signal 'dbus-error '("No connection to bus")))))
      ;; ERT debugs every error; a session left to run would not.
      (let ((debug-on-error nil))
        (claude-code--close-notification 7)))
    (should (equal sent
                   `((:session ,notifications-service ,notifications-path
                      ,notifications-interface
                      ,notifications-close-notification-method
                      nil :uint32 7))))))

(ert-deftest claude-code-test-status-message ()
  "A report Claude sent without a message is described by its state.
A turn under a second, or one of unknown start, reads as finished, and a
duration names no unit past its last non-zero one."
  (should (equal (claude-code--status-message 'done 1000.0 1012.4)
                 "Finished after 12s"))
  (should (equal (claude-code--status-message 'done 1000.0 1060.0)
                 "Finished after 1m"))
  (should (equal (claude-code--status-message 'done 1000.0 4725.0)
                 "Finished after 1h 2m 5s"))
  (should (equal (claude-code--status-message 'done 1000.0 1000.4) "Finished"))
  (should (equal (claude-code--status-message 'done nil 1000.0) "Finished"))
  (should (equal (claude-code--status-message 'blocked 1000.0 1001.0)
                 "Waiting for you"))
  (should (equal (claude-code--status-message 'error 1000.0 1001.0)
                 "Stopped on an error")))

(ert-deftest claude-code-test-frame-focused-p ()
  "Focus is a `t' focus state on a visible frame, and nothing else."
  (let ((visible (list (cons 'f t)))
        (state (list (cons 'f t))))
    (cl-letf (((symbol-function 'frame-visible-p)
               (lambda (frame) (alist-get frame visible)))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional frame) (alist-get frame state))))
      (should (claude-code--frame-focused-p 'f))
      ;; A platform that cannot tell is not focus.
      (setf (alist-get 'f state) 'unknown)
      (should-not (claude-code--frame-focused-p 'f))
      (setf (alist-get 'f state) nil)
      (should-not (claude-code--frame-focused-p 'f))
      ;; Minimized while the window manager owed it a focus-out, and made
      ;; invisible.
      (setf (alist-get 'f state) t)
      (setf (alist-get 'f visible) 'icon)
      (should-not (claude-code--frame-focused-p 'f))
      (setf (alist-get 'f visible) nil)
      (should-not (claude-code--frame-focused-p 'f)))))

(ert-deftest claude-code-test-focused-p ()
  "Focus is decided over every frame, not just the selected one.
`frame-focus-state' answers for one frame and more than one can report focus,
so a raise landing on a frame other than the selected one still counts."
  (let ((states (list (cons 'f1 nil) (cons 'f2 nil))))
    (cl-letf (((symbol-function 'frame-list) (lambda () '(f1 f2)))
              ((symbol-function 'frame-visible-p) (lambda (_frame) t))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional frame) (alist-get frame states))))
      (should-not (claude-code--focused-p))
      ;; Focus on the frame that is not first in the list still counts.
      (setf (alist-get 'f2 states) t)
      (should (claude-code--focused-p)))))

(ert-deftest claude-code-test-on-screen-p ()
  "A buffer is on screen when a focused frame shows it, selected or not.
Every window showing it is tested, since the same instance can sit on an
unfocused frame and a focused one at once, and looking only at the window that
happens to come first would miss that."
  (claude-code-tests--with-managed-buffer buf
    (let ((windows (list 'elsewhere 'here))
          (frames '((elsewhere . f1) (here . f2)))
          (states (list (cons 'f1 nil) (cons 'f2 t))))
      (cl-letf (((symbol-function 'get-buffer-window-list)
                 (lambda (&rest _) windows))
                ((symbol-function 'window-frame)
                 (lambda (window) (alist-get window frames)))
                ((symbol-function 'frame-visible-p) (lambda (_frame) t))
                ((symbol-function 'frame-focus-state)
                 (lambda (&optional frame) (alist-get frame states))))
        ;; No frame here has a selected window: the predicate asks for none.
        (should (claude-code--on-screen-p buf))
        ;; Every frame showing it lost focus.
        (setf (alist-get 'f2 states) nil)
        (should-not (claude-code--on-screen-p buf))
        ;; Displayed in no window at all.
        (setf (alist-get 'f2 states) t)
        (setq windows '())
        (should-not (claude-code--on-screen-p buf))))))

(ert-deftest claude-code-test-notify-hands-over-a-session ()
  "A notification reaches the handler as the session it came from, plus the body.
The session is built when the notification fires, so it carries the session,
name and status the instance has now rather than a cached one -- pid 1001 was
launched on another session and runs 11111111 now."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer (buf 1001)
      (let* ((id "11111111-1111-4111-8111-111111111111")
             (seen '())
             (claude-code-notify-function
              (lambda (session body) (push (cons session body) seen))))
        (claude-code--register "launched" buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf)))
                  ((symbol-function 'claude-code--on-screen-p) #'ignore))
          (claude-code--notify buf "Finished after 4m 12s"))
        (should (= (length seen) 1))
        (pcase-let ((`(,session . ,body) (car seen)))
          (should (equal body "Finished after 4m 12s"))
          (should (equal (claude-code-session-id session) id))
          (should (eq (claude-code-session-buffer session) buf))
          (should (claude-code-session-alive-p session))
          (should (equal (claude-code-session-status session) "busy"))
          (should (equal (claude-code--session-display-name session)
                         "Understand the project layout")))))))

(ert-deftest claude-code-test-notify-names-a-session-of-a-sibling-worktree ()
  "An instance launched from a worktree names a session filed under a sibling.
Its transcript is filed under the project's other worktree, which only the
parent project lists, so that is where the name is looked up."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let* ((seen '())
             (claude-code-notify-function
              (lambda (session _body) (push session seen))))
        (claude-code--register "55555555-5555-4555-8555-555555555555" buf
                               "/home/test/proj/.claude/worktrees/feat" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf)))
                  ((symbol-function 'claude-code--on-screen-p) #'ignore))
          (claude-code--notify buf "Finished"))
        (should (equal (claude-code--session-display-name (car seen))
                       "Dotted worktree"))))))

(ert-deftest claude-code-test-notify-stays-quiet ()
  "Nothing is announced with notifications off, after an exit, or on screen.
Nor is anything from a terminal hosting no instance Emacs manages."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let* ((id "11111111-1111-4111-8111-111111111111")
             (announced 0)
             (claude-code-notify-function (lambda (&rest _) (cl-incf announced))))
        (claude-code--register id buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          ;; The user can see the instance already.
          (cl-letf (((symbol-function 'claude-code--on-screen-p)
                     (lambda (_buffer) t)))
            (claude-code--notify buf "Finished after 4m 12s"))
          (should (= announced 0))
          (cl-letf (((symbol-function 'claude-code--on-screen-p) #'ignore))
            ;; An instance whose process has exited.
            (with-temp-buffer
              (claude-code--notify (current-buffer) "Finished after 4m 12s"))
            (should (= announced 0))
            ;; A live terminal hosting no instance Emacs manages.
            (with-temp-buffer
              (setq-local ghostel--pid 4243)
              (cl-letf (((symbol-function 'claude-code--session-process)
                         #'always))
                (claude-code--notify (current-buffer) "Finished after 4m 12s")))
            (should (= announced 0))
            ;; Notifications turned off entirely.
            (let ((claude-code-notify-function nil))
              (claude-code--notify buf "Finished after 4m 12s"))
            (should (= announced 0))
            ;; The same call announces once every guard is out of the way.
            (claude-code--notify buf "Finished after 4m 12s")
            (should (= announced 1))))))))

(ert-deftest claude-code-test-notify-follow-shows-the-instance-once-raised ()
  "A raise inside the activation window displays the instance, exactly once.
The display is deferred rather than run from the focus hook, which fires in
arbitrary contexts, and the watch drops itself as it fires so a second focus
change cannot show the instance twice."
  (claude-code-tests--with-managed-buffer buf
    (let ((shown '())
          (log '())
          (raised nil))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (push b shown))))
        (claude-code-tests--following raised log
          (claude-code--notify-follow buf)
          (setq raised t)
          (funcall after-focus-change-function)
          ;; Nothing rearranged from inside the focus hook itself.
          (should (null shown))
          ;; The deferred display is what moves the windows.
          (funcall (claude-code-tests--thunk-at log 0))
          (should (equal shown (list buf)))
          ;; The watch is gone: a later focus change schedules nothing new.
          (setq log (seq-remove (lambda (e) (equal (nth 1 e) 0)) log))
          (funcall after-focus-change-function)
          (should-not (claude-code-tests--thunk-at log 0))
          (should (equal shown (list buf))))))))

(ert-deftest claude-code-test-notify-does-not-claim-a-view-window ()
  "A notification jump displays with `pop-to-buffer', not `claude-code--show'.
Every other notify test stubs `pop-to-buffer' -- which `claude-code--show' calls
-- so none of them would notice this opt-out being dropped."
  (claude-code-tests--with-managed-buffer buf
    (let ((calls '())
          (log '()))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (push (list 'pop b) calls)))
                ((symbol-function 'claude-code--show)
                 (lambda (b &rest _) (push (list 'show b) calls))))
        (claude-code-tests--capturing-timers log
          (claude-code--notify-show buf)
          (funcall (claude-code-tests--thunk-at log 0))))
      (should (equal calls (list (list 'pop buf)))))))

(defmacro claude-code-tests--jumping (var popped &rest body)
  "Run BODY with VAR bound to an instance buffer and `pop-to-buffer' stubbed.
The stub pushes its buffer onto POPPED.  Tabs are real tab-bar tabs on the
one batch frame: the frame's windows, its tab list and `tab-bar-mode', which
the first tab turns on, are put back afterwards, and VAR is killed."
  (declare (indent 2))
  (let ((tabs (gensym "tabs"))
        (mode (gensym "mode")))
    `(save-window-excursion
       (let ((,tabs (frame-parameter nil 'tabs))
             (,mode tab-bar-mode)
             (,var (generate-new-buffer " *cc-instance*"))
             (,popped '()))
         (unwind-protect
             (cl-letf (((symbol-function 'pop-to-buffer)
                        (lambda (b &rest _) (push b ,popped))))
               (with-current-buffer ,var (claude-code-instance-mode))
               (delete-other-windows)
               ,@body)
           (set-frame-parameter nil 'tabs ,tabs)
           (tab-bar-mode (if ,mode 1 -1))
           (kill-buffer ,var))))))

(defun claude-code-tests--current-tab-index ()
  "Return the 0-based index of the frame's current tab."
  (cl-position 'current-tab (frame-parameter nil 'tabs) :key #'car))

(ert-deftest claude-code-test-display-frames ()
  "The frames a jump may land on: this display's visible ones, the selected first.
Symbols stand in for frames, since batch Emacs cannot make a second one."
  (cl-letf (((symbol-function 'selected-frame) (lambda () 'b))
            ((symbol-function 'frame-list) (lambda () '(a b c d)))
            ((symbol-function 'frame-terminal)
             (lambda (frame) (if (eq frame 'c) 'tty 'display)))
            ((symbol-function 'frame-visible-p)
             (lambda (frame) (if (eq frame 'd) nil 'icon))))
    (should (equal (claude-code--display-frames) '(b a)))))

(ert-deftest claude-code-test-jump-selects-a-window-already-showing-the-instance ()
  "A live window showing the instance is selected, over any background tab.
Restoring the tab would show the instance a second time, and Ghostel sizes the
pty to the smallest window showing it."
  (claude-code-tests--jumping buf popped
    (switch-to-buffer buf)
    (tab-bar-new-tab)
    (let ((other (split-window)))
      (set-window-buffer other buf)
      (switch-to-buffer (get-scratch-buffer-create))
      (claude-code--jump-to buf)
      (should (eq (selected-window) other))
      (should (eql (claude-code-tests--current-tab-index) 1))
      (should (null popped)))))

(ert-deftest claude-code-test-jump-restores-the-tab-that-showed-the-instance ()
  "A background tab is matched by the name the instance held when it was left.
The tab's window state names buffers as of then.  The instance has been
retitled since, and its old name has passed to a newer instance -- which is
not sent to the tab, since it did not exist when the tab was left."
  (claude-code-tests--jumping buf popped
    (switch-to-buffer buf)
    (tab-bar-new-tab)
    (switch-to-buffer (get-scratch-buffer-create))
    (with-current-buffer buf (rename-buffer " *cc-topic*"))
    (let ((decoy (generate-new-buffer " *cc-instance*")))
      (unwind-protect
          (progn
            (with-current-buffer decoy (claude-code-instance-mode))
            (claude-code--jump-to decoy)
            (should (equal popped (list decoy)))
            (should (eql (claude-code-tests--current-tab-index) 1))
            (claude-code--jump-to buf)
            (should (eq (window-buffer (selected-window)) buf))
            (should (eql (claude-code-tests--current-tab-index) 0))
            (should (equal popped (list decoy))))
        (kill-buffer decoy)))))

(ert-deftest claude-code-test-jump-prefers-the-tab-left-most-recently ()
  "Of several background tabs showing the instance, the one left last is taken."
  (claude-code-tests--jumping buf popped
    (switch-to-buffer buf)
    (tab-bar-new-tab)
    (tab-bar-new-tab)
    (switch-to-buffer (get-scratch-buffer-create))
    (claude-code--jump-to buf)
    (should (eq (window-buffer (selected-window)) buf))
    (should (eql (claude-code-tests--current-tab-index) 1))
    (should (null popped))))

(ert-deftest claude-code-test-jump-matches-a-restored-tab-by-its-current-name ()
  "A tab without a configuration of this frame is rebuilt from its state, by name.
That is a tab moved from another frame or brought back by `desktop-save-mode'.
It shows the instance only while the instance holds the name listed, so a
renamed instance is popped up instead, and one renamed back is found."
  (claude-code-tests--jumping buf popped
    (switch-to-buffer buf)
    (tab-bar-new-tab)
    (switch-to-buffer (get-scratch-buffer-create))
    (let ((tab (car (frame-parameter nil 'tabs))))
      (setcdr tab (assq-delete-all 'wc (cdr tab))))
    (with-current-buffer buf (rename-buffer " *cc-topic*"))
    (claude-code--jump-to buf)
    (should (equal popped (list buf)))
    (should (eql (claude-code-tests--current-tab-index) 1))
    (with-current-buffer buf (rename-buffer " *cc-instance*"))
    (claude-code--jump-to buf)
    (should (eq (window-buffer (selected-window)) buf))
    (should (eql (claude-code-tests--current-tab-index) 0))
    (should (equal popped (list buf)))))

(ert-deftest claude-code-test-jump-pops-up-when-the-tab-shows-nothing ()
  "A tab selected and found not to show the instance ends in the pop-up."
  (claude-code-tests--jumping buf popped
    (switch-to-buffer buf)
    (tab-bar-new-tab)
    (switch-to-buffer (get-scratch-buffer-create))
    (cl-letf (((symbol-function 'tab-bar-select-tab) #'ignore))
      (claude-code--jump-to buf))
    (should (equal popped (list buf)))))

(ert-deftest claude-code-test-jump-focuses-the-frame-first ()
  "A place on another frame is reached by focusing that frame before anything."
  (claude-code-tests--jumping buf popped
    (let ((focused '()))
      (cl-letf (((symbol-function 'claude-code--instance-place)
                 (lambda (_buffer) (list 'elsewhere)))
                ((symbol-function 'select-frame-set-input-focus)
                 (lambda (frame &rest _) (push frame focused))))
        (claude-code--jump-to buf))
      (should (equal focused '(elsewhere)))
      (should (equal popped (list buf))))))

(ert-deftest claude-code-test-notify-follow-leaves-a-dismissal-alone ()
  "Waving a notification away never rearranges windows.
A dismissal and a click both close as `dismissed'; only the click raises
Emacs.  With no raise the wait times out, and focus arriving afterwards for
reasons of its own must not revive the jump."
  (claude-code-tests--with-managed-buffer buf
    (let ((shown '())
          (log '())
          (raised nil))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (push b shown))))
        (claude-code-tests--following raised log
          (claude-code--notify-follow buf)
          ;; Focus changes while still unraised: nothing to follow.
          (funcall after-focus-change-function)
          (should-not (claude-code-tests--thunk-at log 0))
          ;; The activation window closes and the wait retires.
          (funcall (claude-code-tests--thunk-at
                    log claude-code--notify-activation-window))
          (setq raised t)
          (funcall after-focus-change-function)
          (should-not (claude-code-tests--thunk-at log 0))
          (should (null shown)))))))

(ert-deftest claude-code-test-notify-follow-skips-an-exited-instance ()
  "An instance that exited between the click and the display opens nothing."
  (let ((buf (generate-new-buffer " *cc-test*"))
        (shown '())
        (log '())
        (raised nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (b &rest _) (push b shown))))
          (claude-code-tests--following raised log
            (claude-code--notify-follow buf)
            (setq raised t)
            (funcall after-focus-change-function)
            (kill-buffer buf)
            (funcall (claude-code-tests--thunk-at log 0))
            (should (null shown))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest claude-code-test-notify-follow-follows-the-first-close ()
  "One click dismisses the whole group, and the clicked notification closes first.
Every close starts a follow, so the burst arriving behind the click must not
take the claim off it: the jump goes to the instance that closed first, and it
happens once."
  (claude-code-tests--with-managed-buffer clicked
    (claude-code-tests--with-managed-buffer swept
      (let ((shown '())
            (log '())
            (raised nil))
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (b &rest _) (push b shown))))
          (claude-code-tests--following raised log
            (claude-code--notify-follow clicked)
            (let ((claim (claude-code-tests--timer-at
                          log claude-code--notify-activation-window)))
              ;; The rest of the group, closed a millisecond behind the click.
              (claude-code--notify-follow swept)
              (claude-code--notify-follow swept)
              ;; The claim stands: nothing rearmed, nothing cancelled.
              (should (eq claim (claude-code-tests--timer-at
                                 log claude-code--notify-activation-window)))
              (should (null (claude-code-tests--cancelled log)))
              (setq raised t)
              (funcall after-focus-change-function)
              ;; A close trailing the raise is still inside the window, and
              ;; Emacs is focused by now -- the branch that displays at once.
              (claude-code--notify-follow swept)
              (funcall (claude-code-tests--thunk-at log 0))
              (should (equal shown (list clicked))))))))))

(ert-deftest claude-code-test-notify-follow-jumps-at-once-when-focused ()
  "An already-focused Emacs has no raise to wait for, so it jumps immediately.
Waiting would drop the click entirely, since `after-focus-change-function'
fires on a transition and none is coming.  The claim is still taken, so the
closes swept along behind the click jump nowhere."
  (claude-code-tests--with-managed-buffer buf
    (let ((shown '())
          (log '()))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (push b shown))))
        (claude-code-tests--following t log
          (claude-code--notify-follow buf)
          ;; No watcher to install: the focus hook is left alone.
          (should (eq after-focus-change-function #'ignore))
          (funcall (claude-code-tests--thunk-at log 0))
          (should (equal shown (list buf)))
          (setq log (seq-remove (lambda (e) (equal (nth 1 e) 0)) log))
          (claude-code--notify-follow buf)
          (should-not (claude-code-tests--thunk-at log 0))
          (should (equal shown (list buf))))))))

(defmacro claude-code-tests--recording-notify (posts &rest body)
  "Run BODY with `notifications-notify' pushing its plist onto POSTS.
D-Bus is not wanted under test, so requiring `notifications' is a no-op."
  (declare (indent 1))
  `(claude-code-tests--without-requiring '(notifications)
     (cl-letf (((symbol-function 'notifications-notify)
                (lambda (&rest params) (push params ,posts) (length ,posts))))
       ,@body)))

(ert-deftest claude-code-test-notify-desktop-payload ()
  "The notification names the session, declares no action, and keeps BODY as sent.
An action would cost the raise the jump depends on, so the list stays empty.
The body reaches the server verbatim: it repairs markup it cannot parse, so a
message quoting a shell command needs no escaping on the way out.  Urgency
travels too, since it is what decides whether a banner is drawn at all."
  (let ((posts '())
        (session (claude-code-session--create
                  :id "id-1" :title "Understand the project layout")))
    (claude-code-tests--recording-notify posts
      ;; A value the defcustom does not already hold, so the wiring is tested
      ;; rather than the default.
      (let ((claude-code-notify-desktop-entry "emacs-nightly")
            (claude-code-notify-urgency 'normal))
        (claude-code-notify-desktop session "run `du -sh * | sort -h` <now>"))
      (let ((params (car posts)))
        (should (equal (plist-get params :title) "Understand the project layout"))
        (should (equal (plist-get params :body) "run `du -sh * | sort -h` <now>"))
        (should (equal (plist-get params :desktop-entry) "emacs-nightly"))
        (should (equal (plist-get params :urgency) 'normal))
        (should-not (plist-member params :actions))))))

(ert-deftest claude-code-test-notify-desktop-follows-only-a-dismissal ()
  "Only a dismissal chases the raise; a notification that expired was not clicked.
The follow is handed the instance's buffer, which is what it jumps to."
  (with-temp-buffer
    (let ((posts '())
          (followed '())
          (session (claude-code-session--create :id "id-1" :title "T"
                                                :buffer (current-buffer))))
      (cl-letf (((symbol-function 'claude-code--notify-follow)
                 (lambda (buffer) (push buffer followed))))
        (claude-code-tests--recording-notify posts
          (claude-code-notify-desktop session "body")
          (let ((on-close (plist-get (car posts) :on-close)))
            (funcall on-close 1 'expired)
            (should (null followed))
            (funcall on-close 1 'dismissed)
            (should (equal followed (list (current-buffer))))))))))

(ert-deftest claude-code-test-notify-desktop-closes-with-the-instance ()
  "Notifications still up when their instance's buffer dies are closed.
One already closed -- clicked, waved away or expired -- is forgotten as it
closes, so the kill closes only what is still up."
  (claude-code-tests--with-managed-buffer buf
    (let ((posts '())
          (closed '())
          (session (claude-code-session--create :id "id-1" :title "T"
                                                :buffer buf)))
      (cl-letf (((symbol-function 'claude-code--close-notification)
                 (lambda (id) (push id closed)))
                ((symbol-function 'claude-code--notify-follow) #'ignore))
        (claude-code-tests--recording-notify posts
          (claude-code-notify-desktop session "first")
          (claude-code-notify-desktop session "second")
          (claude-code-notify-desktop session "third")
          ;; Posted as 1, 2 and 3; the first and the last close on their own.
          (funcall (plist-get (nth 2 posts) :on-close) 1 'dismissed)
          (funcall (plist-get (nth 0 posts) :on-close) 3 'expired)
          (should (null closed))
          (kill-buffer buf)
          (should (equal closed '(2)))
          (should-not (buffer-live-p buf)))))))

(ert-deftest claude-code-test-notify-desktop-closes-what-ends-while-posting ()
  "A notification its instance is done with before it is up closes once up.
Posting waits on D-Bus, where a change of the root's state, the instance
coming into sight and its buffer's kill all close the notifications up for
it -- which the one being posted is not yet.  Another instance coming into
sight leaves it up."
  (claude-code-tests--with-managed-buffer buf
    (claude-code-tests--with-managed-buffer (other 4243)
      (let ((log '()) (now 1000.0) (closed '()) (posted 0) (inside nil)
            (in-sight buf) (claude-code--seen-timer nil)
            (session (claude-code-session--create :id "id-1" :title "T"
                                                  :buffer buf)))
        (claude-code--register "id-1" buf "/home/test/proj" nil)
        (claude-code--register "id-2" other "/home/test/proj" nil)
        (cl-letf (((symbol-function 'notifications-notify)
                   (lambda (&rest _)
                     (when inside (funcall (prog1 inside (setq inside nil))))
                     (cl-incf posted)))
                  ((symbol-function 'claude-code--close-notification)
                   (lambda (id) (push id closed)))
                  ((symbol-function 'claude-code--on-screen-p)
                   (lambda (buffer) (eq buffer in-sight))))
          (claude-code-tests--without-requiring '(notifications)
            (claude-code-tests--reporting buf log now
              ;; Undisturbed, it is remembered for the close to come.
              (claude-code-tests--status buf 'done)
              (claude-code-notify-desktop session "Finished")
              (should (equal claude-code--posted '(1)))
              (claude-code-tests--status buf 'working)
              (should (equal closed '(1)))
              (claude-code-tests--status buf 'done)
              (setq inside (lambda () (claude-code-tests--status buf 'working)))
              (claude-code-notify-desktop session "Finished")
              (should (equal closed '(2 1)))
              (should (null claude-code--posted))
              (setq inside #'claude-code--close-seen)
              (claude-code-notify-desktop session "Finished")
              (should (equal closed '(3 2 1)))
              (should (null claude-code--posted))
              (setq in-sight other inside #'claude-code--close-seen)
              (claude-code-notify-desktop session "Finished")
              (should (equal claude-code--posted '(4)))
              (should (equal closed '(3 2 1)))
              (setq inside (lambda () (kill-buffer buf)))
              (claude-code-notify-desktop session "Finished")
              (should (equal closed '(5 4 3 2 1))))))))))

;;;; View

(ert-deftest claude-code-test-status-display ()
  "Status maps to native words and Emacs palette faces."
  (should (equal (car (claude-code--status-display
                       (claude-code-session--create :alive-p t :status "idle")))
                 "idle"))
  (should (eq (cdr (claude-code--status-display
                    (claude-code-session--create :alive-p t :status "idle")))
              'success))
  (should (eq (cdr (claude-code--status-display
                    (claude-code-session--create :alive-p t :status "busy")))
              'warning))
  (should (eq (cdr (claude-code--status-display
                    (claude-code-session--create :alive-p t :status "waiting")))
              'error))
  (should (equal (car (claude-code--status-display
                       (claude-code-session--create :alive-p nil)))
                 "dead"))
  (should (equal (car (claude-code--status-display
                       (claude-code-session--create :alive-p nil :external-p t)))
                 "external")))

(ert-deftest claude-code-test-format-session ()
  "Columns fall back sensibly and render usage.
Order is Status[0] Active[1] Id[2] Worktree[3] CPU%[4] Mem[5] Name[6]."
  (let ((now 1800000000))
    (let* ((s (claude-code-session--create
               :id "abcdef01-0000-4000-8000-000000000000"
               :alive-p nil :title "The Title"))
           (v (claude-code--format-session s nil now)))
      ;; No status modifier -> the status alone.
      (should (equal (substring-no-properties (aref v 0)) "dead"))
      ;; No last-active -> empty Active cell.
      (should (equal (substring-no-properties (aref v 1)) ""))
      (should (equal (substring-no-properties (aref v 2)) "abcdef01"))
      (should (equal (aref v 3) ""))
      (should (equal (aref v 4) ""))
      (should (equal (aref v 5) ""))
      ;; The transcript title is shown in the final (Name) column.
      (should (equal (aref v 6) "The Title")))
    (let* ((s (claude-code-session--create
               :id "11112222-0000-4000-8000-000000000000"
               :alive-p t :status "busy" :title "Worker task"
               :worktree "feat" :last-active (- now 90)))
           (v (claude-code--format-session s '(12.5 . 204800) now)))
      (should (equal (substring-no-properties (aref v 0)) "busy"))
      (should (eq (get-text-property 0 'face (aref v 0)) 'warning))
      ;; The Active cell is last-active rendered against the NOW argument.
      (should (equal (substring-no-properties (aref v 1))
                     (claude-code--format-relative-time (- now 90) now)))
      (should (equal (aref v 3) "feat"))
      (should (equal (aref v 4) "12.5"))
      (should (equal (aref v 5) "200M"))
      (should (equal (aref v 6) "Worker task")))
    ;; A status modifier's glyph follows the status, in its own face.
    (pcase-dolist (`(,modifier ,cell ,face) '((done "idle ✓" success)
                                              (error "idle ✗" error)))
      (let* ((v (claude-code--format-session
                 (claude-code-session--create :id "a" :alive-p t :status "idle"
                                              :modifier modifier)
                 nil now))
             (glyph (1- (length (aref v 0)))))
        (should (equal (substring-no-properties (aref v 0)) cell))
        (should (eq (get-text-property 0 'face (aref v 0)) 'success))
        (should (eq (get-text-property glyph 'face (aref v 0)) face))
        (should (get-text-property glyph 'help-echo (aref v 0)))))))

(ert-deftest claude-code-test-format-relative-time ()
  "Relative ages render compactly; nil renders empty."
  (let ((now 1800000000))
    (should (equal "" (claude-code--format-relative-time nil now)))
    (should (equal "0s" (claude-code--format-relative-time now now)))
    (should (equal "45s" (claude-code--format-relative-time (- now 45) now)))
    (should (equal "1m" (claude-code--format-relative-time (- now 90) now)))
    (should (equal "2h" (claude-code--format-relative-time (- now 7200) now)))
    (should (equal "3d" (claude-code--format-relative-time
                         (- now (* 3 86400)) now)))
    (should (equal "2w" (claude-code--format-relative-time
                         (- now (* 14 86400)) now)))))

(ert-deftest claude-code-test-time-less-p ()
  "The Active-column sorter orders older sessions before newer ones."
  (let ((claude-code--session-table (make-hash-table :test 'equal)))
    (puthash "old" (claude-code-session--create :id "old" :last-active 100)
             claude-code--session-table)
    (puthash "new" (claude-code-session--create :id "new" :last-active 200)
             claude-code--session-table)
    (puthash "none" (claude-code-session--create :id "none")
             claude-code--session-table)
    (should (claude-code--time-less-p '("old" []) '("new" [])))
    (should-not (claude-code--time-less-p '("new" []) '("old" [])))
    ;; A session without a time sorts as oldest.
    (should (claude-code--time-less-p '("none" []) '("old" [])))))

(ert-deftest claude-code-test-session-display-name ()
  "The display name draws on one ordered set of transcript sources."
  ;; The transcript title wins over the prompt and the id.
  (should (equal "t" (claude-code--session-display-name
                      (claude-code-session--create
                       :id "abcdef01-0000-4000-8000-000000000000"
                       :title "t" :last-prompt "p"))))
  (should (equal "p" (claude-code--session-display-name
                      (claude-code-session--create
                       :id "abcdef01-0000-4000-8000-000000000000"
                       :last-prompt "p"))))
  (should (equal "abcdef01"
                 (claude-code--session-display-name
                  (claude-code-session--create
                   :id "abcdef01-0000-4000-8000-000000000000")))))

(ert-deftest claude-code-test-short-session-id ()
  "An id shorter than the truncation width degrades to itself.
Truncating it must not signal: the Id column and the display name are
computed for every row, so one odd id would abort a whole view refresh."
  (let ((s (claude-code-session--create :id "new-id")))
    (should (equal "new-id" (claude-code--session-display-name s)))
    (should (equal "new-id"
                   (substring-no-properties
                    (aref (claude-code--format-session s nil (current-time))
                          2))))))

(ert-deftest claude-code-test-group-key ()
  "Grouping keys depend on the current grouping mode."
  (let ((alive (claude-code-session--create :alive-p t :status "busy"))
        (external (claude-code-session--create :alive-p nil :external-p t))
        (dead (claude-code-session--create :alive-p nil)))
    (let ((claude-code--group-by 'status))
      (should (equal (claude-code--group-key alive) "busy"))
      (should (equal (claude-code--group-key external) "external"))
      (should (equal (claude-code--group-key dead) "dead")))
    (let ((claude-code--group-by 'state))
      (should (equal (claude-code--group-key alive) "alive"))
      ;; External keeps its own group even when grouping by state.
      (should (equal (claude-code--group-key external) "external"))
      (should (equal (claude-code--group-key dead) "dead")))))

(ert-deftest claude-code-test-group-order ()
  "Groups sort by urgency, with external and dead last."
  (should (equal (sort (list "dead" "idle" "external" "waiting" "busy")
                       #'claude-code--group-less-p)
                 '("waiting" "busy" "idle" "external" "dead"))))

(ert-deftest claude-code-test-target-sessions-by-liveness ()
  "Marked targets are filtered to the liveness a command's operation accepts.
An external session is neither a killable nor a deletable target, so a batch
never hands one to an operation that would only refuse it."
  (let ((claude-code--session-table (make-hash-table :test 'equal))
        (claude-code--marks '("a" "e" "d")))
    (dolist (s (list (claude-code-session--create :id "a" :alive-p t)
                     (claude-code-session--create :id "e" :external-p t)
                     (claude-code-session--create :id "d")))
      (puthash (claude-code-session-id s) s claude-code--session-table))
    (let ((ids (lambda (liveness)
                 (mapcar #'claude-code-session-id
                         (claude-code--target-sessions liveness)))))
      (should (equal (funcall ids nil) '("a" "e" "d")))
      (should (equal (funcall ids 'alive) '("a")))
      (should (equal (funcall ids 'external) '("e")))
      ;; The external row must not be offered up as dead.
      (should (equal (funcall ids 'dead) '("d"))))))

(ert-deftest claude-code-test-sessions-visit-dispatch ()
  "RET shows a row's running instance, else what `claude-code--resume' returns.
An external row is refused by the model alone
\(`claude-code-test-resume-refuses-external')."
  (let* ((binding '(:name "feat" :path "/r/.claude/worktrees/feat" :bound nil))
         (alive (claude-code-session--create :id "a" :alive-p t :pid 70
                                             :buffer 'terminal))
         (moved (claude-code-session--create :id "m" :alive-p t :pid 70
                                             :buffer 'terminal))
         (stale (claude-code-session--create :id "s" :alive-p t :buffer 'exited))
         (external (claude-code-session--create :id "e" :external-p t))
         (dead (claude-code-session--create :id "d" :worktree-binding binding))
         (at-point nil) (calls '()))
    (cl-letf (((symbol-function 'claude-code--session-at-point)
               (lambda () at-point))
              ((symbol-function 'claude-code--session-process)
               (lambda (b) (eq b 'terminal)))
              ((symbol-function 'claude-code--resume)
               (lambda (root id b)
                 (push (list 'resume root id b) calls) 'terminal))
              ((symbol-function 'claude-code--show)
               (lambda (b &rest _) (push (list 'show b) calls)))
              ((symbol-function 'claude-code--refresh-views)
               (lambda () (push '(refresh) calls)))
              ((symbol-function 'claude-code-sessions-toggle-group)
               (lambda () (push '(toggle) calls))))
      (claude-code-tests--with-config
        (claude-code-tests--with-registry
          (puthash 70 (list :buffer 'terminal :session "a") claude-code--managed)
          (claude-code-tests--in-view
            (setq-local claude-code--project "/r")
            ;; A group header (no session at point) toggles.
            (claude-code-sessions-visit)
            (should (equal calls '((toggle))))
            ;; An alive row shows the instance it was drawn for while that
            ;; runs, and nothing needs a redraw.
            (setq at-point alive calls nil)
            (claude-code-sessions-visit)
            (should (equal calls '((show terminal))))
            ;; It still does once a `/clear' has moved the instance onto
            ;; another session, and the views catch up.
            (setq at-point moved calls nil)
            (claude-code-sessions-visit)
            (should (equal (reverse calls) '((refresh) (show terminal))))
            ;; A row still drawn alive whose instance has since exited displays
            ;; what the model returns, and the views catch up.
            (setq at-point stale calls nil)
            (claude-code-sessions-visit)
            (should (equal (reverse calls)
                           '((resume "/r" "s" nil) (refresh) (show terminal))))
            ;; An external row goes to the model like any other.
            (setq at-point external calls nil)
            (claude-code-sessions-visit)
            (should (equal (car (last calls)) '(resume "/r" "e" nil)))
            ;; A dead row resumes, refreshes and displays.
            (setq at-point dead calls nil)
            (claude-code-sessions-visit)
            (should (equal (reverse calls)
                           ;; The binding comes off the struct the view
                           ;; already built, so a resume costs no second read
                           ;; of disk.
                           (list (list 'resume "/r" "d" binding)
                                 '(refresh) '(show terminal))))))))))

(ert-deftest claude-code-test-sessions-visit-other-window ()
  "`o' shows the row's buffer in another window; a header line is refused.
The dispatch is shared with RET \(`claude-code-test-sessions-visit-dispatch')."
  (let ((alive (claude-code-session--create :id "a" :alive-p t :buffer 'terminal))
        (at-point nil) (shown nil))
    (cl-letf (((symbol-function 'claude-code--session-at-point)
               (lambda () at-point))
              ((symbol-function 'claude-code--resume)
               (lambda (&rest _) 'terminal))
              ((symbol-function 'switch-to-buffer-other-window)
               (lambda (b) (setq shown b))))
      (claude-code-tests--in-view
        (should-error (claude-code-sessions-visit-other-window)
                      :type 'user-error)
        (setq at-point alive)
        (claude-code-sessions-visit-other-window)
        (should (eq shown 'terminal))))))

(ert-deftest claude-code-test-sessions-vc ()
  "`v' hands the tree the session at point works in to `claude-code-vc-function'.
The tree is found as the key is pressed, so a row drawn before its instance
moved still opens where the instance is now."
  (let* ((at-point nil) (shown '())
         (claude-code-vc-function (lambda (dir) (push dir shown))))
    (should (eq (keymap-lookup claude-code-sessions-mode-map "v")
                #'claude-code-sessions-vc))
    (cl-letf (((symbol-function 'claude-code--session-at-point)
               (lambda () at-point)))
      (claude-code-tests--with-fixtures
        (claude-code-tests--with-registry
          (claude-code-tests--in-view
            (setq-local claude-code--project "/home/test/proj")
            (should (equal (should-error (claude-code-sessions-vc)
                                         :type 'user-error)
                           '(user-error "No session on this line")))
            (setq at-point (claude-code-session--create :id "d"))
            (claude-code-sessions-vc)
            (puthash 1003 (list :origin "/home/test/proj") claude-code--managed)
            (setq at-point (claude-code-session--create :id "a" :alive-p t
                                                        :pid 1003))
            (claude-code-sessions-vc)
            (should (equal (reverse shown)
                           '("/home/test/proj/"
                             "/home/test/proj/.claude/worktrees/feat/")))))))))

(defmacro claude-code-tests--recording-exports (exports cancelled &rest body)
  "Run BODY with exports and their cancels stubbed and recorded.
Each export pushes (ID ROOT ON-TEXT ON-ERROR PROC) onto EXPORTS, PROC a fresh
symbol standing for its process, and refuses session \"gone\" the way a
session with no transcript is refused; each cancel pushes PROC onto
CANCELLED.  Every transcript buffer is killed afterwards."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'claude-code-export-transcript)
              (lambda (session root on-text on-error)
                (let ((id (claude-code-session-id session))
                      (proc (gensym "export")))
                  (when (equal id "gone")
                    (user-error "No transcript on disk for session gone"))
                  (push (list id root on-text on-error proc) ,exports)
                  proc)))
             ((symbol-function 'claude-code--export-cancel)
              (lambda (proc) (push proc ,cancelled))))
     (unwind-protect (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (eq (buffer-local-value 'major-mode buffer)
                   'claude-code-transcript-mode)
           (kill-buffer buffer))))))

(ert-deftest claude-code-test-sessions-transcript ()
  "`t' shows the row's transcript beside the view, leaving the view selected.
Another row's takes the same window; a row's own is exported again into the
buffer it has, abandoning an export that buffer still awaits.  A session the
export refuses leaves no buffer behind.  Run against real windows."
  (let ((exports '()) (cancelled '()) (at-point nil)
        (view (generate-new-buffer " *cc-view*"))
        (a (claude-code-session--create :id "a" :title "Alpha"))
        (b (claude-code-session--create :id "b" :title "Beta")))
    (should (eq (keymap-lookup claude-code-sessions-mode-map "t")
                #'claude-code-sessions-transcript))
    (unwind-protect
        (let ((display-buffer-overriding-action nil)
              (display-buffer-alist nil)
              (display-buffer-base-action nil)
              (ignore-window-parameters t))
          (cl-letf (((symbol-function 'claude-code--session-at-point)
                     (lambda () at-point)))
            (claude-code-tests--recording-exports exports cancelled
              (save-window-excursion
                (delete-other-windows)
                (set-window-buffer (selected-window) view)
                (cl-flet ((press (session)
                            (setq at-point session)
                            (with-current-buffer view
                              (claude-code-sessions-transcript)))
                          (answer (n fn arg)
                            (funcall (nth (if (eq fn 'text) 2 3) (nth n exports))
                                     arg)))
                  (with-current-buffer view
                    (claude-code-sessions-mode)
                    (setq claude-code--project "/r")
                    (should (equal (should-error (claude-code-sessions-transcript)
                                                 :type 'user-error)
                                   '(user-error "No session on this line"))))
                  (press a)
                  (let* ((buffer-a (claude-code--transcript-buffer "a"))
                         (window (get-buffer-window buffer-a)))
                    (should (equal (buffer-name buffer-a)
                                   "*claude-transcript: Alpha*"))
                    (should (eq (window-in-direction 'right) window))
                    (should (eq (window-buffer (selected-window)) view))
                    (should (equal (mapcar (lambda (e) (list (nth 0 e) (nth 1 e)))
                                           exports)
                                   '(("a" "/r"))))
                    (should (equal (buffer-local-value 'mode-line-process buffer-a)
                                   ":exporting"))
                    (answer 0 'text "first\nsecond")
                    (with-current-buffer buffer-a
                      (should (equal (buffer-string) "first\nsecond"))
                      (should-not mode-line-process)
                      (should-not claude-code--transcript-export))
                    ;; Another row's takes the same window.
                    (press b)
                    (should (eq (window-buffer window) (claude-code--transcript-buffer "b")))
                    (should (= (length (window-list)) 2))
                    ;; Pressed again before the answer: the first is abandoned.
                    (press b)
                    (should (equal cancelled (list (nth 4 (nth 1 exports)))))
                    (should (eq (claude-code--transcript-buffer "b")
                                (window-buffer window)))
                    ;; A row's own buffer is reused, nothing left to abandon.
                    (press a)
                    (should (eq (window-buffer window) buffer-a))
                    (should (= (length cancelled) 1))
                    ;; A failure keeps the text there was.
                    (answer 0 'error "boom")
                    (with-current-buffer buffer-a
                      (should (equal (buffer-string) "first\nsecond"))
                      (should-not mode-line-process))
                    ;; Refused: no buffer, and the window keeps what it had.
                    (should-error (press (claude-code-session--create :id "gone"))
                                  :type 'user-error)
                    (should-not (claude-code--transcript-buffer "gone"))
                    (should (eq (window-buffer window) buffer-a))))))))
      (kill-buffer view))))

(ert-deftest claude-code-test-transcript-buffer-exports-again ()
  "`g' exports a transcript buffer's session again.
Killing the buffer abandons the export it awaits, and so does leaving the mode,
which takes the buffer out of reach of the answer.  No text it held is kept
for undo."
  (let ((exports '()) (cancelled '())
        (session (claude-code-session--create :id "a")))
    (claude-code-tests--recording-exports exports cancelled
      (let ((buffer (claude-code--transcript-export session "/r")))
        (with-current-buffer buffer
          (should (eq major-mode 'claude-code-transcript-mode))
          (should (eq buffer-undo-list t))
          (should (eq (keymap-lookup (current-local-map) "g") #'revert-buffer))
          (revert-buffer)
          (should (equal (mapcar (lambda (e) (list (nth 0 e) (nth 1 e))) exports)
                         '(("a" "/r") ("a" "/r"))))
          (should (equal cancelled (list (nth 4 (nth 1 exports))))))
        (kill-buffer buffer)
        (should (equal cancelled (list (nth 4 (nth 0 exports))
                                       (nth 4 (nth 1 exports)))))
        (with-current-buffer (claude-code--transcript-export session "/r")
          (fundamental-mode)
          (should (eq (car cancelled) (nth 4 (nth 0 exports))))
          (kill-buffer))))))

(ert-deftest claude-code-test-transcript-fill-keeps-places ()
  "Exporting again leaves every window, and the buffer's point, where it was.
One at the end stays at the end, the latest of the conversation in view."
  (let ((buffer (generate-new-buffer " *cc-transcript*"))
        (other (generate-new-buffer " *cc-other*"))
        (lines (lambda (n)
                 (mapconcat (lambda (i) (format "line %d" i))
                            (number-sequence 1 n) "\n"))))
    (cl-flet ((line-col (pos)
                (with-current-buffer buffer
                  (save-excursion
                    (goto-char pos)
                    (list (line-number-at-pos) (current-column))))))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) other)
            (with-current-buffer buffer
              (claude-code-transcript-mode)
              ;; A first export lands at the end.
              (claude-code--transcript-fill (funcall lines 100))
              (should (eobp)))
            (let ((top (split-window))
                  (bottom (split-window nil nil 'right)))
              (set-window-buffer top buffer)
              (set-window-buffer bottom buffer)
              (with-current-buffer buffer
                (goto-char (point-min))
                (forward-line 9))
              (set-window-start top (with-current-buffer buffer
                                      (save-excursion (goto-char (point-min))
                                                      (forward-line 34)
                                                      (point))))
              (set-window-point top (with-current-buffer buffer
                                      (save-excursion (goto-char (point-min))
                                                      (forward-line 39)
                                                      (forward-char 3)
                                                      (point))))
              (set-window-point bottom (with-current-buffer buffer (point-max)))
              (with-current-buffer buffer
                (claude-code--transcript-fill (funcall lines 150))
                (should (equal (line-col (point)) '(10 0))))
              (should (equal (line-col (window-point top)) '(40 3)))
              (should (equal (line-col (window-start top)) '(35 0)))
              (should (= (window-point bottom)
                         (with-current-buffer buffer (point-max))))
              (should (equal (line-col (window-start bottom))
                             (list (- 151 (window-body-height bottom)) 0)))))
        (kill-buffer buffer)
        (kill-buffer other)))))

(ert-deftest claude-code-test-sessions-point-commands-refuse-before-prompting ()
  "`r', `s' and `i' refuse a row they cannot drive before reading any input.
The gate is the live process, not the row's `alive-p': a session that ended
since the last refresh still draws as alive."
  (claude-code-tests--with-managed-buffer buf
    (let ((gone (generate-new-buffer " *cc-gone*"))
          (at-point nil) (answer nil) (driven '()))
      ;; The stale row names a buffer whose instance is already gone -- what an
      ;; unrefreshed view holds after a `/exit'.
      (kill-buffer gone)
      (cl-letf (((symbol-function 'claude-code--session-at-point)
                 (lambda () at-point))
                ((symbol-function 'claude-code--session-process)
                 (lambda (b) (and (eq b buf) 'proc)))
                ((symbol-function 'read-string)
                 (lambda (&rest _) (or answer (ert-fail "Prompted before the guard"))))
                ((symbol-function 'claude-code-send-text)
                 (lambda (s text &optional _submit)
                   (push (list 'send (claude-code-session-id s) text) driven)))
                ((symbol-function 'claude-code-interrupt)
                 (lambda (s) (push (list 'interrupt (claude-code-session-id s)) driven))))
        (claude-code-tests--in-view
          (pcase-dolist (`(,row ,message)
                         (list
                          (list nil "No session on this line")
                          (list (claude-code-session--create
                                 :id "x" :alive-p t :buffer gone)
                                "Session x has exited; press g to refresh")
                          (list (claude-code-session--create :id "e" :external-p t)
                                "Session e is running outside Emacs")
                          (list (claude-code-session--create :id "d")
                                "Session d is not alive; press RET to resume it")))
            (setq at-point row)
            (dolist (cmd '(claude-code-sessions-rename
                           claude-code-sessions-send
                           claude-code-sessions-interrupt))
              (should (equal (should-error (funcall cmd) :type 'user-error)
                             (list 'user-error message)))))
          ;; Nothing reached an operation.
          (should-not driven)
          ;; A row Emacs is still running prompts and acts.
          (setq at-point (claude-code-session--create :id "a" :alive-p t :buffer buf)
                answer "hi")
          (claude-code-sessions-rename)
          (claude-code-sessions-send)
          (claude-code-sessions-interrupt)
          (should (equal (reverse driven)
                         '((send "a" "/rename hi") (send "a" "hi")
                           (interrupt "a")))))))))

(ert-deftest claude-code-test-view-renders-and-collapses ()
  "The view prints group headers, folds Dead by default, and toggles rows."
  (claude-code-tests--with-fixtures
    (let ((buf (get-buffer-create " *cc-view-test*")))
      (unwind-protect
          (with-current-buffer buf
            (claude-code-tests--with-registry
              (claude-code-tests--with-live-pids '()
                (claude-code-sessions-mode)
                (setq claude-code--project "/home/test/proj")
                (claude-code-sessions-refresh)
                ;; The Dead group starts folded: its header shows but no rows do.
                (should (member "dead" claude-code--collapsed))
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "Dead (7)" text))
                  (should-not (string-match-p "11111111" text)))
                ;; Expanding it reveals every dead row.
                (setq claude-code--collapsed (delete "dead" claude-code--collapsed))
                (claude-code-sessions-refresh)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "Dead (7)" text))
                  (should (string-match-p "11111111" text))
                  ;; The worktree session is listed under the parent project.
                  (should (string-match-p "feat" text)))
                ;; Folding it again hides the rows.
                (push "dead" claude-code--collapsed)
                (claude-code-sessions-refresh)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "Dead (7)" text))
                  (should-not (string-match-p "11111111" text))))))
        (kill-buffer buf)))))

(ert-deftest claude-code-test-view-eldoc-recap ()
  "The view answers ElDoc with the recap of the session under point."
  ;; Pinning 1002 makes session 22222222 -- the one carrying a recap -- external
  ;; rather than dead, so the answer plainly does not turn on liveness.
  (claude-code-tests--in-fixture-view '(1002)
    (should (memq #'claude-code--eldoc-session
                  (buffer-local-value 'eldoc-documentation-functions
                                      (current-buffer))))
    (should (eldoc--supported-p))
    (setq claude-code--collapsed nil)
    (claude-code-sessions-refresh)
    (should (claude-code-tests--goto-session
             "22222222-2222-4222-8222-222222222222"))
    (should (string-prefix-p "Goal was extending the consult keybindings"
                             (claude-code--eldoc-session)))
    ;; The recap stops at the text: the CLI's `/config' note is not shown.
    (should-not (string-match-p "/config" (claude-code--eldoc-session)))
    (should (claude-code-tests--goto-session
             "11111111-1111-4111-8111-111111111111"))
    (should-not (claude-code--eldoc-session))
    (goto-char (point-min))
    (should (claude-code--group-at-point))
    (should-not (claude-code--eldoc-session))))

(ert-deftest claude-code-test-view-eldoc-leads-with-the-modifier-message ()
  "A failed turn's message heads the ElDoc answer, above the recap."
  (let ((session (claude-code-session--create
                  :id "a" :alive-p t :status "idle" :recap "Where it stood."
                  :modifier 'error :modifier-message "There's an issue")))
    (cl-letf (((symbol-function 'claude-code--session-at-point)
               (lambda () session)))
      (should (equal (claude-code--eldoc-session)
                     "There's an issue\n\nWhere it stood."))
      (setf (claude-code-session-recap session) nil)
      (should (equal (claude-code--eldoc-session) "There's an issue")))))

(ert-deftest claude-code-test-view-rooted-at-a-worktree ()
  "A view rooted at a worktree shows the running session as running.
The model answers for whatever root it is handed -- `claude-code-sessions'
hands it the parent (`claude-code--current-project'), but nothing in the model
depends on that, since a session belongs to both roots.  The row must land in
its status group, so `d' has no target there and `k' does."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer (buf 1003)
      (let ((id "33333333-3333-4333-8333-333333333333")
            (view (generate-new-buffer " *cc-view-test*")))
        (claude-code--register id buf "/home/test/proj" nil)
        (unwind-protect
            (cl-letf (((symbol-function 'claude-code--session-process)
                       (lambda (b) (eq b buf))))
              (claude-code-tests--with-live-pids '()
                (with-current-buffer view
                  (claude-code-sessions-mode)
                  (setq claude-code--project
                        (claude-code--normalize-root
                         "/home/test/proj/.claude/worktrees/feat"))
                  (claude-code-sessions-refresh)
                  (let ((text (buffer-substring-no-properties
                               (point-min) (point-max))))
                    (should (string-match-p "Waiting (1)" text))
                    (should-not (string-match-p "Dead" text)))
                  ;; Point on the row: delete finds nothing to act on, kill does.
                  (goto-char (point-min))
                  (forward-line 1)
                  (should-not (claude-code--target-sessions 'dead))
                  (should (equal (mapcar #'claude-code-session-id
                                         (claude-code--target-sessions 'alive))
                                 (list id))))))
          (kill-buffer view))))))

(ert-deftest claude-code-test-view-toggle-keeps-point ()
  "TAB leaves point on the toggled header, so TAB TAB folds and unfolds in place."
  (claude-code-tests--in-fixture-view '(1002)
    (claude-code--goto-group "dead")
    (let ((header (point)))
      ;; A header below the first line is what makes this test meaningful:
      ;; losing point would land on `point-min', not here.
      (should (> header (point-min)))
      ;; Unfold, then fold: point sits on the header either way.
      (claude-code-sessions-toggle-group)
      (should-not (member "dead" claude-code--collapsed))
      (should (equal (point) header))
      (claude-code-sessions-toggle-group)
      (should (member "dead" claude-code--collapsed))
      (should (equal (point) header))
      ;; From a row inside the group, folding falls back to the header.
      (claude-code-sessions-toggle-group)
      (forward-line 1)
      (should (claude-code--session-at-point))
      (claude-code-sessions-toggle-group)
      (should (member "dead" claude-code--collapsed))
      (should (equal (point) header)))))

(ert-deftest claude-code-test-view-line-motion-with-n-and-p ()
  "`n' and `p' are Emacs's own line motion, and `c' opens the create menu.
The view binds neither, so motion is `tabulated-list-mode-map's `next-line' and
`previous-line': a line at a time, group headers included."
  (claude-code-tests--in-fixture-view '(1002)
    (should (eq (keymap-lookup claude-code-sessions-mode-map "n") #'next-line))
    (should (eq (keymap-lookup claude-code-sessions-mode-map "p")
                #'previous-line))
    (should (eq (keymap-lookup claude-code-sessions-mode-map "c")
                #'claude-code-spawn-menu))
    (setq claude-code--collapsed nil)
    (claude-code-sessions-refresh)
    (claude-code--goto-group "dead")
    (let ((header (point))
          ;; Batch has no window to move by visual lines in.
          (line-move-visual nil)
          (down (keymap-lookup claude-code-sessions-mode-map "n"))
          (up (keymap-lookup claude-code-sessions-mode-map "p")))
      ;; Down from a header onto its first row, and on to the next row.
      (call-interactively down)
      (let ((first (tabulated-list-get-id)))
        (should first)
        (call-interactively down)
        (should (tabulated-list-get-id))
        (should-not (equal (tabulated-list-get-id) first))
        (call-interactively up)
        (should (equal (tabulated-list-get-id) first)))
      ;; Up from the first row lands on the header, which carries no session.
      (call-interactively up)
      (should (equal (point) header))
      (should-not (tabulated-list-get-id)))))

(ert-deftest claude-code-test-view-refresh-keeps-the-row-at-point ()
  "`g' leaves point on its row, which is what `claude-code--redraw' asks for."
  (claude-code-tests--in-fixture-view '(1002)
    (setq claude-code--collapsed nil)
    (claude-code-sessions-refresh)
    (claude-code--goto-group "dead")
    (forward-line 1)
    (let ((id (tabulated-list-get-id)))
      (should id)
      (claude-code-sessions-refresh)
      (should (equal (tabulated-list-get-id) id)))))

(ert-deftest claude-code-test-view-pins-its-directories ()
  "Opening the view points both directory variables at the root, and it sticks."
  (claude-code-tests--with-fixtures
    (let ((root "/home/test/proj")
          (buf nil))
      (unwind-protect
          (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _dir) 'proj))
                    ((symbol-function 'project-root) (lambda (_p) root))
                    ((symbol-function 'pop-to-buffer) (lambda (b &rest _) (setq buf b))))
            ;; Opening the view runs a real refresh over the fixtures; the pin
            ;; must outlive it, so the refresh is deliberately not stubbed out.
            (claude-code-sessions)
            (with-current-buffer buf
              (should (derived-mode-p 'claude-code-sessions-mode))
              (should (equal claude-code--project (claude-code--normalize-root root)))
              (should (equal default-directory
                             (file-name-as-directory
                              (claude-code--normalize-root root))))
              (should (local-variable-p 'list-buffers-directory))
              (should (equal list-buffers-directory
                             (file-name-as-directory
                              (claude-code--normalize-root root))))
              ;; Unabbreviated, or `ibuffer's filename filters miss the view.
              (should (equal list-buffers-directory
                             (expand-file-name list-buffers-directory)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest claude-code-test-view-commands-are-view-scoped ()
  "Every view command carries the mode tag and refuses other buffers.
The commands are found by naming convention, so a new sessions command is
held to the same contract without touching this test.  Refusing means
failing before doing anything: no prompt is read and no buffer-local state
is created in the foreign buffer."
  (let ((cmds nil)
        (prompt (lambda (&rest _) (ert-fail "Prompted before the guard"))))
    (mapatoms (lambda (sym)
                (when (and (commandp sym)
                           (string-prefix-p "claude-code-sessions-"
                                            (symbol-name sym))
                           ;; The mode function shares the prefix but is not
                           ;; a view command.
                           (not (eq sym 'claude-code-sessions-mode)))
                  (push sym cmds))))
    (should (<= 12 (length cmds)))
    (cl-letf (((symbol-function 'read-string) prompt)
              ((symbol-function 'y-or-n-p) prompt)
              ((symbol-function 'yes-or-no-p) prompt))
      (dolist (cmd cmds)
        (should (equal (command-modes cmd) '(claude-code-sessions-mode)))
        (with-temp-buffer
          ;; The guard's own error, not an incidental one from deeper in the
          ;; command (kill/delete signal a user-error even without the guard).
          (should (equal (should-error (funcall cmd) :type 'user-error)
                         '(user-error "Not in a Claude sessions buffer")))
          (should-not
           (seq-filter (lambda (local)
                         (string-prefix-p
                          "claude-code-"
                          (symbol-name (if (consp local) (car local) local))))
                       (buffer-local-variables))))))))

(defun claude-code-tests--view-buffers ()
  "Return the sessions-view buffers that exist right now.
Tests diff this around an act rather than asserting over the whole
`buffer-list', so a real view left open by the Emacs running the suite (as
`M-x ert' has) cannot fail them."
  (seq-filter (lambda (buffer)
                (string-prefix-p "*claude-sessions: " (buffer-name buffer)))
              (buffer-list)))

(defun claude-code-tests--open-view (root)
  "Return the buffer `claude-code-sessions' opens for ROOT.
`project.el' and the window are stubbed: which buffer the entry point picks is
what is under test, not where it displays it.  Stubbing `pop-to-buffer' also
keeps the act from reordering `buffer-list', which the pick reads."
  (let ((shown nil))
    (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _dir) 'proj))
              ((symbol-function 'project-root) (lambda (_p) root))
              ((symbol-function 'pop-to-buffer) (lambda (b &rest _) (setq shown b))))
      (claude-code-sessions))
    shown))

(ert-deftest claude-code-test-view-per-project-not-per-name ()
  "Two projects sharing a basename get two independent views.
A view is identified by the project it names, so opening the second must not
land in the first's buffer and silently re-scope it -- which would leave the
first project with no view at all."
  (claude-code-tests--with-fixtures
    (let ((a nil) (b nil))
      (unwind-protect
          (progn
            (setq a (claude-code-tests--open-view "/home/test/proj"))
            (setq b (claude-code-tests--open-view "/home/other/proj"))
            (should-not (eq a b))
            (with-current-buffer a
              (should (equal claude-code--project
                             (claude-code--normalize-root "/home/test/proj")))
              (should (< 0 (hash-table-count claude-code--session-table))))
            (with-current-buffer b
              (should (equal claude-code--project
                             (claude-code--normalize-root "/home/other/proj")))
              (should (zerop (hash-table-count claude-code--session-table))))
            ;; Both are views, so a mutation redrawing every view reaches both.
            (should (memq a (claude-code--views)))
            (should (memq b (claude-code--views))))
        (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
              (list a b))))))

(ert-deftest claude-code-test-view-reopens-a-renamed-view ()
  "Reopening a project reuses its view, including one the user renamed.
Identity is the project, not the buffer name, so the rename is honoured rather
than answered with a second view.  Reuse also leaves the mode alone: re-running
it would reset the grouping and collapse state the user set, so the listing is
compared across the reopen."
  (claude-code-tests--with-fixtures
    (let ((view nil))
      (unwind-protect
          (progn
            (setq view (claude-code-tests--open-view "/home/test/proj"))
            (with-current-buffer view
              (rename-buffer "*pinned proj sessions*")
              (claude-code-sessions-cycle-grouping)
              (goto-char (point-min))
              (claude-code-sessions-toggle-group))
            (let ((listing (with-current-buffer view (buffer-string))))
              (should (eq view (claude-code-tests--open-view "/home/test/proj")))
              (should (equal (with-current-buffer view (buffer-string)) listing))))
        (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest claude-code-test-view-does-not-adopt-a-foreign-buffer ()
  "A buffer that merely carries the view's name is left alone.
Adopting one would put the listing where the user's data was."
  (claude-code-tests--with-fixtures
    (let ((foreign (generate-new-buffer "*claude-sessions: proj*"))
          (view nil))
      (unwind-protect
          (progn
            (with-current-buffer foreign (insert "not a sessions view"))
            (setq view (claude-code-tests--open-view "/home/test/proj"))
            (should-not (eq view foreign))
            (with-current-buffer foreign
              (should (eq major-mode 'fundamental-mode))
              (should (equal (buffer-string) "not a sessions view"))))
        (kill-buffer foreign)
        (when (buffer-live-p view) (kill-buffer view))))))

(ert-deftest claude-code-test-project-root-may-prompt ()
  "Resolving through `project.el' lets it prompt when the buffer has no project."
  (let ((maybe-prompt 'unset))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&optional prompt &rest _) (setq maybe-prompt prompt) 'proj))
              ((symbol-function 'project-root) (lambda (_p) "/home/test/picked")))
      (with-temp-buffer
        (should (equal (claude-code--project-root)
                       (claude-code--normalize-root "/home/test/picked")))
        (should maybe-prompt)))))

(ert-deftest claude-code-test-current-project-resolves-a-worktree ()
  "A buffer inside a worktree acts on the parent, naming the worktree it sits in.
`project.el' calls the worktree a project of its own; a sessions view is already
scoped and is never redirected."
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) 'proj)))
    (cl-letf (((symbol-function 'project-root)
               (lambda (_p) "/home/test/proj/.claude/worktrees/my.feat")))
      (with-temp-buffer
        (should (equal (claude-code--current-project)
                       (cons (claude-code--normalize-root "/home/test/proj")
                             "my.feat")))))
    (cl-letf (((symbol-function 'project-root) (lambda (_p) "/home/test/proj")))
      (with-temp-buffer
        (should (equal (claude-code--current-project)
                       (cons (claude-code--normalize-root "/home/test/proj")
                             nil)))))
    ;; A view names its project, worktree or not, and is taken at its word.
    (claude-code-tests--in-view
      (setq-local claude-code--project "/home/test/proj/.claude/worktrees/feat")
      (should (equal (claude-code--current-project)
                     '("/home/test/proj/.claude/worktrees/feat" . nil))))))

(ert-deftest claude-code-test-current-project-of-an-instance ()
  "An instance buffer acts on the project it was launched from.
The worktree is the one of that project the instance works in now.  Wherever
else it works decides nothing, so the view it opens stays the same and a
checkout the menu could not name is not offered."
  (claude-code-tests--with-managed-buffer buf
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) (ert-fail "Asked `project.el'"))))
      (with-current-buffer buf
        (pcase-dolist (`(,origin ,here ,project)
                       '(("/home/test/proj" "/home/test/proj/"
                          ("/home/test/proj" . nil))
                         ("/home/test/proj" "/home/test/proj/.claude/worktrees/feat/"
                          ("/home/test/proj" . "feat"))
                         ;; Launched from a worktree, Claude built a sibling.
                         ("/home/test/proj/.claude/worktrees/feat"
                          "/home/test/proj/.claude/worktrees/fix/"
                          ("/home/test/proj" . "fix"))
                         ("/home/test/proj" "/home/test/checkouts/feat/"
                          ("/home/test/proj" . nil))
                         ("/home/test/proj" "/home/test/other/.claude/worktrees/feat/"
                          ("/home/test/proj" . nil))))
          (claude-code--register "id" buf origin nil)
          (setq default-directory here)
          (should (equal (claude-code--current-project) project)))))))

(ert-deftest claude-code-test-project-switch-outranks-the-buffer-project ()
  "The create menu opens on the project `project-switch-project' picked."
  (claude-code-tests--with-managed-buffer buf
    (let ((menus '())
          (project-switch-commands #'claude-code-spawn-menu))
      (cl-letf (((symbol-function 'project-current)
                 (lambda (&optional _ dir)
                   (or dir project-current-directory-override default-directory)))
                ((symbol-function 'project-root) #'identity)
                ;; Keep the pick out of the user's project list.
                ((symbol-function 'project--remember-dir) #'ignore)
                ((symbol-function 'claude-code--seed-worktree)
                 (lambda (_obj worktree) worktree))
                ((symbol-function 'transient-setup)
                 (lambda (_name _layout _edit &rest props)
                   (push (cons (plist-get props :scope)
                               (and-let* ((seed (plist-get props :init-value)))
                                 (funcall seed nil)))
                         menus))))
        (claude-code-tests--in-view
          (setq-local claude-code--project "/home/test/proj")
          (project-switch-project "/home/test/other/"))
        (claude-code--register "id" buf "/home/test/proj" nil)
        (with-current-buffer buf
          (project-switch-project "/home/test/other/.claude/worktrees/feat/")))
      (let ((other (claude-code--normalize-root "/home/test/other")))
        (should (equal (reverse menus)
                       (list (cons other nil) (cons other "feat"))))))))

(ert-deftest claude-code-test-spawn-menu-resolves-project-up-front ()
  "The menu resolves the project into its scope and opens no view to do it.
A sessions view names its own project without consulting `project.el'; any
other buffer asks `project.el', which prompts when the buffer has no project."
  (let ((scopes '())
        (views-before (claude-code-tests--view-buffers)))
    (cl-letf (((symbol-function 'transient-setup)
               (lambda (&rest args) (push (plist-get (nthcdr 3 args) :scope) scopes)))
              ((symbol-function 'claude-code-sessions)
               (lambda () (ert-fail "Opened the sessions view"))))
      (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _dir) 'proj))
                ((symbol-function 'project-root) (lambda (_p) "/home/test/proj")))
        (with-temp-buffer (claude-code-spawn-menu)))
      ;; In a view the buffer-local project wins, so `project.el' is never asked
      ;; -- which is what makes the menu work in a view for a directory the
      ;; selected buffer knows nothing about.
      (cl-letf (((symbol-function 'project-current)
                 (lambda (&rest _) (ert-fail "Consulted project.el in a view"))))
        (claude-code-tests--in-view
          (setq-local claude-code--project "/home/test/other")
          (claude-code-spawn-menu)))
      (should (equal (reverse scopes)
                     (list (claude-code--normalize-root "/home/test/proj")
                           "/home/test/other")))
      (should-not (seq-difference (claude-code-tests--view-buffers) views-before)))))

(ert-deftest claude-code-test-spawn-args-require-live-menu ()
  "A direct call spawns with no options; only a live menu's scope and args apply."
  (let ((spawn-args nil))
    (cl-letf (((symbol-function 'claude-code-spawn)
               (lambda (root &rest kw) (setq spawn-args (cons root kw))))
              ((symbol-function 'claude-code--refresh-views) #'ignore)
              ((symbol-function 'claude-code--show) #'ignore)
              ;; Stubbed at the real arity, which the transient built into
              ;; Emacs 30 caps at zero.
              ((symbol-function 'transient-scope) (lambda () "/scoped"))
              ;; Transient signals on a nil prefix, so hold the command to that
              ;; contract whichever version is installed.
              ((symbol-function 'transient-args)
               (lambda (prefix)
                 (unless prefix (error "Not a transient prefix: nil"))
                 '("--worktree" "--model=opus" "--effort=xhigh"
                   "--name=a long name"))))
      (claude-code-tests--in-view
        (setq-local claude-code--project "/r")
        (let ((transient-current-command nil))
          (call-interactively #'claude-code--spawn-session))
        (should (equal spawn-args
                       '("/r" :name nil :worktree nil :model nil :effort nil)))
        ;; With a menu live the root comes from its scope, not from whichever
        ;; buffer the suffix happens to run in.
        (let ((transient-current-command 'claude-code-spawn-menu))
          (call-interactively #'claude-code--spawn-session))
        (should (equal spawn-args
                       '("/scoped" :name "a long name" :worktree t
                         :model "opus" :effort "xhigh")))))))

(defmacro claude-code-tests--driving-spawn-menu (spawns &rest body)
  "Run BODY able to work the real menu, pushing (ROOT . OPTIONS) onto SPAWNS.
Nothing about transient is stubbed: BODY drives the menu with
`execute-kbd-macro', and the project it resolves is \"/home/test/proj\".  The
menu opens with no value set and the state it leaves behind is put back
afterwards -- the value a `transient-set' pins and the history an infix read
records -- so a suite run inside a live Emacs (as `M-x ert' is) neither reads
nor disturbs the user's own menu."
  (declare (indent 1))
  `(let* ((,spawns '())
          (instance (generate-new-buffer " *cc-instance*"))
          (prefix (get 'claude-code-spawn-menu 'transient--prefix))
          (set-p (slot-boundp prefix 'value))
          (set-value (and set-p (oref prefix value)))
          (transient-history (copy-tree transient-history)))
     (slot-makeunbound prefix 'value)
     (unwind-protect
         (cl-letf (((symbol-function 'claude-code-spawn)
                    (lambda (root &rest options)
                      (push (cons root options) ,spawns)
                      (cons "spawned-id" instance)))
                   ((symbol-function 'claude-code--refresh-views) #'ignore)
                   ((symbol-function 'claude-code--show) #'ignore)
                   ((symbol-function 'project-current) (lambda (&rest _) 'proj))
                   ((symbol-function 'project-root)
                    (lambda (_project) "/home/test/proj")))
           ,@body)
       ;; A failure mid-macro would otherwise leave transient's keymap on
       ;; `overriding-terminal-local-map' and its hooks armed for every later
       ;; test, hiding the real failure behind unrelated ones.
       (transient--emergency-exit)
       (if set-p (oset prefix value set-value) (slot-makeunbound prefix 'value))
       (when (buffer-live-p instance) (kill-buffer instance)))))

(ert-deftest claude-code-test-spawn-menu-scope-reaches-the-suffix ()
  "The real menu carries its project through to the spawn.
Driven through transient itself, keys and all: handing the project down as the
prefix's scope is what frees the menu from the view, so nothing about transient
is stubbed here."
  (claude-code-tests--driving-spawn-menu spawns
    (with-temp-buffer
      (claude-code-spawn-menu)
      ;; `-n' reads a name, `-w' reads a worktree -- answered with the
      ;; candidate that leaves the naming to Claude -- and `c' creates the
      ;; session.
      (execute-kbd-macro (kbd "- n r e v i e w RET - w ( a u t o ) RET c")))
    (should (equal (car spawns)
                   (list (claude-code--normalize-root "/home/test/proj")
                         :name "review" :worktree t
                         :model nil :effort nil)))))

(ert-deftest claude-code-test-spawn-menu-worktree-by-name ()
  "The one worktree key takes a name, and a second press withdraws the request.
Driven through the real menu, since which argument an answer reaches the CLI as
is what `claude-code--worktree-infix' decides."
  (claude-code-tests--driving-spawn-menu spawns
    (with-temp-buffer
      (claude-code-spawn-menu)
      (execute-kbd-macro (kbd "- w f e a t RET c")))
    (with-temp-buffer
      (claude-code-spawn-menu)
      (execute-kbd-macro (kbd "- w f e a t RET - w c")))
    (should (equal (mapcar (lambda (spawn) (plist-get (cdr spawn) :worktree))
                           (reverse spawns))
                   '("feat" nil)))))

(ert-deftest claude-code-test-spawn-menu-completes-over-the-scope ()
  "The worktree reader offers the scoped project's checkouts, not the buffer's.
The menu works for a project the current buffer knows nothing about, so its
scope -- not `default-directory' -- has to be what the candidates come from."
  (let ((root (file-truename (make-temp-file "cc-root" t)))
        (asked nil))
    (unwind-protect
        (progn
          (make-directory (claude-code--worktree-path root "feat") t)
          (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) root))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _)
                       (setq asked candidates)
                       "feat")))
            (with-temp-buffer
              (should (equal (claude-code--read-worktree "w: " nil nil) "feat"))))
          (should (equal asked (list claude-code--worktree-auto "feat")))
          ;; The label is answered as the empty string, which is the unnamed
          ;; request; a real worktree could not be called that.
          (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) root))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) claude-code--worktree-auto)))
            (should (equal (claude-code--read-worktree "w: " nil nil) ""))))
      (delete-directory root t))))

(ert-deftest claude-code-test-spawn-menu-seeds-the-worktree-it-opened-in ()
  "The menu opened from inside a worktree scopes to the parent and asks for it.
The seeded request is what keeps the session in that worktree rather than
beside it, and it outranks -- without displacing -- the options the user
pinned."
  (claude-code-tests--driving-spawn-menu spawns
    (let ((prefix (get 'claude-code-spawn-menu 'transient--prefix)))
      (oset prefix value '("--model=opus")))
    (cl-letf (((symbol-function 'project-root)
               (lambda (_project) "/home/test/proj/.claude/worktrees/my.feat")))
      (with-temp-buffer
        (claude-code-spawn-menu)
        (execute-kbd-macro (kbd "c"))))
    (should (equal (car spawns)
                   (list (claude-code--normalize-root "/home/test/proj")
                         :name nil :worktree "my.feat"
                         :model "opus" :effort nil)))))

(ert-deftest claude-code-test-spawn-menu-forgets-the-worktree ()
  "A worktree is spent on the session it spawns, and a seeded one is refusable.
The infix is `:unsavable', so `transient-set' cannot pin a worktree onto later
spawns -- which would put every project's sessions in a checkout named after
one of them.  A seeded request is an ordinary infix value, so the first press
withdraws it."
  (claude-code-tests--driving-spawn-menu spawns
    (cl-letf (((symbol-function 'project-root)
               (lambda (_project) "/home/test/proj/.claude/worktrees/my.feat")))
      (with-temp-buffer
        (claude-code-spawn-menu)
        (execute-kbd-macro (kbd "- m o p u s RET"))
        (call-interactively #'transient-set)
        (execute-kbd-macro (kbd "- w c"))))
    ;; Back in the parent, with only the pinned model to inherit.
    (with-temp-buffer
      (claude-code-spawn-menu)
      (execute-kbd-macro (kbd "c")))
    (should (equal (mapcar (lambda (spawn)
                             (list (plist-get (cdr spawn) :worktree)
                                   (plist-get (cdr spawn) :model)))
                           (reverse spawns))
                   '((nil "opus") (nil "opus"))))))

(ert-deftest claude-code-test-worktree-infix-round-trip ()
  "The worktree infix emits both spellings and reads both back.
A class that emitted an argument it could not parse again would lose the
request the moment the menu redrew from its own value."
  (let ((obj (claude-code--worktree-infix :argument "--worktree=")))
    (oset obj value nil)
    (should-not (transient-infix-value obj))
    (oset obj value "")
    (should (equal (transient-infix-value obj) "--worktree"))
    (oset obj value "my.feat")
    (should (equal (transient-infix-value obj) "--worktree=my.feat")))
  (pcase-dolist (`(,args ,value)
                 '((nil nil)
                   (("--model=opus") nil)
                   (("--worktree") "")
                   (("--model=opus" "--worktree=my.feat") "my.feat")))
    (let ((prefix (transient-prefix :command 'claude-code-spawn-menu))
          (obj (claude-code--worktree-infix :argument "--worktree=")))
      (oset prefix value args)
      (let ((transient--prefix prefix))
        (transient-init-value obj))
      (should (equal (oref obj value) value)))))

(ert-deftest claude-code-test-spawn-menu-forgets-the-name ()
  "A name is spent on the session it spawns; a later menu never reoffers it.
Transient drops a prefix's value when the menu exits, and the name infix is
`:unsavable', so even the value `transient-set' pins for later spawns -- the
model here -- carries no name into them."
  (claude-code-tests--driving-spawn-menu spawns
    (with-temp-buffer
      (claude-code-spawn-menu)
      (execute-kbd-macro (kbd "- n r e v i e w RET - m o p u s RET"))
      ;; `transient-set' is called rather than keyed: which key runs it is
      ;; transient's business, and the menu stays up either way.
      (call-interactively #'transient-set)
      (execute-kbd-macro (kbd "c")))
    (with-temp-buffer
      (claude-code-spawn-menu)
      (execute-kbd-macro (kbd "c")))
    (should (equal (mapcar (lambda (spawn)
                             (list (plist-get (cdr spawn) :name)
                                   (plist-get (cdr spawn) :model)))
                           (reverse spawns))
                   '(("review" "opus") (nil "opus"))))))

(ert-deftest claude-code-test-mutations-refresh-every-view ()
  "Spawn, resume, kill and delete redraw every sessions view, displayed or not.
A view of another project is included: no view owns a session, so redrawing only
the acting view's root would leave a view of the same session stale."
  (let* ((root (claude-code--normalize-root "/home/test/proj"))
         (redrawn '())
         (ever-redrawn '())
         (acting (generate-new-buffer " *cc-view-acting*"))
         (sibling (generate-new-buffer " *cc-view-sibling*"))
         (other (generate-new-buffer " *cc-view-other*"))
         (instance (generate-new-buffer " *cc-instance*"))
         (alive (claude-code-session--create :id "a" :alive-p t))
         (dead (claude-code-session--create :id "d"))
         (projectless (generate-new-buffer " *cc-view-projectless*"))
         (all (sort (mapcar #'buffer-name (list acting sibling other)) #'string<))
         ;; Only this test's views are asserted over: a real view left open by
         ;; the Emacs running the suite is one of `claude-code--views' too.
         (redrawn-since
          (lambda () (prog1 (sort (seq-filter (lambda (name) (member name redrawn))
                                              all)
                                  #'string<)
                       (setq redrawn nil)))))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code--redraw)
                   (lambda (&rest _)
                     (push (buffer-name) redrawn)
                     (push (buffer-name) ever-redrawn)))
                  ((symbol-function 'claude-code-spawn)
                   (lambda (&rest _) (cons "spawned-id" instance)))
                  ((symbol-function 'claude-code--resume) (lambda (&rest _) instance))
                  ((symbol-function 'claude-code-kill) #'ignore)
                  ((symbol-function 'claude-code-delete) #'ignore)
                  ;; Both the spawn and the resume RET drives display through
                  ;; the one policy.
                  ((symbol-function 'claude-code--show) #'ignore)
                  ((symbol-function 'yes-or-no-p) (lambda (_) t)))
          (pcase-dolist (`(,buffer . ,project)
                         (list (cons acting root)
                               (cons sibling root)
                               (cons other (claude-code--normalize-root
                                            "/home/test/elsewhere"))
                               ;; A buffer left in the mode by hand names no
                               ;; project, so it has nothing to list.
                               (cons projectless nil)))
            (with-current-buffer buffer
              (claude-code-sessions-mode)
              (setq claude-code--project project)))
          ;; Spawning from outside any view still reaches all of them.
          (with-temp-buffer (claude-code--spawn-session root))
          (should (equal (funcall redrawn-since) all))
          (with-current-buffer acting
            (cl-letf (((symbol-function 'claude-code--session-at-point)
                       (lambda () dead)))
              (claude-code-sessions-visit))
            (should (equal (funcall redrawn-since) all))
            (puthash "a" alive claude-code--session-table)
            (setq claude-code--marks (list "a"))
            (claude-code-sessions-kill)
            (should (equal (funcall redrawn-since) all))
            (puthash "d" dead claude-code--session-table)
            (setq claude-code--marks (list "d"))
            (claude-code-sessions-delete)
            (should (equal (funcall redrawn-since) all)))
          ;; The project-less buffer was never asked to list anything, which is
          ;; what keeps a mutation from erroring on it and stranding the rest.
          (should-not (member (buffer-name projectless) ever-redrawn)))
      (mapc #'kill-buffer
            (list acting sibling other projectless instance)))))

(ert-deftest claude-code-test-spawn-displays-the-instance ()
  "A spawn displays its instance through `claude-code--show', from any buffer.
Where an instance lands is one decision, made in one place; `RET' reaching the
same policy is `claude-code-test-sessions-visit-dispatch'."
  (let ((shown '())
        (instance (generate-new-buffer " *cc-instance*")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-spawn)
                   (lambda (&rest _) (cons "spawned-id" instance)))
                  ((symbol-function 'claude-code--refresh-views) #'ignore)
                  ((symbol-function 'claude-code--show)
                   (lambda (b &rest _) (push b shown))))
          (with-temp-buffer (claude-code--spawn-session "/r"))
          (should (equal shown (list instance))))
      (kill-buffer instance))))

(ert-deftest claude-code-test-show-takes-a-view-window ()
  "`claude-code--show' takes a sessions view's window, and no other buffer's.
Run against real windows."
  (let ((instance (generate-new-buffer " *cc-instance*"))
        (occupant (generate-new-buffer " *cc-occupant*"))
        (view (generate-new-buffer " *cc-view*"))
        (other-view (generate-new-buffer " *cc-other-view*"))
        (projectless (generate-new-buffer " *cc-projectless*")))
    (unwind-protect
        ;; Nothing of the user's may decide the outcome: the three variables
        ;; `display-buffer' consults before this function's own action, the
        ;; pop-up and split settings, and the window parameters that would
        ;; otherwise make `delete-other-windows' refuse (from a side window) or
        ;; leave a `no-delete-other-windows' sibling standing.
        ;; `save-window-excursion' restores the layout, so the suite is safe to
        ;; run from `M-x ert' in a live frame and not only in batch.
        (let ((display-buffer-overriding-action nil)
              (display-buffer-alist nil)
              (display-buffer-base-action nil)
              (pop-up-windows t)
              (pop-up-frames nil)
              (split-window-preferred-function #'split-window-sensibly)
              (split-height-threshold 4)
              (split-width-threshold nil)
              (ignore-window-parameters t))
          (dolist (b (list view other-view projectless))
            (with-current-buffer b
              (claude-code-sessions-mode)
              (unless (eq b projectless)
                (setq claude-code--project "/r"))))
          (cl-flet ((reset (buffer)
                      (delete-other-windows)
                      (set-window-buffer (selected-window) buffer)
                      (selected-window))
                    (shown-in-p (window)
                      (and (eq (selected-window) window)
                           (eq (window-buffer window) instance))))
            (save-window-excursion
              (let ((kept (reset occupant)))
                (claude-code--show instance)
                (should (eq (window-buffer kept) occupant))
                (should (eq (window-buffer (selected-window)) instance)))

              (dolist (buffer (list view instance))
                (let ((selected (reset buffer)))
                  (claude-code--show instance)
                  (should (shown-in-p selected))
                  (should (= (length (window-list)) 1))))

              (let* ((kept (reset occupant))
                     (beside (split-window)))
                (set-window-buffer beside view)
                (claude-code--show instance)
                (should (shown-in-p beside))
                (should (eq (window-buffer kept) occupant)))

              (let* ((selected (reset view))
                     (beside (split-window)))
                (set-window-buffer beside other-view)
                (claude-code--show instance)
                (should (shown-in-p selected))
                (should (eq (window-buffer beside) other-view)))

              ;; Neither a dedicated view nor a sessions buffer naming no
              ;; project is a target.
              (dolist (buffer (list view projectless))
                (let* ((kept (reset occupant))
                       (beside (split-window)))
                  (set-window-buffer beside buffer)
                  (set-window-dedicated-p beside (eq buffer view))
                  (claude-code--show instance)
                  (should (eq (window-buffer beside) buffer))
                  (should (eq (window-buffer kept) occupant))
                  (should (eq (window-buffer (selected-window)) instance))))

              ;; Which window a selected side window sends the instance to is
              ;; `display-buffer''s business; that it is not this one is not.
              (dolist (select-side '(nil t))
                (let ((kept (reset occupant))
                      (side (display-buffer
                             view '(display-buffer-in-side-window (side . bottom)))))
                  (when select-side
                    (select-window side))
                  (claude-code--show instance)
                  (should (eq (window-buffer side) view))
                  (should (eq (window-dedicated-p side) 'side))
                  (unless select-side
                    (should (eq (window-buffer kept) occupant)))
                  (should (eq (window-buffer (selected-window)) instance))))

              (dolist (selected-buffer (list occupant view))
                (reset selected-buffer)
                (let ((elsewhere (split-window)))
                  (set-window-buffer elsewhere instance)
                  (claude-code--show instance)
                  (should (shown-in-p elsewhere))
                  (should (= (length (get-buffer-window-list instance nil t)) 1))))

              ;; The user's entry gets the last word, even one the view beside
              ;; would otherwise outrank.
              (let* ((kept (reset occupant))
                     (beside (split-window))
                     (display-buffer-alist
                      `((,(regexp-quote (buffer-name instance))
                         display-buffer-same-window))))
                (set-window-buffer beside view)
                (claude-code--show instance)
                (should (shown-in-p kept))
                (should (eq (window-buffer beside) view))))))
      (mapc #'kill-buffer (list instance occupant view other-view projectless)))))

(ert-deftest claude-code-test-command-surface ()
  "The spawn menu's suffix is never offered by `M-x'; the entry points always are.
Under Emacs's own predicate the mode tags scope the view's commands out, leaving
the entry points alone.  Transient installs a predicate that ignores mode tags,
so there the view's commands are offered too and each one's guard is the real
boundary -- but the suffix stays hidden either way, which is what its
`completion-predicate' buys.  Only commands this package defines are considered,
so an unrelated `claude-code'-prefixed package cannot fail this."
  (let ((ours '())
        (entry-points (seq-filter #'fboundp '(claude-code-sessions
                                              claude-code-spawn-menu
                                              claude-code-sessions-mode
                                              claude-code-mcp-stop))))
    (mapatoms (lambda (sym)
                (when (and (commandp sym)
                           (member (file-name-base (or (symbol-file sym 'defun) ""))
                                   '("claude-code" "claude-code-mcp")))
                  (push sym ours))))
    (should (memq 'claude-code--spawn-session ours))
    (with-temp-buffer
      (let ((offered (lambda (predicate)
                       (sort (seq-filter (lambda (sym)
                                           (funcall predicate sym (current-buffer)))
                                         ours)
                             #'string<))))
        (should (equal (funcall offered #'command-completion-default-include-p)
                       (sort entry-points #'string<)))
        (should-not (memq 'claude-code--spawn-session
                          (funcall offered
                                   #'transient-command-completion-not-suffix-only-p)))))))

(defun claude-code-tests--tagged-ids ()
  "Return, sorted, the ids of the rows currently showing a `*' mark tag."
  (let (ids)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (and (tabulated-list-get-id)
                   (string-prefix-p
                    "*" (buffer-substring-no-properties
                         (line-beginning-position)
                         (+ (line-beginning-position) tabulated-list-padding))))
          (push (tabulated-list-get-id) ids))
        (forward-line 1)))
    (sort ids #'string<)))

(ert-deftest claude-code-test-view-marks-survive-every-reprint ()
  "Marks stay painted through reprints that never reach `claude-code--redraw'."
  (claude-code-tests--in-fixture-view '(1002)
    (setq claude-code--collapsed nil)
    (claude-code-sessions-refresh)
    (claude-code--goto-group "dead")
    (forward-line 1)
    ;; `m' advances, so this marks two consecutive rows.
    (claude-code-sessions-mark)
    (claude-code-sessions-mark)
    (let ((marked (sort (copy-sequence claude-code--marks) #'string<)))
      (should (= (length marked) 2))
      (should (equal marked (claude-code-tests--tagged-ids)))
      (dolist (reprint (list #'claude-code-sessions-refresh
                             ;; Column 6 is Name.  This is what `S' runs, and a
                             ;; header click funnels into the same place.
                             (lambda () (tabulated-list-sort 6))
                             #'revert-buffer
                             (lambda () (tabulated-list-widen-current-column 1))))
        ;; Park on a marked row: the width commands read the entry at point.
        (claude-code-tests--goto-session (car marked))
        (funcall reprint)
        (should (equal marked (claude-code-tests--tagged-ids)))))))

(ert-deftest claude-code-test-view-restore-original-order-is-harmless ()
  "`C-u -1 S' does not signal: it sorts `tabulated-list-entries' directly."
  (claude-code-tests--in-fixture-view '(1002)
    (should-not (functionp tabulated-list-entries))
    ;; The first sort is what arms it: it leaves a `tabulated-list--original-
    ;; order' behind, which is the only guard on the `-1' branch.
    (tabulated-list-sort 6)
    (tabulated-list-sort -1)
    (should (string-match-p "Dead" (buffer-string)))))

(ert-deftest claude-code-test-view-collapsed-group-reports-its-marks ()
  "A folded group reports how many of the rows it hides are marked."
  (claude-code-tests--in-fixture-view '(1002)
    (setq claude-code--collapsed nil)
    (claude-code-sessions-refresh)
    (claude-code--goto-group "dead")
    (should (string-match-p "^▾ Dead (6)$" (thing-at-point 'line t)))
    ;; `m' advances, so this marks two of the six dead rows.
    (forward-line 1)
    (claude-code-sessions-mark)
    (claude-code-sessions-mark)
    (claude-code--goto-group "dead")
    ;; Their tags are on screen, so the header adds nothing.
    (should (string-match-p "^▾ Dead (6)$" (thing-at-point 'line t)))
    (claude-code-sessions-toggle-group)
    (should (member "dead" claude-code--collapsed))
    (should (equal 2 (length claude-code--marks)))
    (should (null (claude-code-tests--tagged-ids)))
    (should (string-match-p "^▸ Dead (6, 2 marked)$" (thing-at-point 'line t)))
    ;; Unfolding hands the rows back their tags.
    (claude-code-sessions-toggle-group)
    (should (string-match-p "^▾ Dead (6)$" (thing-at-point 'line t)))
    (should (equal 2 (length (claude-code-tests--tagged-ids))))))

(ert-deftest claude-code-test-view-collapsed-group-reports-its-modifiers ()
  "A folded group counts the status modifiers of the rows it hides.
They follow its marks, and an expanded group shows the glyphs themselves."
  (claude-code-tests--in-view
    (let ((sessions (mapcar (lambda (spec)
                              (claude-code-session--create
                               :id (car spec) :alive-p t :status "idle"
                               :modifier (cdr spec)))
                            '(("a" . done) ("b" . done) ("c" . error)
                              ("d") ("e")))))
      (cl-letf (((symbol-function 'claude-code-project-sessions)
                 (lambda (_) sessions)))
        (setq claude-code--marks '("d" "e"))
        (setq claude-code--collapsed (list "idle"))
        (should (equal (substring-no-properties
                        (car (car (claude-code--tabulated-groups))))
                       "▸ Idle (5, 2 marked, 2 done, 1 error)"))
        (setq claude-code--collapsed nil)
        (should (equal (substring-no-properties
                        (car (car (claude-code--tabulated-groups))))
                       "▾ Idle (5)"))))))

(ert-deftest claude-code-test-view-sorts-by-modifier ()
  "`S' on the Status column sorts each group by status modifier."
  (claude-code-tests--in-view
    (let ((sessions (mapcar (lambda (spec)
                              (claude-code-session--create
                               :id (car spec) :alive-p t :status "idle"
                               :modifier (cdr spec)))
                            '(("a" . done) ("b") ("c" . error)))))
      (cl-letf (((symbol-function 'claude-code-project-sessions)
                 (lambda (_) sessions)))
        (claude-code-sessions-refresh)
        (claude-code-tests--goto-session "a")
        (forward-char tabulated-list-padding)
        (tabulated-list-sort)
        (let ((ids '()))
          (goto-char (point-min))
          (while (not (eobp))
            (when-let* ((id (tabulated-list-get-id))) (push id ids))
            (forward-line 1))
          (should (equal (nreverse ids) '("b" "a" "c"))))))))

(ert-deftest claude-code-test-view-drops-marks-for-unlisted-sessions ()
  "A mark whose session leaves the listing is dropped, not left dormant."
  (let ((gone '()))
    (cl-letf* ((real (symbol-function 'claude-code-project-sessions))
               ((symbol-function 'claude-code-project-sessions)
                (lambda (&rest args)
                  (seq-remove (lambda (s)
                                (member (claude-code-session-id s) gone))
                              (apply real args)))))
      (claude-code-tests--in-fixture-view '(1002)
        (setq claude-code--collapsed nil)
        (claude-code-sessions-refresh)
        (claude-code--goto-group "dead")
        (forward-line 1)
        (claude-code-sessions-mark)
        (setq gone (copy-sequence claude-code--marks))
        (should gone)
        (claude-code-sessions-refresh)
        (should-not claude-code--marks)
        ;; The session returning does not bring the mark back with it.
        (setq gone '())
        (claude-code-sessions-refresh)
        (should-not claude-code--marks)
        (should-not (claude-code-tests--tagged-ids))))))

(ert-deftest claude-code-test-kill-and-delete-keep-unacted-marks ()
  "Kill and delete drop the marks they consumed, in every view.
An unacted mark survives.  The second view is scoped to another root on
purpose: a worktree session belongs to two roots, so a consumed target must not
stay armed in a view that reaches it under the other one."
  (let* ((acted '())
         (root "/home/test/proj")
         (sibling (generate-new-buffer " *cc-view-sibling*"))
         (record (lambda (s) (push (claude-code-session-id s) acted))))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-kill) record)
                  ((symbol-function 'claude-code-delete) record)
                  ((symbol-function 'yes-or-no-p) (lambda (_) t))
                  ((symbol-function 'claude-code--refresh-views) #'ignore))
          (with-current-buffer sibling
            (claude-code-sessions-mode)
            (setq claude-code--project
                  "/home/test/proj/.claude/worktrees/feat")
            (setq claude-code--marks (list "a" "d")))
          (claude-code-tests--in-view
            (setq-local claude-code--project root)
            (puthash "a" (claude-code-session--create :id "a" :alive-p t)
                     claude-code--session-table)
            (puthash "d" (claude-code-session--create :id "d")
                     claude-code--session-table)
            (setq-local claude-code--marks (list "a" "d"))
            ;; Kill acts on the alive mark only; the dead mark must survive.
            (claude-code-sessions-kill)
            (should (equal acted '("a")))
            (should (equal claude-code--marks '("d")))
            (should (equal (buffer-local-value 'claude-code--marks sibling) '("d")))
            ;; Delete then consumes the remaining dead mark.
            (claude-code-sessions-delete)
            (should (equal acted '("d" "a")))
            (should-not claude-code--marks)
            (should-not (buffer-local-value 'claude-code--marks sibling))))
      (kill-buffer sibling))))

(ert-deftest claude-code-test-batch-delete-survives-a-refusal ()
  "A refused target does not abort the batch, keep its mark, or skip the redraw.
The model re-checks each target by id, so one that came alive since the view was
drawn is refused mid-batch.  The rest are still deleted, only the consumed marks
are dropped, and what was skipped is reported."
  (let ((deleted '()) (refreshed 0) (reported nil))
    (cl-letf (((symbol-function 'claude-code-delete)
               (lambda (s)
                 (let ((id (claude-code-session-id s)))
                   (when (equal id "b") (user-error "Session %s is alive" id))
                   (push id deleted))))
              ((symbol-function 'claude-code--refresh-views)
               (lambda () (cl-incf refreshed)))
              ((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq reported (apply #'format fmt args)))))
      (claude-code-tests--with-fixtures
        (claude-code-tests--in-view
          (setq-local claude-code--project "/r")
          (dolist (id '("a" "b" "c"))
            (puthash id (claude-code-session--create :id id)
                     claude-code--session-table))
          (setq-local claude-code--marks (list "a" "b" "c"))
          (claude-code-sessions-delete)
          ;; The refusal sits between two deletable targets, so an abort would be
          ;; visible as a missing "c".
          (should (equal (reverse deleted) '("a" "c")))
          (should (= refreshed 1))
          ;; Only the refused target stays armed, ready for a retry.
          (should (equal claude-code--marks '("b")))
          (should (string-match-p "Session b is alive" reported)))))))

(ert-deftest claude-code-test-batch-delete-propagates-a-real-fault ()
  "Only a refusal is caught; anything else reaches the debugger.
A failed unlink is a `file-error', not a `user-error', so it is not reported as
though the model had declined -- but the marks and the redraw are still settled
on the way out."
  (let ((deleted '()) (refreshed 0))
    (cl-letf (((symbol-function 'claude-code-delete)
               (lambda (s)
                 (let ((id (claude-code-session-id s)))
                   (when (equal id "b")
                     (signal 'file-error (list "Permission denied")))
                   (push id deleted))))
              ((symbol-function 'claude-code--refresh-views)
               (lambda () (cl-incf refreshed)))
              ((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (claude-code-tests--in-view
        (setq-local claude-code--project "/r")
        (dolist (id '("a" "b" "c"))
          (puthash id (claude-code-session--create :id id)
                   claude-code--session-table))
        (setq-local claude-code--marks (list "a" "b" "c"))
        (should-error (claude-code-sessions-delete) :type 'file-error)
        ;; The batch stops at the fault, but what it did manage is not left
        ;; dangling: "a" is unmarked and every view is redrawn.
        (should (equal deleted '("a")))
        (should (= refreshed 1))
        (should (equal claude-code--marks '("b" "c")))))))

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

(ert-deftest claude-code-test-integration-buffer-kill-unregisters ()
  "A real terminal killed buffer-first reports its instance's exit.
Ghostel runs no `ghostel-exit-functions' for such a terminal, which the unit
tests cannot see: they kill plain buffers with no process behind them."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let ((exits 0))
    (claude-code-tests--with-registered-pty buffer fired
      (add-hook 'ghostel-exit-functions (lambda (&rest _) (cl-incf exits)))
      (unwind-protect
          (progn
            (should (claude-code--session-process buffer))
            (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))
            ;; Wait for an exit-function call that must never arrive.
            (claude-code-tests--await (lambda () (> exits 0)) 3)
            (should (= exits 0))
            (should (zerop (hash-table-count claude-code--managed)))
            (should (= fired 1)))
        (remove-hook 'ghostel-exit-functions
                     (car ghostel-exit-functions))))))

(ert-deftest claude-code-test-integration-exit-kills-the-buffer ()
  "A real process exit kills the instance buffer and retires it, once.
The buffer-local `ghostel-kill-buffer-on-exit' is what guarantees this, so the
user's global preference must not reach it -- a nil there is exactly the case
that would otherwise leave a dead instance registered forever."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (dolist (global '(t nil))
    (let ((ghostel-kill-buffer-on-exit global))
      (claude-code-tests--with-registered-pty buffer fired
        (signal-process (buffer-local-value 'ghostel--pid buffer) 'SIGTERM)
        (should (claude-code-tests--await
                 (lambda () (not (buffer-live-p buffer))) 5))
        (should (zerop (hash-table-count claude-code--managed)))
        ;; Give a second report the chance to arrive that it must not take.
        (claude-code-tests--await (lambda () (> fired 1)) 0.5)
        (should (= fired 1))))))

(ert-deftest claude-code-test-integration-exit-kill-is-never-queried ()
  "The kill that follows a process exit cannot be blocked by a query.
`ghostel-query-before-killing' guards on the process still being live, and by
sentinel time it is not -- so a user who asks to be queried is never asked, and
the instance is still retired."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let ((asked nil)
        (ghostel-query-before-killing t))
    (claude-code-tests--with-registered-pty buffer fired
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (setq asked t) nil))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) nil)))
        (signal-process (buffer-local-value 'ghostel--pid buffer) 'SIGTERM)
        (should (claude-code-tests--await
                 (lambda () (not (buffer-live-p buffer))) 5)))
      (should-not asked)
      (should (zerop (hash-table-count claude-code--managed)))
      (should (= fired 1)))))

(ert-deftest claude-code-test-integration-lifecycle ()
  "Spawn a real named instance, see it register a session, then kill and delete.
The name is given as several words to show that it reaches the CLI whole."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         (name "emacs integration name")
         (after-focus-change-function after-focus-change-function)
         buffer id pid mcp-port)
    (unwind-protect
        (claude-code-tests--with-top-level-env
          (let* ((claude-code-renderer 'inline)
                 (instance (claude-code-spawn
                            root :name name
                            :prompt "Respond with the single word: pong")))
            (setq id (car instance))
            (setq buffer (cdr instance)))
          (should (string-match-p claude-code-tests--uuid-re id))
          ;; Ghostel spawned into the mode it was handed, leaving the title
          ;; tracker the mode installed in place.
          (should (eq (buffer-local-value 'major-mode buffer)
                      'claude-code-instance-mode))
          (should (eq (buffer-local-value 'ghostel-buffer-name-function buffer)
                      #'claude-code--ghostel-buffer-name))
          ;; A binding in the mode's map outlives Ghostel's input-mode
          ;; switches, each of which installs a local map of its own, and
          ;; char mode still outranks it.
          (keymap-set claude-code-instance-mode-map "C-c M-z" #'ignore)
          (unwind-protect
              (with-current-buffer buffer
                (should (eq (key-binding (kbd "C-c M-z")) #'ignore))
                (ghostel-char-mode)
                (should-not (eq (key-binding (kbd "C-c M-z")) #'ignore))
                (ghostel-semi-char-mode)
                (should (eq (key-binding (kbd "C-c M-z")) #'ignore))
                ;; Ghostel's own semi-char bindings are still reachable.
                (should (eq (key-binding (kbd "C-c C-j"))
                            #'ghostel-semi-char-mode)))
            (keymap-unset claude-code-instance-mode-map "C-c M-z" t))
          (setq pid (buffer-local-value 'ghostel--pid buffer))
          (should (claude-code--pid-live-p pid))
          ;; A live status only appears once the child writes its sessions file,
          ;; which only happens for a real (non-nested) session.
          (should (member
                   (claude-code-tests--await
                    (lambda () (let ((s (claude-code-tests--find-session
                                         (claude-code-project-sessions root) id)))
                                 (and s (claude-code-session-status s))))
                    45)
                   '("busy" "idle" "waiting")))
          ;; Ghostel ran the pre-spawn hook: the entry the `inline' renderer
          ;; asks for is in the spawned process's own environment.
          (when-let* ((environ (claude-code-tests--proc-strings pid "environ")))
            (should (member "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1" environ)))
          ;; The name given at spawn is the name the view shows: the CLI records
          ;; it in the transcript this package takes a session's name from.
          (should (claude-code-tests--await
                   (lambda ()
                     (let ((s (claude-code-tests--find-session
                               (claude-code-project-sessions root) id)))
                       (equal (and s (claude-code--session-display-name s))
                              name)))
                   15))
          (let ((s (claude-code-tests--find-session (claude-code-project-sessions root) id)))
            (should (claude-code-session-alive-p s))
            ;; The server dies with the *last* instance, so this has to be it.
            (should (= (hash-table-count claude-code--managed) 1))
            ;; The instance is talking to a live server; killing it is what has
            ;; to take that server down.
            (should claude-code--mcp-server)
            (setq mcp-port (claude-code--mcp-port))
            (should (integerp mcp-port))
            (claude-code-kill s))
          ;; The socket has to be gone, not just the variable holding it:
          ;; clearing the variable alone would hide a listener left running.
          (should-not claude-code--mcp-server)
          (should-not (claude-code-tests--listening-p mcp-port))
          ;; The model reports it dead immediately (it is no longer managed)...
          (let ((s (claude-code-tests--find-session (claude-code-project-sessions root) id)))
            (should (or (null s) (not (claude-code-session-alive-p s)))))
          ;; ...and the OS process must actually terminate (Ghostel tears the
          ;; child down asynchronously, so give its sentinel time to run).
          (should (claude-code-tests--await
                   (lambda () (not (claude-code--pid-live-p pid))) 15))
          ;; The now-dead transcript can be deleted.
          (let ((s (claude-code-tests--find-session (claude-code-project-sessions root) id)))
            (when (and s (claude-code-session-transcript s)
                       (file-exists-p (claude-code-session-transcript s)))
              (claude-code-delete s)
              (should-not (file-exists-p (claude-code-session-transcript s))))))
      ;; Always clean up: kill the buffer, SIGKILL any survivor so an immediate
      ;; batch exit never orphans it, and remove any stray transcript.
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
      (when (and pid (claude-code--pid-live-p pid))
        (ignore-errors (signal-process pid 'SIGKILL)))
      (when id
        (let ((f (expand-file-name (concat id ".jsonl")
                                   (claude-code-tests--project-dir default-directory))))
          (when (file-exists-p f) (delete-file f)))))))

(ert-deftest claude-code-test-integration-long-rename-submits ()
  "A long rename lands even when Claude reads it and its RET in one go.
Stopping the instance across the send stands for a Claude too busy to read
between the two: the read then holds the whole command and its RET, which is
where a typed RET would be taken as a newline.  No model turn is spent."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         (name (concat "emacs integration " (make-string 60 ?x)))
         buffer id pid)
    (unwind-protect
        (claude-code-tests--with-top-level-env
          (let ((instance (claude-code-spawn root)))
            (setq id (car instance))
            (setq buffer (cdr instance))
            (setq pid (buffer-local-value 'ghostel--pid buffer)))
          ;; Ready for input once Claude has turned on bracketed paste.
          (should (claude-code-tests--await
                   (lambda () (and (buffer-live-p buffer)
                                   (with-current-buffer buffer
                                     (ghostel--mode-enabled ghostel--term 2004))))
                   45))
          (let ((s (claude-code-tests--find-session
                    (claude-code-project-sessions root) id)))
            (signal-process pid 'SIGSTOP)
            (unwind-protect (claude-code-rename s name)
              (signal-process pid 'SIGCONT)))
          (should (claude-code-tests--await
                   (lambda ()
                     (let ((s (claude-code-tests--find-session
                               (claude-code-project-sessions root) id)))
                       (equal (and s (claude-code--session-display-name s))
                              name)))
                   15)))
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
      (when (and pid (not (claude-code-tests--await
                           (lambda () (not (claude-code--pid-live-p pid))) 15)))
        (ignore-errors (signal-process pid 'SIGKILL)))
      (when id
        (let* ((dir (claude-code-tests--project-dir default-directory))
               (f (expand-file-name (concat id ".jsonl") dir))
               ;; Where a `/rename' also leaves the name.
               (own (expand-file-name id dir)))
          (when (file-exists-p f) (delete-file f))
          (when (file-directory-p own) (delete-directory own t)))))))

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
            (should (= (process-exit-status proc) 0))
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
    (cl-flet ((clear ()
                (claude-code-send-text (claude-code--instance-session buffer)
                                       "/clear" t)
                (let ((now (claude-code-tests--await
                            (lambda ()
                              (let ((now (plist-get (claude-code--pid-info pid)
                                                    :session)))
                                (and now (not (member now ids)) now)))
                            30)))
                  (should now)
                  (push now ids))))
      (unwind-protect
          (claude-code-tests--with-top-level-env
            (let ((instance (claude-code-spawn root)))
              (push (car instance) ids)
              (setq buffer (cdr instance)))
            (setq pid (claude-code--instance-pid buffer))
            ;; Ready for input once its sessions/ file reads idle.
            (should (claude-code-tests--await
                     (lambda ()
                       (equal (plist-get (claude-code--pid-info pid) :status)
                              "idle"))
                     45))
            (clear)
            ;; Claude writes the transcript shortly after the switch.
            (should (claude-code-tests--await
                     (lambda () (claude-code--transcript-for root (car ids)))
                     15))
            (clear)
            (pcase-let ((`(,current ,left ,launched) ids))
              (let ((running (claude-code--running)))
                (should (eql (gethash current running) pid))
                (should-not (gethash left running))
                (should-not (gethash launched running)))
              (let* ((sessions (claude-code-project-sessions root))
                     (row (claude-code-tests--find-session sessions current))
                     (gone (claude-code-tests--find-session sessions left)))
                (should (eq 'alive (claude-code--session-liveness row)))
                (should (eq (claude-code-session-buffer row) buffer))
                (should (eq 'dead (claude-code--session-liveness gone)))
                (claude-code-delete gone)
                (should-not (file-exists-p
                             (claude-code-session-transcript gone))))))
        (when (buffer-live-p buffer)
          (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
        (when (and pid (claude-code--pid-live-p pid))
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
