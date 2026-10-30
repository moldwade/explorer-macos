import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct SafetyTests {
    let fm = FileManager.default
    func tmp() throws -> URL {
        let d = fm.temporaryDirectory.appending(path: "safe-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d, withIntermediateDirectories: true); return d
    }

    @Test func copyStopsOnUnreadableFile() throws {
        let d = try tmp(); let src = d.appending(path: "src"); try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "ok".write(to: src.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let bad = src.appending(path: "b.txt"); try "secret".write(to: bad, atomically: true, encoding: .utf8)
        chmod(bad.path, 0)
        defer { chmod(bad.path, 0o644) }
        #expect(throws: (any Error).self) { try TransferEngine.copy(src, to: d.appending(path: "dst"), counter: ByteCounter()) }
    }

    @Test func undoKeepsWhatFailed() async throws {
        let d = try tmp(); let sub = d.appending(path: "sub").normalized
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        for n in ["x.txt", "y.txt"] { try "".write(to: d.appending(path: n), atomically: true, encoding: .utf8) }
        let s = ExplorerState(start: d); try? await Task.sleep(for: .milliseconds(300))
        s.transfer([d.appending(path: "x.txt"), d.appending(path: "y.txt")], into: sub, move: true)
        // Block undo for x by putting a new file where it came from.
        try "".write(to: d.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        s.undo()
        #expect(fm.fileExists(atPath: d.appending(path: "y.txt").path))
        #expect(s.undoStack.count == 1)  // x's move is still there to retry
    }

    @Test func secondPasteGetsItsOwnName() throws {
        let d = try tmp(); let f = d.appending(path: "big.txt"); try "x".write(to: f, atomically: true, encoding: .utf8)
        ExplorerState.inFlight.insert(d.appending(path: "big - Copy.txt").path)
        defer { ExplorerState.inFlight.removeAll() }
        let s = ExplorerState(start: d)
        let out = s.transfer([f], into: d, move: false)
        #expect(out.first?.lastPathComponent != "big - Copy.txt")
    }
}
