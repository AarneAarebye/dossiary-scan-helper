import Foundation
import Testing
@testable import HelperCore

private func entries(profiles: [ProfileMenuEntry]?, running: Bool = false, last: String? = nil, problem: String? = nil) -> [MenuEntry] {
    MenuModel.entries(scanners: [], port: 8766, fake: false, pairedCount: 0, startAtLogin: nil, profiles: profiles,
                      profileScanRunning: running, lastProfileScan: last, profileProblem: problem)
}

@Test func noProfilesParameterMeansNoProfileSection() {
    let all = entries(profiles: nil)
    #expect(!all.contains(.action("Scan profiles…", .editProfiles, checked: false, enabled: true)))
}

@Test func eachProfileIsAScanEntryAndThereIsAnEditEntry() {
    let all = entries(profiles: [ProfileMenuEntry(id: "a", name: "Letters", scannerName: "Canon CanoScan 8800F (node-000)", scanning: false)])
    #expect(all.contains(.action("Scan: Letters (Canon CanoScan 8800F (node-000))", .scanWithProfile("a"), checked: false, enabled: true)))
    #expect(all.contains(.action("Scan profiles…", .editProfiles, checked: false, enabled: true)))
}

@Test func theRunningProfileSaysSoAndAllScanEntriesAreDisabled() {
    let all = entries(profiles: [ProfileMenuEntry(id: "a", name: "Letters", scannerName: "S", scanning: true),
                                 ProfileMenuEntry(id: "b", name: "Photos", scannerName: "S", scanning: false)], running: true)
    #expect(all.contains(.action("Scanning “Letters”…", .scanWithProfile("a"), checked: false, enabled: false)))
    #expect(all.contains(.action("Scan: Photos (S)", .scanWithProfile("b"), checked: false, enabled: false)))
}

@Test func theLastScanAndAProblemAreShownAsInfoLines() {
    let all = entries(profiles: [], last: "scan_2026-11-11_120000.pdf", problem: "No paper in the feeder.")
    #expect(all.contains(.info("Last profile scan: scan_2026-11-11_120000.pdf")))
    #expect(all.contains(.info("No paper in the feeder.")))
}

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

@Test func summaryOfASavedScan() {
    let one = Texts.english.profileScanSummary(.saved(files: [url("a.pdf")], pages: 1, searchable: nil))
    #expect(one.title == "1 page scanned" && one.body == "a.pdf")
    let many = Texts.english.profileScanSummary(.saved(files: [url("a.pdf"), url("b.pdf")], pages: 5, searchable: true))
    #expect(many.title == "5 pages scanned" && many.body == "a.pdf, b.pdf")
}

@Test func summaryMentionsMissingText() {
    let s = Texts.english.profileScanSummary(.saved(files: [url("a.pdf")], pages: 2, searchable: false))
    #expect(s.body.hasPrefix("a.pdf"))
    #expect(s.body.contains("text recognition didn't finish"))
}

@Test func summaryOfAPartialAndAFailedScan() {
    let partial = Texts.english.profileScanSummary(.partial(files: [url("a.pdf")], message: "Paper jam."))
    #expect(partial.title == "Scan incomplete" && partial.body.contains("a.pdf") && partial.body.contains("Paper jam."))
    let failed = Texts.english.profileScanSummary(.failed("No paper in the feeder."))
    #expect(failed.title == "Scan failed" && failed.body == "No paper in the feeder.")
}
