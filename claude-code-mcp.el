;;; claude-code-mcp.el --- MCP server exposing Emacs to Claude Code -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lautaro Emanuel

;; Author: Lautaro Emanuel

;;; Commentary:

;; A Model Context Protocol (MCP) server that lets any local `claude' act on the
;; user's live Emacs.  Claude runs `claude-code-mcp-bridge' as a stdio MCP
;; server, registered once at its user scope by `claude-code-mcp-install'; the
;; bridge hands each message to `claude-code-mcp-dispatch' through
;; `emacsclient'.  The server advertises a growing catalog of tools, documented
;; one by one in docs/mcp-tools.md:
;;
;;   * `eval' -- read and evaluate Elisp, return the printed result.
;;   * `spawn' -- start another instance in the calling session's directory.
;;
;; The file is organized in the same model/view/adapter spirit as
;; `claude-code.el':
;;
;;   * Protocol -- the pure response authority:
;;     `claude-code--mcp-response-for-body' maps a raw message to a response
;;     envelope (or nil for a notification), guarding JSON parsing before
;;     `claude-code--mcp-handle-request' dispatches the parsed request.  Both
;;     are directly unit-testable.
;;   * Registry/catalog -- the tool table and `claude-code-mcp-make-tool', plain
;;     data describing every advertised tool.
;;   * Session context -- what a tool call knows about the `claude' that made
;;     it: `claude-code--mcp-with-session' runs it in its working directory.
;;   * Bridge -- the stdio bridge, the entry point it calls, its registration,
;;     and what a launch sets so an instance's bridge reaches this Emacs.
;;
;; Session state is reached ONLY through the `claude-code.el' model; this file
;; never re-parses `~/.claude'.  A tool that acts on sessions does so through
;; the public operations API.
;;
;; SECURITY.  This server executes arbitrary Elisp for every process that can
;; reach the Emacs server.  Read the threat model in docs/architecture.md
;; before changing anything here.

;;; Code:

(require 'claude-code)
(require 'server)


;;;; Customization

(defgroup claude-code-mcp nil
  "MCP server exposing Emacs to Claude Code sessions."
  :group 'claude-code
  :prefix "claude-code-mcp-")

(defcustom claude-code-mcp-auto-approve t
  "When non-nil, launched instances call Emacs's MCP tools without prompting.
A local launch then carries `--allowedTools mcp__emacs'.  Weigh it against the
threat model in docs/architecture.md."
  :type 'boolean
  :group 'claude-code-mcp)

(defcustom claude-code-mcp-eval-timeout 10
  "Seconds before the MCP `eval' tool aborts a yielding evaluation.
The timeout interrupts only code that yields (I/O, `sit-for', process waits);
a CPU-bound infinite loop is not stopped by it."
  :type 'integer
  :group 'claude-code-mcp)


;;;; Protocol constants and errors

(defconst claude-code--mcp-protocol-version "2025-06-18"
  "The MCP protocol version this server implements and reports.")

(defconst claude-code--mcp-server-name "emacs"
  "The name `claude' knows this MCP server by.
Used as the `mcpServers' key `claude-code-mcp-install' registers and as the
`mcp__<name>' rule auto-approving its tools; the two must agree.")

(define-error 'claude-code--mcp-rpc-error
              "MCP JSON-RPC error carrying (CODE MESSAGE)")


;;;; Session context

(defvar claude-code--mcp-session-cwd nil
  "Working directory of the `claude' whose tool call is running.
Bound by `claude-code--mcp-with-session' for the duration of the call.  A
handler is passed its validated arguments and nothing else, so this is how one
that has to act on the caller's own project reaches it.")

(defmacro claude-code--mcp-with-session (caller &rest body)
  "Evaluate BODY in the context of the `claude' process whose PID is CALLER.
Its cwd is what its sessions/ file says (`claude-code--pid-cwd'), or the
current `default-directory' for a process with no such file -- through
`emacsclient', the directory the bridge was started in.  It is resolved once
and bound to `claude-code--mcp-session-cwd'.  BODY runs in a temporary buffer
whose `default-directory' is that cwd, so the buffer the request arrived in is
left alone.  That directory is best-effort context for a tool, not a sandbox:
it only affects `default-directory'-relative operations, not code using
absolute paths."
  (declare (indent 1) (debug (form body)))
  `(let ((claude-code--mcp-session-cwd
          (or (claude-code--pid-cwd ,caller)
              (directory-file-name (expand-file-name default-directory)))))
     (with-temp-buffer
       (setq default-directory
             (file-name-as-directory claude-code--mcp-session-cwd))
       ,@body)))


;;;; Tool registry and catalog
;;
;; The registry maps a tool name to a plist describing it.

(defconst claude-code--mcp-arg-types
  (list (cons 'string #'stringp)
        (cons 'boolean (lambda (value) (memq value '(t :false)))))
  "Argument types a tool may advertise, each with the predicate enforcing it.
A key is the JSON-Schema type name the wire carries, and it belongs here
exactly when `claude-code--mcp-validate-args' can hold a value to it, so the
schema never advertises a type nothing checks.  A predicate answers for the
value as the wire spells it, sentinels included, which is what leaves the
validator with no type of its own to name.")

(defvar claude-code--mcp-tools (make-hash-table :test 'equal)
  "Hash of MCP tool name (string) to its plist.
Each value is a plist with keys `:description' (string), `:args' (a list of
argument specs) and `:handler' (the function run for the tool).")

(defun claude-code-mcp-make-tool (&rest slots)
  "Define and register an MCP tool from SLOTS, returning its plist.
SLOTS is a property list with these keys:

  :name         the tool name (string) Claude calls it by;
  :description  a human-readable description of the tool (string);
  :args         a list of argument specs, each a plist with :name (string),
                :type (a symbol from `claude-code--mcp-arg-types'),
                :description (string), an optional :enum listing the values the
                argument accepts and an optional :optional flag; nil for a tool
                taking no arguments;
  :handler      the function invoked with the validated argument values in
                :args order.

The tool is stored in `claude-code--mcp-tools' under :name and also returned."
  (let ((name (plist-get slots :name))
        (description (plist-get slots :description))
        (args (plist-get slots :args))
        (handler (plist-get slots :handler)))
    (unless name (error "Tool :name is required"))
    (unless description (error "Tool :description is required"))
    (unless handler (error "Tool :handler is required"))
    ;; An arg spec reaches the wire as JSON Schema and comes back as the
    ;; contract a call is held to, so a malformed one breaks `tools/list' for
    ;; the whole catalog rather than its own tool.  Refuse it here instead.
    (dolist (arg args)
      (let ((arg-name (plist-get arg :name))
            (arg-type (plist-get arg :type))
            (enum (plist-get arg :enum)))
        (unless (and (stringp arg-name) (not (string-empty-p arg-name)))
          (error "Tool %s: every argument needs a :name" name))
        (unless (assq arg-type claude-code--mcp-arg-types)
          (error "Argument %s: no such :type %s" arg-name arg-type))
        (unless (seq-every-p #'stringp enum)
          (error "Argument %s: every :enum value must be a string" arg-name))))
    (let ((tool (list :description description :args args :handler handler)))
      (puthash name tool claude-code--mcp-tools)
      tool)))

(defun claude-code--mcp-read-form (code)
  "Return the single top-level form in the string CODE, or nil for none.
Whitespace and comments around the form are skipped.  Signal if anything else
follows it: text that reads as a second form asks the caller to wrap both in
`progn', and text that reads as no form signals the read error instead."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (with-syntax-table emacs-lisp-mode-syntax-table
      (forward-comment (point-max))
      (unless (eobp)
        (let ((form (read (current-buffer))))
          (forward-comment (point-max))
          (unless (eobp)
            (read (current-buffer))
            (error
             "`code' takes one top-level form; wrap several in (progn ...)"))
          form)))))

(defun claude-code--mcp-tool-eval (code)
  "Evaluate the single Elisp form in the string CODE; return its printed value.
Evaluation uses lexical binding and is bounded by `claude-code-mcp-eval-timeout'
seconds.  The value prints in full, whatever `print-length' and `print-level'
the user runs with."
  (with-timeout (claude-code-mcp-eval-timeout
                 (error "Evaluation timed out after %s seconds"
                        claude-code-mcp-eval-timeout))
    (let* ((value (eval (claude-code--mcp-read-form code) t))
           (print-length nil)
           (print-level nil))
      (prin1-to-string value))))

(claude-code-mcp-make-tool
 :name "eval"
 :description
 "Evaluate a single Emacs Lisp form in the user's live Emacs and return the
printed result.  Wrap several forms in (progn ...).  Evaluation uses lexical
binding.  The current buffer is a temporary one made for the call and killed
after it, never a buffer the user can see: name the buffer to act on with
(with-current-buffer BUFFER ...), or reach the one the user is looking at
with (window-buffer (selected-window))."
 :args (list (list :name "code" :type 'string
                   :description "A single Emacs Lisp form"))
 :handler #'claude-code--mcp-tool-eval)

(defun claude-code--mcp-tool-spawn (prompt name model effort worktree)
  "Handle the `spawn' tool; return the new session's id.
PROMPT, NAME, MODEL, EFFORT and WORKTREE are `claude-code-spawn' options, with
WORKTREE the name of the checkout to run in.  The root is not among them: an
instance is launched from the directory of the session that asked for it."
  (car (claude-code-spawn claude-code--mcp-session-cwd
                          :prompt prompt :name name
                          :model model :effort effort
                          :worktree worktree)))

(claude-code-mcp-make-tool
 :name "spawn"
 :description
 "Spawn another Claude Code instance in the user's Emacs and return its session
id.  It runs in the calling session's own directory -- or, when asked for a
worktree, in a worktree of it, which carries none of the caller's uncommitted
work.  The instance takes no window of its own: the user reaches it
through the Emacs sessions view.  An id means the instance was launched, not
that it survived startup."
 :args (list (list :name "prompt" :type 'string :optional t
                   :description
                   "Initial prompt; without one the instance starts idle.")
             (list :name "name" :type 'string :optional t
                   :description
                   "Display name for the session, shown in the sessions view.")
             (list :name "model" :type 'string :optional t
                   :description
                   "Model alias (opus, sonnet, haiku, fable) or full name.")
             (list :name "effort" :type 'string :optional t
                   :description
                   "Reasoning effort level: low, medium, high, xhigh or max.")
             (list :name "worktree" :type 'string :optional t
                   :description
                   "Name of the git worktree to run the instance in.  A name
that already exists runs the instance in that worktree, which may carry an
earlier session's commits; any other name builds a fresh one.  Use letters,
digits, dots, hyphens and underscores only -- a name the CLI rejects kills the
instance at startup."))
 :handler #'claude-code--mcp-tool-spawn)


;;;; Protocol layer (pure, socket-free)

(defun claude-code--mcp-result (id payload)
  "Return a JSON-RPC success envelope alist for request ID carrying PAYLOAD."
  (list (cons 'jsonrpc "2.0")
        (cons 'id id)
        (cons 'result payload)))

(defun claude-code--mcp-error (id code message)
  "Return a JSON-RPC error envelope alist for request ID with CODE and MESSAGE.
Pass `:null' as ID for a request that could not be parsed."
  (list (cons 'jsonrpc "2.0")
        (cons 'id id)
        (cons 'error (list (cons 'code code) (cons 'message message)))))

(defun claude-code--mcp-args->properties (args)
  "Return the JSON-Schema `properties' alist for argument specs ARGS."
  (mapcar (lambda (arg)
            (let ((name (plist-get arg :name))
                  (type (plist-get arg :type))
                  (desc (plist-get arg :description))
                  (enum (plist-get arg :enum)))
              (cons (intern name)
                    (append (list (cons 'type (symbol-name type)))
                            (when desc (list (cons 'description desc)))
                            (when enum (list (cons 'enum (vconcat enum))))))))
          args))

(defun claude-code--mcp-required-args (args)
  "Return the required argument names in ARGS as a JSON array vector.
An argument is required unless its spec carries a non-nil :optional flag."
  (vconcat (delq nil (mapcar (lambda (arg)
                               (unless (plist-get arg :optional)
                                 (plist-get arg :name)))
                             args))))

(defun claude-code--mcp-tool-descriptor (name tool)
  "Return the `tools/list' descriptor alist for TOOL registered under NAME."
  (let ((args (plist-get tool :args)))
    (list (cons 'name name)
          (cons 'description (plist-get tool :description))
          (cons 'inputSchema
                (list (cons 'type "object")
                      (cons 'properties (claude-code--mcp-args->properties args))
                      (cons 'required (claude-code--mcp-required-args args)))))))

(defun claude-code--mcp-initialize ()
  "Return the `initialize' result payload.
Reports `claude-code--mcp-protocol-version'."
  (list (cons 'protocolVersion claude-code--mcp-protocol-version)
        (cons 'capabilities
              (list (cons 'tools (list (cons 'listChanged :false)))))
        (cons 'serverInfo
              (list (cons 'name "claude-code.el")
                    (cons 'version "0.1.0")))))

(defun claude-code--mcp-tools-list ()
  "Return the `tools/list' result payload built from the tool catalog."
  (list (cons 'tools
              (vconcat
               (cl-loop for name being the hash-keys of claude-code--mcp-tools
                        using (hash-values tool)
                        collect (claude-code--mcp-tool-descriptor name tool))))))

(defun claude-code--mcp-reject (format-string &rest args)
  "Signal a -32602 `claude-code--mcp-rpc-error' reading FORMAT-STRING and ARGS.
This is the answer to a call that does not hold to the schema its tool
advertises, which is the caller's to fix."
  (signal 'claude-code--mcp-rpc-error
          (list -32602 (apply #'format format-string args))))

(defun claude-code--mcp-validate-args (arg-specs arguments)
  "Return values from ARGUMENTS ordered to match ARG-SPECS.
ARGUMENTS is the parsed `arguments' object (an alist), or nil when the call
carried none.  An argument the call left out, and one it sent as JSON null, is
unanswered: required, that is an error, and optional it reads as nil.

Every value a handler receives holds to the schema its tool advertises -- the
spec's :type, and its :enum where one is named -- and anything else signals a
`claude-code--mcp-rpc-error' with code -32602 naming the argument, so a caller
that ignored the schema is told what its call got wrong instead of the handler
acting on it.  Which wire spellings a type accepts is the type's own business,
in `claude-code--mcp-arg-types': a boolean accepts JSON false, which is how a
required one is answered with no, and reads as nil.  An empty string is a value
only a string can carry, and given for an optional argument it reads as nil, so
a handler passing values on to a process emits no option with an empty value."
  (when (eq arguments :null)
    (setq arguments nil))
  (unless (listp arguments)
    (claude-code--mcp-reject "Arguments must be an object"))
  (mapcar (lambda (spec)
            (let* ((name (plist-get spec :name))
                   (type (plist-get spec :type))
                   (enum (plist-get spec :enum))
                   (optional (plist-get spec :optional))
                   (cell (assq (intern name) arguments))
                   (value (cdr cell)))
              (cond
               ((or (null cell) (eq value :null))
                (unless optional
                  (claude-code--mcp-reject "Missing required argument: %s" name)))
               ((not (funcall (alist-get type claude-code--mcp-arg-types
                                         #'ignore)
                              value))
                (claude-code--mcp-reject "Argument %s must be of type %s"
                                         name type))
               ;; Past its predicate the value is one the type accepts, so what
               ;; is left to shape is reachable for that one type alone.
               ((eq value :false) nil)
               ((and optional (equal value "")) nil)
               ((and enum (not (member value enum)))
                (claude-code--mcp-reject "Argument %s must be one of: %s"
                                         name (string-join enum ", ")))
               (t value))))
          arg-specs))

(defun claude-code--mcp-tools-call (caller params)
  "Run the tool named in PARAMS for CALLER and return its result payload.
CALLER is the PID of the calling `claude'.
PARAMS is the `tools/call' params alist carrying `name' and `arguments', and
must be an object -- JSON null standing for the one a call did not send.
Signals a `claude-code--mcp-rpc-error' for a PARAMS of any other shape, for an
unknown tool, and for arguments that do not hold to the tool's schema; a tool
that itself errors yields an `isError' result rather than crashing the server."
  (when (eq params :null)
    (setq params nil))
  (unless (listp params)
    (claude-code--mcp-reject "Params must be an object"))
  (let* ((name (alist-get 'name params))
         (tool (and (stringp name) (gethash name claude-code--mcp-tools))))
    (unless tool
      (signal 'claude-code--mcp-rpc-error
              (list -32602 (format "Unknown tool: %s" name))))
    (let ((call-args (claude-code--mcp-validate-args
                      (plist-get tool :args)
                      (alist-get 'arguments params))))
      (condition-case err
          (let ((result (claude-code--mcp-with-session caller
                          (apply (plist-get tool :handler) call-args))))
            (list (cons 'content
                        (vector (list (cons 'type "text")
                                      (cons 'text (format "%s" result)))))
                  (cons 'isError :false)))
        ((error quit)
         (list (cons 'content
                     (vector (list (cons 'type "text")
                                   (cons 'text
                                         (format "Error: %s"
                                                 (error-message-string err))))))
               (cons 'isError t)))))))

(defun claude-code--mcp-handle-request (caller request)
  "Return the JSON-RPC response alist for REQUEST, or nil for a notification.
CALLER is the PID of the calling `claude'.  REQUEST is the parsed JSON-RPC
request object (an alist).  A request with no `id' is a notification and
yields nil.  A non-object REQUEST -- a JSON array or bare scalar -- is answered
with a -32600 Invalid Request; any `claude-code--mcp-rpc-error', other error or
quit becomes a JSON-RPC error envelope echoing the request `id'."
  (if (not (listp request))
      (claude-code--mcp-error :null -32600 "Invalid Request")
    (let ((id (alist-get 'id request))
          (method (alist-get 'method request))
          (params (alist-get 'params request)))
      (if (null id)
          nil
        (condition-case err
            (claude-code--mcp-result
             id
             (pcase method
               ("initialize" (claude-code--mcp-initialize))
               ("tools/list" (claude-code--mcp-tools-list))
               ("tools/call" (claude-code--mcp-tools-call caller params))
               (_ (signal 'claude-code--mcp-rpc-error
                          (list -32601 (format "Method not found: %s" method))))))
          (claude-code--mcp-rpc-error
           (claude-code--mcp-error id (nth 1 err) (nth 2 err)))
          ((error quit)
           (claude-code--mcp-error
            id -32603
            (format "Internal error: %s" (error-message-string err)))))))))

(defun claude-code--mcp-response-for-body (caller body)
  "Return the JSON-RPC response alist for BODY, or nil for a notification.
CALLER is the PID of the calling `claude'.  BODY is one raw JSON-RPC message;
one that is not valid JSON is answered with a -32700 error.  Dispatch errors
never escape `claude-code--mcp-handle-request', so the `json-error' handler
here fires only for the parse."
  (condition-case nil
      (claude-code--mcp-handle-request
       caller (json-parse-string body :object-type 'alist))
    (json-error (claude-code--mcp-error :null -32700 "Parse error"))))


;;;; Bridge

(defconst claude-code-mcp-bridge
  "while IFS= read -r line; do
  req=$(printf %s \"$line\" | base64 | tr -d '\\n')
  out=$(emacsclient -a false --eval \"(progn (require 'claude-code-mcp) (claude-code-mcp-dispatch \\\"$req\\\" $PPID))\") || exit 1
  [ \"$out\" = nil ] || { printf %s \"$out\" | tr -d '\"' | base64 --decode; echo; }
done"
  "The stdio MCP server Claude runs to reach Emacs, an sh script.
It hands each JSON-RPC line to `claude-code-mcp-dispatch' through `emacsclient',
naming its parent, the `claude' that started it, as the caller.  It exits once
Emacs cannot be reached; Claude starts it again for its next call.")

(defun claude-code--mcp-serialize (envelope)
  "Serialize response ENVELOPE alist to a JSON string for the wire."
  (json-serialize envelope))

(defun claude-code-mcp-dispatch (request pid)
  "Answer REQUEST, a base64 JSON-RPC message from the `claude' whose PID is PID.
Return the response as base64 JSON, or nil for a notification.  This is what
`claude-code-mcp-bridge' calls, and it never signals or quits: an error
reaching `server.el' would end the bridge, and a quit would read as no reply."
  (when-let* ((response
               (claude-code--mcp-response-for-body
                pid (condition-case nil
                        (decode-coding-string (base64-decode-string request)
                                              'utf-8)
                      ((error quit) "")))))
    (base64-encode-string
     (condition-case nil
         (claude-code--mcp-serialize response)
       ((error quit)
        (claude-code--mcp-serialize
         (claude-code--mcp-error (alist-get 'id response) -32603
                                 "Internal error: unserializable response"))))
     t)))

(defun claude-code--mcp-server-config ()
  "Return the `mcpServers' entry that runs `claude-code-mcp-bridge'."
  (list (cons 'type "stdio")
        (cons 'command "sh")
        (cons 'args (vector "-c" claude-code-mcp-bridge))))

;;;###autoload
(defun claude-code-mcp-install ()
  "Register the Emacs MCP server at Claude's user scope.
It lands in the config dir instances launch with, replacing any user-scope
server of the same name there, and every `claude' sharing that dir reaches
Emacs from then on."
  (interactive)
  (with-environment-variables (("CLAUDE_CONFIG_DIR" (claude-code--config-env)))
    (let* ((default-directory (expand-file-name "~/"))
           (program (claude-code--resolve-executable claude-code-cli)))
      ;; Its status is ignored: there may be nothing to remove.
      (call-process program nil nil nil "mcp" "remove" "--scope" "user"
                    claude-code--mcp-server-name)
      (with-temp-buffer
        (unless (eql 0 (call-process program nil t nil "mcp" "add-json"
                                     "--scope" "user" claude-code--mcp-server-name
                                     (claude-code--mcp-serialize
                                      (claude-code--mcp-server-config))))
          (error "Cannot register the MCP server: %s"
                 (string-trim (buffer-string)))))))
  (message "Registered the `%s' MCP server with Claude"
           claude-code--mcp-server-name))

(defvar claude-code--mcp-warned nil
  "Non-nil once a launch has warned that this Emacs runs no server.")

(defun claude-code--mcp-server-env ()
  "Return the environment pointing `emacsclient' at this Emacs's server.
A list of cells as `claude-code--apply-env' takes them: the file the server
listens on, whether it runs yet or not, in the variable for its kind, with the
other variable unset.  The first call to find this Emacs running no server
warns, once per session: instances then reach it only once its server starts,
and reach the other Emacs while one holds the server's name."
  (unless (or (process-live-p server-process) claude-code--mcp-warned)
    (setq claude-code--mcp-warned t)
    (display-warning
     'claude-code-mcp
     (if (server-running-p)
         (format-message "Another Emacs's server holds the name `%s', so \
instances launched here reach that Emacs's MCP tools; give this Emacs a \
`server-name' of its own and start its server" server-name)
       (substitute-command-keys
        "No Emacs server is running, so instances cannot reach Emacs's MCP \
tools until one starts; start it with \\[server-start]"))))
  (let ((file (expand-file-name server-name (if server-use-tcp
                                                server-auth-dir
                                              server-socket-dir))))
    (if server-use-tcp
        (list (cons "EMACS_SERVER_FILE" file) (list "EMACS_SOCKET_NAME"))
      (list (cons "EMACS_SOCKET_NAME" file) (list "EMACS_SERVER_FILE")))))

(defun claude-code--mcp-wiring (buffer)
  "Return what points the instance BUFFER hosts at this Emacs, or nil.
Nil when BUFFER's directory, where Ghostel runs the instance, is remote: its
bridge runs on that host.  Otherwise (ARGS . ENV): ARGS auto-approves the
server's tools when `claude-code-mcp-auto-approve' is non-nil, and ENV is
`claude-code--mcp-server-env'."
  (unless (file-remote-p (buffer-local-value 'default-directory buffer))
    (cons (and claude-code-mcp-auto-approve
               (list "--allowedTools"
                     (concat "mcp__" claude-code--mcp-server-name)))
          (claude-code--mcp-server-env))))

(provide 'claude-code-mcp)
;;; claude-code-mcp.el ends here
