# java-kit Development Guide

This file is self-contained. It adapts the applicable engineering and Emacs Lisp rules from `~/repos/coding-guidelines` to this project.

## Product Boundary

- Build `java-kit` as the eventual maintained replacement for both the local `eglot-java` fork and `java-server`: project-aware JDTLS setup, JDK resolution, build/run/test/navigation workflows, JDTLS and test-tool installation, Java project/file scaffolding, Spring Boot and Tomcat lifecycle management, and optional Dape integration are in scope.
- Land that scope incrementally. A capability is not complete until its public command, project-isolation rules, error behavior, tests, and README documentation agree.
- Do not preserve an old implementation merely for compatibility. Preserve useful user outcomes while replacing private APIs, global process discovery, global environment mutation, blocking sleeps, and ambiguous JDK/port state with explicit designs.
- Treat JDTLS JDK and project JDK as separate concepts. Never make one setting silently control both.
- Never mutate global `JAVA_HOME` or `PATH` for project builds or JDTLS startup. Construct a subprocess-only environment.
- Track project root and nearest build-module root separately. Prefer a module wrapper, then a project-root wrapper, then a global build tool.
- Keep Emacs 30.1 as the explicit baseline. Do not raise it silently; update package metadata, README, and this decision when a newer API becomes necessary.

## Architecture

- Prefer one clear entry point and one behavior model. `java-kit-build` owns Maven/Gradle task execution; narrower commands should call the same path.
- Keep project discovery, JDK resolution, build/run/test/navigation workflows, JDTLS registration, and the minor mode in `java-kit.el`.
- Keep Spring Boot, Tomcat, and tracked process lifecycle in `java-kit-app.el`; Dape and Hot Code Replace in `java-kit-debug.el`; explicit tool installation in `java-kit-install.el`; and Java type/project scaffolding in `java-kit-new.el`.
- Question every abstraction. Inline trivial one-use wrappers and avoid piles of pass-through helpers.
- Split only by stable responsibility, never into vague `common`, `utils`, or `helpers` modules.
- Separate pure resolution and command construction from filesystem, process, Eglot, and UI side effects.
- Use plain plists for short-lived project context. Introduce a struct or object only when stable state crosses a real lifecycle boundary.
- Use only public APIs from Eglot and other dependencies. Symbols with another package's double-dash prefix are out of bounds.
- Loading `java-kit.el` must not alter active editing behavior. Registration and startup happen only through explicit commands or `java-kit-mode`.

## Emacs Lisp Conventions

- Enable lexical binding in every Elisp file.
- Prefix public API with `java-kit-`; prefix private implementation with `java-kit--`.
- End multi-word predicates in `-p` and prefix unused arguments with `_`.
- Add `;;;###autoload` only to user-facing commands and modes.
- Give every public function, macro, variable, and customization a docstring. Its first line must be a complete sentence ending with a period, and argument names must be uppercase.
- Give each `defcustom` a precise `:type` and `:group 'java-kit`.
- Prefer flat control flow, `when-let*`, `if-let*`, `pcase`, and `cl-loop` over deep nesting or manual accumulators.
- Use stock Emacs facilities such as `project.el`, `compilation-mode`, `completing-read`, and Eglot public APIs before inventing frameworks.
- Use `user-error` for invalid user or project state and `error` only for programmer faults. Do not silently replace a failed resolution with a plausible but wrong value.
- Catch errors only at genuine external boundaries or for non-essential recoverable operations.
- Keep functions near 30 lines when practical. Extract a helper only when it names a real computation or removes a duplicated rule.
- Treat optional integrations as optional: load them at the point of use and report a clear boundary error when unavailable.
- Do not add compatibility shims, deprecated aliases, or re-exports without an explicit compatibility requirement.

## Testing Discipline

- Use the smallest ERT test that proves the behavior, but drive the public or installed dispatch path when the bug concerns mode registration, hooks, command routing, or callbacks.
- Assert distinct outputs across multiple inputs and boundary cases; avoid tests that can pass with a hard-coded return.
- For a user-visible regression, write and run a failing test first unless an existing test already demonstrates the fault.
- Keep tests focused on public workflows and durable invariants: project/module separation, wrapper precedence, JDK isolation, initialization options, Eglot registration, tracked-process and debug-session ownership, Hot Code Replace state transitions, transactional installation, scaffold validation, and public protocol boundaries.
- Tests must use temporary directories and must not depend on the developer's installed JDKs, Maven repositories, or active Eglot sessions.

## Documentation

- Update `README.md` in the same change as any key binding, default, configuration, compatibility, or user-visible workflow change.
- Code is the source of truth. Fix documentation immediately when it diverges.
- Keep each semantic Markdown paragraph on one source line and let renderers wrap it. Do not reflow unchanged prose merely to fit a source-width limit.
- Lead with concrete user outcomes and verify every documented command, capability, and requirement against code or tests.
- Keep documentation-only work documentation-only unless the user explicitly asks for implementation changes.

## Required Quality Gates

Before declaring a code change complete:

1. Read the full diff and remove dead code, duplicated logic, and accidental scope expansion.
2. Run `check-parens` on every changed Elisp file.
3. Byte-compile every distributable Elisp file with zero warnings.
4. Run the complete ERT suite, ensuring stale `.elc` files cannot shadow newer source.
5. Run `checkdoc` with zero warnings.
6. Run `package-lint` with zero warnings on `java-kit.el`.
7. Search for accidental calls to external private APIs, especially `eglot--*`.
8. Confirm `git status` contains only intended files and no generated `.elc` artifacts.

Reference commands:

```sh
emacs -Q --batch -L . -f batch-byte-compile java-kit.el java-kit-debug.el java-kit-app.el java-kit-install.el java-kit-new.el
emacs -Q --batch -L . -L test --eval '(setq load-prefer-newer t)' -l test/java-kit-test.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L ~/.emacs.d/straight/repos/package-lint -l package-lint -f package-lint-batch-and-exit java-kit.el
rg -n '\b(eglot|dape|project|jsonrpc|compilation|archive|tar|url)--' --glob '*.el'
git diff --check
```

Delete generated `.elc` files after local verification; they are not source artifacts.
