import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct CutTests {
    let fm = FileManager.default
    func tmp() throws -> URL {
        let d = fm.temporaryDirectory.appending(path: "cut-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func cutInOneTabPasteInAnotherMoves() async throws {
        let dir = try tmp(); let sub = dir.appending(path: "sub").normalized
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        let f = dir.appending(path: "t.txt"); try "x".write(to: f, atomically: true, encoding: .utf8)
        let a = ExplorerState(start: dir), b = ExplorerState(start: sub); await settle()
        a.cut([f])
        #expect(b.isCutPending(f))
        b.paste()
        #expect(fm.fileExists(atPath: sub.appending(path: "t.txt").path))
        #expect(!fm.fileExists(atPath: f.path))
        #expect(!a.isCutPending(f))
    }

    @Test func escapeCancelsCut() async throws {
        let dir = try tmp(); let f = dir.appending(path: "e.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        let s = ExplorerState(start: dir); await settle()
        s.cut([f]); #expect(s.isCutPending(f))
        s.cancelCut(); #expect(!s.isCutPending(f))
    }

    @Test func copyIsNotDimmed() async throws {
        let dir = try tmp(); let f = dir.appending(path: "c.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        let s = ExplorerState(start: dir); await settle()
        s.copy([f]); #expect(!s.isCutPending(f))
    }
}
