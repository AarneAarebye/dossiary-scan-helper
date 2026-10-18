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

@Test func everyVisibleMenuTextGoesThroughTexts() {
    let entries = MenuModel.entries(scanners: Array(FakeScanners.infos.prefix(1)), port: 8766, fake: true, pairedCount: 1,
                                    startAtLogin: true,
                                    networkServers: [NetworkServerEntry(id: "1", name: "attic", status: .unreachable)],
                                    texts: marked)
    var texts: [String] = []
    for entry in entries {
        switch entry {
        case .title(let s), .info(let s): texts.append(s)
        case .action(let s, _, _, _): texts.append(s)
        case .separator: break
        }
    }
    let scannerNames: Set = ["Fake Flatbed"]
    for text in texts where !scannerNames.contains(text) {
        #expect(text.hasPrefix("‹"), "not translated: \(text)")
    }
    #expect(texts.contains("‹Listening on 127.0.0.1:8766›"))
    // The server line is t("%1$@: %2$@", name, statusText(t)): the status is looked up too.
    #expect(texts.contains("‹attic: ‹can't be reached››"))
}

@Test func statusTextsTranslate() {
    let entry = NetworkServerEntry(id: "1", name: "attic", status: .certificateChanged)
    #expect(entry.statusText(.english) == "certificate changed, remove and add it again")
    #expect(entry.statusText(marked) == "‹certificate changed, remove and add it again›")
    #expect(NetworkServerEntry(id: "1", name: "a", status: nil).statusText(.english) == "checking…")
}
