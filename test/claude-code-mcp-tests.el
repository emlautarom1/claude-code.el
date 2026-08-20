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
;; For the `claude-code-tests--' scaffolding the sibling suite owns, starting
;; with `claude-code-tests--with-registry', which every isolated test here
;; expands into.
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
             (should (claude-code-tests--listening-p ,port))
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

(defun claude-code-mcp-tests--eval-answer (code)
  "Return `eval' of CODE as a cons of its `isError' flag and result text."
  (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval code))))
    (cons (alist-get 'isError result)
          (alist-get 'text (aref (alist-get 'content result) 0)))))

(defun claude-code-mcp-tests--eval-buffers ()
  "Return the buffers the `eval' tool evaluates in that are still alive."
  (seq-filter (lambda (buffer)
                (string-prefix-p " *claude-code-eval*" (buffer-name buffer)))
              (buffer-list)))

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
                :false)))
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
  "`spawn' advertises every option as optional and holds none to a set of values."
  (let* ((schema (claude-code-mcp-tests--tool-schema "spawn"))
         (properties (alist-get 'properties schema)))
    (should (equal (alist-get 'required schema) []))
    (should (equal (alist-get 'type (alist-get 'worktree properties)) "string"))
    (should (equal (alist-get 'type (alist-get 'name properties)) "string"))
    (should-not (assq 'enum (alist-get 'model properties)))
    (should-not (assq 'enum (alist-get 'effort properties)))
    (should-not (assq 'enum (alist-get 'name properties)))))

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
      (should (eq (alist-get 'isError result) :false)))))

(ert-deftest claude-code-mcp-test-args-hold-to-the-schema ()
  "A value contradicting the advertised schema is a -32602; the handler is not run.
The schema is what a caller builds its call from, so a wrong type or a value
outside an `:enum' is a protocol error rather than something to pass on.  An
empty string is a value only a string carries: that value for a required
argument, an omission for an optional one -- a handler forwarding it to a
process would otherwise emit an option with nothing after it -- and for any
other type the contradiction it looks like."
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
                         ;; Only a boolean takes false, and no type takes an
                         ;; empty string but a string: the caller named the
                         ;; argument, so what it sent is the wrong type rather
                         ;; than nothing at all.
                         (((text . :false)) . "type")
                         (((text . "t") (flag . "")) . "type")
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
        (let ((result (alist-get 'result
                                 (claude-code-mcp-tests--call-tool
                                  "sess" "cc-mcp-test-confirm"
                                  '(confirm . :false)))))
          (should (eq (alist-get 'isError result) :false))
          (should (null seen)))
        ;; Omitted it is missing, and so is null: only false is an answer, so
        ;; a caller that sent nothing in particular is not read as a no.
        (dolist (arguments '(nil ((confirm . :null))))
          (setq seen 'unset)
          (should (string-match-p
                   "Missing required"
                   (alist-get 'message
                              (alist-get 'error
                                         (apply #'claude-code-mcp-tests--call-tool
                                                "sess" "cc-mcp-test-confirm"
                                                arguments)))))
          (should (eq seen 'unset)))))))

(ert-deftest claude-code-mcp-test-params-and-arguments-must-be-objects ()
  "A `params' or `arguments' that is not an object is the caller's error.
JSON null stands for the object a call did not send, since both are optional;
anything else is a -32602 rather than a Lisp type error dressed up as -32603."
  (claude-code-mcp-tests--with-tools '("cc-mcp-test-noargs")
    (claude-code-mcp-make-tool
     :name "cc-mcp-test-noargs" :description "No args."
     :handler (lambda () "ok"))
    (claude-code-mcp-tests--isolated
      ;; Null is the absent object: a tool needing nothing still runs.
      (let ((response (claude-code--mcp-handle-request
                       "sess"
                       (claude-code-mcp-tests--request
                        "tools/call" 1
                        (list (cons 'name "cc-mcp-test-noargs")
                              (cons 'arguments :null))))))
        (should (eq (alist-get 'isError (alist-get 'result response))
                    :false)))
      ;; A scalar or an array is not an arguments object.
      (dolist (arguments (list "code" 42 (vector 1 2)))
        (let ((error-object
               (alist-get 'error (claude-code--mcp-handle-request
                                  "sess"
                                  (claude-code-mcp-tests--request
                                   "tools/call" 2
                                   (list (cons 'name "cc-mcp-test-noargs")
                                         (cons 'arguments arguments)))))))
          (should (equal (alist-get 'code error-object) -32602))
          (should (string-match-p "must be an object"
                                  (alist-get 'message error-object)))))
      ;; `params' is what a tool name is read from, so it answers for its own
      ;; shape rather than letting `alist-get' answer for it.
      (dolist (params (list "code" 42 (vector 1 2)))
        (let ((error-object
               (alist-get 'error (claude-code--mcp-handle-request
                                  "sess"
                                  (claude-code-mcp-tests--request
                                   "tools/call" 3 params)))))
          (should (equal (alist-get 'code error-object) -32602))
          (should (string-match-p "must be an object"
                                  (alist-get 'message error-object)))))
      ;; Null is the absent object here too, leaving the absent name to answer.
      (should (string-match-p
               "Unknown tool"
               (alist-get 'message
                          (alist-get 'error
                                     (claude-code--mcp-handle-request
                                      "sess"
                                      (claude-code-mcp-tests--request
                                       "tools/call" 4 :null)))))))))

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
  "`eval' returns the form's printed value and `isError' JSON false.
This one spells the extraction out: it is the wire-shape check the rest of
the `eval' tests reach through `claude-code-mcp-tests--eval-answer'."
  (let* ((resp (claude-code-mcp-tests--call-eval "(+ 40 2)"))
         (result (alist-get 'result resp))
         (content (alist-get 'content result)))
    (should (vectorp content))
    (should (equal (alist-get 'type (aref content 0)) "text"))
    (should (equal (alist-get 'text (aref content 0)) "42"))
    ;; Success is JSON false, not nil (wire-shape check).
    (should (eq (alist-get 'isError result) :false)))
  ;; Empty code is nil, not a read error.
  (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval ""))))
    (should (equal (alist-get 'text (aref (alist-get 'content result) 0)) "nil"))
    (should (eq (alist-get 'isError result) :false))))

(defvar claude-code-mcp-tests--x nil
  "Scratch special variable for the `eval' tool tests.")

(ert-deftest claude-code-mcp-test-eval-progn ()
  "A `progn' sequences several forms and answers with the last value."
  (let* ((claude-code-mcp-tests--x nil)
         (answer (claude-code-mcp-tests--eval-answer
                  "(progn (setq claude-code-mcp-tests--x 5)
                          (* claude-code-mcp-tests--x
                             claude-code-mcp-tests--x))")))
    (should (eq (car answer) :false))
    (should (equal (cdr answer) "25"))))

(ert-deftest claude-code-mcp-test-eval-refuses-several-forms ()
  "Several top-level forms are refused, with advice to wrap them in `progn'."
  (let ((answer (claude-code-mcp-tests--eval-answer "(+ 1 2) (* 3 4)")))
    (should (eq (car answer) t))
    (should (string-match-p "progn" (cdr answer))))
  ;; The refusal precedes evaluation: no part of the submission runs.
  (let ((claude-code-mcp-tests--x nil))
    (claude-code-mcp-tests--call-eval "(setq claude-code-mcp-tests--x 'ran) 42")
    (should (null claude-code-mcp-tests--x))))

(ert-deftest claude-code-mcp-test-eval-trailing-text-is-not-a-form ()
  "Trailing text that reads as nothing surfaces the reader's own complaint.
Advising `progn' there would be a trap: wrapping an unbalanced form leaves it
unbalanced, so the caller needs the syntax error instead."
  (let ((answer (claude-code-mcp-tests--eval-answer "(+ 1 2))")))
    (should (eq (car answer) t))
    (should (string-match-p "Invalid read syntax" (cdr answer)))
    (should-not (string-match-p "progn" (cdr answer))))
  (let ((answer (claude-code-mcp-tests--eval-answer "(+ 1 2) (+ 3")))
    (should (eq (car answer) t))
    (should (string-match-p "End of file" (cdr answer)))
    (should-not (string-match-p "progn" (cdr answer)))))

(ert-deftest claude-code-mcp-test-eval-errors ()
  "Evaluation and read errors become an `isError' result, never a crash."
  ;; A runtime error (division by zero) is caught and reported.
  (let ((answer (claude-code-mcp-tests--eval-answer "(/ 1 0)")))
    (should (eq (car answer) t))
    (should (string-match-p "Error:" (cdr answer))))
  ;; A malformed form (unbalanced paren) is caught and reported.
  (should (eq (car (claude-code-mcp-tests--eval-answer "(+ 1")) t)))

(ert-deftest claude-code-mcp-test-eval-semicolons-in-code ()
  "A `;' is code in a character literal or string, and a comment elsewhere."
  (dolist (case '(("?;" . "59")
                  ("(list ?; 5)" . "(59 5)")
                  ("\"a;b\"" . "\"a;b\"")
                  ;; A leading comment, and a comment inside the form.
                  (";; lead\n(progn (+ 1 2) ; mid\n (* 2 3))" . "6")
                  ;; A comment after the form, skipped before the trailing check.
                  ("(+ 40 2) ; the answer" . "42")
                  ;; A comment holding an unbalanced delimiter is skipped by
                  ;; syntax, so it never reaches the reader.
                  ("(+ 1 2) ; )" . "3")
                  ;; Nothing but comments evaluates to nil, not a read error.
                  (";; just a comment" . "nil")))
    (let ((answer (claude-code-mcp-tests--eval-answer (car case))))
      (should (eq (car answer) :false))
      (should (equal (cdr answer) (cdr case))))))

(ert-deftest claude-code-mcp-test-eval-survives-a-buffer-switch ()
  "A form leaving another buffer current still answers with its own value.
Nothing of that buffer may be read as source, and its point must not move."
  (let ((buffer (generate-new-buffer "*claude-code-mcp-test-source*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "(setq claude-code-mcp-tests--x 'read-from-the-wrong-buffer)")
            (goto-char (point-min)))
          (let* ((claude-code-mcp-tests--x nil)
                 (answer (claude-code-mcp-tests--eval-answer
                          (format "(progn (set-buffer %S) :submitted)"
                                  (buffer-name buffer)))))
            (should (eq (car answer) :false))
            (should (equal (cdr answer) ":submitted"))
            (should (null claude-code-mcp-tests--x))
            (should (= (with-current-buffer buffer (point)) 1))))
      (kill-buffer buffer))))

(ert-deftest claude-code-mcp-test-eval-runs-in-a-buffer-of-its-own ()
  "Evaluation runs in an empty buffer, never one the caller did not name."
  (should (equal (cdr (claude-code-mcp-tests--eval-answer "(buffer-string)")) "\"\""))
  (let ((buffer (generate-new-buffer "*claude-code-mcp-test-bystander*")))
    (unwind-protect
        (with-current-buffer buffer
          (claude-code-mcp-tests--call-eval "(insert \"x\")")
          (should (equal (buffer-string) "")))
      (kill-buffer buffer))))

(ert-deftest claude-code-mcp-test-eval-buffer-does-not-survive ()
  "The buffer evaluation ran in is gone afterwards, however the call ended."
  (dolist (code '("(buffer-name)" "(kill-buffer)" "(error \"boom\")" "(+ 1"))
    (claude-code-mcp-tests--call-eval code)
    (should-not (claude-code-mcp-tests--eval-buffers)))
  ;; The timeout leaves by a throw from a timer, not by returning or signalling.
  (let ((claude-code-mcp-eval-timeout 0.1))
    (should (eq (car (claude-code-mcp-tests--eval-answer "(sit-for 5)")) t))
    (should-not (claude-code-mcp-tests--eval-buffers))))

(ert-deftest claude-code-mcp-test-eval-answers-in-full ()
  "A caller's own print limits never truncate what the tool answers with."
  (let ((print-length 2)
        (print-level 1))
    (should (equal (cdr (claude-code-mcp-tests--eval-answer "(list 1 2 3 4)"))
                   "(1 2 3 4)"))
    (should (equal (cdr (claude-code-mcp-tests--eval-answer "'(1 (2 (3 (4))))"))
                   "(1 (2 (3 (4))))"))))

(ert-deftest claude-code-mcp-test-eval-sees-the-session-directory ()
  "The evaluated form runs in the calling session's own working directory."
  (claude-code-mcp-tests--isolated
    (puthash "sess" (list :buffer nil :origin "/home/test/proj")
             claude-code--managed)
    (let ((result (alist-get 'result
                             (claude-code-mcp-tests--call-tool
                              "sess" "eval" (cons 'code "default-directory")))))
      (should (eq (alist-get 'isError result) :false))
      (should (equal (alist-get 'text (aref (alist-get 'content result) 0))
                     "\"/home/test/proj/\"")))))

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
                    :false))
        (should (string-match-p claude-code-tests--uuid-re id))
        (should (= (length execs) 1))
        ;; The instance was registered under that id, launched from the
        ;; caller's root, and carries the session id on its command line.
        (should (equal (plist-get (gethash id claude-code--managed) :origin)
                       (claude-code--normalize-root "/home/test/proj")))
        (should (equal (nth 1 (car execs))
                       (list "--session-id" id "--mcp-config" "{}")))))))

(ert-deftest claude-code-mcp-test-spawn-options ()
  "Every option reaches the CLI, and a worktree is asked for by name."
  (let ((execs '()))
    (claude-code-mcp-tests--with-caller "/home/test/proj" execs
      (let ((id (claude-code-mcp-tests--result-text
                 (claude-code-mcp-tests--call-tool
                  "sess" "spawn" '(prompt . "do the thing") '(model . "opus")
                  '(effort . "xhigh") '(worktree . "feat")
                  '(name . "a long name")))))
        (should (equal (nth 1 (car execs))
                       (list "--session-id" id "--name=a long name"
                             "--worktree=feat"
                             "--model" "opus" "--effort" "xhigh"
                             "--mcp-config" "{}" "--" "do the thing"))))
      ;; A name on its own is the whole request.
      (claude-code-mcp-tests--call-tool "sess" "spawn" '(worktree . "solo"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "--worktree=solo" "--mcp-config" "{}")))
      ;; The name joins the flag in one argument, so a caller-chosen name the
      ;; CLI would otherwise take for a flag of its own cannot become one.
      (claude-code-mcp-tests--call-tool "sess" "spawn"
                                        '(worktree . "--ax-screen-reader"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "--worktree=--ax-screen-reader" "--mcp-config" "{}")))
      ;; A worktree is asked for by name, so a value that is not one is
      ;; refused, and refused before anything is launched.
      (dolist (value '(t :false))
        (let* ((launched (length execs))
               (error-object
                (alist-get 'error (claude-code-mcp-tests--call-tool
                                   "sess" "spawn" (cons 'worktree value)))))
          (should (equal (alist-get 'code error-object) -32602))
          (should (string-match-p "must be of type string"
                                  (alist-get 'message error-object)))
          (should (= (length execs) launched))))
      ;; An empty string is an omitted option, not an empty value: `--model ""'
      ;; would reach the CLI and kill the instance at startup, and an unnamed
      ;; worktree is no worktree.
      (claude-code-mcp-tests--call-tool
       "sess" "spawn" '(prompt . "") '(model . "") '(effort . "")
       '(worktree . "") '(name . ""))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "--mcp-config" "{}")))
      ;; Neither the model nor the effort is held to a set of values: an unknown
      ;; one reaches the CLI, whose error it is to report.
      (claude-code-mcp-tests--call-tool "sess" "spawn" '(effort . "turbo"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "--effort" "turbo" "--mcp-config" "{}"))))))

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

(ert-deftest claude-code-mcp-test-serialize-carries-a-parsed-false ()
  "An `id' the parser produced serializes without translation on the way back."
  (let* ((body (concat "{\"jsonrpc\":\"2.0\",\"id\":false,"
                       "\"method\":\"initialize\"}"))
         (response (claude-code--mcp-response-for-body "sess" body nil)))
    (should (eq (alist-get 'id response) :false))
    (should (string-match-p "\"id\":false"
                            (claude-code--mcp-serialize response)))))

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
                 :name "bad" :description "No handler."))
  ;; So is any arg spec the schema cannot carry: a type no predicate enforces,
  ;; a nameless argument, an enum of anything but strings.  Each would break
  ;; `tools/list' for the whole catalog, so none of them registers.
  (dolist (arg '((:name "count" :type integer :description "How many.")
                 (:type string :description "Nameless.")
                 (:name "level" :type string :enum (low high))))
    (should-error (claude-code-mcp-make-tool
                   :name "cc-mcp-test-bad-arg" :description "Malformed arg."
                   :args (list arg) :handler #'identity))
    (should-not (gethash "cc-mcp-test-bad-arg" claude-code--mcp-tools))))

(ert-deftest claude-code-mcp-test-boolean-args ()
  "A `boolean' argument reaches its handler as a Lisp truth value.
The parser renders JSON false as `:false' and null as `:null', both non-nil in
Lisp, so each must reach the handler as nil."
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
      (dolist (case '((:false . nil) (:null . nil) (t . t)))
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
      (claude-code-mcp-tests--with-server port
        (puthash "a" (list :buffer buf) claude-code--managed)
        (puthash "b" (list :buffer other) claude-code--managed)
        ;; One of two exiting leaves the server up for the survivor.
        (with-current-buffer buf (claude-code--on-buffer-kill))
        (should (= (hash-table-count claude-code--managed) 1))
        (should claude-code--mcp-server)
        ;; The last one takes it down.
        (with-current-buffer other (claude-code--on-buffer-kill))
        (should (zerop (hash-table-count claude-code--managed)))
        (should-not claude-code--mcp-server)
        (should-not (claude-code-tests--listening-p port))))))

(ert-deftest claude-code-mcp-test-stops-when-the-last-instance-is-killed ()
  "Killing the last instance takes the shared server down with it.
The server's lifetime hangs on the registry emptying, and a killed instance
reports that from its buffer."
  (claude-code-tests--with-managed-buffer buf
    (claude-code-mcp-tests--with-server port
      (claude-code--register "a" buf "/r" nil)
      (claude-code-kill (claude-code-session--create
                         :id "a" :alive-p t :buffer buf))
      (should (zerop (hash-table-count claude-code--managed)))
      (should-not claude-code--mcp-server)
      (should-not (claude-code-tests--listening-p port)))))

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
      (json-parse-string body :object-type 'alist))))

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
      (should (eq (alist-get 'isError result) :false)))
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
            (should (eq (alist-get 'isError result) :false))
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
