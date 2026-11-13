;;; claude-code-mcp-tests.el --- Tests for claude-code-mcp -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT suite for claude-code-mcp.el: the protocol as `claude-code-mcp-dispatch'
;; answers it, the tools and the calls they take, the launch wiring, and the
;; bridge driven end to end through a real Emacs server.  A live handshake test
;; is gated behind CLAUDE_CODE_INTEGRATION.  Run with `make test' (unit) or
;; `make integration' (live).

;;; Code:

(require 'ert)
(require 'seq)
(require 'cl-lib)
(require 'claude-code)
(require 'claude-code-mcp)
;; For the `claude-code-tests--' scaffolding the sibling suite owns, starting
;; with `claude-code-tests--with-registry', which every isolated test here
;; expands into.
(require 'claude-code-tests)

(defmacro claude-code-mcp-tests--isolated (&rest body)
  "Run BODY with session lookups isolated from the real config dir.
Points `claude-code-config-dir' at a nonexistent path, so sessions/ is empty
and `claude-code--pid-cwd' names no directory, and rebinds
`claude-code--managed' to a fresh table."
  (declare (indent 0))
  `(let ((claude-code-config-dir "/claude-code-mcp-tests-nonexistent"))
     (claude-code-tests--with-registry ,@body)))

(defmacro claude-code-mcp-tests--with-session-at (pid cwd &rest body)
  "Run BODY with the `claude' process PID working in CWD.
That is what its sessions/ file says, in a scratch config dir private to BODY
along with the registry."
  (declare (indent 2))
  `(claude-code-tests--with-registry
     (claude-code-tests--with-config
       (claude-code-tests--write-session-file
        ,pid (json-serialize (list (cons 'pid ,pid) (cons 'sessionId "caller")
                                   (cons 'cwd ,cwd))))
       ,@body)))

(defmacro claude-code-mcp-tests--with-tools (names &rest body)
  "Run BODY, then unregister the tools named in NAMES.
The registry is global, so a tool left behind would leak into every later
`tools/list'."
  (declare (indent 1))
  `(unwind-protect (progn ,@body)
     (dolist (name ,names) (remhash name claude-code--mcp-tools))))

(defun claude-code-mcp-tests--request (method &optional id params)
  "Build a JSON-RPC request alist for METHOD with optional ID and PARAMS."
  (append (list (cons 'jsonrpc "2.0"))
          (when id (list (cons 'id id)))
          (list (cons 'method method))
          (when params (list (cons 'params params)))))

(defun claude-code-mcp-tests--encode (request)
  "Return REQUEST, an alist, as the base64 JSON line the bridge passes on."
  (base64-encode-string (json-serialize request) t))

(defun claude-code-mcp-tests--decode (reply)
  "Return REPLY, base64 JSON from `claude-code-mcp-dispatch', parsed."
  (json-parse-string (decode-coding-string (base64-decode-string reply) 'utf-8)
                     :object-type 'alist))

(defun claude-code-mcp-tests--send (pid request)
  "Dispatch REQUEST from the `claude' process PID; return the parsed reply.
REQUEST is an alist, or a string holding the raw message.  Nil means no reply."
  (when-let* ((reply (claude-code-mcp-dispatch
                      (if (stringp request)
                          (base64-encode-string request t)
                        (claude-code-mcp-tests--encode request))
                      pid)))
    (claude-code-mcp-tests--decode reply)))

(defun claude-code-mcp-tests--call (pid params)
  "Dispatch a `tools/call' carrying PARAMS from PID; return the parsed reply."
  (claude-code-mcp-tests--send
   pid (claude-code-mcp-tests--request "tools/call" 7 params)))

(defun claude-code-mcp-tests--call-tool (pid name &rest arguments)
  "Dispatch a `tools/call' of the tool NAME from PID; return the parsed reply.
ARGUMENTS are the (NAME . VALUE) pairs of the call's `arguments' object."
  (claude-code-mcp-tests--call
   pid (list (cons 'name name) (cons 'arguments arguments))))

(defun claude-code-mcp-tests--result-text (response)
  "Return the text payload of RESPONSE's tool result."
  (alist-get 'text (aref (alist-get 'content (alist-get 'result response)) 0)))

(defun claude-code-mcp-tests--answer (reply)
  "Return REPLY's tool result as (ERROR-P . TEXT)."
  (let ((is-error (alist-get 'isError (alist-get 'result reply))))
    (should (memq is-error '(t :false)))
    (cons (eq is-error t) (claude-code-mcp-tests--result-text reply))))

(defun claude-code-mcp-tests--error (reply)
  "Return REPLY's JSON-RPC error as (CODE . MESSAGE)."
  (let ((error-object (alist-get 'error reply)))
    (cons (alist-get 'code error-object) (alist-get 'message error-object))))

(defun claude-code-mcp-tests--eval-answer (code)
  "Return `eval' of CODE, from a caller with no session, as (ERROR-P . TEXT)."
  (claude-code-mcp-tests--isolated
    (claude-code-mcp-tests--answer
     (claude-code-mcp-tests--call-tool 4242 "eval" (cons 'code code)))))

(defun claude-code-mcp-tests--tool-schema (name)
  "Return the `inputSchema' `tools/list' advertises for the tool NAME, or nil."
  (alist-get 'inputSchema
             (seq-find (lambda (tool) (equal (alist-get 'name tool) name))
                       (alist-get 'tools
                                  (alist-get 'result
                                             (claude-code-mcp-tests--send
                                              4242
                                              (claude-code-mcp-tests--request
                                               "tools/list" 1)))))))

(defvar claude-code-mcp-tests--x nil
  "Scratch special variable for the `eval' tool tests.")

;;;; Protocol

(ert-deftest claude-code-mcp-test-dispatch-round-trip ()
  "A session's handshake and calls round-trip through `claude-code-mcp-dispatch'."
  (claude-code-mcp-tests--isolated
    ;; The server answers with its own protocol version, whatever is asked for.
    (dolist (params (list (list (cons 'protocolVersion "2024-11-05")) nil))
      (let ((reply (claude-code-mcp-tests--send
                    4242 (claude-code-mcp-tests--request "initialize" 1 params))))
        (should (equal (alist-get 'jsonrpc reply) "2.0"))
        (should (equal (alist-get 'id reply) 1))
        (should (equal (alist-get 'protocolVersion (alist-get 'result reply))
                       claude-code--mcp-protocol-version))))
    (dolist (id '("seven" :false))
      (should (equal (alist-get 'id (claude-code-mcp-tests--send
                                     4242 (claude-code-mcp-tests--request
                                           "tools/list" id)))
                     id)))
    ;; A notification is answered with nothing.
    (should-not (claude-code-mcp-tests--send
                 4242 (claude-code-mcp-tests--request "notifications/initialized")))
    (should (claude-code-mcp-tests--tool-schema "spawn"))
    (let ((schema (claude-code-mcp-tests--tool-schema "eval")))
      (should (equal (alist-get 'type schema) "object"))
      (should (equal (alist-get 'required schema) ["code"]))
      (should (equal (alist-get 'type (alist-get 'code (alist-get 'properties schema)))
                     "string")))
    (let* ((result (alist-get 'result (claude-code-mcp-tests--call-tool
                                       4242 "eval"
                                       (cons 'code "(concat \"ñ\" \"✓\")"))))
           (item (aref (alist-get 'content result) 0)))
      (should (equal (alist-get 'type item) "text"))
      (should (equal (alist-get 'text item) "\"ñ✓\""))
      (should (eq (alist-get 'isError result) :false)))))

(ert-deftest claude-code-mcp-test-dispatch-answers-malformed-input ()
  "Malformed input or an unserializable reply gets a JSON-RPC error, not a signal."
  (claude-code-mcp-tests--isolated
    (let ((reply (claude-code-mcp-tests--send
                  4242 (claude-code-mcp-tests--request "no/such/method" 7))))
      (should (equal (alist-get 'jsonrpc reply) "2.0"))
      (should (equal (alist-get 'id reply) 7))
      (should (= (car (claude-code-mcp-tests--error reply)) -32601)))
    ;; An answer carrying a raw byte, which JSON cannot hold.
    (let ((reply (claude-code-mcp-tests--call-tool
                  4242 "eval"
                  (cons 'code "(error \"%s\" (string-to-unibyte \"\\377\"))"))))
      (should (equal (alist-get 'id reply) 7))
      (should (= (car (claude-code-mcp-tests--error reply)) -32603)))
    ;; Neither a message that is no request nor one that is no JSON has an id.
    (pcase-dolist (`(,body . ,code) '(("[1,2]" . -32600)
                                      ("5" . -32600)
                                      ("\"x\"" . -32600)
                                      ("null" . -32600)
                                      ("{not json" . -32700)))
      (let ((reply (claude-code-mcp-tests--send 4242 body)))
        (should (eq (alist-get 'id reply) :null))
        (should (= (car (claude-code-mcp-tests--error reply)) code))))
    (should (= (car (claude-code-mcp-tests--error
                     (claude-code-mcp-tests--decode
                      (claude-code-mcp-dispatch "%%%" 4242))))
               -32700))))

;;;; Tools

(ert-deftest claude-code-mcp-test-calls-hold-to-the-schema ()
  "A handler runs only on arguments its tool's advertised schema allows."
  (let ((seen 'unset))
    (claude-code-mcp-tests--isolated
      (claude-code-mcp-tests--with-tools '("cc-mcp-test-schema" "cc-mcp-test-confirm"
                                           "cc-mcp-test-noargs" "cc-mcp-test-bad")
        ;; A spec the schema cannot carry registers nothing.
        (should-error (claude-code-mcp-make-tool
                       :name "cc-mcp-test-bad" :description "No handler."))
        (dolist (arg '((:name "count" :type integer)
                       (:type string)
                       (:name "level" :type string :enum (low high))))
          (should-error (claude-code-mcp-make-tool
                         :name "cc-mcp-test-bad" :description "Malformed."
                         :args (list arg) :handler #'ignore)))
        (should-not (claude-code-mcp-tests--tool-schema "cc-mcp-test-bad"))
        (claude-code-mcp-make-tool
         :name "cc-mcp-test-schema" :description "Typed arguments."
         :args (list (list :name "text" :type 'string)
                     (list :name "level" :type 'string :optional t
                           :enum '("low" "high"))
                     (list :name "flag" :type 'boolean :optional t))
         :handler (lambda (text &optional level flag)
                    (setq seen (list text level flag))
                    "ok"))
        (claude-code-mcp-make-tool
         :name "cc-mcp-test-confirm" :description "One required boolean."
         :args (list (list :name "confirm" :type 'boolean))
         :handler (lambda (confirm) (setq seen (list confirm)) "ok"))
        (claude-code-mcp-make-tool
         :name "cc-mcp-test-noargs" :description "No arguments."
         :handler (lambda () (setq seen 'ran) "ok"))
        (let* ((schema (claude-code-mcp-tests--tool-schema "cc-mcp-test-schema"))
               (properties (alist-get 'properties schema)))
          (should (equal (alist-get 'required schema) ["text"]))
          (should (equal (alist-get 'enum (alist-get 'level properties))
                         ["low" "high"]))
          (should (equal (alist-get 'type (alist-get 'flag properties)) "boolean")))
        (cl-flet ((call (tool arguments)
                    (setq seen 'unset)
                    (claude-code-mcp-tests--call
                     4242 (list (cons 'name tool) (cons 'arguments arguments)))))
          (pcase-dolist (`(,tool ,arguments ,received)
                         '(("cc-mcp-test-schema" ((text . "t")) ("t" nil nil))
                           ("cc-mcp-test-schema" ((text . "t") (level . "high")
                                                  (flag . t))
                            ("t" "high" t))
                           ("cc-mcp-test-schema" ((text . "t") (flag . :false))
                            ("t" nil nil))
                           ("cc-mcp-test-schema" ((text . "t") (flag . :null))
                            ("t" nil nil))
                           ;; A value for a required string, nothing for an
                           ;; optional one.
                           ("cc-mcp-test-schema" ((text . "") (level . ""))
                            ("" nil nil))
                           ;; False is an answer to a required boolean.
                           ("cc-mcp-test-confirm" ((confirm . :false)) (nil))
                           ;; Null is the absent arguments object.
                           ("cc-mcp-test-noargs" :null ran)))
            (should-not (car (claude-code-mcp-tests--answer (call tool arguments))))
            (should (equal seen received)))
          ;; Each refusal names what the caller got wrong.
          (pcase-dolist (`(,tool ,arguments ,named)
                         '(("cc-mcp-test-schema" ((text . 42)) "text")
                           ("cc-mcp-test-schema" ((text . :false)) "text")
                           ("cc-mcp-test-schema" ((text . :null)) "text")
                           ("cc-mcp-test-schema" nil "text")
                           ("cc-mcp-test-schema" ((text . "t") (flag . "yes")) "flag")
                           ("cc-mcp-test-schema" ((text . "t") (flag . "")) "flag")
                           ("cc-mcp-test-schema" ((text . "t") (level . "turbo"))
                            "level")
                           ("cc-mcp-test-confirm" nil "confirm")
                           ("cc-mcp-test-confirm" ((confirm . :null)) "confirm")
                           ("cc-mcp-test-noargs" "code" "object")
                           ("cc-mcp-test-noargs" 42 "object")
                           ("cc-mcp-test-noargs" [1 2] "object")
                           ("nope" nil "nope")))
            (let ((refusal (claude-code-mcp-tests--error (call tool arguments))))
              (should (equal (car refusal) -32602))
              (should (string-match-p named (cdr refusal)))
              (should (eq seen 'unset)))))
        (pcase-dolist (`(,params . ,named) '(("code" . "object")
                                             (42 . "object")
                                             ([1 2] . "object")
                                             (:null . "Unknown tool")))
          (let ((refusal (claude-code-mcp-tests--error
                          (claude-code-mcp-tests--call 4242 params))))
            (should (equal (car refusal) -32602))
            (should (string-match-p named (cdr refusal)))))))))

(ert-deftest claude-code-mcp-test-eval-reads-one-form ()
  "`eval' evaluates the one form its code holds and answers with its value."
  (let ((claude-code-mcp-tests--x nil))
    (pcase-dolist (`(,code . ,value)
                   '(("(+ 40 2)" . "42")
                     ("\"a;b\"" . "\"a;b\"")
                     ("?;" . "59")
                     ("(progn (setq claude-code-mcp-tests--x 5)
                              (* claude-code-mcp-tests--x claude-code-mcp-tests--x))"
                      . "25")
                     (";; lead\n(+ 1 2) ; )" . "3")
                     ("" . "nil")
                     (";; just a comment" . "nil")))
      (should (equal (claude-code-mcp-tests--eval-answer code) (cons nil value))))
    (pcase-dolist (`(,code . ,complaint)
                   '(("(setq claude-code-mcp-tests--x 'ran) 42" . "progn")
                     ("(+ 1 2))" . "Invalid read syntax")
                     ("(+ 1 2) (+ 3" . "End of file")
                     ("(/ 1 0)" . "\\`Error:")))
      (let ((answer (claude-code-mcp-tests--eval-answer code)))
        (should (car answer))
        (should (string-match-p complaint (cdr answer)))
        ;; Wrapping text that reads as no form leaves it unreadable.
        (unless (equal complaint "progn")
          (should-not (string-match-p "progn" (cdr answer))))))
    ;; A refused submission does not run in part.
    (should (equal claude-code-mcp-tests--x 5))))

(ert-deftest claude-code-mcp-test-eval-runs-in-a-throwaway-buffer ()
  "`eval' runs in a buffer of its own that no call outlives, and answers in full."
  (let* ((claude-code-mcp-tests--x nil)
         (source "(setq claude-code-mcp-tests--x 'read-from-the-user)")
         (user (generate-new-buffer " *cc-mcp-test-user*"))
         (before (buffer-list)))
    (unwind-protect
        (progn
          (with-current-buffer user
            (insert source)
            (goto-char (point-min))
            (should (equal (claude-code-mcp-tests--eval-answer "(buffer-string)")
                           '(nil . "\"\"")))
            (claude-code-mcp-tests--eval-answer "(insert \"x\")")
            (should (equal (buffer-string) source)))
          ;; A form that leaves the user's buffer current still answers for itself.
          (should (equal (claude-code-mcp-tests--eval-answer
                          (format "(progn (set-buffer %S) :submitted)"
                                  (buffer-name user)))
                         '(nil . ":submitted")))
          (should-not claude-code-mcp-tests--x)
          (should (= (with-current-buffer user (point)) 1))
          (dolist (code '("(kill-buffer)" "(error \"boom\")" "(+ 1"))
            (claude-code-mcp-tests--eval-answer code))
          (let ((claude-code-mcp-eval-timeout 0.1))
            (should (car (claude-code-mcp-tests--eval-answer "(sit-for 5)"))))
          (should-not (seq-difference (buffer-list) before))
          (let ((print-length 2)
                (print-level 1))
            (should (equal (claude-code-mcp-tests--eval-answer "(list 1 2 3 4)")
                           '(nil . "(1 2 3 4)")))
            (should (equal (claude-code-mcp-tests--eval-answer "'(1 (2 (3 (4))))")
                           '(nil . "(1 (2 (3 (4))))")))))
      (kill-buffer user))))

(ert-deftest claude-code-mcp-test-call-runs-where-the-caller-works ()
  "A tool call runs in its caller's working directory, for the call alone."
  (let ((seen 'unset))
    (claude-code-mcp-tests--with-tools '("cc-mcp-test-cwd")
      (claude-code-mcp-make-tool
       :name "cc-mcp-test-cwd" :description "Report the caller's cwd."
       :handler (lambda ()
                  (setq seen (cons claude-code--mcp-session-cwd default-directory))
                  "ok"))
      (with-temp-buffer
        (setq default-directory "/home/test/root/")
        (claude-code-mcp-tests--with-session-at 4242 "/home/test/proj"
          ;; A caller with no sessions/ file works where the request arrived.
          (pcase-dolist (`(,caller ,cwd) '((4242 "/home/test/proj")
                                           (4343 "/home/test/root")
                                           (nil "/home/test/root")))
            (setq seen 'unset)
            (claude-code-mcp-tests--call-tool caller "cc-mcp-test-cwd")
            (should (equal seen (cons cwd (file-name-as-directory cwd)))))
          (should-not claude-code--mcp-session-cwd)
          ;; A directory a call gives the buffer it arrived in stays.
          (claude-code-mcp-tests--call-tool
           4242 "eval"
           (cons 'code (format "(with-current-buffer %S
                                  (setq default-directory \"/home/test/root/wt/\"))"
                               (buffer-name))))
          (should (equal default-directory "/home/test/root/wt/")))))
    (claude-code-tests--with-fixtures
      (should (equal (claude-code-mcp-tests--answer
                      (claude-code-mcp-tests--call-tool
                       1003 "eval" (cons 'code "default-directory")))
                     '(nil . "\"/home/test/proj/.claude/worktrees/feat/\""))))))

(defmacro claude-code-mcp-tests--with-caller (var cwd execs &rest body)
  "Run BODY with VAR the PID of a `claude' working in CWD, the launch stubbed.
EXECS collects the (BUFFER ARGS) of every launch, so a test asserts what
reached the CLI without a `claude' ever running."
  (declare (indent 3))
  `(let ((,var 4242))
     (claude-code-mcp-tests--with-session-at ,var ,cwd
       (claude-code-tests--recording-launch ,execs ,@body))))

(ert-deftest claude-code-mcp-test-spawn ()
  "`spawn' launches an instance where its caller works and answers with its id."
  (let ((execs '()))
    (claude-code-mcp-tests--with-caller caller "/home/test/proj" execs
      (cl-flet ((spawn (&rest arguments)
                  (apply #'claude-code-mcp-tests--call-tool caller "spawn" arguments))
                (launched () (car execs)))
        (let ((answer (claude-code-mcp-tests--answer (spawn))))
          (should-not (car answer))
          (should (string-match-p claude-code-tests--uuid-re (cdr answer)))
          (should (= (length execs) 1))
          (should (equal (cadr (member "--session-id" (nth 1 (launched))))
                         (cdr answer)))
          (should-not (member "--model" (nth 1 (launched))))
          (should (equal (buffer-local-value 'default-directory (car (launched)))
                         "/home/test/proj/")))
        ;; The effort is not vetted, and the worktree is one argument whatever
        ;; it is called.
        (spawn '(prompt . "do the thing") '(name . "a long name") '(model . "opus")
               '(effort . "turbo") '(worktree . "--ax-screen-reader"))
        (let ((args (nth 1 (launched))))
          (should (member "--name=a long name" args))
          (should (equal (cadr (member "--model" args)) "opus"))
          (should (equal (cadr (member "--effort" args)) "turbo"))
          (should (member "--worktree=--ax-screen-reader" args))
          (should-not (member "--ax-screen-reader" args))
          (should (equal (cadr (member "--" args)) "do the thing")))
        ;; An empty string is an option left out, not one given no value.
        (spawn '(prompt . "") '(name . "") '(model . "") '(effort . "")
               '(worktree . ""))
        (let ((args (nth 1 (launched))))
          (should-not (member "" args))
          (should-not (seq-find (lambda (arg) (string-suffix-p "=" arg)) args)))
        (dolist (value '(t :false))
          (let ((launches (length execs)))
            (should (= (car (claude-code-mcp-tests--error
                             (spawn (cons 'worktree value))))
                       -32602))
            (should (= (length execs) launches))))))
    ;; A caller in a Claude worktree has the instance join that worktree.
    (claude-code-mcp-tests--with-caller caller
        "/home/test/proj/.claude/worktrees/feat" execs
      (claude-code-mcp-tests--call-tool caller "spawn")
      (should (equal (buffer-local-value 'default-directory (car (car execs)))
                     "/home/test/proj/"))
      (should (member "--worktree=feat" (nth 1 (car execs)))))))

;;;; Launch wiring

(defmacro claude-code-mcp-tests--with-server-at (tcp dir &rest body)
  "Run BODY with this Emacs's server named `server' in DIR, over TCP when TCP.
DIR is the socket dir, or the TCP server's file dir.  No server runs, and no
launch has warned yet; `display-warning' pushes onto `warnings' instead."
  (declare (indent 2))
  `(let ((server-use-tcp ,tcp)
         (server-name "server")
         (server-socket-dir ,dir)
         (server-auth-dir ,dir)
         (server-process nil)
         (claude-code--mcp-warned nil)
         (warnings '()))
     (cl-letf (((symbol-function 'display-warning)
                (lambda (type message &rest _) (push (cons type message) warnings))))
       ,@body)))

(ert-deftest claude-code-mcp-test-launch-wiring ()
  "A local instance is pointed at this Emacs's server, running yet or not."
  (cl-flet ((child-env (wiring name)
              (let ((process-environment (list "EMACS_SOCKET_NAME=/stale"
                                               "EMACS_SERVER_FILE=/stale")))
                (claude-code--apply-env (cdr wiring))
                (getenv name))))
    (with-temp-buffer
      (pcase-dolist (`(,tcp ,dir ,named ,unset)
                     '((nil "/run/test/emacs/" "EMACS_SOCKET_NAME" "EMACS_SERVER_FILE")
                       (t "/home/test/server/" "EMACS_SERVER_FILE" "EMACS_SOCKET_NAME")))
        (claude-code-mcp-tests--with-server-at tcp dir
          (let* ((claude-code-mcp-auto-approve t)
                 (wiring (claude-code--mcp-wiring (current-buffer))))
            (should (equal (child-env wiring named) (concat dir "server")))
            (should-not (child-env wiring unset))
            (should (equal (cadr (member "--allowedTools" (car wiring)))
                           "mcp__emacs")))
          (let ((claude-code-mcp-auto-approve nil))
            (should-not (member "--allowedTools"
                                (car (claude-code--mcp-wiring (current-buffer))))))))
      ;; Its bridge would run on the remote host, where `emacs' is anyone's.
      (claude-code-mcp-tests--with-server-at nil "/run/test/emacs/"
        (setq default-directory "/ssh:cc-test-host:/r/")
        (should-not (claude-code--mcp-wiring (current-buffer)))
        (should-not warnings)))))

;;;; The bridge, end to end through a real Emacs server

(defmacro claude-code-mcp-tests--with-emacs-server (&rest body)
  "Run BODY with this Emacs serving `emacsclient' from a server of its own.
The server listens on loopback TCP, which a sandbox refusing Unix sockets
still allows; BODY is skipped when no server can start."
  (declare (indent 0))
  `(let* ((server-use-tcp t)
          (server-host "127.0.0.1")
          (server-auth-dir (file-name-as-directory
                            (make-temp-file "cc-mcp-server" t)))
          (server-name "cc-mcp-test")
          (server-process nil)
          (inhibit-message t))
     (unwind-protect
         (progn
           (ignore-errors (server-start nil t))
           (skip-unless (process-live-p server-process))
           ,@body)
       (ignore-errors (server-start t t))
       (delete-directory server-auth-dir t))))

(defun claude-code-mcp-tests--bridge (env)
  "Run the registered MCP server with the cells of ENV set; return its process.
ENV holds cells as `claude-code--apply-env' takes them.  What the bridge
writes to stdout collects in its process buffer, its stderr apart."
  (let* ((config (claude-code--mcp-server-config))
         (stderr (generate-new-buffer " *cc-mcp-bridge-stderr*"))
         (process-environment
          (append (mapcar (pcase-lambda (`(,name . ,value))
                            (if value (concat name "=" value) name))
                          env)
                  process-environment))
         (bridge (make-process :name "cc-mcp-bridge"
                               :buffer (generate-new-buffer " *cc-mcp-bridge*")
                               :stderr stderr
                               :command (cons (alist-get 'command config)
                                              (append (alist-get 'args config) nil))
                               :connection-type 'pipe :noquery t
                               ;; Not the default, which reports the exit in
                               ;; the buffer.
                               :sentinel #'ignore)))
    (process-put bridge 'stderr stderr)
    bridge))

(defun claude-code-mcp-tests--bridge-lines (bridge)
  "Return the lines BRIDGE has written so far."
  (with-current-buffer (process-buffer bridge)
    (split-string (buffer-string) "\n" t)))

(defun claude-code-mcp-tests--bridge-ask (bridge &rest requests)
  "Send BRIDGE each of REQUESTS, alists, one line each; return its replies.
The replies are parsed, and awaited until there is one per request carrying
an `id'."
  (let* ((before (length (claude-code-mcp-tests--bridge-lines bridge)))
         (expected (+ before (seq-count (lambda (request)
                                          (alist-get 'id request))
                                        requests))))
    (dolist (request requests)
      (process-send-string bridge (concat (json-serialize request) "\n")))
    (should (claude-code-tests--await
             (lambda () (>= (length (claude-code-mcp-tests--bridge-lines bridge))
                            expected))
             10))
    (mapcar (lambda (line) (json-parse-string line :object-type 'alist))
            (nthcdr before (claude-code-mcp-tests--bridge-lines bridge)))))

(ert-deftest claude-code-mcp-test-registered-bridge ()
  "The registered MCP server carries a session's calls to this Emacs and back.
Its caller is its parent, working where its sessions/ file says or else where
the bridge started.  Once Emacs is gone it exits silently on the next message."
  (skip-unless (executable-find "emacsclient"))
  (claude-code-mcp-tests--with-emacs-server
    (claude-code-mcp-tests--isolated
      (let* ((default-directory (file-name-as-directory
                                 (make-temp-file "cc-mcp-cwd" t)))
             (cwd default-directory)
             (bridge (claude-code-mcp-tests--bridge
                      (cons '("ALTERNATE_EDITOR" . "echo")
                            (claude-code--mcp-server-env))))
             (call-eval (lambda (id code)
                          (claude-code-mcp-tests--request
                           "tools/call" id
                           (list (cons 'name "eval")
                                 (cons 'arguments (list (cons 'code code))))))))
        (unwind-protect
            (progn
              ;; A notification draws no line, so each reply lines up with its
              ;; request.
              (pcase-let ((`(,init ,tools ,text ,big ,here)
                           (claude-code-mcp-tests--bridge-ask
                            bridge
                            (claude-code-mcp-tests--request
                             "initialize" 1
                             (list (cons 'protocolVersion "2025-06-18")))
                            (claude-code-mcp-tests--request
                             "notifications/initialized")
                            (claude-code-mcp-tests--request "tools/list" 2)
                            (funcall call-eval 3 "(concat \"ñ\" \"✓\")")
                            (funcall call-eval 4 "(make-string 200000 ?x)")
                            (funcall call-eval "five" "default-directory"))))
                (should (equal (alist-get 'protocolVersion (alist-get 'result init))
                               claude-code--mcp-protocol-version))
                (should (seq-find (lambda (tool) (equal (alist-get 'name tool) "eval"))
                                  (alist-get 'tools (alist-get 'result tools))))
                (should (equal (claude-code-mcp-tests--result-text text) "\"ñ✓\""))
                (should (= (length (claude-code-mcp-tests--result-text big)) 200002))
                (should (equal (alist-get 'id here) "five"))
                (should (equal (file-truename
                                (read (claude-code-mcp-tests--result-text here)))
                               (file-truename cwd))))
              (claude-code-mcp-tests--with-session-at (emacs-pid) "/home/test/proj"
                (should (equal (claude-code-mcp-tests--result-text
                                (car (claude-code-mcp-tests--bridge-ask
                                      bridge (funcall call-eval 6 "default-directory"))))
                               "\"/home/test/proj/\"")))
              (server-start t t)
              (let ((lines (length (claude-code-mcp-tests--bridge-lines bridge))))
                (process-send-string
                 bridge (concat (json-serialize (claude-code-mcp-tests--request
                                                 "tools/list" 7))
                                "\n"))
                (should (claude-code-tests--await
                         (lambda () (not (process-live-p bridge))) 10))
                (should (= (process-exit-status bridge) 1))
                (should (= (length (claude-code-mcp-tests--bridge-lines bridge))
                           lines))))
          (delete-process bridge)
          (kill-buffer (process-buffer bridge))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer (process-get bridge 'stderr)))
          (delete-directory cwd t))))))

;;;; Live integration (real `claude' + real MCP handshake)
;;
;; Gated behind CLAUDE_CODE_INTEGRATION (run via `make integration'); strips the
;; Claude nesting env vars so the spawned CLI starts a real top-level session.

(defun claude-code-mcp-tests--worktrees (root)
  "Return an alist of (PATH . BRANCH) for every worktree registered in ROOT.
BRANCH is the short branch name, or nil for a detached worktree.  Parses the
output of `git worktree list --porcelain' run in ROOT."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory root)))
      (when (zerop (call-process "git" nil t nil
                                 "worktree" "list" "--porcelain"))
        (goto-char (point-min))
        (let (result path branch)
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (cond
               ((string-prefix-p "worktree " line)
                (setq path (substring line 9) branch nil))
               ((string-prefix-p "branch refs/heads/" line)
                (setq branch (substring line 18)))
               ((and (string= line "") path)
                (push (cons path branch) result)
                (setq path nil branch nil))))
            (forward-line 1))
          (when path (push (cons path branch) result))
          (nreverse result))))))

(defun claude-code-mcp-tests--remove-new-worktrees (root before)
  "Remove ROOT worktrees under .claude/worktrees that are absent from BEFORE.
BEFORE is the list of worktree paths captured before the test spawned.  Each
newly-appeared worktree is force-removed -- twice-forced so a locked worktree
goes in one call -- and its actual branch (read back from git, never guessed)
is deleted.  Every worktree already in BEFORE is left untouched, so a
developer's real worktrees are never disturbed.  Best-effort: git errors are
ignored so a partially-created worktree is still cleaned up."
  (let ((default-directory (file-name-as-directory root)))
    (dolist (wt (claude-code-mcp-tests--worktrees root))
      (when (and (string-match-p "/\\.claude/worktrees/" (car wt))
                 (not (member (car wt) before)))
        (ignore-errors
          (call-process "git" nil nil nil
                        "worktree" "remove" "--force" "--force" (car wt)))
        (when (cdr wt)
          (ignore-errors
            (call-process "git" nil nil nil "branch" "-D" (cdr wt))))))))

(ert-deftest claude-code-test-integration-instance-life ()
  "A real instance's whole life: launch, MCP, name, rename, kill and delete.
Spawned named, in a new worktree, it reports the PID Ghostel runs it under,
reaches this Emacs's MCP server under that PID, and works in its worktree.  A
long rename lands even when Claude reads the command and its RET in one go:
stopping the instance across the send stands for a Claude too busy to read
between the two.  Killed and deleted, it leaves no process and no transcript.
The instance is handed only the entry `claude-code-mcp-install' registers, so
the test reads no user configuration and leaves none behind."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         (name "emacs integration name")
         (long-name (concat "emacs integration " (make-string 60 ?x)))
         (initialized nil)
         (probe (lambda (request caller)
                  (when (equal (alist-get 'method
                                          (ignore-errors
                                            (claude-code-mcp-tests--decode
                                             request)))
                               "initialize")
                    (setq initialized caller))))
         (config (make-temp-file
                  "cc-mcp-config" nil ".json"
                  (json-serialize
                   (list (cons 'mcpServers
                               (list (cons (intern claude-code--mcp-server-name)
                                           (claude-code--mcp-server-config))))))))
         (wrapper (make-temp-file
                   "cc-claude" nil nil
                   (format "#!/bin/sh\nexec %s --strict-mcp-config --mcp-config %s \"$@\"\n"
                           (shell-quote-argument (executable-find claude-code-cli))
                           (shell-quote-argument config))))
         (claude-code-cli wrapper)
         ;; A server of this Emacs's own, which the launch points the instance at.
         (server-name (format "cc-mcp-integration-%d" (emacs-pid)))
         (server-process nil)
         ;; Snapshot existing worktrees so teardown removes only what this test
         ;; creates, never a developer's real worktrees.
         (worktrees-before (mapcar #'car (claude-code-mcp-tests--worktrees root)))
         buffer id pid cwd)
    (set-file-modes wrapper #o700)
    (advice-add 'claude-code-mcp-dispatch :before probe)
    (cl-flet ((session ()
                (claude-code-tests--find-session
                 (claude-code-project-sessions root) id)))
      (unwind-protect
          (claude-code-tests--with-top-level-env
            (server-start nil t)
            (pcase-setq `(,id . ,buffer)
                        (claude-code-spawn
                         root :name name :worktree t
                         :prompt "Respond with the single word: pong"))
            (should (string-match-p claude-code-tests--uuid-re id))
            ;; The launch wrapper reports the PID it `exec's the CLI under.
            (should (claude-code-tests--await
                     (lambda () (setq pid (claude-code--instance-pid buffer)))
                     10))
            (should (eql pid (buffer-local-value 'ghostel--pid buffer)))
            ;; The CLI's MCP handshake reaches this Emacs through the bridge,
            ;; which names the instance by its PID.
            (should (claude-code-tests--await (lambda () initialized) 45))
            (should (eql initialized pid))
            ;; The instance runs in the config dir this Emacs reads.
            (when-let* ((environ (claude-code-tests--proc-strings pid "environ")))
              (should (equal (seq-find (lambda (entry)
                                         (string-prefix-p "CLAUDE_CONFIG_DIR="
                                                          entry))
                                       environ)
                             (when-let* ((env (claude-code--config-env)))
                               (concat "CLAUDE_CONFIG_DIR=" env)))))
            ;; Listed under the root, alive and named as spawned, once Claude
            ;; has written the transcript and finished the turn.
            (should (claude-code-tests--await
                     (lambda ()
                       (when-let* ((s (session)))
                         (and (claude-code-session-alive-p s)
                              (equal (claude-code-session-title s) name)
                              (equal (claude-code-session-status s) "idle"))))
                     60))
            ;; An eval from it runs in the worktree it works in.
            (setq cwd (claude-code--pid-cwd pid))
            (should (string-match-p "/\\.claude/worktrees/" cwd))
            (pcase-let ((`(,error-p . ,text)
                         (claude-code-mcp-tests--answer
                          (claude-code-mcp-tests--call-tool
                           pid "eval" (cons 'code "default-directory")))))
              (should-not error-p)
              (should (equal (read text) (file-name-as-directory cwd))))
            (signal-process pid 'SIGSTOP)
            (unwind-protect (claude-code-rename (session) long-name)
              (signal-process pid 'SIGCONT))
            (should (claude-code-tests--await
                     (lambda ()
                       (equal (claude-code-session-title (session)) long-name))
                     30))
            (claude-code-kill (session))
            (let ((s (session)))
              (should-not (and s (claude-code-session-alive-p s))))
            (should (claude-code-tests--await
                     (lambda () (not (process-attributes pid))) 15))
            (let ((s (session)))
              (should (file-exists-p (claude-code-session-transcript s)))
              (claude-code-delete s)
              (should-not (file-exists-p (claude-code-session-transcript s)))))
        (advice-remove 'claude-code-mcp-dispatch probe)
        ;; Where the transcript went, read while the instance still runs.
        (unless cwd
          (setq cwd (and pid (ignore-errors (claude-code--pid-cwd pid)))))
        (when (buffer-live-p buffer)
          (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
        (when (and pid (process-attributes pid))
          (ignore-errors (signal-process pid 'SIGCONT))
          (ignore-errors (signal-process pid 'SIGKILL))
          ;; Let the process and its git children die before touching its
          ;; worktree.
          (claude-code-tests--await (lambda () (not (process-attributes pid))) 5))
        (ignore-errors (server-start t t))
        (delete-file config)
        (delete-file wrapper)
        (when (and id cwd)
          (let* ((dir (claude-code-tests--project-dir cwd))
                 (file (expand-file-name (concat id ".jsonl") dir))
                 ;; Where a `/rename' also leaves the name.
                 (own (expand-file-name id dir)))
            (when (file-exists-p file) (delete-file file))
            (when (file-directory-p own) (delete-directory own t))
            ;; The worktree's own transcript directory, once nothing is left in it.
            (ignore-errors (delete-directory dir))))
        ;; Spawning with `:worktree t' leaves a locked git worktree behind that the
        ;; CLI never tears down.  Remove only worktrees that appeared during this
        ;; test; every pre-existing real worktree stays untouched.  A nil snapshot
        ;; means the pre-spawn listing failed -- a live repo always lists its main
        ;; worktree -- so skip cleanup rather than mistake every worktree for new.
        (when worktrees-before
          (claude-code-mcp-tests--remove-new-worktrees root worktrees-before))))))

(provide 'claude-code-mcp-tests)
;;; claude-code-mcp-tests.el ends here
