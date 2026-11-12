import SwiftUI
import AppKit

/// One row of the ⌘K "Go to" palette.
struct PaletteItem: Identifiable, Hashable {
    enum Kind { case favorite, recent, place, found }
    let url: URL
    let kind: Kind
    var id: URL { url }
    var title: String { FileManager.default.displayName(atPath: url.path) }
}

extension ExplorerState {
    private static let recentKey = "recentFolders"

    /// Folders opened most recently, newest first (kept across launches for the palette).
    static var recentFolders: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).map { URL(filePath: $0) } }
        set { UserDefaults.standard.set(newValue.prefix(30).map(\.path), forKey: recentKey) }
    }

    static func noteRecent(_ url: URL) {
        let u = url.normalized
        guard u.path != "/" else { return }
        recentFolders = [u] + recentFolders.filter { $0 != u }
    }

    /// Instant matches: favourites, recent folders and the standard places.
    func paletteMatches(_ q: String) -> [PaletteItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let places = ["Desktop", "Downloads", "Documents", "Pictures", "Movies", "Music"].map { home.appending(path: $0).normalized }
            + [home.normalized] + pinned
        var seen = Set<URL>()
        let all = favorites.map { PaletteItem(url: $0, kind: .favorite) }
            + Self.recentFolders.map { PaletteItem(url: $0, kind: .recent) }
            + places.map { PaletteItem(url: $0, kind: .place) }
        return all.filter { item in
            guard FileManager.default.fileExists(atPath: item.url.path), seen.insert(item.url).inserted else { return false }
            return q.isEmpty || Self.nameMatches(item.title, q) || Self.nameMatches(item.url.path, q)
        }
    }

    /// Folders anywhere in the home folder whose name contains `q`, via Spotlight.
    nonisolated static func findFolders(_ q: String) -> [URL] {
        guard q.count >= 2 else { return [] }
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return mdfind(["kMDItemContentType == \"public.folder\" && kMDItemFSName == \"*\(escaped)*\"cd"], onlyIn: home)
            .filter { !$0.url.path.hasPrefix(home + "/Library/") }
            .prefix(40).map(\.url)
    }
}

/// ⌘K: type part of a folder name (customer, supplier, project) and jump there.
/// ↑/↓ choose, Return opens, ⌘Return opens in a new tab, Esc closes.
struct CommandPalette: View {
    let state: ExplorerState
    @ViewState private var query = ""
    @ViewState private var found: (query: String, urls: [URL]) = ("", [])
    @ViewState private var index = 0
    @FocusState private var focused: Bool

    private var rows: [PaletteItem] {
        var seen = Set<URL>()
        // Spotlight results only for the text currently in the box, never a previous one.
        let spotlight = found.query == query ? found.urls : []
        return (state.paletteMatches(query) + spotlight.map { PaletteItem(url: $0, kind: .found) })
            .filter { seen.insert($0.url).inserted }
            .prefix(60).map { $0 }
    }

    var body: some View {
        let list = rows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to folder…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { open(list, newTab: NSEvent.modifierFlags.contains(.command)) }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onExitCommand { state.showPalette = false }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == index)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { index = i; open(list, newTab: NSEvent.modifierFlags.contains(.command)) }
                        }
                        if list.isEmpty {
                            Text(query.count < 2 ? "Type a folder name" : "No folders found")
                                .foregroundStyle(.secondary).padding(20)
                        }
                    }
                }
                .onChange(of: index) { proxy.scrollTo(index) }
            }
            .frame(height: 340)
            Divider()
            Text("↑↓ choose · ↩ open · ⌘↩ new tab · esc close")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: query) {
            index = 0
            let q = query
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard q == query else { return }
                let urls = await Task.detached { ExplorerState.findFolders(q) }.value
                if q == query { found = (q, urls) }
            }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            switch item.kind {
            case .favorite: Image(systemName: "star.fill").foregroundStyle(.yellow)
            case .recent: Image(systemName: "clock").foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selected ? Theme.selection : .clear)
    }

    private func open(_ list: [PaletteItem], newTab: Bool) {
        guard list.indices.contains(index) else { return }
        let u = list[index].url
        state.showPalette = false
        if newTab, let tab = state.openInNewTab { tab(u) } else { state.go(to: u) }
    }
}
