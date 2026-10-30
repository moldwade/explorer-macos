import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct ConflictTests {
    let fm = FileManager.default
    func settle() async { try? await Task.sleep(for: .milliseconds(500)) }
    func setup() throws -> (src: URL, dst: URL) {
        let d = fm.temporaryDirectory.appending(path: "cf-\(UUID().uuidString)").normalized
        let src = d.appending(path: "src"), dst = d.appending(path: "dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for n in ["a.txt", "b.txt"] {
            try "new".write(to: src.appending(path: n), atomically: true, encoding: .utf8)
            try "old".write(to: dst.appending(path: n), atomically: true, encoding: .utf8)
        }
        return (src.normalized, dst.normalized)
    }
    func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    @Test func replaceAllOverwritesAndAsksOnce() async throws {
        let (src, dst) = try setup()
        let s = ExplorerState(start: dst); await settle()
        var asked = 0
        s.resolveConflict = { _, _, remaining in asked += 1; #expect(remaining == 2); return (.replace, true) }
        s.transfer([src.appending(path: "a.txt"), src.appending(path: "b.txt")], into: dst, move: false)
        await settle()
        #expect(asked == 1)
        #expect(text(dst.appending(path: "a.txt")) == "new" && text(dst.appending(path: "b.txt")) == "new")
        #expect(!fm.fileExists(atPath: dst.appending(path: "a - Copy.txt").path))
    }

    @Test func skipLeavesOldAndKeepBothAddsCopy() async throws {
        let (src, dst) = try setup()
        let s = ExplorerState(start: dst); await settle()
        var answers: [ExplorerState.ConflictChoice] = [.skip, .keepBoth]
        s.resolveConflict = { _, _, _ in (answers.removeFirst(), false) }
        s.transfer([src.appending(path: "a.txt"), src.appending(path: "b.txt")], into: dst, move: true)
        await settle()
        #expect(text(dst.appending(path: "a.txt")) == "old")
        #expect(fm.fileExists(atPath: src.appending(path: "a.txt").path))      // skipped: not moved
        #expect(text(dst.appending(path: "b.txt")) == "old")
        #expect(text(dst.appending(path: "b - Copy.txt")) == "new")
    }

    @Test func pasteIntoSameFolderNeverAsks() async throws {
        let (src, _) = try setup()
        let s = ExplorerState(start: src); await settle()
        s.resolveConflict = { _, _, _ in Issue.record("should not ask"); return (.skip, false) }
        s.copy([src.appending(path: "a.txt")]); s.paste()
        await settle()
        #expect(fm.fileExists(atPath: src.appending(path: "a - Copy.txt").path))
    }
}
