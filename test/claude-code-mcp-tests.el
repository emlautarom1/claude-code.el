;;; claude-code-mcp-tests.el --- Tests for claude-code-mcp -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT suite for claude-code-mcp.el: the pure protocol layer, the tool
;; registry and its tools, the dispatch entry point, the launch wiring, and the
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

(defun claude-code-mcp-tests--tools ()
  "Return the tool descriptors `tools/list' advertises."
  (alist-get 'tools
             (alist-get 'result
                        (claude-code--mcp-handle-request
                         4242
                         (claude-code-mcp-tests--request "tools/list" 1)))))

(defun claude-code-mcp-tests--tool (name)
  "Return the `tools/list' descriptor advertised for the tool called NAME."
  (seq-find (lambda (tool) (equal (alist-get 'name tool) name))
            (claude-code-mcp-tests--tools)))

(defun claude-code-mcp-tests--tool-schema (name)
  "Return the `inputSchema' advertised for the tool called NAME."
  (alist-get 'inputSchema (claude-code-mcp-tests--tool name)))

(defun claude-code-mcp-tests--call-tool (pid name &rest arguments)
  "Dispatch a `tools/call' of the tool NAME for instance PID; return the response.
ARGUMENTS are the (NAME . VALUE) pairs of the call's `arguments' object.  The
caller owns the session state the call runs against, so a test that needs one
isolated wraps this in `claude-code-mcp-tests--isolated' itself."
  (claude-code--mcp-handle-request
   pid
   (claude-code-mcp-tests--request
    "tools/call" 7 (list (cons 'name name) (cons 'arguments arguments)))))

(defun claude-code-mcp-tests--call-eval (code)
  "Dispatch a `tools/call' of the `eval' tool for CODE and return the response."
  (claude-code-mcp-tests--isolated
    (claude-code--mcp-handle-request
     4242
     (claude-code-mcp-tests--request
      "tools/call" 9
      (list (cons 'name "eval")
            (cons 'arguments (list (cons 'code code))))))))

(defun claude-code-mcp-tests--eval-answer (code)
  "Return `eval' of CODE as a cons of its `isError' flag and result text."
  (let ((result (alist-get 'result (claude-code-mcp-tests--call-eval code))))
    (cons (alist-get 'isError result)
          (alist-get 'text (aref (alist-get 'content result) 0)))))

;;;; Pure dispatch: initialize / notifications / errors

(ert-deftest claude-code-mcp-test-initialize ()
  "`initialize' reports the server's own protocol version and capabilities."
  ;; Ignores the client's request for a specific version.
  (let* ((resp (claude-code--mcp-handle-request
                4242
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
                            4242
                            (claude-code-mcp-tests--request "initialize" 2)))))
    (should (equal (alist-get 'protocolVersion result) "2025-06-18"))))

(ert-deftest claude-code-mcp-test-notification-returns-nil ()
  "A request without an `id' is a notification and yields nil (no response)."
  (should (null (claude-code--mcp-handle-request
                 4242
                 (claude-code-mcp-tests--request "notifications/initialized")))))

(ert-deftest claude-code-mcp-test-error-codes-echo-id ()
  "Protocol errors carry the right code and echo the request id."
  ;; Unknown method -> -32601.
  (let ((resp (claude-code--mcp-handle-request
               4242 (claude-code-mcp-tests--request "no/such/method" 7))))
    (should (equal (alist-get 'id resp) 7))
    (should (= (alist-get 'code (alist-get 'error resp)) -32601)))
  ;; Unknown tool -> -32602.
  (let ((resp (claude-code-mcp-tests--isolated
                (claude-code--mcp-handle-request
                 4242
                 (claude-code-mcp-tests--request
                  "tools/call" 8 (list (cons 'name "nope")
                                       (cons 'arguments nil)))))))
    (should (equal (alist-get 'id resp) 8))
    (should (= (alist-get 'code (alist-get 'error resp)) -32602)))
  ;; Missing required argument -> -32602.
  (let ((resp (claude-code-mcp-tests--isolated
                (claude-code--mcp-handle-request
                 4242
                 (claude-code-mcp-tests--request
                  "tools/call" 10 (list (cons 'name "eval")
                                        (cons 'arguments nil)))))))
    (should (equal (alist-get 'id resp) 10))
    (should (= (alist-get 'code (alist-get 'error resp)) -32602))))

(ert-deftest claude-code-mcp-test-invalid-request-shape ()
  "A non-object request (array or bare scalar) yields -32600 with a null id."
  (dolist (bad (list [1 2] 5 "x" :null))
    (let ((resp (claude-code--mcp-handle-request 4242 bad)))
      (should (eq (alist-get 'id resp) :null))
      (should (= (alist-get 'code (alist-get 'error resp)) -32600)))))

;;;; Pure body handling: JSON parsing

(ert-deftest claude-code-mcp-test-body-dispatch ()
  "A well-formed body dispatches; a notification body yields nil."
  (let ((resp (claude-code--mcp-response-for-body
               4242
               (claude-code--mcp-serialize
                (claude-code-mcp-tests--request "tools/list" 1)))))
    (should (equal (alist-get 'id resp) 1))
    (should (alist-get 'tools (alist-get 'result resp))))
  (should (null (claude-code--mcp-response-for-body
                 4242
                 (claude-code--mcp-serialize
                  (claude-code-mcp-tests--request "notifications/initialized"))))))

(ert-deftest claude-code-mcp-test-parse-error ()
  "A malformed JSON body is answered with a -32700 error and a null id."
  (let ((resp (claude-code--mcp-response-for-body 4242 "{not json")))
    (should (eq (alist-get 'id resp) :null))
    (should (= (alist-get 'code (alist-get 'error resp)) -32700))))

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
                                4242
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
                                          4242 "cc-mcp-test-schema" arguments))))
            (should (equal (alist-get 'code error-object) -32602))
            (should (string-match-p message (alist-get 'message error-object)))
            (should (eq seen 'unset))))
        ;; Both empty strings reach the handler as what they mean there.
        (claude-code-mcp-tests--call-tool 4242 "cc-mcp-test-schema"
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
                                  4242 "cc-mcp-test-confirm"
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
                                                4242 "cc-mcp-test-confirm"
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
                       4242
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
                                  4242
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
                                  4242
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
                                      4242
                                      (claude-code-mcp-tests--request
                                       "tools/call" 4 :null)))))))))

(ert-deftest claude-code-mcp-test-session-cwd-is-bound-for-the-call ()
  "A tool sees its caller's cwd for the call, as both value and directory.
A caller with no sessions/ file works in the current directory, which
`server.el' binds to the bridge's own.  The binding must not outlive the call:
the next one may come from another `claude'."
  (let ((seen 'unset)
        (here (directory-file-name (expand-file-name default-directory))))
    (claude-code-mcp-tests--with-tools '("cc-mcp-test-cwd")
      (claude-code-mcp-make-tool
       :name "cc-mcp-test-cwd" :description "Report the caller's cwd."
       :handler (lambda ()
                  (setq seen (cons claude-code--mcp-session-cwd default-directory))
                  "ok"))
      (claude-code-mcp-tests--with-session-at 4242 "/home/test/proj"
        (pcase-dolist (`(,caller ,cwd)
                       (list (list 4242 "/home/test/proj")
                             (list 4343 here)
                             (list nil here)))
          (setq seen 'unset)
          (claude-code-mcp-tests--call-tool caller "cc-mcp-test-cwd")
          (should (equal seen (cons cwd (file-name-as-directory cwd)))))))
    (should (null claude-code--mcp-session-cwd))))

(ert-deftest claude-code-mcp-test-session-cwd-follows-the-process ()
  "A call is answered for the process it comes from, whatever it runs.
Its cwd is read off its own sessions/ file, which a `/clear' rewrites under a
new session id while the PID stays."
  (claude-code-tests--with-fixtures
    (should (equal (claude-code-mcp-tests--result-text
                    (claude-code-mcp-tests--call-tool
                     1003 "eval" (cons 'code "default-directory")))
                   "\"/home/test/proj/.claude/worktrees/feat/\""))))

(ert-deftest claude-code-mcp-test-call-leaves-the-current-buffer-alone ()
  "A directory set during a call in the buffer it arrived in outlives the call.
A request is dispatched in whatever buffer is current, the user's, which may be
an instance buffer following its process into a worktree meanwhile."
  (claude-code-mcp-tests--with-tools '("cc-mcp-test-cd")
    (with-temp-buffer
      (setq default-directory "/home/test/root/")
      (let ((user (current-buffer)))
        (claude-code-mcp-make-tool
         :name "cc-mcp-test-cd" :description "Move the user's buffer."
         :handler (lambda ()
                    (with-current-buffer user
                      (setq default-directory "/home/test/root/wt/"))
                    "ok"))
        (claude-code-mcp-tests--with-session-at 4242 "/home/test/proj"
          (claude-code-mcp-tests--call-tool 4242 "cc-mcp-test-cd"))
        (should (equal default-directory "/home/test/root/wt/"))))))

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
  (let ((before (buffer-list)))
    (dolist (code '("(buffer-name)" "(kill-buffer)" "(error \"boom\")" "(+ 1"))
      (claude-code-mcp-tests--call-eval code)
      (should-not (seq-difference (buffer-list) before)))
    ;; The timeout leaves by a throw from a timer, not by returning or signalling.
    (let ((claude-code-mcp-eval-timeout 0.1))
      (should (eq (car (claude-code-mcp-tests--eval-answer "(sit-for 5)")) t))
      (should-not (seq-difference (buffer-list) before)))))

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
  (claude-code-mcp-tests--with-session-at 4242 "/home/test/proj"
    (let ((result (alist-get 'result
                             (claude-code-mcp-tests--call-tool
                              4242 "eval" (cons 'code "default-directory")))))
      (should (eq (alist-get 'isError result) :false))
      (should (equal (alist-get 'text (aref (alist-get 'content result) 0))
                     "\"/home/test/proj/\"")))))

;;;; Pure dispatch: tools/call spawn

(defmacro claude-code-mcp-tests--with-caller (var cwd execs &rest body)
  "Run BODY with VAR the PID of a `claude' working in CWD, the launch stubbed.
EXECS collects the (BUFFER ARGS) of every launch, so a test asserts what
reached the CLI without a `claude' ever running."
  (declare (indent 3))
  `(let ((,var 4242))
     (claude-code-mcp-tests--with-session-at ,var ,cwd
       (claude-code-tests--recording-launch ,execs ,@body))))

(defun claude-code-mcp-tests--result-text (response)
  "Return the text payload of RESPONSE's tool result."
  (alist-get 'text (aref (alist-get 'content (alist-get 'result response)) 0)))

(ert-deftest claude-code-mcp-test-spawn-in-the-callers-directory ()
  "`spawn' launches in the calling session's own directory and returns the id.
The directory is the server's to resolve -- the tool takes no path argument --
and the id is what the caller has to find the session by afterwards."
  (let ((execs '()))
    (claude-code-mcp-tests--with-caller caller "/home/test/proj" execs
      (let* ((response (claude-code-mcp-tests--call-tool caller "spawn"))
             (id (claude-code-mcp-tests--result-text response)))
        (should (eq (alist-get 'isError (alist-get 'result response))
                    :false))
        (should (string-match-p claude-code-tests--uuid-re id))
        (should (= (length execs) 1))
        ;; The instance was registered under that id, launched from the
        ;; caller's root, and carries the session id on its command line.
        (should (equal (plist-get (claude-code-tests--entry id) :origin)
                       (claude-code--normalize-root "/home/test/proj")))
        (should (equal (nth 1 (car execs))
                       (list "--session-id" id)))))))

(ert-deftest claude-code-mcp-test-spawn-options ()
  "Every option reaches the CLI, and a worktree is asked for by name."
  (let ((execs '()))
    (claude-code-mcp-tests--with-caller caller "/home/test/proj" execs
      (let ((id (claude-code-mcp-tests--result-text
                 (claude-code-mcp-tests--call-tool
                  caller "spawn" '(prompt . "do the thing") '(model . "opus")
                  '(effort . "xhigh") '(worktree . "feat")
                  '(name . "a long name")))))
        (should (equal (nth 1 (car execs))
                       (list "--session-id" id "--name=a long name"
                             "--worktree=feat"
                             "--model" "opus" "--effort" "xhigh"
                             "--" "do the thing"))))
      ;; A name on its own is the whole request.
      (claude-code-mcp-tests--call-tool caller "spawn" '(worktree . "solo"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "--worktree=solo")))
      ;; The name joins the flag in one argument, so a caller-chosen name the
      ;; CLI would otherwise take for a flag of its own cannot become one.
      (claude-code-mcp-tests--call-tool caller "spawn"
                                        '(worktree . "--ax-screen-reader"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "--worktree=--ax-screen-reader")))
      ;; A worktree is asked for by name, so a value that is not one is
      ;; refused, and refused before anything is launched.
      (dolist (value '(t :false))
        (let* ((launched (length execs))
               (error-object
                (alist-get 'error (claude-code-mcp-tests--call-tool
                                   caller "spawn" (cons 'worktree value)))))
          (should (equal (alist-get 'code error-object) -32602))
          (should (string-match-p "must be of type string"
                                  (alist-get 'message error-object)))
          (should (= (length execs) launched))))
      ;; An empty string is an omitted option, not an empty value: `--model ""'
      ;; would reach the CLI and kill the instance at startup, and an unnamed
      ;; worktree is no worktree.
      (claude-code-mcp-tests--call-tool
       caller "spawn" '(prompt . "") '(model . "") '(effort . "")
       '(worktree . "") '(name . ""))
      (should (null (nthcdr 2 (nth 1 (car execs)))))
      ;; Neither the model nor the effort is held to a set of values: an unknown
      ;; one reaches the CLI, whose error it is to report.
      (claude-code-mcp-tests--call-tool caller "spawn" '(effort . "turbo"))
      (should (equal (nthcdr 2 (nth 1 (car execs)))
                     (list "--effort" "turbo"))))))

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
         (response (claude-code--mcp-response-for-body 4242 body)))
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
           4242
           (claude-code-mcp-tests--request
            "tools/call" 2
            (list (cons 'name "cc-mcp-test-bool")
                  (cons 'arguments (list (cons 'flag (car case))))))))
        (should (eq seen (cdr case)))))))

;;;; Dispatch: the bridge's entry point

(defun claude-code-mcp-tests--encode (request)
  "Return REQUEST, an alist, as the base64 JSON line the bridge passes on."
  (base64-encode-string (json-serialize request) t))

(defun claude-code-mcp-tests--decode (reply)
  "Return REPLY, base64 JSON from `claude-code-mcp-dispatch', parsed."
  (json-parse-string (decode-coding-string (base64-decode-string reply) 'utf-8)
                     :object-type 'alist))

(ert-deftest claude-code-mcp-test-dispatch ()
  "A request round-trips through base64 JSON, text outside ASCII included.
A notification is answered with nothing, which the bridge prints nothing for."
  (claude-code-mcp-tests--isolated
    (let ((resp (claude-code-mcp-tests--decode
                 (claude-code-mcp-dispatch
                  (claude-code-mcp-tests--encode
                   (claude-code-mcp-tests--request
                    "tools/call" 3
                    (list (cons 'name "eval")
                          (cons 'arguments
                                (list (cons 'code "(concat \"ñ\" \"✓\")"))))))
                  4242))))
      (should (equal (alist-get 'id resp) 3))
      (should (equal (claude-code-mcp-tests--result-text resp) "\"ñ✓\"")))
    (should-not (claude-code-mcp-dispatch
                 (claude-code-mcp-tests--encode
                  (claude-code-mcp-tests--request "notifications/initialized"))
                 4242))))

(ert-deftest claude-code-mcp-test-dispatch-never-signals ()
  "Whatever reaches the dispatch is answered, since an error would end the bridge."
  (claude-code-mcp-tests--isolated
    ;; Neither base64 nor, decoded, JSON: both are a parse error.
    (dolist (request (list "%%%" (base64-encode-string "{not json" t)))
      (let ((error-object (alist-get 'error (claude-code-mcp-tests--decode
                                             (claude-code-mcp-dispatch
                                              request 4242)))))
        (should (= (alist-get 'code error-object) -32700))))
    ;; A quit while decoding is a parse error, not the nil of no reply.
    (cl-letf* ((decode (symbol-function 'base64-decode-string))
               ((symbol-function 'base64-decode-string)
                (lambda (string &rest _)
                  (if (equal string "quit") (signal 'quit nil)
                    (funcall decode string)))))
      (should (= (alist-get 'code (alist-get 'error (claude-code-mcp-tests--decode
                                                     (claude-code-mcp-dispatch
                                                      "quit" 4242))))
                 -32700)))
    ;; A quit outside any tool is an internal error for the request.
    (cl-letf (((symbol-function 'claude-code--mcp-tools-list)
               (lambda () (signal 'quit nil))))
      (let ((resp (claude-code-mcp-tests--decode
                   (claude-code-mcp-dispatch
                    (claude-code-mcp-tests--encode
                     (claude-code-mcp-tests--request "tools/list" 4))
                    4242))))
        (should (equal (alist-get 'id resp) 4))
        (should (= (alist-get 'code (alist-get 'error resp)) -32603))))
    ;; So is a response JSON cannot carry.
    (cl-letf (((symbol-function 'claude-code--mcp-handle-request)
               (lambda (_caller _request)
                 (list (cons 'id 5) (cons 'result (current-buffer))))))
      (let ((resp (claude-code-mcp-tests--decode
                   (claude-code-mcp-dispatch
                    (claude-code-mcp-tests--encode
                     (claude-code-mcp-tests--request "tools/list" 5))
                    4242))))
        (should (equal (alist-get 'id resp) 5))
        (should (= (alist-get 'code (alist-get 'error resp)) -32603))))))

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

(ert-deftest claude-code-mcp-test-wiring ()
  "A local launch names this Emacs's server and auto-approves the tools.
The variable `emacsclient' would try first is unset, so it reaches this server
whatever the environment Emacs runs in says."
  (with-temp-buffer
    (let ((claude-code-mcp-auto-approve t))
      (claude-code-mcp-tests--with-server-at nil "/run/test/emacs/"
        (should (equal (claude-code--mcp-wiring (current-buffer))
                       '(("--allowedTools" "mcp__emacs")
                         ("EMACS_SOCKET_NAME" . "/run/test/emacs/server")
                         ("EMACS_SERVER_FILE")))))
      (claude-code-mcp-tests--with-server-at t "/home/test/server/"
        (should (equal (cdr (claude-code--mcp-wiring (current-buffer)))
                       '(("EMACS_SERVER_FILE" . "/home/test/server/server")
                         ("EMACS_SOCKET_NAME"))))
        ;; Without auto-approval the instance is pointed at Emacs all the same.
        (let ((claude-code-mcp-auto-approve nil))
          (should (equal (car (claude-code--mcp-wiring (current-buffer)))
                         nil)))))))

(ert-deftest claude-code-mcp-test-wiring-without-a-server ()
  "With no server running, a launch still names the one this Emacs would run.
An instance so reaches this Emacs once its server starts.  The user is told
once, not per launch, and told when the name belongs to another Emacs, which
is where the instance's calls then go."
  (with-temp-buffer
    (claude-code-mcp-tests--with-server-at nil "/run/test/emacs/"
      (dotimes (_ 2)
        (should (equal (cdr (claude-code--mcp-wiring (current-buffer)))
                       '(("EMACS_SOCKET_NAME" . "/run/test/emacs/server")
                         ("EMACS_SERVER_FILE")))))
      (should (= (length warnings) 1))
      (should (eq (car (car warnings)) 'claude-code-mcp))
      (should (string-match-p "No Emacs server is running" (cdr (car warnings)))))
    (claude-code-mcp-tests--with-server-at nil "/run/test/emacs/"
      (cl-letf (((symbol-function 'server-running-p) (lambda (&rest _) t)))
        (claude-code--mcp-wiring (current-buffer)))
      (should (string-match-p "Another Emacs.s server holds the name .server."
                              (cdr (car warnings)))))
    ;; A live server draws no warning.
    (claude-code-mcp-tests--with-server-at nil "/run/test/emacs/"
      (setq server-process (make-pipe-process :name "cc-mcp-test-server"
                                              :noquery t))
      (unwind-protect (claude-code--mcp-wiring (current-buffer))
        (delete-process server-process))
      (should (null warnings)))))

(ert-deftest claude-code-mcp-test-no-wiring-in-a-remote-directory ()
  "An instance in a remote directory is not wired, and nothing is checked for it.
Its bridge runs on its host, and a rule auto-approving an `emacs' server there
would approve whatever that host calls by the name."
  (claude-code-mcp-tests--with-server-at nil "/run/test/emacs/"
    (with-temp-buffer
      (setq default-directory "/ssh:cc-test-host:/r/")
      (should (null (claude-code--mcp-wiring (current-buffer)))))
    (should (null warnings))))

(ert-deftest claude-code-mcp-test-install ()
  "Install replaces the user-scope entry, in the config dir launches use.
It runs the CLI from the home directory, whatever host the current buffer is
on, and reports what the CLI says when registering fails."
  (let ((calls '())
        (resolved-in nil)
        (status 0)
        (default-directory "/ssh:cc-test-host:/r/")
        (claude-code-config-dir "/home/test/config")
        (environment (getenv "CLAUDE_CONFIG_DIR")))
    (cl-letf (((symbol-function 'claude-code--resolve-executable)
               (lambda (program) (setq resolved-in default-directory) program))
              ((symbol-function 'call-process)
               (lambda (program _infile destination _display &rest args)
                 (push (list program args default-directory
                             (getenv "CLAUDE_CONFIG_DIR"))
                       calls)
                 (when (equal (cadr args) "add-json")
                   (when (eq destination t) (insert "boom"))
                   status)))
              ((symbol-function 'message) #'ignore))
      (let ((claude-code-cli "claude"))
        (claude-code-mcp-install)
        (should (equal resolved-in (expand-file-name "~/")))
        (should (equal (reverse calls)
                       (list (list "claude"
                                   '("mcp" "remove" "--scope" "user" "emacs")
                                   (expand-file-name "~/") "/home/test/config")
                             (list "claude"
                                   (list "mcp" "add-json" "--scope" "user" "emacs"
                                         (claude-code--mcp-serialize
                                          (claude-code--mcp-server-config)))
                                   (expand-file-name "~/") "/home/test/config"))))
        (should (equal (getenv "CLAUDE_CONFIG_DIR") environment))
        (setq status 1)
        (should (equal (cadr (should-error (claude-code-mcp-install)))
                       "Cannot register the MCP server: boom"))))))

(ert-deftest claude-code-mcp-test-server-config ()
  "The registered entry runs the bridge through sh, with nothing else to it."
  (should (equal (json-parse-string
                  (claude-code--mcp-serialize (claude-code--mcp-server-config))
                  :object-type 'alist)
                 `((type . "stdio") (command . "sh")
                   (args . ["-c" ,claude-code-mcp-bridge])))))

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
  "Start `claude-code-mcp-bridge' with the cells of ENV set; return its process.
ENV holds cells as `claude-code--apply-env' takes them.  What the bridge
writes collects in its process buffer."
  (let ((process-environment
         (append (mapcar (pcase-lambda (`(,name . ,value))
                           (if value (concat name "=" value) name))
                         env)
                 process-environment)))
    (make-process :name "cc-mcp-bridge"
                  :buffer (generate-new-buffer " *cc-mcp-bridge*")
                  ;; `emacsclient' complains on stderr, which is not the
                  ;; reply stream under test.
                  :command (list "sh" "-c"
                                 (concat "exec 2>/dev/null\n"
                                         claude-code-mcp-bridge))
                  :connection-type 'pipe :noquery t
                  ;; Not the default, which reports the exit in the buffer.
                  :sentinel #'ignore)))

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

(ert-deftest claude-code-mcp-test-bridge ()
  "The bridge carries a session's handshake and calls to this Emacs and back.
A notification draws no line, so each reply lines up with its request; text
outside ASCII and a reply far past one `server.el' message arrive intact; and
the bridge names its parent as the caller, which works where its sessions/
file says, or, with none, in the directory its bridge started in."
  (skip-unless (executable-find "emacsclient"))
  (claude-code-mcp-tests--with-emacs-server
    (claude-code-mcp-tests--isolated
      (let* ((default-directory (file-name-as-directory
                                 (make-temp-file "cc-mcp-cwd" t)))
             (cwd default-directory)
             (bridge (claude-code-mcp-tests--bridge
                      (claude-code--mcp-server-env))))
        (unwind-protect
            (pcase-let ((`(,init ,tools ,eval ,big ,here)
                         (claude-code-mcp-tests--bridge-ask
                          bridge
                          (claude-code-mcp-tests--request
                           "initialize" 1
                           (list (cons 'protocolVersion "2025-06-18")))
                          (claude-code-mcp-tests--request
                           "notifications/initialized")
                          (claude-code-mcp-tests--request "tools/list" 2)
                          (claude-code-mcp-tests--request
                           "tools/call" 3
                           (list (cons 'name "eval")
                                 (cons 'arguments
                                       (list (cons 'code "(concat \"ñ\" \"✓\")")))))
                          (claude-code-mcp-tests--request
                           "tools/call" 4
                           (list (cons 'name "eval")
                                 (cons 'arguments
                                       (list (cons 'code
                                                   "(make-string 200000 ?x)")))))
                          (claude-code-mcp-tests--request
                           "tools/call" "five"
                           (list (cons 'name "eval")
                                 (cons 'arguments
                                       (list (cons 'code
                                                   "default-directory"))))))))
              (should (equal (alist-get 'protocolVersion (alist-get 'result init))
                             claude-code--mcp-protocol-version))
              (should (seq-find (lambda (tool) (equal (alist-get 'name tool) "eval"))
                                (alist-get 'tools (alist-get 'result tools))))
              (should (equal (claude-code-mcp-tests--result-text eval) "\"ñ✓\""))
              (should (= (length (claude-code-mcp-tests--result-text big)) 200002))
              (should (equal (alist-get 'id here) "five"))
              (should (equal (file-truename
                              (read (claude-code-mcp-tests--result-text here)))
                             (file-truename cwd)))
              ;; The bridge's parent is this Emacs.
              (claude-code-mcp-tests--with-session-at (emacs-pid) "/home/test/proj"
                (should (equal (claude-code-mcp-tests--result-text
                                (car (claude-code-mcp-tests--bridge-ask
                                      bridge
                                      (claude-code-mcp-tests--request
                                       "tools/call" 6
                                       (list (cons 'name "eval")
                                             (cons 'arguments
                                                   (list (cons 'code
                                                               "default-directory"))))))))
                               "\"/home/test/proj/\""))))
          (delete-process bridge)
          (kill-buffer (process-buffer bridge))
          (delete-directory cwd t))))))

(ert-deftest claude-code-mcp-test-bridge-exits-without-emacs ()
  "With no server to reach, the bridge exits on the first message and says nothing.
Claude then starts it again for the next call.  It never falls back to an
alternate editor, which would run with the MCP pipe as its input, or start a
daemon of its own."
  (skip-unless (executable-find "emacsclient"))
  (let ((bridge (claude-code-mcp-tests--bridge
                 '(("EMACS_SERVER_FILE" . "/claude-code-mcp-tests-nonexistent")
                   ("EMACS_SOCKET_NAME" . "/claude-code-mcp-tests-nonexistent")
                   ("ALTERNATE_EDITOR" . "echo")))))
    (unwind-protect
        (progn
          (process-send-string
           bridge
           (concat (json-serialize (claude-code-mcp-tests--request "tools/list" 1))
                   "\n"))
          (should (claude-code-tests--await
                   (lambda () (not (process-live-p bridge))) 10))
          (should (= (process-exit-status bridge) 1))
          (should (null (claude-code-mcp-tests--bridge-lines bridge))))
      (delete-process bridge)
      (kill-buffer (process-buffer bridge)))))

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
  "A spawned instance reaches this Emacs through the bridge, named by its PID.
An eval from it, in a worktree, sees the worktree as its cwd.  The instance
is handed the entry `claude-code-mcp-install' registers, alone, so the test
reads no user configuration and leaves none behind."
  (skip-unless (getenv "CLAUDE_CODE_INTEGRATION"))
  (require 'ghostel)
  (let* ((root (directory-file-name (expand-file-name default-directory)))
         (initialized nil)
         (probe (lambda (caller request)
                  (when (equal (alist-get 'method request) "initialize")
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
         buffer pid)
    (set-file-modes wrapper #o700)
    (advice-add 'claude-code--mcp-handle-request :before probe)
    (unwind-protect
        (claude-code-tests--with-top-level-env
          (server-start nil t)
          (setq buffer (cdr (claude-code-spawn
                             root :worktree t
                             :prompt "Respond with the single word: pong")))
          (should (claude-code-tests--await
                   (lambda () (setq pid (claude-code--instance-pid buffer))) 10))
          ;; The real CLI performs the MCP initialize handshake through the
          ;; bridge, which names the instance by its PID.
          (should (claude-code-tests--await (lambda () initialized) 45))
          (should (eql initialized pid))
          ;; Once the worktree session's sessions file lands, its real cwd is the
          ;; worktree dir; an `eval' of `default-directory' returns it.
          (should (claude-code-tests--await
                   (lambda ()
                     (let ((cwd (claude-code--pid-cwd pid)))
                       (and cwd (string-match-p "/\\.claude/worktrees/" cwd))))
                   45))
          (let* ((resp (claude-code--mcp-handle-request
                        pid
                        (claude-code-mcp-tests--request
                         "tools/call" 1
                         (list (cons 'name "eval")
                               (cons 'arguments
                                     (list (cons 'code "default-directory")))))))
                 (result (alist-get 'result resp)))
            (should (eq (alist-get 'isError result) :false))
            ;; The text is `prin1-to-string' of the bound directory (quoted).
            (should (equal (read (claude-code-mcp-tests--result-text resp))
                           (file-name-as-directory (claude-code--pid-cwd pid))))))
      (advice-remove 'claude-code--mcp-handle-request probe)
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
      (when (and pid (process-attributes pid))
        (ignore-errors (signal-process pid 'SIGKILL))
        ;; Let the process and its git children die before touching its worktree.
        (claude-code-tests--await (lambda () (not (process-attributes pid))) 5))
      (ignore-errors (server-start t t))
      (delete-file config)
      (delete-file wrapper)
      ;; Spawning with `:worktree t' leaves a locked git worktree behind that the
      ;; CLI never tears down.  Remove only worktrees that appeared during this
      ;; test; every pre-existing real worktree stays untouched.  A nil snapshot
      ;; means the pre-spawn listing failed -- a live repo always lists its main
      ;; worktree -- so skip cleanup rather than mistake every worktree for new.
      (when worktrees-before
        (claude-code-mcp-tests--remove-new-worktrees root worktrees-before)))))

(provide 'claude-code-mcp-tests)
;;; claude-code-mcp-tests.el ends here
