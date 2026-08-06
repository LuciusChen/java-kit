;;; java-kit.el --- Project-aware Java tools for Eglot  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen

;; Author: Lucius Chen <chenyh572@gmail.com>
;; Assisted-by: OpenAI Codex:gpt-5.6-sol, Claude code:fable-5
;; Maintainer: Lucius Chen <chenyh572@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools
;; URL: https://github.com/LuciusChen/java-kit

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

;; java-kit provides project-aware Java tools built around the facilities
;; included with Emacs.  It registers JDTLS with Eglot, keeps the JDK used to
;; launch JDTLS separate from the JDK used by project processes, detects Maven
;; and Gradle modules, prefers project wrappers, and exposes build, run, test,
;; and project-refresh commands.  Separate modules provide installation,
;; scaffolding, application lifecycle, debugging, and Hot Code Replace without
;; relying on dependency-private APIs.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'eglot)
(require 'json)
(require 'jsonrpc)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'url-parse)

(defgroup java-kit nil
  "Focused Java project tools."
  :group 'languages
  :prefix "java-kit-")

(defcustom java-kit-auto-start-eglot t
  "Whether enabling `java-kit-mode' should start Eglot."
  :type 'boolean
  :group 'java-kit)

(defcustom java-kit-jdtls-install-directory
  (expand-file-name "java-kit/tools/jdtls" user-emacs-directory)
  "Directory used by `java-kit-install-jdtls'."
  :type 'directory
  :group 'java-kit)

(defcustom java-kit-jdtls-command nil
  "Optional command and arguments used to start the JDTLS launcher.

When nil, prefer java-kit's installed launcher and then `jdtls' on PATH."
  :type '(choice (const :tag "Installed launcher or PATH" nil)
                 (repeat :tag "Explicit command" string))
  :group 'java-kit)

(defcustom java-kit-jdtls-java-home nil
  "JDK home used only for the JDTLS process.

The value may be nil, a directory name, or a function.  A function receives
the current project context and should return a directory name or nil.  A nil
value lets JDTLS inherit the current process environment."
  :type '(choice (const :tag "Inherit environment" nil)
                 (directory :tag "JDK home")
                 (function :tag "Resolver function"))
  :group 'java-kit)

(defcustom java-kit-jdtls-jvm-arguments nil
  "JVM arguments passed to the JDTLS launcher.

Each value is converted to a `--jvm-arg=VALUE' launcher argument."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-jdtls-bundles nil
  "Additional JAR bundles passed in JDTLS initialization options.

The Microsoft Java debug adapter plugin can be configured here."
  :type '(repeat file)
  :group 'java-kit)

(defcustom java-kit-jdtls-workspace-directory
  (expand-file-name "java-kit/jdtls/" user-emacs-directory)
  "Directory containing per-project JDTLS workspace data."
  :type 'directory
  :group 'java-kit)

(defcustom java-kit-jdt-class-cache-directory
  (expand-file-name "java-kit/classfiles" user-emacs-directory)
  "Directory used for read-only source returned for JDTLS `jdt://' URIs."
  :type 'directory
  :group 'java-kit)

(defcustom java-kit-jdtls-extra-initialization-options nil
  "Extra JDTLS initialization options.

This plist is shallowly merged into java-kit's default options."
  :type 'plist
  :group 'java-kit)

(defcustom java-kit-project-java-home nil
  "Optional JDK home override for project build processes.

The value may be nil, a directory name, or a function.  A function receives
the project context and should return a directory name or nil.  This setting
does not control the JDK used to launch JDTLS."
  :type '(choice (const :tag "Detect from project" nil)
                 (directory :tag "JDK home")
                 (function :tag "Resolver function"))
  :group 'java-kit)

(defcustom java-kit-project-java-version nil
  "Optional Java major-version override for project build processes.

The value may be nil, a version string, or a function receiving the project
context.  When nil, java-kit checks common project version files and build
configuration."
  :type '(choice (const :tag "Detect from project" nil)
                 (string :tag "Java version")
                 (function :tag "Resolver function"))
  :group 'java-kit)

(defcustom java-kit-maven-default-task "test"
  "Default task offered for Maven builds."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-gradle-default-task "test"
  "Default task offered for Gradle builds."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-main-arguments nil
  "Program arguments passed by `java-kit-run-main'."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-main-jvm-arguments nil
  "JVM arguments passed by `java-kit-run-main'."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-main-environment nil
  "Environment entries added only to `java-kit-run-main' processes.

Each entry has the form `NAME=VALUE'."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-test-jvm-arguments nil
  "JVM arguments passed by `java-kit-run-test'."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-test-environment nil
  "Environment entries added only to `java-kit-run-test' processes.

Each entry has the form `NAME=VALUE'."
  :type '(repeat string)
  :group 'java-kit)

(defcustom java-kit-junit-console-jar
  (expand-file-name
   "java-kit/tools/junit-platform-console-standalone.jar"
   user-emacs-directory)
  "JUnit Platform Console standalone JAR used to run focused tests."
  :type 'file
  :group 'java-kit)

(defconst java-kit--eglot-modes '(java-mode java-ts-mode)
  "Major modes managed by java-kit's JDTLS instance.")

(defconst java-kit--project-markers
  '("pom.xml" "build.gradle" "build.gradle.kts"
    "settings.gradle" "settings.gradle.kts" ".git")
  "Files and directories that identify a Java project root.")

(defconst java-kit--lsp-package-kind 4
  "LSP SymbolKind value for packages.")

(defconst java-kit--lsp-type-kinds '(5 10 11 23)
  "LSP SymbolKind values that java-kit treats as Java types.")

(defconst java-kit--lsp-method-kind 6
  "LSP SymbolKind value for methods.")

(defconst java-kit--jdt-uri-write-operations
  '(write-region delete-file rename-file add-name-to-file
    make-symbolic-link set-file-modes set-file-times)
  "File operations rejected for read-only JDTLS class contents.")

(defvar java-kit--project-java-home-selections (make-hash-table :test #'equal)
  "Interactive project JDK choices keyed by build-module root.")

(defvar java-kit-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c C-j b" #'java-kit-build)
    (keymap-set map "C-c C-j t" #'java-kit-test)
    (keymap-set map "C-c C-j m" #'java-kit-run-main)
    (keymap-set map "C-c C-j u" #'java-kit-run-test)
    (keymap-set map "C-c C-j r" #'java-kit-project-refresh)
    (keymap-set map "C-c C-j d" #'java-kit-debug-main)
    (keymap-set map "C-c C-j D" #'java-kit-debug-test)
    (keymap-set map "C-c C-j h" #'java-kit-hot-replace)
    (keymap-set map "C-c C-j n" #'java-kit-new-java-type)
    (keymap-set map "C-c C-j N" #'java-kit-new-project)
    (keymap-set map "C-c C-j j" #'java-kit-select-project-jdk)
    map)
  "Keymap for `java-kit-mode'.")

(autoload 'java-kit-debug-main "java-kit-debug"
  "Debug the current Java main class through JDTLS and Dape." t)
(autoload 'java-kit-debug-test "java-kit-debug"
  "Debug the JUnit class or method at point through JDTLS and Dape." t)
(autoload 'java-kit-dape-attach "java-kit-debug"
  "Attach Dape through JDTLS to a listening JVM." t)
(autoload 'java-kit-hot-replace "java-kit-debug"
  "Replace changed classes in the current Java debug session." t)
(autoload 'java-kit-spring-boot-run "java-kit-app" nil t)
(autoload 'java-kit-spring-boot-stop "java-kit-app" nil t)
(autoload 'java-kit-spring-boot-restart "java-kit-app" nil t)
(autoload 'java-kit-tomcat-deploy "java-kit-app" nil t)
(autoload 'java-kit-tomcat-stop "java-kit-app" nil t)
(autoload 'java-kit-tomcat-restart "java-kit-app" nil t)
(autoload 'java-kit-app-status "java-kit-app" nil t)
(autoload 'java-kit-detect-tomcat-home "java-kit-app" nil nil)
(autoload 'java-kit-install-jdtls "java-kit-install" nil t)
(autoload 'java-kit-install-junit "java-kit-install" nil t)
(autoload 'java-kit-tools-status "java-kit-install" nil t)
(autoload 'java-kit-new-java-type "java-kit-new" nil t)
(autoload 'java-kit-new-project "java-kit-new" nil t)

(defun java-kit--start-directory (&optional directory)
  "Return a normalized starting directory for DIRECTORY."
  (let ((path (expand-file-name
               (or directory
                   (and buffer-file-name
                        (file-name-directory buffer-file-name))
                   default-directory))))
    (file-name-as-directory
     (if (file-directory-p path)
         path
       (file-name-directory path)))))

(defun java-kit--has-project-marker-p (directory)
  "Return non-nil when DIRECTORY contains a known project marker."
  (seq-some (lambda (marker)
              (file-exists-p (expand-file-name marker directory)))
            java-kit--project-markers))

(defun java-kit-project-root (&optional directory)
  "Return the project root containing DIRECTORY.

Use `project.el' first and fall back to known Java and Git markers."
  (let* ((start (java-kit--start-directory directory))
         (project (project-current nil start))
         (root (or (and project (project-root project))
                   (locate-dominating-file
                    start #'java-kit--has-project-marker-p))))
    (unless root
      (user-error "Could not find a project root from %s" start))
    (file-name-as-directory (expand-file-name root))))

(defun java-kit--build-system-at (directory)
  "Return the build-system symbol detected in DIRECTORY."
  (cond
   ((file-exists-p (expand-file-name "pom.xml" directory)) 'maven)
   ((or (file-exists-p (expand-file-name "build.gradle" directory))
        (file-exists-p (expand-file-name "build.gradle.kts" directory)))
    'gradle)))

(defun java-kit--parent-directory (directory)
  "Return the parent of DIRECTORY, or nil at the file-system root."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (parent (file-name-directory (directory-file-name directory))))
    (unless (equal directory parent)
      parent)))

(defun java-kit--nearest-build-root (directory project-root)
  "Find the nearest build root above DIRECTORY, bounded by PROJECT-ROOT."
  (let ((current (java-kit--start-directory directory))
        (limit (file-name-as-directory (expand-file-name project-root)))
        found)
    (while (and current
                (or (equal current limit)
                    (file-in-directory-p current limit))
                (not found))
      (if (java-kit--build-system-at current)
          (setq found current)
        (if (equal current limit)
            (setq current nil)
          (setq current (java-kit--parent-directory current)))))
    found))

(defun java-kit--build-file (directory build-system)
  "Return the primary build file in DIRECTORY for BUILD-SYSTEM."
  (pcase build-system
    ('maven (expand-file-name "pom.xml" directory))
    ('gradle
     (let ((kotlin-file (expand-file-name "build.gradle.kts" directory)))
       (if (file-exists-p kotlin-file)
           kotlin-file
         (expand-file-name "build.gradle" directory))))))

(defun java-kit--wrapper-name (build-system)
  "Return the wrapper file name for BUILD-SYSTEM."
  (pcase build-system
    ('maven "mvnw")
    ('gradle "gradlew")))

(defun java-kit--find-wrapper (build-system module-root project-root)
  "Find BUILD-SYSTEM wrapper in MODULE-ROOT or PROJECT-ROOT."
  (when-let* ((wrapper-name (java-kit--wrapper-name build-system)))
    (cl-loop for directory in (delete-dups (list module-root project-root))
             for candidate = (expand-file-name wrapper-name directory)
             when (file-regular-p candidate)
             return candidate)))

(defun java-kit-project-context (&optional directory)
  "Return a plist describing the Java project around DIRECTORY.

The plist contains `:root', `:module-root', `:name', `:build-system',
`:build-file', and `:wrapper'.  Build-related values may be nil for a plain
Java project without Maven or Gradle metadata."
  (let* ((start (java-kit--start-directory directory))
         (root (java-kit-project-root start))
         (module-root (or (java-kit--nearest-build-root start root) root))
         (build-system (java-kit--build-system-at module-root)))
    (list :root root
          :module-root module-root
          :name (file-name-nondirectory (directory-file-name module-root))
          :build-system build-system
          :build-file (and build-system
                           (java-kit--build-file module-root build-system))
          :wrapper (and build-system
                        (java-kit--find-wrapper
                         build-system module-root root)))))

(defun java-kit--module-scope (context)
  "Return CONTEXT's normalized build-module scope."
  (file-name-as-directory
   (expand-file-name (plist-get context :module-root))))

(defun java-kit--configured-value (value context)
  "Resolve customizable VALUE for CONTEXT."
  (if (functionp value)
      (funcall value context)
    value))

(defun java-kit--safe-archive-entry-p (name destination)
  "Return non-nil when archive NAME remains inside DESTINATION."
  (let* ((destination
          (file-name-as-directory (expand-file-name destination)))
         (target (expand-file-name name destination)))
    (and (not (file-name-absolute-p name))
         (or (equal (directory-file-name target)
                    (directory-file-name destination))
             (file-in-directory-p target destination)))))

(defun java-kit--read-first-line (file)
  "Return the first non-empty line from FILE, trimmed."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "[^[:space:]].*" nil t)
        (string-trim (match-string 0))))))

(defun java-kit--extract-java-major (value)
  "Extract a Java major-version string from VALUE."
  (when (and value (not (string-empty-p value)))
    (cond
     ((string-match "\\(?:^\\|[^0-9]\\)1[._]\\([0-9]+\\)" value)
      (match-string 1 value))
     ((string-match "\\([0-9]+\\)" value)
      (match-string 1 value)))))

(defun java-kit--file-match (file regexp)
  "Return the first matching group for REGEXP in FILE."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward regexp nil t)
        (string-trim (match-string 1))))))

(defun java-kit--pom-property (content property)
  "Return PROPERTY from Maven POM CONTENT."
  (let ((tag (regexp-quote property)))
    (when (string-match
           (format "<%s>[[:space:]]*\\([^<]+\\)[[:space:]]*</%s>"
                   tag tag)
           content)
      (string-trim (match-string 1 content)))))

(defun java-kit--pom-resolve-value (content value &optional seen)
  "Resolve a Maven property expression VALUE in CONTENT.

SEEN tracks property names already visited."
  (if (and value (string-match "^\\${\\([^}]+\\)}$" value))
      (let ((property (match-string 1 value)))
        (unless (member property seen)
          (java-kit--pom-resolve-value
           content
           (java-kit--pom-property content property)
           (cons property seen))))
    value))

(defun java-kit--maven-java-version (pom-file)
  "Return the declared Java version from POM-FILE."
  (when (file-readable-p pom-file)
    (with-temp-buffer
      (insert-file-contents pom-file)
      (let* ((content (buffer-string))
             (value (or (java-kit--pom-property
                         content "maven.compiler.release")
                        (java-kit--pom-property content "java.version")
                        (java-kit--pom-property
                         content "maven.compiler.source"))))
        (java-kit--extract-java-major
         (java-kit--pom-resolve-value content value))))))

(defun java-kit--gradle-java-version (module-root)
  "Return the declared Java version under MODULE-ROOT."
  (let ((build-file (or
                     (let ((file (expand-file-name
                                  "build.gradle.kts" module-root)))
                       (and (file-readable-p file) file))
                     (let ((file (expand-file-name
                                  "build.gradle" module-root)))
                       (and (file-readable-p file) file)))))
    (when build-file
      (java-kit--extract-java-major
       (or
        (java-kit--file-match
         build-file
         "sourceCompatibility[[:space:]]*=[[:space:]]*\\(?:JavaVersion\\.VERSION_\\)?[\"']?\\([^\"' )\n]+\\)")
        (java-kit--file-match
         build-file
         "JavaLanguageVersion\\.of([[:space:]]*\\([0-9]+\\)"))))))

(defun java-kit--tool-versions-java (file)
  "Return the Java entry from asdf/mise FILE."
  (java-kit--file-match
   file "^[[:space:]]*java[[:space:]]+\\([^[:space:]\n]+\\)"))

(defun java-kit--declared-java-version (context)
  "Return the Java major version declared by CONTEXT."
  (let* ((configured (java-kit--configured-value
                      java-kit-project-java-version context))
         (module-root (plist-get context :module-root))
         (root (plist-get context :root))
         (java-version-file (or
                             (let ((file (expand-file-name
                                          ".java-version" module-root)))
                               (and (file-readable-p file) file))
                             (let ((file (expand-file-name
                                          ".java-version" root)))
                               (and (file-readable-p file) file))))
         (tool-versions-file (or
                              (let ((file (expand-file-name
                                           ".tool-versions" module-root)))
                                (and (file-readable-p file) file))
                              (let ((file (expand-file-name
                                           ".tool-versions" root)))
                                (and (file-readable-p file) file))))
         (sdkman-file (or
                       (let ((file (expand-file-name ".sdkmanrc" module-root)))
                         (and (file-readable-p file) file))
                       (let ((file (expand-file-name ".sdkmanrc" root)))
                         (and (file-readable-p file) file))))
         (build-system (plist-get context :build-system)))
    (java-kit--extract-java-major
     (or configured
         (and java-version-file
              (java-kit--read-first-line java-version-file))
         (and tool-versions-file
              (java-kit--tool-versions-java tool-versions-file))
         (and sdkman-file
              (java-kit--file-match
               sdkman-file
               "^[[:space:]]*java=\\([^[:space:]\n]+\\)"))
         (pcase build-system
           ('maven (java-kit--maven-java-version
                    (plist-get context :build-file)))
           ('gradle (java-kit--gradle-java-version module-root)))))))

(defun java-kit--gradle-java-home (context)
  "Return `org.gradle.java.home' declared by CONTEXT."
  (let* ((module-root (plist-get context :module-root))
         (root (plist-get context :root))
         (properties-file (or
                           (let ((file (expand-file-name
                                        "gradle.properties" module-root)))
                             (and (file-readable-p file) file))
                           (let ((file (expand-file-name
                                        "gradle.properties" root)))
                             (and (file-readable-p file) file)))))
    (and properties-file
         (java-kit--file-match
          properties-file
          "^[[:space:]]*org\\.gradle\\.java\\.home[[:space:]]*=[[:space:]]*\\(.+\\)$"))))

(defun java-kit--valid-java-home-p (directory)
  "Return non-nil when DIRECTORY looks like a JDK home."
  (and (stringp directory)
       (file-directory-p directory)
       (file-executable-p (expand-file-name "bin/java" directory))
       (file-executable-p (expand-file-name "bin/javac" directory))))

(defun java-kit--java-home-major (directory)
  "Return the Java major version provided by DIRECTORY."
  (when (java-kit--valid-java-home-p directory)
    (let ((release-file (expand-file-name "release" directory)))
      (or (and (file-readable-p release-file)
               (java-kit--extract-java-major
                (java-kit--file-match
                 release-file "^JAVA_VERSION=\"\\([^\"]+\\)\"")))
          (java-kit--extract-java-major
           (file-name-nondirectory (directory-file-name directory)))))))

(defun java-kit--macos-java-home (version)
  "Return the macOS JDK home matching VERSION."
  (let ((java-home-program "/usr/libexec/java_home"))
    (when (file-executable-p java-home-program)
      (with-temp-buffer
        (when (zerop (call-process java-home-program nil t nil "-v" version))
          (let ((home (string-trim (buffer-string))))
            (and (java-kit--valid-java-home-p home) home)))))))

(defun java-kit--linux-java-homes ()
  "Return valid JDK homes found under `/usr/lib/jvm'."
  (let ((directory "/usr/lib/jvm"))
    (when (file-directory-p directory)
      (seq-filter
       #'java-kit--valid-java-home-p
       (directory-files directory t directory-files-no-dot-files-regexp)))))

(defun java-kit--macos-java-homes ()
  "Return valid JDK homes reported by macOS `java_home'."
  (let ((program "/usr/libexec/java_home")
        homes)
    (when (file-executable-p program)
      (with-temp-buffer
        (call-process program nil (list t t) nil "-V")
        (goto-char (point-min))
        (while (re-search-forward
                "\\(/[^\n]+/Contents/Home\\)[[:space:]]*$" nil t)
          (push (string-trim (match-string 1)) homes))))
    (seq-filter #'java-kit--valid-java-home-p (delete-dups homes))))

(defun java-kit--installed-java-homes ()
  "Return JDK homes available for interactive project selection."
  (let ((homes
         (append
          (pcase system-type
            ('darwin (java-kit--macos-java-homes))
            ('gnu/linux (java-kit--linux-java-homes)))
          (list (getenv "JAVA_HOME")
                (java-kit--java-home-from-path)))))
    (delete-dups (seq-filter #'java-kit--valid-java-home-p homes))))

(defun java-kit--project-jdk-key (context)
  "Return the project JDK selection key for CONTEXT."
  (file-name-as-directory
   (expand-file-name (plist-get context :module-root))))

(defun java-kit--selected-project-java-home (context)
  "Return the interactively selected JDK home for CONTEXT."
  (gethash (java-kit--project-jdk-key context)
           java-kit--project-java-home-selections))

(defun java-kit--java-home-from-path ()
  "Infer a JDK home from the `java' executable on PATH."
  (when-let* ((java (executable-find "java"))
              (real-java (file-truename java))
              (home (file-name-directory
                     (directory-file-name (file-name-directory real-java)))))
    (and (not (and (eq system-type 'darwin)
                   (equal real-java "/usr/bin/java")))
         (java-kit--valid-java-home-p home)
         home)))

(defun java-kit--find-java-home (version)
  "Find an installed JDK home matching VERSION."
  (or (and (eq system-type 'darwin)
           (java-kit--macos-java-home version))
      (and (eq system-type 'gnu/linux)
           (seq-find (lambda (home)
                       (equal version (java-kit--java-home-major home)))
                     (java-kit--linux-java-homes)))
      (let ((environment-home (getenv "JAVA_HOME")))
        (and (java-kit--valid-java-home-p environment-home)
             (equal version (java-kit--java-home-major environment-home))
             environment-home))
      (let ((path-home (java-kit--java-home-from-path)))
        (and path-home
             (equal version (java-kit--java-home-major path-home))
             path-home))))

(defun java-kit-resolve-project-java-home (&optional context)
  "Resolve the JDK home used for project processes in CONTEXT."
  (let* ((context (or context (java-kit-project-context)))
         (configured (java-kit--configured-value
                      java-kit-project-java-home context))
         (gradle-home (and (eq (plist-get context :build-system) 'gradle)
                           (java-kit--gradle-java-home context)))
         (declared-version (java-kit--declared-java-version context))
         (fallback-home (or (getenv "JAVA_HOME")
                            (java-kit--java-home-from-path)))
         (selected (java-kit--selected-project-java-home context))
         (home (or selected configured gradle-home
                   (and declared-version
                        (java-kit--find-java-home declared-version))
                   (and (not declared-version) fallback-home))))
    (when (and home (not (java-kit--valid-java-home-p home)))
      (user-error "Invalid project JDK home: %s" home))
    (when (and declared-version (not home))
      (user-error "Could not find an installed JDK %s for %s"
                  declared-version (plist-get context :name)))
    (and home (directory-file-name (expand-file-name home)))))

;;;###autoload
(defun java-kit-select-project-jdk (&optional clear)
  "Select a process-local JDK for the current build module.

With prefix argument CLEAR, forget the interactive selection and resume normal
project detection.  This command never changes global `JAVA_HOME' or `PATH'."
  (interactive "P")
  (let* ((context (java-kit-project-context))
         (key (java-kit--project-jdk-key context)))
    (if clear
        (progn
          (remhash key java-kit--project-java-home-selections)
          (message "Cleared project JDK selection for %s"
                   (plist-get context :name)))
      (let* ((homes (java-kit--installed-java-homes))
             (choices
              (mapcar
               (lambda (home)
                 (cons (format "Java %s — %s"
                               (or (java-kit--java-home-major home) "?")
                               home)
                       home))
               homes)))
        (unless choices
          (user-error "No installed JDK homes were found"))
        (let* ((label (completing-read "Project JDK: " choices nil t))
               (home (alist-get label choices nil nil #'string-equal)))
          (puthash key home java-kit--project-java-home-selections)
          (message "Project processes for %s will use %s"
                   (plist-get context :name) home)
          home)))))

(defun java-kit--environment-value (name environment)
  "Return NAME from an ENVIRONMENT list."
  (when-let* ((entry (seq-find
                      (lambda (item)
                        (string-prefix-p (concat name "=") item))
                      environment)))
    (substring entry (1+ (length name)))))

(defun java-kit--environment-with-java-home (java-home)
  "Return a process environment using JAVA-HOME."
  (let* ((old-java-home (getenv "JAVA_HOME"))
         (old-java-bin (and old-java-home
                            (directory-file-name
                             (expand-file-name "bin" old-java-home))))
         (java-bin (directory-file-name
                    (expand-file-name "bin" java-home)))
         (path-parts (split-string (or (getenv "PATH") "")
                                   path-separator t))
         (filtered-path
          (seq-remove
           (lambda (path)
             (let ((expanded (directory-file-name (expand-file-name path))))
               (or (equal expanded java-bin)
                   (and old-java-bin (equal expanded old-java-bin)))))
           path-parts))
         (environment
          (seq-remove
           (lambda (entry)
             (or (string-prefix-p "JAVA_HOME=" entry)
                 (string-prefix-p "PATH=" entry)))
           process-environment)))
    (cons (concat "JAVA_HOME=" java-home)
          (cons (concat "PATH="
                        (mapconcat #'identity
                                   (cons java-bin filtered-path)
                                   path-separator))
                environment))))

(defun java-kit-project-process-environment (&optional context)
  "Return a process environment suitable for CONTEXT."
  (if-let* ((java-home (java-kit-resolve-project-java-home context)))
      (java-kit--environment-with-java-home java-home)
    (copy-sequence process-environment)))

(defun java-kit--parse-environment-entry (entry)
  "Parse NAME=VALUE environment ENTRY and return a cons cell."
  (unless (and (stringp entry)
               (string-match
                "\\`\\([[:alpha:]_][[:alnum:]_]*\\)=\\(.*\\)\\'" entry))
    (user-error "Invalid process environment entry: %S" entry))
  (cons (match-string 1 entry) (match-string 2 entry)))

(defun java-kit--environment-merge (environment additions)
  "Return ENVIRONMENT with NAME=VALUE ADDITIONS applied."
  (let ((result (copy-sequence environment)))
    (dolist (entry additions)
      (let* ((parsed (java-kit--parse-environment-entry entry))
             (prefix (concat (car parsed) "=")))
        (setq result
              (cons entry
                    (seq-remove
                     (lambda (existing)
                       (string-prefix-p prefix existing))
                     result)))))
    result))

(defun java-kit--build-command (context)
  "Return a command list for CONTEXT's build tool."
  (let ((build-system (plist-get context :build-system))
        (wrapper (plist-get context :wrapper)))
    (unless build-system
      (user-error "No Maven or Gradle build found for %s"
                  (plist-get context :name)))
    (cond
     ((and wrapper (file-executable-p wrapper)) (list wrapper))
     (wrapper (list "sh" wrapper))
     ((eq build-system 'maven) '("mvn"))
     ((eq build-system 'gradle) '("gradle")))))

(defun java-kit--command-available-p (program)
  "Return non-nil when PROGRAM can be executed."
  (if (file-name-absolute-p program)
      (file-executable-p program)
    (executable-find program)))

(defun java-kit--shell-command (arguments)
  "Convert ARGUMENTS into a safely quoted shell command."
  (mapconcat #'shell-quote-argument arguments " "))

(defun java-kit--default-task (build-system)
  "Return the configured default task for BUILD-SYSTEM."
  (pcase build-system
    ('maven java-kit-maven-default-task)
    ('gradle java-kit-gradle-default-task)))

;;;###autoload
(defun java-kit-build (&optional task)
  "Build the current project using TASK.

Interactively, prompt for TASK using a build-system-specific default."
  (interactive)
  (let* ((context (java-kit-project-context))
         (build-system (plist-get context :build-system))
         (task (or task
                   (read-string "Task and arguments: "
                                (java-kit--default-task build-system))))
         (command-prefix (java-kit--build-command context))
         (arguments (append command-prefix (split-string-and-unquote task)))
         (program (car arguments))
         (default-directory (plist-get context :module-root))
         (process-environment
          (java-kit-project-process-environment context))
         (command (java-kit--shell-command arguments))
         (buffer-name (format "*java-kit build:%s*"
                              (plist-get context :name))))
    (unless (java-kit--command-available-p program)
      (user-error "Build program is not executable: %s" program))
    (compilation-start command 'compilation-mode
                       (lambda (_mode) buffer-name))))

;;;###autoload
(defun java-kit-test ()
  "Run the current project's standard test task."
  (interactive)
  (java-kit-build "test"))

(defun java-kit--eglot-server ()
  "Return the Eglot server managing the current buffer."
  (or (eglot-current-server)
      (user-error "No Eglot server manages the current buffer")))

(defun java-kit--current-java-file ()
  "Return the current buffer's saved file name."
  (unless buffer-file-name
    (user-error "The current buffer is not visiting a Java file"))
  (when (buffer-modified-p)
    (save-buffer))
  (unless (file-readable-p buffer-file-name)
    (user-error "Save the current Java file before running it"))
  (expand-file-name buffer-file-name))

(defun java-kit--symbol-range-contains-line-p (symbol line)
  "Return non-nil when SYMBOL's range contains zero-based LINE."
  (when-let* ((range (plist-get symbol :range))
              (start (plist-get range :start))
              (end (plist-get range :end))
              (start-line (plist-get start :line))
              (end-line (plist-get end :line)))
    (and (<= start-line line) (<= line end-line))))

(defun java-kit--symbol-children (symbol)
  "Return SYMBOL's children as a sequence."
  (or (plist-get symbol :children) []))

(defun java-kit--symbol-name-for-kind (symbols kind)
  "Return the first name in SYMBOLS with LSP symbol KIND."
  (seq-some
   (lambda (symbol)
     (or (and (equal kind (plist-get symbol :kind))
              (plist-get symbol :name))
         (java-kit--symbol-name-for-kind
          (java-kit--symbol-children symbol) kind)))
   symbols))

(defun java-kit--type-path-at-line (symbols line)
  "Return the nested Java type path in SYMBOLS containing LINE."
  (seq-some
   (lambda (symbol)
     (let* ((children (java-kit--symbol-children symbol))
            (nested (java-kit--type-path-at-line children line)))
       (cond
        ((and (memq (plist-get symbol :kind) java-kit--lsp-type-kinds)
              (java-kit--symbol-range-contains-line-p symbol line))
         (cons (plist-get symbol :name) nested))
        (nested nested))))
   symbols))

(defun java-kit--first-type-path (symbols)
  "Return the first nested Java type path found in SYMBOLS."
  (seq-some
   (lambda (symbol)
     (if (memq (plist-get symbol :kind) java-kit--lsp-type-kinds)
         (list (plist-get symbol :name))
       (java-kit--first-type-path (java-kit--symbol-children symbol))))
   symbols))

(defun java-kit--method-at-line (symbols line)
  "Return the Java method in SYMBOLS containing LINE."
  (seq-some
   (lambda (symbol)
     (or (and (equal java-kit--lsp-method-kind
                     (plist-get symbol :kind))
              (java-kit--symbol-range-contains-line-p symbol line)
              (car (split-string (plist-get symbol :name) "(" t)))
         (java-kit--method-at-line
          (java-kit--symbol-children symbol) line)))
   symbols))

(defun java-kit--target-from-symbols (symbols line)
  "Return a class and optional method target from SYMBOLS at LINE."
  (when-let* ((type-path (or (java-kit--type-path-at-line symbols line)
                             (java-kit--first-type-path symbols))))
    (let* ((package (or (java-kit--symbol-name-for-kind
                         symbols java-kit--lsp-package-kind)
                        ""))
           (type-name (mapconcat #'identity type-path "$"))
           (class-name (if (string-empty-p package)
                           type-name
                         (concat package "." type-name))))
      (list :class class-name
            :method (java-kit--method-at-line symbols line)))))

(defun java-kit--document-symbols (server file)
  "Request document symbols for FILE from SERVER."
  (jsonrpc-request
   server :textDocument/documentSymbol
   (list :textDocument (list :uri (eglot-path-to-uri file)))))

(defun java-kit--current-target (server file)
  "Return the Java target at point using SERVER and FILE."
  (or (java-kit--target-from-symbols
       (java-kit--document-symbols server file)
       (1- (line-number-at-pos)))
      (user-error "No Java type found in the current file")))

(defun java-kit--jdtls-execute (server command arguments)
  "Ask SERVER to execute JDTLS COMMAND with ARGUMENTS."
  (eglot-execute
   server
   (list :command command :arguments (vconcat arguments))))

(defun java-kit--jdtls-classpaths (server file scope context)
  "Return FILE classpaths for SCOPE from SERVER in CONTEXT."
  (let* ((scope-json (json-serialize (list :scope scope)))
         (response
          (java-kit--jdtls-execute
           server "java.project.getClasspaths"
           (list (eglot-path-to-uri file) scope-json)))
         (classpaths (plist-get response :classpaths))
         (root (plist-get context :module-root))
         (paths
          (mapcar (lambda (path)
                    (if (file-name-absolute-p path)
                        path
                      (expand-file-name path root)))
                  (seq-filter #'stringp (append classpaths nil)))))
    (unless paths
      (user-error "JDTLS returned no %s classpath for %s"
                  scope (file-name-nondirectory file)))
    paths))

(defun java-kit--jdtls-test-file-p (server file)
  "Return non-nil when SERVER identifies FILE as a test."
  (let ((answer
         (java-kit--jdtls-execute
          server "java.project.isTestFile"
          (list (eglot-path-to-uri file)))))
    (not (memq answer '(nil :json-false json-false)))))

(defun java-kit--project-java-program (context)
  "Return the Java executable to use for CONTEXT."
  (if-let* ((home (java-kit-resolve-project-java-home context)))
      (expand-file-name "bin/java" home)
    (or (executable-find "java")
        (user-error "Could not find a Java executable for %s"
                    (plist-get context :name)))))

(defun java-kit--start-java-compilation
    (arguments context operation &optional environment-additions)
  "Run Java ARGUMENTS for CONTEXT and label its buffer with OPERATION.

Apply ENVIRONMENT-ADDITIONS only to the new process."
  (let* ((program (car arguments))
         (default-directory (plist-get context :module-root))
         (process-environment
          (java-kit--environment-merge
           (java-kit-project-process-environment context)
           environment-additions))
         (command (java-kit--shell-command arguments))
         (buffer-name (format "*java-kit %s:%s*"
                              operation (plist-get context :name))))
    (unless (java-kit--command-available-p program)
      (user-error "Java program is not executable: %s" program))
    (compilation-start command 'compilation-mode
                       (lambda (_mode) buffer-name))))

(defun java-kit--main-command (context classpaths class arguments)
  "Return the Java main command for CONTEXT, CLASSPATHS, CLASS, and ARGUMENTS."
  (append (list (java-kit--project-java-program context))
          java-kit-main-jvm-arguments
          (list "-cp" (mapconcat #'identity classpaths path-separator)
                class)
          arguments))

(defun java-kit--junit-command (context classpaths class method)
  "Return the JUnit command for CONTEXT, CLASSPATHS, CLASS, and METHOD."
  (let ((jar (expand-file-name java-kit-junit-console-jar)))
    (unless (file-regular-p jar)
      (user-error
       "JUnit Console JAR is missing: %s; install or configure it first" jar))
    (append
     (list (java-kit--project-java-program context))
     java-kit-test-jvm-arguments
     (list "-jar" jar "execute"
           "--class-path" (mapconcat #'identity classpaths path-separator)
           (if method "--select-method" "--select-class")
           (if method (concat class "#" method) class)))))

;;;###autoload
(defun java-kit-run-main (&optional debug)
  "Run the current Java class.

With prefix argument DEBUG, launch it through JDTLS and Dape."
  (interactive "P")
  (if debug
      (java-kit-debug-main)
    (let* ((file (java-kit--current-java-file))
           (server (java-kit--eglot-server))
           (context (java-kit-project-context file))
           (target (java-kit--current-target server file))
           (class (plist-get target :class))
           (classpaths
            (java-kit--jdtls-classpaths server file "runtime" context))
           (command (java-kit--main-command
                     context classpaths class java-kit-main-arguments)))
      (java-kit--start-java-compilation
       command context "main" java-kit-main-environment))))

;;;###autoload
(defun java-kit-run-test (&optional debug)
  "Run the JUnit class or method at point.

With prefix argument DEBUG, launch it through JDTLS and Dape."
  (interactive "P")
  (if debug
      (java-kit-debug-test)
    (let* ((file (java-kit--current-java-file))
           (server (java-kit--eglot-server)))
      (unless (java-kit--jdtls-test-file-p server file)
        (user-error "JDTLS does not identify the current file as a test"))
      (let* ((context (java-kit-project-context file))
             (target (java-kit--current-target server file))
             (classpaths
              (java-kit--jdtls-classpaths server file "test" context))
             (command
              (java-kit--junit-command
               context classpaths
               (plist-get target :class)
               (plist-get target :method))))
        (java-kit--start-java-compilation
         command context "test" java-kit-test-environment)))))

;;;###autoload
(defun java-kit-project-refresh ()
  "Ask JDTLS to refresh configuration and rebuild the current project."
  (interactive)
  (let* ((server (java-kit--eglot-server))
         (context (java-kit-project-context))
         (build-file (plist-get context :build-file)))
    (when (and build-file (file-readable-p build-file))
      (jsonrpc-notify
       server :java/projectConfigurationUpdate
       (list :uri (eglot-path-to-uri build-file))))
    (jsonrpc-notify server :java/buildWorkspace (vector :json-false))
    (message "Requested JDTLS project refresh for %s"
             (plist-get context :name))))

(defun java-kit--jdt-uri-cache-file (uri)
  "Return the deterministic read-only cache file for JDTLS URI."
  (let* ((url (url-generic-parse-url uri))
         (path (or (url-filename url) "Class.class"))
         (base (file-name-base
                (car (split-string (file-name-nondirectory path) "?"))))
         (safe-base
          (replace-regexp-in-string "[^[:alnum:]_$-]" "_" base))
         (digest (substring (secure-hash 'sha256 uri) 0 16)))
    (expand-file-name (format "%s-%s.java" safe-base digest)
                      java-kit-jdt-class-cache-directory)))

(defun java-kit--jdt-uri-local-file (uri)
  "Materialize JDTLS URI as a read-only local Java file."
  (let ((cache-file (java-kit--jdt-uri-cache-file uri)))
    (unless (file-readable-p cache-file)
      (let* ((server (java-kit--eglot-server))
             (content
              (jsonrpc-request
               server :java/classFileContents (list :uri uri))))
        (unless (stringp content)
          (error "JDTLS returned no class contents for %s" uri))
        (make-directory (file-name-directory cache-file) t)
        (with-temp-file cache-file
          (insert content))
        (set-file-modes cache-file #o444)))
    cache-file))

(defun java-kit--jdt-uri-handler (operation &rest arguments)
  "Handle file OPERATION with ARGUMENTS for JDTLS `jdt://' URIs."
  (when (memq operation java-kit--jdt-uri-write-operations)
    (signal 'file-error
            (list "JDTLS class contents are read-only" (car arguments))))
  (let ((local-arguments
         (mapcar
          (lambda (argument)
            (if (and (stringp argument)
                     (string-prefix-p "jdt://" argument))
                (java-kit--jdt-uri-local-file argument)
              argument))
          arguments))
        (inhibit-file-name-handlers
         (cons #'java-kit--jdt-uri-handler
               (and (eq inhibit-file-name-operation operation)
                    inhibit-file-name-handlers)))
        (inhibit-file-name-operation operation))
    (apply operation local-arguments)))

;;;###autoload
(defun java-kit-jdt-uri-register ()
  "Register java-kit's read-only handler for JDTLS `jdt://' URIs."
  (interactive)
  (add-to-list 'file-name-handler-alist
               '("\\`jdt://" . java-kit--jdt-uri-handler)))

;;;###autoload
(defun java-kit-jdt-uri-unregister ()
  "Unregister java-kit's handler for JDTLS `jdt://' URIs."
  (interactive)
  (setq file-name-handler-alist
        (delete '("\\`jdt://" . java-kit--jdt-uri-handler)
                file-name-handler-alist)))

;;;###autoload
(defun java-kit-clear-class-cache ()
  "Delete java-kit's cached read-only JDTLS class contents."
  (interactive)
  (when (and (file-directory-p java-kit-jdt-class-cache-directory)
             (yes-or-no-p
              (format "Delete cached JDTLS class contents under %s? "
                      java-kit-jdt-class-cache-directory)))
    (delete-directory java-kit-jdt-class-cache-directory t)
    (message "Cleared java-kit JDTLS class cache")))

(defun java-kit--plist-merge (base extra)
  "Return a shallow merge of plist EXTRA over BASE."
  (let ((result (copy-sequence base)))
    (while extra
      (setq result (plist-put result (pop extra) (pop extra))))
    result))

(defun java-kit--expanded-bundles ()
  "Return validated absolute paths from `java-kit-jdtls-bundles'."
  (mapcar
   (lambda (bundle)
     (let ((path (expand-file-name bundle)))
       (unless (file-regular-p path)
         (user-error "JDTLS bundle does not exist: %s" path))
       (file-truename path)))
   java-kit-jdtls-bundles))

(defun java-kit-jdtls-initialization-options (&optional context)
  "Return JDTLS initialization options for CONTEXT."
  (let* ((context (or context (java-kit-project-context)))
         (project-java-home
          (java-kit-resolve-project-java-home context))
         (bundles (java-kit--expanded-bundles))
         (options (list :extendedClientCapabilities
                        (list :classFileContentsSupport t))))
    (when project-java-home
      (setq options
            (plist-put options :settings
                       `(:java (:home ,project-java-home)))))
    (when bundles
      (setq options (plist-put options :bundles (vconcat bundles))))
    (java-kit--plist-merge
     options java-kit-jdtls-extra-initialization-options)))

(defun java-kit--jdtls-workspace (project-root)
  "Return the JDTLS workspace directory for PROJECT-ROOT."
  (expand-file-name
   (secure-hash 'sha1 (file-truename project-root))
   java-kit-jdtls-workspace-directory))

(defun java-kit--jdtls-java-home (context)
  "Resolve the JDTLS-only JDK home for CONTEXT."
  (when-let* ((home (java-kit--configured-value
                     java-kit-jdtls-java-home context)))
    (unless (java-kit--valid-java-home-p home)
      (user-error "Invalid JDTLS JDK home: %s" home))
    (directory-file-name (expand-file-name home))))

(defun java-kit--effective-jdtls-command ()
  "Return the configured, installed, or PATH-based JDTLS command."
  (or java-kit-jdtls-command
      (let ((installed
             (expand-file-name "bin/jdtls"
                               java-kit-jdtls-install-directory)))
        (and (file-executable-p installed) (list installed)))
      '("jdtls")))

(defun java-kit--jdtls-contact (&optional _interactive)
  "Return the Eglot contact used to launch JDTLS."
  (let* ((context (java-kit-project-context))
         (project-root (plist-get context :root))
         (jdtls-home (java-kit--jdtls-java-home context))
         (jdtls-command (copy-sequence
                         (java-kit--effective-jdtls-command)))
         (launcher (car jdtls-command))
         (workspace (java-kit--jdtls-workspace project-root))
         (jvm-arguments
          (mapcar (lambda (argument)
                    (concat "--jvm-arg=" argument))
                  java-kit-jdtls-jvm-arguments))
         (options (java-kit-jdtls-initialization-options context))
         (environment-prefix
          (when jdtls-home
            (let* ((environment
                    (java-kit--environment-with-java-home jdtls-home))
                   (path (java-kit--environment-value "PATH" environment)))
              (list "env" (concat "JAVA_HOME=" jdtls-home)
                    (concat "PATH=" path))))))
    (unless launcher
      (user-error "`java-kit-jdtls-command' is empty"))
    (unless (java-kit--command-available-p launcher)
      (user-error "JDTLS launcher is not executable: %s" launcher))
    (make-directory workspace t)
    (append environment-prefix
            jdtls-command
            jvm-arguments
            (list "-data" workspace
                  :initializationOptions options))))

;;;###autoload
(defun java-kit-eglot-register ()
  "Register java-kit's JDTLS contact in `eglot-server-programs'."
  (interactive)
  (java-kit-jdt-uri-register)
  (setq eglot-server-programs
        (cons (cons java-kit--eglot-modes #'java-kit--jdtls-contact)
              (cl-remove-if
               (lambda (entry)
                 (equal (car entry) java-kit--eglot-modes))
               eglot-server-programs))))

;;;###autoload
(define-minor-mode java-kit-mode
  "Use java-kit's project tools in the current Java buffer."
  :lighter " JKit"
  :keymap java-kit-mode-map
  (when java-kit-mode
    (java-kit-eglot-register)
    (when java-kit-auto-start-eglot
      (eglot-ensure))))

(provide 'java-kit)
;;; java-kit.el ends here
