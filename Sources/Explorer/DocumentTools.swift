import AppKit
import PDFKit

/// Everyday document chores from the right-click menu: PDF merge/split/rotate and image
/// resize/convert. Everything runs locally (PDFKit, ImageIO via `sips`); results land next to
/// the originals, get selected, and can be undone like any newly created file.
extension ExplorerState {
    func isPDF(_ u: URL) -> Bool { u.pathExtension.lowercased() == "pdf" }

    /// Selected URLs in list order (merge and "images to PDF" follow what the user sees).
    private func ordered(_ urls: Set<URL>) -> [URL] {
        urls.sorted { (displayIndex(of: $0) ?? .max, $0.path) < (displayIndex(of: $1) ?? .max, $1.path) }
    }

    /// Runs `work` off the main thread; on success records the created files for undo and selects them.
    private func produce(_ failure: String, _ work: @escaping @Sendable () throws -> [URL]) {
        Task.detached {
            let result = Result { try work() }
            await MainActor.run {
                switch result {
                case .success(let made) where !made.isEmpty:
                    self.record(.create(made.map(\.normalized)))
                    self.reload()
                    self.selection = Set(made.map(\.normalized))
                case .success: break
                case .failure(let e): self.errorMessage = failure + ": " + e.localizedDescription
                }
            }
        }
    }

    // MARK: PDF

    func mergePDFs(_ urls: Set<URL>) {
        let list = ordered(urls).filter(isPDF)
        guard list.count > 1, let first = list.first else { return }
        let dest = Self.uniqueURL(in: first.deletingLastPathComponent(), name: "Merged.pdf", suffix: " (1)")
        produce(String(localized: "Couldn't merge the PDFs")) {
            let out = PDFDocument()
            for u in list {
                guard let doc = PDFDocument(url: u) else { throw ToolError("Can't read “\(u.lastPathComponent)” (protected or damaged?)") }
                for i in 0..<doc.pageCount { if let p = doc.page(at: i) { out.insert(p, at: out.pageCount) } }
            }
            guard out.write(to: dest) else { throw ToolError("Can't write “\(dest.lastPathComponent)”") }
            return [dest]
        }
    }

    /// One PDF per page, in a new folder "<name> (pages)".
    func splitPDF(_ u: URL) {
        let base = u.deletingPathExtension().lastPathComponent
        let folder = Self.uniqueURL(in: u.deletingLastPathComponent(), name: "\(base) (pages)", suffix: " (1)")
        produce(String(localized: "Couldn't split “\(u.lastPathComponent)”")) {
            guard let doc = PDFDocument(url: u) else { throw ToolError("Can't read the PDF (protected or damaged?)") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let digits = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let one = PDFDocument()
                one.insert(page, at: 0)
                let n = String(i + 1)
                let name = "\(base) - page \(String(repeating: "0", count: digits - n.count))\(n).pdf"
                guard one.write(to: folder.appending(path: name)) else { throw ToolError("Can't write page \(i + 1)") }
            }
            return [folder]
        }
    }

    /// Rotates every page in place (like Preview), 90° clockwise or counter-clockwise.
    func rotatePDFs(_ urls: Set<URL>, degrees: Int) {
        let list = urls.filter(isPDF)
        Task.detached {
            var failed: [String] = []
            for u in list {
                guard let doc = PDFDocument(url: u) else { failed.append(u.lastPathComponent); continue }
                for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + degrees + 360) % 360 } }
                if !doc.write(to: u) { failed.append(u.lastPathComponent) }
            }
            let names = failed
            await MainActor.run {
                if !names.isEmpty { let list = names.joined(separator: ", "); self.errorMessage = String(localized: "Couldn't rotate: \(list)") }
                self.reload()
            }
        }
    }

    // MARK: Images

    /// Makes a copy small enough to mail (longest side 1600 px, JPEG).
    func resizeForEmail(_ urls: Set<URL>) {
        convertImages(urls, format: "jpeg", ext: "jpg", suffix: " (email)", extra: ["-Z", "1600", "-s", "formatOptions", "80"])
    }

    func convertImages(_ urls: Set<URL>, to format: String) {
        convertImages(urls, format: format, ext: format == "jpeg" ? "jpg" : format, suffix: "", extra: [])
    }

    private func convertImages(_ urls: Set<URL>, format: String, ext: String, suffix: String, extra: [String]) {
        let list = ordered(urls).filter(isImage)
        let plan = list.map { u in
            (u, Self.uniqueURL(in: u.deletingLastPathComponent(),
                               name: u.deletingPathExtension().lastPathComponent + suffix + "." + ext, suffix: " (1)"))
        }
        produce(String(localized: "Couldn't convert the image")) {
            var made: [URL] = []
            for (src, dest) in plan {
                let p = Process()
                p.executableURL = URL(filePath: "/usr/bin/sips")
                p.arguments = ["-s", "format", format] + extra + [src.path, "--out", dest.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    try? FileManager.default.removeItem(at: dest)
                    throw ToolError("“\(src.lastPathComponent)” isn't an image macOS can convert")
                }
                made.append(dest)
            }
            return made
        }
    }

    /// One PDF with a page per selected image, in list order.
    func imagesToPDF(_ urls: Set<URL>) {
        let list = ordered(urls).filter(isImage)
        guard let first = list.first else { return }
        let name = list.count == 1 ? first.deletingPathExtension().lastPathComponent + ".pdf" : "Images.pdf"
        let dest = Self.uniqueURL(in: first.deletingLastPathComponent(), name: name, suffix: " (1)")
        produce(String(localized: "Couldn't make a PDF from the images")) {
            let out = PDFDocument()
            for u in list {
                // PDFPage(image:) raises an Objective-C exception (a crash) for an image without bitmap
                // data, so make sure there is a CGImage before handing it over.
                guard let img = NSImage(contentsOf: u),
                      img.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil,
                      let page = PDFPage(image: img) else {
                    throw ToolError("Can't read “\(u.lastPathComponent)”")
                }
                out.insert(page, at: out.pageCount)
            }
            guard out.write(to: dest) else { throw ToolError("Can't write “\(dest.lastPathComponent)”") }
            return [dest]
        }
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
