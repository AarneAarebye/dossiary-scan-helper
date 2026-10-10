public enum MenuAction: Equatable, Sendable { case pair, forget, startAtLogin, openLog, quit }

public enum MenuEntry: Equatable, Sendable {
    case title(String)
    case info(String)
    case separator
    case action(String, MenuAction, checked: Bool, enabled: Bool)
}

/// The status menu as data, so it can be tested without AppKit.
public enum MenuModel {
    public static func entries(scanners: [ScannerInfo], port: UInt16, fake: Bool, pairedCount: Int,
                               startAtLogin: Bool?) -> [MenuEntry] {
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
            .separator,
            .action("Start at login", .startAtLogin, checked: startAtLogin == true, enabled: startAtLogin != nil),
            .action("Open log", .openLog, checked: false, enabled: true),
            .separator,
            .action("Quit Dossiary Scan Helper", .quit, checked: false, enabled: true),
        ]
        return entries
    }
}
