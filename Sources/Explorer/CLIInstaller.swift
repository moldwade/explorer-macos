import AppKit

/// Installs the bundled `explorermac` script into a bin directory that is on PATH.
@MainActor
enum CLIInstaller {
    static var script: URL? { Bundle.main.url(forResource: "explorermac", withExtension: nil) }

    /// Writable candidates, best first.
    static func candidateDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferred = [URL(filePath: "/usr/local/bin"), URL(filePath: "/opt/homebrew/bin"), home.appending(path: ".local/bin")]
        return preferred.filter { d in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) && isDir.boolValue
            return exists && FileManager.default.isWritableFile(atPath: d.path)
        }
    }

    static func install() {
        let alert = NSAlert()
        guard let src = script else {
            alert.messageText = String(localized: "Command line tool not found in the app bundle.")
            alert.runModal(); return
        }
        guard let dir = candidateDirs().first else {
            alert.messageText = String(localized: "No writable folder on your PATH")
            alert.informativeText = String(localized: "Run this in Terminal:\n\nsudo cp \"\(src.path)\" /usr/local/bin/explorermac")
            alert.runModal(); return
        }
        let dest = dir.appending(path: "explorermac")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            alert.messageText = String(localized: "Installed ‘explorermac’")
            alert.informativeText = String(localized: "Copied to \(dest.path).\n\nTry it in Terminal:\n\nexplorermac /Users")
        } catch {
            alert.messageText = String(localized: "Couldn't install")
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
