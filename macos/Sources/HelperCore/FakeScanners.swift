import Foundation

/// A fake scanner from PROTOCOL.md "Fake scanner mode". Pages carry the text in `sheets`; "" is blank.
public struct FakeScanner: Sendable {
    public let info: ScannerInfo
    public let sheets: [String]
    public let delay: TimeInterval
    public let offline: Bool
    public let jamAfter: Int?
    public let empty: Bool
}

public enum FakeScanners {
    public static let emptyFeederMessage = "No paper in the feeder."

    private static func make(_ id: String, _ name: String, _ sources: [Source], duplex: Bool = false,
                             extras: [String] = [], sheets: [String] = [], delay: TimeInterval = 0,
                             offline: Bool = false, jamAfter: Int? = nil, empty: Bool = false) -> FakeScanner {
        FakeScanner(info: ScannerInfo(id: id, name: name, sources: sources, duplex: duplex,
                                      colorModes: [.color, .gray, .bw], resolutions: [150, 300, 600], extras: extras),
                    sheets: sheets, delay: delay, offline: offline, jamAfter: jamAfter, empty: empty)
    }

    public static let all: [FakeScanner] = [
        make("fake:flatbed", "Fake Flatbed", [.flatbed]),
        make("fake:feeder", "Fake Feeder", [.feeder, .flatbed], duplex: true, sheets: ["Sheet 1", "Sheet 2", "Sheet 3"]),
        make("fake:splitter", "Fake Splitter", [.feeder], extras: ["splitOnBlank", "skipBlankPages"],
             sheets: ["Doc A page 1", "Doc A page 2", "", "Doc B page 1"]),
        make("fake:jam", "Fake Jamming Feeder", [.feeder], sheets: ["Sheet 1", "Sheet 2", "Sheet 3"], jamAfter: 2),
        make("fake:slow", "Fake Slow Scanner", [.flatbed], delay: 2),
        make("fake:offline", "Fake Offline Scanner", [.flatbed], offline: true),
        make("fake:empty", "Fake Empty Feeder", [.feeder], empty: true),
    ]

    public static var infos: [ScannerInfo] { all.map(\.info) }
}
