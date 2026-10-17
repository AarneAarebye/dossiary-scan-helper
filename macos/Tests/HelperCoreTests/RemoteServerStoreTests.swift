import Foundation
import Testing
@testable import HelperCore

private let fp = "0AC646A4E3664417C73EEB6A9F99925AD4275F0A198302289B943C82E539102A"

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("remote-servers.json")
}

@Test func serverIdComesFromTheFingerprint() {
    #expect(RemoteServer(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp).id == "0AC646A4E3664417")
}

@Test func addListTokenRemoveAndReload() throws {
    let file = tempFile(), secrets = MemorySecretStore()
    let store = RemoteServerStore(fileURL: file, secrets: secrets)
    let server = RemoteServer(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    try store.add(server, token: "secret-token")
    #expect(store.servers == [server])
    #expect(store.token(for: server.id) == "secret-token")
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("secret-token"))
    #expect(RemoteServerStore(fileURL: file, secrets: secrets).servers == [server])
    try store.remove(id: server.id)
    #expect(store.servers.isEmpty && store.token(for: server.id) == nil)
    #expect(RemoteServerStore(fileURL: file, secrets: secrets).servers.isEmpty)
}

@Test func addingTheSameServerAgainReplacesIt() throws {
    let store = RemoteServerStore(fileURL: nil, secrets: MemorySecretStore())
    try store.add(RemoteServer(name: "old", host: "a.local", port: 8767, fingerprint: fp), token: "1")
    try store.add(RemoteServer(name: "new", host: "b.local", port: 8767, fingerprint: fp), token: "2")
    #expect(store.servers.map(\.name) == ["new"] && store.token(for: "0AC646A4E3664417") == "2")
}
