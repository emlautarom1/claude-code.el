;;; claude-code-tests.el --- Tests for claude-code -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT suite for claude-code.el.  Run with `make test'.

;;; Code:

(require 'ert)
(require 'seq)
(require 'cl-lib)
(require 'claude-code)

;; Declared so a `let' on it binds dynamically in tests that run without
;; Ghostel loaded.
(defvar ghostel-kill-buffer-on-exit)

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

(ert-deftest claude-code-test-worktree-dir-belongs-to-two-roots ()
  "A worktree's transcript directory is listed by the worktree root too.
Encoding the worktree path yields exactly the parent's encoded directory plus
the worktree prefix, so one directory is the parent project's worktree
directory and the worktree project's own.  Both roots therefore list the same
transcript, and from the worktree root it carries no worktree token: there it
is the main tree."
  (should (equal (claude-code--encode-cwd
                  "/home/test/proj/.claude/worktrees/feat")
                 (concat (claude-code--encode-cwd "/home/test/proj")
                         "--claude-worktrees-feat")))
  (claude-code-tests--with-fixtures
    (let ((ts (claude-code--project-transcripts
               "/home/test/proj/.claude/worktrees/feat")))
      (should (= (length ts) 1))
      (should (equal (plist-get (car ts) :id)
                     "33333333-3333-4333-8333-333333333333"))
      (should (null (plist-get (car ts) :worktree))))))

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

(ert-deftest claude-code-test-transcript-fields-custom-title-wins ()
  "A `custom-title' outranks an `ai-title', whichever came last."
  (claude-code-tests--with-transcript file
      '("{\"type\":\"custom-title\",\"customTitle\":\"renamed\"}"
        "{\"type\":\"ai-title\",\"aiTitle\":\"generated\"}")
      1800000000
    (should (equal (plist-get (claude-code--transcript-fields file) :title)
                   "renamed"))))

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
          (let ((ss (claude-code-project-sessions "/home/test/proj")))
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
        (claude-code--register id buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          (let* ((ss (claude-code-project-sessions "/home/test/proj"))
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
        (claude-code-tests--with-managed-buffer buf
          (claude-code-tests--with-live-pids '()
            (with-current-buffer buf (setq-local ghostel--pid 4242))
            (claude-code--register id buf (car case) nil)
            (cl-letf (((symbol-function 'claude-code--session-process)
                       (lambda (b) (eq b buf))))
              (let ((s (claude-code-tests--find-session
                        (claude-code-project-sessions (cdr case)) id)))
                (should (claude-code-session-alive-p s))
                (should (eq 'alive (claude-code--session-liveness s)))
                (should (eq (claude-code-session-buffer s) buf))
                (should (= (claude-code-session-pid s) 4242))
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
  "Resume returns only \"--resume=ID\" and ignores new-session arguments."
  (should (equal (claude-code--build-args :resume "ID") '("--resume=ID")))
  (should (equal (claude-code--build-args :resume "ID" :prompt "x" :model "opus"
                                          :effort "high" :name "review")
                 '("--resume=ID")))
  (should (equal (claude-code--build-args :resume "ID" :session-id "ID")
                 '("--resume=ID"))))

(ert-deftest claude-code-test-build-args-mcp ()
  "MCP args append verbatim; a nil `:mcp-args' leaves the base list unchanged."
  ;; A nil `:mcp-args' adds nothing to either branch.
  (should (equal (claude-code--build-args :session-id "ID" :mcp-args nil)
                 '("--session-id" "ID")))
  (should (equal (claude-code--build-args :resume "ID" :mcp-args nil)
                 '("--resume=ID")))
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
                 '("--resume=ID" "--mcp-config" "{}"))))

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
        (puthash "id-1" (list :buffer buf :origin "/r") claude-code--managed)
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

(ert-deftest claude-code-test-launch-shared-by-spawn-and-resume ()
  "Spawn and resume host their instance through one launch path.
Both reach `ghostel-exec' with the MCP arguments threaded in, register the
instance, and install title tracking; only the CLI argument list differs."
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
                           '("--resume=given-id" "--mcp-config" "{}")))
            (should (equal (nth 0 spawn-args) "--session-id"))
            (should (string-match-p claude-code-tests--uuid-re spawned-id))
            ;; Spawn hands back that id with the buffer hosting it.
            (should (equal (car spawned) spawned-id))
            (should (eq (cdr spawned) (nth 0 (nth 0 calls))))
            (should (equal (nthcdr 2 spawn-args)
                           '("--worktree=feat" "--model" "opus"
                             "--mcp-config" "{}")))
            ;; Both registered; only spawn recorded a worktree.
            (should (= (hash-table-count claude-code--managed) 2))
            (should (null (plist-get (gethash "given-id" claude-code--managed)
                                     :worktree)))
            (should (equal (plist-get (gethash spawned-id claude-code--managed)
                                      :worktree)
                           "feat"))
            ;; Title tracking survives on both buffers, and each one announces
            ;; the instance it hosts rather than its sibling.
            (should (= (length buffers) 2))
            (let ((routed '()))
              (cl-letf (((symbol-function 'claude-code--notify)
                         (lambda (id _body) (push id routed))))
                (dolist (id (list "given-id" spawned-id))
                  (let ((buffer (plist-get (gethash id claude-code--managed)
                                           :buffer)))
                    (should (memq buffer buffers))
                    (should (eq (buffer-local-value 'ghostel-buffer-name-function
                                                    buffer)
                                #'claude-code--ghostel-buffer-name))
                    (funcall (buffer-local-value 'ghostel-notification-function
                                                 buffer)
                             "Claude Code" "Claude is waiting for your input"))))
              (should (equal (nreverse routed)
                             (list "given-id" spawned-id))))))))))

(ert-deftest claude-code-test-resume-returns-existing ()
  "Resuming an already-managed live session returns it and spawns nothing."
  (claude-code-tests--with-managed-buffer buf
    (let ((spawned nil))
      (puthash "id-x" (list :buffer buf :origin "/r") claude-code--managed)
      (cl-letf (((symbol-function 'claude-code--session-process)
                 (lambda (b) (and (eq b buf) 'proc)))
                ((symbol-function 'ghostel-exec)
                 (lambda (&rest _) (setq spawned t))))
        (should (eq (claude-code-resume "/r" "id-x") buf))
        (should-not spawned)
        ;; No second registry entry was created for the same id.
        (should (= (hash-table-count claude-code--managed) 1))))))

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
      (should-not (gethash "id-k" claude-code--managed))
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
              (should (eq (plist-get (gethash "id-r" claude-code--managed) :buffer)
                          new))
              (should (buffer-live-p new))))
        (dolist (buffer (list old new))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

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
  "An instance's buffer routes its terminal notifications to its own session.
The handler is buffer-local, so terminals this package does not manage keep
the user's global handler, and it carries the instance id rather than reading
it back from whatever buffer happens to be current."
  (claude-code-tests--with-managed-buffer buf
    (let ((seen '()))
      (claude-code--install-notifications "id-1" buf)
      (should (local-variable-p 'ghostel-notification-function buf))
      (cl-letf (((symbol-function 'claude-code--notify)
                 (lambda (id body) (push (list id body) seen))))
        ;; Claude's title is a constant banner; only the body carries meaning.
        (funcall (buffer-local-value 'ghostel-notification-function buf)
                 "Claude Code" "Claude is waiting for your input"))
      (should (equal seen '(("id-1" "Claude is waiting for your input")))))))

(ert-deftest claude-code-test-focused-p ()
  "Focus is decided over every frame, not just the selected one.
`frame-focus-state' answers for one frame and more than one can report focus,
so a raise landing on a frame other than the selected one still counts.  An
`unknown' answer is not focus."
  (let ((states '((f1 . nil) (f2 . nil))))
    (cl-letf (((symbol-function 'frame-list) (lambda () '(f1 f2)))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional frame) (alist-get frame states))))
      (should-not (claude-code--focused-p))
      ;; Focus on the frame that is not first in the list still counts.
      (setf (alist-get 'f2 states) t)
      (should (claude-code--focused-p))
      ;; A platform that cannot tell is not a raise.
      (setf (alist-get 'f2 states) 'unknown)
      (should-not (claude-code--focused-p)))))

(ert-deftest claude-code-test-attended-p ()
  "A buffer is attended when any focused frame has it selected.
Every window showing it is considered: one displayed in a side window as well
as in a focused frame's selected window is being watched, and looking only at
the window that happens to come first would miss that."
  (claude-code-tests--with-managed-buffer buf
    (let ((windows '(side main))
          (frames '((side . f1) (main . f2)))
          (selected '((f1 . other) (f2 . main)))
          (states '((f1 . t) (f2 . t))))
      (cl-letf (((symbol-function 'get-buffer-window-list)
                 (lambda (&rest _) windows))
                ((symbol-function 'window-frame)
                 (lambda (window) (alist-get window frames)))
                ((symbol-function 'frame-selected-window)
                 (lambda (frame) (alist-get frame selected)))
                ((symbol-function 'frame-focus-state)
                 (lambda (&optional frame) (alist-get frame states))))
        ;; Selected on f2, which has focus, even though f1 lists it first.
        (should (claude-code--attended-p buf))
        ;; Same windows, but the frame holding it selected lost focus.
        (setf (alist-get 'f2 states) nil)
        (should-not (claude-code--attended-p buf))
        ;; Focused again, but no longer that frame's selected window.
        (setf (alist-get 'f2 states) t)
        (setf (alist-get 'f2 selected) 'other)
        (should-not (claude-code--attended-p buf))
        ;; Displayed in no window at all.
        (setq windows '())
        (should-not (claude-code--attended-p buf))))))

(ert-deftest claude-code-test-notify-hands-over-a-session ()
  "A notification reaches the handler as the session it came from, plus the body.
The session is built when the notification fires, so it carries the name and
status the instance has now rather than a cached one."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let* ((id "11111111-1111-4111-8111-111111111111")
             (seen '())
             (claude-code-notify-function
              (lambda (session body) (push (cons session body) seen))))
        (with-current-buffer buf (setq-local ghostel--pid 4242))
        (claude-code--register id buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf)))
                  ((symbol-function 'claude-code--attended-p) #'ignore))
          (claude-code--notify id "Claude is waiting for your input"))
        (should (= (length seen) 1))
        (pcase-let ((`(,session . ,body) (car seen)))
          (should (equal body "Claude is waiting for your input"))
          (should (equal (claude-code-session-id session) id))
          (should (eq (claude-code-session-buffer session) buf))
          (should (claude-code-session-alive-p session))
          (should (equal (claude-code-session-status session) "busy"))
          (should (equal (claude-code--session-display-name session)
                         "Understand the project layout")))))))

(ert-deftest claude-code-test-notify-stays-quiet ()
  "Nothing is announced with notifications off, off-registry, or on screen."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let* ((id "11111111-1111-4111-8111-111111111111")
             (announced 0)
             (claude-code-notify-function (lambda (&rest _) (cl-incf announced))))
        (with-current-buffer buf (setq-local ghostel--pid 4242))
        (claude-code--register id buf "/home/test/proj" nil)
        (cl-letf (((symbol-function 'claude-code--session-process)
                   (lambda (b) (eq b buf))))
          ;; The user is looking at the instance already.
          (cl-letf (((symbol-function 'claude-code--attended-p)
                     (lambda (_buffer) t)))
            (claude-code--notify id "Claude is waiting for your input"))
          (should (= announced 0))
          (cl-letf (((symbol-function 'claude-code--attended-p) #'ignore))
            ;; An id that has left the registry, e.g. the instance just exited.
            (claude-code--notify "gone" "Claude is waiting for your input")
            (should (= announced 0))
            ;; Notifications turned off entirely.
            (let ((claude-code-notify-function nil))
              (claude-code--notify id "Claude is waiting for your input"))
            (should (= announced 0))
            ;; The same call announces once every guard is out of the way.
            (claude-code--notify id "Claude is waiting for your input")
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
                 (lambda (b &rest _) (push b shown)))
                ((symbol-function 'claude-code--managed-buffer)
                 (lambda (_id) buf)))
        (claude-code-tests--following raised log
          (claude-code--notify-follow "id-1")
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

(ert-deftest claude-code-test-notify-does-not-claim-the-selected-window ()
  "A notification jump displays with `pop-to-buffer', not `claude-code--show'.
Every other notify test stubs `pop-to-buffer' -- which `claude-code--show' calls
-- so none of them would notice this opt-out being dropped."
  (claude-code-tests--with-managed-buffer buf
    (let ((calls '())
          (log '()))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (b &rest _) (push (list 'pop b) calls)))
                ((symbol-function 'claude-code--show)
                 (lambda (b &rest _) (push (list 'show b) calls)))
                ((symbol-function 'claude-code--managed-buffer)
                 (lambda (_id) buf)))
        (claude-code-tests--capturing-timers log
          (claude-code--notify-show "id-1")
          (funcall (claude-code-tests--thunk-at log 0))))
      (should (equal calls (list (list 'pop buf)))))))

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
                 (lambda (b &rest _) (push b shown)))
                ((symbol-function 'claude-code--managed-buffer)
                 (lambda (_id) buf)))
        (claude-code-tests--following raised log
          (claude-code--notify-follow "id-1")
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

(ert-deftest claude-code-test-notify-follow-resolves-the-instance-on-arrival ()
  "The jump target is resolved when the click lands, not when it was posted.
A session killed and resumed between the two is hosted in a new buffer, and
that is the one to open; one that left the registry opens nothing."
  (claude-code-tests--with-managed-buffer old
    (claude-code-tests--with-managed-buffer new
      (let ((shown '())
            (log '())
            (hosted old)
            (raised nil))
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (b &rest _) (push b shown)))
                  ((symbol-function 'claude-code--managed-buffer)
                   (lambda (_id) hosted)))
          (claude-code-tests--following raised log
            (claude-code--notify-follow "id-1")
            (setq raised t)
            (funcall after-focus-change-function)
            ;; Killed and resumed between the raise and the display: resolving
            ;; any earlier than the display would open the stale buffer.
            (setq hosted new)
            (funcall (claude-code-tests--thunk-at log 0))
            (should (equal shown (list new)))
            (should-not (memq old shown))
            ;; The activation window expires, freeing the claim for a new click.
            (funcall (claude-code-tests--thunk-at
                      log claude-code--notify-activation-window))
            ;; Gone from the registry by the time the click lands.
            (setq hosted nil log '() raised nil)
            (claude-code--notify-follow "id-1")
            (setq raised t)
            (funcall after-focus-change-function)
            (funcall (claude-code-tests--thunk-at log 0))
            (should (equal shown (list new)))))))))

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
                   (lambda (b &rest _) (push b shown)))
                  ((symbol-function 'claude-code--managed-buffer)
                   (lambda (id) (if (equal id "clicked") clicked swept))))
          (claude-code-tests--following raised log
            (claude-code--notify-follow "clicked")
            (let ((claim (claude-code-tests--timer-at
                          log claude-code--notify-activation-window)))
              ;; The rest of the group, closed a millisecond behind the click.
              (claude-code--notify-follow "swept-1")
              (claude-code--notify-follow "swept-2")
              ;; The claim stands: nothing rearmed, nothing cancelled.
              (should (eq claim (claude-code-tests--timer-at
                                 log claude-code--notify-activation-window)))
              (should (null (claude-code-tests--cancelled log)))
              (setq raised t)
              (funcall after-focus-change-function)
              ;; A close trailing the raise is still inside the window, and
              ;; Emacs is focused by now -- the branch that displays at once.
              (claude-code--notify-follow "swept-3")
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
                 (lambda (b &rest _) (push b shown)))
                ((symbol-function 'claude-code--managed-buffer)
                 (lambda (_id) buf)))
        (claude-code-tests--following t log
          (claude-code--notify-follow "id-1")
          ;; No watcher to install: the focus hook is left alone.
          (should (eq after-focus-change-function #'ignore))
          (funcall (claude-code-tests--thunk-at log 0))
          (should (equal shown (list buf)))
          (setq log (seq-remove (lambda (e) (equal (nth 1 e) 0)) log))
          (claude-code--notify-follow "id-2")
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
The follow is handed the session id, so it resolves the instance itself."
  (let ((posts '())
        (followed '())
        (session (claude-code-session--create :id "id-1" :title "T")))
    (cl-letf (((symbol-function 'claude-code--notify-follow)
               (lambda (id) (push id followed))))
      (claude-code-tests--recording-notify posts
        (claude-code-notify-desktop session "body")
        (let ((on-close (plist-get (car posts) :on-close)))
          (funcall on-close 1 'expired)
          (should (null followed))
          (funcall on-close 1 'dismissed)
          (should (equal followed '("id-1"))))))))

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
  "RET displays alive rows through `claude-code--show', resuming otherwise.
A dead row prompts first; an external row reaches `claude-code-resume'
without a prompt, so the model's guard is the only refusal
\(`claude-code-test-resume-refuses-external')."
  (let ((alive (claude-code-session--create :id "a" :alive-p t))
        (external (claude-code-session--create :id "e" :external-p t))
        (dead (claude-code-session--create :id "d"))
        (at-point nil) (answer nil) (calls '()))
    (cl-letf (((symbol-function 'claude-code--session-at-point)
               (lambda () at-point))
              ((symbol-function 'claude-code--buffer)
               (lambda (_s) 'terminal))
              ((symbol-function 'claude-code-resume)
               (lambda (root id) (push (list 'resume root id) calls) 'terminal))
              ((symbol-function 'claude-code--show)
               (lambda (b &rest _) (push (list 'show b) calls)))
              ((symbol-function 'claude-code--refresh-views)
               (lambda () (push '(refresh) calls)))
              ((symbol-function 'claude-code-sessions-toggle-group)
               (lambda () (push '(toggle) calls)))
              ((symbol-function 'y-or-n-p)
               (lambda (_) (push '(ask) calls) answer)))
      (claude-code-tests--in-view
        (setq-local claude-code--project "/r")
        ;; A group header (no session at point) toggles.
        (claude-code-sessions-visit)
        (should (equal calls '((toggle))))
        ;; An alive row is displayed without a prompt.
        (setq at-point alive calls nil)
        (claude-code-sessions-visit)
        (should (equal calls '((show terminal))))
        ;; An external row goes to the model unprompted, and the returned
        ;; buffer is displayed after the redraw.
        (setq at-point external calls nil)
        (claude-code-sessions-visit)
        (should (equal (reverse calls)
                       '((resume "/r" "e") (refresh) (show terminal))))
        ;; A dead row asks first: yes resumes, refreshes and displays...
        (setq at-point dead calls nil answer t)
        (claude-code-sessions-visit)
        (should (equal (reverse calls)
                       '((ask) (resume "/r" "d") (refresh) (show terminal))))
        ;; ...no stops at the prompt.
        (setq calls nil answer nil)
        (claude-code-sessions-visit)
        (should (equal calls '((ask))))))))

(ert-deftest claude-code-test-sessions-visit-other-window ()
  "`o' shows the row's buffer in another window; a header line is refused.
The liveness dispatch is shared with RET
\(`claude-code-test-sessions-visit-dispatch')."
  (let ((alive (claude-code-session--create :id "a" :alive-p t))
        (at-point nil) (shown nil))
    (cl-letf (((symbol-function 'claude-code--session-at-point)
               (lambda () at-point))
              ((symbol-function 'claude-code--buffer)
               (lambda (_s) 'terminal))
              ((symbol-function 'switch-to-buffer-other-window)
               (lambda (b) (setq shown b))))
      (claude-code-tests--in-view
        (should-error (claude-code-sessions-visit-other-window)
                      :type 'user-error)
        (setq at-point alive)
        (claude-code-sessions-visit-other-window)
        (should (eq shown 'terminal))))))

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

(ert-deftest claude-code-test-view-rooted-at-a-worktree ()
  "A view rooted at a worktree shows the running session as running.
Opening the view from a file inside the worktree scopes it to the worktree,
which `project.el' treats as its own project.  The row must land in its status
group, so `d' has no target there and `k' does."
  (claude-code-tests--with-fixtures
    (claude-code-tests--with-managed-buffer buf
      (let ((id "33333333-3333-4333-8333-333333333333")
            (view (generate-new-buffer " *cc-view-test*")))
        (with-current-buffer buf (setq-local ghostel--pid 4242))
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

(ert-deftest claude-code-test-view-pins-default-directory ()
  "Opening the view pins `default-directory' to the project root, and it sticks."
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
                              (claude-code--normalize-root root))))))
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
              ((symbol-function 'read-string) (lambda (&rest _) ""))
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
                       '("/r" :prompt nil :name nil :worktree nil :model nil
                         :effort nil)))
        ;; With a menu live the root comes from its scope, not from whichever
        ;; buffer the suffix happens to run in.
        (let ((transient-current-command 'claude-code-spawn-menu))
          (call-interactively #'claude-code--spawn-session))
        (should (equal spawn-args
                       '("/scoped" :prompt nil :name "a long name" :worktree t
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
      ;; `-n' reads a name, `-w' toggles the worktree switch, `n' spawns, and
      ;; RET answers the initial-prompt read with the empty string.
      (execute-kbd-macro (kbd "- n r e v i e w RET - w n RET")))
    (should (equal (car spawns)
                   (list (claude-code--normalize-root "/home/test/proj")
                         :prompt nil :name "review" :worktree t
                         :model nil :effort nil)))))

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
      (execute-kbd-macro (kbd "n RET")))
    (with-temp-buffer
      (claude-code-spawn-menu)
      (execute-kbd-macro (kbd "n RET")))
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
                  ((symbol-function 'claude-code-resume) (lambda (&rest _) instance))
                  ((symbol-function 'claude-code-kill) #'ignore)
                  ((symbol-function 'claude-code-delete) #'ignore)
                  ;; Both the spawn and the resume RET drives display through
                  ;; the one policy.
                  ((symbol-function 'claude-code--show) #'ignore)
                  ((symbol-function 'read-string) (lambda (&rest _) ""))
                  ((symbol-function 'y-or-n-p) (lambda (_) t))
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
                  ((symbol-function 'read-string) (lambda (&rest _) ""))
                  ((symbol-function 'claude-code--show)
                   (lambda (b &rest _) (push b shown))))
          (with-temp-buffer (claude-code--spawn-session "/r"))
          (should (equal shown (list instance))))
      (kill-buffer instance))))

(ert-deftest claude-code-test-show-prefers-the-selected-window ()
  "`claude-code--show' takes the selected window only when it can host the buffer.
Run against real windows: an ordinary selected window is reused; a dedicated one
-- a side window among them -- keeps its buffer and the instance goes elsewhere;
and a window already showing the instance wins over the selected one, since a
second window would shrink the terminal to whichever of the two is smaller."
  (let ((instance (generate-new-buffer " *cc-instance*"))
        (occupant (generate-new-buffer " *cc-occupant*"))
        (sidebar (generate-new-buffer " *cc-sidebar*")))
    (unwind-protect
        ;; Nothing of the user's may decide the outcome: the three variables
        ;; `display-buffer' consults before this function's own action, the
        ;; split thresholds, and the window parameters that would otherwise make
        ;; `delete-other-windows' refuse (from a side window) or leave a
        ;; `no-delete-other-windows' sibling standing.  `save-window-excursion'
        ;; restores the layout, so the suite is safe to run from `M-x ert' in a
        ;; live frame and not only in batch.
        (let ((display-buffer-overriding-action nil)
              (display-buffer-alist nil)
              (display-buffer-base-action nil)
              (split-height-threshold 4)
              (split-width-threshold nil)
              (ignore-window-parameters t))
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) occupant)
            (claude-code--show instance)
            (should (eq (window-buffer (selected-window)) instance))
            (should (= (length (window-list)) 1))

            ;; The instance is on screen nowhere here, so reuse cannot be what
            ;; spares the side window.
            (delete-other-windows)
            (set-window-buffer (selected-window) occupant)
            (let ((side (display-buffer
                         sidebar '(display-buffer-in-side-window (side . bottom)))))
              (select-window side)
              (claude-code--show instance)
              (should (eq (window-buffer side) sidebar))
              (should (eq (window-dedicated-p side) 'side))
              ;; Which window `display-buffer' then finds is its business; that
              ;; the instance is on screen and selected, and not here, is not.
              (should-not (eq (selected-window) side))
              (should (eq (window-buffer (selected-window)) instance)))

            (delete-other-windows)
            (set-window-buffer (selected-window) occupant)
            (let ((elsewhere (split-window)))
              (set-window-buffer elsewhere instance)
              (claude-code--show instance)
              (should (eq (selected-window) elsewhere))
              (should (= (length (get-buffer-window-list instance nil t)) 1)))

            ;; Expressing the preference as a `display-buffer' action is what
            ;; leaves the user the last word, which a `switch-to-buffer' would
            ;; quietly take away.
            (delete-other-windows)
            (set-window-buffer (selected-window) occupant)
            (let* ((kept (selected-window))
                   (display-buffer-alist
                    `((,(regexp-quote (buffer-name instance))
                       display-buffer-in-side-window (side . bottom)))))
              (claude-code--show instance)
              (should (eq (window-buffer kept) occupant))
              (should (eq (window-parameter (get-buffer-window instance) 'window-side)
                          'bottom)))))
      (kill-buffer instance)
      (kill-buffer occupant)
      (kill-buffer sidebar))))

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
    (should (string-match-p "▾ Dead (3)$" (thing-at-point 'line t)))
    ;; `m' advances, so this marks two of the three dead rows.
    (forward-line 1)
    (claude-code-sessions-mark)
    (claude-code-sessions-mark)
    (claude-code--goto-group "dead")
    ;; Their tags are on screen, so the header adds nothing.
    (should (string-match-p "▾ Dead (3)$" (thing-at-point 'line t)))
    (claude-code-sessions-toggle-group)
    (should (member "dead" claude-code--collapsed))
    (should (equal 2 (length claude-code--marks)))
    (should (null (claude-code-tests--tagged-ids)))
    (should (string-match-p "▸ Dead (3, 2 marked)$" (thing-at-point 'line t)))
    ;; Unfolding hands the rows back their tags.
    (claude-code-sessions-toggle-group)
    (should (string-match-p "▾ Dead (3)$" (thing-at-point 'line t)))
    (should (equal 2 (length (claude-code-tests--tagged-ids))))))

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
         buffer id pid mcp-port)
    (unwind-protect
        (claude-code-tests--with-top-level-env
          (let ((instance (claude-code-spawn
                           root :name name
                           :prompt "Respond with the single word: pong")))
            (setq id (car instance))
            (setq buffer (cdr instance)))
          (should (string-match-p claude-code-tests--uuid-re id))
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
                                         (claude-code-project-sessions root) id)))
                                 (and s (claude-code-session-status s))))
                    45)
                   '("busy" "idle" "waiting")))
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

(provide 'claude-code-tests)
;;; claude-code-tests.el ends here
