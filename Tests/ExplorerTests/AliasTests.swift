import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct AliasTests {
    let fm = FileManager.default
    @Test func shortcutToFolderOpensFolder() async throws {
        let d = fm.temporaryDirectory.appending(path: "al-\(UUID().uuidString)").normalized
        let target = d.appending(path: "Customers").normalized
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let s = ExplorerState(start: d)
        let alias = try #require(s.makeShortcut(to: target, in: d))
        let item = try #require(FileItem(url: alias))
        #expect(item.isAlias && !item.isFolder)
        #expect(item.aliasTarget == target)
        s.open([alias.normalized])
        #expect(s.current == target)
        s.go(to: d); s.go(to: alias)
        #expect(s.current == target)
    }
}
