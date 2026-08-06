;;; java-kit-app.el --- Spring Boot and Tomcat lifecycle tools  -*- lexical-binding: t; -*-

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

;; This module manages Spring Boot and Tomcat processes started by java-kit.
;; Processes are isolated by build-module root.  Stop and restart operations
;; never discover or signal unrelated JVMs.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'seq)
(require 'subr-x)
(require 'java-kit)

(declare-function notifications-notify "notifications" (&rest parameters))

(defcustom java-kit-app-notifications t
  "Whether application lifecycle commands send desktop notifications."
  :type 'boolean
  :group 'java-kit)

(defcustom java-kit-app-auto-debug-attach nil
  "Whether a debug service should invoke Dape after it becomes ready."
  :type 'boolean
  :group 'java-kit)

(defcustom java-kit-spring-boot-port 8080
  "Expected Spring Boot HTTP port displayed in status messages.

This value does not override the application's own server configuration."
  :type 'natnum
  :group 'java-kit)

(defcustom java-kit-spring-boot-debug-port 5005
  "JDWP port used when starting Spring Boot in debug mode."
  :type 'natnum
  :group 'java-kit)

(defcustom java-kit-spring-boot-jvm-arguments nil
  "Additional JVM arguments used to start a Spring Boot JAR."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-spring-boot-arguments nil
  "Application arguments appended when starting a Spring Boot JAR."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-tomcat-home #'java-kit-detect-tomcat-home
  "Tomcat installation used by deployment and lifecycle commands.

The value may be a directory or a function receiving the project context and
returning a directory.  The default detects `CATALINA_HOME', a `catalina.sh'
on PATH, or an unambiguous platform-standard installation."
  :type '(choice (const :tag "Auto-detect" java-kit-detect-tomcat-home)
                 (const :tag "Not configured" nil)
                 (directory :tag "Tomcat home")
                 (function :tag "Resolver function"))
  :group 'java-kit)

(defcustom java-kit-tomcat-base nil
  "Tomcat runtime instance used by deployment and lifecycle commands.

The value may be nil, a directory, or a function receiving the project
context and returning a directory.  Nil uses `CATALINA_BASE' when set and
otherwise uses `java-kit-tomcat-home'.  Set this separately for Linux package
layouts that split executable files and writable runtime state."
  :type '(choice (const :tag "Environment or Tomcat home" nil)
                 (directory :tag "Tomcat base")
                 (function :tag "Resolver function"))
  :group 'java-kit)

(defcustom java-kit-tomcat-port 8080
  "Expected Tomcat HTTP port displayed in status messages."
  :type 'natnum
  :group 'java-kit)

(defcustom java-kit-tomcat-debug-port 8000
  "JDWP port used when starting Tomcat in debug mode."
  :type 'natnum
  :group 'java-kit)

(defcustom java-kit-tomcat-context-name nil
  "Optional deployed Tomcat context name without the `.war' suffix.

When nil, preserve the built WAR file name.  The value may also be a function
receiving the project context and returning a string or nil."
  :type '(choice (const :tag "Use artifact name" nil)
                 (string :tag "Context name")
                 (function :tag "Resolver function"))
  :group 'java-kit)

(cl-defstruct (java-kit-app--service
               (:constructor java-kit-app--service-create))
  "State for one java-kit-managed process."
  key kind context process status debug port debug-port source-buffer home base
  ready-regexp output-tail on-success)

(defvar java-kit-app--services (make-hash-table :test #'equal)
  "Project-scoped services started by java-kit.")

(defvar java-kit-app--mode-line nil
  "Mode-line text describing live java-kit services.")
(put 'java-kit-app--mode-line 'risky-local-variable t)

(defvar java-kit-app--mode-line-entry '("" java-kit-app--mode-line)
  "Entry installed in `global-mode-string' while services are live.")

(defun java-kit-app--key (context kind)
  "Return the registry key for CONTEXT and service KIND."
  (cons kind (java-kit--module-scope context)))

(defun java-kit-app--live-service (context kind)
  "Return the live KIND service for CONTEXT, if any."
  (let* ((key (java-kit-app--key context kind))
         (service (gethash key java-kit-app--services)))
    (cond
     ((and service
           (process-live-p (java-kit-app--service-process service)))
      service)
     (service
      (remhash key java-kit-app--services)
      nil))))

(defun java-kit-app--service-label (service)
  "Return a concise mode-line label for SERVICE."
  (let ((name (pcase (java-kit-app--service-kind service)
                ('spring-boot "Boot")
                ('tomcat "Tomcat")
                (_ "Java")))
        (status (java-kit-app--service-status service))
        (port (java-kit-app--service-port service)))
    (format "%s:%s%s"
            name
            (if (eq status 'running) port status)
            (if (java-kit-app--service-debug service) "*" ""))))

(defun java-kit-app--refresh-mode-line ()
  "Refresh the global summary of java-kit application services."
  (let (services)
    (maphash
     (lambda (_key service)
       (when (and (memq (java-kit-app--service-kind service)
                         '(spring-boot tomcat))
                  (process-live-p (java-kit-app--service-process service)))
         (push service services)))
     java-kit-app--services)
    (setq java-kit-app--mode-line
          (when services
            (format " JKit[%s]"
                    (mapconcat #'java-kit-app--service-label services ","))))
    (if services
        (unless (member java-kit-app--mode-line-entry global-mode-string)
          (setq global-mode-string
                (append global-mode-string
                        (list java-kit-app--mode-line-entry))))
      (setq global-mode-string
            (delete java-kit-app--mode-line-entry global-mode-string)))
    (force-mode-line-update t)))

(defun java-kit-app--notify (title body)
  "Report lifecycle event BODY under TITLE."
  (message "%s: %s" title body)
  (when (and java-kit-app-notifications
             (or (featurep 'notifications)
                 (require 'notifications nil t))
             (fboundp 'notifications-notify))
    (condition-case nil
        (notifications-notify :title title :body body)
      (error nil))))

(defun java-kit-app--auto-attach (service)
  "Attach Dape when configured for debug SERVICE."
  (when (and java-kit-app-auto-debug-attach
             (java-kit-app--service-debug service))
    (let ((source (java-kit-app--service-source-buffer service))
          (port (java-kit-app--service-debug-port service)))
      (if (buffer-live-p source)
          (with-current-buffer source
            (condition-case error-data
                (java-kit-dape-attach port)
              (error
               (message "java-kit Dape attach failed: %s"
                        (error-message-string error-data)))))
        (message "java-kit cannot auto-attach: source buffer was closed")))))

(defun java-kit-app--mark-ready (service)
  "Mark SERVICE as running and report readiness."
  (unless (eq (java-kit-app--service-status service) 'running)
    (setf (java-kit-app--service-status service) 'running)
    (java-kit-app--refresh-mode-line)
    (java-kit-app--notify
     (pcase (java-kit-app--service-kind service)
       ('spring-boot "Spring Boot")
       ('tomcat "Tomcat")
       (_ "Java service"))
     (format "ready on port %d%s"
             (java-kit-app--service-port service)
             (if (java-kit-app--service-debug service)
                 (format "; JDWP %d"
                         (java-kit-app--service-debug-port service))
               "")))
    (java-kit-app--auto-attach service)))

(defun java-kit-app--process-filter (service process output)
  "Insert PROCESS OUTPUT and update readiness for SERVICE."
  (compilation-filter process output)
  (when-let* ((regexp (java-kit-app--service-ready-regexp service)))
    (let* ((combined (concat (or (java-kit-app--service-output-tail service)
                                 "")
                             output))
           (tail-start (max 0 (- (length combined) 4096))))
      (setf (java-kit-app--service-output-tail service)
            (substring combined tail-start))
      (when (string-match-p regexp combined)
        (java-kit-app--mark-ready service)))))

(defun java-kit-app--process-sentinel (service process event)
  "Handle PROCESS EVENT for SERVICE."
  (when (memq (process-status process) '(exit signal failed closed))
    (let* ((key (java-kit-app--service-key service))
           (current (gethash key java-kit-app--services))
           (stopping (process-get process 'java-kit-app-stopping))
           (success (and (eq (process-status process) 'exit)
                         (zerop (process-exit-status process)))))
      (when (eq current service)
        (remhash key java-kit-app--services))
      (java-kit-app--refresh-mode-line)
      (cond
       ((and success (java-kit-app--service-on-success service))
        (funcall (java-kit-app--service-on-success service)))
       ((and (not stopping) (not success))
        (java-kit-app--notify
         "java-kit process"
         (format "%s failed: %s"
                 (java-kit-app--service-kind service)
                 (string-trim event))))))))

(cl-defun java-kit-app--start-process
    (context kind command status
             &key ready-regexp debug port debug-port home base environment
             source-buffer on-success)
  "Start COMMAND for CONTEXT and register it as KIND with STATUS.

READY-REGEXP marks the process running.  DEBUG, PORT, and DEBUG-PORT describe
its endpoints.  HOME and BASE identify an external server installation and
runtime instance.  ENVIRONMENT overrides its subprocess environment,
SOURCE-BUFFER retains editor context, and ON-SUCCESS runs after a successful
finite process."
  (when (java-kit-app--live-service context kind)
    (user-error "%s is already active for %s"
                kind (plist-get context :name)))
  (unless (java-kit--command-available-p (car command))
    (user-error "Program is not executable: %s" (car command)))
  (let* ((key (java-kit-app--key context kind))
         (scope (java-kit--module-scope context))
         (buffer-name (format "*java-kit %s:%s*"
                              kind (plist-get context :name)))
         (buffer (get-buffer-create buffer-name))
         (process-environment
          (or environment (java-kit-project-process-environment context)))
         service)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (compilation-mode)
      (setq default-directory scope))
    (let ((process
           (make-process
            :name (format "java-kit-%s-%s"
                          kind (substring (secure-hash 'sha1 scope) 0 8))
            :buffer buffer
            :command command
            :connection-type 'pipe
            :noquery t
            :filter (lambda (process output)
                      (java-kit-app--process-filter service process output))
            :sentinel (lambda (process event)
                        (java-kit-app--process-sentinel
                         service process event)))))
      (setq service
            (java-kit-app--service-create
             :key key :kind kind :context context :process process
             :status status :debug debug :port port :debug-port debug-port
             :source-buffer (or source-buffer (current-buffer))
             :home home :base base
             :ready-regexp ready-regexp :output-tail ""
             :on-success on-success))
      (puthash key service java-kit-app--services)
      (java-kit-app--refresh-mode-line)
      (display-buffer buffer)
      service)))

(defun java-kit-app--stop (context kind)
  "Stop java-kit's tracked KIND process for CONTEXT."
  (if-let* ((service (java-kit-app--live-service context kind))
            (process (java-kit-app--service-process service)))
      (progn
        (process-put process 'java-kit-app-stopping t)
        (delete-process process)
        (remhash (java-kit-app--service-key service) java-kit-app--services)
        (java-kit-app--refresh-mode-line)
        (message "Stopped %s for %s" kind (plist-get context :name))
        t)
    (message "No java-kit %s process is active for %s"
             kind (plist-get context :name))
    nil))

(defun java-kit-app--build-arguments (context purpose)
  "Return build arguments for CONTEXT and PURPOSE."
  (append
   (java-kit--build-command context)
   (pcase (cons (plist-get context :build-system) purpose)
     (`(maven . spring-boot) '("package" "-DskipTests"))
     (`(gradle . spring-boot) '("bootJar" "-x" "test"))
     (`(maven . tomcat) '("package" "-DskipTests"))
     (`(gradle . tomcat) '("war" "-x" "test"))
     (_ (user-error "Unsupported build system for %s" purpose)))))

(defun java-kit-app--newest-artifact (directory regexp excluded-regexp)
  "Return the newest file in DIRECTORY matching REGEXP but not EXCLUDED-REGEXP."
  (when (file-directory-p directory)
    (car
     (sort
      (seq-remove
       (lambda (file)
         (and excluded-regexp
              (string-match-p excluded-regexp
                              (file-name-nondirectory file))))
       (directory-files directory t regexp))
      (lambda (first second)
        (time-less-p
         (file-attribute-modification-time (file-attributes second))
         (file-attribute-modification-time (file-attributes first))))))))

(defun java-kit-app--spring-boot-jar (context)
  "Return the built Spring Boot JAR for CONTEXT."
  (let* ((root (plist-get context :module-root))
         (build-system (plist-get context :build-system))
         (directory (pcase build-system
                      ('maven (expand-file-name "target" root))
                      ('gradle (expand-file-name "build/libs" root))))
         (jar (java-kit-app--newest-artifact
               directory "\\.jar\\'" "\\(?:-plain\\|-original\\)\\.jar\\'")))
    (or jar
        (user-error "No runnable Spring Boot JAR found under %s" directory))))

(defun java-kit-app--spring-command (context jar debug)
  "Return the Spring Boot command for CONTEXT, JAR, and DEBUG mode."
  (append
   (list (java-kit--project-java-program context))
   java-kit-spring-boot-jvm-arguments
   (when debug
     (list
      (format
       "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=%d"
       java-kit-spring-boot-debug-port)))
   (list "-jar" jar)
   java-kit-spring-boot-arguments))

(defun java-kit-app--start-spring (context debug source-buffer)
  "Start a built Spring Boot app for CONTEXT in DEBUG mode from SOURCE-BUFFER."
  (let ((jar (java-kit-app--spring-boot-jar context)))
    (java-kit-app--start-process
     context 'spring-boot
     (java-kit-app--spring-command context jar debug)
     'starting
     :ready-regexp "Started .* in"
     :debug debug
     :port java-kit-spring-boot-port
     :debug-port (and debug java-kit-spring-boot-debug-port)
     :source-buffer source-buffer)))

;;;###autoload
(defun java-kit-spring-boot-run (&optional debug)
  "Build and run the current Spring Boot module.

With prefix argument DEBUG, enable JDWP on
`java-kit-spring-boot-debug-port'."
  (interactive "P")
  (let ((context (java-kit-project-context))
        (source-buffer (current-buffer)))
    (when (java-kit-app--live-service context 'spring-boot)
      (user-error "Spring Boot is already active for %s"
                  (plist-get context :name)))
    (java-kit-app--start-process
     context 'spring-build
     (java-kit-app--build-arguments context 'spring-boot)
     'building
     :source-buffer source-buffer
     :on-success
     (lambda ()
       (java-kit-app--start-spring context debug source-buffer)))))

;;;###autoload
(defun java-kit-spring-boot-stop ()
  "Stop the Spring Boot process started for the current module."
  (interactive)
  (java-kit-app--stop (java-kit-project-context) 'spring-boot))

;;;###autoload
(defun java-kit-spring-boot-restart (&optional debug)
  "Restart the current Spring Boot module, rebuilding it first.

With prefix argument DEBUG, enable JDWP."
  (interactive "P")
  (let ((context (java-kit-project-context)))
    (java-kit-app--stop context 'spring-boot)
    (java-kit-spring-boot-run debug)))

(defun java-kit-app--tomcat-home-p (directory)
  "Return non-nil when DIRECTORY contains a Tomcat launcher."
  (and (stringp directory)
       (file-directory-p directory)
       (file-regular-p (expand-file-name "bin/catalina.sh" directory))))

(defun java-kit-app--tomcat-launcher-home ()
  "Return the Tomcat home containing `catalina.sh' on PATH."
  (when-let* ((launcher (executable-find "catalina.sh")))
    (let* ((launcher (expand-file-name launcher))
           (home (file-name-directory
                  (directory-file-name (file-name-directory launcher)))))
      (or (and (java-kit-app--tomcat-home-p home)
               (directory-file-name home))
          (let* ((real-launcher (file-truename launcher))
                 (real-home
                  (file-name-directory
                   (directory-file-name
                    (file-name-directory real-launcher)))))
            (and (java-kit-app--tomcat-home-p real-home)
                 (directory-file-name real-home)))))))

(defun java-kit-app--tomcat-installations ()
  "Return valid Tomcat homes in platform-standard locations."
  (let ((patterns
         (pcase system-type
           ('darwin
            '("/opt/homebrew/opt/tomcat*/libexec"
              "/usr/local/opt/tomcat*/libexec"))
           ('gnu/linux
            '("/opt/tomcat*" "/opt/apache-tomcat-*"
              "/usr/local/tomcat*" "/usr/local/apache-tomcat-*"
              "/usr/share/tomcat*")))))
    (delete-dups
     (seq-filter
      #'java-kit-app--tomcat-home-p
      (mapcan (lambda (pattern)
                (file-expand-wildcards pattern t))
              patterns)))))

(defun java-kit-detect-tomcat-home (&optional _context)
  "Return an unambiguous Tomcat installation for the current system.

Honor `CATALINA_HOME' first, then a `catalina.sh' on PATH, then conventional
macOS Homebrew or Linux installation locations.  _CONTEXT is accepted so this
function can be used directly as a project-aware customization resolver."
  (let ((environment-home (getenv "CATALINA_HOME")))
    (cond
     ((and environment-home (not (string-empty-p environment-home)))
      (unless (java-kit-app--tomcat-home-p environment-home)
        (user-error "CATALINA_HOME is not a Tomcat installation: %s"
                    environment-home))
      (directory-file-name (expand-file-name environment-home)))
     ((java-kit-app--tomcat-launcher-home))
     (t
      (pcase (java-kit-app--tomcat-installations)
        ('nil nil)
        (`(,home) (directory-file-name (expand-file-name home)))
        (homes
         (user-error "Multiple Tomcat installations found: %s"
                     (string-join homes ", "))))))))

(defun java-kit-app--tomcat-home (context)
  "Resolve and validate the Tomcat home for CONTEXT."
  (let ((home (java-kit--configured-value java-kit-tomcat-home context)))
    (unless (and (stringp home) (not (string-empty-p home)))
      (user-error
       "Could not detect Tomcat; configure `java-kit-tomcat-home'"))
    (setq home (directory-file-name (expand-file-name home)))
    (unless (java-kit-app--tomcat-home-p home)
      (user-error "Tomcat catalina.sh is missing under %s" home))
    home))

(defun java-kit-app--tomcat-base (context home)
  "Resolve and validate the Tomcat runtime base for CONTEXT and HOME."
  (let* ((configured
          (java-kit--configured-value java-kit-tomcat-base context))
         (environment-base (getenv "CATALINA_BASE"))
         (base (or configured
                   (and environment-base
                        (not (string-empty-p environment-base))
                        environment-base)
                   home)))
    (setq base (directory-file-name (expand-file-name base)))
    (unless (file-directory-p (expand-file-name "conf" base))
      (user-error "Tomcat conf directory is missing under %s" base))
    (unless (file-directory-p (expand-file-name "webapps" base))
      (user-error "Tomcat webapps directory is missing under %s" base))
    (unless (file-writable-p (expand-file-name "webapps" base))
      (user-error "Tomcat webapps directory is not writable under %s" base))
    base))

(defun java-kit-app--tomcat-command (home debug)
  "Return the foreground Tomcat command under HOME for DEBUG mode."
  (let ((script (expand-file-name "bin/catalina.sh" home)))
    (append (if (file-executable-p script) (list script) (list "sh" script))
            (if debug '("jpda" "run") '("run")))))

(defun java-kit-app--tomcat-process-environment (context home base debug)
  "Return the Tomcat environment for CONTEXT, HOME, BASE, and DEBUG mode."
  (let ((environment (java-kit-project-process-environment context)))
    (setq environment
          (java-kit--environment-merge
           environment
           (list (concat "CATALINA_HOME=" home)
                 (concat "CATALINA_BASE=" base))))
    (if debug
        (java-kit--environment-merge
         environment
         (list (format "JPDA_ADDRESS=%d" java-kit-tomcat-debug-port)))
      environment)))

(defun java-kit-app--tomcat-conflict (base)
  "Return a live java-kit Tomcat service using BASE."
  (let (found)
    (maphash
     (lambda (_key service)
       (when (and (eq (java-kit-app--service-kind service) 'tomcat)
                  (equal base (java-kit-app--service-base service))
                  (process-live-p (java-kit-app--service-process service)))
         (setq found service)))
     java-kit-app--services)
    found))

(defun java-kit-app--war (context)
  "Return the built WAR artifact for CONTEXT."
  (let* ((root (plist-get context :module-root))
         (directory
          (pcase (plist-get context :build-system)
            ('maven (expand-file-name "target" root))
            ('gradle (expand-file-name "build/libs" root))))
         (war (java-kit-app--newest-artifact
               directory "\\.war\\'" "\\(?:-sources\\|-javadoc\\)\\.war\\'")))
    (or war (user-error "No WAR artifact found under %s" directory))))

(defun java-kit-app--deploy-war (context base)
  "Copy CONTEXT's built WAR into Tomcat BASE and return its destination."
  (let* ((war (java-kit-app--war context))
         (configured-name
          (java-kit--configured-value java-kit-tomcat-context-name context))
         (file-name
          (if (and configured-name (not (string-empty-p configured-name)))
              (concat configured-name ".war")
            (file-name-nondirectory war)))
         (destination (expand-file-name file-name
                                        (expand-file-name "webapps" base))))
    (copy-file war destination t)
    destination))

(defun java-kit-app--start-tomcat (context home base debug source-buffer)
  "Start Tomcat HOME and BASE for CONTEXT in DEBUG mode from SOURCE-BUFFER."
  (when-let* ((conflict (java-kit-app--tomcat-conflict base)))
    (user-error "Tomcat base %s is already managed for %s"
                base
                (plist-get (java-kit-app--service-context conflict) :name)))
  (let ((environment
         (java-kit-app--tomcat-process-environment
          context home base debug)))
    (java-kit-app--start-process
     context 'tomcat (java-kit-app--tomcat-command home debug)
     'starting
     :ready-regexp "Server startup in"
     :debug debug
     :port java-kit-tomcat-port
     :debug-port (and debug java-kit-tomcat-debug-port)
     :home home :base base
     :environment environment
     :source-buffer source-buffer)))

;;;###autoload
(defun java-kit-tomcat-deploy (&optional debug)
  "Build and deploy the current WAR, then start its configured Tomcat.

With prefix argument DEBUG, start Tomcat in JPDA mode."
  (interactive "P")
  (let* ((context (java-kit-project-context))
         (home (java-kit-app--tomcat-home context))
         (base (java-kit-app--tomcat-base context home))
         (source-buffer (current-buffer)))
    (java-kit-app--start-process
     context 'tomcat-build
     (java-kit-app--build-arguments context 'tomcat)
     'building
     :home home :base base
     :source-buffer source-buffer
     :on-success
     (lambda ()
       (java-kit-app--stop context 'tomcat)
       (let ((destination (java-kit-app--deploy-war context base)))
         (message "Deployed %s" destination))
       (java-kit-app--start-tomcat
        context home base debug source-buffer)))))

;;;###autoload
(defun java-kit-tomcat-stop ()
  "Stop the Tomcat process started for the current module."
  (interactive)
  (java-kit-app--stop (java-kit-project-context) 'tomcat))

;;;###autoload
(defun java-kit-tomcat-restart (&optional debug)
  "Restart the current module's tracked Tomcat without rebuilding.

With prefix argument DEBUG, enable JPDA."
  (interactive "P")
  (let* ((context (java-kit-project-context))
         (home (java-kit-app--tomcat-home context))
         (base (java-kit-app--tomcat-base context home))
         (source-buffer (current-buffer)))
    (java-kit-app--stop context 'tomcat)
    (java-kit-app--start-tomcat
     context home base debug source-buffer)))

;;;###autoload
(defun java-kit-app-status ()
  "Display and return live java-kit services for the current module."
  (interactive)
  (let* ((context (java-kit-project-context))
         (scope (java-kit--module-scope context))
         services)
    (maphash
     (lambda (_key service)
       (when (and (equal scope
                         (java-kit--module-scope
                          (java-kit-app--service-context service)))
                  (process-live-p (java-kit-app--service-process service)))
         (push (list :kind (java-kit-app--service-kind service)
                     :status (java-kit-app--service-status service)
                     :debug (java-kit-app--service-debug service)
                     :port (java-kit-app--service-port service)
                     :debug-port
                     (java-kit-app--service-debug-port service))
               services)))
     java-kit-app--services)
    (setq services (nreverse services))
    (if services
        (message "%s"
                 (mapconcat
                  (lambda (service)
                    (format "%s=%s"
                            (plist-get service :kind)
                            (plist-get service :status)))
                  services ", "))
      (message "No java-kit services are active for %s"
               (plist-get context :name)))
    services))

(provide 'java-kit-app)
;;; java-kit-app.el ends here
