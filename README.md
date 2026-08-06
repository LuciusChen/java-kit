# java-kit

Project-aware Java development for Emacs, Eglot, JDTLS, Dape, Spring Boot, and Tomcat.

`java-kit` is a clean replacement for the local `eglot-java` fork and `java-server`. It preserves their useful workflows while removing dependency-private Eglot calls, global JDK mutation, global JVM discovery, blocking sleeps, and shared single-project process state.

## Coverage

| Previous outcome | `java-kit` replacement |
| --- | --- |
| Register and configure JDTLS | `java-kit-mode`, `java-kit-eglot-register` |
| Install or upgrade JDTLS | `java-kit-install-jdtls` |
| Install or upgrade JUnit Console | `java-kit-install-junit` |
| Detect or choose a project JDK | automatic resolution, `java-kit-select-project-jdk` |
| Build or run a build-tool test task | `java-kit-build`, `java-kit-test` |
| Run or debug a main class | `java-kit-run-main`, `java-kit-debug-main` |
| Run or debug a JUnit class/method | `java-kit-run-test`, `java-kit-debug-test` |
| Refresh the JDTLS project model | `java-kit-project-refresh` |
| Navigate into dependency classes | read-only `jdt://` materialization registered with Eglot |
| Create a Java class, record, enum, interface, annotation, or test | `java-kit-new-java-type` |
| Create Maven, Gradle, Spring, Micronaut, Quarkus, or Vert.x projects | `java-kit-new-project` |
| Build/run/stop/restart Spring Boot | `java-kit-spring-boot-run`, `java-kit-spring-boot-stop`, `java-kit-spring-boot-restart` |
| Build/deploy/stop/rebuild and restart Tomcat WARs | `java-kit-tomcat-deploy`, `java-kit-tomcat-stop`, `java-kit-tomcat-restart` |
| Attach a debugger to a listening JVM | `java-kit-dape-attach` |
| Replace changed classes in a Java debug session | automatic build events or `java-kit-hot-replace` |
| View managed service state | `java-kit-app-status` and the mode-line summary |

This is functional coverage, not an API-compatible fork: old command names and unsafe global behaviors are intentionally not aliased.

## Requirements

- Emacs 30.1 or newer
- Java 21 or newer to launch current JDTLS releases; a project may still use an older, separate JDK
- Maven or Gradle unless the project supplies `mvnw` or `gradlew`
- `unzip` for projects downloaded from remote starter services
- Dape plus the Microsoft Java Debug JDTLS bundle for debug commands
- an external Tomcat installation for Tomcat commands

The [Eclipse JDTLS project](https://github.com/eclipse-jdtls/eclipse.jdt.ls) documents its runtime requirement and release archives. The [JUnit Console Launcher](https://docs.junit.org/current/running-tests/console-launcher.html) is distributed as a standalone executable JAR.

## Installation

For this local checkout:

```emacs-lisp
(use-package java-kit
  :load-path "~/repos/java-kit"
  :hook ((java-mode java-ts-mode) . java-kit-mode))
```

After publishing the repository:

```emacs-lisp
(use-package java-kit
  :straight (:host github :repo "LuciusChen/java-kit")
  :hook ((java-mode java-ts-mode) . java-kit-mode))
```

The main library declares lazy autoloads for the debugging, application, installer, and scaffolding modules, so loading `java-kit.el` does not start servers, processes, downloads, or network requests.

## Tool installation

Tool downloads are always explicit:

- `M-x java-kit-install-jdtls` installs or upgrades the latest Eclipse milestone; customize `java-kit-jdtls-release-channel` for snapshots
- `M-x java-kit-install-junit` installs or upgrades the newest stable Java 8-compatible JUnit Platform 1.x release
- `M-x java-kit-tools-status` shows recorded installed versions

Both installers stage downloads beside their destinations and verify published SHA-256 checksums before replacement. Use a prefix argument to force reinstallation of the same version.

To follow JUnit's newest major instead of the Java 8-compatible line:

```emacs-lisp
(setopt java-kit-junit-release-line 'latest)
```

JUnit 6 requires Java 17 at runtime. An explicit `java-kit-junit-version` pin takes precedence over the release line.

With `java-kit-jdtls-command` nil, the installed `java-kit` launcher is preferred, followed by `jdtls` on `PATH`. Set an explicit command when JDTLS is managed elsewhere:

```emacs-lisp
(setopt java-kit-jdtls-command '("/path/to/jdtls"))
```

## JDK model

JDTLS and project subprocesses have separate JDK settings:

```emacs-lisp
(setopt java-kit-jdtls-java-home "/path/to/jdk-21"
        java-kit-project-java-home nil)
```

For project processes, `java-kit` checks an interactive per-module choice, an explicit customization, `org.gradle.java.home`, then these version declarations in order:

1. `.java-version`
2. `.tool-versions`
3. `.sdkmanrc`
4. Maven compiler properties
5. common Gradle toolchain and source-compatibility syntax

On macOS, versions are resolved through `/usr/libexec/java_home`; on Linux, installed homes under `/usr/lib/jvm` are considered. `M-x java-kit-select-project-jdk` records a choice only for the current build module, and `C-u M-x java-kit-select-project-jdk` clears it. No command changes Emacs' global `JAVA_HOME` or `PATH`.

For a persistent project override, use `.dir-locals.el`:

```emacs-lisp
((java-mode . ((java-kit-project-java-home . "/path/to/project-jdk")))
 (java-ts-mode . ((java-kit-project-java-home . "/path/to/project-jdk"))))
```

## JDTLS and Java Debug

Launcher JVM arguments, initialization options, workspace location, and extension bundles are explicit customizations:

```emacs-lisp
(setopt java-kit-jdtls-jvm-arguments
        '("-Xmx4G" "-XX:+UseStringDeduplication")
        java-kit-jdtls-bundles
        '("/path/to/com.microsoft.java.debug.plugin-VERSION.jar"))
```

Each project gets a JDTLS data directory derived from its complete project path, so equal directory basenames do not collide. Project JDK settings are sent to JDTLS without changing the JDK that launches JDTLS.

`java-kit-eglot-register` also registers the `jdt://` file handler. Dependency class contents requested through `java/classFileContents` are cached as read-only Java files. Use `java-kit-clear-class-cache` to remove that cache, or `java-kit-jdt-uri-unregister` to remove the handler.

## Build, run, test, and refresh

- `M-x java-kit-build` prompts for a Maven or Gradle task
- `M-x java-kit-test` runs the build tool's `test` task
- `M-x java-kit-run-main` runs the class at point with the runtime classpath reported by JDTLS
- `M-x java-kit-run-test` runs the JUnit method at point, or its containing class, with the test classpath reported by JDTLS
- `M-x java-kit-project-refresh` asks JDTLS to reload the build file and rebuild its workspace model

Module wrappers take precedence over project-root wrappers, which take precedence over global tools. Commands run from the nearest build-module root while JDTLS workspace identity remains tied to the project root.

Program, JVM, and environment arguments are configurable without shell interpolation or global environment changes:

```emacs-lisp
(setopt java-kit-main-arguments '("--profile" "local")
        java-kit-main-jvm-arguments '("-Xmx2g")
        java-kit-main-environment '("APP_ENV=dev")
        java-kit-test-jvm-arguments '("-ea")
        java-kit-test-environment '("TEST_ENV=focused"))
```

Focused JUnit runs require `java-kit-junit-console-jar`; install it explicitly with `java-kit-install-junit`. A prefix argument to `java-kit-run-main` or `java-kit-run-test` routes to the corresponding Dape debug command.

## Creating files and projects

`java-kit-new-java-type` asks JDTLS for project source roots, then creates a class, record, enum, interface, annotation, or JUnit test from a small local template. It rejects invalid qualified names and existing destination files.

`java-kit-new-project` supports local Maven archetype generation, local Gradle `init`, and the official Spring Initializr, Micronaut Launch, Quarkus, and Eclipse Vert.x starter services. Remote dependency choices are loaded from each provider's current metadata. Downloaded ZIP entries are checked for path traversal before extraction, and an existing destination is never overwritten.

The remote integrations follow the providers' documented generators: [Spring Initializr](https://docs.spring.io/initializr/docs/current/reference/html/), [Micronaut Launch](https://launch.micronaut.io), [Quarkus Code](https://code.quarkus.io), and [Vert.x Starter](https://start.vertx.io).

## Spring Boot, Tomcat, and Dape

`java-kit-spring-boot-run` builds with Maven `package -DskipTests` or Gradle `bootJar -x test`, then starts the newest runnable JAR with the resolved project JDK. The stop and restart commands affect only the process recorded for the current module.

Tomcat is detected from `CATALINA_HOME`, `catalina.sh` on `PATH`, or an unambiguous conventional macOS/Linux installation. Homebrew keeps configuration under `etc/tomcat@9`, but the installation home is its `libexec` directory:

```emacs-lisp
(setopt java-kit-tomcat-home "/opt/homebrew/opt/tomcat@9/libexec"
        java-kit-tomcat-context-name "ROOT")
```

For a Linux package that follows [Tomcat's separate `CATALINA_HOME` and `CATALINA_BASE` model](https://tomcat.apache.org/tomcat-9.0-doc/introduction.html#CATALINA_HOME_and_CATALINA_BASE), configure both directories; the base must be writable by Emacs:

```emacs-lisp
(setopt java-kit-tomcat-home "/usr/share/tomcat10"
        java-kit-tomcat-base "/var/lib/tomcat10")
```

Arch Linux's `tomcat9` package is detected under `/usr/share/tomcat9`; its `conf` and `webapps` entries point to `/etc/tomcat9` and `/var/lib/tomcat9/webapps`. The effective `webapps` directory must be writable by the Emacs user.

`CATALINA_BASE` is honored when `java-kit-tomcat-base` is nil; otherwise the base defaults to the detected home. Both `java-kit-tomcat-deploy` and `java-kit-tomcat-restart` build the current WAR, stop the tracked Tomcat after a successful build, replace only the configured WAR file in the base's `webapps`, and start the home's `catalina.sh run` as a tracked foreground process. They never use `pgrep` or kill an unrelated Tomcat. A single Tomcat base cannot be managed concurrently for two projects.

Use a prefix argument with Spring Boot run or Tomcat deploy/restart to enable JDWP. `java-kit-app-auto-debug-attach` can attach Dape after the readiness message; it defaults to nil. `java-kit-dape-attach` can also attach manually to any listening JDWP port through the JDTLS Java Debug adapter.

For Dape launch commands, the JDTLS debug-adapter transport port and the target JVM's JDWP port remain distinct. This fixes the port conflation in the old server package.

Hot Code Replace is controlled by `java-kit-hot-code-replace-mode`: `auto` reacts to Java Debug's completed-build event, `manual` enables only `M-x java-kit-hot-replace`, and `never` disables replacement. If the debuggee is running, java-kit queues the standard Java Debug `redefineClasses` request, pauses it through Dape's public request API, and resumes only after the request finishes. Structural JVM changes still require a restart.

The old package's generated Attach API agent and exploded-Tomcat class-copy fallback are not copied. They were private implementation-specific optimizations; java-kit provides the same public Hot Code Replace workflow through the supported Java Debug adapter boundary.

## Default bindings

`java-kit-mode` uses the `C-c C-j` prefix:

- `b`: build task
- `t`: build-tool test task
- `m`: run main
- `u`: run focused JUnit test
- `r`: refresh JDTLS project model
- `d`: debug main
- `D`: debug focused JUnit test
- `h`: Hot Code Replace
- `j`: select project JDK
- `n`: create Java type
- `N`: create project

## Development

Run the complete test suite:

```sh
emacs -Q --batch -L . -L test --eval '(setq load-prefer-newer t)' \
  -l test/java-kit-test.el \
  -f ert-run-tests-batch-and-exit
```

Byte-compile all distributable modules:

```sh
emacs -Q --batch -L . -f batch-byte-compile \
  java-kit.el java-kit-debug.el java-kit-app.el \
  java-kit-install.el java-kit-new.el
```

The suite uses temporary directories and mocked protocol/process boundaries; it does not require a local JDK, Maven repository, active Eglot session, or running application server.

## License

GPL-3.0-or-later.
