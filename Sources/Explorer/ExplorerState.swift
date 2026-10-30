import AppKit
import Observation

enum ViewMode: String, CaseIterable, Identifiable {
    case extraLarge = "Extra large icons", large = "Large icons", medium = "Medium icons"
    case small = "Small icons", list = "List", details = "Details"
    var id: String { rawValue }
    var iconSize: CGFloat {
        switch self { case .extraLarge: 96; case .large: 64; case .medium: 40; default: 16 }
    }
    var systemImage: String {
        switch self {
        case .extraLarge, .large: "square.grid.2x2"
        case .medium, .small: "square.grid.3x3"
        case .list: "list.bullet"
        case .details: "list.bullet.below.rectangle"
        }
    }
}

enum GroupKey: String, CaseIterable, Identifiable {
    case none = "(None)", name = "Name", modified = "Date modified", kind = "Type", size = "Size"
    var id: String { rawValue }
}

enum NewKind: String, CaseIterable {
    case folder = "Folder", text = "Text Document", rtf = "Rich Text Document"
    case markdown = "Markdown Document", html = "HTML Document", zip = "Compressed (zipped) Folder"
}

enum UndoOp {
    case rename(from: URL, to: URL)
    case move([(from: URL, to: URL)])
    case create([URL])
    case trash([(orig: URL, trashed: URL)])
    var label: String {
        switch self {
        case .rename: "Rename"
        case .move: "Move"
        case .create: "Copy"
        case .trash: "Delete"
        }
    }
}

/// One clipboard for the whole app, so Cut in one tab or window and Paste in another still moves.
@MainActor @Observable
final class SharedClipboard {
    static let shared = SharedClipboard()
    var urls: [URL] = []
    var isCut = false
    var changeCount = -1
}

@MainActor @Observable
final class ExplorerState {
    var current: URL
    var items: [FileItem] = [] { didSet { listVersion &+= 1 } }
    var selection: Set<URL> = []
    var sortOrder: [KeyPathComparator<FileItem>] = [ExplorerState.nameSort]
    var showHidden = false
    var viewMode: ViewMode = .details
    var searchText = ""
    var searchResults: [FileItem] = [] { didSet { listVersion &+= 1 } }
    /// Bumped whenever `items` or `searchResults` change; part of the sorted-list cache key.
    private var listVersion = 0
    var isSearching = false
    var back: [URL] = []
    var forward: [URL] = []
    var editingPath = false
    var pathText = ""
    var renameTarget: URL?
    var renameText = ""
    var errorMessage: String?
    var quickLook: URL?
    var clipboard: [URL] {
        get { SharedClipboard.shared.urls }
        set { SharedClipboard.shared.urls = newValue }
    }
    var clipboardIsCut: Bool {
        get { SharedClipboard.shared.isCut }
        set { SharedClipboard.shared.isCut = newValue }
    }
    var group: GroupKey = .none
    var showDetailsPane = false
    var propertiesTarget: [URL]?
    var pinned: [URL] = (UserDefaults.standard.stringArray(forKey: "pinned") ?? []).map { URL(filePath: $0) }
    var undoStack: [UndoOp] = []
    var nameW: CGFloat = 320
    var dateW: CGFloat = 160
    var kindW: CGFloat = 140
    var sizeW: CGFloat = 90
    var anchor: URL?
    /// The moving end of the selection (keyboard focus); the list scrolls to keep it visible.
    var cursor: URL?
    var transferJob: TransferJob?
    var marquee: CGRect?
    var volumesVersion = 0
    @ObservationIgnored var hoverURL: URL?
    /// Opens a folder in a new tab of this window; set by the view, which owns `openWindow`.
    @ObservationIgnored var openInNewTab: ((URL) -> Void)?
    @ObservationIgnored var rowFrames: [URL: CGRect] = [:]
    @ObservationIgnored private var marqueeBase: Set<URL>?
    @ObservationIgnored private var rightClickMonitor: Any?
    @ObservationIgnored private var mountObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var typeBuffer = ""
    @ObservationIgnored private var typeTime = Date.distantPast

    private var clipboardChange: Int {
        get { SharedClipboard.shared.changeCount }
        set { SharedClipboard.shared.changeCount = newValue }
    }
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    static let nameSort = KeyPathComparator(\FileItem.name, comparator: .localizedStandard)

    init(start: URL = FileManager.default.homeDirectoryForCurrentUser) {
        current = start.normalized
        reload()
        watch()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesVersion += 1 }
            })
        }
    }

    deinit {
        if let m = rightClickMonitor { NSEvent.removeMonitor(m) }
        mountObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: Derived

    private struct ListKey: Equatable {
        let version: Int, searching: Bool, hidden: Bool, sort: [KeyPathComparator<FileItem>], group: GroupKey
    }
    private struct ListCache {
        let key: ListKey
        let groups: [(title: String, items: [FileItem])]
        let displayed: [FileItem]
        let index: [URL: Int]
    }
    @ObservationIgnored private var listCache: ListCache?

    /// Sorting thousands of names is slow, and selection code asks for the list on every click and
    /// key press, so the sorted/grouped result is kept until one of its inputs changes.
    private var list: ListCache {
        // Reading the inputs here also registers them for observation on a cache hit.
        let key = ListKey(version: listVersion, searching: !searchText.isEmpty, hidden: showHidden,
                          sort: sortOrder, group: group)
        if let c = listCache, c.key == key { return c }
        let groups = makeGroups(sortedVisible)
        let displayed = group == .none ? groups.first?.items ?? [] : groups.flatMap(\.items)
        let c = ListCache(key: key, groups: groups, displayed: displayed,
                          index: Dictionary(displayed.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { a, _ in a }))
        listCache = c
        return c
    }

    private var sortedVisible: [FileItem] {
        let base = searchText.isEmpty ? items : searchResults
        let visible = showHidden ? base : base.filter { !$0.isHidden }
        let sorted = visible.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var groups: [(title: String, items: [FileItem])] { list.groups }

    private func makeGroups(_ list: [FileItem]) -> [(title: String, items: [FileItem])] {
        guard group != .none else { return [("", list)] }
        var buckets: [String: [FileItem]] = [:]
        var rank: [String: Int] = [:]
        for i in list {
            let (t, r) = groupInfo(i)
            buckets[t, default: []].append(i)
            rank[t] = r
        }
        return buckets.keys.sorted { (rank[$0]!, $0) < (rank[$1]!, $1) }.map { ($0, buckets[$0]!) }
    }

    private func groupInfo(_ i: FileItem) -> (String, Int) {
        switch group {
        case .none: return ("", 0)
        case .name:
            let c = i.name.first.map { String($0).uppercased() } ?? "#"
            return (c.first!.isLetter ? c : "0-9 & symbols", c.first!.isLetter ? 1 : 0)
        case .kind: return (i.kind, 0)
        case .modified:
            let cal = Calendar.current, now = Date()
            if cal.isDateInToday(i.modified) { return ("Today", 0) }
            if cal.isDateInYesterday(i.modified) { return ("Yesterday", 1) }
            if cal.isDate(i.modified, equalTo: now, toGranularity: .weekOfYear) { return ("Earlier this week", 2) }
            if let w = cal.date(byAdding: .weekOfYear, value: -1, to: now), cal.isDate(i.modified, equalTo: w, toGranularity: .weekOfYear) { return ("Last week", 3) }
            if cal.isDate(i.modified, equalTo: now, toGranularity: .month) { return ("Earlier this month", 4) }
            if let m = cal.date(byAdding: .month, value: -1, to: now), cal.isDate(i.modified, equalTo: m, toGranularity: .month) { return ("Last month", 5) }
            if cal.isDate(i.modified, equalTo: now, toGranularity: .year) { return ("Earlier this year", 6) }
            return ("A long time ago", 7)
        case .size:
            if i.isFolder { return ("Unspecified", 0) }
            let kb: Int64 = 1024, mb = kb * 1024, gb = mb * 1024
            switch i.size {
            case 0: return ("Empty", 1)
            case ..<(16 * kb): return ("Tiny (0 – 16 KB)", 2)
            case ..<mb: return ("Small (16 KB – 1 MB)", 3)
            case ..<(128 * mb): return ("Medium (1 – 128 MB)", 4)
            case ..<gb: return ("Large (128 MB – 1 GB)", 5)
            case ..<(4 * gb): return ("Huge (1 – 4 GB)", 6)
            default: return ("Gigantic (> 4 GB)", 7)
            }
        }
    }

    var displayed: [FileItem] { list.displayed }
    func displayIndex(of url: URL) -> Int? { list.index[url] }

    // MARK: Selection

    func click(_ item: FileItem, shift: Bool, toggle: Bool) {
        let list = displayed
        if shift, let a = anchor, let i0 = displayIndex(of: a), let i1 = displayIndex(of: item.url) {
            let r = list[min(i0, i1)...max(i0, i1)].map(\.url)
            selection = toggle ? selection.union(r) : Set(r)
        } else if toggle {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
            anchor = item.url
        } else {
            selection = [item.url]
            anchor = item.url
        }
        cursor = item.url
    }

    /// Arrow keys: move from the moving end of the selection; with Shift, grow or shrink the range
    /// from the anchor (Windows behaviour).
    func moveSelection(_ delta: Int, extend: Bool) {
        let list = displayed
        guard !list.isEmpty else { return }
        let from = cursor.flatMap { selection.contains($0) ? displayIndex(of: $0) : nil }
            ?? list.lastIndex { selection.contains($0.url) }
        let idx = from.map { max(0, min(list.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : list.count - 1)
        click(list[idx], shift: extend, toggle: false)
    }

    func selectAll() { selection = Set(displayed.map(\.url)) }
    func selectNone() { selection = [] }
    func invertSelection() { selection = Set(displayed.map(\.url)).subtracting(selection) }

    func typeSelect(_ chars: String) {
        if Date().timeIntervalSince(typeTime) > 1 { typeBuffer = "" }
        typeTime = Date()
        typeBuffer += chars.lowercased()
        if let m = displayed.first(where: { $0.name.lowercased().hasPrefix(typeBuffer) }) {
            selection = [m.url]; anchor = m.url; cursor = m.url
        }
    }

    // MARK: Undo / pins

    func record(_ op: UndoOp) { undoStack.append(op); if undoStack.count > 50 { undoStack.removeFirst() } }
    var undoLabel: String? { undoStack.last.map { "Undo \($0.label)" } }

    /// Undoes as much of the last operation as it can; whatever fails stays on the stack to retry.
    func undo() {
        guard let op = undoStack.popLast() else { return }
        let fm = FileManager.default
        var firstError: Error?
        func attempt(_ body: () throws -> Void) -> Bool {
            do { try body(); return true } catch { if firstError == nil { firstError = error }; return false }
        }
        switch op {
        case .rename(let f, let t):
            if !attempt({ try fm.moveItem(at: t, to: f) }) { undoStack.append(op) }
        case .move(let pairs):
            let left = pairs.filter { p in !attempt { try fm.moveItem(at: p.to, to: p.from) } }
            if !left.isEmpty { undoStack.append(.move(left)) }
        case .create(let urls):
            let left = urls.filter { u in !attempt { try fm.trashItem(at: u, resultingItemURL: nil) } }
            if !left.isEmpty { undoStack.append(.create(left)) }
        case .trash(let pairs):
            let left = pairs.filter { p in !attempt { try fm.moveItem(at: p.trashed, to: p.orig) } }
            if !left.isEmpty { undoStack.append(.trash(left)) }
        }
        if let firstError { errorMessage = firstError.localizedDescription }
        reload()
    }

    func isPinned(_ u: URL) -> Bool { pinned.contains(u.normalized) }
    func togglePin(_ u: URL) {
        let n = u.normalized
        if let i = pinned.firstIndex(of: n) { pinned.remove(at: i) } else { pinned.append(n) }
        UserDefaults.standard.set(pinned.map(\.path), forKey: "pinned")
    }

    var selectedItems: [FileItem] {
        selection.compactMap { displayIndex(of: $0) }.sorted().map { displayed[$0] }
    }
    var title: String { FileManager.default.displayName(atPath: current.path) }
    var canGoUp: Bool { current.path != "/" }
    var hasClipboard: Bool { !clipboard.isEmpty || !pasteboardURLs().isEmpty }

    var breadcrumbs: [(title: String, url: URL)] {
        var result: [(String, URL)] = [(FileManager.default.displayName(atPath: "/"), URL(filePath: "/"))]
        var u = URL(filePath: "/")
        for c in current.pathComponents.dropFirst() {
            u = u.appending(path: c, directoryHint: .notDirectory)
            result.append((c, u))
        }
        return result
    }

    // MARK: Navigation

    func go(to url: URL, push: Bool = true) {
        let target = url.normalized
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            if FileManager.default.fileExists(atPath: target.path) { NSWorkspace.shared.open(target) }
            else { errorMessage = "Can't find “\(target.path)”." }
            return
        }
        if target != current {
            if push { back.append(current); forward.removeAll() }
            current = target
        }
        searchText = ""
        searchResults = []
        selection = []
        rowFrames.removeAll()
        editingPath = false
        reload()
        watch()
    }

    func goBack() {
        guard let u = back.popLast() else { return }
        forward.append(current)
        go(to: u, push: false)
    }

    func goForward() {
        guard let u = forward.popLast() else { return }
        back.append(current)
        go(to: u, push: false)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = current
        go(to: current.deletingLastPathComponent())
        selection = [child.normalized]
        anchor = child.normalized; cursor = child.normalized
    }

    func goToPath(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { editingPath = false; return }
        go(to: URL(filePath: NSString(string: t).expandingTildeInPath))
        editingPath = false
    }

    func open(_ urls: Set<URL>) {
        for u in urls {
            if let item = items.first(where: { $0.url == u }) ?? FileItem(url: u) {
                item.isFolder ? go(to: u) : { NSWorkspace.shared.open(u) }()
            }
        }
    }

    // MARK: Loading

    func reload() {
        let dir = current
        loadToken += 1
        let token = loadToken
        Task.detached {
            let result = Result { try FileItem.list(dir) }
            await MainActor.run {
                guard token == self.loadToken else { return }
                switch result {
                case .success(let list):
                    self.items = list
                    // Keep selected search results too: they live outside the current folder.
                    let present = Set(list.map(\.url)).union(self.searchResults.map(\.url))
                    self.selection = self.selection.filter(present.contains)
                case .failure(let e):
                    self.items = []
                    self.errorMessage = e.localizedDescription
                }
            }
        }
        if !searchText.isEmpty { search() }
    }

    private func watch() {
        source?.cancel()
        source = nil
        let fd = Darwin.open(current.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    // MARK: Search (recursive, like Explorer)

    func search() {
        searchTask?.cancel()
        let q = searchText
        guard !q.isEmpty else { searchResults = []; isSearching = false; return }
        let root = current
        let hidden = showHidden
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let found = await Task.detached { Self.scan(root, matching: q, hidden: hidden) }.value
            if Task.isCancelled { return }
            self?.searchResults = found
            self?.isSearching = false
        }
    }

    nonisolated static func scan(_ root: URL, matching q: String, hidden: Bool) -> [FileItem] {
        var out: [FileItem] = []
        let opts: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileItem.keys, options: opts) else { return [] }
        for case let u as URL in en {
            if Task.isCancelled || out.count >= 5000 { break }
            if u.lastPathComponent.localizedCaseInsensitiveContains(q), let i = FileItem(url: u) { out.append(i) }
        }
        return out
    }

    // MARK: Clipboard

    private func pasteboardURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func stash(_ urls: Set<URL>, cut: Bool) {
        guard !urls.isEmpty else { return }
        clipboard = Array(urls)
        clipboardIsCut = cut
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(clipboard as [NSURL])
        clipboardChange = pb.changeCount
    }

    func copy(_ urls: Set<URL>? = nil) { stash(urls ?? selection, cut: false) }
    func cut(_ urls: Set<URL>? = nil) { stash(urls ?? selection, cut: true) }

    /// True while `url` is marked by Cut and still waiting to be pasted (drawn dimmed, like Windows).
    func isCutPending(_ url: URL) -> Bool {
        clipboardIsCut && NSPasteboard.general.changeCount == clipboardChange && clipboard.contains(url)
    }

    /// Esc drops a pending Cut, as in Windows: the items stay on the clipboard, but Paste now copies.
    func cancelCut() { clipboardIsCut = false }

    func paste() {
        let pb = NSPasteboard.general
        let internal_ = pb.changeCount == clipboardChange
        let sources = internal_ ? clipboard : pasteboardURLs()
        let move = internal_ && clipboardIsCut
        transfer(sources, into: current, move: move)
        if move { clipboard = []; clipboardIsCut = false }
    }

    func copyPaths(_ urls: Set<URL>? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString((urls ?? selection).map(\.path).sorted().joined(separator: "\n"), forType: .string)
    }

    // MARK: File operations

    static func uniqueURL(in dir: URL, name: String, suffix: String = " - Copy") -> URL {
        let fm = FileManager.default
        var candidate = dir.appending(path: name, directoryHint: .notDirectory)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 1
        repeat {
            let tag = n == 1 ? suffix : "\(suffix) (\(n))"
            candidate = dir.appending(path: ext.isEmpty ? base + tag : "\(base)\(tag).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let id = { (u: URL) in (try? u.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
        return id(a) != nil && id(a) == id(b)
    }

    /// Copies or moves `sources` into `dir`. Same-volume moves are instant; everything else runs in the
    /// background with a progress bar and Cancel. Returns the planned destination URLs.
    @discardableResult
    func transfer(_ sources: [URL], into dir: URL, move: Bool) -> [URL] {
        var plan: [(src: URL, dest: URL)] = []
        var taken = Self.inFlight
        for src in sources {
            // Compare normalized paths: a dropped URL's parent ends in "/" and wouldn't equal `dir`, which
            // turned "move into the folder it is already in" into a rename to "name - Copy".
            if move && src.deletingLastPathComponent().normalized == dir.normalized { continue }
            if dir.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path + "/") || dir.standardizedFileURL == src.standardizedFileURL {
                errorMessage = "Can't put “\(src.lastPathComponent)” inside itself."
                continue
            }
            var dest = Self.uniqueURL(in: dir, name: src.lastPathComponent)
            var n = 2
            while taken.contains(dest.path) {
                dest = Self.uniqueURL(in: dir, name: "\(n) " + src.lastPathComponent, suffix: " - Copy"); n += 1
            }
            taken.insert(dest.path)
            plan.append((src, dest))
        }
        guard !plan.isEmpty else { return [] }

        if move && plan.allSatisfy({ sameVolume($0.src, dir) }) {
            var pairs: [(from: URL, to: URL)] = []
            for p in plan {
                do { try FileManager.default.moveItem(at: p.src, to: p.dest); pairs.append((p.src.normalized, p.dest.normalized)) }
                catch { errorMessage = error.localizedDescription }
            }
            finishTransfer(done: pairs, move: true, dir: dir)
        } else {
            runTransfer(plan, move: move, dir: dir)
        }
        return plan.map { $0.dest.normalized }
    }

    /// Destinations of copies still running in any window, so a second paste can't pick the same name.
    static var inFlight = Set<String>()

    private func runTransfer(_ plan: [(src: URL, dest: URL)], move: Bool, dir: URL) {
        let job = TransferJob(title: move ? "Moving" : "Copying", count: plan.count)
        transferJob = job
        Self.inFlight.formUnion(plan.map(\.dest.path))
        let counter = job.counter
        Task.detached { [plan] in
            counter.setTotal(TransferEngine.totalBytes(plan.map(\.src)))
            var done: [(from: URL, to: URL)] = []
            var failure: String?
            for p in plan {
                if counter.isCancelled { break }
                counter.beginItem(p.src.lastPathComponent)
                // Never touch something that is already at the destination: it isn't ours to remove.
                if FileManager.default.fileExists(atPath: p.dest.path) {
                    failure = "“\(p.dest.lastPathComponent)” already exists."
                    break
                }
                do {
                    try TransferEngine.copy(p.src, to: p.dest, counter: counter)
                } catch {
                    try? FileManager.default.removeItem(at: p.dest)  // only the incomplete copy we made
                    if !counter.isCancelled { failure = error.localizedDescription }
                    break
                }
                if move {
                    // The copy is complete; from here on it is the only safe version, so keep it whatever happens.
                    do { try FileManager.default.removeItem(at: p.src) } catch {
                        failure = "Copied “\(p.src.lastPathComponent)”, but couldn't remove the original: \(error.localizedDescription)"
                        break
                    }
                }
                done.append((p.src.normalized, p.dest.normalized))
            }
            let finalDone = done, finalFailure = failure
            await MainActor.run {
                Self.inFlight.subtract(plan.map(\.dest.path))
                if let finalFailure { self.errorMessage = finalFailure }
                self.finishTransfer(done: finalDone, move: move, dir: dir)
                if self.transferJob === job { self.transferJob = nil }
            }
        }
        Task { @MainActor [weak self, weak job] in
            while let self, let job, self.transferJob === job {
                let s = job.counter.snapshot
                job.fraction = s.fraction
                job.currentName = s.name
                job.visible = Date().timeIntervalSince(job.started) > 0.35
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finishTransfer(done: [(from: URL, to: URL)], move: Bool, dir: URL) {
        if !done.isEmpty { record(move ? .move(done) : .create(done.map(\.to))) }
        reload()
        if dir.normalized == current, !done.isEmpty { selection = Set(done.map(\.to)) }
    }

    /// Drag & drop: same volume moves, different volume copies; ⌥ flips.
    func drop(_ urls: [URL], into dir: URL) {
        let same = urls.first.map { sameVolume($0, dir) } ?? false
        let flip = NSEvent.modifierFlags.contains(.option)
        transfer(urls, into: dir, move: same != flip)
    }

    // MARK: Context-menu selection, marquee, hover

    func noteHover(_ url: URL, _ hovering: Bool) {
        if hovering { hoverURL = url } else if hoverURL == url { hoverURL = nil }
    }

    /// Windows selects the item you right-click (unless it is already part of the selection).
    func prepareContextMenu(for url: URL?) {
        guard let url, !selection.contains(url) else { return }
        selection = [url]
        anchor = url
    }

    func installRightClickMonitor(for window: NSWindow) {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .otherMouseDown]) { [weak self, weak window] e in
            guard let window, e.window === window else { return e }
            if e.type == .otherMouseDown {
                guard e.buttonNumber == 2 else { return e }
                let handled = MainActor.assumeIsolated { self?.middleClick(e, in: window) ?? false }
                return handled ? nil : e
            }
            guard e.type == .rightMouseDown || e.modifierFlags.contains(.control) else { return e }
            MainActor.assumeIsolated { self?.prepareContextMenu(for: self?.hoverURL) }
            return e
        }
    }

    /// Middle click, as in Windows: on a tab closes it, on a folder opens it in a new tab.
    private func middleClick(_ e: NSEvent, in window: NSWindow) -> Bool {
        if let tab = WindowTabs.tab(at: e.locationInWindow, in: window) {
            tab.performClose(nil)
            return true
        }
        if let u = hoverURL, let item = item(for: u), item.isFolder, let open = openInNewTab {
            open(u)
            return true
        }
        return false
    }

    /// Drag-box (rubber-band) selection; `rect` is in the scroll content's coordinate space.
    func updateMarquee(_ rect: CGRect, additive: Bool) {
        if marquee == nil { marqueeBase = additive ? selection : [] }
        marquee = rect
        let hit = rowFrames.filter { $0.value.intersects(rect) && displayIndex(of: $0.key) != nil }.map(\.key)
        selection = (marqueeBase ?? []).union(hit)
        if let last = hit.first { anchor = last }
    }

    func endMarquee() { marquee = nil; marqueeBase = nil }

    @discardableResult
    func newFolder() -> URL? {
        let url = Self.uniqueURL(in: current, name: "New folder", suffix: "")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            record(.create([url.normalized]))
            reload()
            selection = [url.normalized]
            beginRename(url.normalized)
            return url.normalized
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func beginRename(_ url: URL? = nil) {
        guard let u = url ?? (selection.count == 1 ? selection.first : nil) else { return }
        renameTarget = u
        renameText = u.lastPathComponent
    }

    @discardableResult
    func commitRename() -> URL? {
        defer { renameTarget = nil }
        guard let old = renameTarget else { return nil }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old.lastPathComponent else { return nil }
        guard !name.contains("/") else { errorMessage = "A name can't contain “/”."; return nil }
        let new = old.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory).normalized
        guard !FileManager.default.fileExists(atPath: new.path) else {
            errorMessage = "“\(name)” already exists."; return nil
        }
        do {
            try FileManager.default.moveItem(at: old, to: new)
            record(.rename(from: old, to: new))
            reload()
            selection = [new]
            return new
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func trash(_ urls: Set<URL>? = nil) {
        var rec: [(orig: URL, trashed: URL)] = []
        for u in urls ?? selection {
            var out: NSURL?
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                if let r = out as URL? { rec.append((u.normalized, r.normalized)) }
            } catch { errorMessage = error.localizedDescription }
        }
        if !rec.isEmpty { record(.trash(rec)) }
        selection = []
        reload()
    }

    func deletePermanently(_ urls: Set<URL>? = nil) {
        let targets = urls ?? selection
        guard !targets.isEmpty else { return }
        let a = NSAlert()
        a.messageText = targets.count == 1 ? "Delete “\(targets.first!.lastPathComponent)” permanently?" : "Delete these \(targets.count) items permanently?"
        a.informativeText = "This can't be undone."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for u in targets { do { try FileManager.default.removeItem(at: u) } catch { errorMessage = error.localizedDescription } }
        selection = []
        reload()
    }

    func reveal(_ urls: Set<URL>? = nil) {
        let u = Array(urls ?? selection)
        NSWorkspace.shared.activateFileViewerSelecting(u.isEmpty ? [current] : u)
    }

    var sortKey: PartialKeyPath<FileItem>? { sortOrder.first?.keyPath }
    var sortAscending: Bool { sortOrder.first?.order != .reverse }

    func setSort(_ key: PartialKeyPath<FileItem>) {
        applySort(key, ascending: sortKey == key ? !sortAscending : true)
    }

    func applySort(_ key: PartialKeyPath<FileItem>, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case \FileItem.name: sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)]
        case \FileItem.modified: sortOrder = [KeyPathComparator(\FileItem.modified, order: order)]
        case \FileItem.kind: sortOrder = [KeyPathComparator(\FileItem.kind, order: order)]
        default: sortOrder = [KeyPathComparator(\FileItem.sizeKey, order: order)]
        }
    }

    func item(for u: URL) -> FileItem? { items.first { $0.url == u } ?? searchResults.first { $0.url == u } ?? FileItem(url: u) }
}
