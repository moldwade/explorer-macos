import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct TagTests {
    @Test func toggleAddsThenRemovesAndKeepsOthers() async throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "tag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let a = d.appending(path: "a.txt"), b = d.appending(path: "b.txt")
        try "".write(to: a, atomically: true, encoding: .utf8); try "".write(to: b, atomically: true, encoding: .utf8)
        #expect(FinderTag.write([FinderTag(name: "Work", color: 4)], to: a))
        let s = ExplorerState(start: d)
        let red = FinderTag.standard.first { $0.color == 6 }!
        s.toggleTag(red, [a, b])
        #expect(FinderTag.read(a) == [FinderTag(name: "Work", color: 4), red])
        #expect(FinderTag.read(b) == [red])
        #expect(s.item(for: a)?.tags.count == 2)
        s.toggleTag(red, [a, b])
        #expect(FinderTag.read(a) == [FinderTag(name: "Work", color: 4)])
        #expect(FinderTag.read(b).isEmpty)
        #expect(FinderTag.standard.count == 7)
    }
}
