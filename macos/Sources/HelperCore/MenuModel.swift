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

public enum MenuEntry: Equatable, Sendable {
    case title(String)
    case info(String)
    case separator
    case action(String, MenuAction, checked: Bool, enabled: Bool)
}

/// The status menu as data, so it can be tested without AppKit.
public enum MenuModel {
    public static func entries(scanners: [ScannerInfo], port: UInt16, fake: Bool, pairedCount: Int,
                               startAtLogin: Bool?, networkServers: [NetworkServerEntry]? = nil) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .title(fake ? "Dossiary Scan Helper — fake scanners" : "Dossiary Scan Helper"),
            .info("Listening on 127.0.0.1:\(port)"),
            .separator,
        ]
        entries += scanners.isEmpty ? [.info("No scanners found")] : scanners.map { .info($0.name) }
        entries += [
            .separator,
            .action("Pair a browser…", .pair, checked: false, enabled: true),
            .action("Forget paired browsers (\(pairedCount))", .forget, checked: false, enabled: pairedCount > 0),
        ]
        if let networkServers {
            entries.append(.separator)
            for server in networkServers {
                entries.append(.info("\(server.name): \(server.statusText)"))
                entries.append(.action("Remove “\(server.name)”", .removeNetworkScanner(server.id), checked: false, enabled: true))
            }
            entries.append(.action("Add network scanner…", .addNetworkScanner, checked: false, enabled: true))
        }
        entries += [
            .separator,
            .action("Start at login", .startAtLogin, checked: startAtLogin == true, enabled: startAtLogin != nil),
            .action("Open log", .openLog, checked: false, enabled: true),
            .separator,
            .action("Quit Dossiary Scan Helper", .quit, checked: false, enabled: true),
        ]
        return entries
    }
}
