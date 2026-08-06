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
(declare-function dape-continue "dape" (connection))
(declare-function dape-request
                  "dape" (connection command arguments &optional callback))
(defvar dape-request-timeout)

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

The value is sent to Java Debug and also bounds Dape Hot Code Replace requests."
  :type 'natnum
  :group 'java-kit)

(cl-defstruct (java-kit-debug--session
               (:constructor java-kit-debug--session-create))
  "State for one Java debug session started by java-kit."
  connection state hcr-pending hcr-in-progress resume-after-hcr)

(defvar java-kit-debug--sessions (make-hash-table :test #'equal)
  "Java debug sessions started by java-kit, keyed by build-module root.")

(defvar java-kit-debug--pending-context nil
  "Project context waiting for a Dape initialized event.")

(defvar java-kit-debug--handlers-installed nil
  "Whether java-kit's Dape event methods have been installed.")

(defun java-kit-debug--session-entry-for-connection (connection)
  "Return the scope and debug session associated with CONNECTION."
  (let (entry)
    (maphash
     (lambda (scope session)
       (when (eq connection (java-kit-debug--session-connection session))
         (setq entry (cons scope session))))
     java-kit-debug--sessions)
    entry))

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
      (remhash scope java-kit-debug--sessions)
      nil))))

(defun java-kit-debug--forget-connection (connection)
  "Forget the java-kit debug session using CONNECTION."
  (when-let* ((entry
               (java-kit-debug--session-entry-for-connection connection)))
    (remhash (car entry) java-kit-debug--sessions)))

(defun java-kit-debug--attach-config (adapter-port target-port)
  "Return a Java attach configuration for ADAPTER-PORT and TARGET-PORT."
  (list 'port adapter-port
        :type "java"
        :request "attach"
        :hostName "localhost"
        :port target-port))

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

(defun java-kit-debug--initialized (connection)
  "Associate initialized Dape CONNECTION with its pending project context."
  (when-let* ((context java-kit-debug--pending-context))
    (setq java-kit-debug--pending-context nil)
    (let ((session
           (java-kit-debug--session-create
            :connection connection :state 'running)))
      (puthash (java-kit--module-scope context)
               session java-kit-debug--sessions)
      session)))

(defun java-kit-debug--expire-pending-context (context)
  "Forget pending Dape CONTEXT when it has not initialized in time."
  (when (eq context java-kit-debug--pending-context)
    (setq java-kit-debug--pending-context nil)))

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
    (condition-case resume-error
        (dape-continue (java-kit-debug--session-connection session))
      (error
       (message "Hot Code Replace completed, but resume failed: %s"
                (error-message-string resume-error))))))

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
        (java-kit-debug--session-resume-after-hcr session) t)
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

(defun java-kit-debug--stopped (connection)
  "Record that Dape CONNECTION stopped and run a queued replacement."
  (when-let* ((entry
               (java-kit-debug--session-entry-for-connection connection))
              (session (cdr entry)))
    (setf (java-kit-debug--session-state session) 'stopped)
    (when (java-kit-debug--session-hcr-pending session)
      (java-kit-debug--send-hot-replace session))))

(defun java-kit-debug--continued (connection)
  "Record that Dape CONNECTION continued."
  (when-let* ((entry
               (java-kit-debug--session-entry-for-connection connection)))
    (setf (java-kit-debug--session-state (cdr entry)) 'running)))

(defun java-kit-debug--hot-code-replace-event (connection body)
  "Handle Java Debug Hot Code Replace event BODY for CONNECTION."
  (when-let* ((entry
               (java-kit-debug--session-entry-for-connection connection))
              (session (cdr entry)))
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
  "Install java-kit's public Dape event extensions once."
  (unless java-kit-debug--handlers-installed
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql initialized)) _body)
      (java-kit-debug--initialized connection))
    (cl-defmethod dape-handle-event :after
      (connection (_event (eql stopped)) _body)
      (java-kit-debug--stopped connection))
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

(defun java-kit-debug--start-dape (config context)
  "Start Dape with CONFIG and associate it with project CONTEXT."
  (java-kit-debug--ensure-dape)
  (when java-kit-debug--pending-context
    (user-error "Another java-kit Java debug session is initializing"))
  (setq java-kit-debug--pending-context context)
  (run-at-time
   (max 1.0 (/ java-kit-java-debug-request-timeout 1000.0)) nil
   #'java-kit-debug--expire-pending-context context)
  (condition-case error-data
      (dape config)
    (error
     (when (eq context java-kit-debug--pending-context)
       (setq java-kit-debug--pending-context nil))
     (signal (car error-data) (cdr error-data)))))

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
  (let* ((context (java-kit-project-context))
         (server (java-kit--eglot-server))
         (adapter-port (java-kit-debug--adapter-port server)))
    (java-kit-debug--start-dape
     (java-kit-debug--attach-config adapter-port port) context)))

(defun java-kit-debug--main-config
    (adapter-port context class module-paths class-paths)
  "Return a main launch config using ADAPTER-PORT and CONTEXT.

CLASS is launched with MODULE-PATHS and CLASS-PATHS."
  (let ((config
         (list 'port adapter-port
               :type "java"
               :request "launch"
               :mainClass class
               :projectName (plist-get context :name)
               :javaExec (java-kit--project-java-program context)
               :cwd (plist-get context :module-root)
               :modulePaths (vconcat module-paths)
               :classPaths (vconcat class-paths)
               :args (combine-and-quote-strings java-kit-main-arguments)
               :vmArgs (combine-and-quote-strings
                        java-kit-main-jvm-arguments)
               :console "integratedConsole")))
    (when java-kit-main-environment
      (setq config
            (plist-put config :env
                       (mapcar #'java-kit--parse-environment-entry
                               java-kit-main-environment))))
    config))

(defun java-kit-debug--resolved-classpaths (server context class)
  "Resolve debug paths from SERVER for CLASS in CONTEXT."
  (let ((response
         (java-kit--jdtls-execute
          server "vscode.java.resolveClasspath"
          (list class (plist-get context :name)))))
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
         (target (java-kit--current-target server file))
         (class (plist-get target :class))
         (paths
          (java-kit-debug--resolved-classpaths server context class))
         (adapter-port (java-kit-debug--adapter-port server)))
    (java-kit-debug--start-dape
     (java-kit-debug--main-config
      adapter-port context class (car paths) (cadr paths))
     context)))

(defun java-kit-debug--test-config
    (adapter-port context classpaths class method)
  "Return a JUnit launch config using ADAPTER-PORT and CONTEXT.

CLASSPATHS contain project outputs, while CLASS and METHOD select the test."
  (let* ((jar (expand-file-name java-kit-junit-console-jar))
         (selector (if method (concat class "#" method) class))
         (arguments
          (list "execute" "--class-path"
                (mapconcat #'identity classpaths path-separator)
                (if method "--select-method" "--select-class")
                selector)))
    (unless (file-regular-p jar)
      (user-error
       "JUnit Console JAR is missing: %s; run `java-kit-install-junit'" jar))
    (let ((config
           (list 'port adapter-port
                 :type "java"
                 :request "launch"
                 :mainClass "org.junit.platform.console.ConsoleLauncher"
                 :projectName (plist-get context :name)
                 :javaExec (java-kit--project-java-program context)
                 :cwd (plist-get context :module-root)
                 :classPaths (vconcat (cons jar classpaths))
                 :args (combine-and-quote-strings arguments)
                 :vmArgs (combine-and-quote-strings
                          java-kit-test-jvm-arguments)
                 :console "integratedConsole")))
      (when java-kit-test-environment
        (setq config
              (plist-put config :env
                         (mapcar #'java-kit--parse-environment-entry
                                 java-kit-test-environment))))
      config)))

;;;###autoload
(defun java-kit-debug-test ()
  "Debug the JUnit class or method at point through JDTLS and Dape."
  (interactive)
  (let* ((file (java-kit--current-java-file))
         (server (java-kit--eglot-server)))
    (unless (java-kit--jdtls-test-file-p server file)
      (user-error "JDTLS does not identify the current file as a test"))
    (let* ((context (java-kit-project-context file))
           (target (java-kit--current-target server file))
           (classpaths
            (java-kit--jdtls-classpaths server file "test" context))
           (adapter-port (java-kit-debug--adapter-port server)))
      (java-kit-debug--start-dape
       (java-kit-debug--test-config
        adapter-port context classpaths
        (plist-get target :class)
        (plist-get target :method))
       context))))

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
