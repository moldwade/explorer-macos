import Testing
import Foundation
@testable import Explorer

@MainActor struct ServerTests {
    @Test func sameServerIgnoresUserCaseAndSlashes() {
        let a = URL(string: "smb://tugay@Ubuntu.local/Share/")!
        #expect(ExplorerState.sameServer(a, URL(string: "smb://ubuntu.local/share")!))
        #expect(!ExplorerState.sameServer(a, URL(string: "smb://ubuntu.local/other")!))
        #expect(!ExplorerState.sameServer(a, URL(string: "afp://ubuntu.local/share")!))
    }

    @Test func passwordsAreNeverSaved() {
        let u = ExplorerState.withoutPassword(URL(string: "smb://tugay:secret@10.0.0.5/data")!)
        #expect(u.absoluteString == "smb://tugay@10.0.0.5/data")
    }

    @Test func sidebarTitle() {
        #expect(SidebarView.serverTitle(URL(string: "smb://10.0.0.5/Dosyalar")!) == "Dosyalar (10.0.0.5)")
        #expect(SidebarView.serverTitle(URL(string: "smb://ubuntu.local")!) == "ubuntu.local")
    }
}
