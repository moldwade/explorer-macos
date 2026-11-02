import AppKit
import NetFS
import UniformTypeIdentifiers

extension ExplorerState {
    // MARK: New

    func newItem(_ kind: NewKind) {
        if kind == .folder { newFolder(); return }
        let (base, ext, data): (String, String, Data) = switch kind {
        case .text: ("New Text Document", "txt", Data())
        case .rtf: ("New Rich Text Document", "rtf", Data("{\\rtf1\\ansi }".utf8))
        case .markdown: ("New Markdown Document", "md", Data())
        case .html: ("New HTML Document", "html", Data("<!DOCTYPE html>\n<html><body></body></html>\n".utf8))
        default: ("New Compressed (zipped) Folder", "zip",
                  Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)))
        }
        let url = Self.uniqueURL(in: current, name: "\(base).\(ext)", suffix: " (1)").normalized
        do {
            try data.write(to: url)
            record(.create([url]))
            reload()
            selection = [url]
            beginRename(url)
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Shortcuts (macOS aliases)

    @discardableResult
    func makeShortcut(to target: URL, in dir: URL) -> URL? {
        let dest = Self.uniqueURL(in: dir, name: target.lastPathComponent + " - Shortcut", suffix: " (1)")
        do {
            let data = try target.bookmarkData(options: .suitableForBookmarkFile)
            try URL.writeBookmarkData(data, to: dest)
            return dest.normalized
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func createShortcuts(_ urls: Set<URL>? = nil) {
        let made = (urls ?? selection).compactMap { makeShortcut(to: $0, in: current) }
        if !made.isEmpty { record(.create(made)); reload(); selection = Set(made) }
    }

    func pasteShortcuts() {
        let src = clipboard.isEmpty ? (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []) : clipboard
        let made = src.compactMap { makeShortcut(to: $0, in: current) }
        if !made.isEmpty { record(.create(made)); reload(); selection = Set(made) }
    }

    func newShortcutViaPicker() {
        let p = NSOpenPanel()
        p.message = "Choose the item the shortcut should point to"
        p.canChooseDirectories = true
        guard p.runModal() == .OK, let u = p.url else { return }
        if let made = makeShortcut(to: u, in: current) { record(.create([made])); reload(); selection = [made] }
    }

    // MARK: Archives

    private func run(_ exe: String, _ args: [String], cwd: URL? = nil, then: @escaping @MainActor (Bool) -> Void) {
        Task.detached {
            let p = Process()
            p.executableURL = URL(filePath: exe)
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.standardError = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            await MainActor.run { then(ok) }
        }
    }

    func compress(_ urls: Set<URL>? = nil, into dir: URL? = nil) {
        let list = Array(urls ?? selection).sorted { $0.path < $1.path }
        guard let first = list.first else { return }
        let destDir = dir ?? current
        let name = list.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let dest = Self.uniqueURL(in: destDir, name: name + ".zip", suffix: " (1)")
        let parent = first.deletingLastPathComponent()
        let sameParent = list.allSatisfy { $0.deletingLastPathComponent() == parent }
        // "./" keeps names starting with "-" from being read as options; -y stores symlinks instead of following them.
        let args = ["-r", "-q", "-y", dest.path] + (sameParent ? list.map { "./" + $0.lastPathComponent } : list.map(\.path))
        run("/usr/bin/zip", args, cwd: sameParent ? parent : nil) { ok in
            if ok { self.record(.create([dest.normalized])); self.reload(); self.selection = [dest.normalized] }
            else { try? FileManager.default.removeItem(at: dest); self.errorMessage = String(localized: "Couldn't compress the selection.") }
        }
    }

    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "cpio", "iso"]
    func isArchive(_ u: URL) -> Bool { Self.archiveExts.contains(u.pathExtension.lowercased()) }

    func extract(_ u: URL) {
        let dest = Self.uniqueURL(in: u.deletingLastPathComponent(), name: u.deletingPathExtension().lastPathComponent, suffix: " (1)")
        do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false) }
        catch { errorMessage = error.localizedDescription; return }
        let zip = u.pathExtension.lowercased() == "zip"
        run(zip ? "/usr/bin/ditto" : "/usr/bin/tar", zip ? ["-x", "-k", u.path, dest.path] : ["-xf", u.path, "-C", dest.path]) { ok in
            if ok { self.record(.create([dest.normalized])); self.reload(); self.selection = [dest.normalized] }
            else { try? FileManager.default.removeItem(at: dest); self.errorMessage = String(localized: "Couldn't extract “\(u.lastPathComponent)”.") }
        }
    }

    // MARK: Open with / share / send to

    func openWithApps(_ u: URL) -> [URL] {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: u)
        return Array(apps.prefix(14))
    }

    func open(_ urls: Set<URL>, with app: URL) {
        NSWorkspace.shared.open(Array(urls), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseAppAndOpen(_ urls: Set<URL>) {
        let p = NSOpenPanel()
        p.directoryURL = URL(filePath: "/Applications")
        p.allowedContentTypes = [.application]
        p.message = "Choose an app to open the selection with"
        if p.runModal() == .OK, let app = p.url { open(urls, with: app) }
    }

    func share(_ urls: Set<URL>? = nil) {
        let list = Array(urls ?? selection)
        guard !list.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: list)
        let mouse = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        picker.show(relativeTo: NSRect(origin: mouse, size: .init(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    func mailRecipient(_ urls: Set<URL>) { NSSharingService(named: .composeEmail)?.perform(withItems: Array(urls)) }

    var sendToVolumes: [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path != "/" }
    }

    func copyOrMove(_ urls: Set<URL>, move: Bool) {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = move ? "Move" : "Copy"
        p.message = move ? "Move the selected items to…" : "Copy the selected items to…"
        guard p.runModal() == .OK, let dest = p.url else { return }
        transfer(Array(urls), into: dest.normalized, move: move)
    }

    // MARK: Network

    func isRemote(_ volume: URL) -> Bool {
        (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
    }

    /// Mounted network shares (SMB / NFS / AFP / WebDAV…).
    var networkVolumes: [URL] {
        _ = volumesVersion
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? []
        return vols.filter { isRemote($0) }
    }

    static let serverSchemes: Set<String> = ["smb", "nfs", "afp", "ftp", "http", "https", "webdav"]

    func connectToServer() {
        let a = NSAlert()
        a.messageText = String(localized: "Connect to server")
        a.informativeText = String(localized: "Enter a server address, for example smb://server/share or nfs://host/path.")
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
        field.placeholderString = "smb://server/share"
        let save = NSButton(checkboxWithTitle: String(localized: "Show in the navigation pane"), target: nil, action: nil)
        save.state = .on
        save.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        box.addSubview(field); box.addSubview(save)
        a.accessoryView = box
        a.window.initialFirstResponder = field
        a.addButton(withTitle: String(localized: "Connect")); a.addButton(withTitle: String(localized: "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "smb://" + text }   // "192.168.1.10/share" means SMB, like Finder
        guard let url = URL(string: text), let scheme = url.scheme, Self.serverSchemes.contains(scheme.lowercased()),
              url.host() != nil else {
            errorMessage = String(localized: "“\(text)” isn't a valid server address."); return
        }
        if save.state == .on { saveServer(url) }
        openServer(url)
    }

    func isSaved(server url: URL) -> Bool { servers.contains { Self.sameServer($0, url) } }

    func saveServer(_ url: URL) {
        guard !isSaved(server: url) else { return }
        servers.append(Self.withoutPassword(url))
        UserDefaults.standard.set(servers.map(\.absoluteString), forKey: "savedServers")
    }

    func forgetServer(_ url: URL) {
        servers.removeAll { Self.sameServer($0, url) }
        UserDefaults.standard.set(servers.map(\.absoluteString), forKey: "savedServers")
    }

    /// Passwords belong in the keychain (macOS offers "Remember this password"), never in our settings.
    static func withoutPassword(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.password = nil
        return c.url ?? url
    }

    /// Same host and share, ignoring user name, case and trailing slashes.
    nonisolated static func sameServer(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String {
            let path = u.path().removingPercentEncoding ?? u.path()
            return (u.scheme ?? "").lowercased() + "://" + (u.host() ?? "").lowercased() + "/"
                + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        return key(a) == key(b)
    }

    /// Where a saved server is mounted right now, if it is.
    func mountPoint(of server: URL) -> URL? {
        networkVolumes.first { v in
            guard let remote = (try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting else { return false }
            return Self.sameServer(remote, server)
        }
    }

    /// Mounted shares that aren't saved servers (those are listed under their saved entry).
    var unsavedNetworkVolumes: [URL] {
        networkVolumes.filter { v in
            guard let remote = (try? v.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting else { return true }
            return !isSaved(server: remote)
        }
    }

    func remoteURL(of volume: URL) -> URL? {
        (try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting
    }

    /// Opens a server: goes straight there if it's mounted, otherwise mounts it (macOS asks for the
    /// password and can keep it in the keychain) and then opens it here, not in Finder.
    func openServer(_ url: URL) {
        if let mp = mountPoint(of: url) { go(to: mp.normalized); return }
        connecting = url
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &request, .main) { [weak self] status, _, mounts in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connecting = nil
                let points = (mounts as? [String]) ?? []
                if let first = points.first {
                    self.go(to: URL(filePath: first).normalized)
                } else if let mp = self.mountPoint(of: url) {
                    self.go(to: mp.normalized)      // already mounted (EEXIST)
                } else if status != 0 && status != Int32(ECANCELED) && status != Int32(userCanceledErr) {
                    self.errorMessage = String(localized: "Couldn't connect to “\(url.host() ?? url.absoluteString)” (error \(status)).")
                }
            }
        }
        if status != 0 { connecting = nil; errorMessage = String(localized: "Couldn't connect to “\(url.host() ?? url.absoluteString)” (error \(status)).") }
    }

    func disconnect(_ volume: URL) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch { errorMessage = error.localizedDescription }
        if current.path.hasPrefix(volume.normalized.path) { go(to: FileManager.default.homeDirectoryForCurrentUser.normalized) }
    }

    // MARK: Misc

    func openInTerminal(_ dir: URL? = nil) {
        NSWorkspace.shared.open([dir ?? current], withApplicationAt: URL(filePath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func isImage(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false }

    func setDesktopBackground(_ u: URL) {
        do { for s in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(u, for: s, options: [:]) } }
        catch { errorMessage = error.localizedDescription }
    }

    func rotate(_ urls: Set<URL>, degrees: Int) {
        for u in urls where isImage(u) {
            run("/usr/bin/sips", ["-r", String(degrees), u.path]) { _ in self.reload() }
        }
    }

    func printFiles(_ urls: Set<URL>) {
        run("/usr/bin/lpr", urls.map(\.path)) { ok in if !ok { self.errorMessage = String(localized: "Couldn't print (no default printer?).") } }
    }

    // MARK: Finder tags

    func hasTag(_ tag: FinderTag, _ urls: Set<URL>) -> Bool {
        !urls.isEmpty && urls.allSatisfy { u in FinderTag.read(u).contains { $0.name == tag.name } }
    }

    /// Adds the tag to every item, or removes it when all of them already have it (like Finder).
    func toggleTag(_ tag: FinderTag, _ urls: Set<URL>) {
        let remove = hasTag(tag, urls)
        for u in urls {
            var tags = FinderTag.read(u).filter { $0.name != tag.name }
            if !remove { tags.append(tag) }
            if !FinderTag.write(tags, to: u) { errorMessage = String(localized: "Couldn't change the tags of “\(u.lastPathComponent)”.") }
        }
        reload()
    }
}
