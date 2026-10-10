import Testing
@testable import HelperCore

@Test func menuWithScanners() {
    let entries = MenuModel.entries(scanners: Array(FakeScanners.infos.prefix(2)), port: 8766, fake: false,
                                    pairedCount: 2, startAtLogin: true)
    #expect(entries == [
        .title("Dossiary Scan Helper"),
        .info("Listening on 127.0.0.1:8766"),
        .separator,
        .info("Fake Flatbed"),
        .info("Fake Feeder"),
        .separator,
        .action("Pair a browser…", .pair, checked: false, enabled: true),
        .action("Forget paired browsers (2)", .forget, checked: false, enabled: true),
        .separator,
        .action("Start at login", .startAtLogin, checked: true, enabled: true),
        .action("Open log", .openLog, checked: false, enabled: true),
        .separator,
        .action("Quit Dossiary Scan Helper", .quit, checked: false, enabled: true),
    ])
}

@Test func menuWithoutScannersOrBundle() {
    let entries = MenuModel.entries(scanners: [], port: 9000, fake: true, pairedCount: 0, startAtLogin: nil)
    #expect(entries[0] == .title("Dossiary Scan Helper — fake scanners"))
    #expect(entries.contains(.info("No scanners found")))
    #expect(entries.contains(.action("Forget paired browsers (0)", .forget, checked: false, enabled: false)))
    #expect(entries.contains(.action("Start at login", .startAtLogin, checked: false, enabled: false)))
}
