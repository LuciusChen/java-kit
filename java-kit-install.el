;;; java-kit-install.el --- Explicit Java tool installation  -*- lexical-binding: t; -*-

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

;; This module installs JDTLS and the JUnit Platform Console only through
;; explicit interactive commands.  Downloads are verified with SHA-256 and
;; staged beside the destination before replacing a previous installation.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tar-mode)
(require 'url)
(require 'url-handlers)
(require 'url-http)
(require 'java-kit)

(defcustom java-kit-jdtls-release-channel 'milestone
  "Eclipse JDTLS release channel installed by java-kit."
  :type '(choice (const :tag "Latest milestone" milestone)
                 (const :tag "Latest snapshot" snapshot))
  :group 'java-kit)

(defcustom java-kit-jdtls-download-root
  "https://download.eclipse.org/jdtls"
  "Official Eclipse JDTLS download root."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-jdtls-milestones-index-url
  "https://download.eclipse.org/justj/?file=jdtls%2Fmilestones"
  "Official Eclipse directory page used to discover the latest milestone."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-junit-maven-root
  "https://repo1.maven.org/maven2"
  "Maven repository root for the JUnit Platform Console artifact."
  :type 'string
  :group 'java-kit)

(defcustom java-kit-junit-version nil
  "Optional JUnit Platform Console version to install.

When nil, select a version according to `java-kit-junit-release-line'."
  :type '(choice (const :tag "Latest release" nil)
                 (string :tag "Pinned version"))
  :group 'java-kit)

(defcustom java-kit-junit-release-line 'java-8-compatible
  "JUnit release line selected when `java-kit-junit-version' is nil.

The Java 8-compatible line chooses the newest stable 1.x JUnit Platform,
which corresponds to JUnit 5.  The latest line follows Maven's release value
and may require a newer project JDK."
  :type '(choice (const :tag "Newest Java 8-compatible 1.x release"
                        java-8-compatible)
                 (const :tag "Latest release of any major" latest))
  :group 'java-kit)

(defcustom java-kit-install-download-timeout 600
  "Seconds an asynchronous JDTLS download may take before it is abandoned."
  :type 'number
  :group 'java-kit)

(defconst java-kit-install--junit-artifact
  "org/junit/platform/junit-platform-console-standalone"
  "Maven path of the JUnit Platform Console standalone artifact.")

(defun java-kit-install--url-text (url)
  "Retrieve URL synchronously and return its trimmed text."
  (with-temp-buffer
    (url-insert-file-contents url)
    (string-trim (buffer-string))))

(defun java-kit-install--latest-milestone-version (index)
  "Return the newest JDTLS milestone version found in INDEX."
  (let ((case-fold-search t)
        (position 0)
        versions)
    (while (string-match
            "milestones\\(?:%2f\\|/\\)\\([0-9]+\\(?:\\.[0-9]+\\)+\\)"
            index position)
      (push (match-string 1 index) versions)
      (setq position (match-end 0)))
    (car (sort (delete-dups versions)
               (lambda (first second) (version< second first))))))

(defun java-kit-install--jdtls-release-from-file (channel file)
  "Return release metadata for CHANNEL and archive FILE."
  (unless (string-match
           "\\`jdt-language-server-\\([0-9]+\\(?:\\.[0-9]+\\)+\\)-[0-9]+\\.tar\\.gz\\'"
           file)
    (user-error "Unexpected JDTLS release file name: %s" file))
  (let* ((version (match-string 1 file))
         (channel-name (symbol-name channel))
         (directory
          (if (eq channel 'milestone)
              (format "%s/milestones/%s"
                      (string-remove-suffix "/" java-kit-jdtls-download-root)
                      version)
            (format "%s/snapshots"
                    (string-remove-suffix "/"
                                          java-kit-jdtls-download-root))))
         (url (format "%s/%s" directory file)))
    (list :tool 'jdtls :channel channel-name :version version
          :file file :url url :checksum-url (concat url ".sha256"))))

(defun java-kit-install--jdtls-release ()
  "Retrieve metadata for the configured JDTLS release channel."
  (pcase java-kit-jdtls-release-channel
    ('milestone
     (let* ((index
             (java-kit-install--url-text
              java-kit-jdtls-milestones-index-url))
            (version (java-kit-install--latest-milestone-version index)))
       (unless version
         (user-error "Could not discover a JDTLS milestone release"))
       (java-kit-install--jdtls-release-from-file
        'milestone
        (java-kit-install--url-text
         (format "%s/milestones/%s/latest.txt"
                 (string-remove-suffix "/" java-kit-jdtls-download-root)
                 version)))))
    ('snapshot
     (java-kit-install--jdtls-release-from-file
      'snapshot
      (java-kit-install--url-text
       (format "%s/snapshots/latest.txt"
               (string-remove-suffix "/"
                                     java-kit-jdtls-download-root)))))
    (_ (user-error "Unsupported JDTLS release channel: %s"
                   java-kit-jdtls-release-channel))))

(defun java-kit-install--junit-metadata-url ()
  "Return the configured JUnit Maven metadata URL."
  (format "%s/%s/maven-metadata.xml"
          (string-remove-suffix "/" java-kit-junit-maven-root)
          java-kit-install--junit-artifact))

(defun java-kit-install--metadata-release (metadata)
  "Return the release version declared by Maven METADATA XML."
  (when (string-match
         "<release>[[:space:]]*\\([^<[:space:]]+\\)[[:space:]]*</release>"
         metadata)
    (match-string 1 metadata)))

(defun java-kit-install--metadata-versions (metadata)
  "Return all versions declared by Maven METADATA XML."
  (let ((position 0)
        versions)
    (while (string-match
            "<version>[[:space:]]*\\([^<[:space:]]+\\)[[:space:]]*</version>"
            metadata position)
      (push (match-string 1 metadata) versions)
      (setq position (match-end 0)))
    (nreverse versions)))

(defun java-kit-install--latest-java-8-junit-version (metadata)
  "Return the newest stable Java 8-compatible JUnit version in METADATA."
  (car
   (sort
    (seq-filter
     (lambda (version)
       (string-match-p "\\`1\\.[0-9]+\\.[0-9]+\\'" version))
     (java-kit-install--metadata-versions metadata))
    (lambda (first second) (version< second first)))))

(defun java-kit-install--valid-artifact-version-p (version)
  "Return non-nil when VERSION is safe in an artifact URL and file name."
  (and (stringp version)
       (string-match-p "\\`[0-9A-Za-z][0-9A-Za-z._-]*\\'" version)))

(defun java-kit-install--junit-release ()
  "Retrieve metadata for the configured JUnit Console release."
  (let* ((metadata
          (unless java-kit-junit-version
            (java-kit-install--url-text
             (java-kit-install--junit-metadata-url))))
         (version
          (or java-kit-junit-version
              (pcase java-kit-junit-release-line
                ('java-8-compatible
                 (java-kit-install--latest-java-8-junit-version metadata))
                ('latest (java-kit-install--metadata-release metadata))
                (_ (user-error "Unsupported JUnit release line: %s"
                               java-kit-junit-release-line)))))
         (artifact "junit-platform-console-standalone"))
    (unless (java-kit-install--valid-artifact-version-p version)
      (user-error "Could not determine a valid JUnit release version"))
    (let ((url
           (format "%s/%s/%s/%s-%s.jar"
                   (string-remove-suffix "/" java-kit-junit-maven-root)
                   java-kit-install--junit-artifact version artifact version)))
      (list :tool 'junit :version version :url url
            :checksum-url (concat url ".sha256")))))

(defun java-kit-install--file-sha256 (file)
  "Return the hexadecimal SHA-256 digest for FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun java-kit-install--expected-sha256 (checksum-text)
  "Return the SHA-256 digest found in CHECKSUM-TEXT."
  (let ((case-fold-search t))
    (when (string-match "\\b\\([[:xdigit:]]\\{64\\}\\)\\b" checksum-text)
      (downcase (match-string 1 checksum-text)))))

(defun java-kit-install--verify-download (file checksum-text)
  "Verify FILE against CHECKSUM-TEXT or signal an error."
  (let ((expected (java-kit-install--expected-sha256 checksum-text))
        (actual (java-kit-install--file-sha256 file)))
    (unless expected
      (error "Release source did not provide a valid SHA-256 checksum"))
    (unless (string-equal expected actual)
      (error "SHA-256 mismatch for %s" (file-name-nondirectory file)))
    actual))

(defun java-kit-install--extract-tar-gz (archive destination)
  "Extract ARCHIVE into DESTINATION using Emacs' built-in tar support."
  (make-directory destination t)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally archive)
    (unless (zlib-decompress-region (point-min) (point-max))
      (error "Could not decompress %s" archive))
    (tar-mode)
    (dolist (descriptor tar-parse-info)
      (let ((name (tar-header-name descriptor)))
        (unless (java-kit--safe-archive-entry-p name destination)
          (error "Unsafe path in JDTLS archive: %s" name))))
    (setq default-directory (file-name-as-directory destination))
    (tar-untar-buffer)))

(defun java-kit-install--version-file (directory)
  "Return java-kit's version marker under DIRECTORY."
  (expand-file-name ".java-kit-version" directory))

(defun java-kit-install--read-version (file)
  "Return the trimmed installed version from FILE."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (string-trim (buffer-string)))))

(defun java-kit-install--replace-directory (staged destination)
  "Atomically replace DESTINATION with STAGED and roll back on failure."
  (let* ((destination (directory-file-name (expand-file-name destination)))
         (backup (make-temp-name (concat destination ".backup-")))
         (had-destination (file-exists-p destination)))
    (condition-case error-data
        (progn
          (when had-destination
            (rename-file destination backup))
          (rename-file staged destination)
          (when (file-exists-p backup)
            (delete-directory backup t)))
      (error
       (when (and had-destination (file-exists-p backup))
         (when (file-exists-p destination)
           (delete-directory destination t))
         (rename-file backup destination))
       (signal (car error-data) (cdr error-data))))))

(defun java-kit-install--download-release (release destination)
  "Download RELEASE into DESTINATION and verify its checksum."
  (message "Downloading %s %s..."
           (plist-get release :tool) (plist-get release :version))
  (url-copy-file (plist-get release :url) destination t)
  (java-kit-install--verify-download
   destination
   (java-kit-install--url-text (plist-get release :checksum-url))))

(defvar java-kit-install--jdtls-installing nil
  "Non-nil while a JDTLS installation is in progress.")

(defvar url-http-end-of-headers)

(defun java-kit-install--abandon-requests (handler)
  "Close every connection whose completion callback is HANDLER.
A redirect continues in a new buffer, so the buffer `url-retrieve' returned
is not necessarily the one holding the live connection."
  (dolist (buffer (buffer-list))
    (when (and (local-variable-p 'url-callback-function buffer)
               (eq handler (buffer-local-value 'url-callback-function buffer)))
      (when-let* ((process (get-buffer-process buffer)))
        (delete-process process))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun java-kit-install--download-async (url file callback)
  "Download URL to FILE without blocking Emacs, then call CALLBACK.
CALLBACK receives nil on success or an error message string.  A download
that exceeds `java-kit-install-download-timeout' is abandoned."
  (let (done timer handler)
    (cl-flet ((finish (message)
                (unless done
                  (setq done t)
                  (when timer (cancel-timer timer))
                  (funcall callback message))))
      (setq handler
            (lambda (status)
              (let ((response (current-buffer)))
                (finish
                 (unwind-protect
                     (condition-case error-data
                         (cond
                          (done nil)
                          ((plist-get status :error)
                           (format "Download failed: %S"
                                   (plist-get status :error)))
                          ((/= 200 (url-http-parse-response))
                           (format "Download failed: HTTP %s"
                                   (url-http-parse-response)))
                          (t
                           (let ((coding-system-for-write 'binary))
                             (write-region (1+ url-http-end-of-headers)
                                           (point-max) file nil 'silent))
                           nil))
                       (error (error-message-string error-data)))
                   (kill-buffer response))))))
      (condition-case error-data
          (progn
            (url-retrieve url handler nil t)
            (unless done
              (setq timer
                    (run-at-time
                     java-kit-install-download-timeout nil
                     (lambda ()
                       (finish "Download timed out")
                       (java-kit-install--abandon-requests handler))))))
        (error
         (finish (format "Download could not start: %s"
                         (error-message-string error-data))))))))

(defun java-kit-install--install-jdtls-release (release &optional on-done)
  "Install the JDTLS RELEASE transactionally without blocking Emacs.
The archive downloads in the background; ON-DONE is called with nil on
success or an error message string."
  (when java-kit-install--jdtls-installing
    (user-error "A JDTLS installation is already in progress"))
  (let* ((destination
          (directory-file-name
           (expand-file-name java-kit-jdtls-install-directory)))
         (parent (file-name-directory destination)))
    (make-directory parent t)
    (let* ((temporary
            (make-temp-file (expand-file-name ".jdtls-stage-" parent) t))
           (archive (expand-file-name (plist-get release :file) temporary))
           (payload (expand-file-name "payload" temporary)))
      (cl-flet ((finish (message)
                  (setq java-kit-install--jdtls-installing nil)
                  (when (file-exists-p temporary)
                    (delete-directory temporary t))
                  (when on-done (funcall on-done message))))
        (setq java-kit-install--jdtls-installing t)
        (message "Downloading %s %s..."
                 (plist-get release :tool) (plist-get release :version))
        (java-kit-install--download-async
         (plist-get release :url) archive
         (lambda (failure)
           (finish
            (or failure
                (condition-case error-data
                    (progn
                      (java-kit-install--verify-download
                       archive
                       (java-kit-install--url-text
                        (plist-get release :checksum-url)))
                      (java-kit-install--extract-tar-gz archive payload)
                      (unless (file-regular-p
                               (expand-file-name "bin/jdtls" payload))
                        (error "Downloaded JDTLS archive has no bin/jdtls launcher"))
                      (with-temp-file (java-kit-install--version-file payload)
                        (insert (plist-get release :version) "\n"))
                      (java-kit-install--replace-directory payload destination)
                      nil)
                  (error (error-message-string error-data)))))))))))

(defun java-kit-install--junit-version-file ()
  "Return the version marker associated with the configured JUnit JAR."
  (concat (expand-file-name java-kit-junit-console-jar) ".version"))

(defun java-kit-install--install-junit-release (release)
  "Install the JUnit RELEASE transactionally."
  (let* ((destination (expand-file-name java-kit-junit-console-jar))
         (parent (file-name-directory destination)))
    (make-directory parent t)
    (let* ((temporary
            (make-temp-file (expand-file-name ".junit-stage-" parent) t))
           (jar (expand-file-name "junit-console.jar" temporary)))
      (unwind-protect
          (progn
            (java-kit-install--download-release release jar)
            (rename-file jar destination t)
            (with-temp-file (java-kit-install--junit-version-file)
              (insert (plist-get release :version) "\n")))
        (when (file-exists-p temporary)
          (delete-directory temporary t))))))

;;;###autoload
(defun java-kit-install-jdtls (&optional force)
  "Install or upgrade JDTLS from the configured release channel.

The archive downloads in the background; Emacs reports the outcome when it
finishes.  With prefix argument FORCE, reinstall an unchanged release."
  (interactive "P")
  (let* ((release (java-kit-install--jdtls-release))
         (version (plist-get release :version))
         (installed
          (java-kit-install--read-version
           (java-kit-install--version-file
            java-kit-jdtls-install-directory))))
    (if (and (not force) (equal installed version))
        (message "JDTLS %s is already installed" version)
      (java-kit-install--install-jdtls-release
       release
       (lambda (failure)
         (if failure
             (message "JDTLS installation failed: %s" failure)
           (message "Installed JDTLS %s; restart Eglot to use it" version)))))))

;;;###autoload
(defun java-kit-install-junit (&optional force)
  "Install or upgrade the JUnit Platform Console standalone JAR.

With prefix argument FORCE, reinstall an unchanged release."
  (interactive "P")
  (let* ((release (java-kit-install--junit-release))
         (version (plist-get release :version))
         (installed
          (java-kit-install--read-version
           (java-kit-install--junit-version-file))))
    (if (and (not force) (equal installed version)
             (file-regular-p (expand-file-name java-kit-junit-console-jar)))
        (message "JUnit Platform Console %s is already installed" version)
      (java-kit-install--install-junit-release release)
      (message "Installed JUnit Platform Console %s" version))))

;;;###autoload
(defun java-kit-tools-status ()
  "Display and return locally installed java-kit tool versions."
  (interactive)
  (let ((status
         (list
          :jdtls
          (java-kit-install--read-version
           (java-kit-install--version-file
            java-kit-jdtls-install-directory))
          :junit
          (java-kit-install--read-version
           (java-kit-install--junit-version-file)))))
    (message "JDTLS: %s; JUnit Console: %s"
             (or (plist-get status :jdtls) "not installed")
             (or (plist-get status :junit) "not installed"))
    status))

(provide 'java-kit-install)
;;; java-kit-install.el ends here
