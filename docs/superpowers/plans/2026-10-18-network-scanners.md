# Network Scanners in the macOS Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dossiary Scan Helper lists scanix500-server scanners on the local network next to its own, pairs with a server once (by its Scan button or a code), and forwards scans and background-OCR jobs to it — part 2 of iX500's `docs/superpowers/specs/2026-10-17-pi-scan-server-design.md`.

**Architecture:** `RemoteScanners` sits beside the existing `ScannerBackend`: the `Router` merges its scanners into `GET /scanners` and hands it every `POST /scan` for a `remote:` scanner and every `GET /ocr/remote.…` job, forwarding the server's answer almost unchanged (it already speaks protocol version 2). Every connection goes through `URLSessionRemoteTransport`, which pins the server's certificate fingerprint (SHA-256 of the DER). Paired servers live in `remote-servers.json`, their tokens in the Keychain. Discovery uses Bonjour (`_dossiary-scan._tcp`), pairing a small panel opened from the menu.

**Tech Stack:** Swift 6 tools (language mode 5), Foundation `URLSession`, Security (Keychain, `SecTrust`), CryptoKit, `NetServiceBrowser`, AppKit, swift-testing.

## Global Constraints

- Dossiary is unchanged; it still talks only to the helper on `127.0.0.1`.
- Remote scanner ids: `remote:<serverID>:<the server's scanner id>`; names: `<the server's name> (<server name>)`. `serverID` = the first 16 hex digits of the server's certificate fingerprint.
- Remote OCR job ids handed to Dossiary: `remote.<serverID>.<the server's job id>`.
- Fingerprint: SHA-256 of the leaf certificate's DER, 64 uppercase hex; shown as the first 32 in 8 groups of 4 joined by `-` (as `scanix500-server` prints it).
- A connection whose certificate doesn't match the pinned fingerprint is refused, never trusted silently.
- Bonjour service type `_dossiary-scan._tcp`; default port 8767.
- Timeouts: listing 3 s per server, OCR polls 30 s, scans 1800 s, pairing calls 10 s.
- Button pairing: poll `GET /pair/button/<id>` every 2 s, at most 65 times; 408 → timed out, 409 → another computer asked at the same time, 429 → too many requests.
- Tokens are stored in the Keychain (service `com.aarneaarebye.dossiary-scan-helper.remote`, account = serverID), never in the JSON file.
- Fake-scanner mode (`--fake-scanners`) has no network scanners.
- Tests: `swift test` in `macos/`. Every new public type in `HelperCore` gets swift-testing tests; AppKit UI is checked by hand.

---

### Task 1: Pinned HTTPS transport and fingerprints

**Files:**
- Create: `macos/Sources/HelperCore/RemoteTransport.swift`
- Modify: `macos/Sources/HelperCore/Model.swift` (`ScannerInfo.init?(json:)`)
- Test: `macos/Tests/HelperCoreTests/RemoteTransportTests.swift`

**Interfaces:**
- Produces: `RemoteFingerprint.sha256Hex(_ der: Data) -> String`, `.display(_ hex: String) -> String`, `.accepts(observed: String, pin: String?) -> Bool`; `RemoteError` (`.unreachable(String)`, `.certificateChanged(seen: String)`); `RemoteRequest(method:path:token:body:timeout:)`; `RemoteReply(status:body:fingerprint:)` with `json: [String: Any]?`; `protocol RemoteTransport { func send(_ request: RemoteRequest) async throws -> RemoteReply }`; `URLSessionRemoteTransport(host: String, port: Int, pin: String?)`; `ScannerInfo(json: [String: Any])` (failable).

- [ ] **Step 1: Failing tests** — `RemoteTransportTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

@Test func fingerprintIsUppercaseSHA256OfTheDER() {
    #expect(RemoteFingerprint.sha256Hex(Data()) == "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
}

@Test func fingerprintDisplayIsEightGroupsOfFour() {
    let hex = "0AC646A4E3664417C73EEB6A9F99925AD4275F0A198302289B943C82E539102A"
    #expect(RemoteFingerprint.display(hex) == "0AC6-46A4-E366-4417-C73E-EB6A-9F99-925A")
}

@Test func pinRules() {
    #expect(RemoteFingerprint.accepts(observed: "AB", pin: nil))
    #expect(RemoteFingerprint.accepts(observed: "AB", pin: "AB"))
    #expect(!RemoteFingerprint.accepts(observed: "AB", pin: "CD"))
}

@Test func scannerInfoFromServerJSON() {
    let json: [String: Any] = ["id": "sane:ix500", "name": "ScanSnap iX500", "sources": ["feeder"], "duplex": true,
                               "colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600],
                               "extras": ["splitOnBlank", "skipBlankPages"], "ocr": ["languages": ["deu", "eng"]]]
    let info = ScannerInfo(json: json)
    #expect(info == ScannerInfo(id: "sane:ix500", name: "ScanSnap iX500", sources: [.feeder], duplex: true,
                                colorModes: [.color, .gray, .bw], resolutions: [150, 300, 600],
                                extras: ["splitOnBlank", "skipBlankPages"], ocrLanguages: ["deu", "eng"]))
    #expect(ScannerInfo(json: ["name": "no id"]) == nil)
}

@Test func errorsReadForAPerson() {
    #expect(RemoteError.certificateChanged(seen: "0AC646A4E3664417C73EEB6A9F99925A").errorDescription!
        .contains("0AC6-46A4-E366-4417-C73E-EB6A-9F99-925A"))
}
```

- [ ] **Step 2: Run** — `cd macos && swift test --filter RemoteTransportTests` → compile errors (types missing).

- [ ] **Step 3: Implement** — `RemoteTransport.swift`:

```swift
import CryptoKit
import Foundation
import Security

/// A scanix500-server's certificate fingerprint: SHA-256 of the certificate's DER bytes, uppercase hex.
/// The helper pins it when it pairs and refuses any other certificate afterwards.
public enum RemoteFingerprint {
    public static func sha256Hex(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// The first 128 bits in 8 groups of 4, the way `scanix500-server status` prints it.
    public static func display(_ hex: String) -> String {
        let head = Array(hex.prefix(32))
        return stride(from: 0, to: head.count, by: 4)
            .map { String(head[$0..<min($0 + 4, head.count)]) }
            .joined(separator: "-")
    }

    /// No pin yet (while pairing, the person compares the fingerprint) or exactly the pinned one.
    public static func accepts(observed: String, pin: String?) -> Bool { pin == nil || pin == observed }
}

public enum RemoteError: LocalizedError, Equatable, Sendable {
    case unreachable(String)
    case certificateChanged(seen: String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return "The network scanner can't be reached (\(detail))."
        case .certificateChanged(let seen):
            return "The network scanner presented a different certificate (\(RemoteFingerprint.display(seen))) than when it "
                + "was paired. If it was reinstalled, remove it in Dossiary Scan Helper and add it again."
        }
    }
}

public struct RemoteRequest: Sendable {
    public var method: String
    public var path: String
    public var token: String?
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, path: String, token: String? = nil, body: Data? = nil, timeout: TimeInterval) {
        self.method = method; self.path = path; self.token = token; self.body = body; self.timeout = timeout
    }
}

public struct RemoteReply: Sendable {
    public var status: Int
    public var body: Data
    /// The certificate fingerprint this answer came with.
    public var fingerprint: String

    public init(status: Int, body: Data, fingerprint: String) {
        self.status = status; self.body = body; self.fingerprint = fingerprint
    }

    public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

public protocol RemoteTransport: Sendable {
    func send(_ request: RemoteRequest) async throws -> RemoteReply
}

/// Accepts the server's self-signed certificate only by its pinned fingerprint (or, with no pin, records it).
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: String?
    private let lock = NSLock()
    private var seen: String?

    init(pin: String?) { self.pin = pin }

    var observed: String? { lock.withLock { seen } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = RemoteFingerprint.sha256Hex(SecCertificateCopyData(leaf) as Data)
        lock.withLock { seen = fingerprint }
        if RemoteFingerprint.accepts(observed: fingerprint, pin: pin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public final class URLSessionRemoteTransport: RemoteTransport, @unchecked Sendable {
    private let base: URL
    private let delegate: PinningDelegate
    private let session: URLSession

    public init(host: String, port: Int, pin: String?) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        base = components.url ?? URL(string: "https://invalid.invalid")!
        delegate = PinningDelegate(pin: pin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: RemoteRequest) async throws -> RemoteReply {
        guard let url = URL(string: request.path, relativeTo: base) else { throw RemoteError.unreachable("bad address") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        if let token = request.token { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return RemoteReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data,
                               fingerprint: delegate.observed ?? "")
        } catch {
            if let seen = delegate.observed, !RemoteFingerprint.accepts(observed: seen, pin: delegate.pin) {
                throw RemoteError.certificateChanged(seen: seen)
            }
            throw RemoteError.unreachable(error.localizedDescription)
        }
    }
}
```

In `Model.swift`, add after `ScannerInfo`'s `json` property (inside the struct):

```swift
    /// A scanner as another helper (scanix500-server) lists it in GET /scanners.
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        let ocr = json["ocr"] as? [String: Any]
        self.init(id: id, name: name,
                  sources: (json["sources"] as? [String] ?? []).compactMap(Source.init(rawValue:)),
                  duplex: json["duplex"] as? Bool ?? false,
                  colorModes: (json["colorModes"] as? [String] ?? []).compactMap(ColorMode.init(rawValue:)),
                  resolutions: json["resolutions"] as? [Int] ?? [],
                  extras: json["extras"] as? [String] ?? [],
                  ocrLanguages: ocr?["languages"] as? [String] ?? [])
    }
```

- [ ] **Step 4: Run** — `swift test --filter RemoteTransportTests` → 5 passed; `swift test` → all pass.

- [ ] **Step 5: Commit** — `git add macos/Sources/HelperCore/RemoteTransport.swift macos/Sources/HelperCore/Model.swift macos/Tests/HelperCoreTests/RemoteTransportTests.swift && git commit -m "Network scanners: pinned HTTPS transport and certificate fingerprints"`

---

### Task 2: Paired servers and their tokens

**Files:**
- Create: `macos/Sources/HelperCore/RemoteServerStore.swift`
- Test: `macos/Tests/HelperCoreTests/RemoteServerStoreTests.swift`

**Interfaces:**
- Produces: `RemoteServer(name:host:port:fingerprint:)` (Codable, `id` = fingerprint prefix 16); `protocol SecretStore` (`get(_:)`, `set(_:for:)`, `delete(_:)`); `MemorySecretStore`, `KeychainSecretStore(service:)`; `RemoteServerStore(fileURL: URL?, secrets: SecretStore)` with `servers: [RemoteServer]`, `add(_:token:) throws`, `remove(id:) throws`, `token(for:) -> String?`, `static defaultFileURL`.

- [ ] **Step 1: Failing tests** — `RemoteServerStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run** — `swift test --filter RemoteServerStoreTests` → compile errors.

- [ ] **Step 3: Implement** — `RemoteServerStore.swift`:

```swift
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
```

- [ ] **Step 4: Run** — `swift test --filter RemoteServerStoreTests` → 3 passed; `swift test` → all pass.

- [ ] **Step 5: Commit** — `git add macos/Sources/HelperCore/RemoteServerStore.swift macos/Tests/HelperCoreTests/RemoteServerStoreTests.swift && git commit -m "Network scanners: paired servers, tokens in the Keychain"`

---

### Task 3: Listing, scanning and OCR jobs through a server

**Files:**
- Create: `macos/Sources/HelperCore/RemoteScanners.swift`, `macos/Tests/HelperCoreTests/RemoteTestSupport.swift`
- Test: `macos/Tests/HelperCoreTests/RemoteScannersTests.swift`

**Interfaces:**
- Consumes: Task 1 and 2 types.
- Produces: `RemoteStatus` (`.connected`, `.needsPairing`, `.unreachable`, `.certificateChanged`); `RemoteScanners(store:transport:log:)` where `transport: @Sendable (RemoteServer) -> RemoteTransport`; `listScanners() async -> [ScannerInfo]`; `statuses: [String: RemoteStatus]` (by server id); `owns(_ scannerID: String) -> Bool`; `isRemoteJob(_ id: String) -> Bool`; `scan(scannerID:settings:) async throws -> (Int, [String: Any])`; `fetchOCR(_ id: String) async -> (Int, [String: Any])`. Test helper `FakeTransport(fingerprint:handler:)` with `sent`.

- [ ] **Step 1: Test support** — `RemoteTestSupport.swift`:

```swift
import Foundation
@testable import HelperCore

/// Answers RemoteRequests from a closure: (status, JSON object) or a thrown error.
final class FakeTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RemoteRequest] = []
    let fingerprint: String
    let handler: @Sendable (RemoteRequest) throws -> (Int, Any)

    init(fingerprint: String = String(repeating: "AB", count: 32),
         handler: @escaping @Sendable (RemoteRequest) throws -> (Int, Any)) {
        self.fingerprint = fingerprint; self.handler = handler
    }

    var sent: [RemoteRequest] { lock.withLock { requests } }

    func send(_ request: RemoteRequest) async throws -> RemoteReply {
        lock.withLock { requests.append(request) }
        let (status, object) = try handler(request)
        return RemoteReply(status: status, body: try JSONSerialization.data(withJSONObject: object), fingerprint: fingerprint)
    }
}

let piScanner: [String: Any] = ["id": "sane:ix500", "name": "ScanSnap iX500", "sources": ["feeder"], "duplex": true,
                                "colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600],
                                "extras": ["splitOnBlank", "skipBlankPages"], "ocr": ["languages": ["deu", "eng"]]]

func pairedStore(name: String = "scanner", fingerprint: String = String(repeating: "AB", count: 32)) -> (RemoteServerStore, RemoteServer) {
    let store = RemoteServerStore(fileURL: nil, secrets: MemorySecretStore())
    let server = RemoteServer(name: name, host: "\(name).local", port: 8767, fingerprint: fingerprint)
    try! store.add(server, token: "tok-\(name)")
    return (store, server)
}
```

- [ ] **Step 2: Failing tests** — `RemoteScannersTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private let settings = ScanSettings(source: .feeder, duplex: true, colorMode: .color, resolution: 300,
                                    extras: ["skipBlankPages": true], ocr: true, ocrLanguages: ["deu"])

@Test func listsTheServersScannersUnderItsOwnName() async {
    let (store, server) = pairedStore()
    let transport = FakeTransport { _ in (200, ["scanners": [piScanner]]) }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    let list = await remote.listScanners()
    #expect(list.map(\.id) == ["remote:\(server.id):sane:ix500"])
    #expect(list.map(\.name) == ["ScanSnap iX500 (scanner)"])
    #expect(list.first?.ocrLanguages == ["deu", "eng"])
    #expect(transport.sent.first?.path == "/scanners" && transport.sent.first?.token == "tok-scanner")
    #expect(remote.statuses[server.id] == .connected)
}

@Test func unpairedUnreachableAndChangedServersListNothing() async {
    let cases: [(@Sendable (RemoteRequest) throws -> (Int, Any), RemoteStatus)] = [
        ({ _ in (401, ["ok": false, "message": "not paired"]) }, .needsPairing),
        ({ _ in throw RemoteError.unreachable("timed out") }, .unreachable),
        ({ _ in throw RemoteError.certificateChanged(seen: "CD") }, .certificateChanged),
    ]
    for (handler, expected) in cases {
        let (store, server) = pairedStore()
        let remote = RemoteScanners(store: store, transport: { _ in FakeTransport(handler: handler) })
        #expect(await remote.listScanners().isEmpty)
        #expect(remote.statuses[server.id] == expected)
    }
}

@Test func scanIsForwardedAndItsOcrJobsRenamed() async throws {
    let (store, server) = pairedStore()
    let transport = FakeTransport { request in
        (200, ["ok": true, "partial": false, "message": "2 pages scanned.",
               "files": [["name": "scan_1.pdf", "pages": 2, "data": "JVBERg==", "ocrJob": "job_123-x"]]])
    }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    #expect(remote.owns("remote:\(server.id):sane:ix500") && !remote.owns("ica:1234"))
    let (status, body) = try await remote.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings)
    #expect(status == 200)
    let file = (body["files"] as? [[String: Any]])?.first
    #expect(file?["ocrJob"] as? String == "remote.\(server.id).job_123-x")
    #expect(file?["data"] as? String == "JVBERg==")
    let sent = try #require(transport.sent.first)
    #expect(sent.method == "POST" && sent.path == "/scan" && sent.timeout == 1800)
    let forwarded = try #require((try? JSONSerialization.jsonObject(with: sent.body ?? Data())) as? [String: Any])
    #expect(forwarded["scanner"] as? String == "sane:ix500")
    #expect(forwarded["ocr"] as? Bool == true && forwarded["ocrLanguages"] as? [String] == ["deu"])
    #expect((forwarded["extras"] as? [String: Bool])?["skipBlankPages"] == true)
}

@Test func scanErrorsBecomeProtocolErrors() async {
    let (store, server) = pairedStore()
    let unreachable = RemoteScanners(store: store, transport: { _ in FakeTransport { _ in throw RemoteError.unreachable("offline") } })
    await #expect(throws: ProtocolError.self) { try await unreachable.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings) }
    let unpaired = RemoteScanners(store: store, transport: { _ in FakeTransport { _ in (401, ["ok": false]) } })
    do {
        _ = try await unpaired.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings)
        Issue.record("expected an error")
    } catch let error as ProtocolError {
        #expect(error.status == 503 && error.message.contains("Add network scanner"))
    } catch { Issue.record("\(error)") }
}

@Test func busyAnswersPassThrough() async throws {
    let (store, server) = pairedStore()
    let remote = RemoteScanners(store: store, transport: { _ in FakeTransport { _ in (409, ["ok": false, "partial": false, "message": "A scan is already running."]) } })
    let (status, body) = try await remote.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings)
    #expect(status == 409 && body["message"] as? String == "A scan is already running.")
}

@Test func ocrJobsGoToTheirServer() async {
    let (store, server) = pairedStore()
    let transport = FakeTransport { request in
        request.path == "/ocr/job_123-x" ? (200, ["ok": true, "files": [["name": "scan_1.pdf", "pages": 2, "data": "JVBERg=="]]])
                                         : (404, ["ok": false])
    }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    #expect(remote.isRemoteJob("remote.\(server.id).job_123-x") && !remote.isRemoteJob("abcDEF"))
    let (status, body) = await remote.fetchOCR("remote.\(server.id).job_123-x")
    #expect(status == 200 && (body["files"] as? [[String: Any]])?.count == 1)
    #expect(await remote.fetchOCR("remote.0000000000000000.job").0 == 404)
}
```

- [ ] **Step 3: Run** — `swift test --filter RemoteScannersTests` → compile errors.

- [ ] **Step 4: Implement** — `RemoteScanners.swift`:

```swift
import Foundation

public enum RemoteStatus: Equatable, Sendable { case connected, needsPairing, unreachable, certificateChanged }

/// The paired scanix500-servers' scanners: listed beside the helper's own and used through the server, which
/// already speaks protocol version 2 -- so answers are passed on, only ids and job ids renamed.
public final class RemoteScanners: @unchecked Sendable {
    public typealias TransportFactory = @Sendable (RemoteServer) -> RemoteTransport
    public static let idPrefix = "remote:"
    public static let jobPrefix = "remote."

    private let store: RemoteServerStore
    private let transport: TransportFactory
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var status: [String: RemoteStatus] = [:]

    public init(store: RemoteServerStore,
                transport: @escaping TransportFactory = { URLSessionRemoteTransport(host: $0.host, port: $0.port, pin: $0.fingerprint) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store; self.transport = transport; self.log = log
    }

    public var servers: [RemoteServer] { store.servers }
    public var statuses: [String: RemoteStatus] { lock.withLock { status } }

    private func setStatus(_ value: RemoteStatus, _ server: RemoteServer) {
        let changed = lock.withLock { () -> Bool in
            defer { status[server.id] = value }
            return status[server.id] != value
        }
        if changed { log("Network scanner \(server.name) (\(server.host)): \(value).") }
    }

    public func owns(_ scannerID: String) -> Bool { scannerID.hasPrefix(Self.idPrefix) }
    public func isRemoteJob(_ id: String) -> Bool { id.hasPrefix(Self.jobPrefix) }

    public func listScanners() async -> [ScannerInfo] {
        await withTaskGroup(of: [ScannerInfo].self) { group in
            for server in store.servers { group.addTask { await self.list(server) } }
            var all: [ScannerInfo] = []
            for await part in group { all += part }
            return all.sorted { $0.name < $1.name }
        }
    }

    private func list(_ server: RemoteServer) async -> [ScannerInfo] {
        guard let token = store.token(for: server.id) else { setStatus(.needsPairing, server); return [] }
        do {
            let reply = try await transport(server).send(RemoteRequest(method: "GET", path: "/scanners", token: token, timeout: 3))
            if reply.status == 401 { setStatus(.needsPairing, server); return [] }
            guard reply.status == 200, let list = reply.json?["scanners"] as? [[String: Any]] else {
                setStatus(.unreachable, server); return []
            }
            setStatus(.connected, server)
            return list.compactMap(ScannerInfo.init(json:)).map { scanner in
                var scanner = scanner
                scanner.id = "\(Self.idPrefix)\(server.id):\(scanner.id)"
                scanner.name = "\(scanner.name) (\(server.name))"
                return scanner
            }
        } catch RemoteError.certificateChanged {
            setStatus(.certificateChanged, server); return []
        } catch {
            setStatus(.unreachable, server); return []
        }
    }

    /// "remote:<server>:<scanner>" → the server and its own scanner id.
    private func locate(_ scannerID: String) -> (RemoteServer, String)? {
        let rest = scannerID.dropFirst(Self.idPrefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let serverID = String(rest[..<colon]), remoteID = String(rest[rest.index(after: colon)...])
        guard let server = store.servers.first(where: { $0.id == serverID }) else { return nil }
        return (server, remoteID)
    }

    private static func needsPairing(_ server: RemoteServer) -> ProtocolError {
        ProtocolError(503, "\(server.name) needs to be paired again: choose “Add network scanner…” in Dossiary Scan Helper.")
    }

    public func scan(scannerID: String, settings: ScanSettings) async throws -> (Int, [String: Any]) {
        guard let (server, remoteID) = locate(scannerID), let token = store.token(for: server.id) else {
            throw ProtocolError(503, "This network scanner isn't set up in Dossiary Scan Helper any more.")
        }
        var body: [String: Any] = ["scanner": remoteID, "source": settings.source.rawValue, "duplex": settings.duplex,
                                   "colorMode": settings.colorMode.rawValue, "resolution": settings.resolution,
                                   "extras": settings.extras]
        if settings.ocr { body["ocr"] = true; body["ocrLanguages"] = settings.ocrLanguages }
        let reply: RemoteReply
        do {
            reply = try await transport(server).send(RemoteRequest(method: "POST", path: "/scan", token: token,
                                                                   body: try JSONSerialization.data(withJSONObject: body),
                                                                   timeout: 1800))
        } catch let error as RemoteError {
            throw ProtocolError(503, "\(server.name): \(error.errorDescription ?? "can't be reached.")")
        }
        if reply.status == 401 { throw Self.needsPairing(server) }
        guard var object = reply.json else {
            throw ProtocolError(500, "\(server.name) gave an answer the scan helper couldn't read.")
        }
        if let files = object["files"] as? [[String: Any]] {
            object["files"] = files.map { file -> [String: Any] in
                var file = file
                if let job = file["ocrJob"] as? String { file["ocrJob"] = "\(Self.jobPrefix)\(server.id).\(job)" }
                return file
            }
        }
        return (reply.status, object)
    }

    public func fetchOCR(_ id: String) async -> (Int, [String: Any]) {
        let unknown = (404, Router.errorBody("This text recognition job is unknown, already fetched, or expired."))
        let rest = id.dropFirst(Self.jobPrefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return unknown }
        let serverID = String(rest[..<dot]), job = String(rest[rest.index(after: dot)...])
        guard !job.isEmpty, let server = store.servers.first(where: { $0.id == serverID }),
              let token = store.token(for: server.id) else { return unknown }
        do {
            let reply = try await transport(server).send(RemoteRequest(method: "GET", path: "/ocr/\(job)", token: token, timeout: 30))
            if reply.status == 401 { return (503, Router.errorBody(Self.needsPairing(server).message)) }
            return (reply.status, reply.json ?? Router.errorBody("\(server.name) gave an answer the scan helper couldn't read."))
        } catch {
            // 503 keeps Dossiary polling; after 10 minutes it makes the document searchable itself.
            return (503, Router.errorBody("\(server.name) can't be reached right now."))
        }
    }
}
```

- [ ] **Step 5: Run** — `swift test --filter RemoteScannersTests` → 6 passed; `swift test` → all pass.

- [ ] **Step 6: Commit** — `git add macos/Sources/HelperCore/RemoteScanners.swift macos/Tests/HelperCoreTests/RemoteTestSupport.swift macos/Tests/HelperCoreTests/RemoteScannersTests.swift && git commit -m "Network scanners: list, scan and OCR jobs through a paired scanix500-server"`

---

### Task 4: The router uses network scanners

**Files:**
- Modify: `macos/Sources/HelperCore/Router.swift`, `macos/Sources/HelperCore/HelperRuntime.swift`
- Test: `macos/Tests/HelperCoreTests/RouterTests.swift` (append)

**Interfaces:**
- Consumes: `RemoteScanners` (Task 3).
- Produces: `Router(backend:pairing:ocrJobs:ocrLanguages:remote:now:log:)` (new `remote: RemoteScanners? = nil` after `ocrLanguages`); `HelperRuntime.remote: RemoteScanners?`, `HelperRuntime.remoteStore: RemoteServerStore?`.

- [ ] **Step 1: Failing tests** — append to `RouterTests.swift`:

```swift
private func remoteRouter(handler: @escaping @Sendable (RemoteRequest) throws -> (Int, Any)) -> (Router, String, RemoteServer) {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    let (store, server) = pairedStore()
    let remote = RemoteScanners(store: store, transport: { _ in FakeTransport(handler: handler) })
    return (Router(backend: FakeBackend(), pairing: pairing, remote: remote), token, server)
}

@Test func networkScannersAreListedBesideLocalOnes() async {
    let (router, token, server) = remoteRouter { _ in (200, ["scanners": [piScanner]]) }
    let ids = ((object(await router.handle(req("GET", "/scanners", token: token)))["scanners"]) as? [[String: Any]] ?? [])
        .compactMap { $0["id"] as? String }
    #expect(ids.contains("remote:\(server.id):sane:ix500"))
    #expect(ids.contains { $0.hasPrefix("fake:") })
}

@Test func scansOnANetworkScannerAreForwarded() async {
    let (router, token, server) = remoteRouter { request in
        request.path == "/scanners" ? (200, ["scanners": [piScanner]])
            : (200, ["ok": true, "partial": false, "message": "1 page scanned.",
                     "files": [["name": "scan_1.pdf", "pages": 1, "data": "JVBERg==", "ocrJob": "j1"]]])
    }
    let body = #"{"scanner":"remote:\#(server.id):sane:ix500","source":"feeder","ocr":true,"ocrLanguages":["deu"]}"#
    let response = await router.handle(req("POST", "/scan", token: token, body: body))
    #expect(response.status == 200)
    let file = (object(response)["files"] as? [[String: Any]])?.first
    #expect(file?["ocrJob"] as? String == "remote.\(server.id).j1")
}

@Test func networkOcrJobsAreForwarded() async {
    let (router, token, server) = remoteRouter { _ in (202, ["ok": true, "state": "running", "position": 0]) }
    let response = await router.handle(req("GET", "/ocr/remote.\(server.id).j1", token: token))
    #expect(response.status == 202 && object(response)["state"] as? String == "running")
}
```

- [ ] **Step 2: Run** — `swift test --filter RouterTests` → compile error (`remote:` argument).

- [ ] **Step 3: Implement** — in `Router.swift`:
  - Add `private let remote: RemoteScanners?` and the init parameter `remote: RemoteScanners? = nil` (after `ocrLanguages`), assigned in the init body.
  - In `scan(_:origin:)`, directly after the `validate` line:

```swift
        if let remote, remote.owns(scanner.id) {
            log("Scanning with \(scanner.name) over the network: \(settings.source.rawValue), \(settings.colorMode.rawValue), \(settings.resolution) dpi\(settings.duplex ? ", both sides" : "")\(settings.ocr ? ", searchable" : "").")
            let (status, payload) = try await remote.scan(scannerID: scanner.id, settings: settings)
            log(payload["message"] as? String ?? "Network scan finished.")
            return .json(status, payload, origin: origin)
        }
```

  - In `ocr(_:origin:)`, as its first line:

```swift
        if let remote, remote.isRemoteJob(id) {
            let (status, body) = await remote.fetchOCR(id)
            return .json(status, body, origin: origin)
        }
```

  - In `scanners()`, return local plus network scanners:

```swift
    private func scanners() async -> [ScannerInfo] {
        let local = await backend.listScanners().map { scanner in
            var scanner = scanner
            if ocrJobs == nil { scanner.ocrLanguages = [] }
            else if scanner.ocrLanguages.isEmpty { scanner.ocrLanguages = ocrLanguages }
            return scanner
        }
        return local + (await remote?.listScanners() ?? [])
    }
```

  In `HelperRuntime.swift` add `public let remoteStore: RemoteServerStore?` and `public let remote: RemoteScanners?`; in the fake branch set both to `nil`; in the real branch

```swift
            let store = RemoteServerStore(fileURL: RemoteServerStore.defaultFileURL, secrets: KeychainSecretStore())
            remoteStore = store
            remote = RemoteScanners(store: store, log: write)
```

  (declare `write` before the branch) and pass `remote: remote` to `Router(...)`.

- [ ] **Step 4: Run** — `swift test` → all pass, including the conformance-style router tests (local behaviour unchanged).

- [ ] **Step 5: Commit** — `git add macos/Sources/HelperCore/Router.swift macos/Sources/HelperCore/HelperRuntime.swift macos/Tests/HelperCoreTests/RouterTests.swift && git commit -m "Network scanners: the router lists them and forwards their scans and OCR jobs"`

---

### Task 5: Discovery and pairing

**Files:**
- Create: `macos/Sources/HelperCore/RemotePairing.swift`, `macos/Sources/HelperCore/RemoteDiscovery.swift`
- Test: `macos/Tests/HelperCoreTests/RemotePairingTests.swift`

**Interfaces:**
- Produces: `RemoteProbe` (`name`, `host`, `port`, `fingerprint`); `PairingFailure` (`.notAScanServer`, `.timedOut`, `.conflict`, `.tooMany`, `.refused(String)`); `RemotePairing(transport: @Sendable (String, Int, String?) -> RemoteTransport, sleep: @Sendable (TimeInterval) async -> Void)` with `probe(host:port:) async throws -> RemoteProbe`, `pairByButton(_:client:) async throws -> String`, `pairByCode(_:code:client:) async throws -> String`; `DiscoveredServer(name:host:port:)`; `RemoteDiscovery` with `servers`, `onChange`, `start()`, `stop()`.

- [ ] **Step 1: Failing tests** — `RemotePairingTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private let fp = String(repeating: "AB", count: 32)

private func pairing(_ handler: @escaping @Sendable (RemoteRequest) throws -> (Int, Any)) -> (RemotePairing, FakeTransport) {
    let transport = FakeTransport(fingerprint: fp, handler: handler)
    return (RemotePairing(transport: { _, _, _ in transport }, sleep: { _ in }), transport)
}

private let health: [String: Any] = ["ok": true, "protocol": 2, "remote": true, "fingerprint": fp, "name": "scanner"]

@Test func probeReadsNameAndFingerprint() async throws {
    let (p, _) = pairing { _ in (200, health) }
    let probe = try await p.probe(host: "scanner.local", port: 8767)
    #expect(probe.name == "scanner" && probe.fingerprint == fp && probe.host == "scanner.local")
}

@Test func probeRefusesWhatIsNotAScanServer() async {
    let (p, _) = pairing { _ in (200, ["ok": true, "protocol": 2]) }
    await #expect(throws: PairingFailure.notAScanServer) { try await p.probe(host: "x.local", port: 8767) }
    let (q, _) = pairing { _ in (200, health.merging(["fingerprint": "CD"]) { $1 }) }  // claims another certificate
    await #expect(throws: PairingFailure.notAScanServer) { try await q.probe(host: "x.local", port: 8767) }
}

@Test func buttonPairingWaitsForThePress() async throws {
    let polls = Counter()
    let (p, transport) = pairing { request in
        if request.method == "POST" { return (202, ["request": "r1"]) }
        return polls.next() < 2 ? (202, ["state": "pending"]) : (200, ["ok": true, "token": "tok"])
    }
    let probe = RemoteProbe(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    #expect(try await p.pairByButton(probe, client: "Mac") == "tok")
    let first = try #require(transport.sent.first)
    #expect(first.path == "/pair/button")
    #expect(((try? JSONSerialization.jsonObject(with: first.body ?? Data())) as? [String: Any])?["client"] as? String == "Mac")
    #expect(transport.sent.dropFirst().allSatisfy { $0.path == "/pair/button/r1" })
}

@Test func buttonPairingFailures() async {
    let probe = RemoteProbe(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    for (status, failure) in [(408, PairingFailure.timedOut), (409, .conflict)] {
        let (p, _) = pairing { request in request.method == "POST" ? (202, ["request": "r1"]) : (status, ["ok": false]) }
        await #expect(throws: failure) { try await p.pairByButton(probe, client: "Mac") }
    }
    let (busy, _) = pairing { _ in (429, ["ok": false]) }
    await #expect(throws: PairingFailure.tooMany) { try await busy.pairByButton(probe, client: "Mac") }
}

@Test func codePairing() async throws {
    let probe = RemoteProbe(name: "scanner", host: "scanner.local", port: 8767, fingerprint: fp)
    let (ok, _) = pairing { _ in (200, ["ok": true, "token": "tok"]) }
    #expect(try await ok.pairByCode(probe, code: "123456", client: "Mac") == "tok")
    let (wrong, _) = pairing { _ in (403, ["ok": false, "message": "That code isn't right."]) }
    await #expect(throws: PairingFailure.refused("That code isn't right.")) {
        try await wrong.pairByCode(probe, code: "000000", client: "Mac")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
```

- [ ] **Step 2: Run** — `swift test --filter RemotePairingTests` → compile errors.

- [ ] **Step 3: Implement** — `RemotePairing.swift`:

```swift
import Foundation

public struct RemoteProbe: Equatable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let fingerprint: String
    public init(name: String, host: String, port: Int, fingerprint: String) {
        self.name = name; self.host = host; self.port = port; self.fingerprint = fingerprint
    }
}

public enum PairingFailure: LocalizedError, Equatable, Sendable {
    case notAScanServer, timedOut, conflict, tooMany, refused(String)

    public var errorDescription: String? {
        switch self {
        case .notAScanServer: return "That address doesn't answer like a scanix500 network scan server."
        case .timedOut: return "Nobody pressed the Scan button within 2 minutes. Try again."
        case .conflict: return "Another computer asked to pair at the same time. Try again, one computer at a time."
        case .tooMany: return "Too many pairing requests. Wait a minute, then try again."
        case .refused(let message): return message
        }
    }
}

/// Pairing with a scanix500-server: look at it first (its name and certificate fingerprint, for the person to
/// compare), then pair by the Scan button or a code -- both over a connection pinned to that fingerprint.
public final class RemotePairing: @unchecked Sendable {
    public typealias TransportFactory = @Sendable (_ host: String, _ port: Int, _ pin: String?) -> RemoteTransport
    public static let pollInterval: TimeInterval = 2
    public static let maxPolls = 65

    private let transport: TransportFactory
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(transport: @escaping TransportFactory = { URLSessionRemoteTransport(host: $0, port: $1, pin: $2) },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.transport = transport; self.sleep = sleep
    }

    public func probe(host: String, port: Int) async throws -> RemoteProbe {
        let reply = try await transport(host, port, nil).send(RemoteRequest(method: "GET", path: "/health", timeout: 10))
        guard reply.status == 200, let json = reply.json, json["remote"] as? Bool == true,
              let claimed = json["fingerprint"] as? String, claimed.uppercased() == reply.fingerprint else {
            throw PairingFailure.notAScanServer
        }
        return RemoteProbe(name: json["name"] as? String ?? host, host: host, port: port, fingerprint: reply.fingerprint)
    }

    private func body(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    public func pairByButton(_ probe: RemoteProbe, client: String) async throws -> String {
        let connection = transport(probe.host, probe.port, probe.fingerprint)
        let start = try await connection.send(RemoteRequest(method: "POST", path: "/pair/button",
                                                            body: body(["client": client]), timeout: 10))
        if start.status == 429 { throw PairingFailure.tooMany }
        guard start.status == 202, let request = start.json?["request"] as? String else {
            throw PairingFailure.refused(start.json?["message"] as? String ?? "The scan server refused to pair.")
        }
        for _ in 0..<Self.maxPolls {
            let reply = try await connection.send(RemoteRequest(method: "GET", path: "/pair/button/\(request)", timeout: 10))
            switch reply.status {
            case 200:
                if let token = reply.json?["token"] as? String { return token }
                throw PairingFailure.refused("The scan server answered without a key.")
            case 202: await sleep(Self.pollInterval)
            case 408: throw PairingFailure.timedOut
            case 409: throw PairingFailure.conflict
            default: throw PairingFailure.refused(reply.json?["message"] as? String ?? "Pairing failed.")
            }
        }
        throw PairingFailure.timedOut
    }

    public func pairByCode(_ probe: RemoteProbe, code: String, client: String) async throws -> String {
        let reply = try await transport(probe.host, probe.port, probe.fingerprint)
            .send(RemoteRequest(method: "POST", path: "/pair", body: body(["code": code, "client": client]), timeout: 10))
        if reply.status == 200, let token = reply.json?["token"] as? String { return token }
        throw PairingFailure.refused(reply.json?["message"] as? String ?? "Pairing failed.")
    }
}
```

`RemoteDiscovery.swift` (Bonjour; checked by hand, needs a run loop — the app starts it on the main thread):

```swift
import Foundation

public struct DiscoveredServer: Equatable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
}

/// Finds scanix500-servers announcing `_dossiary-scan._tcp` on the local network. Start it on the main thread.
public final class RemoteDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    public static let serviceType = "_dossiary-scan._tcp."
    public private(set) var servers: [DiscoveredServer] = []
    public var onChange: (() -> Void)?

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    public func start() {
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    public func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving = []
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        servers.removeAll { $0.name == service.name }
        onChange?()
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeAll { $0 === sender }
        guard let host = sender.hostName else { return }
        let found = DiscoveredServer(name: sender.name, host: host.hasSuffix(".") ? String(host.dropLast()) : host,
                                     port: sender.port)
        servers.removeAll { $0.name == found.name }
        servers.append(found)
        onChange?()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}
```

Add to `macos/Resources/Info.plist`, after `NSLocalNetworkUsageDescription`:

```xml
    <key>NSBonjourServices</key><array><string>_dossiary-scan._tcp</string></array>
```

- [ ] **Step 4: Run** — `swift test --filter RemotePairingTests` → 5 passed; `swift test` → all pass.

- [ ] **Step 5: Commit** — `git add macos/Sources/HelperCore/RemotePairing.swift macos/Sources/HelperCore/RemoteDiscovery.swift macos/Tests/HelperCoreTests/RemotePairingTests.swift macos/Resources/Info.plist && git commit -m "Network scanners: Bonjour discovery and pairing by button or code"`

---

### Task 6: Menu, the "Add network scanner" panel, docs

**Files:**
- Modify: `macos/Sources/HelperCore/MenuModel.swift`, `macos/Sources/App/AppDelegate.swift`, `PROTOCOL.md`, `README.md`
- Create: `macos/Sources/App/NetworkScannerPanel.swift`
- Test: `macos/Tests/HelperCoreTests/MenuModelTests.swift` (append)

**Interfaces:**
- Consumes: everything above.
- Produces: `MenuAction.addNetworkScanner`, `MenuAction.removeNetworkScanner(String)`; `NetworkServerEntry(id:name:status:)`; `MenuModel.entries(..., networkServers: [NetworkServerEntry]? = nil)`.

- [ ] **Step 1: Failing test** — append to `MenuModelTests.swift`:

```swift
@Test func networkScannersSection() {
    let entries = MenuModel.entries(scanners: [], port: 8766, fake: false, pairedCount: 0, startAtLogin: true,
                                    networkServers: [NetworkServerEntry(id: "0AC646A4E3664417", name: "scanner", status: .connected),
                                                     NetworkServerEntry(id: "1111111111111111", name: "attic", status: .needsPairing)])
    #expect(entries.contains(.info("scanner: connected")))
    #expect(entries.contains(.info("attic: needs pairing again")))
    #expect(entries.contains(.action("Remove “attic”", .removeNetworkScanner("1111111111111111"), checked: false, enabled: true)))
    #expect(entries.contains(.action("Add network scanner…", .addNetworkScanner, checked: false, enabled: true)))
    let fakeMode = MenuModel.entries(scanners: [], port: 8766, fake: true, pairedCount: 0, startAtLogin: nil)
    #expect(!fakeMode.contains(.action("Add network scanner…", .addNetworkScanner, checked: false, enabled: true)))
}
```

- [ ] **Step 2: Run** — `swift test --filter MenuModelTests` → compile errors.

- [ ] **Step 3: Menu model** — in `MenuModel.swift`:

```swift
public enum MenuAction: Equatable, Sendable {
    case pair, forget, startAtLogin, openLog, quit, addNetworkScanner
    case removeNetworkScanner(String)
}

public struct NetworkServerEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: RemoteStatus?
    public init(id: String, name: String, status: RemoteStatus?) { self.id = id; self.name = name; self.status = status }

    var statusText: String {
        switch status {
        case .connected: return "connected"
        case .needsPairing: return "needs pairing again"
        case .unreachable: return "can't be reached"
        case .certificateChanged: return "certificate changed, remove and add it again"
        case nil: return "checking…"
        }
    }
}
```

`entries(...)` gains `networkServers: [NetworkServerEntry]? = nil` as its last parameter, and after the browser-pairing actions (before the "Start at login" separator) adds:

```swift
        if let networkServers {
            entries.append(.separator)
            for server in networkServers {
                entries.append(.info("\(server.name): \(server.statusText)"))
                entries.append(.action("Remove “\(server.name)”", .removeNetworkScanner(server.id), checked: false, enabled: true))
            }
            entries.append(.action("Add network scanner…", .addNetworkScanner, checked: false, enabled: true))
        }
```

(`entries` must be declared `var` and built in two parts around this block, keeping the existing order otherwise.)

- [ ] **Step 4: Panel** — `macos/Sources/App/NetworkScannerPanel.swift`:

```swift
import AppKit
import HelperCore

/// "Add network scanner…": pick a scanix500-server found on the network (or type its address), check its
/// fingerprint, and pair by pressing the scanner's Scan button or with a code from `sudo scanix500-server pair`.
final class NetworkScannerPanel: NSPanel {
    private let store: RemoteServerStore
    private let pairing = RemotePairing()
    private let discovery = RemoteDiscovery()
    private let onPaired: () -> Void
    private let serverPopup = NSPopUpButton()
    private let addressField = NSTextField(string: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "Looking for scan servers on the network…")
    private let codeField = NSTextField(string: "")
    private let buttonPairButton = NSButton(title: "Pair with the Scan button", target: nil, action: nil)
    private let codePairButton = NSButton(title: "Pair with code", target: nil, action: nil)
    private var probe: RemoteProbe?
    private var busy = false

    init(store: RemoteServerStore, onPaired: @escaping () -> Void) {
        self.store = store
        self.onPaired = onPaired
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Add network scanner"
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        addressField.placeholderString = "or an address, e.g. scanner.local"
        codeField.placeholderString = "6-digit code"
        let connect = NSButton(title: "Connect", target: self, action: #selector(connectChosen))
        buttonPairButton.target = self; buttonPairButton.action = #selector(pairWithButton)
        codePairButton.target = self; codePairButton.action = #selector(pairWithCode)
        let codeRow = NSStackView(views: [codeField, codePairButton])
        let stack = NSStackView(views: [serverPopup, addressField, connect, detailLabel, buttonPairButton, codeRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        contentView = stack
        discovery.onChange = { [weak self] in self?.refreshPopup() }
        setPairingEnabled(false)
    }

    func show() {
        probe = nil
        detailLabel.stringValue = "Looking for scan servers on the network…"
        setPairingEnabled(false)
        discovery.start()
        refreshPopup()
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        discovery.stop()
        super.close()
    }

    private func refreshPopup() {
        serverPopup.removeAllItems()
        for server in discovery.servers {
            serverPopup.addItem(withTitle: server.name)
            serverPopup.lastItem?.representedObject = "\(server.host):\(server.port)"
        }
        if discovery.servers.isEmpty { serverPopup.addItem(withTitle: "No scan server found yet") }
    }

    private func setPairingEnabled(_ on: Bool) {
        buttonPairButton.isEnabled = on && !busy
        codePairButton.isEnabled = on && !busy
        codeField.isEnabled = on && !busy
    }

    private func chosenAddress() -> (String, Int)? {
        let typed = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        let text = typed.isEmpty ? (serverPopup.selectedItem?.representedObject as? String ?? "") : typed
        guard !text.isEmpty else { return nil }
        if let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) {
            return (String(text[..<colon]), port)
        }
        return (text, 8767)
    }

    @objc private func connectChosen() {
        guard let (host, port) = chosenAddress() else { detailLabel.stringValue = "Choose a scan server or type its address."; return }
        detailLabel.stringValue = "Connecting to \(host)…"
        Task { @MainActor in
            do {
                let found = try await pairing.probe(host: host, port: port)
                probe = found
                detailLabel.stringValue = "\(found.name) at \(host)\nFingerprint: \(RemoteFingerprint.display(found.fingerprint))\n"
                    + "It should match “scanix500-server status” on the Pi. Then press the button below and, within "
                    + "2 minutes, the Scan button on the iX500 — or enter a code from “sudo scanix500-server pair”."
                setPairingEnabled(true)
            } catch {
                probe = nil
                detailLabel.stringValue = error.localizedDescription
                setPairingEnabled(false)
            }
        }
    }

    @objc private func pairWithButton() {
        guard let probe else { return }
        detailLabel.stringValue = "Press the Scan button on the iX500 now (2 minutes)…"
        run { [pairing] in try await pairing.pairByButton(probe, client: Host.current().localizedName ?? "Mac") }
    }

    @objc private func pairWithCode() {
        guard let probe else { return }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        detailLabel.stringValue = "Pairing…"
        run { [pairing] in try await pairing.pairByCode(probe, code: code, client: Host.current().localizedName ?? "Mac") }
    }

    private func run(_ pair: @escaping () async throws -> String) {
        guard let probe else { return }
        busy = true
        setPairingEnabled(true)
        Task { @MainActor in
            defer { busy = false; setPairingEnabled(self.probe != nil) }
            do {
                let token = try await pair()
                try store.add(RemoteServer(name: probe.name, host: probe.host, port: probe.port,
                                           fingerprint: probe.fingerprint), token: token)
                Log.shared.write("Paired with the network scanner \(probe.name) (\(probe.host)).")
                onPaired()
                close()
            } catch {
                detailLabel.stringValue = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 5: AppDelegate** — add `private lazy var networkPanel: NetworkScannerPanel? = runtime.remoteStore.map { NetworkScannerPanel(store: $0) { [weak self] in self?.refreshScanners() } }`; in `refreshScanners()` the list now comes from the router's view, so after `runtime.backend.listScanners()` also append `await runtime.remote?.listScanners() ?? []`; in `menuNeedsUpdate` pass

```swift
networkServers: runtime.remote.map { remote in
    remote.servers.map { NetworkServerEntry(id: $0.id, name: $0.name, status: remote.statuses[$0.id]) }
}
```

and in `menuItemChosen` handle:

```swift
        case .addNetworkScanner:
            networkPanel?.show()
        case .removeNetworkScanner(let id):
            do {
                try runtime.remoteStore?.remove(id: id)
                Log.shared.write("Removed a network scanner.")
                refreshScanners()
            } catch {
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
```

Build: `swift build` (no warnings-as-errors; fix any error).

- [ ] **Step 6: Docs** — `PROTOCOL.md`, a new section before "## Errors":

```markdown
## Network scan servers (scanix500-server)

A helper may also list scanners of a **scanix500-server** on the local
network (a Raspberry Pi with an iX500). Dossiary never talks to the server:
the helper lists its scanners as `remote:<server>:<id>`, named
"<scanner> (<server name>)", forwards `POST /scan` and returns the answer
with each `ocrJob` renamed `remote.<server>.<job>`, and forwards
`GET /ocr/remote.<server>.<job>`. An unreachable server answers OCR polls
with 503, so Dossiary keeps polling and eventually falls back to its own OCR.

The server listens over **HTTPS** (port 8767 by default) with a self-signed
certificate; the helper pins its SHA-256 fingerprint when pairing and refuses
any other certificate. It is found with Bonjour (`_dossiary-scan._tcp`). It
refuses any request with an `Origin` header (no web pages), and its
`GET /health` adds `"remote": true`, `"fingerprint"` (64 hex digits) and
`"name"`. Besides `POST /pair` (with a code from `sudo scanix500-server
pair`, valid 5 minutes) it offers **button pairing**: `POST /pair/button`
`{"client": "<name>"}` → `202 {"request": "<id>"}`; then
`GET /pair/button/<id>` → `202` while waiting, `200 {"token"}` once the
iX500's Scan button is pressed, `408` after 2 minutes, `409` when two
computers asked at once (both refused), `429` after 10 requests in a minute.
```

`README.md` (helper): under the macOS section, a short paragraph: "**Network scanners**: choose *Add network scanner…* in the menu to use an iX500 on a Raspberry Pi running scanix500-server (see iX500's `docs/raspberry-pi.md`). The helper finds it on the network, shows its certificate fingerprint, and pairs when you press the scanner's Scan button; it then appears in Dossiary as “ScanSnap iX500 (<name>)”."

- [ ] **Step 7: Run and commit** — `swift test` (all pass) and `swift build`; then
`git add macos/Sources macos/Tests PROTOCOL.md README.md && git commit -m "Network scanners: menu entries and the Add network scanner panel; protocol and README"`

- [ ] **Step 8: By hand with the real Pi** — `scripts/build-app.sh`, start the built app, *Add network scanner…*: the Pi is listed, Connect shows its fingerprint (compare with `scanix500-server status`), pair with the Scan button, the menu shows "<name>: connected"; in Dossiary 📷 Scan lists "ScanSnap iX500 (<name>)"; a duplex scan lands in the Inbox and becomes searchable a few minutes later. Then release (version bump, `scripts/sign-and-notarize.sh`, tag `macos-v0.3.0`) with the user's OK.
