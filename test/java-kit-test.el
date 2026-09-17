;;; java-kit-test.el --- Tests for java-kit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Code:

(require 'ert)
(require 'java-kit)
(require 'java-kit-debug)
(require 'java-kit-app)
(require 'java-kit-install)
(require 'java-kit-new)

(defmacro java-kit-test--with-temp-directory (variable &rest body)
  "Bind VARIABLE to a temporary directory while evaluating BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,variable (make-temp-file "java-kit-test-" t)))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,variable t))))

(defun java-kit-test--write-file (file &optional content mode)
  "Write CONTENT to FILE and optionally set MODE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert (or content "")))
  (when mode
    (set-file-modes file mode))
  file)

(defun java-kit-test--fake-jdk (directory version)
  "Create a fake JDK under DIRECTORY with VERSION."
  (java-kit-test--write-file
   (expand-file-name "bin/java" directory) "" #o755)
  (java-kit-test--write-file
   (expand-file-name "bin/javac" directory) "" #o755)
  (java-kit-test--write-file
   (expand-file-name "release" directory)
   (format "JAVA_VERSION=\"%s\"\n" version))
  directory)

(defun java-kit-test--fake-tomcat (home &optional base)
  "Create a fake Tomcat HOME and optional runtime BASE."
  (java-kit-test--write-file
   (expand-file-name "bin/catalina.sh" home) "#!/bin/sh\n" #o755)
  (let ((base (or base home)))
    (make-directory (expand-file-name "conf" base) t)
    (make-directory (expand-file-name "webapps" base) t))
  home)

(defun java-kit-test--range (start-line end-line)
  "Return an LSP range from START-LINE through END-LINE."
  (list :start (list :line start-line :character 0)
        :end (list :line end-line :character 0)))

(ert-deftest java-kit-test-extract-java-major ()
  (should (equal "8" (java-kit--extract-java-major "1.8")))
  (should (equal "8" (java-kit--extract-java-major "VERSION_1_8")))
  (should (equal "17" (java-kit--extract-java-major "17.0.12-tem")))
  (should (equal "21" (java-kit--extract-java-major "temurin-21.0.4")))
  (should-not (java-kit--extract-java-major "temurin")))

(ert-deftest java-kit-test-java-home-requires-a-full-jdk ()
  (java-kit-test--with-temp-directory root
    (java-kit-test--write-file
     (expand-file-name "bin/java" root) "" #o755)
    (should-not (java-kit--valid-java-home-p root))
    (java-kit-test--write-file
     (expand-file-name "bin/javac" root) "" #o755)
    (should (java-kit--valid-java-home-p root))))

(ert-deftest java-kit-test-macos-jdk-selection-matches-exact-major ()
  (java-kit-test--with-temp-directory root
    (let ((jdk-22 (java-kit-test--fake-jdk
                   (expand-file-name "jdk-22" root) "22.0.1"))
          (jdk-8 (java-kit-test--fake-jdk
                  (expand-file-name "jdk-8" root) "1.8.0_301")))
      (cl-letf (((symbol-function 'java-kit--macos-java-homes)
                 (lambda () (list jdk-22 jdk-8))))
        (should (equal jdk-8 (java-kit--macos-java-home "8")))))))

(ert-deftest java-kit-test-maven-property-resolution ()
  (java-kit-test--with-temp-directory directory
    (let ((pom (java-kit-test--write-file
                (expand-file-name "pom.xml" directory)
                (concat
                 "<project><properties>"
                 "<java.version>17</java.version>"
                 "<maven.compiler.release>${java.version}</maven.compiler.release>"
                 "</properties></project>"))))
      (should (equal "17" (java-kit--maven-java-version pom))))))

(ert-deftest java-kit-test-maven-compiler-plugin-version ()
  (java-kit-test--with-temp-directory directory
    (let ((pom (java-kit-test--write-file
                (expand-file-name "pom.xml" directory)
                (concat
                 "<project><properties><java.version>22</java.version>"
                 "</properties><build><plugins>"
                 "<plugin><artifactId>other-plugin</artifactId>"
                 "<configuration><source>99</source></configuration></plugin>"
                 "<plugin><artifactId>maven-compiler-plugin</artifactId>"
                 "<configuration><target>1.8</target><source>1.8</source>"
                 "</configuration></plugin>"
                 "</plugins></build></project>"))))
      (should (equal "8" (java-kit--maven-java-version pom))))))

(ert-deftest java-kit-test-java-version-file-precedes-build-file ()
  (java-kit-test--with-temp-directory directory
    (let* ((pom (java-kit-test--write-file
                 (expand-file-name "pom.xml" directory)
                 "<project><properties><java.version>17</java.version></properties></project>"))
           (context (list :root (file-name-as-directory directory)
                          :module-root (file-name-as-directory directory)
                          :build-system 'maven
                          :build-file pom)))
      (java-kit-test--write-file
       (expand-file-name ".java-version" directory) "21\n")
      (let ((java-kit-project-java-version nil))
        (should (equal "21"
                       (java-kit--declared-java-version context)))))))

(ert-deftest java-kit-test-gradle-version-syntaxes ()
  (java-kit-test--with-temp-directory directory
    (java-kit-test--write-file
     (expand-file-name "build.gradle" directory)
     "sourceCompatibility = JavaVersion.VERSION_17\n")
    (should (equal "17" (java-kit--gradle-java-version directory)))
    (java-kit-test--write-file
     (expand-file-name "build.gradle.kts" directory)
     "languageVersion = JavaLanguageVersion.of(21)\n")
    (should (equal "21" (java-kit--gradle-java-version directory)))))

(ert-deftest java-kit-test-project-context-prefers-nearest-module ()
  (java-kit-test--with-temp-directory root
    (let* ((root (file-name-as-directory root))
           (module (expand-file-name "services/orders/" root))
           (source (expand-file-name "src/main/java/example/" module))
           (wrapper (java-kit-test--write-file
                     (expand-file-name "mvnw" root) "#!/bin/sh\n" #o755)))
      (make-directory source t)
      (java-kit-test--write-file (expand-file-name "pom.xml" module))
      (cl-letf (((symbol-function 'project-current)
                 (lambda (&rest _) (cons 'transient root))))
        (let ((context (java-kit-project-context source)))
          (should (equal root (plist-get context :root)))
          (should (equal (file-name-as-directory module)
                         (plist-get context :module-root)))
          (should (eq 'maven (plist-get context :build-system)))
          (should (equal wrapper (plist-get context :wrapper))))))))

(ert-deftest java-kit-test-build-command-prefers-wrapper ()
  (java-kit-test--with-temp-directory root
    (let* ((wrapper (java-kit-test--write-file
                     (expand-file-name "gradlew" root) "#!/bin/sh\n"))
           (context (list :name "sample"
                          :build-system 'gradle
                          :wrapper wrapper)))
      (should (equal (list "sh" wrapper)
                     (java-kit--build-command context)))
      (set-file-modes wrapper #o755)
      (should (equal (list wrapper)
                     (java-kit--build-command context))))))

(ert-deftest java-kit-test-process-environment-isolates-jdk ()
  (java-kit-test--with-temp-directory root
    (let* ((old-home (java-kit-test--fake-jdk
                      (expand-file-name "jdk-17" root) "17.0.12"))
           (new-home (java-kit-test--fake-jdk
                      (expand-file-name "jdk-21" root) "21.0.4"))
           (old-bin (expand-file-name "bin" old-home))
           (new-bin (expand-file-name "bin" new-home))
           (process-environment
            (list (concat "JAVA_HOME=" old-home)
                  (concat "PATH=" old-bin path-separator "/usr/bin")
                  "KEEP_ME=yes"))
           (environment
            (java-kit--environment-with-java-home new-home))
           (path (java-kit--environment-value "PATH" environment)))
      (should (equal new-home
                     (java-kit--environment-value "JAVA_HOME" environment)))
      (should (equal new-bin (car (split-string path path-separator t))))
      (should-not (member old-bin (split-string path path-separator t)))
      (should (member "KEEP_ME=yes" environment)))))

(ert-deftest java-kit-test-command-environment-overrides-are-isolated ()
  (let* ((base '("PATH=/usr/bin" "APP_ENV=old" "KEEP=yes"))
         (merged
          (java-kit--environment-merge
           base '("APP_ENV=new" "EXTRA=one=two"))))
    (should (member "APP_ENV=new" merged))
    (should-not (member "APP_ENV=old" merged))
    (should (member "EXTRA=one=two" merged))
    (should (member "KEEP=yes" merged))
    (should-error
     (java-kit--environment-merge base '("INVALID"))
     :type 'user-error)))

(ert-deftest java-kit-test-macos-path-launcher-is-not-a-jdk-home ()
  (let ((system-type 'darwin))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) "/usr/bin/java"))
              ((symbol-function 'file-truename) #'identity)
              ((symbol-function 'java-kit--valid-java-home-p)
               (lambda (_directory) t)))
      (should-not (java-kit--java-home-from-path)))))

(ert-deftest java-kit-test-linux-path-java-resolves-jdk-home ()
  (java-kit-test--with-temp-directory root
    (let* ((system-type 'gnu/linux)
           (jdk (java-kit-test--fake-jdk
                 (expand-file-name "java-21-openjdk" root) "21.0.4"))
           (java (expand-file-name "bin/java" jdk)))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_program) "/usr/bin/java"))
                ((symbol-function 'file-truename)
                 (lambda (_file) java)))
        (should (equal (file-name-as-directory jdk)
                       (java-kit--java-home-from-path)))))))

(ert-deftest java-kit-test-project-jdk-override-is-separate ()
  (java-kit-test--with-temp-directory root
    (let* ((jdk (java-kit-test--fake-jdk
                 (expand-file-name "jdk-17" root) "17.0.12"))
           (context (list :name "sample"
                          :root (file-name-as-directory root)
                          :module-root (file-name-as-directory root)))
           (java-kit-project-java-home jdk)
           (java-kit-project-java-version nil))
      (should (equal jdk (java-kit-resolve-project-java-home context))))))

(ert-deftest java-kit-test-interactive-project-jdk-is-scoped-and-clearable ()
  (java-kit-test--with-temp-directory root
    (let* ((selected (java-kit-test--fake-jdk
                      (expand-file-name "jdk-21" root) "21.0.4"))
           (configured (java-kit-test--fake-jdk
                        (expand-file-name "jdk-17" root) "17.0.12"))
           (context (list :name "sample"
                          :root (file-name-as-directory root)
                          :module-root (file-name-as-directory root)))
           (java-kit-project-java-home configured)
           (java-kit-project-java-version nil)
           (java-kit--project-java-home-selections
            (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'java-kit-project-context)
                 (lambda (&optional _directory) context))
                ((symbol-function 'java-kit--installed-java-homes)
                 (lambda () (list selected configured)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _arguments)
                   (caar collection))))
        (should (equal selected (java-kit-select-project-jdk)))
        (should (equal selected
                       (java-kit-resolve-project-java-home context)))
        (java-kit-select-project-jdk t)
        (should (equal configured
                       (java-kit-resolve-project-java-home context)))))))

(ert-deftest java-kit-test-jdtls-options-use-project-jdk ()
  (java-kit-test--with-temp-directory root
    (let* ((jdk (java-kit-test--fake-jdk
                 (expand-file-name "project-jdk" root) "17.0.12"))
           (bundle (java-kit-test--write-file
                    (expand-file-name "java-debug.jar" root)))
           (context (list :name "sample"
                          :root (file-name-as-directory root)
                          :module-root (file-name-as-directory root)))
           (java-kit-project-java-home jdk)
           (java-kit-project-java-version nil)
           (java-kit-jdtls-bundles (list bundle))
           (options (java-kit-jdtls-initialization-options context)))
      (should (equal jdk (plist-get
                          (plist-get (plist-get options :settings) :java)
                          :home)))
      (should (equal (vector (file-truename bundle))
                     (plist-get options :bundles))))))

(ert-deftest java-kit-test-jdtls-workspaces-use-full-root ()
  (java-kit-test--with-temp-directory root
    (let* ((first (expand-file-name "one/app/" root))
           (second (expand-file-name "two/app/" root))
           (java-kit-jdtls-workspace-directory
            (expand-file-name "workspaces/" root)))
      (make-directory first t)
      (make-directory second t)
      (should-not (equal (java-kit--jdtls-workspace first)
                         (java-kit--jdtls-workspace second))))))

(ert-deftest java-kit-test-jdtls-contact-keeps-jdks-separate ()
  (java-kit-test--with-temp-directory root
    (let* ((root (file-name-as-directory root))
           (jdtls-jdk (java-kit-test--fake-jdk
                       (expand-file-name "jdtls-jdk" root) "21.0.4"))
           (project-jdk (java-kit-test--fake-jdk
                         (expand-file-name "project-jdk" root) "17.0.12"))
           (context (list :name "sample"
                          :root root
                          :module-root root))
           (java-kit-jdtls-java-home jdtls-jdk)
           (java-kit-project-java-home project-jdk)
           (java-kit-project-java-version nil)
           (java-kit-jdtls-command '("jdtls"))
           (java-kit-jdtls-workspace-directory
            (expand-file-name "workspaces/" root)))
      (cl-letf (((symbol-function 'java-kit-project-context)
                 (lambda (&optional _) context))
                ((symbol-function 'java-kit--command-available-p)
                 (lambda (_program) t)))
        (let* ((contact (java-kit--jdtls-contact))
               (options-position
                (cl-position :initializationOptions contact))
               (options (nth (1+ options-position) contact)))
          (should (equal "env" (car contact)))
          (should (member (concat "JAVA_HOME=" jdtls-jdk) contact))
          (should (equal project-jdk
                         (plist-get
                          (plist-get (plist-get options :settings) :java)
                          :home))))))))

(ert-deftest java-kit-test-eglot-registration-replaces-java-entry ()
  (let ((eglot-server-programs
         '(((java-mode java-ts-mode) . ("old-jdtls"))
           (python-mode . ("pyright-langserver" "--stdio"))))
        (file-name-handler-alist nil))
    (java-kit-eglot-register)
    (let ((java-entries
           (seq-filter
            (lambda (entry)
              (equal (car entry) java-kit--eglot-modes))
            eglot-server-programs)))
      (should (= 1 (length java-entries)))
      (should (eq #'java-kit--jdtls-contact
                  (cdr (car java-entries))))
      (should (assoc 'python-mode eglot-server-programs)))))

(ert-deftest java-kit-test-jdt-uri-materializes-class-once-as-read-only ()
  (java-kit-test--with-temp-directory root
    (let ((java-kit-jdt-class-cache-directory root)
          (uri "jdt://contents/java.base/java.lang/String.class?=demo")
          (requests 0))
      (cl-letf (((symbol-function 'java-kit--eglot-server)
                 (lambda () 'server))
                ((symbol-function 'jsonrpc-request)
                 (lambda (server method parameters &rest _options)
                   (should (eq 'server server))
                   (should (eq :java/classFileContents method))
                   (should (equal uri (plist-get parameters :uri)))
                   (cl-incf requests)
                   "package java.lang; public final class String {}\n")))
        (let ((first (java-kit--jdt-uri-local-file uri))
              (second (java-kit--jdt-uri-local-file uri)))
          (should (equal first second))
          (should (= 1 requests))
          (should (file-readable-p first))
          (should (zerop (logand #o222 (file-modes first))))
          (should (java-kit--jdt-uri-handler 'file-readable-p uri)))))))

(ert-deftest java-kit-test-jdt-uri-handler-rejects-writes ()
  (should-error
   (java-kit--jdt-uri-handler
    'write-region "content" nil
    "jdt://contents/java.base/java.lang/String.class?=demo")
   :type 'file-error))

(ert-deftest java-kit-test-jdt-uri-registration-is-explicit-and-idempotent ()
  (let ((file-name-handler-alist nil))
    (java-kit-jdt-uri-register)
    (java-kit-jdt-uri-register)
    (should
     (equal '(("\\`jdt://" . java-kit--jdt-uri-handler))
            file-name-handler-alist))
    (java-kit-jdt-uri-unregister)
    (should-not file-name-handler-alist)))

(ert-deftest java-kit-test-symbol-target-finds-nested-test-method ()
  (let* ((symbols
          (vector
           (list :name "com.example" :kind 4
                 :range (java-kit-test--range 0 0))
           (list
            :name "Outer" :kind 5 :range (java-kit-test--range 2 20)
            :children
            (vector
             (list
              :name "Inner" :kind 5 :range (java-kit-test--range 4 12)
              :children
              (vector
               (list :name "works(String)" :kind 6
                     :range (java-kit-test--range 6 8))))))))
         (target (java-kit--target-from-symbols symbols 7)))
    (should (equal "com.example.Outer$Inner" (plist-get target :class)))
    (should (equal "works" (plist-get target :method)))))

(ert-deftest java-kit-test-jdtls-classpaths-use-public-execute-command ()
  (java-kit-test--with-temp-directory root
    (let* ((file (java-kit-test--write-file
                  (expand-file-name "Example.java" root)))
           (context (list :module-root (file-name-as-directory root)))
           captured)
      (cl-letf (((symbol-function 'eglot-execute)
                 (lambda (server action)
                   (setq captured (list server action))
                   (list :classpaths
                         (vector "/tmp/classes" "target/test-classes")))))
        (should
         (equal (list "/tmp/classes"
                      (expand-file-name "target/test-classes" root))
                (java-kit--jdtls-classpaths
                 'server file "test" context)))
        (let* ((action (cadr captured))
               (arguments (plist-get action :arguments))
               (scope (json-parse-string
                       (aref arguments 1) :object-type 'plist)))
          (should (eq 'server (car captured)))
          (should (equal "java.project.getClasspaths"
                         (plist-get action :command)))
          (should (equal "test" (plist-get scope :scope))))))))

(ert-deftest java-kit-test-run-main-dispatches-isolated-command ()
  (java-kit-test--with-temp-directory root
    (let* ((file (java-kit-test--write-file
                  (expand-file-name "Example.java" root)
                  "class Example {}\n"))
           (context (list :name "sample"
                          :root (file-name-as-directory root)
                          :module-root (file-name-as-directory root)))
           (java-kit-main-jvm-arguments '("-Xmx1g"))
           (java-kit-main-arguments '("one" "two words"))
           (java-kit-main-environment '("APP_ENV=dev"))
           captured)
      (with-temp-buffer
        (setq buffer-file-name file)
        (cl-letf (((symbol-function 'java-kit--eglot-server)
                   (lambda () 'server))
                  ((symbol-function 'java-kit-project-context)
                   (lambda (&optional _directory) context))
                  ((symbol-function 'java-kit--current-target)
                   (lambda (_server _file) (list :class "example.Main")))
                  ((symbol-function 'java-kit--jdtls-classpaths)
                   (lambda (_server _file _scope _context)
                     '("/tmp/classes")))
                  ((symbol-function 'java-kit--project-java-program)
                   (lambda (_context) "/fake/jdk/bin/java"))
                  ((symbol-function 'java-kit--start-java-compilation)
                   (lambda (arguments actual-context operation environment)
                     (setq captured
                           (list arguments actual-context operation
                                 environment)))))
          (java-kit-run-main)))
      (should
       (equal '("/fake/jdk/bin/java" "-Xmx1g" "-cp" "/tmp/classes"
                "example.Main" "one" "two words")
              (car captured)))
      (should (eq context (cadr captured)))
      (should (equal "main" (caddr captured)))
      (should (equal '("APP_ENV=dev") (cadddr captured))))))

(ert-deftest java-kit-test-run-test-selects-method ()
  (java-kit-test--with-temp-directory root
    (let* ((file (java-kit-test--write-file
                  (expand-file-name "ExampleTest.java" root)))
           (jar (java-kit-test--write-file
                 (expand-file-name "junit-console.jar" root)))
           (context (list :name "sample"
                          :root (file-name-as-directory root)
                          :module-root (file-name-as-directory root)))
           (java-kit-junit-console-jar jar)
           (java-kit-test-jvm-arguments '("-ea"))
           (java-kit-test-environment '("TEST_ENV=focused"))
           captured)
      (with-temp-buffer
        (setq buffer-file-name file)
        (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
                  ((symbol-function 'eglot-server-capable)
                   (lambda (&rest _) ["vscode.java.test.findTestTypesAndMethods"
                                      "vscode.java.test.junit.argument"]))
                  ((symbol-function 'java-kit-debug-test)
                   (lambda (&rest _) (ert-fail "A normal test run must use Console Launcher")))
                  ((symbol-function 'java-kit--eglot-server)
                   (lambda () 'server))
                  ((symbol-function 'java-kit--jdtls-test-file-p)
                   (lambda (_server _file) t))
                  ((symbol-function 'java-kit-project-context)
                   (lambda (&optional _directory) context))
                  ((symbol-function 'java-kit--current-target)
                   (lambda (_server _file)
                     (list :class "example.ExampleTest"
                           :method "works")))
                  ((symbol-function 'java-kit--jdtls-classpaths)
                   (lambda (_server _file scope _context)
                     (should (equal "test" scope))
                     '("/tmp/test-classes")))
                  ((symbol-function 'java-kit--project-java-program)
                   (lambda (_context) "/fake/jdk/bin/java"))
                  ((symbol-function 'java-kit--start-java-compilation)
                   (lambda (arguments _context operation environment)
                     (setq captured
                           (list arguments operation environment)))))
          (java-kit-run-test)))
      (should
       (equal (list "/fake/jdk/bin/java" "-ea" "-jar" jar "execute"
                    "--class-path" "/tmp/test-classes"
                    "--select-method" "example.ExampleTest#works")
              (car captured)))
      (should (equal "test" (cadr captured)))
      (should (equal '("TEST_ENV=focused") (caddr captured))))))

(ert-deftest java-kit-test-project-refresh-notifies-build-file-first ()
  (java-kit-test--with-temp-directory root
    (let* ((build-file (java-kit-test--write-file
                        (expand-file-name "pom.xml" root)))
           (context (list :name "sample" :build-file build-file))
           notifications)
      (cl-letf (((symbol-function 'java-kit--eglot-server)
                 (lambda () 'server))
                ((symbol-function 'java-kit-project-context)
                 (lambda (&optional _directory) context))
                ((symbol-function 'jsonrpc-notify)
                 (lambda (server method parameters)
                   (push (list server method parameters) notifications))))
        (java-kit-project-refresh))
      (setq notifications (nreverse notifications))
      (should (equal :java/projectConfigurationUpdate
                     (cadr (car notifications))))
      (should (equal (eglot-path-to-uri build-file)
                     (plist-get (caddr (car notifications)) :uri)))
      (should (equal '(server :java/buildWorkspace [:json-false])
                     (cadr notifications))))))

(ert-deftest java-kit-test-app-build-arguments-preserve-wrapper-precedence ()
  (java-kit-test--with-temp-directory root
    (let* ((wrapper (java-kit-test--write-file
                     (expand-file-name "mvnw" root) "#!/bin/sh\n" #o755))
           (context (list :name "sample" :build-system 'maven
                          :wrapper wrapper)))
      (should (equal (list wrapper "package" "-DskipTests")
                     (java-kit-app--build-arguments
                      context 'spring-boot))))))

(ert-deftest java-kit-test-app-debug-services-auto-attach-by-default ()
  (should java-kit-app-auto-debug-attach))

(ert-deftest java-kit-test-spring-command-keeps-debug-and-project-jdk-explicit ()
  (let ((context (list :name "sample"))
        (java-kit-spring-boot-debug-port 5105)
        (java-kit-spring-boot-jvm-arguments '("-Xmx2g"))
        (java-kit-spring-boot-arguments '("--spring.profiles.active=dev")))
    (cl-letf (((symbol-function 'java-kit--project-java-program)
               (lambda (_context) "/project/jdk/bin/java")))
      (should
       (equal
        '("/project/jdk/bin/java" "-Xmx2g"
          "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5105"
          "-jar" "/tmp/app.jar" "--spring.profiles.active=dev")
        (java-kit-app--spring-command
        context "/tmp/app.jar" t))))))

(ert-deftest java-kit-test-tomcat-auto-detection-uses-path-on-linux ()
  (java-kit-test--with-temp-directory root
    (let* ((system-type 'gnu/linux)
           (process-environment '("PATH=/usr/bin"))
           (home (java-kit-test--fake-tomcat
                  (expand-file-name "apache-tomcat-10" root)))
           (launcher (expand-file-name "bin/catalina.sh" home)))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (program)
                   (and (equal program "catalina.sh") launcher))))
        (should (equal home (java-kit-detect-tomcat-home)))))))

(ert-deftest java-kit-test-tomcat-auto-detection-rejects-ambiguity ()
  (let ((process-environment '("PATH=/usr/bin")))
    (cl-letf (((symbol-function 'java-kit-app--tomcat-launcher-home)
               (lambda () nil))
              ((symbol-function 'java-kit-app--user-tomcat-installations)
               (lambda () nil))
              ((symbol-function 'java-kit-app--tomcat-installations)
               (lambda () '("/opt/tomcat9" "/opt/tomcat10"))))
      (should-error (java-kit-detect-tomcat-home) :type 'user-error))))

(ert-deftest java-kit-test-tomcat-auto-detection-prefers-user-installation ()
  (let ((system-type 'gnu/linux)
        (process-environment '("PATH=/usr/bin")))
    (cl-letf (((symbol-function 'java-kit-app--tomcat-launcher-home)
               (lambda () nil))
              ((symbol-function 'java-kit-app--user-tomcat-installations)
               (lambda () '("/home/user/tomcat9")))
              ((symbol-function 'java-kit-app--tomcat-installations)
               (lambda () '("/usr/share/tomcat9"))))
      (should (equal "/home/user/tomcat9"
                     (java-kit-detect-tomcat-home))))))

(ert-deftest java-kit-test-tomcat-user-installation-scan-is-linux-only ()
  (let ((system-type 'darwin))
    (cl-letf (((symbol-function 'file-expand-wildcards)
               (lambda (&rest _arguments)
                 (ert-fail "macOS must not scan Linux user Tomcat paths"))))
      (should-not (java-kit-app--user-tomcat-installations)))))

(ert-deftest java-kit-test-tomcat-auto-detection-scans-arch-layout ()
  (java-kit-test--with-temp-directory root
    (let* ((system-type 'gnu/linux)
           (home (java-kit-test--fake-tomcat
                  (expand-file-name "usr/share/tomcat9" root))))
      (cl-letf (((symbol-function 'file-expand-wildcards)
                 (lambda (pattern &optional _full)
                   (and (equal pattern "/usr/share/tomcat*")
                        (list home)))))
        (should (equal (list home)
                       (java-kit-app--tomcat-installations)))))))

(ert-deftest java-kit-test-tomcat-home-and-base-resolve-separately ()
  (java-kit-test--with-temp-directory root
    (let* ((home (expand-file-name "usr/share/tomcat10" root))
           (base (expand-file-name "var/lib/tomcat10" root))
           (context (list :name "sample"))
           (java-kit-tomcat-home home)
           (java-kit-tomcat-base base))
      (java-kit-test--fake-tomcat home base)
      (should (equal home (java-kit-app--tomcat-home context)))
      (should (equal base (java-kit-app--tomcat-base context home))))))

(ert-deftest java-kit-test-tomcat-project-bases-are-stable-and-isolated ()
  (java-kit-test--with-temp-directory root
    (let* ((java-kit-tomcat-instance-directory
            (expand-file-name "instances" root))
           (java-kit-tomcat-port 8080)
           (first (list :name "sample"
                        :module-root (expand-file-name "first" root)))
           (second (list :name "sample"
                         :module-root (expand-file-name "second" root)))
           (first-base (java-kit-tomcat-project-base first))
           (second-base (java-kit-tomcat-project-base second)))
      (should (string-prefix-p
               (file-name-as-directory java-kit-tomcat-instance-directory)
               (file-name-as-directory first-base)))
      (should (equal first-base (java-kit-tomcat-project-base first)))
      (should-not (equal first-base second-base)))))

(ert-deftest java-kit-test-tomcat-managed-base-prepares-runtime-layout ()
  (java-kit-test--with-temp-directory root
    (let* ((home (java-kit-test--fake-tomcat
                  (expand-file-name "tomcat-home" root)))
           (java-kit-tomcat-instance-directory
            (expand-file-name "instances" root))
           (context (list :name "sample"
                          :module-root (expand-file-name "project" root)))
           (java-kit-tomcat-base #'java-kit-tomcat-project-base)
           (server (java-kit-test--write-file
                    (expand-file-name "conf/server.xml" home) "server"))
           (base (java-kit-tomcat-project-base context)))
      (should (file-readable-p server))
      (should (equal base (java-kit-app--tomcat-base context home)))
      (should (equal "server"
                     (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name "conf/server.xml" base))
                       (buffer-string))))
      (dolist (directory '("logs" "temp" "webapps" "work"))
        (should (file-directory-p (expand-file-name directory base)))))))

(ert-deftest java-kit-test-tomcat-managed-base-skips-host-contexts ()
  (java-kit-test--with-temp-directory root
    (let* ((home (java-kit-test--fake-tomcat
                  (expand-file-name "tomcat-home" root)))
           (base (expand-file-name "instance" root))
           (context (expand-file-name
                     "conf/Catalina/localhost/system.xml" home)))
      (java-kit-test--write-file
       (expand-file-name "conf/server.xml" home) "server")
      (java-kit-test--write-file context "system context")
      (java-kit-app--prepare-managed-tomcat-base home base)
      (should (file-exists-p (expand-file-name "conf/server.xml" base)))
      (should-not
       (file-exists-p
        (expand-file-name "conf/Catalina/localhost/system.xml" base))))))

(ert-deftest java-kit-test-tomcat-managed-base-requires-readable-config ()
  (java-kit-test--with-temp-directory root
    (let* ((home (java-kit-test--fake-tomcat
                  (expand-file-name "tomcat-home" root)))
           (base (expand-file-name "instance" root))
           (server-conf (expand-file-name "conf/server.xml" home)))
      (java-kit-test--write-file server-conf "server")
      (cl-letf (((symbol-function 'file-readable-p)
                 (lambda (file) (not (equal file server-conf)))))
        (should-error
         (java-kit-app--prepare-managed-tomcat-base home base)
         :type 'user-error)))))

(ert-deftest java-kit-test-tomcat-base-must-be-writable ()
  (java-kit-test--with-temp-directory root
    (let* ((home (java-kit-test--fake-tomcat root))
           (context (list :name "sample"))
           (java-kit-tomcat-base home))
      (cl-letf (((symbol-function 'file-writable-p)
                 (lambda (_file) nil)))
        (should-error (java-kit-app--tomcat-base context home)
                      :type 'user-error)))))

(ert-deftest java-kit-test-tomcat-environment-is-process-local ()
  (let ((context (list :name "sample"))
        (java-kit-tomcat-debug-port 8100))
    (cl-letf (((symbol-function 'java-kit-project-process-environment)
               (lambda (&optional _context)
                 '("PATH=/project/jdk/bin:/usr/bin" "KEEP=yes"))))
      (let ((environment
             (java-kit-app--tomcat-process-environment
              context "/usr/share/tomcat10" "/var/lib/tomcat10" t)))
        (should (member "CATALINA_HOME=/usr/share/tomcat10" environment))
        (should (member "CATALINA_BASE=/var/lib/tomcat10" environment))
        (should (member "JPDA_ADDRESS=8100" environment))
        (should (member "KEEP=yes" environment))
        (should-not (getenv "CATALINA_HOME"))
        (should-not (getenv "CATALINA_BASE"))))))

(ert-deftest java-kit-test-tomcat-runtime-jdk-is-independent ()
  (java-kit-test--with-temp-directory runtime-jdk
    (java-kit-test--fake-jdk runtime-jdk "21")
    (let ((context (list :name "legacy"))
          (java-kit-tomcat-java-home runtime-jdk))
      (cl-letf (((symbol-function 'java-kit-project-process-environment)
                 (lambda (&optional _context)
                   '("JAVA_HOME=/project/jdk8"
                     "PATH=/project/jdk8/bin:/usr/bin"
                     "KEEP=yes"))))
        (let ((environment
               (java-kit-app--tomcat-process-environment
                context "/tomcat" "/instance" nil)))
          (should (member (concat "JAVA_HOME=" runtime-jdk) environment))
          (should
           (equal (concat (expand-file-name "bin" runtime-jdk) ":/usr/bin")
                  (java-kit--environment-value "PATH" environment)))
          (should (member "KEEP=yes" environment)))))))

(ert-deftest java-kit-test-tomcat-conflict-detects-shared-port ()
  (let* ((context (list :name "first" :module-root "/first/"))
         (key (java-kit-app--key context 'tomcat))
         (service (java-kit-app--service-create
                   :key key :kind 'tomcat :context context
                   :process 'tomcat-process :status 'running
                   :port 8080 :base "/instances/first"))
         (java-kit-app--services (make-hash-table :test #'equal)))
    (puthash key service java-kit-app--services)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (process) (eq process 'tomcat-process))))
      (should (eq service
                  (java-kit-app--tomcat-conflict "/instances/second" 8080)))
      (should-not
       (java-kit-app--tomcat-conflict "/instances/second" 9090)))))

(ert-deftest java-kit-test-tomcat-switch-stops-managed-port-owner ()
  (let* ((owner-context (list :name "first" :module-root "/first/"))
         (current-context (list :name "second" :module-root "/second/"))
         (service (java-kit-app--service-create
                   :kind 'tomcat :context owner-context
                   :process 'tomcat-process
                   :status 'running :port 8080 :base "/instances/first"))
         callback
         stopped)
    (cl-letf (((symbol-function 'java-kit-project-context)
               (lambda (&optional _directory) current-context))
              ((symbol-function 'java-kit-app--tomcat-home)
               (lambda (_context) "/tomcat"))
              ((symbol-function 'java-kit-app--tomcat-base)
               (lambda (_context _home) "/instances/second"))
              ((symbol-function 'java-kit-app--build-arguments)
               (lambda (_context _purpose) '("mvn" "package")))
              ((symbol-function 'java-kit-app--start-process)
               (lambda (&rest arguments)
                 (setq callback
                       (plist-get (nthcdr 4 arguments) :on-success))))
              ((symbol-function 'java-kit-app--tomcat-conflict)
               (lambda (_base _port) service))
              ((symbol-function 'java-kit-app--stop)
               (lambda (stopped-context kind &optional quiet)
                 (push (list stopped-context kind quiet) stopped)))
              ((symbol-function 'java-kit-app--deploy-war)
               (lambda (_context _base) "/instances/second/webapps/app.war"))
              ((symbol-function 'java-kit-app--start-tomcat) #'ignore))
      (java-kit-tomcat-deploy)
      (should callback)
      (funcall callback))
    (should (equal (list (list current-context 'tomcat t)
                         (list owner-context 'tomcat t))
                   (nreverse stopped)))))

(ert-deftest java-kit-test-tomcat-deploy-selects-newest-war ()
  (java-kit-test--with-temp-directory root
    (let* ((module (file-name-as-directory (expand-file-name "app" root)))
           (target (expand-file-name "target" module))
           (home (file-name-as-directory (expand-file-name "tomcat" root)))
           (old (java-kit-test--write-file
                 (expand-file-name "old.war" target) "old"))
           (new (java-kit-test--write-file
                 (expand-file-name "new.war" target) "new"))
           (context (list :module-root module :build-system 'maven))
           (java-kit-tomcat-context-name "ROOT"))
      (make-directory (expand-file-name "webapps" home) t)
      (java-kit-test--write-file
       (expand-file-name "webapps/keep.txt" home) "keep")
      (set-file-times old (seconds-to-time 1))
      (set-file-times new (seconds-to-time 2))
      (let ((destination (java-kit-app--deploy-war context home)))
        (should (equal (expand-file-name "webapps/ROOT.war" home)
                       destination))
        (should (equal "new"
                       (with-temp-buffer
                         (insert-file-contents destination)
                         (buffer-string))))
        (should (file-exists-p
                 (expand-file-name "webapps/keep.txt" home)))))))

(ert-deftest java-kit-test-tomcat-deploy-resets-managed-runtime ()
  (java-kit-test--with-temp-directory root
    (let* ((module (file-name-as-directory (expand-file-name "app" root)))
           (target (expand-file-name "target" module))
           (java-kit-tomcat-instance-directory
            (expand-file-name "instances" root))
           (base (expand-file-name "sample" java-kit-tomcat-instance-directory))
           (context (list :module-root module :build-system 'maven)))
      (java-kit-test--write-file
       (expand-file-name "sample.war" target) "new")
      (java-kit-test--write-file
       (expand-file-name "webapps/old/WEB-INF/web.xml" base) "old")
      (java-kit-test--write-file
       (expand-file-name "work/Catalina/localhost/old" base) "old")
      (should (equal (expand-file-name "webapps/sample.war" base)
                     (java-kit-app--deploy-war context base)))
      (should-not (file-exists-p (expand-file-name "webapps/old" base)))
      (should-not
       (directory-files (expand-file-name "work" base) nil
                        directory-files-no-dot-files-regexp)))))

(ert-deftest java-kit-test-tomcat-restart-rebuilds-and-redeploys ()
  (let (deploy-debug)
    (cl-letf (((symbol-function 'java-kit-tomcat-deploy)
               (lambda (&optional debug)
                 (setq deploy-debug debug))))
      (java-kit-tomcat-restart 'debug))
    (should (eq 'debug deploy-debug))))

(ert-deftest java-kit-test-app-stop-can-silence-missing-process ()
  (let ((context (list :name "sample"))
        messages)
    (cl-letf (((symbol-function 'java-kit-app--live-service)
               (lambda (_context _kind) nil))
              ((symbol-function 'message)
               (lambda (format-string &rest arguments)
                 (push (apply #'format format-string arguments) messages))))
      (should-not (java-kit-app--stop context 'tomcat t))
      (should-not messages)
      (should-not (java-kit-app--stop context 'tomcat))
      (should (equal '("No java-kit tomcat process is active for sample")
                     messages)))))

(ert-deftest java-kit-test-app-process-starts-in-module-root ()
  (java-kit-test--with-temp-directory root
    (let* ((module (file-name-as-directory (expand-file-name "app" root)))
           (source (file-name-as-directory
                    (expand-file-name "src/main/java/example" module)))
           (context (list :name "sample" :module-root module))
           (default-directory source)
           (java-kit-app--services (make-hash-table :test #'equal))
           (global-mode-string nil)
           process-directory)
      (make-directory source t)
      (unwind-protect
          (cl-letf (((symbol-function 'java-kit--command-available-p)
                     (lambda (_program) t))
                    ((symbol-function 'make-process)
                     (lambda (&rest _parameters)
                       (setq process-directory default-directory)
                       'fake-process))
                    ((symbol-function 'java-kit-app--refresh-mode-line)
                     #'ignore)
                    ((symbol-function 'display-buffer) #'ignore))
            (java-kit-app--start-process
             context 'tomcat-build '("mvn" "package") 'building)
            (should (equal module process-directory)))
        (when-let* ((buffer (get-buffer "*java-kit tomcat-build:sample*")))
          (kill-buffer buffer))))))

(ert-deftest java-kit-test-app-stop-only-signals-current-module-process ()
  (java-kit-test--with-temp-directory root
    (let* ((first-context
            (list :name "first"
                  :module-root
                  (file-name-as-directory (expand-file-name "first" root))))
           (second-context
            (list :name "second"
                  :module-root
                  (file-name-as-directory (expand-file-name "second" root))))
           (first-key (java-kit-app--key first-context 'spring-boot))
           (second-key (java-kit-app--key second-context 'spring-boot))
           (java-kit-app--services (make-hash-table :test #'equal))
           (global-mode-string nil)
           deleted)
      (puthash first-key
               (java-kit-app--service-create
                :key first-key :kind 'spring-boot :context first-context
                :process 'first-process :status 'running :port 8080)
               java-kit-app--services)
      (puthash second-key
               (java-kit-app--service-create
                :key second-key :kind 'spring-boot :context second-context
                :process 'second-process :status 'running :port 8081)
               java-kit-app--services)
      (cl-letf (((symbol-function 'java-kit-project-context)
                 (lambda (&optional _directory) first-context))
                ((symbol-function 'process-live-p)
                 (lambda (process)
                   (memq process '(first-process second-process))))
                ((symbol-function 'process-put)
                 (lambda (&rest _arguments) nil))
                ((symbol-function 'delete-process)
                 (lambda (process) (setq deleted process)))
                ((symbol-function 'force-mode-line-update)
                 (lambda (&optional _all) nil)))
        (java-kit-spring-boot-stop))
      (should (eq 'first-process deleted))
      (should-not (gethash first-key java-kit-app--services))
      (should (gethash second-key java-kit-app--services)))))

(ert-deftest java-kit-test-debug-main-public-workflow-builds-dape-launch ()
  (java-kit-test--with-temp-directory root
    (let* ((file (java-kit-test--write-file
                  (expand-file-name "Main.java" root)))
           (project-jdk (java-kit-test--fake-jdk
                         (expand-file-name
                          "Library/Java/JavaVirtualMachines/temurin-8.jdk/Contents/Home"
                          root)
                         "1.8.0_402"))
           (context (list :name "sample"
                          :root (file-name-as-directory root)
                          :module-root (file-name-as-directory root)))
           (java-kit-project-java-home project-jdk)
           (java-kit-project-java-version nil)
           (java-kit-main-arguments '("one" "two words"))
           (java-kit-main-jvm-arguments '("-ea"))
           (java-kit-main-environment '("APP_ENV=debug"))
           (java-kit-debug-build-before-launch nil)
           captured)
      (with-temp-buffer
        (setq buffer-file-name file)
        (cl-letf (((symbol-function 'java-kit--eglot-server)
                   (lambda () 'server))
                  ((symbol-function 'java-kit-project-context)
                   (lambda (&optional _directory) context))
                  ((symbol-function 'java-kit--debug-main-target)
                   (lambda (_server _context _file)
                     '(:mainClass "example.Main" :projectName "sample-jdt")))
                  ((symbol-function 'java-kit-debug--resolved-classpaths)
                   (lambda (_server _context _class)
                     '(("/tmp/modules") ("/tmp/classes"))))
                  ((symbol-function 'java-kit--debug-start)
                   (lambda (debug-context config)
                     (should (equal "sample-jdt" (plist-get debug-context :debug-project-name)))
                     (setq captured config))))
          (java-kit-debug-main)))
      (should-not (plist-member captured 'port))
      (should (equal "launch" (plist-get captured :request)))
      (should (equal "example.Main" (plist-get captured :mainClass)))
      (should (equal (expand-file-name "bin/java" project-jdk)
                     (plist-get captured :javaExec)))
      (should (equal ["/tmp/classes"]
                     (plist-get captured :classPaths)))
      (should (equal "one \"two words\""
                     (plist-get captured :args)))
      (should (equal '(:APP_ENV "debug")
                     (plist-get captured :env))))))

(ert-deftest java-kit-test-debug-test-launches-junit-console-through-adapter ()
  (java-kit-test--with-temp-directory root
    (let* ((project-jdk (java-kit-test--fake-jdk
                         (expand-file-name "jdk-17" root) "17.0.12"))
           (jar (java-kit-test--write-file
                 (expand-file-name "junit.jar" root)))
           (java-kit-junit-console-jar jar)
           (java-kit-project-java-home project-jdk)
           (java-kit-project-java-version nil)
           (java-kit-test-environment '("TEST_ENV=debug"))
           (context (list :name "sample"
                          :root (file-name-as-directory root)
                          :module-root (file-name-as-directory root)))
           (config
            (java-kit-debug--test-config
             context '("/tmp/test classes")
             "example.ExampleTest" "works")))
      (should (equal "org.junit.platform.console.ConsoleLauncher"
                     (plist-get config :mainClass)))
      (should (equal (expand-file-name "bin/java" project-jdk)
                     (plist-get config :javaExec)))
      (should (equal (vector jar)
                     (plist-get config :classPaths)))
      (should
       (string-match-p
        "--select-method example.ExampleTest#works"
        (plist-get config :args)))
      (should (equal '(:TEST_ENV "debug")
                     (plist-get config :env))))))

(ert-deftest java-kit-test-debug-adapter-syncs-public-java-debug-settings ()
  (let ((java-kit-hot-code-replace-mode 'manual)
        (java-kit-java-debug-request-timeout 45000)
        calls)
    (cl-letf (((symbol-function 'java-kit--jdtls-execute)
               (lambda (_server command arguments)
                 (push (list command arguments) calls)
                 (when (equal command "vscode.java.startDebugSession")
                   4711))))
      (should (= 4711 (java-kit-debug--adapter-port 'server))))
    (setq calls (nreverse calls))
    (should (equal "vscode.java.updateDebugSettings" (caar calls)))
    (let ((settings
           (json-parse-string
            (car (cadr (car calls))) :object-type 'plist)))
      (should (equal "manual" (plist-get settings :hotCodeReplace)))
      (should (= 45000 (plist-get settings :jdwpRequestTimeout))))
    (should (equal '("vscode.java.startDebugSession" nil)
                   (cadr calls)))))

(ert-deftest java-kit-test-debug-launch-preserves-environment-and-project-jdk ()
  (java-kit-test--with-temp-directory root
    (let* ((jdk (java-kit-test--fake-jdk
                 (expand-file-name "jdk 17" root) "17.0.12"))
           (java-kit-project-java-home jdk)
           (java-kit-main-environment '("APP_ENV=debug" "EMPTY=" "VALUE=a=b"))
           (java-kit-debug-console "integratedTerminal")
           (context (list :name "directory-name" :debug-project-name "jdt-name"
                          :root root :module-root root))
           (config (java-kit-debug--main-config
                    context "example.Main" nil '("/tmp/classes"))))
      (should (equal '(:APP_ENV "debug" :EMPTY "" :VALUE "a=b")
                     (plist-get config :env)))
      (should (equal (expand-file-name "bin/java" jdk)
                     (plist-get config :javaExec)))
      (should (equal "jdt-name" (plist-get config :projectName)))
      (should (equal "integratedTerminal" (plist-get config :console))))))

(ert-deftest java-kit-test-debug-launch-waits-for-successful-build ()
  (dolist (status '("SUCCEED" "WITH_ERROR" "FAILED" "CANCELLED" nil))
    (let ((java-kit-debug-build-before-launch t)
          success launched request)
      (cl-letf (((symbol-function 'jsonrpc-async-request)
                 (lambda (_server method arguments &rest callbacks)
                   (setq request (list method arguments)
                         success (plist-get callbacks :success-fn))))
                ((symbol-function 'java-kit--debug-start)
                 (lambda (_context config) (setq launched config))))
        (java-kit--debug-launch
         'server '(:name "directory-name" :module-root "/tmp/"
                   :debug-project-name "jdt-name")
         "example.Main" (lambda () '(:request "launch")))
        (should-not launched)
        (should (eq :workspace/executeCommand (car request)))
        (let ((params (json-parse-string
                       (aref (plist-get (cadr request) :arguments) 0)
                       :object-type 'plist)))
          (should (equal "jdt-name" (plist-get params :projectName))))
        (funcall success status)
        (should (eq (not (null launched)) (equal status "SUCCEED")))))))

(ert-deftest java-kit-test-hot-replace-does-not-resume-a-real-breakpoint ()
  (let* ((session (java-kit-debug--session-create :connection 'connection :state 'running))
         (java-kit-debug--sessions (make-hash-table :test #'equal))
         (java-kit-hot-code-replace-mode 'auto)
         resumed)
    (puthash "/tmp/" session java-kit-debug--sessions)
    (cl-letf (((symbol-function 'dape-request)
               (lambda (_connection command _arguments &optional callback)
                 (when (eq command :continue) (setq resumed t))
                 (funcall callback '(:changedClasses ["Example"]) nil)))
              ((symbol-function 'dape-handle-event) #'ignore))
      (java-kit-debug--request-hot-replace session)
      (java-kit-debug--stopped 'connection '(:reason "breakpoint" :threadId 7))
      (should-not resumed))))

(ert-deftest java-kit-test-debug-build-callbacks-report-cancellation-or-launch ()
  (dolist (outcome '(edited killed error timeout))
    (let ((source (generate-new-buffer " *java-kit source*"))
          (java-kit-debug-build-before-launch t)
          callbacks launched messages)
      (unwind-protect
          (cl-letf (((symbol-function 'save-some-buffers) #'ignore)
                    ((symbol-function 'jsonrpc-async-request)
                     (lambda (_server _method _arguments &rest options)
                       (setq callbacks options)))
                    ((symbol-function 'java-kit--debug-start)
                     (lambda (&rest _) (setq launched t)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest arguments)
                       (push (apply #'format format-string arguments) messages))))
            (with-current-buffer source
              (java-kit--debug-launch 'server '(:module-root "/tmp/") "Main"
                                      (lambda () '(:request "launch"))))
            (pcase outcome
              ('edited (with-current-buffer source (insert "changed")))
              ('killed (kill-buffer source)))
            (pcase outcome
              ('error (funcall (plist-get callbacks :error-fn) '(:message "failure")))
              ('timeout (funcall (plist-get callbacks :timeout-fn)))
              (_ (funcall (plist-get callbacks :success-fn) "SUCCEED")))
            (should (eq (not (null launched)) (eq outcome 'edited)))
            (should messages))
        (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest java-kit-test-debug-start-failure-cleans-pending-session ()
  (let ((java-kit--pending-session nil) session cancelled)
    (cl-letf (((symbol-function 'java-kit-debug--ensure-dape) #'ignore)
              ((symbol-function 'dape)
               (lambda (_)
                 (setq session (java-kit-debug--session-create :timer 'timer)
                       java-kit--pending-session session)
                 (error "Adapter startup failed")))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (setq cancelled timer))))
      (should-error (java-kit--debug-start nil '(:request "launch")))
      (should (eq cancelled 'timer))
      (should-not (java-kit-debug--session-timer session))
      (should-not java-kit--pending-session))))

(ert-deftest java-kit-test-debug-preparation-failure-allows-retry ()
  (let ((java-kit--pending-session nil)
        (java-kit-debug--sessions (make-hash-table :test #'equal))
        (fail t))
    (unwind-protect
        (cl-letf (((symbol-function 'java-kit--eglot-server) (lambda () 'server))
                  ((symbol-function 'java-kit-debug--adapter-port)
                   (lambda (_)
                     (if fail (error "Adapter unavailable") 4711))))
          (should-error (java-kit--debug-prepare
                         '(java-kit-context (:module-root "/tmp/"))))
          (should-not java-kit--pending-session)
          (setq fail nil)
          (should (= 4711 (plist-get (java-kit--debug-prepare
                                     '(java-kit-context (:module-root "/tmp/")))
                                    'port)))
          (should java-kit--pending-session))
      (when java-kit--pending-session (java-kit--debug-cleanup java-kit--pending-session)))))

(ert-deftest java-kit-test-debug-expired-request-preserves-new-pending-session ()
  (dolist (command '(:launch :attach "launch" "attach"))
    (dolist (with-callback '(nil t))
      (let* ((session (java-kit-debug--session-create :launch-id "current"))
             (java-kit--pending-session session)
             (dape-request-timeout nil)
             killed failure)
        (cl-letf (((symbol-function 'dape-kill)
                   (lambda (connection &optional callback &rest _)
                     (should (> dape-request-timeout 0))
                     (setq killed connection)
                     (when callback (funcall callback nil nil)))))
          (java-kit--debug-request
           (lambda (&rest _) (ert-fail "Expired request reached the adapter"))
           'expired-connection command '(:java-kit-session-id "expired")
           (when with-callback
             (lambda (body error)
               (should-not body)
               (setq failure error))))
          (should (eq killed 'expired-connection))
          (should (eq java-kit--pending-session session))
          (should-not (java-kit-debug--session-connection session))
          (should (eq (not (null failure)) with-callback)))))))

(ert-deftest java-kit-test-debug-project-name-comes-from-jdtls ()
  (cl-letf (((symbol-function 'java-kit--document-symbols)
             (lambda (_server _file)
               [(:kind 5 :selectionRange (:start (:line 4 :character 13)))]))
            ((symbol-function 'java-kit--jdtls-execute)
             (lambda (_server command arguments)
               (should (equal "vscode.java.resolveElementAtSelection" command))
               (should (equal '(4 13) (cdr arguments)))
               '(:projectName "not-the-directory-name"))))
    (should (equal "not-the-directory-name"
                   (java-kit--debug-project-name 'server "/tmp/Test.java")))))

(ert-deftest java-kit-test-debug-session-owns-timeout-and-abrupt-disconnect-cleanup ()
  (let ((java-kit--pending-session nil)
        (java-kit-debug--sessions (make-hash-table :test #'equal))
        (now 0) (running t) tick session killed)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest _) (setq tick function) nil))
              ((symbol-function 'float-time) (lambda (&rest _) now))
              ((symbol-function 'java-kit--eglot-server) (lambda () 'server))
              ((symbol-function 'java-kit-debug--adapter-port) (lambda (_) 4711))
              ((symbol-function 'jsonrpc-running-p) (lambda (_) running))
              ((symbol-function 'dape-kill)
               (lambda (connection &rest _) (setq killed connection))))
      (let ((config (java-kit--debug-prepare
                     (append '(java-kit-context (:module-root "/tmp/"))
                             (java-kit-debug--attach-config 5005)))))
        (should (= 4711 (plist-get config 'port)))
        (should (= 5005 (plist-get config :port))))
      (setq session java-kit--pending-session)
      (setf (java-kit-debug--session-connection session) 'connection)
      (java-kit-debug--initialized 'connection)
      (setq now 1000)
      (funcall tick)
      (should (eq session (gethash "/tmp/" java-kit-debug--sessions)))
      (setq running nil)
      (funcall tick)
      (should-not (gethash "/tmp/" java-kit-debug--sessions))
      (should-not killed)
      (java-kit--debug-prepare '(java-kit-context (:module-root "/tmp/")))
      ;; Creating the connection does not exempt an uninitialized session
      ;; from its deadline, even if the transport remains live.
      (setq running t)
      (setf (java-kit-debug--session-connection java-kit--pending-session) 'connection)
      (setq now 2000)
      (funcall tick)
      (should-not java-kit--pending-session)
      (should (eq killed 'connection)))))

(ert-deftest java-kit-test-debug-session-is-project-scoped-and-forgotten ()
  (let* ((java-kit-debug--sessions (make-hash-table :test #'equal))
         (java-kit--pending-session
          (java-kit-debug--session-create :scope "/tmp/sample/" :connection 'connection))
         (session (java-kit-debug--initialized 'connection)))
    (should (eq 'connection
                (java-kit-debug--session-connection session)))
    (should (eq session
                (gethash "/tmp/sample/" java-kit-debug--sessions)))
    (java-kit-debug--forget-connection 'connection)
    (should-not (gethash "/tmp/sample/" java-kit-debug--sessions))))

(ert-deftest java-kit-test-hot-replace-stopped-session-uses-public-request ()
  (let* ((session
          (java-kit-debug--session-create
           :connection 'connection :state 'stopped))
         (java-kit-hot-code-replace-mode 'manual)
         request)
    (cl-letf (((symbol-function 'dape-request)
               (lambda (connection command arguments &optional callback)
                 (setq request (list connection command arguments))
                 (funcall callback '(:changedClasses ["example.Main"]) nil)))
              ((symbol-function 'dape-continue)
               (lambda (_connection)
                 (ert-fail "A stopped manual request must not auto-resume"))))
      (java-kit-debug--request-hot-replace session t))
    (should (equal '(connection :redefineClasses nil) request))
    (should-not (java-kit-debug--session-hcr-in-progress session))))

(ert-deftest java-kit-test-hot-replace-running-session-pauses-and-resumes ()
  (let* ((session
          (java-kit-debug--session-create
           :connection 'connection :state 'running))
         (java-kit-debug--sessions (make-hash-table :test #'equal))
         (java-kit-hot-code-replace-mode 'auto)
         requests resumed)
    (puthash "/tmp/sample/" session java-kit-debug--sessions)
    (cl-letf (((symbol-function 'dape-request)
               (lambda (_connection command _arguments &optional callback)
                 (push command requests)
                 (funcall callback
                          (if (eq command :redefineClasses)
                              '(:changedClasses []) nil)
                          nil)))
              ((symbol-function 'dape-handle-event)
               (lambda (connection event body)
                 (should (eq event 'continued))
                 (should (eq t (plist-get body :allThreadsContinued)))
                 (setq resumed connection))))
      (java-kit-debug--request-hot-replace session)
      (should (java-kit-debug--session-hcr-pending session))
      (java-kit-debug--stopped 'connection
                               '(:reason "pause" :threadId 0 :allThreadsStopped t)))
    (should (equal '(:pause :redefineClasses :continue) (nreverse requests)))
    (should (eq 'connection resumed))
    (should-not (java-kit-debug--session-hcr-pending session))
    (should-not (java-kit-debug--session-resume-after-hcr session))))

(ert-deftest java-kit-test-hot-replace-build-event-honors-auto-mode ()
  (let* ((session
          (java-kit-debug--session-create
           :connection 'connection :state 'running))
         (java-kit-debug--sessions (make-hash-table :test #'equal))
         (java-kit-hot-code-replace-mode 'auto)
         called)
    (puthash "/tmp/sample/" session java-kit-debug--sessions)
    (cl-letf (((symbol-function 'java-kit-debug--request-hot-replace)
               (lambda (candidate &optional _interactive)
                 (setq called candidate))))
      (java-kit-debug--hot-code-replace-event
       'connection '(:changeType "BUILD_COMPLETE")))
    (should (eq session called))))

(ert-deftest java-kit-test-hot-replace-public-command-uses-current-module-session ()
  (let* ((context '(:name "sample" :module-root "/tmp/sample/"))
         (session
          (java-kit-debug--session-create
           :connection 'connection :state 'stopped))
         called)
    (cl-letf (((symbol-function 'java-kit-debug--ensure-dape) #'ignore)
              ((symbol-function 'java-kit-project-context)
               (lambda (&optional _directory) context))
              ((symbol-function 'java-kit-debug--session)
               (lambda (candidate)
                 (should (eq context candidate))
                 session))
              ((symbol-function 'java-kit-debug--request-hot-replace)
               (lambda (candidate &optional interactive)
                 (setq called (list candidate interactive)))))
      (java-kit-hot-replace))
    (should (equal (list session t) called))))

(ert-deftest java-kit-test-run-prefix-routes-to-debug-command ()
  (let (called)
    (cl-letf (((symbol-function 'java-kit-debug-main)
               (lambda () (setq called 'main)))
              ((symbol-function 'java-kit-debug-test)
               (lambda () (setq called 'test))))
      (java-kit-run-main t)
      (should (eq called 'main))
      (java-kit-run-test t)
      (should (eq called 'test)))))

(ert-deftest java-kit-test-console-run-and-debug-share-arguments ()
  (java-kit-test--with-temp-directory root
    (let ((java-kit-junit-console-jar
           (java-kit-test--write-file (expand-file-name "junit console.jar" root)))
          (java-kit-test-jvm-arguments '("-ea")))
      (cl-letf (((symbol-function 'java-kit--project-java-program) (lambda (_) "/jdk/bin/java")))
        (dolist (method '(nil "check(java.lang.String)"))
          (let* ((context (list :module-root root))
                 (command (java-kit--junit-command context '("/test classes") "p.Test" method))
                 (config (java-kit-debug--test-config context '("/test classes") "p.Test" method)))
            (should (equal (nth 3 command) (aref (plist-get config :classPaths) 0)))
            (should (equal (nthcdr 4 command)
                           (split-string-and-unquote (plist-get config :args))))))))))

(ert-deftest java-kit-test-spring-public-command-schedules-build-then-run ()
  (let ((context (list :name "sample" :module-root "/tmp/sample/"
                       :build-system 'gradle :wrapper "/tmp/sample/gradlew"))
        captured)
    (cl-letf (((symbol-function 'java-kit-project-context)
               (lambda (&optional _directory) context))
              ((symbol-function 'java-kit-app--live-service)
               (lambda (_context _kind) nil))
              ((symbol-function 'java-kit-app--build-arguments)
               (lambda (_context purpose)
                 (should (eq purpose 'spring-boot))
                 '("gradlew" "bootJar" "-x" "test")))
              ((symbol-function 'java-kit-app--start-process)
               (lambda (&rest arguments) (setq captured arguments))))
      (java-kit-spring-boot-run t))
    (should (equal '("gradlew" "bootJar" "-x" "test")
                   (nth 2 captured)))
    (should (eq 'spring-build (nth 1 captured)))
    (should (functionp (plist-get (nthcdr 4 captured) :on-success)))))

(ert-deftest java-kit-test-installer-discovers-newest-milestone-version ()
  (let ((index
         (concat
          "href='?file=jdtls%2Fmilestones%2F1.9.0' "
          "href='?file=jdtls%2Fmilestones%2F1.10.0' "
          "href='/jdtls/milestones/1.8.1/'")))
    (should (equal "1.10.0"
                   (java-kit-install--latest-milestone-version index)))))

(ert-deftest java-kit-test-installer-builds-official-jdtls-release-urls ()
  (let ((java-kit-jdtls-download-root
         "https://download.eclipse.org/jdtls/"))
    (should
     (equal
      '(:tool jdtls :channel "milestone" :version "1.60.0"
        :file "jdt-language-server-1.60.0-202606262232.tar.gz"
        :url "https://download.eclipse.org/jdtls/milestones/1.60.0/jdt-language-server-1.60.0-202606262232.tar.gz"
        :checksum-url "https://download.eclipse.org/jdtls/milestones/1.60.0/jdt-language-server-1.60.0-202606262232.tar.gz.sha256")
      (java-kit-install--jdtls-release-from-file
       'milestone
       "jdt-language-server-1.60.0-202606262232.tar.gz")))))

(ert-deftest java-kit-test-installer-parses-junit-release-metadata ()
  (should
   (equal "6.0.3"
          (java-kit-install--metadata-release
           (concat "<metadata><versioning><latest>6.1.0-M1</latest>"
                   "<release>6.0.3</release></versioning></metadata>"))))
  (should-not
   (java-kit-install--valid-artifact-version-p "../../unexpected")))

(ert-deftest java-kit-test-installer-prefers-newest-java-8-junit-line ()
  (let ((metadata
         (concat
          "<versions><version>1.14.3</version>"
          "<version>6.1.2</version><version>1.14.4</version>"
          "<version>1.15.0-M1</version></versions>")))
    (should
     (equal "1.14.4"
            (java-kit-install--latest-java-8-junit-version metadata)))))

(ert-deftest java-kit-test-installer-verifies-sha256-before-use ()
  (java-kit-test--with-temp-directory root
    (let* ((file (java-kit-test--write-file
                  (expand-file-name "artifact" root) "verified bytes"))
           (digest (java-kit-install--file-sha256 file)))
      (should
       (equal digest
              (java-kit-install--verify-download
               file (concat digest "  artifact\n"))))
      (should-error
       (java-kit-install--verify-download
        file (concat (make-string 64 ?0) "  artifact\n"))))))

(ert-deftest java-kit-test-archive-path-check-rejects-traversal ()
  (java-kit-test--with-temp-directory root
    (should
     (java-kit--safe-archive-entry-p "bin/jdtls" root))
    (should-not
     (java-kit--safe-archive-entry-p "../outside" root))
    (should-not
     (java-kit--safe-archive-entry-p "/tmp/outside" root))
    (should-not
     (java-kit--safe-archive-entry-p
      "demo/../../../outside" root))))

(ert-deftest java-kit-test-installer-directory-replacement-is-transactional ()
  (java-kit-test--with-temp-directory root
    (let ((destination (expand-file-name "tool" root))
          (staged (expand-file-name "stage" root)))
      (java-kit-test--write-file
       (expand-file-name "old" destination) "old")
      (java-kit-test--write-file
       (expand-file-name "new" staged) "new")
      (java-kit-install--replace-directory staged destination)
      (should-not (file-exists-p (expand-file-name "old" destination)))
      (should (file-exists-p (expand-file-name "new" destination)))
      (should-not (file-exists-p staged)))))

(ert-deftest java-kit-test-installed-jdtls-launcher-precedes-path-fallback ()
  (java-kit-test--with-temp-directory root
    (let* ((java-kit-jdtls-install-directory
            (expand-file-name "jdtls" root))
           (java-kit-jdtls-command nil)
           (launcher (java-kit-test--write-file
                      (expand-file-name "bin/jdtls"
                                        java-kit-jdtls-install-directory)
                      "#!/bin/sh\n" #o755)))
      (should (equal (list launcher)
                     (java-kit--effective-jdtls-command))))))

(ert-deftest java-kit-test-install-command-skips-current-release-unless-forced ()
  (let ((release (list :version "1.2.3"))
        installed)
    (cl-letf (((symbol-function 'java-kit-install--jdtls-release)
               (lambda () release))
              ((symbol-function 'java-kit-install--read-version)
               (lambda (_file) "1.2.3"))
              ((symbol-function 'java-kit-install--install-jdtls-release)
               (lambda (actual) (setq installed actual))))
      (java-kit-install-jdtls)
      (should-not installed)
      (java-kit-install-jdtls t)
      (should (eq release installed)))))

(ert-deftest java-kit-test-new-source-paths-normalize-jdtls-response ()
  (let* ((main (list :path "/project/src/main/java"
                     :displayPath "src/main/java"))
         (test (list :path "/project/src/test/java"
                     :displayPath "src/test/java"))
         (response (list :metadata "ignored" (vector main test))))
    (should (equal (list main test)
                   (java-kit-new--source-paths response)))))

(ert-deftest java-kit-test-new-java-type-uses-selected-source-root ()
  (java-kit-test--with-temp-directory root
    (let* ((current (java-kit-test--write-file
                     (expand-file-name "Current.java" root)))
           (source-root (expand-file-name "src/main/java" root))
           destination)
      (with-temp-buffer
        (setq buffer-file-name current)
        (cl-letf (((symbol-function 'java-kit--eglot-server)
                   (lambda () 'server))
                  ((symbol-function 'java-kit--jdtls-execute)
                   (lambda (_server command _arguments)
                     (should (equal "java.project.listSourcePaths" command))
                     (vector
                      (list :path source-root
                            :displayPath "src/main/java"))))
                  ((symbol-function 'java-kit-new--package-at-point)
                   (lambda (_server _file) "com.example"))
                  ((symbol-function 'find-file)
                   (lambda (file) (setq destination file))))
          (java-kit-new-java-type
           "com.example.Widget" "record" source-root)))
      (should
       (equal (expand-file-name "com/example/Widget.java" source-root)
              destination))
      (should
       (equal (concat "package com.example;\n\n"
                      "public record Widget() {\n}\n")
              (with-temp-buffer
                (insert-file-contents destination)
                (buffer-string)))))))

(ert-deftest java-kit-test-new-java-name-validation-rejects-empty-components ()
  (should (java-kit-new--qualified-java-name-p "com.example.Valid_Name"))
  (should-not (java-kit-new--qualified-java-name-p ""))
  (should-not (java-kit-new--qualified-java-name-p "com.9invalid"))
  (should-not (java-kit-new--project-name-p "../outside")))

(ert-deftest java-kit-test-new-spring-url-uses-official-parameter-names ()
  (let* ((java-kit-new-spring-url "https://start.spring.io/")
         (url
          (java-kit-new--spring-url
           '(:build gradle-kotlin :group "org.example" :artifact "demo"
             :package "org.example.demo" :java "21"
             :dependencies ("web" "data-jpa")))))
    (should (string-prefix-p "https://start.spring.io/starter.zip?" url))
    (should (string-match-p "type=gradle-project-kotlin" url))
    (should (string-match-p "groupId=org.example" url))
    (should (string-match-p "dependencies=web,data-jpa" url))))

(ert-deftest java-kit-test-new-provider-urls-map-build-systems ()
  (let ((spec
         '(:group "org.acme" :artifact "demo" :package "org.acme.demo"
           :build maven :java "21" :dependencies ("rest" "jdbc"))))
    (let ((micronaut (java-kit-new--micronaut-url spec))
          (quarkus (java-kit-new--quarkus-url spec))
          (vertx (java-kit-new--vertx-url spec)))
      (should
       (string-prefix-p
        "https://launch.micronaut.io/create/default/org.acme.demo?"
        micronaut))
      (should-not (string-match-p "org.acme.demo.demo" micronaut))
      (should (string-match-p "build=MAVEN" micronaut))
      (should (string-match-p "e=rest&e=jdbc" quarkus))
      (should-not (string-match-p "S=nil" quarkus))
      (should (string-match-p "buildTool=maven" vertx)))))

(ert-deftest java-kit-test-new-project-public-spec-dispatches-remote-safely ()
  (java-kit-test--with-temp-directory parent
    (let ((spec
           (list :provider 'spring :parent parent :group "com.example"
                 :artifact "demo" :package "com.example.demo"
                 :build 'maven :java "21" :dependencies '("web")))
          captured)
      (cl-letf (((symbol-function 'java-kit-new--starter-url)
                 (lambda (_spec) "https://start.example/starter.zip"))
                ((symbol-function 'java-kit-new--download-project)
                 (lambda (url destination)
                   (setq captured (list url destination))
                   destination)))
        (java-kit-new-project-from-spec spec))
      (should
       (equal (list "https://start.example/starter.zip"
                    (expand-file-name "demo" parent))
              captured)))))

(provide 'java-kit-test)
;;; java-kit-test.el ends here
