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

(defmacro claude-code-tests--with-fixtures (&rest body)
  "Run BODY with `claude-code-config-dir' pointed at the fixtures.
Clears the transcript cache first so tests do not leak into each other."
  (declare (indent 0))
  `(let ((claude-code-config-dir claude-code-tests--fixtures))
     (clrhash claude-code--transcript-cache)
     ,@body))

(defmacro claude-code-tests--recording-ghostel (calls &rest body)
  "Run BODY with Ghostel send/paste/key stubbed to push onto CALLS.
Each call pushes (paste STR), (send STR) or (key NAME).  A `require' of
`ghostel' becomes a no-op (the native module is absent under test), while other
features still load normally."
  (declare (indent 1))
  `(cl-letf* ((orig (symbol-function 'require))
              ((symbol-function 'require)
               (lambda (feat &rest args)
                 (unless (eq feat 'ghostel) (apply orig feat args))))
              ((symbol-function 'ghostel-paste-string)
               (lambda (s) (push (list 'paste s) ,calls)))
              ((symbol-function 'ghostel-send-string)
               (lambda (s) (push (list 'send s) ,calls)))
              ((symbol-function 'ghostel-send-key)
               (lambda (k &rest _) (push (list 'key k) ,calls))))
     ,@body))

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
       (should (equal (plist-get s1 :name) "proj-1"))
       (should (= (plist-get s1 :pid) 1001)))
     (let ((s3 (gethash "33333333-3333-4333-8333-333333333333" table)))
       (should (equal (plist-get s3 :status) "waiting"))
       (should (equal (plist-get s3 :waiting-for) "permission prompt")))
     ;; A file without a status field yields nil, not an error.
     (let ((s4 (gethash "44444444-4444-4444-8444-444444444444" table)))
       (should (null (plist-get s4 :status)))))))

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
       (should (null (plist-get s1 :worktree-p))))
     (let ((s2 (funcall by-id "22222222-2222-4222-8222-222222222222")))
       ;; A custom title supplies the title even with no ai-title line.
       (should (equal (plist-get s2 :title) "My renamed session"))
       (should (equal (plist-get s2 :last-prompt) "another task here")))
     (let ((s3 (funcall by-id "33333333-3333-4333-8333-333333333333")))
       (should (plist-get s3 :worktree-p))
       ;; The worktree name is captured from the encoded-directory suffix.
       (should (equal (plist-get s3 :worktree-name) "feat"))
       ;; A user custom title takes precedence over Claude's ai-title.
       (should (equal (plist-get s3 :title) "Renamed worktree")))
     (let ((s5 (funcall by-id "55555555-5555-4555-8555-555555555555")))
       (should (plist-get s5 :worktree-p))
       (should (equal (plist-get s5 :worktree-name) "solo"))))))

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
         ;; Dead sessions carry no live status, but keep their title.
         (should (null (claude-code-session-status s1)))
         (should (equal (claude-code-session-title s1)
                        "Understand the project layout")))
       ;; The worktree transcript shows up under the parent project.
       (should (claude-code-session-worktree-p
                (claude-code-tests--find-session
                 ss "33333333-3333-4333-8333-333333333333")))
       ;; A genuinely dead worktree (no sessions/*.json) still labels with its
       ;; own worktree directory, not the parent project (regression: C1).
       (let ((solo (claude-code-tests--find-session
                    ss "55555555-5555-4555-8555-555555555555")))
         (should (equal (claude-code-session-cwd solo)
                        "/home/test/proj/.claude/worktrees/solo"))
         (should (equal (claude-code--dir-label solo) "wt:solo")))))))

(ert-deftest claude-code-test-sessions-with-alive ()
  "A managed live instance becomes the alive session, without duplication."
  (claude-code-tests--with-fixtures
   (let ((buf (generate-new-buffer " *cc-test*"))
         (id "11111111-1111-4111-8111-111111111111"))
     (unwind-protect
         (progn
           (with-current-buffer buf (setq-local ghostel--pid 4242))
           (cl-letf (((symbol-function 'claude-code--live-managed)
                      (lambda (_r) (list (cons id buf)))))
             (let* ((ss (claude-code-sessions "/home/test/proj"))
                    (s1 (claude-code-tests--find-session ss id)))
               (should (= (length ss) 4))
               (should (claude-code-session-alive-p s1))
               (should (eq (claude-code-session-buffer s1) buf))
               (should (= (claude-code-session-pid s1) 4242))
               ;; Alive status and name come from the live sessions file.
               (should (equal (claude-code-session-status s1) "busy"))
               (should (equal (claude-code-session-name s1) "proj-1"))
               (should (equal (claude-code-session-title s1)
                              "Understand the project layout")))))
       (kill-buffer buf)))))

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
      (should (null (claude-code--process-usage nil))))))

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

(ert-deftest claude-code-test-external-session ()
  "An unmanaged transcript with a live sessions PID is external, else dead."
  (claude-code-tests--with-fixtures
   (cl-letf (((symbol-function 'claude-code--live-managed) (lambda (_r) nil)))
     ;; Session 22222222 has sessions/1002.json (pid 1002).  When Emacs does
     ;; not manage it but that pid is live, it is external, not dead.
     (cl-letf (((symbol-function 'list-system-processes) (lambda () '(1002))))
       (let ((s (claude-code-tests--find-session
                 (claude-code-sessions "/home/test/proj")
                 "22222222-2222-4222-8222-222222222222")))
         (should-not (claude-code-session-alive-p s))
         (should (claude-code-session-external-p s))
         (should (eq 'external (claude-code--session-liveness s)))))
     ;; With no such live pid the same session is simply dead.
     (cl-letf (((symbol-function 'list-system-processes) (lambda () '())))
       (let ((s (claude-code-tests--find-session
                 (claude-code-sessions "/home/test/proj")
                 "22222222-2222-4222-8222-222222222222")))
         (should-not (claude-code-session-external-p s))
         (should (eq 'dead (claude-code--session-liveness s))))))))

;;;; Operations

(ert-deftest claude-code-test-build-args-new ()
  "New-session argument lists are ordered and place the prompt last."
  (should (equal (claude-code--build-args :session-id "ID")
                 '("--session-id" "ID")))
  (should (equal (claude-code--build-args :session-id "ID" :prompt "hello")
                 '("--session-id" "ID" "hello")))
  (should (equal (claude-code--build-args
                  :session-id "ID" :name "n" :model "opus" :prompt "hi")
                 '("--session-id" "ID" "-n" "n" "--model" "opus" "hi")))
  (should (equal (claude-code--build-args :session-id "ID" :worktree t)
                 '("--session-id" "ID" "-w")))
  (should (equal (claude-code--build-args :session-id "ID" :worktree "feat")
                 '("--session-id" "ID" "-w" "feat")))
  ;; Empty prompt is dropped.
  (should (equal (claude-code--build-args :session-id "ID" :prompt "")
                 '("--session-id" "ID"))))

(ert-deftest claude-code-test-build-args-resume ()
  "Resume returns only \"-r ID\" and ignores new-session arguments."
  (should (equal (claude-code--build-args :resume "ID") '("-r" "ID")))
  (should (equal (claude-code--build-args :resume "ID" :prompt "x" :name "n")
                 '("-r" "ID"))))

(ert-deftest claude-code-test-new-uuid ()
  "Generated ids are valid, distinct version-4 UUIDs."
  (let ((re (concat "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}"
                    "-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'")))
    (should (string-match-p re (claude-code--new-uuid)))
    (should-not (equal (claude-code--new-uuid) (claude-code--new-uuid)))))

(ert-deftest claude-code-test-default-buffer-name ()
  "Buffer names fall back to the project directory name."
  (should (equal (claude-code--default-buffer-name "/home/x/proj" "nice")
                 "*claude:nice*"))
  (should (equal (claude-code--default-buffer-name "/home/x/proj" nil)
                 "*claude:proj*")))

(ert-deftest claude-code-test-on-exit-unregisters ()
  "Process exit removes the instance's registry entry."
  (let ((claude-code--managed (make-hash-table :test 'equal))
        (buf (generate-new-buffer " *cc-test-exit*")))
    (unwind-protect
        (progn
          (puthash "id-1" (list :buffer buf :origin "/r") claude-code--managed)
          (claude-code--on-exit buf "finished\n")
          (should (zerop (hash-table-count claude-code--managed))))
      (kill-buffer buf))))

(ert-deftest claude-code-test-resume-focuses-existing ()
  "Resuming an already-managed live session focuses it and spawns nothing."
  (let ((claude-code--managed (make-hash-table :test 'equal))
        (buf (generate-new-buffer " *cc-resume*"))
        (focused nil) (spawned nil))
    (unwind-protect
        (progn
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
            (should (= (hash-table-count claude-code--managed) 1))))
      (kill-buffer buf))))

(ert-deftest claude-code-test-kill ()
  "Killing an alive session drops its registry entry and buffer."
  (let ((claude-code--managed (make-hash-table :test 'equal))
        (buf (generate-new-buffer " *cc-kill*")))
    (unwind-protect
        (progn
          (puthash "id-k" (list :buffer buf :origin "/r") claude-code--managed)
          (claude-code-kill (claude-code-session--create
                             :id "id-k" :alive-p t :buffer buf))
          (should-not (gethash "id-k" claude-code--managed))
          (should-not (buffer-live-p buf))
          ;; A dead session cannot be killed.
          (should-error (claude-code-kill
                         (claude-code-session--create :id "d" :alive-p nil))
                        :type 'user-error))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest claude-code-test-rename ()
  "Rename sends exactly the /rename slash command, then submits."
  (let ((buf (generate-new-buffer " *cc-rename*")) (calls '()))
    (unwind-protect
        (progn
          (claude-code-tests--recording-ghostel calls
						(claude-code-rename
						 (claude-code-session--create :id "s" :alive-p t :buffer buf)
						 "My Name"))
          (should (equal (reverse calls)
                         '((send "/rename My Name") (key "return"))))
          ;; Renaming a dead session is refused.
          (should-error (claude-code-rename
                         (claude-code-session--create :id "d" :alive-p nil) "x")
                        :type 'user-error))
      (kill-buffer buf))))

(ert-deftest claude-code-test-send-text ()
  "Newlines paste as one message; single lines type; RET only when submitting."
  (let ((buf (generate-new-buffer " *cc-send*")) (calls '()))
    (unwind-protect
        (let ((s (claude-code-session--create :id "s" :alive-p t :buffer buf)))
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
						(should (equal (reverse calls) '((paste "a\nb") (key "return"))))))
      (kill-buffer buf))))

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
  "Columns fall back sensibly and render usage."
  (let* ((s (claude-code-session--create
             :id "abcdef01-0000-4000-8000-000000000000"
             :alive-p nil :title "The Title" :cwd "/home/x/proj"))
         (v (claude-code--format-session s nil)))
    (should (equal (substring-no-properties (aref v 0)) "dead"))
    ;; No name -> title.
    (should (equal (aref v 1) "The Title"))
    (should (equal (substring-no-properties (aref v 2)) "abcdef01"))
    (should (equal (aref v 3) "proj"))
    (should (equal (aref v 4) ""))
    (should (equal (aref v 5) "")))
  (let* ((s (claude-code-session--create
             :id "11112222-0000-4000-8000-000000000000"
             :alive-p t :status "busy" :name "worker"
             :worktree-p t :cwd "/home/x/proj/.claude/worktrees/feat"))
         (v (claude-code--format-session s '(12.5 . 204800))))
    (should (equal (substring-no-properties (aref v 0)) "busy"))
    (should (eq (get-text-property 0 'face (aref v 0)) 'warning))
    (should (equal (aref v 1) "worker"))
    (should (equal (aref v 3) "wt:feat"))
    (should (equal (aref v 4) "12.5"))
    (should (equal (aref v 5) "200M"))))

(ert-deftest claude-code-test-session-display-name ()
  "The display name draws on one ordered set of sources."
  ;; The live name wins over everything.
  (should (equal "chosen"
                 (claude-code--session-display-name
                  (claude-code-session--create
                   :id "abcdef01-0000-4000-8000-000000000000"
                   :name "chosen" :title "t" :last-prompt "p"))))
  ;; Then the transcript title, then the prompt, then the short id.
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

(ert-deftest claude-code-test-group-key ()
  "Grouping keys depend on the current grouping mode."
  (let ((alive (claude-code-session--create :alive-p t :status "busy"))
        (external (claude-code-session--create :alive-p nil :external-p t))
        (dead (claude-code-session--create :alive-p nil)))
    (let ((claude-code-group-by 'status))
      (should (equal (claude-code--group-key alive) "busy"))
      (should (equal (claude-code--group-key external) "external"))
      (should (equal (claude-code--group-key dead) "dead")))
    (let ((claude-code-group-by 'state))
      (should (equal (claude-code--group-key alive) "alive"))
      ;; External keeps its own group even when grouping by state.
      (should (equal (claude-code--group-key external) "external"))
      (should (equal (claude-code--group-key dead) "dead")))))

(ert-deftest claude-code-test-group-order ()
  "Groups sort by urgency, with external and dead last."
  (should (equal (sort (list "dead" "idle" "external" "waiting" "busy")
                       #'claude-code--group-less-p)
                 '("waiting" "busy" "idle" "external" "dead"))))

(ert-deftest claude-code-test-view-renders-and-collapses ()
  "The view prints group headers and rows, and collapsing hides rows."
  (claude-code-tests--with-fixtures
   (let ((claude-code-refresh-interval nil)
         (buf (get-buffer-create " *cc-view-test*")))
     (unwind-protect
         (with-current-buffer buf
           (cl-letf (((symbol-function 'claude-code--live-managed)
                      (lambda (_r) nil)))
             (claude-code-sessions-mode)
             (setq claude-code--project "/home/test/proj")
             (claude-code-sessions-refresh)
             (let ((text (buffer-substring-no-properties (point-min) (point-max))))
               (should (string-match-p "Dead (4)" text))
               (should (string-match-p "11111111" text))
               ;; The worktree session is listed under the parent project.
               (should (string-match-p "wt:feat" text)))
             (push "dead" claude-code--collapsed)
             (claude-code-sessions-refresh)
             (let ((text (buffer-substring-no-properties (point-min) (point-max))))
               (should (string-match-p "Dead (4)" text))
               (should-not (string-match-p "11111111" text)))))
       (kill-buffer buf)))))

;;;; Integration (real Ghostel + real `claude')
;;
;; These exercise the live spawn/kill lifecycle against an actual `claude'
;; process, so they need Ghostel's native module, network access, and a
;; logged-in CLI.  `make test' and CI never run them: they skip unless
;; CLAUDE_CODE_INTEGRATION is set (use `make integration').
;;
;; GOTCHA — READ THIS BEFORE DEBUGGING SPAWNING.  A running `claude' exports the
;; variables in `claude-code-tests--nesting-env-vars' to mark its subprocesses
;; as nested children.  A `claude' launched with those set does NOT start its
;; own top-level session: it writes no `sessions/*.json' and no transcript, so
;; the model reports no status and the whole lifecycle looks broken.  This bites
;; when debugging the package *from inside a Claude Code session* (e.g. another
;; Claude Code agent running Emacs).  Strip them before spawning —
;; `claude-code-tests--with-top-level-env' does exactly that.  A normally
;; launched Emacs never has these variables, which is why production code does
;; not touch the environment.

(defconst claude-code-tests--nesting-env-vars
  '("CLAUDECODE" "CLAUDE_CODE_CHILD_SESSION" "CLAUDE_CODE_ENTRYPOINT"
    "CLAUDE_CODE_SSE_PORT" "CLAUDE_CODE_SSE_URL" "CLAUDE_CODE_SESSION_ID")
  "Runtime variables a parent `claude' sets to mark nested children.
Only relevant to testing/debugging (see the note above).")

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

(ert-deftest claude-code-test-integration-lifecycle ()
  "Spawn a real instance, see it register a session, then kill and delete it."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         buffer id pid)
    (unwind-protect
        (claude-code-tests--with-top-level-env
         (setq buffer (claude-code-spawn
                       root :prompt "Respond with the single word: pong"
                       :name "ert-integration"))
         (maphash (lambda (k v) (when (eq (plist-get v :buffer) buffer) (setq id k)))
                  claude-code--managed)
         (should id)
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
                                   (claude-code--project-dir default-directory))))
          (when (file-exists-p f) (delete-file f)))))))

(provide 'claude-code-tests)
;;; claude-code-tests.el ends here
