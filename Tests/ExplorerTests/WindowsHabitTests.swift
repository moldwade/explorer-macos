import Testing
import Foundation
@testable import Explorer

@MainActor @Suite(.serialized) struct WindowsHabitTests {
    let fm = FileManager.default
    func settle() async { try? await Task.sleep(for: .milliseconds(400)) }

    @Test func hiddenExtensionsKeepExtensionOnRename() async throws {
        let d = fm.temporaryDirectory.appending(path: "ext-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d.appending(path: "folder.v2"), withIntermediateDirectories: true)
        let f = d.appending(path: "report.pdf"); try "".write(to: f, atomically: true, encoding: .utf8)
        let s = ExplorerState(start: d); await settle()
        let saved = s.showExtensions; defer { s.showExtensions = saved }
        s.showExtensions = false
        let names = s.displayed.map(s.displayName)
        #expect(names.contains("report") && names.contains("folder.v2"))
        s.beginRename(f)
        #expect(s.renameText == "report")
        s.renameText = "invoice"
        s.commitRename()
        #expect(fm.fileExists(atPath: d.appending(path: "invoice.pdf").path))
        s.showExtensions = true
        #expect(s.displayed.map(s.displayName).contains("folder.v2"))
    }

    @Test func slowClickRenameArmsAndOpenCancels() async throws {
        let d = fm.temporaryDirectory.appending(path: "sc-\(UUID().uuidString)").normalized
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appending(path: "a.txt"); try "".write(to: f, atomically: true, encoding: .utf8)
        let s = ExplorerState(start: d); await settle()
        s.selection = [f]
        s.armSlowClickRename(f)
        try await Task.sleep(for: .seconds(1))
        #expect(s.renameTarget == f)
        s.renameTarget = nil
        s.armSlowClickRename(f)
        s.pendingRename = nil          // what open() / a double-click does
        try await Task.sleep(for: .seconds(1))
        #expect(s.renameTarget == nil)
    }
}
