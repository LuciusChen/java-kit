;;; java-kit-new.el --- Java file and project scaffolding  -*- lexical-binding: t; -*-

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

;; This module creates Java types in JDTLS-reported source roots and creates
;; projects through local Maven/Gradle commands or official starter services.
;; Remote archives are inspected for unsafe paths before extraction.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url-handlers)
(require 'url-util)
(require 'java-kit)

(defcustom java-kit-new-projects-directory
  (expand-file-name "~/repos")
  "Default parent directory offered by `java-kit-new-project'."
  :type 'directory
  :group 'java-kit)

(defcustom java-kit-new-default-group "com.example"
  "Default group identifier offered when creating a project."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-new-default-java-version "21"
  "Default Java version offered to remote project starters."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-new-spring-url "https://start.spring.io"
  "Root URL of the Spring Initializr service."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-new-micronaut-url "https://launch.micronaut.io"
  "Root URL of the Micronaut Launch service."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-new-quarkus-url "https://code.quarkus.io"
  "Root URL of the Quarkus project generator."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-new-vertx-url "https://start.vertx.io"
  "Root URL of the Eclipse Vert.x Starter service."
  :type 'string
  :group 'java-kit)

(defconst java-kit-new--java-templates
  '((class . "public class %s {\n\n}\n")
    (record . "public record %s() {\n}\n")
    (enum . "public enum %s {\n\n}\n")
    (interface . "public interface %s {\n\n}\n")
    (annotation . "public @interface %s {\n\n}\n")
    (test . "import org.junit.jupiter.api.Test;\n\npublic class %s {\n\n    @Test\n    void example() {\n    }\n}\n"))
  "Initial contents for Java types created by java-kit.")

(defconst java-kit-new--providers
  '(maven gradle spring micronaut quarkus vertx)
  "Project providers supported by `java-kit-new-project'.")

(defun java-kit-new--source-paths (response)
  "Return source-path plists nested anywhere in JDTLS RESPONSE."
  (cond
   ((and (listp response) (plist-member response :path))
    (list response))
   ((vectorp response)
    (apply #'append (mapcar #'java-kit-new--source-paths response)))
   ((listp response)
    (apply #'append (mapcar #'java-kit-new--source-paths response)))
   (t nil)))

(defun java-kit-new--java-name-p (name)
  "Return non-nil when NAME is a conservative Java identifier."
  (and (stringp name)
       (string-match-p "\\`[[:alpha:]_$][[:alnum:]_$]*\\'" name)))

(defun java-kit-new--qualified-java-name-p (name)
  "Return non-nil when NAME is a qualified Java identifier."
  (when (stringp name)
    (let ((parts (split-string name "\\." t)))
      (and parts
           (seq-every-p #'java-kit-new--java-name-p parts)))))

(defun java-kit-new--package-at-point (server file)
  "Return the package declared in FILE according to SERVER."
  (or (java-kit--symbol-name-for-kind
       (java-kit--document-symbols server file)
       java-kit--lsp-package-kind)
      ""))

(defun java-kit-new--select-source-root (source-paths)
  "Prompt for one entry from SOURCE-PATHS and return its path."
  (unless source-paths
    (user-error "JDTLS returned no Java source roots"))
  (let* ((choices
          (mapcar
           (lambda (entry)
             (cons (or (plist-get entry :displayPath)
                       (plist-get entry :path))
                   (plist-get entry :path)))
           source-paths))
         (selected
          (completing-read "Source root: " choices nil t)))
    (or (alist-get selected choices nil nil #'string-equal)
        (user-error "JDTLS source root has no path: %s" selected))))

(defun java-kit-new--java-content (package simple-name type)
  "Return source text for PACKAGE, SIMPLE-NAME, and Java TYPE."
  (let ((template (alist-get type java-kit-new--java-templates)))
    (unless template
      (user-error "Unsupported Java type: %s" type))
    (concat (unless (string-empty-p package)
              (format "package %s;\n\n" package))
            (format template simple-name))))

;;;###autoload
(defun java-kit-new-java-type (&optional qualified-name type source-root)
  "Create QUALIFIED-NAME of TYPE below a JDTLS SOURCE-ROOT.

Interactively, obtain source roots from JDTLS and prompt for all values."
  (interactive)
  (let* ((server (java-kit--eglot-server))
         (file (java-kit--current-java-file))
         (source-paths
          (java-kit-new--source-paths
           (java-kit--jdtls-execute
            server "java.project.listSourcePaths" nil)))
         (source-root (or source-root
                          (java-kit-new--select-source-root source-paths)))
         (package-default (java-kit-new--package-at-point server file))
         (qualified-name
          (or qualified-name
              (read-string
               "Qualified type name: "
               (unless (string-empty-p package-default)
                 (concat package-default ".")))))
         (type
          (let ((value
                 (or type
                     (completing-read
                      "Type: "
                      (mapcar (lambda (entry) (symbol-name (car entry)))
                              java-kit-new--java-templates)
                      nil t nil nil "class"))))
            (if (symbolp value) value (intern value))))
         (parts (split-string qualified-name "\\." t))
         (simple-name (car (last parts)))
         (package-parts (butlast parts))
         (package (mapconcat #'identity package-parts "."))
         (directory
          (expand-file-name (mapconcat #'identity package-parts "/")
                            source-root))
         (destination (expand-file-name (concat simple-name ".java")
                                        directory)))
    (unless (java-kit-new--qualified-java-name-p qualified-name)
      (user-error "Invalid qualified Java name: %s" qualified-name))
    (when (file-exists-p destination)
      (user-error "Java file already exists: %s" destination))
    (make-directory directory t)
    (with-temp-file destination
      (insert (java-kit-new--java-content package simple-name type)))
    (find-file destination)
    destination))

(defun java-kit-new--json (url &optional accept)
  "Retrieve URL and parse its JSON response, optionally using ACCEPT."
  (let ((url-request-extra-headers
         (and accept (list (cons "Accept" accept)))))
    (with-temp-buffer
      (url-insert-file-contents url)
      (goto-char (point-min))
      (json-parse-buffer :object-type 'plist :array-type 'list
                         :null-object nil :false-object nil))))

(defun java-kit-new--dependency-entry (id name)
  "Return a completion entry for dependency ID and NAME."
  (cons (if (and name (not (string-empty-p name)))
            (format "%s — %s" id name)
          id)
        id))

(defun java-kit-new--spring-dependencies ()
  "Return dependency completion entries from Spring Initializr."
  (let* ((metadata
          (java-kit-new--json
           java-kit-new-spring-url
           "application/vnd.initializr.v2.2+json"))
         (groups (plist-get (plist-get metadata :dependencies) :values)))
    (cl-loop for group in groups
             append
             (cl-loop for item in (plist-get group :values)
                      collect
                      (java-kit-new--dependency-entry
                       (plist-get item :id) (plist-get item :name))))))

(defun java-kit-new--micronaut-dependencies ()
  "Return dependency completion entries from Micronaut Launch."
  (let* ((metadata
          (java-kit-new--json
           (concat (string-remove-suffix "/" java-kit-new-micronaut-url)
                   "/application-types/default/features")))
         (features (plist-get metadata :features)))
    (mapcar
     (lambda (item)
       (java-kit-new--dependency-entry
        (plist-get item :name) (plist-get item :title)))
     features)))

(defun java-kit-new--quarkus-dependencies ()
  "Return dependency completion entries from the Quarkus generator."
  (mapcar
   (lambda (item)
     (java-kit-new--dependency-entry
      (plist-get item :id) (plist-get item :name)))
   (java-kit-new--json
    (concat (string-remove-suffix "/" java-kit-new-quarkus-url)
            "/api/extensions?platformOnly=true"))))

(defun java-kit-new--vertx-dependencies ()
  "Return dependency completion entries from the Vert.x Starter."
  (let* ((metadata
          (java-kit-new--json
           (concat (string-remove-suffix "/" java-kit-new-vertx-url)
                   "/metadata")))
         (groups (plist-get metadata :stack)))
    (cl-loop for group in groups
             append
             (cl-loop for item in (plist-get group :items)
                      collect
                      (java-kit-new--dependency-entry
                       (plist-get item :artifactId)
                       (plist-get item :name))))))

(defun java-kit-new--provider-dependencies (provider)
  "Return dependency completion entries for PROVIDER."
  (condition-case error-data
      (pcase provider
        ('spring (java-kit-new--spring-dependencies))
        ('micronaut (java-kit-new--micronaut-dependencies))
        ('quarkus (java-kit-new--quarkus-dependencies))
        ('vertx (java-kit-new--vertx-dependencies)))
    (error
     (message "Could not load %s dependency metadata: %s"
              provider (error-message-string error-data))
     nil)))

(defun java-kit-new--read-dependencies (provider)
  "Prompt for dependency identifiers supported by PROVIDER."
  (let ((choices (java-kit-new--provider-dependencies provider)))
    (if choices
        (mapcar
         (lambda (choice)
           (alist-get choice choices nil nil #'string-equal))
         (completing-read-multiple
          "Dependencies (comma separated): " choices nil t))
      (split-string
       (read-string "Dependency identifiers (comma separated): ")
       "[[:space:]]*,[[:space:]]*" t))))

(defun java-kit-new--project-name-p (name)
  "Return non-nil when NAME is safe as a project directory name."
  (and (stringp name)
       (string-match-p "\\`[[:alnum:]][[:alnum:]_.-]*\\'" name)
       (not (member name '("." "..")))))

(defun java-kit-new--build-value (provider build)
  "Return PROVIDER's API value for BUILD."
  (pcase provider
    ('spring
     (pcase build
       ('maven "maven-project")
       ('gradle "gradle-project")
       ('gradle-kotlin "gradle-project-kotlin")))
    ('micronaut
     (pcase build
       ('maven "MAVEN")
       ('gradle "GRADLE")
       ('gradle-kotlin "GRADLE_KOTLIN")))
    ('quarkus
     (pcase build
       ('maven "MAVEN")
       ('gradle "GRADLE")
       ('gradle-kotlin "GRADLE_KOTLIN_DSL")))
    ('vertx
     (if (eq build 'maven) "maven" "gradle"))))

(defun java-kit-new--query-url (root path parameters)
  "Return ROOT and PATH with non-nil query PARAMETERS."
  (let ((parameters
         (seq-filter
          (lambda (entry)
            (let ((value (cadr entry)))
              (and value
                   (not (and (stringp value)
                             (string-empty-p value))))))
          parameters)))
    (concat (string-remove-suffix "/" root) path
            (when parameters
              (concat "?" (url-build-query-string parameters))))))

(defun java-kit-new--spring-url (spec)
  "Return a Spring Initializr URL for project SPEC."
  (java-kit-new--query-url
   java-kit-new-spring-url "/starter.zip"
   `(("type" ,(java-kit-new--build-value 'spring
                                          (plist-get spec :build)))
     ("language" "java")
     ("groupId" ,(plist-get spec :group))
     ("artifactId" ,(plist-get spec :artifact))
     ("name" ,(plist-get spec :artifact))
     ("packageName" ,(plist-get spec :package))
     ("javaVersion" ,(plist-get spec :java))
     ("dependencies" ,(mapconcat #'identity
                                  (plist-get spec :dependencies) ",")))))

(defun java-kit-new--micronaut-url (spec)
  "Return a Micronaut Launch URL for project SPEC."
  (let ((name (plist-get spec :package)))
    (java-kit-new--query-url
     java-kit-new-micronaut-url
     (concat "/create/default/" (url-hexify-string name))
     `(("build" ,(java-kit-new--build-value 'micronaut
                                             (plist-get spec :build)))
       ("lang" "JAVA")
       ("test" "JUNIT")
       ("jdkVersion" ,(and (plist-get spec :java)
                            (concat "JDK_" (plist-get spec :java))))
       ("features" ,(mapconcat #'identity
                                (plist-get spec :dependencies) ","))))))

(defun java-kit-new--quarkus-url (spec)
  "Return a Quarkus generator URL for project SPEC."
  (java-kit-new--query-url
   java-kit-new-quarkus-url "/api/download"
   (append
    (mapcar (lambda (dependency) (list "e" dependency))
            (plist-get spec :dependencies))
    `(("S" ,(plist-get spec :platform))
      ("a" ,(plist-get spec :artifact))
      ("g" ,(plist-get spec :group))
      ("j" ,(plist-get spec :java))
      ("b" ,(java-kit-new--build-value 'quarkus
                                        (plist-get spec :build)))
      ("V" "1.0.0-SNAPSHOT")))))

(defun java-kit-new--vertx-url (spec)
  "Return a Vert.x Starter URL for project SPEC."
  (java-kit-new--query-url
   java-kit-new-vertx-url "/starter.zip"
   `(("groupId" ,(plist-get spec :group))
     ("artifactId" ,(plist-get spec :artifact))
     ("packageName" ,(plist-get spec :package))
     ("jdkVersion" ,(plist-get spec :java))
     ("buildTool" ,(java-kit-new--build-value 'vertx
                                               (plist-get spec :build)))
     ("vertxDependencies" ,(mapconcat #'identity
                                      (plist-get spec :dependencies) ",")))))

(defun java-kit-new--starter-url (spec)
  "Return the remote starter URL described by SPEC."
  (pcase (plist-get spec :provider)
    ('spring (java-kit-new--spring-url spec))
    ('micronaut (java-kit-new--micronaut-url spec))
    ('quarkus (java-kit-new--quarkus-url spec))
    ('vertx (java-kit-new--vertx-url spec))
    (provider (user-error "No remote starter for %s" provider))))

(defun java-kit-new--zip-entries (archive)
  "Return member names in ZIP ARCHIVE."
  (unless (executable-find "unzip")
    (user-error "The `unzip' program is required for starter projects"))
  (with-temp-buffer
    (unless (zerop (call-process "unzip" nil t nil "-Z1" archive))
      (error "Could not inspect downloaded starter archive"))
    (split-string (buffer-string) "\n" t)))

(defun java-kit-new--extract-zip (archive destination)
  "Safely extract ZIP ARCHIVE into DESTINATION."
  (let ((entries (java-kit-new--zip-entries archive)))
    (unless entries
      (error "Downloaded starter archive is empty"))
    (dolist (entry entries)
      (unless (java-kit--safe-archive-entry-p entry destination)
        (error "Unsafe path in starter archive: %s" entry)))
    (make-directory destination t)
    (with-temp-buffer
      (unless (zerop
               (call-process "unzip" nil t nil "-q" archive
                             "-d" destination))
        (error "Could not extract downloaded starter archive")))))

(defun java-kit-new--payload-root (payload)
  "Return the actual project root under extracted PAYLOAD."
  (let ((children
         (directory-files payload t directory-files-no-dot-files-regexp)))
    (if (and (= (length children) 1)
             (file-directory-p (car children)))
        (car children)
      payload)))

(defun java-kit-new--download-project (url destination)
  "Download starter URL into a new project at DESTINATION."
  (when (file-exists-p destination)
    (user-error "Project destination already exists: %s" destination))
  (let ((parent (file-name-directory
                 (directory-file-name (expand-file-name destination)))))
    (make-directory parent t)
    (let* ((temporary
            (make-temp-file (expand-file-name ".java-kit-new-" parent) t))
           (archive (expand-file-name "project.zip" temporary))
           (payload (expand-file-name "payload" temporary)))
      (unwind-protect
          (progn
            (message "Downloading starter project...")
            (url-copy-file url archive t)
            (java-kit-new--extract-zip archive payload)
            (rename-file (java-kit-new--payload-root payload) destination)
            (dired destination)
            destination)
        (when (file-exists-p temporary)
          (delete-directory temporary t))))))

(defun java-kit-new--local-command-finished (destination buffer status)
  "Open DESTINATION when compilation BUFFER finishes with STATUS."
  (when (string-prefix-p "finished" status)
    (message "Created Java project at %s" destination)
    (dired destination))
  (unless (string-prefix-p "finished" status)
    (message "Project creation failed; see %s" (buffer-name buffer))))

(defun java-kit-new--start-local-command (command directory destination)
  "Start project creation COMMAND in DIRECTORY for DESTINATION."
  (unless (java-kit--command-available-p (car command))
    (user-error "Project generator is not executable: %s" (car command)))
  (let* ((default-directory (file-name-as-directory directory))
         (command-string (java-kit--shell-command command))
         (buffer
          (compilation-start command-string 'compilation-mode
                             (lambda (_mode) "*java-kit new-project*"))))
    (with-current-buffer buffer
      (add-hook
       'compilation-finish-functions
       (lambda (finished-buffer status)
         (java-kit-new--local-command-finished
          destination finished-buffer status))
       nil t))
    buffer))

(defun java-kit-new--create-maven (spec destination)
  "Create Maven project SPEC at DESTINATION."
  (make-directory (file-name-directory
                   (directory-file-name destination)) t)
  (java-kit-new--start-local-command
   (list "mvn" "archetype:generate"
         (concat "-DgroupId=" (plist-get spec :group))
         (concat "-DartifactId=" (plist-get spec :artifact))
         "-DarchetypeArtifactId=maven-archetype-quickstart"
         "-DinteractiveMode=false")
   (file-name-directory (directory-file-name destination))
   destination))

(defun java-kit-new--create-gradle (spec destination)
  "Create Gradle project SPEC at DESTINATION."
  (unless (java-kit--command-available-p "gradle")
    (user-error "Project generator is not executable: gradle"))
  (make-directory destination t)
  (java-kit-new--start-local-command
   (list "gradle" "init" "--type" "java-application"
         "--test-framework" "junit-jupiter"
         "--dsl" "kotlin"
         "--project-name" (plist-get spec :artifact)
         "--package" (plist-get spec :package))
   destination destination))

(defun java-kit-new-project-from-spec (spec)
  "Create a Java project described by SPEC.

SPEC is a plist containing `:provider', `:parent', `:group', `:artifact',
`:package', `:build', `:java', `:dependencies', and optional `:platform'."
  (let* ((provider (plist-get spec :provider))
         (artifact (plist-get spec :artifact))
         (parent (file-name-as-directory
                  (expand-file-name (plist-get spec :parent))))
         (destination (expand-file-name artifact parent)))
    (unless (memq provider java-kit-new--providers)
      (user-error "Unsupported project provider: %s" provider))
    (unless (java-kit-new--project-name-p artifact)
      (user-error "Invalid project name: %s" artifact))
    (unless (java-kit-new--qualified-java-name-p (plist-get spec :package))
      (user-error "Invalid Java package: %s" (plist-get spec :package)))
    (when (file-exists-p destination)
      (user-error "Project destination already exists: %s" destination))
    (pcase provider
      ('maven (java-kit-new--create-maven spec destination))
      ('gradle (java-kit-new--create-gradle spec destination))
      (_ (java-kit-new--download-project
          (java-kit-new--starter-url spec) destination)))))

(defun java-kit-new--read-build (provider)
  "Prompt for a build system supported by PROVIDER."
  (if (eq provider 'vertx)
      (intern (completing-read "Build: " '("maven" "gradle")
                               nil t nil nil "maven"))
    (intern
     (completing-read "Build: " '("maven" "gradle" "gradle-kotlin")
                      nil t nil nil "maven"))))

;;;###autoload
(defun java-kit-new-project ()
  "Interactively create a Java project from a local or remote provider."
  (interactive)
  (let* ((provider
          (intern
           (completing-read
            "Provider: "
            (mapcar #'symbol-name java-kit-new--providers) nil t)))
         (parent
          (read-directory-name "Parent directory: "
                               java-kit-new-projects-directory))
         (group (read-string "Group ID: " java-kit-new-default-group))
         (artifact (read-string "Artifact ID: " "demo"))
         (package-default
          (concat group "."
                  (replace-regexp-in-string
                   "[^[:alnum:]_$]" "" artifact)))
         (package (read-string "Package: " package-default))
         (remote (memq provider '(spring micronaut quarkus vertx)))
         (build (pcase provider
                  ('maven 'maven)
                  ('gradle 'gradle-kotlin)
                  (_ (java-kit-new--read-build provider))))
         (java
          (and remote
               (read-string
                "Java version (empty for provider default): "
                (unless (eq provider 'micronaut)
                  java-kit-new-default-java-version))))
         (java (unless (string-empty-p (or java "")) java))
         (dependencies
          (and remote (java-kit-new--read-dependencies provider))))
    (java-kit-new-project-from-spec
     (list :provider provider :parent parent :group group
           :artifact artifact :package package :build build
           :java java :dependencies dependencies))))

(provide 'java-kit-new)
;;; java-kit-new.el ends here
