public enum MenuAction: Equatable, Sendable {
    case pair, forget, startAtLogin, openLog, quit, addNetworkScanner, chooseButtonScanFolder, toggleButtonSound
    case removeNetworkScanner(String)
    case scanWithProfile(String)
    case editProfiles
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

public struct ProfileMenuEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let scannerName: String
    public let scanning: Bool
    public init(id: String, name: String, scannerName: String, scanning: Bool) {
        self.id = id; self.name = name; self.scannerName = scannerName; self.scanning = scanning
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
                               buttonScanFolder: String? = nil, lastButtonScan: String? = nil,
                               buttonScanProblem: ButtonScanProblem? = nil, buttonSound: Bool? = nil,
                               profiles: [ProfileMenuEntry]? = nil, profileScanRunning: Bool = false,
                               lastProfileScan: String? = nil, profileProblem: String? = nil,
                               texts t: Texts = .english) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .title(fake ? t("Dossiary Scan Helper — Fake Scanners") : "Dossiary Scan Helper"),
            .info(t("Listening on %@", "127.0.0.1:\(port)")),
            .separator,
        ]
        entries += scanners.isEmpty ? [.info(t("No scanners found"))] : scanners.map { .info($0.name) }
        if let profiles {
            entries.append(.separator)
            for profile in profiles {
                let title = profile.scanning ? t("Scanning “%@”…", profile.name)
                                             : t("Scan: %1$@ (%2$@)", profile.name, profile.scannerName)
                entries.append(.action(title, .scanWithProfile(profile.id), checked: false, enabled: !profileScanRunning))
            }
            entries.append(.action(t("Scan profiles…"), .editProfiles, checked: false, enabled: true))
            if let lastProfileScan { entries.append(.info(t("Last profile scan: %@", lastProfileScan))) }
            if let profileProblem { entries.append(.info(profileProblem)) }
        }
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
            if let buttonScanFolder { entries.append(.info(t("Button scans go to “%@”", buttonScanFolder))) }
            entries.append(.action(t("Folder for button scans…"), .chooseButtonScanFolder, checked: false, enabled: true))
            if let buttonSound { entries.append(.action(t("Sound on button press"), .toggleButtonSound, checked: buttonSound, enabled: true)) }
            if let lastButtonScan { entries.append(.info(t("Last button scan: %@", lastButtonScan))) }
            if let buttonScanProblem { entries.append(.info(t.buttonScanProblem(buttonScanProblem))) }
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
