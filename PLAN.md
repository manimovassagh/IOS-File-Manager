# Plan: A Custom File Manager for macOS

> Note: the repository is called "iOS File Manager", but the goal is to replace Finder on a MacBook. The app targets **macOS only** (no iPhone/iPad version is planned).

## Main Goal
The core problem with Finder: **copy, cut and paste are awkward and frustrating**, and working with files doesn't feel smooth.
So the number one priority of this app is:
- **Real Cut**: `⌘X` on a file, then `⌘V` at the destination moves it (no hidden `⌘⌥V` trick like in Finder).
- **Simple, predictable copy/paste**: via keyboard, right-click menu, and toolbar buttons.
- **Clipboard indicator**: always see which files are copied/cut, with the option to cancel.
- **Dual pane**: drag files from one pane to the other, or move them with a single key (`F5` copy, `F6` move).
- **Clear name-conflict handling**: Replace / Keep Both / Skip — with an "apply to all" option.

---

## 1. Tech Stack

| Area | Choice | Reason |
|---|---|---|
| Language | **Swift 6** | Native Apple language, fast, full access to system APIs |
| UI | **SwiftUI + AppKit** | SwiftUI for windows, sidebar and settings; `NSTableView`/`NSOutlineView` (AppKit) for file lists, since it is much faster than SwiftUI with folders containing tens of thousands of files |
| Minimum version | **macOS 14 (Sonoma)** (adjustable to match your MacBook) | Newer SwiftUI APIs and `@Observable` |
| File system | `FileManager`, `URL resourceValues`, `FSEvents` | Metadata reading and live change detection |
| Preview | `QuickLookThumbnailing` and `QLPreviewPanel` | Thumbnails and Quick Look like Finder |
| Search | `NSMetadataQuery` (Spotlight) + direct search | Fast disk-wide search |
| Project setup | Xcode + a **Swift Package** for the Core module | Testability and separation of logic from UI |
| CI | GitHub Actions (macOS runner) | Automatic build and tests on every push |

> **Sandbox:** since this is a personal app not distributed via the App Store, App Sandbox is **disabled** so we get full access to all files. You only need to grant the app **Full Disk Access** once in System Settings → Privacy & Security.

---

## 2. Architecture

```
FileManagerApp (macOS App target)
├── UI/                 ← SwiftUI views + AppKit wrappers
│   ├── Sidebar         (Favorites, volumes, tags)
│   ├── Browser         (List / Icon / Column view)
│   ├── Toolbar & PathBar
│   ├── Inspector       (file info, preview)
│   └── Settings
└── ViewModels/         ← per-tab/window state

FileCore (Swift Package — no UI dependencies)
├── FileSystemService   (list, copy, move, rename, trash, delete)
├── DirectoryWatcher    (FSEvents)
├── FileOperationQueue  (long-running jobs with progress, cancel and undo)
├── SearchService
├── ThumbnailService    (cache)
└── Models              (FileItem, Volume, Tag, ...)
```

Principles:
- **No file operation ever runs on the main thread** (async/await + actors).
- All destructive operations support **Undo**, and "delete" defaults to moving to Trash.
- FileCore has full unit test coverage, running against temporary directories.

---

## 3. Project Phases

### Phase 0 — Setup (1–2 days)
- [x] Swift package with the macOS app target + a `FileCore` library (open `Package.swift` in Xcode)
- [x] `.gitignore`, README
- [ ] SwiftLint/SwiftFormat
- [x] GitHub Actions for build and tests
- [ ] Disable Sandbox and verify Full Disk Access

### Phase 1 — MVP: Browsing + Copy/Cut/Paste (2–3 weeks)
- [x] Window with a **sidebar** (Home, Desktop, Downloads, Documents, Applications, mounted volumes)
- [x] **List view** with Name / Size / Kind / Date Modified columns, sortable by clicking a column
- [x] Navigation: double-click, Back/Forward, enclosing folder (`⌘↑`), **path bar**
- [x] Open files with the default app (`NSWorkspace`)
- [x] Show/hide hidden files (`⌘⇧.`)
- [x] Live updates (directory watcher; switch to FSEvents later for deep changes)
- [x] **Copy / Cut / Paste** (`⌘C` / `⌘X` / `⌘V`) with real Cut — the most important feature
- [x] Clipboard indicator at the bottom of the window (what is copied/cut + a cancel button)
- [x] Cut files shown dimmed so it's clear they will be moved
- [x] Name-conflict dialog (Replace / Keep Both / Skip, with "apply to all")
- [x] Undo for paste, move and trash (`⌘Z`)

**Phase 1 deliverable:** an app you can open every day instead of Finder, where moving files around is easy.

### Phase 2 — File Operations (1–2 weeks)
- [x] New Folder, Rename (inline), Duplicate
- [x] Move to Trash (`⌘⌫`, undoable)
- [x] Delete Immediately (with confirmation)
- [x] Drag & drop within the app and with other apps
- [x] **Progress bar** (per item) with cancel
- [ ] Byte-level progress for large files, pause and resume
- [x] Redo and full undo history
- [x] Context menu (Open, Copy, Cut, Paste, Move to Trash, Copy Path, Show in Finder)
- [x] Open With, Open in Terminal

### Phase 3 — Better than Finder (2–3 weeks)
- [ ] **Dual pane mode** with `F5`/`F6` to copy/move between panes — top priority of this phase
- [ ] **Tabs**
- [ ] **Icon view**
- [x] **Column view** with a preview pane
- [x] Thumbnails for images, videos and PDFs; thumbnail rows + automatic preview in Screenshots
- [x] End-to-end UI tests with real-window screenshots in CI
- [x] **Quick Look** with Space, plus a preview (inspector) panel
- [ ] **Folder size calculation** in List view
- [x] Instant in-folder filter
- [ ] Spotlight search across the disk
- [x] Sidebar: Recents, Screenshots, Pictures, iCloud Drive; Finder-style Go menu shortcuts
- [x] App icon, themes (appearance, accent colors, row sizes) in Settings
- [ ] **Command Palette** (`⌘K`) for all commands
- [ ] **Batch rename** (patterns, numbering, regex)
- [ ] Customizable keyboard shortcuts, full keyboard navigation (optionally Vim-style)
- [ ] Embedded terminal or "Open Terminal Here"
- [ ] Free disk space shown in the status bar

### Phase 4 — Advanced Features (optional)
- [ ] Compress/extract zip and other archives
- [ ] Tags and colors (compatible with Finder tags)
- [ ] Remote connections: SFTP / SMB / S3
- [ ] Folder compare and sync
- [ ] Duplicate file finder and disk usage analysis
- [ ] Git status next to files in project folders
- [ ] Themes and Dark Mode

### Phase 5 — Stability and Distribution
- [ ] Test with large folders (100k files), profile with Instruments
- [ ] Code signing with an Apple ID (or local unsigned runs)
- [ ] Build `.app`/`.dmg` into GitHub Releases
- [ ] (Optional) Auto-updates with Sparkle
- [ ] (Optional) Act as the default handler for "Reveal in Finder" where possible

---

## 4. Prerequisites
1. A Mac with **Xcode** installed (from the App Store) — building and running a macOS app is only possible on a Mac.
2. A free Apple ID is enough for local signing; the paid Developer Program is only needed for notarization and public distribution.
3. Code is written and pushed to this repository; on the Mac you `git pull`, open it in Xcode and press `⌘R`. CI on GitHub verifies that the build stays green.

---

## 5. Open Questions
1. ~~What bothers you most about Finder?~~ ✅ Copy/cut/paste is awkward and frustrating → top priority.
2. Look and feel: Finder-like (native macOS), or Total Commander / Commander One style (keyboard-driven, dual pane)?
3. Which macOS version is your MacBook running? (determines the minimum deployment target)
4. ~~Do you want an iPhone/iPad version?~~ ✅ No, MacBook only.

Once these are answered, we start Phase 0 and Phase 1.
