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

(provide 'claude-code-tests)
;;; claude-code-tests.el ends here
