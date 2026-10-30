import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct SidebarTests {
    let fm = FileManager.default
    func settle() async { try? await Task.sleep(for: .milliseconds(400)) }

    @Test func dateGroupsSortByFullTime() async throws {
        let d = fm.temporaryDirectory.appending(path: "dg-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let now = Date()
        // Same day, names in reverse time order so name sort would differ.
        for (n, minsAgo) in [("a.txt", 30), ("b.txt", 5), ("c.txt", 60)] {
            let u = d.appending(path: n); try "".write(to: u, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(-minsAgo * 60))], ofItemAtPath: u.path)
        }
        let old = d.appending(path: "z-old.txt"); try "".write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-400 * 86400)], ofItemAtPath: old.path)
        let s = ExplorerState(start: d); await settle()
        s.group = .modified
        let today = Calendar.current.component(.hour, from: now) >= 1 ? ["b.txt", "a.txt", "c.txt"] : nil
        if let today { #expect(Array(s.displayed.map(\.name).prefix(3)) == today) }
        #expect(s.groups.first?.title == "Today" || today == nil)
        #expect(s.groups.last?.title == "A long time ago")
        s.applySort(\FileItem.modified, ascending: true)   // oldest first
        #expect(s.groups.first?.title == "A long time ago")
        if today != nil { #expect(Array(s.displayed.map(\.name).suffix(3)) == ["c.txt", "a.txt", "b.txt"]) }
    }

    @Test func favoritesToggle() async throws {
        let s = ExplorerState(start: fm.temporaryDirectory)
        let saved = s.favorites
        defer { s.favorites = saved; UserDefaults.standard.set(saved.map(\.path), forKey: "favorites") }
        let a = URL(filePath: "/tmp/fav-a.txt"), b = URL(filePath: "/tmp/fav-b")
        s.toggleFavorite([a, b])
        #expect(s.isFavorite(a) && s.isFavorite(b))
        s.toggleFavorite([a])
        #expect(!s.isFavorite(a) && s.isFavorite(b))
    }

    @Test func tagViewSurvivesSearchReset() async throws {
        let s = ExplorerState(start: fm.temporaryDirectory); await settle()
        s.showTag(FinderTag.standard[0])
        s.search()                       // fired by the search box's onChange
        #expect(s.tagFilter != nil && s.isSearching)
        s.go(to: fm.temporaryDirectory)
        #expect(s.tagFilter == nil)
    }
}
