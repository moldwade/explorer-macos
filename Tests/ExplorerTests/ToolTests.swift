import Testing
import Foundation
import AppKit
import PDFKit
@testable import Explorer

@MainActor @Suite(.serialized) struct ToolTests {
    let fm = FileManager.default
    func settle(_ s: Double = 1.5) async { try? await Task.sleep(for: .seconds(s)) }
    func png(_ u: URL, _ w: Int, _ h: Int) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: u)
    }
    func pdf(_ u: URL, pages: Int) throws {
        let doc = PDFDocument()
        let img = u.deletingLastPathComponent().appending(path: "page-src.png")
        try png(img, 50, 50)
        for _ in 0..<pages { doc.insert(PDFPage(image: NSImage(contentsOf: img)!)!, at: doc.pageCount) }
        try FileManager.default.removeItem(at: img)
        #expect(doc.write(to: u))
    }

    @Test func pdfMergeSplitRotate() async throws {
        let d = fm.temporaryDirectory.appending(path: "pdf-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let a = d.appending(path: "a.pdf"), b = d.appending(path: "b.pdf")
        try pdf(a, pages: 2); try pdf(b, pages: 3)
        let s = ExplorerState(start: d); try? await Task.sleep(for: .milliseconds(400))
        s.mergePDFs([a, b]); await settle()
        #expect(PDFDocument(url: d.appending(path: "Merged.pdf"))?.pageCount == 5)
        s.splitPDF(b); await settle()
        let pages = try fm.contentsOfDirectory(atPath: d.appending(path: "b (pages)").path).sorted()
        #expect(pages == ["b - page 1.pdf", "b - page 2.pdf", "b - page 3.pdf"])
        s.rotatePDFs([a], degrees: 90); await settle()
        #expect(PDFDocument(url: a)?.page(at: 0)?.rotation == 90)
        s.undo(); await settle(0.5)   // undo the split folder
        #expect(!fm.fileExists(atPath: d.appending(path: "b (pages)").path))
    }

    @Test func imageResizeConvertAndPDF() async throws {
        let d = fm.temporaryDirectory.appending(path: "img-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let big = d.appending(path: "photo.png"), small = d.appending(path: "logo.png")
        try png(big, 4000, 3000); try png(small, 100, 80)
        let s = ExplorerState(start: d); try? await Task.sleep(for: .milliseconds(400))
        s.resizeForEmail([big]); await settle(3)
        let mail = d.appending(path: "photo (email).jpg")
        let rep = try #require(NSImageRep(contentsOf: mail))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == 1600)
        s.convertImages([small], to: "jpeg"); await settle(2)
        #expect(fm.fileExists(atPath: d.appending(path: "logo.jpg").path))
        s.imagesToPDF([big, small]); await settle(3)
        #expect(PDFDocument(url: d.appending(path: "Images.pdf"))?.pageCount == 2)
    }
}
