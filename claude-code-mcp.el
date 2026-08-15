;;; claude-code-mcp.el --- MCP server exposing Emacs to Claude Code -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lautaro Emanuel

;; Author: Lautaro Emanuel

;;; Commentary:

;; A Model Context Protocol (MCP) server that lets the `claude' CLI instances
;; this package spawns act on the user's live Emacs.  One HTTP server runs per
;; Emacs, shared by every session; each session is keyed by its spawn UUID in
;; the request path `/mcp/<uuid>'.  The server advertises a growing catalog of
;; tools, documented one by one in docs/mcp-tools.md:
;;
;;   * `eval' -- read and evaluate Elisp, return the printed result.
;;
;; The file is organized in the same model/view/adapter spirit as
;; `claude-code.el':
;;
;;   * Transport -- quarantined `web-server' glue: it frames HTTP requests and
;;     writes replies.  This is the ONLY layer that touches sockets, and it
;;     builds no envelopes of its own.
;;   * Protocol -- the pure, socket-free response authority:
;;     `claude-code--mcp-response-for-body' maps a raw POST body to a response
;;     envelope (or nil for a notification), guarding body integrity and JSON
;;     parsing before `claude-code--mcp-handle-request' dispatches the parsed
;;     request.  Both are directly unit-testable.
;;   * Registry/catalog -- the tool table and `claude-code-mcp-make-tool', plain
;;     data describing every advertised tool.
;;
;; Session state is reached ONLY through the `claude-code.el' model
;; (`claude-code--session-cwd'); this file never re-parses `~/.claude'.
;;
;; SECURITY.  This server executes arbitrary Elisp on behalf of a local process
;; and its only real boundary is the loopback bind.  Read the threat model in
;; docs/architecture.md before changing anything here.

;;; Code:

(require 'claude-code)
(require 'web-server)
(require 'eieio)


;;;; Customization

(defgroup claude-code-mcp nil
  "MCP server exposing Emacs to spawned Claude Code sessions."
  :group 'claude-code
  :prefix "claude-code-mcp-")

(defcustom claude-code-mcp-enabled t
  "When non-nil, spawned `claude' instances connect to the Emacs MCP server.
Set to nil to spawn instances with no `--mcp-config' at all."
  :type 'boolean
  :group 'claude-code-mcp)

(defcustom claude-code-mcp-auto-approve t
  "When non-nil, auto-approve every registered MCP tool for spawned instances.
This adds an `--allowedTools' entry for each tool the server advertises, so
Claude calls them without prompting.  Weigh it against the threat model in
docs/architecture.md."
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
  "The name spawned `claude' instances know this MCP server by.
Used as the `mcpServers' key in the `--mcp-config' blob and as the
`mcp__<name>__<tool>' prefix when auto-approving tools; the two must agree.")

(define-error 'claude-code--mcp-rpc-error
              "MCP JSON-RPC error carrying (CODE MESSAGE)")


;;;; Tool registry and catalog
;;
;; The registry maps a tool name to a plist describing it.

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
                :type (a symbol such as `string'), :description (string) and an
                optional :optional flag; nil for a tool taking no arguments;
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
    (let ((tool (list :description description :args args :handler handler)))
      (puthash name tool claude-code--mcp-tools)
      tool)))

(defun claude-code--mcp-tool-eval (code)
  "Evaluate CODE, a string of Elisp, and return the last value as a string.
Reads and evaluates every top-level form in CODE with lexical binding, under a
`claude-code-mcp-eval-timeout'-second timeout, and returns `prin1-to-string'
of the final form's value.  Reading happens in a buffer under the Elisp syntax
table, so `forward-comment' skips whitespace and comments between and after
forms; a malformed form -- including an incomplete final form -- surfaces its
read error to the caller, which reports it as an MCP tool error."
  (with-timeout (claude-code-mcp-eval-timeout
                 (error "Evaluation timed out after %s seconds"
                        claude-code-mcp-eval-timeout))
    (with-temp-buffer
      (insert code)
      (goto-char (point-min))
      (let ((value nil))
        (with-syntax-table emacs-lisp-mode-syntax-table
          (while (progn (forward-comment (point-max)) (not (eobp)))
            (setq value (eval (read (current-buffer)) t))))
        (prin1-to-string value)))))

(claude-code-mcp-make-tool
 :name "eval"
 :description
 "Evaluate Emacs Lisp in the user's live Emacs and return the printed result.
CODE may hold several top-level forms; the value of the last form is returned."
 :args (list (list :name "code" :type 'string
                   :description "Emacs Lisp source to read and evaluate."))
 :handler #'claude-code--mcp-tool-eval)


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
                  (desc (plist-get arg :description)))
              (cons (intern name)
                    (append (list (cons 'type (symbol-name type)))
                            (when desc (list (cons 'description desc)))))))
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
              (list (cons 'tools (list (cons 'listChanged :json-false)))))
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

(defun claude-code--mcp-validate-args (arg-specs arguments)
  "Return values from ARGUMENTS ordered to match ARG-SPECS.
ARGUMENTS is the parsed `arguments' object (an alist).  JSON false and null
arrive from the parser as `:json-false'/`:false' and `:null', all of which are
non-nil in Lisp, so they are normalized to nil before a handler sees them --
a boolean argument therefore reads as a plain Lisp truth value.  Signals a
`claude-code--mcp-rpc-error' with code -32602 when a required argument is
missing."
  (mapcar (lambda (spec)
            (let* ((name (plist-get spec :name))
                   (optional (plist-get spec :optional))
                   (value (alist-get (intern name) arguments)))
              (when (memq value '(:json-false :false :null))
                (setq value nil))
              (when (and (not optional) (null value))
                (signal 'claude-code--mcp-rpc-error
                        (list -32602 (format "Missing required argument: %s"
                                             name))))
              value))
          arg-specs))

(defmacro claude-code--mcp-with-session (session-id &rest body)
  "Evaluate BODY with `default-directory' bound to SESSION-ID's real cwd.
The directory comes from `claude-code--session-cwd'; when it is nil (an
unknown id) `default-directory' is left unchanged.  This is best-effort
context for a tool, not a sandbox: it only affects `default-directory'-relative
operations, not code using absolute paths."
  (declare (indent 1))
  `(let ((default-directory
          (let ((cwd (claude-code--session-cwd ,session-id)))
            (if cwd (file-name-as-directory cwd) default-directory))))
     ,@body))

(defun claude-code--mcp-tools-call (session-id params)
  "Run the tool named in PARAMS for SESSION-ID and return its result payload.
PARAMS is the `tools/call' params alist carrying `name' and `arguments'.
Signals a `claude-code--mcp-rpc-error' for an unknown tool or a missing
required argument; a tool that itself errors yields an `isError' result rather
than crashing the server."
  (let* ((name (alist-get 'name params))
         (tool (and (stringp name) (gethash name claude-code--mcp-tools))))
    (unless tool
      (signal 'claude-code--mcp-rpc-error
              (list -32602 (format "Unknown tool: %s" name))))
    (let ((call-args (claude-code--mcp-validate-args
                      (plist-get tool :args)
                      (alist-get 'arguments params))))
      (condition-case err
          (let ((result (claude-code--mcp-with-session session-id
                          (apply (plist-get tool :handler) call-args))))
            (list (cons 'content
                        (vector (list (cons 'type "text")
                                      (cons 'text (format "%s" result)))))
                  (cons 'isError :json-false)))
        ((error quit)
         (list (cons 'content
                     (vector (list (cons 'type "text")
                                   (cons 'text
                                         (format "Error: %s"
                                                 (error-message-string err))))))
               (cons 'isError t)))))))

(defun claude-code--mcp-handle-request (session-id request)
  "Return the JSON-RPC response alist for REQUEST, or nil for a notification.
SESSION-ID is the path token identifying the calling session.  REQUEST is the
parsed JSON-RPC request object (an alist).  A request with no `id' is a
notification and yields nil (the transport still acknowledges it).  A non-object
REQUEST -- a JSON array or bare scalar -- is answered with a -32600 Invalid
Request; any `claude-code--mcp-rpc-error' or other error becomes a JSON-RPC
error envelope echoing the request `id'."
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
               ("tools/call" (claude-code--mcp-tools-call session-id params))
               (_ (signal 'claude-code--mcp-rpc-error
                          (list -32601 (format "Method not found: %s" method))))))
          (claude-code--mcp-rpc-error
           (claude-code--mcp-error id (nth 1 err) (nth 2 err)))
          (error
           (claude-code--mcp-error
            id -32603
            (format "Internal error: %s" (error-message-string err)))))))))

(defun claude-code--mcp-response-for-body (session-id body declared-length)
  "Return the JSON-RPC response alist for BODY, or nil for a notification.
SESSION-ID is the path token identifying the calling session.  BODY is the
raw POST body; DECLARED-LENGTH is the request's Content-Length value as a
string, or nil when the header is absent.  A BODY whose byte count disagrees
with DECLARED-LENGTH is answered with a -32700 error rather than parsed:
web-server frames the body by the header blank line, not Content-Length, so a
body split across packets arrives truncated.  A body that is not valid JSON
is likewise a -32700.  Dispatch errors never escape
`claude-code--mcp-handle-request', so the `json-error' handler here fires
only for the parse."
  (if (and declared-length
           (/= (string-bytes body) (string-to-number declared-length)))
      (claude-code--mcp-error :null -32700 "Truncated request body")
    (condition-case nil
        (claude-code--mcp-handle-request
         session-id (json-parse-string body :object-type 'alist))
      (json-error (claude-code--mcp-error :null -32700 "Parse error")))))


;;;; Transport (web-server glue)

(defvar claude-code--mcp-server nil
  "The live `ws-server' object for the MCP server, or nil when stopped.")

(defun claude-code--mcp-port ()
  "Return the TCP port the MCP server listens on, or nil when stopped."
  (and claude-code--mcp-server
       (process-contact (ws-process claude-code--mcp-server) :service)))

(defun claude-code--mcp-serialize (envelope)
  "Serialize response ENVELOPE alist to a JSON string for the wire.
Uses `:json-false' for JSON false and `:null' for JSON null so envelope
values round-trip to the shapes the MCP client expects."
  (json-serialize envelope :false-object :json-false :null-object :null))

(defun claude-code--mcp-send (process response)
  "Write RESPONSE alist to PROCESS as an HTTP 200 JSON reply and close it."
  (ws-response-header process 200 '("Content-Type" . "application/json"))
  (ws-send process (claude-code--mcp-serialize response))
  (throw 'close-connection nil))

(defun claude-code--mcp-send-empty (process)
  "Acknowledge a notification on PROCESS with an empty HTTP 202 and close it."
  (ws-response-header process 202)
  (throw 'close-connection nil))

(defun claude-code--mcp-handle (request)
  "Handle one MCP HTTP POST REQUEST from the `web-server' transport.
Reads the session id, body and declared Content-Length off REQUEST, maps
them to a response through `claude-code--mcp-response-for-body', and writes
it back -- an empty 202 when there is none (a notification)."
  (with-slots (process headers body) request
    (let* ((path (cdr (assoc :POST headers)))
           (session-id (and path
                            (string-match "^/mcp/\\([^/]+\\)" path)
                            (match-string 1 path)))
           (response (claude-code--mcp-response-for-body
                      session-id body
                      (cdr (assoc :CONTENT-LENGTH headers)))))
      (if response
          (claude-code--mcp-send process response)
        (claude-code--mcp-send-empty process)))))

(defun claude-code--mcp-handle-get (request)
  "Answer a Streamable-HTTP GET REQUEST on the MCP endpoint with HTTP 405.
A client MAY open a server-to-client SSE stream with GET; we push no
server-initiated messages, so the spec requires 405 Method Not Allowed here to
signal that no stream is offered.  Every JSON-RPC message travels over POST."
  (with-slots (process) request
    (ws-response-header process 405 '("Content-Length" . "0"))
    (throw 'close-connection nil)))

(defun claude-code--mcp-ensure-server ()
  "Ensure the MCP server is running and return its port, or nil.
Returns nil when `claude-code-mcp-enabled' is nil.  Starting is idempotent: a
live server's port is returned without opening a second listener."
  (when claude-code-mcp-enabled
    (unless (and claude-code--mcp-server
                 (process-live-p (ws-process claude-code--mcp-server)))
      (setq claude-code--mcp-server
            (ws-start
             (list (cons (cons :GET "^/mcp/") #'claude-code--mcp-handle-get)
                   (cons (cons :POST "^/mcp/") #'claude-code--mcp-handle))
             0 nil :host "127.0.0.1")))
    (claude-code--mcp-port)))


;;;; Lifecycle and CLI wiring

(defun claude-code--mcp-allowed-tools ()
  "Return every registered tool as an `mcp__<server>__<tool>' identifier list.
These are the identifiers `claude' recognizes on `--allowedTools'; the server
prefix is `claude-code--mcp-server-name'."
  (cl-loop for name being the hash-keys of claude-code--mcp-tools
           collect (format "mcp__%s__%s" claude-code--mcp-server-name name)))

(defun claude-code--mcp-cli-args (id)
  "Return CLI arguments connecting session ID to the MCP server, or nil.
Starts the server if needed.  Returns nil when MCP is disabled or the server
could not start.  Otherwise returns `--mcp-config' with an inline JSON blob
pointing at `/mcp/ID', plus an `--allowedTools' entry for every registered tool
when `claude-code-mcp-auto-approve' is non-nil.  The JSON is passed to `claude'
execvp-style, so it needs no shell escaping."
  (when-let* ((port (claude-code--mcp-ensure-server)))
    (let ((config (json-serialize
                   (list (cons 'mcpServers
                               (list (cons (intern claude-code--mcp-server-name)
                                           (list (cons 'type "http")
                                                 (cons 'url
                                                       (format
                                                        "http://127.0.0.1:%d/mcp/%s"
                                                        port id))))))))))
      (append (list "--mcp-config" config)
              (when-let* ((allowed (and claude-code-mcp-auto-approve
                                        (claude-code--mcp-allowed-tools))))
                (list "--allowedTools" (string-join allowed ",")))))))

;;;###autoload
(defun claude-code-mcp-stop ()
  "Stop the Emacs MCP server if it is running.
A no-op when no server is live, so it is safe to call unconditionally."
  (interactive)
  (when claude-code--mcp-server
    (ignore-errors (ws-stop claude-code--mcp-server))
    (setq claude-code--mcp-server nil)))

(add-hook 'claude-code-last-instance-exit-hook #'claude-code-mcp-stop)

(provide 'claude-code-mcp)
;;; claude-code-mcp.el ends here
