import SwiftUI
import AppKit
import QuickLookThumbnailing

struct PropInfo {
    var name = "", kind = "", location = ""
    var size: Int64 = 0, onDisk: Int64 = 0
    var files = 0, folders = 0
    var created: Date?, modified: Date?, accessed: Date?
    var hidden = false, readOnly = false
    /// Set when the item is a whole disk: Windows shows used/free space instead of counting every file.
    var volume: (total: Int64, free: Int64, format: String)?

    nonisolated static func compute(_ urls: [URL]) -> PropInfo {
        var p = PropInfo()
        if urls.count == 1, let u = urls.first,
           let v = try? u.resourceValues(forKeys: [.isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                    .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]),
           v.isVolume == true {
            let total = Int64(v.volumeTotalCapacity ?? 0)
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            p.volume = (total, free, v.volumeLocalizedFormatDescription ?? "")
            p.name = FileManager.default.displayName(atPath: u.path)
            p.kind = "Disk"
            p.location = u.path
            return p
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isPackageKey]
        let fm = FileManager.default
        for u in urls {
            let v = try? u.resourceValues(forKeys: keys)
            if v?.isDirectory == true {
                p.folders += 0
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: []) {
                    for case let c as URL in en {
                        guard let cv = try? c.resourceValues(forKeys: keys) else { continue }
                        if cv.isDirectory == true { p.folders += 1 } else {
                            p.files += 1
                            p.size += Int64(cv.fileSize ?? 0)
                        }
                        p.onDisk += Int64(cv.totalFileAllocatedSize ?? 0)
                    }
                }
            } else {
                p.files += 1
                p.size += Int64(v?.fileSize ?? 0)
                p.onDisk += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        if let u = urls.first {
            let a = try? fm.attributesOfItem(atPath: u.path)
            p.created = a?[.creationDate] as? Date
            p.modified = a?[.modificationDate] as? Date
            p.accessed = (try? u.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
            p.hidden = (try? u.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
            p.readOnly = ((a?[.posixPermissions] as? Int) ?? 0o644) & 0o200 == 0
            p.location = u.deletingLastPathComponent().path
            p.name = urls.count == 1 ? u.lastPathComponent : "\(urls.count) items"
            p.kind = urls.count == 1
                ? ((try? u.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "File")
                : "Multiple types"
        }
        return p
    }
}

struct PropertiesView: View {
    let state: ExplorerState
    let urls: [URL]
    @ViewState private var info = PropInfo()
    @ViewState private var loaded = false
    @ViewState private var hidden = false
    @ViewState private var readOnly = false
    @Environment(\.dismiss) private var dismiss

    private func bytes(_ n: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) (\(n.formatted()) bytes)"
    }
    private func date(_ d: Date?) -> String { d?.formatted(date: .complete, time: .standard) ?? "—" }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(L(k)).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing)
            Text(v).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? "/")).resizable().frame(width: 40, height: 40)
                Text(info.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            }
            Divider()
            if let vol = info.volume { volumeRows(vol) } else { fileRows }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.disabled(info.volume != nil)
                Button("OK") { if info.volume == nil { apply() }; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12.5))
        .padding(20).frame(width: 440, height: 470)
        .task {
            let list = urls
            info = await Task.detached { PropInfo.compute(list) }.value
            hidden = info.hidden; readOnly = info.readOnly; loaded = true
        }
    }

    /// Disk page, like Windows: used, free, capacity and a bar.
    @ViewBuilder private func volumeRows(_ v: (total: Int64, free: Int64, format: String)) -> some View {
        let used = max(v.total - v.free, 0)
        row("Type:", L("Disk"))
        row("File system:", v.format)
        Divider()
        row("Used space:", bytes(used))
        row("Free space:", bytes(v.free))
        Divider()
        row("Capacity:", bytes(v.total))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.25))
                RoundedRectangle(cornerRadius: 4).fill(Theme.accent)
                    .frame(width: v.total > 0 ? g.size.width * CGFloat(used) / CGFloat(v.total) : 0)
            }
        }
        .frame(height: 14).padding(.leading, 98)
    }

    @ViewBuilder private var fileRows: some View {
            row("Type:", info.kind)
            row("Location:", info.location)
            row("Size:", loaded ? bytes(info.size) : L("Calculating…"))
            row("Size on disk:", loaded ? bytes(info.onDisk) : L("Calculating…"))
            if info.folders + info.files > 0 && (urls.count > 1 || urls.first.map { state.item(for: $0)?.isDirectory == true } == true) {
                row("Contains:", loaded ? String(localized: "\(info.files) Files, \(info.folders) Folders") : L("Calculating…"))
            }
            Divider()
            row("Created:", date(info.created))
            row("Modified:", date(info.modified))
            row("Accessed:", date(info.accessed))
            Divider()
            HStack(alignment: .top) {
                Text("Attributes:").foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing)
                VStack(alignment: .leading) {
                    Toggle("Read-only", isOn: $readOnly)
                    Toggle("Hidden", isOn: $hidden)
                }
            }
    }

    private func apply() {
        let fm = FileManager.default
        for u in urls {
            var uu = u
            var v = URLResourceValues(); v.isHidden = hidden
            try? uu.setResourceValues(v)
            if let perms = (try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int {
                let new = readOnly ? perms & ~0o222 : perms | 0o200
                try? fm.setAttributes([.posixPermissions: new], ofItemAtPath: u.path)
            }
        }
        state.reload()
    }
}

// MARK: - Details pane (right side)

struct DetailsPane: View {
    let state: ExplorerState
    @ViewState private var thumb: NSImage?

    var body: some View {
        let sel = state.selectedItems
        VStack(spacing: 10) {
            if sel.count == 1, let i = sel.first {
                Group {
                    if let t = thumb { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) }
                    else { ItemIcon(item: i, size: 96) }
                }
                .frame(maxWidth: .infinity, maxHeight: 180).padding(.top, 16)
                Text(i.name).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center).lineLimit(3)
                Text(i.kind).foregroundStyle(Theme.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    kv("Date modified", i.modified.formatted(date: .abbreviated, time: .shortened))
                    if !i.isFolder { kv("Size", i.sizeText) }
                    kv("Location", i.url.deletingLastPathComponent().path)
                }
            } else if sel.count > 1 {
                Image(systemName: "square.stack.3d.up").font(.system(size: 48)).foregroundStyle(Theme.secondary).padding(.top, 40)
                Text("\(sel.count) items selected").font(.system(size: 14, weight: .semibold))
                Text(ByteCountFormatter.string(fromByteCount: sel.filter { !$0.isFolder }.reduce(0) { $0 + $1.size }, countStyle: .file))
                    .foregroundStyle(Theme.secondary)
            } else {
                Image(systemName: "folder.fill").font(.system(size: 56)).foregroundStyle(Theme.folder).padding(.top, 40)
                Text(state.title).font(.system(size: 14, weight: .semibold))
                Text("\(state.displayed.count) items").foregroundStyle(Theme.secondary)
                Text("Select a single file to see its details.").font(.caption).foregroundStyle(Theme.secondary).padding(.top, 8)
            }
            Spacer()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .frame(width: 270)
        .background(Theme.background)
        .task(id: sel.first?.url) { await loadThumb(sel.count == 1 ? sel.first : nil) }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption).foregroundStyle(Theme.secondary)
            Text(v).lineLimit(3).textSelection(.enabled)
        }
    }

    private func loadThumb(_ item: FileItem?) async {
        thumb = nil
        guard let item, !item.isFolder else { return }
        let req = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 240, height: 180),
                                               scale: 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            thumb = rep.nsImage
        }
    }
}
