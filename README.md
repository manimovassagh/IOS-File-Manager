# File Manager for macOS

A personal Finder replacement focused on making **copy, cut and paste** of files easy.
See [PLAN.md](PLAN.md) for the roadmap.

## Features (Phase 1)
- Sidebar with Favorites and mounted volumes
- Fast list view (Name, Date Modified, Size, Kind), sortable by column, folders first
- Back / Forward / Enclosing Folder, clickable path bar, live folder updates
- **Copy / Cut / Paste** with `⌘C` / `⌘X` / `⌘V`, toolbar buttons or right-click
  - Real cut: `⌘X` then `⌘V` moves files
  - Clipboard bar shows what's on the clipboard, with **Paste Here** and a cancel button
  - Cut items are shown dimmed until pasted
  - Name conflicts: Replace / Keep Both / Skip / Stop, with "Apply to all"
  - Works with Finder: copy in Finder and paste here, or the other way around
- Move to Trash (`⌘⌫`), Copy Path, Show in Finder
- Undo (`⌘Z`) for paste, move and trash
- Show/hide hidden files (`⇧⌘.`)

## Keyboard shortcuts
| Action | Shortcut |
|---|---|
| Open | `Return` or `⌘↓` / double-click |
| Enclosing folder | `⌘↑` |
| Back / Forward | `⌘[` / `⌘]` |
| Copy / Cut / Paste | `⌘C` / `⌘X` / `⌘V` |
| Move to Trash | `⌘⌫` |
| Undo | `⌘Z` |
| Show hidden files | `⇧⌘.` |

## Requirements
- macOS 14 (Sonoma) or later
- Xcode 16 or later (or the Swift 6 command line tools)

## Run
**From Xcode:** open `Package.swift` in Xcode, choose the `FileManagerApp` scheme, press `⌘R`.

**From Terminal:**
```sh
swift run FileManagerApp
```

**Build a real app** (`build/File Manager.app`), optionally installing it to `/Applications`:
```sh
./scripts/build-app.sh            # build only
./scripts/build-app.sh --install  # build and copy to /Applications
```

**Download from CI:** every push builds the app on GitHub Actions. Open the latest run under
*Actions*, download the `File-Manager-app` artifact, and unzip it. Because the app is not
notarized, remove the quarantine flag once before opening it:
```sh
xattr -cr "File Manager.app"
```

### Full Disk Access
To browse protected folders, grant access in **System Settings → Privacy & Security →
Full Disk Access** (add `File Manager.app`, or your Terminal/Xcode when using `swift run`).

## Project layout
```
Sources/FileCore/        File system logic (listing, sorting, copy/move/trash, undo) — no UI
Sources/FileManagerApp/  The macOS app (SwiftUI + AppKit)
Tests/FileCoreTests/     Unit tests for FileCore
scripts/build-app.sh     Builds the .app bundle
```

## Tests
```sh
swift test
```
