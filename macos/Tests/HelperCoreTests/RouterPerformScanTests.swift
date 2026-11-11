import Foundation
import Testing
@testable import HelperCore

private func makeRouter() -> Router { Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake)) }

@Test func performScanRunsAScanWithoutHTTP() async throws {
    let body: [String: Any] = ["scanner": "fake:flatbed"]
    let (status, payload) = try await makeRouter().performScan(body)
    #expect(status == 200)
    let files = try #require(payload["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect((files[0]["name"] as? String)?.hasSuffix(".pdf") == true)
    #expect((files[0]["data"] as? String)?.isEmpty == false)
}

@Test func performScanThrowsTheProtocolErrors() async {
    let body: [String: Any] = ["scanner": "no-such-scanner"]
    await #expect(throws: ProtocolError.self) { _ = try await makeRouter().performScan(body) }
}

@Test func offeredScannersListsTheBackendsScanners() async {
    let ids = await makeRouter().offeredScanners().map(\.id)
    #expect(ids.contains("fake:flatbed"))
    #expect(ids.contains("fake:feeder"))
}

@Test func performOCRAnswers404ForAnUnknownJob() async {
    let (status, _) = await makeRouter().performOCR("does-not-exist-0123456789")
    #expect(status == 404)
}
