;;; claude-code-mcp-tests.el --- Tests for claude-code-mcp -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT suite for claude-code-mcp.el: the pure protocol layer, the tool
;; registry and `eval' tool, the config/CLI-arg builder, the server lifecycle,
;; and an in-Emacs socket end-to-end test driving the real loopback server.
;; A live handshake test is gated behind CLAUDE_CODE_INTEGRATION.  Run with
;; `make test' (unit) or `make integration' (live).

;;; Code:

(require 'ert)
(require 'seq)
(require 'cl-lib)
(require 'claude-code)
(require 'claude-code-mcp)
;; For the scaffolding the sibling suite owns: `claude-code-tests--with-registry',
;; which every isolated test here expands into, and the integration helpers
;; `claude-code-tests--with-top-level-env' and `claude-code-tests--await'.
(require 'claude-code-tests)

(defmacro claude-code-mcp-tests--isolated (&rest body)
  "Run BODY with session lookups isolated from the real config dir.
Points `claude-code-config-dir' at a nonexistent path (so the live status
table is empty) and rebinds `claude-code--managed' to a fresh table, so
`claude-code--session-cwd' resolves to nil for any test session id."
  (declare (indent 0))
  `(let ((claude-code-config-dir "/claude-code-mcp-tests-nonexistent"))
     (claude-code-tests--with-registry ,@body)))

(defmacro claude-code-mcp-tests--with-server (port &rest body)
  "Start an isolated MCP server, bind PORT to its port, and run BODY.
The server is stopped afterwards, and PORT is asserted to be a real one so
every caller starts from a listening server."
  (declare (indent 1))
  `(claude-code-mcp-tests--isolated
     (let ((claude-code-mcp-enabled t)
           (claude-code--mcp-server nil))
       (unwind-protect
           (let ((,port (claude-code--mcp-ensure-server)))
             (should (integerp ,port))
             ,@body)
         (claude-code-mcp-stop)))))

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

(defun claude-code-mcp-tests--tools ()
  "Return the tool descriptors `tools/list' advertises."
  (alist-get 'tools
             (alist-get 'result
                        (claude-code--mcp-handle-request
                         "sess"
                         (claude-code-mcp-tests--request "tools/list" 1)))))

(defun claude-code-mcp-tests--tool (name)
  "Return the `tools/list' descriptor advertised for the tool called NAME."
  (seq-find (lambda (tool) (equal (alist-get 'name tool) name))
            (claude-code-mcp-tests--tools)))

(defun claude-code-mcp-tests--tool-schema (name)
  "Return the `inputSchema' advertised for the tool called NAME."
  (alist-get 'inputSchema (claude-code-mcp-tests--tool name)))

(defun claude-code-mcp-tests--call-tool (session-id name &rest arguments)
  "Dispatch a `tools/call' of the tool NAME for SESSION-ID; return the response.
ARGUMENTS are the (NAME . VALUE) pairs of the call's `arguments' object.  The
caller owns the session state the call runs against, so a test that needs one
isolated wraps this in `claude-code-mcp-tests--isolated' itself."
  (claude-code--mcp-handle-request
   session-id
   (claude-code-mcp-tests--request
    "tools/call" 7 (list (cons 'name name) (cons 'arguments arguments)))))

(defun claude-code-mcp-tests--call-eval (code)
  "Dispatch a `tools/call' of the `eval' tool for CODE and return the response."
  (claude-code-mcp-tests--isolated
    (claude-code--mcp-handle-request
     "sess"
     (claude-code-mcp-tests--request
      "tools/call" 9
      (list (cons 'name "eval")
            (cons 'arguments (list (cons 'code code))))))))

;;;; Pure dispatch: initialize / notifications / errors

(ert-deftest claude-code-mcp-test-initialize ()
  "`initialize' reports the server's own protocol version and capabilities."
  ;; Ignores the client's request for a specific version.
  (let* ((resp (claude-code--mcp-handle-request
                "sess"
                (claude-code-mcp-tests--request
                 "initialize" 1 (list (cons 'protocolVersion "2024-11-05")))))
         (result (alist-get 'result resp)))
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 1))
    (should (equal (alist-get 'protocolVersion result) "2025-06-18"))
    (should (equal (alist-get 'name (alist-get 'serverInfo result))
                   "claude-code.el"))
    ;; `listChanged' is JSON false, not nil (wire-shape check).
    (should (eq (alist-get 'listChanged
                           (alist-get 'tools (alist-get 'capabilities result)))
                :json-false)))
  ;; A request carrying no version gets the same server version.
  (let ((result (alist-get 'result
                           (claude-code--mcp-handle-request
                            "sess"
                            (claude-code-mcp-tests--request "initialize" 2)))))
    (should (equal (alist-get 'protocolVersion result) "2025-06-18"))))

(ert-deftest claude-code-mcp-test-notification-returns-nil ()
  "A request without an `id' is a notification and yields nil (no response)."
  (should (null (claude-code--mcp-handle-request
                 "sess"
                 (claude-code-mcp-tests--request "notifications/initialized")))))

(ert-deftest claude-code-mcp-test-error-codes-echo-id ()
  "Protocol errors carry the right code and echo the request id."
  ;; Unknown method -> -32601.
  (let ((resp (claude-code--mcp-handle-request
               "sess" (claude-code-mcp-tests--request "no/such/method" 7))))
    (should (equal (alist-get 'id resp) 7))
    (should (= (alist-get 'code (alist-get 'error resp)) -32601)))
  ;; Unknown tool -> -32602.
  (let ((resp (claude-code-mcp-tests--isolated
                (claude-code--mcp-handle-request
                 "sess"
                 (claude-code-mcp-tests--request
                  "tools/call" 8 (list (cons 'name "nope")
                                       (cons 'arguments nil)))))))
    (should (equal (alist-get 'id resp) 8))
    (should (= (alist-get 'code (alist-get 'error resp)) -32602)))
  ;; Missing required argument -> -32602.
  (let ((resp (claude-code-mcp-tests--isolated
                (claude-code--mcp-handle-request
                 "sess"
                 (claude-code-mcp-tests--request
                  "tools/call" 10 (list (cons 'name "eval")
                                        (cons 'arguments nil)))))))
    (should (equal (alist-get 'id resp) 10))
    (should (= (alist-get 'code (alist-get 'error resp)) -32602))))

(ert-deftest claude-code-mcp-test-invalid-request-shape ()
  "A non-object request (array or bare scalar) yields -32600 with a null id."
  (dolist (bad (list [1 2] 5 "x" :null))
    (let ((resp (claude-code--mcp-handle-request "sess" bad)))
      (should (eq (alist-get 'id resp) :null))
      (should (= (alist-get 'code (alist-get 'error resp)) -32600)))))

;;;; Pure body handling: integrity guard and JSON parsing

(ert-deftest claude-code-mcp-test-body-dispatch ()
  "A well-formed body dispatches; a notification body yields nil."
  ;; A parseable request with a matching declared length reaches dispatch.
  (let* ((body (claude-code--mcp-serialize
                (claude-code-mcp-tests--request "tools/list" 1)))
         (resp (claude-code--mcp-response-for-body
                "sess" body (number-to-string (string-bytes body)))))
    (should (equal (alist-get 'id resp) 1))
    (should (alist-get 'tools (alist-get 'result resp))))
  ;; With no Content-Length header the integrity guard is skipped.
  (let ((resp (claude-code--mcp-response-for-body
               "sess"
               (claude-code--mcp-serialize
                (claude-code-mcp-tests--request "tools/list" 2))
               nil)))
    (should (equal (alist-get 'id resp) 2)))
  ;; A notification body maps to nil (the transport then sends the empty 202).
  (should (null (claude-code--mcp-response-for-body
                 "sess"
                 (claude-code--mcp-serialize
                  (claude-code-mcp-tests--request "notifications/initialized"))
                 nil))))

(ert-deftest claude-code-mcp-test-parse-error ()
  "A malformed JSON body is answered with a -32700 error and a null id."
  (let ((resp (claude-code--mcp-response-for-body "sess" "{not json" nil)))
    (should (eq (alist-get 'id resp) :null))
    (should (= (alist-get 'code (alist-get 'error resp)) -32700))))

(ert-deftest claude-code-mcp-test-truncated-body ()
  "A Content-Length disagreeing with the body's byte count yields -32700."
  (let* ((body "{\"jsonrpc\":\"2.0\"}")
         (resp (claude-code--mcp-response-for-body
                "sess" body (number-to-string (+ (string-bytes body) 10)))))
    (should (eq (alist-get 'id resp) :null))
    (should (= (alist-get 'code (alist-get 'error resp)) -32700)))
  ;; The guard counts bytes, not characters.  This body is multibyte (é is one
  ;; char, two bytes): its byte count is accepted, its char count is not.
  (let ((body "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"é\"}"))
    (should (equal (alist-get 'id (claude-code--mcp-response-for-body
                                   "sess" body
                                   (number-to-string (string-bytes body))))
                   4))
    (should (eq (alist-get 'id (claude-code--mcp-response-for-body
                                "sess" body
                                (number-to-string (length body))))
                :null))))

;;;; Pure dispatch: tools/list and the catalog

(ert-deftest claude-code-mcp-test-tools-list ()
  "`tools/list' advertises the catalog with vector-shaped arrays."
  ;; The tools array is a JSON array (vector), not a list.
  (should (vectorp (claude-code-mcp-tests--tools)))
  (should (claude-code-mcp-tests--tool "eval"))
  (let ((schema (claude-code-mcp-tests--tool-schema "eval")))
    (should (equal (alist-get 'type schema) "object"))
    ;; `required' is the vector ["code"].
    (should (equal (alist-get 'required schema) (vector "code")))
    ;; `properties' carries the typed `code' argument.
    (should (equal (alist-get 'type (alist-get 'code
                                               (alist-get 'properties schema)))
                   "string"))))

(ert-deftest claude-code-mcp-test-spawn-schema ()
  "`spawn' advertises every option as optional, with the effort levels enumerated."
  (let* ((schema (claude-code-mcp-tests--tool-schema "spawn"))
         (properties (alist-get 'properties schema)))
    (should (equal (alist-get 'required schema) []))
    (should (equal (alist-get 'type (alist-get 'worktree properties)) "boolean"))
    (should (equal (alist-get 'type (alist-get 'worktree_name properties))
                   "string"))
    (should (string-match-p
             "\"enum\":\\[\"low\",\"medium\",\"high\",\"xhigh\",\"max\"\\]"
             (claude-code--mcp-serialize (alist-get 'effort properties))))
    ;; The model is free-form: the CLI takes aliases and full names alike.
    (should-not (assq 'enum (alist-get 'model properties)))))

(ert-deftest claude-code-mcp-test-tool-schema-shapes ()
  "A no-arg tool advertises `properties':{}, and an optional arg is omittable."
  (claude-code-mcp-tests--with-tools '("cc-mcp-test-noargs" "cc-mcp-test-opt")
    (claude-code-mcp-make-tool
     :name "cc-mcp-test-noargs" :description "No args." :handler #'ignore)
    (claude-code-mcp-make-tool
     :name "cc-mcp-test-opt" :description "One optional arg."
     :args (list (list :name "flag" :type 'string
                       :description "Optional." :optional t))
     :handler (lambda (&optional flag) (format "%s" flag)))
    ;; A no-arg tool serializes `properties' to an empty JSON object.
    (should (equal (json-serialize
                    (alist-get 'properties
                               (claude-code-mcp-tests--tool-schema
                                "cc-mcp-test-noargs")))
                   "{}"))
    ;; An optional arg is excluded from `required'.
    (should (equal (alist-get 'required (claude-code-mcp-tests--tool-schema
                                         "cc-mcp-test-opt"))
                   []))
    ;; Omitting the optional argument runs the tool -- no -32602.
    (let ((result (alist-get 'result
                             (claude-code-mcp-tests--isolated
                               (claude-code--mcp-handle-request
                                "sess"
                                (claude-code-mcp-tests--request
                                 "tools/call" 2
                                 (list (cons 'name "cc-mcp-test-opt")
                                       (cons 'arguments nil))))))))
      (should (eq (alist-get 'isError result) :json-false)))))

(ert-deftest claude-code-mcp-test-args-hold-to-the-schema ()
  "A value contradicting the advertised schema is a -32602; the handler is not run.
The schema is what a caller builds its call from, so a wrong type or a value
outside an `:enum' is a protocol error rather than something to pass on.  An
empty string is a value for a required argument and an omission for an optional
one -- a handler forwarding it to a process would otherwise emit an option with
nothing after it."
  (let ((seen 'unset))
    (claude-code-mcp-tests--isolated
      (claude-code-mcp-tests--with-tools '("cc-mcp-test-schema")
        (claude-code-mcp-make-tool
         :name "cc-mcp-test-schema" :description "Typed arguments."
         :args (list (list :name "text" :type 'string :description "Required.")
                     (list :name "level" :type 'string :optional t
                           :enum '("low" "high") :description "From a set.")
                     (list :name "flag" :type 'boolean :optional t
                           :description "A flag."))
         :handler (lambda (text &optional level flag)
                    (setq seen (list text level flag))
                    "ok"))
        ;; The advertised schema carries the enum as a JSON array of its values.
        (should (string-match-p
                 "\"enum\":\\[\"low\",\"high\"\\]"
                 (claude-code--mcp-serialize
                  (alist-get 'level
                             (alist-get 'properties
                                        (claude-code-mcp-tests--tool-schema
                                         "cc-mcp-test-schema"))))))
        (pcase-dolist (`(,arguments . ,message)
                       '((((text . 42)) . "type")
                         (((text . "t") (flag . "yes")) . "type")
                         (((text . "t") (level . "turbo")) . "one of")
                         ;; A required argument sent as JSON null is as absent
                         ;; as one never sent: null is not a string.
                         (((text . :null)) . "Missing required")
                         (nil . "Missing required")))
          (setq seen 'unset)
          (let ((error-object
                 (alist-get 'error (apply #'claude-code-mcp-tests--call-tool
                                          "sess" "cc-mcp-test-schema" arguments))))
            (should (equal (alist-get 'code error-object) -32602))
            (should (string-match-p message (alist-get 'message error-object)))
            (should (eq seen 'unset))))
        ;; Both empty strings reach the handler as what they mean there.
        (claude-code-mcp-tests--call-tool "sess" "cc-mcp-test-schema"
                                          '(text . "") '(level . ""))
        (should (equal seen '("" nil nil)))))))

(ert-deftest claude-code-mcp-test-a-required-boolean-can-be-false ()
  "`false' answers a required boolean; leaving it out is what is missing.
A boolean reaches its handler as nil either way, so the call is the only thing
that says which happened -- and a tool asking to be told before it acts must be
able to hear no."
  (let ((seen 'unset))
    (claude-code-mcp-tests--isolated
      (claude-code-mcp-tests--with-tools '("cc-mcp-test-confirm")
        (claude-code-mcp-make-tool
         :name "cc-mcp-test-confirm" :description "One required boolean."
         :args (list (list :name "confirm" :type 'boolean
                           :description "Required."))
         :handler (lambda (confirm) (setq seen confirm) "ok"))
        (dolist (false '(:json-false :false))
          (setq seen 'unset)
          (let ((result (alist-get 'result
                                   (claude-code-mcp-tests--call-tool
                                    "sess" "cc-mcp-test-confirm"
                                    (cons 'confirm false)))))
            (should (eq (alist-get 'isError result) :json-false))
            (should (null seen))))
        ;; Omitted, it is missing; the handler never runs.
        (setq seen 'unset)
        (should (string-match-p
                 "Missing required"
                 (alist-get 'message
                            (alist-get 'error (claude-code-mcp-tests--call-tool
                                               "sess" "cc-mcp-test-confirm")))))
        (should (eq seen 'unset))))))

(ert-deftest claude-code-mcp-test-session-cwd-is-bound-for-the-call ()
  "A tool sees its caller's cwd for the call, and nil for an id naming nothing.
The nil is what a tool acting on the caller's project has to check, and it
must not outlive the call: the next one may come from another session."
  (let ((seen 'unset))
    (claude-code-mcp-tests--with-tools '("cc-mcp-test-cwd")
      (claude-code-mcp-make-tool
       :name "cc-mcp-test-cwd" :description "Report the caller's cwd."
       :handler (lambda () (setq seen claude-code--mcp-session-cwd) "ok"))
      (claude-code-mcp-tests--isolated
        (puthash "sess" (list :buffer nil :origin "/home/test/proj")
                 claude-code--managed)
        (pcase-dolist (`(,session-id . ,cwd) '(("sess" . "/home/test/proj")
                                               ("no-such-session" . nil)))
          (setq seen 'unset)
          (claude-code-mcp-tests--call-tool session-id "cc-mcp-test-cwd")
          (should (equal seen cwd)))))
    (should (null claude-code--mcp-session-cwd))))

;;;; Pure dispatch: tools/call eval happy and error paths

(ert-deftest claude-code-mcp-test-eval-happy ()
  "`eval' returns the last value's printed form and `isError' JSON false."
  (let* ((resp (claude-code-mcp-tests--call-eval "(+ 40 2)"))
         (result (alist-get 'result resp))
         (content (alist-get 'content result)))
    (should (vectorp content))
    (should (equal (alist-get 'type (aref content 0)) "text"))
    (should (equal (alist-get 'text (aref content 0)) "42"))
    ;; Success is JSON false, not nil (wire-shape check).
    (should (eq (alist-get 'isError result) :json-false)))
  ;; Empty code is nil, not a read error.
  (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval ""))))
    (should (equal (alist-get 'text (aref (alist-get 'content result) 0)) "nil"))
    (should (eq (alist-get 'isError result) :json-false))))

(defvar claude-code-mcp-tests--x nil
  "Scratch special variable for `claude-code-mcp-test-eval-multi-form'.")

(ert-deftest claude-code-mcp-test-eval-multi-form ()
  "`eval' runs every top-level form and returns the last value."
  (let* ((claude-code-mcp-tests--x nil)
         (result (alist-get 'result
                            (claude-code-mcp-tests--call-eval
                             "(setq claude-code-mcp-tests--x 5)
                              (* claude-code-mcp-tests--x claude-code-mcp-tests--x)"))))
    (should (equal (alist-get 'text (aref (alist-get 'content result) 0)) "25"))
    (should (eq (alist-get 'isError result) :json-false))))

(ert-deftest claude-code-mcp-test-eval-errors ()
  "Evaluation and read errors become an `isError' result, never a crash."
  ;; A runtime error (division by zero) is caught and reported.
  (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval "(/ 1 0)"))))
    (should (eq (alist-get 'isError result) t))
    (should (string-match-p "Error:"
                            (alist-get 'text (aref (alist-get 'content result) 0)))))
  ;; A malformed form (unbalanced paren) is caught and reported.
  (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval "(+ 1"))))
    (should (eq (alist-get 'isError result) t)))
  ;; An incomplete form after a valid one errors, not a silent partial success.
  (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval "(+ 1 2) (+ 3"))))
    (should (eq (alist-get 'isError result) t))))

(ert-deftest claude-code-mcp-test-eval-semicolons-in-code ()
  "A `;' is code in a character literal or string, and a comment elsewhere."
  (dolist (case '(("?;" . "59")
                  ("(list ?; 5)" . "(59 5)")
                  ("\"a;b\"" . "\"a;b\"")
                  ;; A leading comment, and a comment between two forms.
                  (";; lead\n(+ 1 2) ; mid\n(* 2 3)" . "6")
                  ;; A comment after the last form, skipped before the loop ends.
                  ("(+ 40 2) ; the answer" . "42")
                  ;; A comment holding an unbalanced delimiter is skipped by
                  ;; syntax, so it never reaches the reader.
                  ("(+ 1 2) ; )" . "3")
                  ;; Nothing but comments evaluates to nil, not a read error.
                  (";; just a comment" . "nil")))
    (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval (car case)))))
      (should (eq (alist-get 'isError result) :json-false))
      (should (equal (alist-get 'text (aref (alist-get 'content result) 0))
                     (cdr case))))))

;;;; Pure dispatch: tools/call spawn

(defmacro claude-code-mcp-tests--with-caller (cwd execs &rest body)
  "Run BODY with session \"sess\" managed from CWD and the launch path stubbed.
EXECS collects the (BUFFER ARGS) of every launch, so a test asserts what
reached the CLI without a `claude' ever running."
  (declare (indent 2))
  `(claude-code-mcp-tests--isolated
     (puthash "sess" (list :buffer nil :origin ,cwd) claude-code--managed)
     (claude-code-tests--recording-launch ,execs ,@body)))

(defun claude-code-mcp-tests--result-text (response)
  "Return the text payload of RESPONSE's tool result."
  (alist-get 'text (aref (alist-get 'content (alist-get 'result response)) 0)))

(ert-deftest claude-code-mcp-test-spawn-in-the-callers-directory ()
  "`spawn' launches in the calling session's own directory and returns the id.
The directory is the server's to resolve -- the tool takes no path argument --
and the id is what the caller has to find the session by afterwards."
  (let ((execs '()))
    (claude-code-mcp-tests--with-caller "/home/test/proj" execs
      (let* ((response (claude-code-mcp-tests--call-tool "sess" "spawn"))
             (id (claude-code-mcp-tests--result-text response)))
        (should (eq (alist-get 'isError (alist-get 'result response))
                    :json-false))
        (should (string-match-p claude-code-tests--uuid-re id))
        (should (= (length execs) 1))
        ;; The instance was registered under that id, launched from the
        ;; caller's root, and carries the session id on its command line.
        (should (equal (plist-get (gethash id claude-code--managed) :origin)
                       (claude-code--normalize-root "/home/test/proj")))
        (should (equal (nth 1 (car execs))
                       (list "--session-id" id "--mcp-config" "{}")))))))

(ert-deftest claude-code-mcp-test-spawn-options ()
  "Every option reaches the CLI; a worktree name stands in for the flag."
  (let ((execs '()))
    (claude-code-mcp-tests--with-caller "/home/test/proj" execs
      (let ((id (claude-code-mcp-tests--result-text
                 (claude-code-mcp-tests--call-tool
                  "sess" "spawn" '(prompt . "do the thing") '(model . "opus")
                  '(effort . "xhigh") '(worktree . t)
                  '(worktree_name . "feat")))))
        (should (equal (nth 1 (car execs))
                       (list "--session-id" id "-w" "feat"
                             "--model" "opus" "--effort" "xhigh"
                             "--mcp-config" "{}" "--" "do the thing"))))
      ;; The flag alone asks for an auto-named worktree.
      (claude-code-mcp-tests--call-tool "sess" "spawn" '(worktree . t))
      (should (member "-w" (nth 1 (car execs))))
      (should-not (member "feat" (nth 1 (car execs))))
      ;; A name alone asks for that worktree, as its description promises.
      (claude-code-mcp-tests--call-tool "sess" "spawn" '(worktree_name . "solo"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "-w" "solo" "--mcp-config" "{}")))
      ;; JSON false is normalized to nil, so no worktree is requested.
      (claude-code-mcp-tests--call-tool "sess" "spawn" '(worktree . :json-false))
      (should-not (member "-w" (nth 1 (car execs))))
      ;; A name given alongside a false flag still asks for the worktree: a
      ;; name is a request for one, and the flag carries nothing to weigh it
      ;; against -- false and omitted reach the handler alike.
      (claude-code-mcp-tests--call-tool "sess" "spawn" '(worktree . :json-false)
                                        '(worktree_name . "named"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "-w" "named" "--mcp-config" "{}")))
      ;; An empty string is an omitted option, not an empty value: `--model ""'
      ;; would reach the CLI and kill the instance at startup.
      (claude-code-mcp-tests--call-tool
       "sess" "spawn" '(prompt . "") '(model . "") '(effort . "")
       '(worktree . t) '(worktree_name . ""))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "-w" "--mcp-config" "{}")))
      ;; An option off the advertised schema is refused before anything runs.
      (let ((launched (length execs)))
        (should (= (alist-get 'code
                              (alist-get 'error
                                         (claude-code-mcp-tests--call-tool
                                          "sess" "spawn" '(effort . "turbo"))))
                   -32602))
        (should (= (length execs) launched))))))

(ert-deftest claude-code-mcp-test-spawn-refuses-an-unknown-caller ()
  "A call from a session with no known directory launches nothing.
Falling back to whatever `default-directory' the server happens to hold would
start an instance in an unrelated project."
  (let ((execs '()))
    (claude-code-mcp-tests--with-caller "/home/test/proj" execs
      (let ((response (claude-code-mcp-tests--call-tool "no-such-session"
                                                        "spawn")))
        (should (eq (alist-get 'isError (alist-get 'result response)) t))
        (should (string-match-p "No working directory"
                                (claude-code-mcp-tests--result-text response)))
        (should (null execs))))))

;;;; Wire serialization (arrays are vectors, false is JSON false)

(ert-deftest claude-code-mcp-test-serialize-shapes ()
  "The serialized `eval' result uses a JSON array and JSON false."
  (let ((json (claude-code--mcp-serialize
               (claude-code-mcp-tests--call-eval "(+ 40 2)"))))
    (should (string-match-p "\"content\":\\[" json))
    (should (string-match-p "\"isError\":false" json))
    (should (string-match-p "\"text\":\"42\"" json)))
  ;; A parse-error envelope serializes a null id, not `{}'.
  (should (string-match-p "\"id\":null"
                          (claude-code--mcp-serialize
                           (claude-code--mcp-error :null -32700 "Parse error")))))

;;;; Tool registry

(ert-deftest claude-code-mcp-test-make-tool ()
  "`claude-code-mcp-make-tool' registers a tool and validates required slots."
  (claude-code-mcp-tests--with-tools '("cc-mcp-test-echo")
    (let ((tool (claude-code-mcp-make-tool
                 :name "cc-mcp-test-echo"
                 :description "Echo its argument."
                 :args (list (list :name "text" :type 'string
                                   :description "Text to echo."))
                 :handler #'identity)))
      (should (equal (plist-get tool :description) "Echo its argument."))
      (should (gethash "cc-mcp-test-echo" claude-code--mcp-tools))
      ;; It shows up in the advertised catalog.
      (should (claude-code-mcp-tests--tool "cc-mcp-test-echo"))))
  ;; A missing :handler is an error.
  (should-error (claude-code-mcp-make-tool
                 :name "bad" :description "No handler.")))

(ert-deftest claude-code-mcp-test-boolean-args ()
  "A `boolean' argument reaches its handler as a Lisp truth value.
The parser renders JSON false as `:json-false'/`:false' and null as `:null',
all non-nil in Lisp, so each must arrive as nil."
  (let ((seen 'unset))
    (claude-code-mcp-tests--with-tools '("cc-mcp-test-bool")
      (claude-code-mcp-make-tool
       :name "cc-mcp-test-bool" :description "One optional boolean."
       :args (list (list :name "flag" :type 'boolean
                         :description "A flag." :optional t))
       :handler (lambda (&optional flag) (setq seen flag) "ok"))
      ;; The advertised schema type is the JSON name of the `:type' symbol.
      (should (equal (alist-get 'type
                                (alist-get 'flag
                                           (alist-get 'properties
                                                      (claude-code-mcp-tests--tool-schema
                                                       "cc-mcp-test-bool"))))
                     "boolean"))
      (dolist (case '((:json-false . nil) (:false . nil) (:null . nil) (t . t)))
        (setq seen 'unset)
        (claude-code-mcp-tests--isolated
          (claude-code--mcp-handle-request
           "sess"
           (claude-code-mcp-tests--request
            "tools/call" 2
            (list (cons 'name "cc-mcp-test-bool")
                  (cons 'arguments (list (cons 'flag (car case))))))))
        (should (eq seen (cdr case)))))))

;;;; CLI arg / config builder

(ert-deftest claude-code-mcp-test-cli-args ()
  "The CLI-arg builder emits `--mcp-config' and, when enabled, `--allowedTools'."
  (cl-letf (((symbol-function 'claude-code--mcp-ensure-server) (lambda () 7777)))
    ;; With auto-approve, both flags are present and the config points at the id.
    (let* ((claude-code-mcp-auto-approve t)
           (args (claude-code--mcp-cli-args "the-id"))
           (allowed (split-string (cadr (member "--allowedTools" args)) ",")))
      (should (equal (nth 0 args) "--mcp-config"))
      (should (member "--allowedTools" args))
      ;; The allow-list is the comma-joined identifier of every registered tool.
      (should (member "mcp__emacs__eval" allowed))
      (let ((config (json-parse-string (nth 1 args) :object-type 'alist)))
        (should (equal (alist-get 'url
                                  (alist-get 'emacs
                                             (alist-get 'mcpServers config)))
                       "http://127.0.0.1:7777/mcp/the-id"))
        (should (equal (alist-get 'type
                                  (alist-get 'emacs
                                             (alist-get 'mcpServers config)))
                       "http"))))
    ;; Every registered tool lands in the allow-list, not just a fixed set.
    (claude-code-mcp-tests--with-tools '("cc-mcp-test-noop")
      (claude-code-mcp-make-tool
       :name "cc-mcp-test-noop" :description "No-op." :handler #'ignore)
      (let* ((claude-code-mcp-auto-approve t)
             (allowed (split-string
                       (cadr (member "--allowedTools"
                                     (claude-code--mcp-cli-args "the-id")))
                       ",")))
        (should (member "mcp__emacs__eval" allowed))
        (should (member "mcp__emacs__cc-mcp-test-noop" allowed))))
    ;; Without auto-approve, only `--mcp-config' is emitted.
    (let* ((claude-code-mcp-auto-approve nil)
           (args (claude-code--mcp-cli-args "the-id")))
      (should (equal (nth 0 args) "--mcp-config"))
      (should-not (member "--allowedTools" args))))
  ;; When the server is unavailable (disabled), the builder returns nil.
  (cl-letf (((symbol-function 'claude-code--mcp-ensure-server) (lambda () nil)))
    (should (null (claude-code--mcp-cli-args "the-id")))))

(ert-deftest claude-code-mcp-test-ensure-server-disabled ()
  "`claude-code--mcp-ensure-server' returns nil and starts nothing when off."
  (let ((claude-code-mcp-enabled nil)
        (claude-code--mcp-server nil))
    (should (null (claude-code--mcp-ensure-server)))
    (should (null claude-code--mcp-server))))

;;;; Lifecycle: idempotent start, clean stop

(ert-deftest claude-code-mcp-test-stop-is-a-noop-when-stopped ()
  "`claude-code-mcp-stop' is a clean no-op when no server is live."
  (let ((claude-code--mcp-server nil))
    ;; Must not error and must leave state nil.
    (claude-code-mcp-stop)
    (should (null claude-code--mcp-server))
    (should (null (claude-code--mcp-port)))))

(ert-deftest claude-code-mcp-test-stops-with-the-last-instance ()
  "The shared server is torn down by the last instance to exit, not the first."
  (claude-code-tests--with-managed-buffer buf
    (claude-code-tests--with-managed-buffer other
      (claude-code-mcp-tests--with-server _port
        (puthash "a" (list :buffer buf) claude-code--managed)
        (puthash "b" (list :buffer other) claude-code--managed)
        ;; One of two exiting leaves the server up for the survivor.
        (claude-code--on-exit buf)
        (should (= (hash-table-count claude-code--managed) 1))
        (should claude-code--mcp-server)
        ;; The last one takes it down.
        (claude-code--on-exit other)
        (should (zerop (hash-table-count claude-code--managed)))
        (should-not claude-code--mcp-server)))))

(ert-deftest claude-code-mcp-test-ensure-server-idempotent ()
  "Ensuring twice yields one listener on the same port; stop tears it down."
  (let ((claude-code-mcp-enabled t)
        (claude-code--mcp-server nil))
    (unwind-protect
        (let ((port1 (claude-code--mcp-ensure-server))
              (server1 claude-code--mcp-server)
              (port2 (claude-code--mcp-ensure-server)))
          (should (integerp port1))
          ;; Same server object and port -- no second listener was opened.
          (should (eq server1 claude-code--mcp-server))
          (should (equal port1 port2)))
      (claude-code-mcp-stop))
    (should (null claude-code--mcp-server))
    (should (null (claude-code--mcp-port)))))

;;;; In-Emacs socket end-to-end (real loopback, no claude/ghostel)

(defun claude-code-mcp-tests--http-send (port request)
  "Send raw REQUEST bytes to loopback PORT and return the raw response string.
Detects end-of-response by the server closing the connection (it sends no
Content-Length), via the client process leaving the open/connect/run states."
  (let* ((response "")
         (closed nil)
         (proc (make-network-process
                :name "cc-mcp-test-client"
                :host "127.0.0.1" :service port
                :coding 'binary :nowait nil
                :filter (lambda (_p s) (setq response (concat response s)))
                :sentinel (lambda (p _e)
                            (unless (memq (process-status p)
                                          '(open connect run))
                              (setq closed t))))))
    (process-send-string proc request)
    (let ((deadline (+ (float-time) 5)))
      (while (and (not closed) (< (float-time) deadline))
        (accept-process-output proc 0.1)))
    (when (process-live-p proc) (delete-process proc))
    response))

(defun claude-code-mcp-tests--http-post (port path body &optional declared-length)
  "POST BODY to PATH on loopback PORT and return the raw HTTP response string.
DECLARED-LENGTH overrides the `Content-Length' header, to send a body shorter
than the one announced."
  (claude-code-mcp-tests--http-send
   port
   (format (concat "POST %s HTTP/1.1\r\n"
                   "Host: 127.0.0.1\r\n"
                   "Content-Type: application/json\r\n"
                   "Content-Length: %d\r\n"
                   "Connection: close\r\n"
                   "\r\n%s")
           path (or declared-length (string-bytes body)) body)))

(defun claude-code-mcp-tests--http-get (port path)
  "GET PATH on loopback PORT and return the raw HTTP response string.
Sends the `Accept: text/event-stream' header the real MCP client uses when it
tries to open a server-to-client SSE stream."
  (claude-code-mcp-tests--http-send
   port
   (format (concat "GET %s HTTP/1.1\r\n"
                   "Host: 127.0.0.1\r\n"
                   "Accept: text/event-stream\r\n"
                   "Connection: close\r\n"
                   "\r\n")
           path)))

(ert-deftest claude-code-mcp-test-get-returns-405 ()
  "A GET on the MCP endpoint returns HTTP 405 (no SSE stream offered)."
  (claude-code-mcp-tests--with-server port
    (should (string-match-p
             "\\`HTTP/1\\.[01] 405 "
             (claude-code-mcp-tests--http-get port "/mcp/sess")))))

(defun claude-code-mcp-tests--raw-body (raw)
  "Return the body of raw HTTP response RAW, past the header blank line."
  (when (string-match "\r\n\r\n" raw)
    (substring raw (match-end 0))))

(defun claude-code-mcp-tests--response-body (raw)
  "Parse the JSON body of raw HTTP response RAW to an alist.
Returns nil for a reply that carries no body (an empty 202)."
  (let ((body (claude-code-mcp-tests--raw-body raw)))
    (when (and body (not (string-empty-p body)))
      (json-parse-string body :object-type 'alist
                         :false-object :json-false :null-object :null))))

(defun claude-code-mcp-tests--rpc (port session-id request)
  "Send REQUEST alist to SESSION-ID on PORT; return the parsed response alist.
Returns nil for an empty (notification) reply that carries no body."
  (claude-code-mcp-tests--response-body
   (claude-code-mcp-tests--http-post
    port (format "/mcp/%s" session-id)
    (claude-code--mcp-serialize request))))

(ert-deftest claude-code-mcp-test-socket-e2e ()
  "Drive the real loopback server through initialize/list/call over a socket."
  (claude-code-mcp-tests--with-server port
    ;; initialize
    (let ((resp (claude-code-mcp-tests--rpc
                 port "sess"
                 (claude-code-mcp-tests--request
                  "initialize" 1
                  (list (cons 'protocolVersion "2025-06-18"))))))
      (should (equal (alist-get 'id resp) 1))
      (should (equal (alist-get 'protocolVersion (alist-get 'result resp))
                     "2025-06-18")))
    ;; notification -> the server MUST still reply, with an empty 202 and no
    ;; JSON body.  Assert the 202 status line on the wire, so this is not
    ;; satisfied by a silent no-reply (which also parses to nil).
    (let ((raw (claude-code-mcp-tests--http-post
                port "/mcp/sess"
                (claude-code--mcp-serialize
                 (claude-code-mcp-tests--request
                  "notifications/initialized")))))
      (should (string-match-p "\\`HTTP/1\\.[01] 202 " raw))
      (should (equal (claude-code-mcp-tests--raw-body raw) "")))
    ;; tools/list
    (let* ((resp (claude-code-mcp-tests--rpc
                  port "sess"
                  (claude-code-mcp-tests--request "tools/list" 2)))
           (tools (alist-get 'tools (alist-get 'result resp))))
      (should (vectorp tools))
      (should (seq-find (lambda (tl) (equal (alist-get 'name tl) "eval"))
                        tools)))
    ;; tools/call eval
    (let* ((resp (claude-code-mcp-tests--rpc
                  port "sess"
                  (claude-code-mcp-tests--request
                   "tools/call" 3
                   (list (cons 'name "eval")
                         (cons 'arguments (list (cons 'code "(+ 40 2)")))))))
           (result (alist-get 'result resp)))
      (should (equal (alist-get 'text (aref (alist-get 'content result) 0))
                     "42"))
      (should (eq (alist-get 'isError result) :json-false)))
    ;; A body declared longer than delivered reaches the handler truncated --
    ;; web-server frames by the blank line, not Content-Length -- and is
    ;; refused with -32700 on the wire.
    (let* ((body "{\"jsonrpc\":\"2.0\"}")
           (resp (claude-code-mcp-tests--response-body
                  (claude-code-mcp-tests--http-post
                   port "/mcp/sess" body (+ (string-bytes body) 10)))))
      (should (= (alist-get 'code (alist-get 'error resp)) -32700)))))

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

(ert-deftest claude-code-test-integration-mcp-handshake ()
  "A spawned instance completes the MCP handshake; a worktree eval sees its cwd."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         (claude-code-mcp-enabled t)
         (initialized nil)
         (probe (lambda (_session-id request)
                  (when (equal (alist-get 'method request) "initialize")
                    (setq initialized t))))
         ;; Snapshot existing worktrees so teardown removes only what this test
         ;; creates, never a developer's real worktrees.
         (worktrees-before (mapcar #'car (claude-code-mcp-tests--worktrees root)))
         buffer id pid)
    (advice-add 'claude-code--mcp-handle-request :before probe)
    (unwind-protect
        (claude-code-tests--with-top-level-env
          (let ((instance (claude-code-spawn
                           root :worktree t
                           :prompt "Respond with the single word: pong")))
            (setq id (car instance))
            (setq buffer (cdr instance)))
          (setq pid (buffer-local-value 'ghostel--pid buffer))
          ;; The real CLI performs the MCP initialize handshake against us.
          (should (claude-code-tests--await (lambda () initialized) 45))
          ;; Once the worktree session's sessions file lands, its real cwd is the
          ;; worktree dir; an `eval' of `default-directory' returns it.
          (should (claude-code-tests--await
                   (lambda ()
                     (let ((cwd (claude-code--session-cwd id)))
                       (and cwd (string-match-p "/\\.claude/worktrees/" cwd))))
                   45))
          (let* ((cwd (claude-code--session-cwd id))
                 (resp (claude-code--mcp-handle-request
                        id
                        (list (cons 'jsonrpc "2.0") (cons 'id 1)
                              (cons 'method "tools/call")
                              (cons 'params
                                    (list (cons 'name "eval")
                                          (cons 'arguments
                                                (list (cons 'code
                                                            "default-directory"))))))))
                 (result (alist-get 'result resp))
                 (text (alist-get 'text (aref (alist-get 'content result) 0))))
            (should (eq (alist-get 'isError result) :json-false))
            ;; `text' is `prin1-to-string' of the bound directory (quoted).
            (should (equal (read text) (file-name-as-directory cwd)))))
      (advice-remove 'claude-code--mcp-handle-request probe)
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
      (when (and pid (claude-code--pid-live-p pid))
        (ignore-errors (signal-process pid 'SIGKILL))
        ;; Let the process and its git children die before touching its worktree.
        (claude-code-tests--await (lambda () (not (claude-code--pid-live-p pid))) 5))
      (claude-code-mcp-stop)
      ;; Spawning with `:worktree t' leaves a locked git worktree behind that the
      ;; CLI never tears down.  Remove only worktrees that appeared during this
      ;; test; every pre-existing real worktree stays untouched.  A nil snapshot
      ;; means the pre-spawn listing failed -- a live repo always lists its main
      ;; worktree -- so skip cleanup rather than mistake every worktree for new.
      (when worktrees-before
        (claude-code-mcp-tests--remove-new-worktrees root worktrees-before)))))

(provide 'claude-code-mcp-tests)
;;; claude-code-mcp-tests.el ends here
