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
     (should (= (length ts) 3))
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
       ;; A user custom title takes precedence over Claude's ai-title.
       (should (equal (plist-get s3 :title) "Renamed worktree"))))))

;;;; Model

(defun claude-code-tests--find-session (sessions id)
  "Return the session in SESSIONS whose id is ID."
  (seq-find (lambda (s) (equal (claude-code-session-id s) id)) sessions))

(ert-deftest claude-code-test-sessions-all-dead ()
  "With nothing managed, every transcript is a dead session."
  (claude-code-tests--with-fixtures
   (cl-letf (((symbol-function 'claude-code--live-managed) (lambda (_r) nil)))
     (let ((ss (claude-code-sessions "/home/test/proj")))
       (should (= (length ss) 3))
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
                 ss "33333333-3333-4333-8333-333333333333")))))))

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
               (should (= (length ss) 3))
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

(provide 'claude-code-tests)
;;; claude-code-tests.el ends here
