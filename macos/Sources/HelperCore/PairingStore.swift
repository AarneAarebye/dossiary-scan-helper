import CryptoKit
import Foundation

/// Browser pairing (PROTOCOL.md "Pairing"). Thread-safe.
public final class PairingStore: @unchecked Sendable {
    public enum Mode { case fake; case real(fileURL: URL) }

    public static let fakeCode = "000000"
    public static let codeLifetime: TimeInterval = 120
    public static let maxAttempts = 5
    public static let maxClientLength = 200
    public static let refusedMessage =
        "That pairing code isn't valid. In the scan helper, choose “Pair a browser…” and enter the new code."

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dossiary-scan-helper")
            .appendingPathComponent("paired-browsers.json")
    }

    struct Browser: Codable { var tokenHash: String; var client: String?; var pairedAt: Date }
    struct SavedFile: Codable { var browsers: [Browser] }
    struct Window { var code: String; var opened: Date; var attemptsLeft: Int }

    private let lock = NSLock()
    private let mode: Mode
    private let now: @Sendable () -> Date
    private let makeCode: @Sendable () -> String
    private var browsers: [Browser] = []
    private var window: Window?

    public init(mode: Mode, now: @escaping @Sendable () -> Date = { Date() },
                makeCode: @escaping @Sendable () -> String = PairingStore.randomCode) {
        self.mode = mode
        self.now = now
        self.makeCode = makeCode
        if case .real(let url) = mode, let data = try? Data(contentsOf: url),
           let saved = try? PairingStore.decoder.decode(SavedFile.self, from: data) {
            browsers = saved.browsers
        }
    }

    public var isFake: Bool { if case .fake = mode { return true } else { return false } }

    // MARK: Pairing window (real mode)

    /// Opens a new pairing window and returns its code. Fake mode: always "000000".
    public func openWindow() -> String {
        if isFake { return PairingStore.fakeCode }
        return locked {
            let code = makeCode()
            window = Window(code: code, opened: now(), attemptsLeft: PairingStore.maxAttempts)
            return code
        }
    }

    public var activeCode: String? {
        if isFake { return PairingStore.fakeCode }
        return locked { currentWindow()?.code }
    }

    public var secondsLeft: Int? {
        locked {
            guard let window = currentWindow() else { return nil }
            return Int((PairingStore.codeLifetime - now().timeIntervalSince(window.opened)).rounded(.up))
        }
    }

    public func closeWindow() { locked { window = nil } }

    /// The open window, or nil (closing it) once it has expired. Call with the lock held.
    private func currentWindow() -> Window? {
        guard let open = window else { return nil }
        if now().timeIntervalSince(open.opened) >= PairingStore.codeLifetime { window = nil; return nil }
        return open
    }

    // MARK: Pairing and tokens

    public func pair(code: String, client: String?) throws -> String {
        try locked {
            if !isFake {
                guard var open = currentWindow() else { throw ProtocolError(403, PairingStore.refusedMessage) }
                guard code == open.code else {
                    open.attemptsLeft -= 1
                    window = open.attemptsLeft > 0 ? open : nil
                    throw ProtocolError(403, PairingStore.refusedMessage)
                }
                window = nil
            } else if code != PairingStore.fakeCode {
                throw ProtocolError(403, PairingStore.refusedMessage)
            }
            let token = PairingStore.randomToken()
            browsers.append(Browser(tokenHash: PairingStore.hash(token), client: client, pairedAt: now()))
            save()
            return token
        }
    }

    public func isValid(token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let hash = PairingStore.hash(token)
        return locked { browsers.contains { $0.tokenHash == hash } }
    }

    public var pairedCount: Int { locked { browsers.count } }

    public func forgetAll() { locked { browsers = []; save() } }

    // MARK: Helpers

    public static func validatePairBody(_ body: Any) throws -> (code: String, client: String?) {
        guard let object = body as? [String: Any] else { throw ProtocolError(400, "The request body must be a JSON object.") }
        guard let code = object["code"] as? String else { throw ProtocolError(400, "The request needs a pairing code.") }
        guard let rawClient = object["client"] else { return (code, nil) }
        guard let client = rawClient as? String else { throw ProtocolError(400, "“client” must be a string.") }
        guard client.count <= maxClientLength else {
            throw ProtocolError(400, "“client” may have at most \(maxClientLength) characters.")
        }
        return (code, client)
    }

    public static func randomCode() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }

    /// 24 random bytes (192 bits), base64url without padding: 32 characters.
    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// Writes the hashed tokens (real mode only), readable by this user only. Call with the lock held.
    /// A failed save keeps the pairing working until the helper restarts.
    private func save() {
        guard case .real(let url) = mode else { return }
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? PairingStore.encoder.encode(SavedFile(browsers: browsers)) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
