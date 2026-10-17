import Foundation
import Security

/// A paired scanix500-server. Its token lives in a SecretStore (the Keychain), never in this record.
public struct RemoteServer: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var fingerprint: String

    public init(name: String, host: String, port: Int, fingerprint: String) {
        self.id = String(fingerprint.prefix(16))
        self.name = name; self.host = host; self.port = port; self.fingerprint = fingerprint
    }
}

public protocol SecretStore: Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String, for account: String) throws
    func delete(_ account: String)
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func get(_ account: String) -> String? { lock.withLock { values[account] } }
    public func set(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func delete(_ account: String) { lock.withLock { values[account] = nil } }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let defaultService = "com.aarneaarebye.dossiary-scan-helper.remote"
    private let service: String

    public init(service: String = KeychainSecretStore.defaultService) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for account: String) throws {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProtocolError(500, "Couldn't save the network scanner's key in the Keychain (\(status)).")
        }
    }

    public func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// The paired network scanners (remote-servers.json in Application Support); fileURL nil keeps them in memory.
public final class RemoteServerStore: @unchecked Sendable {
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dossiary-scan-helper")
            .appendingPathComponent("remote-servers.json")
    }

    private let fileURL: URL?
    private let secrets: SecretStore
    private let lock = NSLock()
    private var list: [RemoteServer] = []

    public init(fileURL: URL?, secrets: SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([RemoteServer].self, from: data) {
            list = saved
        }
    }

    public var servers: [RemoteServer] { lock.withLock { list } }

    public func token(for id: String) -> String? { secrets.get(id) }

    public func add(_ server: RemoteServer, token: String) throws {
        try secrets.set(token, for: server.id)
        try lock.withLock {
            list.removeAll { $0.id == server.id }
            list.append(server)
            try save()
        }
    }

    public func remove(id: String) throws {
        secrets.delete(id)
        try lock.withLock {
            list.removeAll { $0.id == id }
            try save()
        }
    }

    /// Call with the lock held.
    private func save() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: fileURL, options: .atomic)
    }
}
