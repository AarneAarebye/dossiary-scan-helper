public enum MenuAction: Equatable, Sendable {
    case pair, forget, startAtLogin, openLog, quit, addNetworkScanner
    case removeNetworkScanner(String)
}

public struct NetworkServerEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: RemoteStatus?
    public init(id: String, name: String, status: RemoteStatus?) { self.id = id; self.name = name; self.status = status }

    func statusText(_ t: Texts) -> String {
        switch status {
        case .connected: return t("connected")
        case .needsPairing: return t("needs pairing again")
        case .unreachable: return t("can't be reached")
        case .certificateChanged: return t("certificate changed — remove and add it again")
        case nil: return t("checking…")
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
                               startAtLogin: Bool?, networkServers: [NetworkServerEntry]? = nil,
                               texts t: Texts = .english) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .title(fake ? t("Dossiary Scan Helper — Fake Scanners") : "Dossiary Scan Helper"),
            .info(t("Listening on %@", "127.0.0.1:\(port)")),
            .separator,
        ]
        entries += scanners.isEmpty ? [.info(t("No scanners found"))] : scanners.map { .info($0.name) }
        entries += [
            .separator,
            .action(t("Pair a browser…"), .pair, checked: false, enabled: true),
            .action(t("Forget paired browsers (%lld)", pairedCount), .forget, checked: false, enabled: pairedCount > 0),
        ]
        if let networkServers {
            entries.append(.separator)
            for server in networkServers {
                entries.append(.info(t("%1$@: %2$@", server.name, server.statusText(t))))
                entries.append(.action(t("Remove “%@”", server.name), .removeNetworkScanner(server.id), checked: false, enabled: true))
            }
            entries.append(.action(t("Add network scanner…"), .addNetworkScanner, checked: false, enabled: true))
        }
        entries += [
            .separator,
            .action(t("Open at Login"), .startAtLogin, checked: startAtLogin == true, enabled: startAtLogin != nil),
            .action(t("Open log"), .openLog, checked: false, enabled: true),
            .separator,
            .action(t("Quit Dossiary Scan Helper"), .quit, checked: false, enabled: true),
        ]
        return entries
    }
}
