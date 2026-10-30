import AppKit
import UniformTypeIdentifiers

extension URL {
    /// Canonical form (standardized, no trailing slash) so URLs compare equal.
    var normalized: URL { URL(filePath: standardizedFileURL.path, directoryHint: .notDirectory) }
}

struct FileItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let kind: String
    let tags: [FinderTag]
    /// A Finder alias or symbolic link ("shortcut").
    let isAlias: Bool

    /// Where an alias or symlink points, or nil if it is broken (or not a shortcut).
    var aliasTarget: URL? {
        guard isAlias else { return nil }
        return (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]))?.normalized
    }

    /// A folder you can navigate into (packages such as .app open like files).
    var isFolder: Bool { isDirectory && !isPackage }
    var sizeKey: Int64 { isFolder ? -1 : size }
    var sizeText: String {
        isFolder ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .isAliasFileKey,
    ]

    init?(url: URL) {
        guard var v = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        isAlias = v.isAliasFile ?? false
        if v.isSymbolicLink == true,
           let r = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(Self.keys)) {
            v = r
        }
        self.url = url.normalized
        name = url.lastPathComponent
        isDirectory = v.isDirectory ?? false
        isPackage = v.isPackage ?? false
        isHidden = v.isHidden ?? name.hasPrefix(".")
        size = Int64(v.fileSize ?? 0)
        modified = v.contentModificationDate ?? .distantPast
        kind = v.localizedTypeDescription ?? (isDirectory ? "Folder" : "File")
        tags = FinderTag.read(url)
    }

    static func list(_ dir: URL) throws -> [FileItem] {
        try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
            .compactMap { FileItem(url: $0) }
    }
}

/// A macOS Finder tag. `color` is Finder's label index: 0 none, 1 gray, 2 green, 3 purple,
/// 4 blue, 5 yellow, 6 red, 7 orange.
struct FinderTag: Hashable {
    let name: String
    let color: Int

    static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    /// Tags as Finder stores them: a binary-plist array of "name\ncolor" strings in an extended attribute.
    static func read(_ url: URL) -> [FinderTag] {
        let size = getxattr(url.path, xattrName, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let got = data.withUnsafeMutableBytes { getxattr(url.path, xattrName, $0.baseAddress, size, 0, 0) }
        guard got == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return FinderTag(name: String(parts[0]), color: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }

    @discardableResult
    static func write(_ tags: [FinderTag], to url: URL) -> Bool {
        if tags.isEmpty { return removexattr(url.path, xattrName, 0) == 0 || errno == ENOATTR }
        let list = tags.map { $0.color == 0 ? $0.name : "\($0.name)\n\($0.color)" }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        else { return false }
        return data.withUnsafeBytes { setxattr(url.path, xattrName, $0.baseAddress, data.count, 0, 0) } == 0
    }

    /// Finder's seven colour tags, with the names the system uses for them (localized).
    static var standard: [FinderTag] {
        let names = NSWorkspace.shared.fileLabels
        return (1...7).compactMap { i in i < names.count ? FinderTag(name: names[i], color: i) : nil }
    }

    var nsColor: NSColor? {
        let colors = NSWorkspace.shared.fileLabelColors
        return color > 0 && color < colors.count ? colors[color] : nil
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    private static let folder = NSWorkspace.shared.icon(for: .folder)

    static func icon(for item: FileItem) -> NSImage {
        if item.isFolder { return folder }
        let ext = item.url.pathExtension.lowercased()
        // Aliases get the system icon, which already carries the shortcut arrow.
        if item.isPackage || item.isAlias || ext.isEmpty { return NSWorkspace.shared.icon(forFile: item.url.path) }
        if let i = cache[ext] { return i }
        let i = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = i
        return i
    }
}

/// Lazy node for the navigation-pane folder tree.
struct TreeNode: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: URL { url }

    init(url: URL, title: String? = nil) {
        self.url = url.normalized
        self.title = title ?? FileManager.default.displayName(atPath: url.path)
    }

    /// Sub-folders, or nil when there are none (hides the disclosure arrow).
    var children: [TreeNode]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let dirs = urls.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { TreeNode(url: $0, title: $0.lastPathComponent) }
        return dirs.isEmpty ? nil : dirs
    }
}
