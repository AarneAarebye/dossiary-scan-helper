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
