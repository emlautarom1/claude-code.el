;;; claude-code-tests.el --- Tests for claude-code -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT suite for claude-code.el.  Run with `make test'.

;;; Code:

(require 'ert)
(require 'seq)
(require 'cl-lib)
(require 'claude-code)

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
  `(let ((claude-code--managed (make-hash-table :test 'equal)))
     ,@body))

(defmacro claude-code-tests--with-managed-buffer (var &rest body)
  "Run BODY with VAR bound to a fresh buffer and an empty managed registry.
The buffer is killed afterwards even when BODY already killed it."
  (declare (indent 1))
  `(claude-code-tests--with-registry
     (let ((,var (generate-new-buffer " *cc-test*")))
       (unwind-protect (progn ,@body)
         (when (buffer-live-p ,var) (kill-buffer ,var))))))

(defmacro claude-code-tests--with-live-pids (pids &rest body)
  "Run BODY with exactly the pids in PIDS reading as live processes.
Pinning the process table keeps a fixture pid that happens to be live on the
host from classifying its session as external.  Every pinned pid parents to 0,
so no pid is its own ancestor and a subtree walk always terminates."
  (declare (indent 1))
  (let ((live (gensym "live")))
    `(let ((,live ,pids))
       (cl-letf (((symbol-function 'list-system-processes) (lambda () ,live))
                 ((symbol-function 'process-attributes)
                  (lambda (p) (and (memql p ,live) '((ppid . 0))))))
         ,@body))))

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

(defmacro claude-code-tests--recording-ghostel (calls &rest body)
  "Run BODY with Ghostel send/paste/key stubbed to push onto CALLS.
Each call pushes (paste STR), (send STR) or (key NAME).  Ghostel's native
module is absent under test, so requiring it is a no-op."
  (declare (indent 1))
  `(claude-code-tests--without-requiring '(ghostel)
     (cl-letf (((symbol-function 'ghostel-paste-string)
                (lambda (s) (push (list 'paste s) ,calls)))
               ((symbol-function 'ghostel-send-string)
                (lambda (s) (push (list 'send s) ,calls)))
               ((symbol-function 'ghostel-send-key)
                (lambda (k &rest _) (push (list 'key k) ,calls))))
       ,@body)))

(defmacro claude-code-tests--recording-launch (execs &rest body)
  "Run BODY with the launch path stubbed, pushing (BUFFER ARGS) onto EXECS.
Neither Ghostel's native module nor the MCP server is wanted under test, so
requiring either is a no-op and the MCP CLI arguments are a fixed stand-in.
Every buffer a launch hosted is killed afterwards, however BODY exits."
  (declare (indent 1))
  `(claude-code-tests--without-requiring '(ghostel claude-code-mcp)
     (cl-letf (((symbol-function 'claude-code--mcp-cli-args)
                (lambda (_id) '("--mcp-config" "{}")))
               ((symbol-function 'ghostel-exec)
                (lambda (buffer _program args) (push (list buffer args) ,execs))))
       (unwind-protect (progn ,@body)
         (dolist (call ,execs)
           (when (buffer-live-p (nth 0 call)) (kill-buffer (nth 0 call))))))))

;;;; Storage adapter

(ert-deftest claude-code-test-encode-cwd ()
  "Encoding replaces slashes and dots with hyphens, losslessly per Claude."
  (should (equal (claude-code--encode-cwd
                  "/home/emlautarom1/Development/Elisp/claude-code.el")
                 "-home-emlautarom1-Development-Elisp-claude-code-el"))
  ;; A leading dot (dotfile dir) yields a doubled hyphen.
  (should (equal (claude-code--encode-cwd "/home/emlautarom1/.dotfiles")
                 "-home-emlautarom1--dotfiles"))
  ;; A trailing slash (as `project-root' returns) must not add a trailing dash.
  (should (equal (claude-code--encode-cwd "/home/x/proj/")
                 "-home-x-proj")))

(ert-deftest claude-code-test-live-status-table ()
  "Every sessions/ file is parsed and keyed by session id."
  (claude-code-tests--with-fixtures
    (let ((table (claude-code--live-status-table)))
      (should (= (hash-table-count table) 4))
      (let ((s1 (gethash "11111111-1111-4111-8111-111111111111" table)))
        (should (equal (plist-get s1 :status) "busy"))
        ;; The parser exposes only :pid, :cwd, :status and :waiting-for.
        (should (null (plist-get s1 :name)))
        (should (= (plist-get s1 :pid) 1001)))
      (let ((s3 (gethash "33333333-3333-4333-8333-333333333333" table)))
        (should (equal (plist-get s3 :status) "waiting"))
        (should (equal (plist-get s3 :waiting-for) "permission prompt")))
      ;; A file without a status field yields nil, not an error.
      (let ((s4 (gethash "44444444-4444-4444-8444-444444444444" table)))
        (should (null (plist-get s4 :status))))
      ;; `claude-code--live-info' is the per-id lookup over the same data:
      ;; a fresh parse without TABLE, the given TABLE as-is (no reparse).
      (let ((id "11111111-1111-4111-8111-111111111111"))
        (should (equal (claude-code--live-info id) (gethash id table)))
        (should (null (claude-code--live-info "no-such-id")))
        (cl-letf (((symbol-function 'claude-code--live-status-table)
                   (lambda () (error "Reparsed"))))
          (should (eq (claude-code--live-info id table)
                      (gethash id table))))))))

(ert-deftest claude-code-test-project-transcripts ()
  "Transcripts of the project and its worktrees are enumerated."
  (claude-code-tests--with-fixtures
    (let* ((ts (claude-code--project-transcripts "/home/test/proj"))
           (by-id (lambda (id)
                    (seq-find (lambda (d) (equal (plist-get d :id) id)) ts))))
      (should (= (length ts) 4))
      (let ((s1 (funcall by-id "11111111-1111-4111-8111-111111111111")))
        ;; With no custom title, the LAST ai-title wins over earlier ones.
        (should (equal (plist-get s1 :title) "Understand the project layout"))
        (should (equal (plist-get s1 :last-prompt) "first prompt"))
        (should (null (plist-get s1 :worktree)))
        ;; Last-active is the newest timestamped (assistant) line, even though an
        ;; untimestamped ai-title line follows it -- not the file mtime.
        (should (time-equal-p (plist-get s1 :last-active)
                              (date-to-time "2026-06-10T13:23:27.697Z"))))
      (let ((s2 (funcall by-id "22222222-2222-4222-8222-222222222222")))
        ;; A custom title supplies the title even with no ai-title line.
        (should (equal (plist-get s2 :title) "My renamed session"))
        (should (equal (plist-get s2 :last-prompt) "another task here")))
      (let ((s3 (funcall by-id "33333333-3333-4333-8333-333333333333")))
        (should (equal (plist-get s3 :worktree) "feat"))
        ;; A user custom title takes precedence over Claude's ai-title.
        (should (equal (plist-get s3 :title) "Renamed worktree")))
      (let ((s5 (funcall by-id "55555555-5555-4555-8555-555555555555")))
        ;; A worktree named "my.feat" leaves only the lossy directory token:
        ;; the dot flattens to a hyphen and is never decoded back.
        (should (equal (plist-get s5 :worktree) "my-feat"))))))

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
    (cl-letf (((symbol-function 'claude-code--live-managed) (lambda (_r) nil)))
      (let ((ss (claude-code-sessions "/home/test/proj")))
        (should (= (length ss) 4))
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
        ;; own worktree, not the parent project.
        (let ((solo (claude-code-tests--find-session
                     ss "55555555-5555-4555-8555-555555555555")))
          (should (equal (claude-code-session-worktree solo) "my-feat")))))))

(ert-deftest claude-code-test-sessions-worktree-before-transcript ()
  "A named spawn labels its worktree before Claude creates the directory.
The registry stands in with the token the name will produce; an auto-named
request carries no name, so it stays blank."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let ((named "66666666-6666-4666-8666-666666666666")
            (auto "77777777-7777-4777-8777-777777777777"))
        (with-current-buffer buf (setq-local ghostel--pid 4242))
        (claude-code--register named buf "/home/test/proj" "my.feat")
        (claude-code--register auto buf "/home/test/proj" t)
        (cl-letf (((symbol-function 'claude-code--live-managed)
                   (lambda (_r) (list (cons named buf) (cons auto buf)))))
          (let ((ss (claude-code-sessions "/home/test/proj")))
            (should (equal (claude-code-session-worktree
                            (claude-code-tests--find-session ss named))
                           "my-feat"))
            (should-not (claude-code-session-worktree
                         (claude-code-tests--find-session ss auto)))))))))

(ert-deftest claude-code-test-sessions-with-alive ()
  "A managed live instance becomes the alive session, without duplication."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let ((id "11111111-1111-4111-8111-111111111111"))
        (with-current-buffer buf (setq-local ghostel--pid 4242))
        (cl-letf (((symbol-function 'claude-code--live-managed)
                   (lambda (_r) (list (cons id buf)))))
          (let* ((ss (claude-code-sessions "/home/test/proj"))
                 (s1 (claude-code-tests--find-session ss id)))
            (should (= (length ss) 4))
            (should (claude-code-session-alive-p s1))
            (should (eq (claude-code-session-buffer s1) buf))
            (should (= (claude-code-session-pid s1) 4242))
            ;; Alive status comes from the live sessions file; the display
            ;; name comes from the transcript title.
            (should (equal (claude-code-session-status s1) "busy"))
            (should (equal (claude-code-session-title s1)
                           "Understand the project layout"))
            (should (equal (claude-code--session-display-name s1)
                           "Understand the project layout"))))))))

(ert-deftest claude-code-test-process-usage ()
  "Usage sums the pcpu/rss of a PID's whole subtree."
  (let ((tree '((100 . ((ppid . 1) (pcpu . 1.0) (rss . 1000)))
                (101 . ((ppid . 100) (pcpu . 2.0) (rss . 2000)))
                (102 . ((ppid . 101) (pcpu . 3.0) (rss . 3000)))
                (200 . ((ppid . 1) (pcpu . 9.0) (rss . 9000))))))
    (cl-letf (((symbol-function 'list-system-processes)
               (lambda () (mapcar #'car tree)))
              ((symbol-function 'process-attributes)
               (lambda (p) (alist-get p tree))))
      (let ((usage (claude-code--process-usage 100)))
        (should (equal (car usage) 6.0))
        (should (= (cdr usage) 6000)))
      ;; A non-integer pid yields nil.
      (should (null (claude-code--process-usage nil)))
      ;; So does a pid the process table does not list: a process that died
      ;; between the snapshot and the sum must not read as an idle one.
      (should (null (claude-code--process-usage 999999))))))

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

(ert-deftest claude-code-test-external-p ()
  "External means: not Emacs-managed, and the sessions/ PID is live."
  (claude-code-tests--with-fixtures
    ;; Session 22222222 has sessions/1002.json (pid 1002).
    (claude-code-tests--with-live-pids '(1002)
      (claude-code-tests--with-registry
        (should (claude-code--external-p "22222222-2222-4222-8222-222222222222"))
        ;; An id with no sessions/ entry is never external.
        (should-not (claude-code--external-p "no-such-id")))
      ;; An Emacs-managed live instance is not external even with a live PID.
      (claude-code-tests--with-managed-buffer buf
        (puthash "22222222-2222-4222-8222-222222222222"
                 (list :buffer buf) claude-code--managed)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          (should-not (claude-code--external-p
                       "22222222-2222-4222-8222-222222222222")))))))

(ert-deftest claude-code-test-external-session ()
  "An unmanaged transcript with a live sessions PID is external, else dead."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      ;; Session 22222222 has sessions/1002.json (pid 1002).  When Emacs does
      ;; not manage it but that pid is live, it is external, not dead.
      (claude-code-tests--with-live-pids '(1002)
        (let ((s (claude-code-tests--find-session
                  (claude-code-sessions "/home/test/proj")
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
                  (claude-code-sessions "/home/test/proj")
                  "22222222-2222-4222-8222-222222222222")))
          (should-not (claude-code-session-external-p s))
          (should (eq 'dead (claude-code--session-liveness s)))
          (should (equal (claude-code--session-display-name s)
                         "My renamed session"))))
      (claude-code-tests--with-live-pids '()
        (let ((s (claude-code-tests--find-session
                  (claude-code-sessions "/home/test/proj")
                  "55555555-5555-4555-8555-555555555555")))
          (should (eq 'dead (claude-code--session-liveness s)))
          (should (equal (claude-code--session-display-name s)
                         "Dotted worktree")))))))

(ert-deftest claude-code-test-session-cwd ()
  "Session cwd prefers the live file, then the registry, else nil."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      ;; The live sessions file wins.  Session 33333333 is a worktree, so its
      ;; live cwd is the worktree directory, not the parent project root.
      (should (equal (claude-code--session-cwd
                      "33333333-3333-4333-8333-333333333333")
                     "/home/test/proj/.claude/worktrees/feat"))
      ;; With no live file, fall back to the registry's launch-time root.
      (puthash "reg-only" (list :origin "/home/x/proj") claude-code--managed)
      (should (equal (claude-code--session-cwd "reg-only") "/home/x/proj"))
      ;; An unknown id yields nil, so `default-directory' is left unchanged.
      (should (null (claude-code--session-cwd "no-such-id"))))))


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
  (should (equal (claude-code--build-args :session-id "ID" :worktree t)
                 '("--session-id" "ID" "-w")))
  (should (equal (claude-code--build-args :session-id "ID" :worktree "feat")
                 '("--session-id" "ID" "-w" "feat")))
  ;; A worktree prompt is kept off `-w' (which takes an optional name) by "--".
  (should (equal (claude-code--build-args :session-id "ID" :worktree t
                                          :prompt "hi")
                 '("--session-id" "ID" "-w" "--" "hi")))
  ;; Empty prompt is dropped (and so is the terminator).
  (should (equal (claude-code--build-args :session-id "ID" :prompt "")
                 '("--session-id" "ID"))))

(ert-deftest claude-code-test-build-args-resume ()
  "Resume returns only \"-r ID\" and ignores new-session arguments."
  (should (equal (claude-code--build-args :resume "ID") '("-r" "ID")))
  (should (equal (claude-code--build-args :resume "ID" :prompt "x" :model "opus")
                 '("-r" "ID")))
  (should (equal (claude-code--build-args :resume "ID" :session-id "ID")
                 '("-r" "ID"))))

(ert-deftest claude-code-test-build-args-mcp ()
  "MCP args append verbatim; a nil `:mcp-args' leaves the base list unchanged."
  ;; A nil `:mcp-args' adds nothing to either branch.
  (should (equal (claude-code--build-args :session-id "ID" :mcp-args nil)
                 '("--session-id" "ID")))
  (should (equal (claude-code--build-args :resume "ID" :mcp-args nil)
                 '("-r" "ID")))
  ;; Non-nil MCP args sit with the options, before the "--" terminator and the
  ;; prompt, so the variadic MCP flags cannot swallow the positional prompt.
  (should (equal (claude-code--build-args
                  :session-id "ID" :prompt "hi"
                  :mcp-args '("--mcp-config" "{}" "--allowedTools" "x"))
                 '("--session-id" "ID"
                   "--mcp-config" "{}" "--allowedTools" "x" "--" "hi")))
  ;; ...and to the resume list too.
  (should (equal (claude-code--build-args
                  :resume "ID" :mcp-args '("--mcp-config" "{}"))
                 '("-r" "ID" "--mcp-config" "{}"))))

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

(ert-deftest claude-code-test-install-buffer-name-tracking ()
  "Instrumenting a buffer makes Ghostel name it via the Claude title tracker."
  (with-temp-buffer
    (claude-code--install-buffer-name-tracking (current-buffer))
    (should (local-variable-p 'ghostel-buffer-name-function))
    (should (eq ghostel-buffer-name-function
                #'claude-code--ghostel-buffer-name))))

(ert-deftest claude-code-test-on-exit-unregisters ()
  "Process exit removes the instance's registry entry."
  (claude-code-tests--with-managed-buffer buf
    (puthash "id-1" (list :buffer buf :origin "/r") claude-code--managed)
    (claude-code--on-exit buf "finished\n")
    (should (zerop (hash-table-count claude-code--managed)))))

(ert-deftest claude-code-test-on-exit-runs-last-instance-hook-on-transition ()
  "The hook fires exactly when a managed exit empties the registry.
Unmanaged terminal exits never fire it — not even while the registry is
empty, the steady state once every instance has exited."
  (claude-code-tests--with-managed-buffer buf
    (claude-code-tests--with-managed-buffer stranger
      (let* ((fired 0)
             (claude-code-last-instance-exit-hook
              (list (lambda () (cl-incf fired)))))
        ;; Empty registry: an unmanaged exit must not fire the hook.
        (claude-code--on-exit stranger "finished\n")
        (should (= fired 0))
        ;; Non-empty registry, unmanaged exit: still nothing.
        (puthash "id-1" (list :buffer buf :origin "/r") claude-code--managed)
        (claude-code--on-exit stranger "finished\n")
        (should (= fired 0))
        ;; The managed exit that empties the registry fires it once.
        (claude-code--on-exit buf "finished\n")
        (should (= fired 1))
        ;; A repeat exit event for the same buffer does not fire it again.
        (claude-code--on-exit buf "finished\n")
        (should (= fired 1))))))

(ert-deftest claude-code-test-launch-shared-by-spawn-and-resume ()
  "Spawn and resume host their instance through one launch path.
Both reach `ghostel-exec' with the MCP arguments threaded in, register the
instance, and install title tracking; only the CLI argument list differs."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-registry
      (let ((execs '())
            (buffers '()))
        (claude-code-tests--recording-launch execs
          (push (claude-code-spawn "/r" :worktree "feat" :model "opus") buffers)
          (push (claude-code-resume "/r" "given-id") buffers)
          (let* ((calls (reverse execs))
                 (spawn-args (nth 1 (nth 0 calls)))
                 (resume-args (nth 1 (nth 1 calls)))
                 (spawned-id (nth 1 spawn-args)))
            (should (= (length calls) 2))
            ;; Resume ignores new-session options; spawn keeps them behind the
            ;; generated session id.
            (should (equal resume-args '("-r" "given-id" "--mcp-config" "{}")))
            (should (equal (nth 0 spawn-args) "--session-id"))
            (should (string-match-p claude-code-tests--uuid-re spawned-id))
            (should (equal (nthcdr 2 spawn-args)
                           '("-w" "feat" "--model" "opus"
                             "--mcp-config" "{}")))
            ;; Both registered; only spawn recorded a worktree.
            (should (= (hash-table-count claude-code--managed) 2))
            (should (null (plist-get (gethash "given-id" claude-code--managed)
                                     :worktree)))
            (should (equal (plist-get (gethash spawned-id claude-code--managed)
                                      :worktree)
                           "feat"))
            ;; Title tracking survives on both buffers.
            (dolist (buffer buffers)
              (should (eq (buffer-local-value 'ghostel-buffer-name-function
                                              buffer)
                          #'claude-code--ghostel-buffer-name)))))))))

(ert-deftest claude-code-test-resume-focuses-existing ()
  "Resuming an already-managed live session focuses it and spawns nothing."
  (claude-code-tests--with-managed-buffer buf
    (let ((focused nil) (spawned nil))
      (puthash "id-x" (list :buffer buf :origin "/r") claude-code--managed)
      (cl-letf (((symbol-function 'claude-code--session-process)
                 (lambda (b) (and (eq b buf) 'proc)))
                ((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (setq focused b)))
                ((symbol-function 'ghostel-exec)
                 (lambda (&rest _) (setq spawned t))))
        (should (eq (claude-code-resume "/r" "id-x") buf))
        (should (eq focused buf))
        (should-not spawned)
        ;; No second registry entry was created for the same id.
        (should (= (hash-table-count claude-code--managed) 1))))))

(ert-deftest claude-code-test-resume-refuses-external ()
  "Resuming a session a `claude' outside Emacs is running is refused.
The guard is in the model, not in the view, so a headless caller cannot attach
a second process to a session another one is already driving.  Fixture session
22222222 has sessions/1002.json, so pinning pid 1002 live makes it external."
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

(ert-deftest claude-code-test-kill ()
  "Killing an alive session drops its registry entry and buffer."
  (claude-code-tests--with-managed-buffer buf
    (puthash "id-k" (list :buffer buf :origin "/r") claude-code--managed)
    (claude-code-kill (claude-code-session--create
                       :id "id-k" :alive-p t :buffer buf))
    (should-not (gethash "id-k" claude-code--managed))
    (should-not (buffer-live-p buf))
    ;; A dead session cannot be killed.
    (should-error (claude-code-kill
                   (claude-code-session--create :id "d" :alive-p nil))
                  :type 'user-error)))

(ert-deftest claude-code-test-rename ()
  "Rename sends exactly the /rename slash command, then submits."
  (claude-code-tests--with-managed-buffer buf
    (let ((calls '()))
      (claude-code-tests--recording-ghostel calls
        (claude-code-rename
         (claude-code-session--create :id "s" :alive-p t :buffer buf)
         "My Name"))
      (should (equal (reverse calls)
                     '((send "/rename My Name") (key "return"))))
      ;; Renaming a dead session is refused.
      (should-error (claude-code-rename
                     (claude-code-session--create :id "d" :alive-p nil) "x")
                    :type 'user-error))))

(ert-deftest claude-code-test-send-text ()
  "Newlines paste as one message; single lines type; RET only when submitting."
  (claude-code-tests--with-managed-buffer buf
    (let ((calls '())
          (s (claude-code-session--create :id "s" :alive-p t :buffer buf)))
      (claude-code-tests--recording-ghostel calls
        ;; Single line, no submit: typed, no RET.
        (setq calls nil)
        (claude-code-send-text s "hello")
        (should (equal (reverse calls) '((send "hello"))))
        ;; Single line, submit: typed then RET.
        (setq calls nil)
        (claude-code-send-text s "hi" t)
        (should (equal (reverse calls) '((send "hi") (key "return"))))
        ;; Multi-line: bracketed paste, then RET only for the submit.
        (setq calls nil)
        (claude-code-send-text s "a\nb" t)
        (should (equal (reverse calls) '((paste "a\nb") (key "return"))))))))

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
        (progn
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
                        :type 'user-error))
      (when (file-exists-p file) (delete-file file)))))

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
      (should (equal (aref v 6) "Worker task")))))

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
An external session is neither a killable nor a deletable target, so batch
delete cannot pick one up and abort partway through `claude-code-delete'."
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
  "RET focuses alive rows, resumes via the model otherwise, prompting on dead.
An external row reaches `claude-code-resume' without a prompt, so the model's
guard is the only refusal (`claude-code-test-resume-refuses-external')."
  (let ((claude-code--project "/r")
        (alive (claude-code-session--create :id "a" :alive-p t))
        (external (claude-code-session--create :id "e" :external-p t))
        (dead (claude-code-session--create :id "d"))
        (at-point nil) (answer nil) (calls '()))
    (cl-letf (((symbol-function 'claude-code--session-at-point)
               (lambda () at-point))
              ((symbol-function 'claude-code-focus)
               (lambda (s) (push (list 'focus (claude-code-session-id s)) calls)))
              ((symbol-function 'claude-code-resume)
               (lambda (root id) (push (list 'resume root id) calls)))
              ((symbol-function 'claude-code-sessions-refresh)
               (lambda () (push '(refresh) calls)))
              ((symbol-function 'claude-code-sessions-toggle-group)
               (lambda () (push '(toggle) calls)))
              ((symbol-function 'y-or-n-p)
               (lambda (_) (push '(ask) calls) answer)))
      ;; A group header (no session at point) toggles.
      (claude-code-sessions-visit)
      (should (equal calls '((toggle))))
      ;; An alive row focuses, without a prompt.
      (setq at-point alive calls nil)
      (claude-code-sessions-visit)
      (should (equal calls '((focus "a"))))
      ;; An external row goes to the model unprompted.
      (setq at-point external calls nil)
      (claude-code-sessions-visit)
      (should (equal (reverse calls) '((resume "/r" "e") (refresh))))
      ;; A dead row asks first: yes resumes and refreshes...
      (setq at-point dead calls nil answer t)
      (claude-code-sessions-visit)
      (should (equal (reverse calls) '((ask) (resume "/r" "d") (refresh))))
      ;; ...no stops at the prompt.
      (setq calls nil answer nil)
      (claude-code-sessions-visit)
      (should (equal calls '((ask)))))))

(ert-deftest claude-code-test-view-renders-and-collapses ()
  "The view prints group headers, folds Dead by default, and toggles rows."
  (claude-code-tests--with-fixtures
    (let ((claude-code-refresh-interval nil)
          (buf (get-buffer-create " *cc-view-test*")))
      (unwind-protect
          (with-current-buffer buf
            (cl-letf (((symbol-function 'claude-code--live-managed)
                       (lambda (_r) nil)))
              (claude-code-tests--with-live-pids '()
                (claude-code-sessions-mode)
                (setq claude-code--project "/home/test/proj")
                (claude-code-sessions-refresh)
                ;; The Dead group starts folded: its header shows but no rows do.
                (should (member "dead" claude-code--collapsed))
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "Dead (4)" text))
                  (should-not (string-match-p "11111111" text)))
                ;; Expanding it reveals every dead row.
                (setq claude-code--collapsed (delete "dead" claude-code--collapsed))
                (claude-code-sessions-refresh)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "Dead (4)" text))
                  (should (string-match-p "11111111" text))
                  ;; The worktree session is listed under the parent project.
                  (should (string-match-p "feat" text)))
                ;; Folding it again hides the rows.
                (push "dead" claude-code--collapsed)
                (claude-code-sessions-refresh)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "Dead (4)" text))
                  (should-not (string-match-p "11111111" text))))))
        (kill-buffer buf)))))

(ert-deftest claude-code-test-view-pins-default-directory ()
  "Opening the view pins `default-directory' to the project root, and it sticks."
  (claude-code-tests--with-fixtures
    (let ((claude-code-refresh-interval nil)
          (root "/home/test/proj")
          (buf nil))
      (unwind-protect
          (cl-letf (((symbol-function 'project-current) (lambda (&optional _ _dir) 'proj))
                    ((symbol-function 'project-root) (lambda (_p) root))
                    ((symbol-function 'pop-to-buffer) (lambda (b &rest _) (setq buf b))))
            ;; `claude' runs a real refresh over the fixtures; the pin must
            ;; outlive it, so the refresh is deliberately not stubbed out.
            (claude-code)
            (with-current-buffer buf
              (should (derived-mode-p 'claude-code-sessions-mode))
              (should (equal claude-code--project (claude-code--normalize-root root)))
              (should (equal default-directory
                             (file-name-as-directory
                              (claude-code--normalize-root root))))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

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

(defun claude-code-tests--managed-id (buffer)
  "Return the id of the managed instance hosted in BUFFER, or nil for none."
  (cl-loop for id being the hash-keys of claude-code--managed
           using (hash-values plist)
           when (eq (plist-get plist :buffer) buffer) return id))

(defun claude-code-tests--await (pred timeout)
  "Pump events until PRED is non-nil or TIMEOUT seconds elapse; return PRED."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.2)
      (sleep-for 0.1))
    (funcall pred)))

(defun claude-code-tests--project-dir (cwd)
  "Return the transcript directory under `claude-code-config-dir' for CWD."
  (expand-file-name (claude-code--encode-cwd cwd) (claude-code--projects-dir)))

(ert-deftest claude-code-test-integration-lifecycle ()
  "Spawn a real instance, see it register a session, then kill and delete it."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         buffer id pid)
    (unwind-protect
        (claude-code-tests--with-top-level-env
          (setq buffer (claude-code-spawn
                        root :prompt "Respond with the single word: pong"))
          (setq id (claude-code-tests--managed-id buffer))
          (should id)
          ;; The title tracker survives `ghostel-exec's `ghostel-mode' switch.
          (should (eq (buffer-local-value 'ghostel-buffer-name-function buffer)
                      #'claude-code--ghostel-buffer-name))
          (setq pid (buffer-local-value 'ghostel--pid buffer))
          (should (claude-code--pid-live-p pid))
          ;; A live status only appears once the child writes its sessions file,
          ;; which only happens for a real (non-nested) session.
          (should (member
                   (claude-code-tests--await
                    (lambda () (let ((s (claude-code-tests--find-session
                                         (claude-code-sessions root) id)))
                                 (and s (claude-code-session-status s))))
                    45)
                   '("busy" "idle" "waiting")))
          (let ((s (claude-code-tests--find-session (claude-code-sessions root) id)))
            (should (claude-code-session-alive-p s))
            (claude-code-kill s))
          ;; The model reports it dead immediately (it is no longer managed)...
          (let ((s (claude-code-tests--find-session (claude-code-sessions root) id)))
            (should (or (null s) (not (claude-code-session-alive-p s)))))
          ;; ...and the OS process must actually terminate (Ghostel tears the
          ;; child down asynchronously, so give its sentinel time to run).
          (should (claude-code-tests--await
                   (lambda () (not (claude-code--pid-live-p pid))) 15))
          ;; The now-dead transcript can be deleted.
          (let ((s (claude-code-tests--find-session (claude-code-sessions root) id)))
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

(provide 'claude-code-tests)
;;; claude-code-tests.el ends here
