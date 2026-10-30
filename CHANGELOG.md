# Changelog

All notable changes are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased] — fork moldwade/explorer-macos

### Added
- Cut & Paste shared across tabs/windows; cut items dimmed; Esc cancels the cut
- Replace / Skip / Keep both conflict dialog
- Multi-item drag, drops onto folder rows, middle-click new tab / close tab
- Favorites and Tags sections; Recycle Bin with Restore and Empty
- Finder colour tags shown next to names and editable from the context menu
- PDF tools (merge, split, rotate) and image tools (resize for email, convert, to PDF)
- Spotlight full-text search; accent- and Turkish-İ-insensitive name search
- Windows keys: Backspace/Alt+arrows/mouse buttons 4–5 navigate, F3/F4/F5, Alt+D, Ctrl+E; Delete key trashes
- View › Show › File name extensions; click-pause-click to rename
- Grouped by date: items ordered by full date and time
- ⌘K "Go to folder" palette with recent folders, favourites and Spotlight folder search
- Smart folders (recent documents, PDFs/images last 7 days, spreadsheets last 30 days)
- Turkish and Bosnian interface (Explorer → Language), with all menus, dialogs and messages translated
- Swift Testing suites for cut/paste, transfers, selection, conflicts, aliases, tools and tags

### Fixed
- Data safety: a failed source delete during a cross-volume move no longer deletes the copy; copy errors are no longer ignored; parallel copies can't overwrite each other; undo continues past failures; safer ZIP
- Dropping files into their own folder renamed them to "name - Copy"
- Clicking below the last row didn't deselect or start a drag-box; selection was slow in big folders; Shift+arrows couldn't grow upward
- New tabs flashed as a separate window first; rebuilds re-asked for folder permissions
- Undoing a move to another disk froze the window; it now runs in the background with progress

## [1.2.1] — 2026-10-07

### Fixed
- `explorermac` now finds Explorer.app itself when macOS hasn't registered it yet (e.g. right after `brew install`), instead of failing

### Added
- CI job that installs the Homebrew cask on a clean macOS runner and verifies the app, signature and command

## [1.2.0] — 2026-10-07

### Added
- **Right-click selects** the item under the cursor, like Windows
- **Drag-box (rubber-band) selection** in all views (⌘ to add)
- **Copy / move progress bar with Cancel**; large copies no longer freeze the window; recursive copy via `copyfile` keeps metadata and clones on APFS
- **Breadcrumb dropdowns**: click `>` to jump to a sibling or sub-folder
- **Network section** in the navigation pane (mounted shares, Eject, *Connect to server…*); drives/shares appear live on mount/unmount
- **App icon**
- `.dmg` disk image (drag-to-Applications) built by `make_dmg.sh`, with an *Uninstall Explorer.command* inside
- `uninstall.sh` (`--dry-run`, `--keep-settings`, `--yes`)
- Homebrew cask: `brew install --cask preslav-panayotov/tap/explorer-macos`
- GitHub Actions CI, issue / PR templates, `CONTRIBUTING.md`
- 9 new tests (33 total)

### Changed
- Copy/paste is asynchronous: files appear when the copy finishes

## [1.1.0] — 2026-10-07

### Added
- Image, video and PDF **thumbnails** in the Medium / Large / Extra large icon views (cached, aspect-ratio preserving)
- **`explorermac <dir>`** terminal command: opens a folder (or reveals a file) in a new Explorer window; fixes path letter-case; installable from the app menu; `explorermac://` URL scheme and `open -a Explorer <folder>` support
- 5 new tests (24 total)

### Fixed
- Cold-starting the app with a folder no longer leaves an extra home-folder window

## [1.0.0] — 2026-10-07

First public release.

### Added
- Windows 11 File Explorer look and feel: navigation pane, address bar with breadcrumbs, command bar, Details list, status bar, light and dark themes
- Navigation: Back / Forward / Up, editable address bar (⌘L), recursive search, folder tree for disk and volumes, pinnable Quick access
- Views: Details, List, Small / Medium / Large / Extra large icons; Group by Name / Date modified / Type / Size; sortable, resizable columns
- Details pane with thumbnail and file info; Properties dialog (size, size on disk, contents, dates, Read-only / Hidden attributes)
- Windows 11-style right-click menus for files, folders, multi-selection and empty space, plus "Show more options"
- File operations: real Cut & Paste, Copy, Paste shortcut, inline Rename, Trash, Delete permanently, drag & drop (move/copy by volume, ⌥ flips), multi-level Undo
- Compress to ZIP, Extract All (zip, tar, gz, bz2, xz, 7z, rar, iso), Create shortcut (macOS alias), Open with, Share, Send to, Copy to / Move to folder
- New menu: Folder, Shortcut, Text, Rich text, Markdown, HTML and ZIP documents
- Image actions: set as desktop background, rotate left / right
- Native macOS tabs and windows, live folder refresh, Quick Look
- Keyboard: F2 rename, ⌘X/⌘C/⌘V, arrow-key and type-to-select navigation, shift/⌘ multi-select
- Command-line options for demos: `--path --view --group --details-pane --hidden --select --light --dark`
- 19 unit tests covering navigation, file operations, undo, archives, grouping, selection and properties

### Known limitations
- No Home / Gallery pages, drag-box selection, or Tiles or Content views
- App is ad-hoc signed, not notarized (see README for first-launch instructions)
