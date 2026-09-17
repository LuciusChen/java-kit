;;; java-kit-protocol-test.el --- Local protocol integration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; These tests require Dape and loopback sockets, but no Java installation.

;;; Code:

(require 'ert)
(require 'java-kit-debug)
(require 'dape)

(defun java-kit-test--await (predicate)
  "Process events until PREDICATE succeeds or three seconds elapse."
  (let ((deadline (+ (float-time) 3)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(defun java-kit-test--dap-send (process object)
  "Send a DAP OBJECT to PROCESS."
  (let ((body (encode-coding-string (json-serialize object) 'utf-8)))
    (process-send-string process
                         (format "Content-Length: %d\r\n\r\n%s"
                                 (string-bytes body) body))))

(defun java-kit-test--dap-server (on-launch &optional manual-events)
  "Call ON-LAUNCH for launch/attach; MANUAL-EVENTS suppresses startup events."
  (make-network-process
   :name "java-kit-dap-test" :server t :host "127.0.0.1"
   :family 'ipv4 :service t :noquery t :coding 'binary
   :log (lambda (server client _message)
          (process-put server :clients (cons client (process-get server :clients))))
   :filter
   (lambda (process text)
     (let ((pending (concat (process-get process :pending) text)))
       (while (and (string-match "Content-Length: \\([0-9]+\\)\r\n\r\n" pending)
                   (>= (- (length pending) (match-end 0))
                       (string-to-number (match-string 1 pending))))
         (let* ((end (+ (match-end 0) (string-to-number (match-string 1 pending))))
                (request (json-parse-string
                          (decode-coding-string (substring pending (match-end 0) end) 'utf-8)
                          :object-type 'plist))
                (command (plist-get request :command)))
           (setq pending (substring pending end))
           (process-put process :commands (cons command (process-get process :commands)))
           (java-kit-test--dap-send
            process (list :seq 1 :type "response" :success t
                          :request_seq (plist-get request :seq) :command command
                          :body (if (equal command "threads") '(:threads [])
                                  (make-hash-table))))
           (when (member command '("launch" "attach"))
             (process-put process :launched t)
             (funcall on-launch (plist-get request :arguments))
             (unless manual-events
               (when (equal command "launch")
                 (java-kit-test--dap-send
                  process '(:seq 2 :type "event" :event "processid" :body (:processId 1234))))
               (java-kit-test--dap-send
                process '(:seq 3 :type "event" :event "initialized" :body nil))))))
       (process-put process :pending pending)))))

(ert-deftest java-kit-test-protocol-startup-timeout-cancels-delayed-launch ()
  (dolist (stage '(initialize launch))
    (let ((dape-start-hook nil) (dape-default-config-functions nil)
          (dape-request-timeout 5)
          (java-kit-java-debug-request-timeout 1000)
          (java-kit--pending-session nil)
          (java-kit-debug--sessions (make-hash-table :test #'equal))
          (send (symbol-function 'java-kit-test--dap-send))
          server session client initialize-response launches)
      (unwind-protect
          (cl-letf (((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'java-kit--eglot-server) (lambda () 'eglot))
                    ((symbol-function 'java-kit-debug--adapter-port)
                     (lambda (_) (process-contact server :service)))
                    ((symbol-function 'java-kit-test--dap-send)
                     (lambda (process object)
                       (if (and (eq stage 'initialize)
                                (equal (plist-get object :command) "initialize"))
                           (setq client process initialize-response object)
                         (funcall send process object)))))
            (setq server (java-kit-test--dap-server
                          (lambda (args) (push args launches)) t))
            (java-kit--debug-start
             '(:module-root "/tmp/")
             '(:type "java" :request "launch" :mainClass "Late"))
            (setq session java-kit--pending-session)
            (java-kit-test--await
             (lambda () (if (eq stage 'initialize) initialize-response launches)))
            (setq client (car (process-get server :clients)))
            (java-kit-test--await (lambda () (null java-kit--pending-session)))
            (should-not (java-kit-debug--session-timer session))
            (when initialize-response
              (funcall send client initialize-response))
            (java-kit-test--await
             (lambda () (member "disconnect" (process-get client :commands))))
            (java-kit-test--await (lambda () (not (process-live-p client))))
            (should (= 1 (cl-count "disconnect" (process-get client :commands) :test #'equal)))
            (should (= (length launches) (if (eq stage 'initialize) 0 1)))
            (should (= 0 (hash-table-count java-kit-debug--sessions))))
        (when session (java-kit--debug-cleanup session))
        (when server
          (dolist (process (cons server (process-get server :clients)))
            (when (process-live-p process) (delete-process process))))))))

(ert-deftest java-kit-test-protocol-preparation-rejects-reentrant-start ()
  (let ((dape-start-hook nil) (dape-default-config-functions nil)
        (java-kit--pending-session nil)
        (java-kit-debug--sessions (make-hash-table :test #'equal))
        (port-requests 0)
        server session nested-session nested-error resumed launches timer)
    (unwind-protect
        (cl-letf (((symbol-function 'java-kit--eglot-server) (lambda () 'eglot))
                  ((symbol-function 'java-kit-debug--adapter-port)
                   (lambda (_)
                     (cl-incf port-requests)
                     (when (= port-requests 1)
                       ;; A synchronous Eglot request processes other callbacks.
                       (setq timer
                             (run-at-time
                              0 nil
                              (lambda ()
                                (condition-case error-data
                                    (java-kit--debug-start
                                     '(:module-root "/tmp/b/")
                                     '(:type "java" :request "launch" :mainClass "B"))
                                  (user-error (setq nested-error error-data)))
                                (setq nested-session java-kit--pending-session
                                      resumed t))))
                       (java-kit-test--await (lambda () resumed)))
                     (process-contact server :service))))
          (setq server (java-kit-test--dap-server (lambda (args) (push args launches))))
          (java-kit--debug-start '(:module-root "/tmp/a/")
                                 '(:type "java" :request "launch" :mainClass "A"))
          (setq session java-kit--pending-session)
          (should (eq (car nested-error) 'user-error))
          (should (eq session nested-session))
          (should (= 1 port-requests))
          (java-kit-test--await (lambda () (gethash "/tmp/a/" java-kit-debug--sessions)))
          (should (eq session (gethash "/tmp/a/" java-kit-debug--sessions)))
          (should-not java-kit--pending-session)
          (should (= 1 (length launches)))
          (should (equal "A" (plist-get (car launches) :mainClass))))
      (when timer (cancel-timer timer))
      (dolist (owned (list session nested-session java-kit--pending-session))
        (when owned (java-kit--debug-cleanup owned)))
      (when server
        (dolist (process (cons server (process-get server :clients)))
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest java-kit-test-protocol-startup-events-keep-connection-ownership ()
  (let ((dape-start-hook nil) (dape-default-config-functions nil)
        (java-kit--pending-session nil)
        (java-kit-debug--sessions (make-hash-table :test #'equal))
        servers sessions port event-count launches)
    (let ((observer (lambda (&rest _) (setq event-count (1+ (or event-count 0))))))
      (unwind-protect
          (cl-letf (((symbol-function 'java-kit--eglot-server) (lambda () 'eglot))
                    ((symbol-function 'java-kit-debug--adapter-port) (lambda (_) port)))
            (advice-add 'java-kit-debug--initialized :after observer)
            (dotimes (_ 3)
              (push (java-kit-test--dap-server (lambda (args) (push args launches)) t) servers))
            (setq port (process-contact (car servers) :service))
            (java-kit--debug-start '(:module-root "/tmp/a/")
                                   '(:type "java" :request "launch" :mainClass "A"))
            (java-kit-test--await
             (lambda () (when-let* ((client (car (process-get (car servers) :clients))))
                          (process-get client :launched))))
            (java-kit-test--dap-send
             (car (process-get (car servers) :clients))
             '(:seq 2 :type "event" :event "initialized" :body nil))
            (java-kit-test--await (lambda () (gethash "/tmp/a/" java-kit-debug--sessions)))
            (push (gethash "/tmp/a/" java-kit-debug--sessions) sessions)
            (setq port (process-contact (cadr servers) :service))
            (java-kit--debug-start '(:module-root "/tmp/b/")
                                   '(:type "java" :request "launch" :mainClass "B"))
            (push java-kit--pending-session sessions)
            ;; An unrelated Dape launch must not consume B's pending session.
            (dape (list 'port (process-contact (caddr servers) :service)
                        :type "java" :request "launch" :mainClass "Foreign"))
            (java-kit-test--await
             (lambda () (when-let* ((client (car (process-get (caddr servers) :clients))))
                          (process-get client :launched))))
            (dolist (event '("processid" "initialized"))
              (java-kit-test--dap-send
               (car (process-get (caddr servers) :clients))
               (list :seq 2 :type "event" :event event :body nil)))
            (java-kit-test--await (lambda () (= event-count 2)))
            (should (eq java-kit--pending-session (car sessions)))
            (java-kit-test--dap-send
             (car (process-get (car servers) :clients))
             '(:seq 3 :type "event" :event "initialized" :body nil))
            (java-kit-test--await (lambda () (= event-count 3)))
            (should (eq java-kit--pending-session (car sessions)))
            (java-kit-test--await
             (lambda () (when-let* ((client (car (process-get (cadr servers) :clients))))
                          (process-get client :launched))))
            (dolist (event '("processid" "initialized"))
              (java-kit-test--dap-send
               (car (process-get (cadr servers) :clients))
               (list :seq 4 :type "event" :event event :body nil)))
            (java-kit-test--await (lambda () (= event-count 4)))
            (should-not java-kit--pending-session)
            (should-not (eq (java-kit-debug--session-connection (car sessions))
                            (java-kit-debug--session-connection (cadr sessions))))
            (dolist (arguments launches)
              (should-not (plist-member arguments :java-kit-session-id))))
        (advice-remove 'java-kit-debug--initialized observer)
        (dolist (session sessions) (when session (java-kit--debug-cleanup session)))
        (when java-kit--pending-session (java-kit--debug-cleanup java-kit--pending-session))
        (dolist (server servers)
          (dolist (process (cons server (process-get server :clients)))
            (when (process-live-p process) (delete-process process))))))))

(ert-deftest java-kit-test-protocol-attach-binds-session-without-leaking-marker ()
  (let ((dape-start-hook nil) (dape-default-config-functions nil)
        (java-kit--pending-session nil)
        (java-kit-debug--sessions (make-hash-table :test #'equal))
        server session arguments)
    (unwind-protect
        (cl-letf (((symbol-function 'java-kit--eglot-server) (lambda () 'eglot))
                  ((symbol-function 'java-kit-debug--adapter-port)
                   (lambda (_) (process-contact server :service))))
          (setq server (java-kit-test--dap-server (lambda (args) (setq arguments args))))
          (java-kit--debug-start '(:module-root "/tmp/") (java-kit-debug--attach-config 5005))
          (java-kit-test--await (lambda () (gethash "/tmp/" java-kit-debug--sessions)))
          (setq session (gethash "/tmp/" java-kit-debug--sessions))
          (should (jsonrpc-running-p (java-kit-debug--session-connection session)))
          (should (= 5005 (plist-get arguments :port)))
          (should-not (plist-member arguments :javaExec))
          (should-not (plist-member arguments :java-kit-session-id)))
      (when session (java-kit--debug-cleanup session))
      (when java-kit--pending-session (java-kit--debug-cleanup java-kit--pending-session))
      (when server
        (dolist (process (cons server (process-get server :clients)))
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest java-kit-test-protocol-restart-prepares-a-fresh-session ()
  (let ((dape-start-hook nil) (dape-default-config-functions nil)
        (java-kit--pending-session nil)
        (java-kit-debug--sessions (make-hash-table :test #'equal))
        (port-requests 0) servers first second launches)
    (unwind-protect
        (cl-letf (((symbol-function 'java-kit--eglot-server) (lambda () 'eglot))
                  ((symbol-function 'java-kit-debug--adapter-port)
                   (lambda (_)
                     (prog1 (process-contact (nth port-requests servers) :service)
                       (cl-incf port-requests)))))
          (dotimes (_ 2)
            (push (java-kit-test--dap-server (lambda (args) (push args launches))) servers))
          (java-kit--debug-start
           '(:module-root "/tmp/")
           '(:type "java" :request "launch" :mainClass "Main"
             :javaExec "/project-jdk/bin/java" :env (:PROFILE "debug")))
          (java-kit-test--await (lambda () (gethash "/tmp/" java-kit-debug--sessions)))
          (setq first (gethash "/tmp/" java-kit-debug--sessions))
          (dape-restart (java-kit-debug--session-connection first))
          (java-kit-test--await
           (lambda ()
             (setq second (gethash "/tmp/" java-kit-debug--sessions))
             (and second (not (eq first second)) (= 2 (length launches)))))
          (should (= 2 port-requests))
          (should-not (jsonrpc-running-p (java-kit-debug--session-connection first)))
          (should-not (java-kit-debug--session-timer first))
          (should (jsonrpc-running-p (java-kit-debug--session-connection second)))
          (should (equal (car launches) (cadr launches)))
          (dolist (arguments launches)
            (should-not (plist-member arguments :java-kit-session-id)))
          (java-kit--debug-cleanup first)
          (should (eq second (gethash "/tmp/" java-kit-debug--sessions))))
      (dolist (session (list first second java-kit--pending-session))
        (when session (java-kit--debug-cleanup session)))
      (dolist (server servers)
        (dolist (process (cons server (process-get server :clients)))
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest java-kit-test-protocol-dape-sends-launch-options ()
  (let ((dape-start-hook nil)
        (dape-default-config-functions nil)
        (java-kit-main-environment '("PROFILE=debug" "EMPTY=" "VALUE=中文=a"))
        (java-kit-debug-console "integratedTerminal")
        server launch)
    (unwind-protect
        (progn
          (setq server (java-kit-test--dap-server (lambda (args) (setq launch args))))
          (cl-letf (((symbol-function 'java-kit--project-java-program)
                     (lambda (_) "/project jdk/bin/java")))
            (dape (plist-put
                   (java-kit-debug--main-config
                    '(:module-root "/tmp/" :debug-project-name "actual-jdt-project")
                    "example.Main" nil '("/tmp/test classes"))
                   'port (process-contact server :service))))
          (java-kit-test--await (lambda () launch))
          (should (equal '(:PROFILE "debug" :EMPTY "" :VALUE "中文=a")
                         (plist-get launch :env)))
          (should (equal "/project jdk/bin/java" (plist-get launch :javaExec)))
          (should (equal "actual-jdt-project" (plist-get launch :projectName)))
          (should (equal "integratedTerminal" (plist-get launch :console))))
      (when server
        (dolist (process (cons server (process-get server :clients)))
          (when (process-live-p process) (delete-process process))))
      (accept-process-output nil 0.05))))

(provide 'java-kit-protocol-test)
;;; java-kit-protocol-test.el ends here
