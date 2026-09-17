;;; java-kit-debug.el --- Java debugging through JDTLS and Dape  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This module starts JDTLS-backed Dape sessions and manages project-scoped
;; Hot Code Replace state.  It extends only Dape's public event and request
;; interfaces and is loaded on demand by java-kit's debug commands.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'jsonrpc)
(require 'subr-x)
(require 'java-kit)

(declare-function dape "dape" (config &optional skip-compile))
(declare-function dape-handle-event "dape" (connection event body))
(declare-function dape-kill "dape" (connection &optional callback with-disconnect))
(declare-function dape-request
                  "dape" (connection command arguments &optional callback))
(defvar dape-request-timeout)

(defcustom java-kit-debug-console "integratedTerminal"
  "Console used by Java launch sessions.

An integrated terminal accepts program input.  The internal console sends
program output to Dape's REPL and cannot accept standard input."
  :type '(choice (const "integratedTerminal") (const "internalConsole"))
  :group 'java-kit)

(defcustom java-kit-debug-build-before-launch t
  "Whether Java launches wait for a successful JDTLS incremental build."
  :type 'boolean
  :group 'java-kit)

(defcustom java-kit-debug-build-timeout 120
  "Maximum seconds to wait for the build preceding a Java launch."
  :type 'natnum
  :group 'java-kit)

(defcustom java-kit-hot-code-replace-mode 'auto
  "Control Hot Code Replace for java-kit Java debug sessions.

Value `auto' requests replacement after Java Debug reports a completed build,
`manual' enables only `java-kit-hot-replace', and `never' disables both."
  :type '(choice (const :tag "After completed builds" auto)
                 (const :tag "Manual command only" manual)
                 (const :tag "Disabled" never))
  :group 'java-kit)

(defcustom java-kit-java-debug-request-timeout 30000
  "Java Debug request timeout in milliseconds.

The value is sent to Java Debug and also bounds session initialization,
cancellation and Dape Hot Code Replace requests."
  :type 'natnum
  :group 'java-kit)

(cl-defstruct (java-kit-debug--session
               (:constructor java-kit-debug--session-create))
  "State for one Java debug session started by java-kit."
  connection state hcr-pending hcr-in-progress resume-after-hcr
  scope launch-id timer)

(defvar java-kit-debug--sessions (make-hash-table :test #'equal)
  "Java debug sessions started by java-kit, keyed by build-module root.")

(defvar java-kit--pending-session nil
  "Session waiting for its Dape startup notification.")

(defvar java-kit-debug--handlers-installed nil
  "Whether java-kit's Dape request and event extensions are installed.")

(defun java-kit--debug-session-for-connection (connection)
  "Return the debug session associated with CONNECTION."
  (cl-loop for session being the hash-values of java-kit-debug--sessions
           when (eq connection (java-kit-debug--session-connection session))
           return session))

(defun java-kit-debug--session (context)
  "Return the live Java debug session for CONTEXT, if any."
  (let* ((scope (java-kit--module-scope context))
         (session (gethash scope java-kit-debug--sessions)))
    (cond
     ((and session
           (jsonrpc-running-p
            (java-kit-debug--session-connection session)))
      session)
     (session
      (java-kit--debug-cleanup session)
      nil))))

(defun java-kit--debug-cleanup (session)
  "Release SESSION's resources and registrations, safely more than once."
  (when-let* ((timer (java-kit-debug--session-timer session)))
    (cancel-timer timer)
    (setf (java-kit-debug--session-timer session) nil))
  (when (eq session java-kit--pending-session)
    (setq java-kit--pending-session nil))
  (let ((scope (java-kit-debug--session-scope session)))
    (when (eq session (gethash scope java-kit-debug--sessions))
      (remhash scope java-kit-debug--sessions))))

(defun java-kit-debug--forget-connection (connection)
  "Forget the java-kit debug session using CONNECTION."
  (when-let* ((session (java-kit--debug-session-for-connection connection)))
    (java-kit--debug-cleanup session)))

(defun java-kit-debug--attach-config (target-port)
  "Return a Java attach configuration for TARGET-PORT."
  (list :type "java" :request "attach"
        :hostName "localhost" :port target-port))

(defun java-kit--debug-environment (entries)
  "Convert environment ENTRIES to the keyword plist accepted by Dape."
  (let (result)
    (dolist (entry entries result)
      (pcase-let ((`(,name . ,value)
                   (java-kit--parse-environment-entry entry)))
        (setq result (plist-put result (intern (concat ":" name)) value))))))

(defun java-kit--debug-launch-options (context environment)
  "Return common launch options for CONTEXT and ENVIRONMENT entries."
  (append
   (list :type "java" :request "launch"
         :cwd (plist-get context :module-root)
         :javaExec (java-kit--project-java-program context)
         :console java-kit-debug-console)
   (when (plist-get context :debug-project-name)
     (list :projectName (plist-get context :debug-project-name)))
   (when environment
     (list :env (java-kit--debug-environment environment)))))

(defun java-kit--debug-start (context config)
  "Start CONFIG in CONTEXT with repeatable Dape session preparation."
  (java-kit-debug--ensure-dape)
  (let ((pending java-kit--pending-session))
    (condition-case error-data
        (dape (append (list 'fn #'java-kit--debug-prepare
                            'java-kit-context context
                            'java-kit-source buffer-file-name)
                      config))
      (error
       (when (and java-kit--pending-session
                  (not (eq pending java-kit--pending-session)))
         (java-kit--debug-cleanup java-kit--pending-session))
       (signal (car error-data) (cdr error-data))))))

(defun java-kit--debug-prepare (config)
  "Prepare fresh runtime resources for CONFIG on each Dape start or restart."
  (when java-kit--pending-session
    (user-error "Another java-kit Java debug session is initializing"))
  (let* ((context (plist-get config 'java-kit-context))
         (source (plist-get config 'java-kit-source))
         (session (java-kit-debug--session-create
                   :scope (java-kit--module-scope context)
                   :launch-id (symbol-name (gensym "java-kit-"))))
         (deadline (+ (float-time)
                      (max 1.0 (/ java-kit-java-debug-request-timeout 1000.0))))
         ready)
    (unwind-protect
        (progn
          ;; Synchronous Eglot requests can run another launch callback.
          (setq java-kit--pending-session session)
          (when (java-kit-debug--session context)
            (user-error "A Java session is active for this module; stop or restart it"))
          (with-temp-buffer
            (setq default-directory (plist-get context :module-root)
                  major-mode 'java-mode)
            (with-current-buffer (if source (find-file-noselect source) (current-buffer))
              (setq config (plist-put config 'port
                                      (java-kit-debug--adapter-port (java-kit--eglot-server))))))
          (setq config (plist-put config :java-kit-session-id
                                  (java-kit-debug--session-launch-id session)))
          (setf (java-kit-debug--session-timer session)
                (run-at-time
                 1 1 (lambda ()
                       (let ((connection (java-kit-debug--session-connection session)))
                         (cond
                          ((and connection (not (jsonrpc-running-p connection)))
                           (java-kit--debug-cleanup session))
                          ((and (eq session java-kit--pending-session)
                                (> (float-time) deadline))
                           (message "Java debug session initialization timed out")
                           (java-kit--debug-cleanup session)
                           (when connection
                             (let ((dape-request-timeout
                                    (max 1.0 (/ java-kit-java-debug-request-timeout 1000.0))))
                               (dape-kill connection)))))))))
          (setq ready t)
          config)
      (unless ready (java-kit--debug-cleanup session)))))

(defun java-kit--debug-launch (server context class config-function)
  "Build CLASS in CONTEXT with SERVER, then launch CONFIG-FUNCTION's result.

The build is asynchronous.  Resolve the launch configuration only after a
successful build and while the originating source buffer still exists."
  (let ((source (current-buffer))
        (file buffer-file-name))
    (cl-labels
        ((launch ()
           (if (not (and (buffer-live-p source)
                         (equal file (buffer-file-name source))))
               (message "Java launch cancelled: source buffer was closed or renamed")
             (with-current-buffer source
               (when (buffer-modified-p)
                 (message "Java launch uses compiled classes; unsaved edits are not included"))
               (java-kit--debug-start context (funcall config-function))))))
      (if (not java-kit-debug-build-before-launch)
          (launch)
        (save-some-buffers
         t (lambda ()
             (and buffer-file-name
                  (file-in-directory-p buffer-file-name
                                       (or (plist-get context :root)
                                           (plist-get context :module-root))))))
        (jsonrpc-async-request
         server :workspace/executeCommand
         (list :command "vscode.java.buildWorkspace"
               :arguments
               (vector (json-serialize
                        (list :mainClass class
                              :projectName (plist-get context :debug-project-name)
                              :isFullBuild :false))))
         :deferred :java-kit-debug-build
         :timeout java-kit-debug-build-timeout
         :success-fn
         (lambda (status)
           (if (equal status "SUCCEED")
               (condition-case error-data
                   (launch)
                 (error (message "Java launch failed: %s"
                                 (error-message-string error-data))))
             (message "Java launch cancelled: build returned %s" status)))
         :error-fn (lambda (error-data)
                     (message "Java launch cancelled: build failed: %s"
                              error-data))
         :timeout-fn (lambda ()
                       (message "Java launch cancelled: build timed out")))))))

(defun java-kit--debug-main-target (server context file)
  "Resolve FILE's main class and JDTLS project using SERVER and CONTEXT."
  (let* ((items (java-kit--jdtls-execute
                 server "vscode.java.resolveMainClass"
                 (list (eglot-path-to-uri (plist-get context :module-root)))))
         (matches (seq-filter
                   (lambda (item)
                     (when-let* ((path (plist-get item :filePath)))
                       (equal (file-truename file) (file-truename path))))
                   items)))
    (unless matches
      (user-error "JDTLS found no main class in %s" file))
    (let* ((choices (mapcar (lambda (item)
                             (cons (format "%s (%s)"
                                           (plist-get item :mainClass)
                                           (plist-get item :projectName)) item))
                           matches))
           (item (if (length= choices 1) (cdar choices)
                   (cdr (assoc (completing-read "Main class: " choices nil t)
                               choices)))))
      (unless (and (stringp (plist-get item :mainClass))
                   (stringp (plist-get item :projectName)))
        (user-error "JDTLS returned an invalid main class"))
      item)))

(defun java-kit--debug-project-name (server file)
  "Resolve FILE's actual JDTLS project name through SERVER."
  (cl-labels
      ((type-position (symbols)
         (seq-some
          (lambda (symbol)
            (if (memq (plist-get symbol :kind) java-kit--lsp-type-kinds)
                (plist-get (plist-get symbol :selectionRange) :start)
              (type-position (java-kit--symbol-children symbol))))
          symbols)))
    (let* ((position (type-position (java-kit--document-symbols server file)))
           (element (when position
                      (java-kit--jdtls-execute
                       server "vscode.java.resolveElementAtSelection"
                       (list (eglot-path-to-uri file)
                             (plist-get position :line)
                             (plist-get position :character)))))
           (name (plist-get element :projectName)))
      (unless (and (stringp name) (not (string-empty-p name)))
        (user-error "JDTLS could not resolve the project for %s" file))
      name)))

(defun java-kit-debug--settings-json ()
  "Return java-kit's Java Debug settings as JSON."
  (json-serialize
   (list :hotCodeReplace (symbol-name java-kit-hot-code-replace-mode)
         :jdwpRequestTimeout java-kit-java-debug-request-timeout
         :logLevel "INFO")))

(defun java-kit-debug--sync-settings (server)
  "Send java-kit's Java Debug settings to JDTLS SERVER."
  (condition-case error-data
      (java-kit--jdtls-execute
       server "vscode.java.updateDebugSettings"
       (list (java-kit-debug--settings-json)))
    (error
     (message "java-kit could not update Java Debug settings: %s"
              (error-message-string error-data))
     nil)))

(defun java-kit--debug-request (request connection command arguments &optional callback)
  "Associate an owned launch with CONNECTION before calling REQUEST.
Forward COMMAND, ARGUMENTS and CALLBACK, removing java-kit's local marker.
Cancel obsolete launches without forwarding them to the adapter."
  (let ((id (and (member command '(:launch :attach "launch" "attach"))
                 (plist-get arguments :java-kit-session-id)))
        (session java-kit--pending-session))
    (if (and id (not (and session
                         (equal id (java-kit-debug--session-launch-id session)))))
        ;; Dape disables request timeouts around launch; bound cancellation too.
        (let ((dape-request-timeout
               (max 1.0 (/ java-kit-java-debug-request-timeout 1000.0))))
          (dape-kill connection
                     (when callback
                       (lambda (_body _error)
                         (funcall callback nil "Java debug session initialization expired")))))
      (when id
        (setq arguments (copy-sequence arguments))
        (cl-remf arguments :java-kit-session-id)
        (setf (java-kit-debug--session-connection session) connection))
      (funcall request connection command arguments callback))))

(defun java-kit-debug--initialized (connection)
  "Associate initialized Dape CONNECTION with the pending session."
  (when-let* ((session java-kit--pending-session)
              ((eq connection (java-kit-debug--session-connection session))))
    (setq java-kit--pending-session nil)
    (setf (java-kit-debug--session-state session) 'running)
    (puthash (java-kit-debug--session-scope session) session java-kit-debug--sessions)
    session))

(defun java-kit-debug--finish-hot-replace (session body error-data)
  "Finish SESSION's Hot Code Replace with BODY or ERROR-DATA."
  (setf (java-kit-debug--session-hcr-in-progress session) nil)
  (let ((changed-count (length (or (plist-get body :changedClasses) []))))
    (cond
     (error-data
      (message "Hot Code Replace failed: %s" error-data))
     ((plist-get body :errorMessage)
      (message "Hot Code Replace failed: %s"
               (plist-get body :errorMessage)))
     (t
      (message
       "Hot Code Replace completed; Java Debug reported %d changed class%s"
       changed-count (if (= changed-count 1) "" "es")))))
  (when (java-kit-debug--session-resume-after-hcr session)
    (setf (java-kit-debug--session-resume-after-hcr session) nil)
    (let ((connection (java-kit-debug--session-connection session)))
      (dape-request
       connection :continue '(:threadId 0)
       (lambda (_body resume-error)
         (if resume-error
             (message "Hot Code Replace resume failed: %s" resume-error)
           (dape-handle-event connection 'continued
                              '(:allThreadsContinued t))))))))

(defun java-kit-debug--send-hot-replace (session)
  "Send Java Debug's redefine-classes request for SESSION."
  (setf (java-kit-debug--session-hcr-pending session) nil
        (java-kit-debug--session-hcr-in-progress session) t)
  (let ((dape-request-timeout
         (max 1.0 (/ java-kit-java-debug-request-timeout 1000.0))))
    (dape-request
     (java-kit-debug--session-connection session)
     :redefineClasses nil
     (lambda (body error-data)
       (java-kit-debug--finish-hot-replace session body error-data)))))

(defun java-kit-debug--queue-hot-replace (session interactive)
  "Pause SESSION before replacement, reporting errors for INTERACTIVE use."
  (setf (java-kit-debug--session-hcr-pending session) t
        (java-kit-debug--session-resume-after-hcr session) nil)
  (message "Hot Code Replace queued; pausing the debuggee")
  (dape-request
   (java-kit-debug--session-connection session)
   :pause '(:threadId 0)
   (lambda (_body error-data)
     (when error-data
       (setf (java-kit-debug--session-hcr-pending session) nil
             (java-kit-debug--session-resume-after-hcr session) nil)
       (message "%s Hot Code Replace pause failed: %s"
                (if interactive "Manual" "Automatic") error-data)))))

(defun java-kit-debug--request-hot-replace (session &optional interactive)
  "Request Hot Code Replace for SESSION.

When INTERACTIVE is non-nil, report duplicate or disabled requests as user
errors."
  (cond
   ((eq java-kit-hot-code-replace-mode 'never)
    (if interactive
        (user-error "Hot Code Replace is disabled")
      nil))
   ((or (java-kit-debug--session-hcr-pending session)
        (java-kit-debug--session-hcr-in-progress session))
    (if interactive
        (user-error "Hot Code Replace is already pending")
      nil))
   ((eq (java-kit-debug--session-state session) 'stopped)
    (java-kit-debug--send-hot-replace session))
   (t
    (java-kit-debug--queue-hot-replace session interactive))))

(defun java-kit-debug--stopped (connection body)
  "Record CONNECTION's stop event BODY and run a queued replacement."
  (when-let* ((session (java-kit--debug-session-for-connection connection)))
    (setf (java-kit-debug--session-state session) 'stopped)
    (unless (equal (plist-get body :reason) "pause")
      (setf (java-kit-debug--session-resume-after-hcr session) nil))
    (when (java-kit-debug--session-hcr-pending session)
      (setf (java-kit-debug--session-resume-after-hcr session)
            (and (equal (plist-get body :reason) "pause")
                 (equal (plist-get body :threadId) 0)
                 (eq (plist-get body :allThreadsStopped) t)))
      (java-kit-debug--send-hot-replace session))))

(defun java-kit-debug--continued (connection)
  "Record that Dape CONNECTION continued."
  (when-let* ((session (java-kit--debug-session-for-connection connection)))
    (setf (java-kit-debug--session-state session) 'running)))

(defun java-kit-debug--hot-code-replace-event (connection body)
  "Handle Java Debug Hot Code Replace event BODY for CONNECTION."
  (when-let* ((session (java-kit--debug-session-for-connection connection)))
    (pcase (plist-get body :changeType)
      ("ERROR"
       (message "Hot Code Replace failed: %s"
                (or (plist-get body :message) "unknown error")))
      ("WARNING"
       (message "Hot Code Replace warning: %s"
                (or (plist-get body :message) "")))
      ("BUILD_COMPLETE"
       (when (eq java-kit-hot-code-replace-mode 'auto)
         (java-kit-debug--request-hot-replace session))))))

(defun java-kit-debug--install-event-handlers ()
  "Install java-kit's public Dape request and event extensions once."
  (unless java-kit-debug--handlers-installed
    (advice-add 'dape-request :around #'java-kit--debug-request)
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql initialized)) _body)
      (java-kit-debug--initialized connection))
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql stopped)) body)
      (java-kit-debug--stopped connection body))
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql continued)) _body)
      (java-kit-debug--continued connection))
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql hotcodereplace)) body)
      (java-kit-debug--hot-code-replace-event connection body))
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql terminated)) _body)
      (java-kit-debug--forget-connection connection))
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql exited)) _body)
      (java-kit-debug--forget-connection connection))
    (setq java-kit-debug--handlers-installed t)))

(defun java-kit-debug--ensure-dape ()
  "Load Dape or report that the optional integration is unavailable."
  (unless (or (featurep 'dape) (require 'dape nil t))
    (user-error "Dape is not installed"))
  (java-kit-debug--install-event-handlers))

(defun java-kit-debug--adapter-port (server)
  "Ask JDTLS SERVER to start Java Debug and return its adapter port."
  (java-kit-debug--sync-settings server)
  (let ((port
         (java-kit--jdtls-execute
          server "vscode.java.startDebugSession" nil)))
    (unless (natnump port)
      (user-error
       "JDTLS did not start Java Debug; configure its debug bundle"))
    port))

;;;###autoload
(defun java-kit-dape-attach (port)
  "Attach Dape through JDTLS to a JVM listening on PORT."
  (interactive
   (list
    (read-number
     "JDWP port: "
     (if (boundp 'java-kit-spring-boot-debug-port)
         (symbol-value 'java-kit-spring-boot-debug-port)
       5005))))
  (java-kit--debug-start (java-kit-project-context)
                         (java-kit-debug--attach-config port)))

(defun java-kit-debug--main-config (context class module-paths class-paths)
  "Return a main launch config using CONTEXT.

CLASS is launched with MODULE-PATHS and CLASS-PATHS."
  (append (java-kit--debug-launch-options context java-kit-main-environment)
         (list :mainClass class
               :modulePaths (vconcat module-paths)
               :classPaths (vconcat class-paths)
               :args (combine-and-quote-strings java-kit-main-arguments)
               :vmArgs (combine-and-quote-strings
                        java-kit-main-jvm-arguments))))

(defun java-kit-debug--resolved-classpaths (server context class)
  "Resolve debug paths from SERVER for CLASS in CONTEXT."
  (let ((response
         (java-kit--jdtls-execute
          server "vscode.java.resolveClasspath"
          (list class (plist-get context :debug-project-name)))))
    (unless (and (vectorp response) (= (length response) 2))
      (user-error "JDTLS Java Debug returned invalid classpaths"))
    (list (append (aref response 0) nil)
          (append (aref response 1) nil))))

;;;###autoload
(defun java-kit-debug-main ()
  "Debug the current Java main class through JDTLS and Dape."
  (interactive)
  (let* ((file (java-kit--current-java-file))
         (server (java-kit--eglot-server))
         (context (java-kit-project-context file))
         (target (java-kit--debug-main-target server context file))
         (class (plist-get target :mainClass)))
    (setq context (plist-put context :debug-project-name
                             (plist-get target :projectName)))
    (java-kit--debug-launch
     server context class
     (lambda ()
       (let ((paths (java-kit-debug--resolved-classpaths server context class)))
         (java-kit-debug--main-config
          context class (car paths) (cadr paths)))))))

(defun java-kit-debug--test-config (context classpaths class method)
  "Return a JUnit launch config using CONTEXT.

CLASSPATHS contain project outputs, while CLASS and METHOD select the test."
  (let ((launch (java-kit--junit-console-launch classpaths class method)))
    (append (java-kit--debug-launch-options context java-kit-test-environment)
           (list :mainClass "org.junit.platform.console.ConsoleLauncher"
                 :classPaths (vector (car launch))
                 :args (combine-and-quote-strings (cdr launch))
                 :vmArgs (combine-and-quote-strings
                          java-kit-test-jvm-arguments)))))

;;;###autoload
(defun java-kit-debug-test ()
  "Debug the JUnit class or method at point through JDTLS and Dape."
  (interactive)
  (let* ((file (java-kit--current-java-file))
         (server (java-kit--eglot-server)))
    (unless (java-kit--jdtls-test-file-p server file)
      (user-error "JDTLS does not identify the current file as a test"))
    (let* ((context (java-kit-project-context file))
           (target (java-kit--current-target server file)))
      (setq context (plist-put context :debug-project-name
                               (java-kit--debug-project-name server file)))
      (java-kit--debug-launch
       server context (plist-get target :class)
       (lambda ()
         (java-kit-debug--test-config
          context (java-kit--jdtls-classpaths server file "test" context)
          (plist-get target :class) (plist-get target :method)))))))

;;;###autoload
(defun java-kit-hot-replace ()
  "Replace changed classes in the current module's Java debug session."
  (interactive)
  (java-kit-debug--ensure-dape)
  (let* ((context (java-kit-project-context))
         (session (java-kit-debug--session context)))
    (unless session
      (user-error "No java-kit Java debug session is active for %s"
                  (plist-get context :name)))
    (java-kit-debug--request-hot-replace session t)))

(provide 'java-kit-debug)
;;; java-kit-debug.el ends here
