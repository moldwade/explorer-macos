import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct SelectionTests {
    let fm = FileManager.default
    func dirWith(_ names: [String]) throws -> URL {
        let d = fm.temporaryDirectory.appending(path: "sel-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        for n in names { try "".write(to: d.appending(path: n), atomically: true, encoding: .utf8) }
        return d
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
    func names(_ s: ExplorerState) -> [String] { s.selectedItems.map(\.name) }

    @Test func shiftArrowGrowsAndShrinksBothWays() async throws {
        let d = try dirWith(["a", "b", "c", "d", "e"])
        let s = ExplorerState(start: d); await settle()
        let e = s.displayed[2]                       // "c"
        s.click(e, shift: false, toggle: false)
        s.moveSelection(-1, extend: true)             // b..c
        s.moveSelection(-1, extend: true)             // a..c (used to get stuck at b..c)
        #expect(names(s) == ["a", "b", "c"])
        s.moveSelection(1, extend: true)              // b..c
        #expect(names(s) == ["b", "c"])
        s.moveSelection(1, extend: true); s.moveSelection(1, extend: true); s.moveSelection(1, extend: true)  // c, c..d, c..e
        #expect(names(s) == ["c", "d", "e"])
        #expect(s.cursor?.lastPathComponent == "e")
    }

    @Test func cachedListFollowsChanges() async throws {
        let d = try dirWith(["b", "a"])
        let s = ExplorerState(start: d); await settle()
        #expect(s.displayed.map(\.name) == ["a", "b"])
        try "".write(to: d.appending(path: "c"), atomically: true, encoding: .utf8)
        s.reload(); await settle()
        #expect(s.displayed.map(\.name) == ["a", "b", "c"])
        s.sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: .reverse)]
        #expect(s.displayed.map(\.name) == ["c", "b", "a"])
        s.showHidden = true
        try "".write(to: d.appending(path: ".h"), atomically: true, encoding: .utf8)
        s.reload(); await settle()
        #expect(s.displayed.count == 4)
    }

    @Test func goUpSelectsAndFocusesChild() async throws {
        let d = try dirWith([]); let sub = d.appending(path: "sub").normalized
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        let s = ExplorerState(start: sub); await settle()
        s.goUp(); await settle()
        #expect(s.selection == [sub]); #expect(s.cursor == sub)
    }

    @Test func dropIntoOwnFolderDoesNothing() async throws {
        let d = try dirWith(["k.txt"])
        let s = ExplorerState(start: d); await settle()
        // As it arrives from a drag: /private/... spelling, parent with a trailing slash.
        let dragged = URL(fileURLWithPath: d.appending(path: "k.txt").path)
        s.drop([dragged], into: d)
        await settle()
        #expect(fm.fileExists(atPath: d.appending(path: "k.txt").path))
        #expect(!fm.fileExists(atPath: d.appending(path: "k - Copy.txt").path))
    }
}
