import SwiftUI
import AppKit

struct ExplorerKey: FocusedValueKey { typealias Value = ExplorerState }
extension FocusedValues {
    var explorer: ExplorerState? {
        get { self[ExplorerKey.self] }
        set { self[ExplorerKey.self] = newValue }
    }
}

/// "Open in new tab": opens a window then attaches it to the current one as a native macOS tab.
@MainActor
enum WindowTabs {
    static var pendingParent: NSWindow?
    private static var registry: [(state: ExplorerState, window: NSWindow)] = []

    static func register(_ s: ExplorerState, _ w: NSWindow) {
        registry.removeAll { $0.window === w || !$0.window.isVisible && $0.window.contentView == nil }
        registry.append((s, w))
    }

    /// When the app is cold-started by `explorermac <dir>`, SwiftUI also opens its default home window.
    /// Close those untouched default windows once the requested folder window exists.
    static func closeUntouchedDefaults(except keep: ExplorerState) {
        let home = FileManager.default.homeDirectoryForCurrentUser.normalized
        for (s, w) in registry where s !== keep && s.back.isEmpty && s.current == home && s.selection.isEmpty {
            w.close()
        }
    }
    /// The tab under `point` (window coordinates) in the native tab bar. AppKit draws one `NSTabButton`
    /// per tab, left to right in `tabbedWindows` order.
    static func tab(at point: NSPoint, in w: NSWindow) -> NSWindow? {
        guard let tabs = w.tabbedWindows, tabs.count > 1 else { return nil }
        var buttons: [NSView] = []
        collect("NSTabButton", in: w.contentView?.superview, into: &buttons)
        let frames = buttons.map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
        guard frames.count == tabs.count, let i = frames.firstIndex(where: { $0.contains(point) }) else { return nil }
        return tabs[i]
    }

    private static func collect(_ cls: String, in v: NSView?, into out: inout [NSView]) {
        guard let v else { return }
        if String(describing: type(of: v)) == cls { out.append(v); return }
        for s in v.subviews { collect(cls, in: s, into: &out) }
    }

    static func configure(_ w: NSWindow) {
        w.tabbingIdentifier = "explorer"
        if let p = pendingParent, p !== w {
            pendingParent = nil
            // If SwiftUI already put the window on screen, keep it invisible until it is inside the tab group.
            let shown = w.isVisible
            if shown { w.alphaValue = 0 }
            p.addTabbedWindow(w, ordered: .above)
            w.makeKeyAndOrderFront(nil)
            if shown { DispatchQueue.main.async { w.alphaValue = 1 } }
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let state: ExplorerState
    func makeNSView(context: Context) -> NSView { HostView(state: state) }

    /// Configures the window the moment the view is attached to it — before it is first shown —
    /// so a new tab joins its tab group without flashing up as a separate window first.
    final class HostView: NSView {
        let state: ExplorerState
        private var done = false
        init(state: ExplorerState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let w = window else { return }
            done = true
            WindowTabs.configure(w)
            WindowTabs.register(state, w)
            state.installRightClickMonitor(for: w)
        }
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Command-line options (handy for demos/screenshots):
/// `--path <dir> --view <mode> --group <key> --details-pane --hidden --select a,b`
enum Launch {
    static let launchTime = Date()
    static func value(_ key: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var path: URL? { value("--path").map { URL(filePath: NSString(string: $0).expandingTildeInPath) } }

    @MainActor static func apply(to s: ExplorerState) {
        if let v = value("--view"), let m = ViewMode.allCases.first(where: { $0.rawValue.lowercased() == v.lowercased() }) { s.viewMode = m }
        if let g = value("--group"), let k = GroupKey.allCases.first(where: { $0.rawValue.lowercased() == g.lowercased() }) { s.group = k }
        if CommandLine.arguments.contains("--details-pane") { s.showDetailsPane = true }
        if CommandLine.arguments.contains("--hidden") { s.showHidden = true }
        if let names = value("--select")?.split(separator: ",").map(String.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                s.selection = Set(s.displayed.filter { names.contains($0.name) }.map(\.url))
            }
        }
    }
}

extension Launch {
    /// Parses `explorermac://open?path=…&select=…` or a plain `file://` URL.
    static func parse(_ url: URL) -> (dir: URL, select: String?)? {
        if url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            return isDir.boolValue ? (canonical(url), nil) : (canonical(url.deletingLastPathComponent()), url.lastPathComponent)
        }
        guard url.scheme == "explorermac",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value else { return nil }
        let dir = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return (canonical(dir), items.first(where: { $0.name == "select" })?.value)
    }

    /// Fixes letter-case typed in the terminal (`/users` → `/Users`) without resolving symlinks.
    static func canonical(_ url: URL) -> URL {
        let n = url.normalized
        if let c = (try? n.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath,
           c.lowercased() == n.path.lowercased() { return URL(filePath: c).normalized }
        return n
    }
}

@main
struct ExplorerApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        _ = Launch.launchTime
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
    }

    var body: some Scene {
        WindowGroup("Explorer", for: WindowSpec.self) { $spec in
            ContentView(start: spec.url)
        } defaultValue: {
            WindowSpec(url: Launch.path ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        .defaultSize(width: 1180, height: 740)
        .commands { ExplorerCommands() }
    }
}

@MainActor
private func textResponder() -> NSText? { NSApp.keyWindow?.firstResponder as? NSText }

struct ExplorerCommands: Commands {
    @FocusedValue(\.explorer) private var ex: ExplorerState?
    @Environment(\.openWindow) private var openWindow

    private let f2 = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
    private let f3 = KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!))
    private let f4 = KeyEquivalent(Character(UnicodeScalar(NSF4FunctionKey)!))
    private let f5 = KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!))
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Install ‘explorermac’ Command…") { CLIInstaller.install() }
            Menu("Language") {
                ForEach(AppLanguage.choices, id: \.code) { lang in
                    Toggle(isOn: Binding(get: { AppLanguage.current == lang.code }, set: { _ in AppLanguage.set(lang.code) })) {
                        if lang.code == nil { Text("System default") } else { Text(verbatim: lang.name) }
                    }
                }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(value: WindowSpec(url: ex?.current ?? home)) }.keyboardShortcut("n")
            Button("New Tab") {
                WindowTabs.pendingParent = NSApp.keyWindow
                openWindow(value: WindowSpec(url: ex?.current ?? home))
            }.keyboardShortcut("t")
            Button("New Folder") { ex?.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Properties") { if let e = ex { e.propertiesTarget = e.selection.isEmpty ? [e.current] : Array(e.selection) } }
                .keyboardShortcut(.return, modifiers: .option)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(ex?.undoLabel ?? "Undo") {
                if textResponder() != nil { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { ex?.undo() }
            }.keyboardShortcut("z")
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { if let t = textResponder() { t.cut(nil) } else { ex?.cut() } }.keyboardShortcut("x")
            Button("Copy") { if let t = textResponder() { t.copy(nil) } else { ex?.copy() } }.keyboardShortcut("c")
            Button("Paste") { if let t = textResponder() { t.paste(nil) } else { ex?.paste() } }.keyboardShortcut("v")
            Button("Select All") { if let t = textResponder() { t.selectAll(nil) } else { ex?.selectAll() } }.keyboardShortcut("a")
            Button("Invert Selection") { ex?.invertSelection() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Rename") { ex?.beginRename() }.keyboardShortcut(f2, modifiers: [])
            Button("Move to Trash") { ex?.trash() }.keyboardShortcut(.delete, modifiers: .command)
            Button("Delete Permanently…") { ex?.deletePermanently() }.keyboardShortcut(.delete, modifiers: .shift)
            // Windows keys: Delete (fn+⌫ on a Mac keyboard) moves to the Recycle Bin, Backspace goes back.
            Button("Delete") {
                if textResponder() != nil { NSApp.sendAction(#selector(NSResponder.deleteForward(_:)), to: nil, from: nil) }
                else { ex?.trash() }
            }.keyboardShortcut(.deleteForward, modifiers: [])
        }
        CommandMenu("Go") {
            Button("Back") { ex?.goBack() }.keyboardShortcut("[")
            Button("Forward") { ex?.goForward() }.keyboardShortcut("]")
            Button("Up") { ex?.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Refresh") { ex?.reload() }.keyboardShortcut("r")
            Divider()
            Button("Address Bar") { ex?.editingPath = true }.keyboardShortcut("l")
            Button("Go to Folder…") { ex?.showPalette = true }.keyboardShortcut("k")
            Button("Search") { ex?.searchFocusRequest += 1 }.keyboardShortcut("e", modifiers: .control)
            Divider()
            // Windows Explorer keys.
            Section("Windows keys") {
                Button("Back (Backspace)") {
                    if textResponder() != nil { NSApp.sendAction(#selector(NSResponder.deleteBackward(_:)), to: nil, from: nil) }
                    else { ex?.goBack() }
                }.keyboardShortcut(.delete, modifiers: [])
                Button("Back (Alt+←)") { ex?.goBack() }.keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Forward (Alt+→)") { ex?.goForward() }.keyboardShortcut(.rightArrow, modifiers: .option)
                Button("Up (Alt+↑)") { ex?.goUp() }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("Refresh (F5)") { ex?.reload() }.keyboardShortcut(f5, modifiers: [])
                Button("Address Bar (F4)") { ex?.editingPath = true }.keyboardShortcut(f4, modifiers: [])
                Button("Address Bar (Alt+D)") { ex?.editingPath = true }.keyboardShortcut("d", modifiers: .option)
                Button("Search (F3)") { ex?.searchFocusRequest += 1 }.keyboardShortcut(f3, modifiers: [])
            }
            Button("Home") { ex?.go(to: home) }.keyboardShortcut("h", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Menu("Layout") {
                ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { i, m in
                    Button(L(m.rawValue)) { ex?.viewMode = m }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
            Button("Details Pane") { ex?.showDetailsPane.toggle() }.keyboardShortcut("p", modifiers: [.option, .shift])
            Button("Hidden Items") { ex?.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
}

/// Interface language, chosen in the app menu; overrides the macOS language for Explorer only.
enum AppLanguage {
    static let choices: [(code: String?, name: String)] = [(nil, ""), ("en", "English"), ("tr", "Türkçe"), ("bs", "Bosanski")]

    static var current: String? {
        guard UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil
        else { return nil }
        return UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
    }

    @MainActor static func set(_ code: String?) {
        guard code != current else { return }
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        let a = NSAlert()
        a.messageText = String(localized: "Restart Explorer to use the new language.")
        a.addButton(withTitle: String(localized: "Restart now"))
        a.addButton(withTitle: String(localized: "Later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
