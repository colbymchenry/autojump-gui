# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

This repo contains **two cooperating projects** sharing one source tree:

1. **`autojump`** (root: `bin/`, `tests/`, `docs/`, `install.py`) — the upstream shell + Python tool. A `j` command jumps to frequently-used directories using a weighted database fed from prompt hooks.
2. **`autojump-gui`** (`autojump-gui/`) — a macOS menu bar app (Swift / SwiftUI / AppKit) that provides a Spotlight-style launcher (⌘J) over the same database, plus passive Finder navigation tracking and a one-click installer for the shell integration.

The Swift app bundles the Python CLI and shell hooks as resources (`autojump-gui/autojump-gui/cli/`) so the GUI can install or invoke them without requiring a separate `./install.py` step. The bundled `cli/` directory is a curated subset of `bin/` — keep them in sync when modifying the CLI.

## Commands

### Python CLI (`autojump`)

- `make test` — full tox matrix (py26/27/33/34/35 + pre-commit lint).
- `make test-fast` — py27 only.
- `make test-xfail` — runs xfail-marked tests too.
- `make lint` — installs pre-commit hooks and runs them across all files (autopep8, flake8 max-line-length=131, max-complexity=10, reorder-imports, add-trailing-comma).
- `tox -e py35 -- tests/unit/autojump_match_test.py::test_match_anywhere` — run a single test (substitute env/path as needed). The underlying invocation is `coverage run --source=bin/ --omit=bin/autojump_argparse.py -m py.test`.
- `make docs` — regenerates `docs/autojump.1` and `README.md` from `docs/header.md`, `docs/install.md`, `docs/body.md` via `pandoc`. Edit the docs sources, not the generated files.
- `./install.py` / `./uninstall.py` — install/remove autojump for the current shell. Both accept `--dryrun`, `--force`, and prefix flags. (End users of the GUI app should use the menu's "Install CLI integration…" instead.)

### Swift GUI app (`autojump-gui/`)

- Open `autojump-gui/autojump-gui.xcodeproj` in Xcode and build the `autojump-gui` scheme. The product is `Autojump.app` (a `LSUIElement` accessory app — no Dock icon).
- `bash autojump-gui/scripts/release.sh` — full Release flow: `xcodebuild archive` → export with Developer ID signing → notarize the `.app` → staple → build a DMG via `create-dmg` → notarize and staple the DMG. Reads `autojump-gui/scripts/release.env` (gitignored; copy `release.env.example`). Requires `brew install create-dmg` and a valid App Store Connect API key.
- The release script reads `MARKETING_VERSION` from the project; bump it in Xcode before cutting a release.

## Architecture

### Python CLI: shell ⇄ Python boundary

Two halves cooperate via a weighted text database at `~/Library/autojump/autojump.txt` on macOS (XDG on Linux, `%APPDATA%` on Windows):

1. **Shell integration** (`bin/autojump.{bash,zsh,fish,sh,tcsh,lua,bat}`): hooks the shell's prompt (`PROMPT_COMMAND` on bash, `chpwd_functions` on zsh, etc.) to call `autojump --add "$(pwd)"` on every directory change. Defines the `j`, `jc`, `jo`, `jco` shell functions/wrappers, which call the Python CLI to *resolve* a query and then `cd` to its stdout. `autojump.sh` is the cross-shell loader; `_j` is a zsh completion helper.
2. **Python core** (`bin/autojump`, `bin/autojump_*.py`): single-file CLI plus three modules. No external runtime deps — `bin/autojump_argparse.py` is a vendored copy of argparse for Python 2.6 support. Modules use file-prefixed names + relative imports (the `bin/` dir is added to `sys.path`) rather than a package, deliberately, because they are shipped as loose files.

The split matters: anything that needs to run on every prompt must stay in the shell layer for speed; anything matching/ranking lives in Python.

#### Python module responsibilities

- `bin/autojump` — entry point. Argparse setup, `set_defaults()` (resolves `data_home` per-OS), `find_matches()` orchestrator that fans out to the three matchers in order, and the `--add` / `--increase` / `--decrease` / `--purge` / `--stat` paths.
- `bin/autojump_data.py` — `Entry` namedtuple `(path, weight)`, `load()`/`save()` of the tab-separated database, atomic-rename via `NamedTemporaryFile`, daily backup (`BACKUP_THRESHOLD = 24h`), `dictify`/`entriefy` conversions. Weight update formula is `sqrt(old² + 10²)`.
- `bin/autojump_match.py` — three matchers tried in cascade: `match_consecutive` (substring) → `match_fuzzy` (difflib `SequenceMatcher` ≥ `FUZZY_MATCH_THRESHOLD = 0.6`) → `match_anywhere` (regex with `.*` between needles). Case-sensitivity is auto-enabled when the query has uppercase (`has_uppercase`).
- `bin/autojump_utils.py` — platform detection, unicode shims (`unico`), tab-completion menu formatting (`TAB_SEPARATOR = '__'`, `TAB_ENTRIES_COUNT = 9`), and `is_autojump_sourced` which the CLI uses to refuse running outside a shell that has sourced the integration. The Swift app sets `AUTOJUMP_SOURCED=1` in the environment when invoking the CLI for Finder tracking, to bypass this check.

#### Tab completion protocol

`j foo<TAB>` invokes the CLI with `--complete`, which prints up to 9 lines formatted as `query__index__path`. The shell-side completion function parses these back. If you change `TAB_SEPARATOR` or `TAB_ENTRIES_COUNT` in `bin/autojump`, the matching constants in every shell integration script must change too.

### Swift GUI app

The app is `LSUIElement` (menu bar / accessory only). `autojump_guiApp.swift` is a near-empty SwiftUI shell delegating everything to `AppDelegate`, which owns the long-lived components:

- **`AutojumpStore`** — reads and parses `~/Library/autojump/autojump.txt` directly (the same file the CLI writes), sorts by weight, and runs queries. Search is **regex-based, not a re-implementation of the Python matcher**: it builds a "consecutive" pattern (needles separated by `[^/]*/[^/]*`, anchored to the basename) and falls back to an "anywhere" pattern (`.*` between needles). Results are filtered through `FileManager.fileExists` so stale paths are skipped. Case-sensitivity is auto-enabled when the query contains uppercase. If you change ranking semantics here, consider whether the CLI's `autojump_match.py` should match — they intentionally diverge today (the GUI prefers basename anchoring for interactive feel).
- **`LauncherPanel` / `LauncherView` / `LauncherViewModel`** — a borderless `NSPanel` floating-window launcher positioned Spotlight-style (centered, ~22% from the top). The panel resizes to fit content while keeping its top edge fixed (see `setContentSize` override). Key handling (Esc/Return/↑/↓) is via a local `NSEvent` monitor in the panel; query/typing is bound to the SwiftUI `LauncherViewModel`.
- **`HotKey`** — registers the global ⌘J hotkey via Carbon `RegisterEventHotKey`. The unmanaged `self` pointer trick is required because Carbon's C callback can't capture Swift state.
- **`FinderTracker` + `FinderAXObserver`** — populates the autojump database from Finder navigation, so users get useful results even before they install the shell integration. Two paths:
  - **Accessibility (preferred):** `FinderAXObserver` attaches to Finder's pid via `AXObserverCreate` and watches focus/window-change notifications. On change, it debounces (100 ms) and runs an AppleScript to read `POSIX path of (target of front Finder window)`.
  - **Polling fallback:** if Accessibility isn't granted, a 2 s timer polls the same AppleScript only while Finder is frontmost (gated by `NSWorkspace` activate/deactivate notifications) to avoid background CPU.
  - Either way it shells out to `python3 <bundled-autojump> --add <path>` with `AUTOJUMP_SOURCED=1`. The user toggle is persisted in `UserDefaults` under `FinderTrackingEnabled` (default on).
- **`CLIIntegration`** — copies the bundled CLI files to `~/Library/Application Support/autojump-gui/cli/` and patches the user's shell rc file with a fenced block (`# >>> autojump-gui >>>` / `# <<< autojump-gui <<<`) that prepends that directory to `PATH` and sources the appropriate hook. `Shell.detect()` reads `$SHELL`. Uninstall only strips the rc block — installed CLI files are intentionally retained so reinstalls are cheap. The bundled file list is hardcoded in `CLIIntegration.bundleFiles`; if you add a Python module to the CLI it must be added there *and* to the Xcode project's "Copy Bundle Resources" phase, or `bundleResourceMissing` will fire at install time.

### Tests

`tests/unit/` covers `autojump_match` and `autojump_utils` only. `tests/integration/` is an empty package — there are no end-to-end tests of the shell integration, and there are no Swift tests yet. When adding logic to `bin/autojump` itself, prefer extracting it into `autojump_data` / `autojump_match` / `autojump_utils` so it becomes testable; the top-level script is excluded from coverage targets.

## Conventions specific to this repo

- Python 2.6+ and 3.3+ are both supported in `bin/`. Keep `from __future__ import print_function`, the `if sys.version_info[0] == 3:` import shims, and avoid f-strings / `pathlib` / type hints.
- Lint enforces 131-column lines (not 80) and McCabe complexity ≤ 10.
- Don't edit `bin/autojump_argparse.py` (vendored) or `README.md` / `docs/autojump.1` (generated by `make docs`).
- The Swift app and the Python CLI both write/read `~/Library/autojump/autojump.txt`. The Python side serializes via atomic rename; the Swift side never writes the file directly — it always shells out to `autojump --add` so the locking and weight formula stay in one place.
- Release flow for the CLI lives in `make release` and bakes the version from `bin/autojump`'s `VERSION` constant into a git tag `release-vX.Y.Z` plus a tarball. Release flow for the GUI is `autojump-gui/scripts/release.sh` and is independent.
