import Foundation
import Testing
@testable import HelperCore

private let settings = ScanSettings(source: .feeder, duplex: true, colorMode: .color, resolution: 300,
                                    extras: ["skipBlankPages": true], ocr: true, ocrLanguages: ["deu"])

@Test func listsTheServersScannersUnderItsOwnName() async {
    let (store, server) = pairedStore()
    let transport = FakeTransport { _ in (200, ["scanners": [piScanner]]) }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    let list = await remote.listScanners()
    #expect(list.map(\.id) == ["remote:\(server.id):sane:ix500"])
    #expect(list.map(\.name) == ["ScanSnap iX500 (scanner)"])
    #expect(list.first?.ocrLanguages == ["deu", "eng"])
    #expect(transport.sent.first?.path == "/scanners" && transport.sent.first?.token == "tok-scanner")
    #expect(remote.statuses[server.id] == .connected)
}

@Test func unpairedUnreachableAndChangedServersListNothing() async {
    let cases: [(@Sendable (RemoteRequest) throws -> (Int, Any), RemoteStatus)] = [
        ({ _ in (401, ["ok": false, "message": "not paired"]) }, .needsPairing),
        ({ _ in throw RemoteError.unreachable("timed out") }, .unreachable),
        ({ _ in throw RemoteError.certificateChanged(seen: "CD") }, .certificateChanged),
    ]
    for (handler, expected) in cases {
        let (store, server) = pairedStore()
        let remote = RemoteScanners(store: store, transport: { _ in FakeTransport(handler: handler) })
        #expect(await remote.listScanners().isEmpty)
        #expect(remote.statuses[server.id] == expected)
    }
}

@Test func scanIsForwardedAndItsOcrJobsRenamed() async throws {
    let (store, server) = pairedStore()
    let transport = FakeTransport { request in
        (200, ["ok": true, "partial": false, "message": "2 pages scanned.",
               "files": [["name": "scan_1.pdf", "pages": 2, "data": "JVBERg==", "ocrJob": "job_123-x"]]])
    }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    #expect(remote.owns("remote:\(server.id):sane:ix500") && !remote.owns("ica:1234"))
    let (status, body) = try await remote.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings)
    #expect(status == 200)
    let file = (body["files"] as? [[String: Any]])?.first
    #expect(file?["ocrJob"] as? String == "remote.\(server.id).job_123-x")
    #expect(file?["data"] as? String == "JVBERg==")
    let sent = try #require(transport.sent.first)
    #expect(sent.method == "POST" && sent.path == "/scan" && sent.timeout == 1800)
    let forwarded = try #require((try? JSONSerialization.jsonObject(with: sent.body ?? Data())) as? [String: Any])
    #expect(forwarded["scanner"] as? String == "sane:ix500")
    #expect(forwarded["ocr"] as? Bool == true && forwarded["ocrLanguages"] as? [String] == ["deu"])
    #expect((forwarded["extras"] as? [String: Bool])?["skipBlankPages"] == true)
}

@Test func scanErrorsBecomeProtocolErrors() async {
    let (store, server) = pairedStore()
    let unreachable = RemoteScanners(store: store, transport: { _ in FakeTransport { _ in throw RemoteError.unreachable("offline") } })
    await #expect(throws: ProtocolError.self) { try await unreachable.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings) }
    let unpaired = RemoteScanners(store: store, transport: { _ in FakeTransport { _ in (401, ["ok": false]) } })
    do {
        _ = try await unpaired.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings)
        Issue.record("expected an error")
    } catch let error as ProtocolError {
        #expect(error.status == 503 && error.message.contains("Add network scanner"))
    } catch { Issue.record("\(error)") }
}

@Test func busyAnswersPassThrough() async throws {
    let (store, server) = pairedStore()
    let remote = RemoteScanners(store: store, transport: { _ in FakeTransport { _ in (409, ["ok": false, "partial": false, "message": "A scan is already running."]) } })
    let (status, body) = try await remote.scan(scannerID: "remote:\(server.id):sane:ix500", settings: settings)
    #expect(status == 409 && body["message"] as? String == "A scan is already running.")
}

@Test func ocrJobsGoToTheirServer() async {
    let (store, server) = pairedStore()
    let transport = FakeTransport { request in
        request.path == "/ocr/job_123-x" ? (200, ["ok": true, "files": [["name": "scan_1.pdf", "pages": 2, "data": "JVBERg=="]]])
                                         : (404, ["ok": false])
    }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    #expect(remote.isRemoteJob("remote.\(server.id).job_123-x") && !remote.isRemoteJob("abcDEF"))
    let (status, body) = await remote.fetchOCR("remote.\(server.id).job_123-x")
    #expect(status == 200 && (body["files"] as? [[String: Any]])?.count == 1)
    #expect(await remote.fetchOCR("remote.0000000000000000.job").0 == 404)
}
