# CLAUDE.md

## Language
- The user writes to Claude in Persian (Farsi) because it is easier for them.
- Everything Claude produces must be in **English**: chat replies, code, comments, commit messages, docs, PR descriptions, and any file in this repository.
- Never write Persian text anywhere.

## Project
A personal file manager for **macOS only** (replacement for Finder). See `PLAN.md` for the roadmap.
Top priority: easy, reliable copy / cut / paste of files.

## Build & test
- Swift package: `FileCore` (logic, no UI) + `FileManagerApp` (SwiftUI + AppKit executable).
- `swift build`, `swift test`, `./scripts/build-app.sh` — macOS only.
- Cloud sessions have no Swift toolchain; verify changes through the GitHub Actions CI (`.github/workflows/ci.yml`, macOS runners).
- The app must build with the **Command Line Tools only** (no Xcode). Don't use SwiftUI macros —
  `@State`, `@Entry`, `@Previewable`, `#Preview` — their plugin ships only with Xcode. Use
  `ObservableObject` + `@StateObject` / `@Published` instead. CI has a job that checks this.

## End-to-end testing (required for every feature)
- `Tests/FileManagerAppTests` puts the app's real views in a window on a folder of test files,
  waits for them to load and checks what is on screen (rows, columns, preview, thumbnails).
  Add or extend a test there for every user-visible feature or fix.
- Tests call `snapshot("name")`, which saves the real window pixels (`screencapture`). CI uploads
  them as artifacts and, from the `macos-26` job on pushes, force-pushes them to the
  `ci-snapshots` branch. Look at them before calling a UI change done:
  `git fetch origin ci-snapshots && git archive origin/ci-snapshots | tar -x -C <dir>`.
- Check visibility in window coordinates (see `assertFirstRowVisible`), not just inside a view.
