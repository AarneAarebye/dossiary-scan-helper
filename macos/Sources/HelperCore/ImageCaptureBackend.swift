import AppKit
import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

/// Real scanners: USB, network and AirPrint/eSCL devices that macOS's Image Capture sees.
public final class ImageCaptureBackend: NSObject, ScannerBackend, @unchecked Sendable {
    private let log: @Sendable (String) -> Void
    // All state below is touched on the main thread only.
    private var browser: ICDeviceBrowser?
    private var devices: [String: ICScannerDevice] = [:]
    private var infos: [String: ScannerInfo] = [:]
    private var busy: Set<String> = []
    private var changeHandler: (@Sendable () -> Void)?
    /// Pending unit switches: the requested unit type and the waiter for it.
    private var selectWaiters: [String: (type: ICScannerFunctionalUnitType, once: Once<Void>)] = [:]
    private var collectors: [String: Collector] = [:]
    private var sessionStarts: [String: SessionStart] = [:]

    /// What one opening session has sent so far: its own `deviceDidBecomeReady` and its automatic first
    /// `didSelect`. Registered before the open request, since ready can arrive with the open completion.
    private final class SessionStart {
        private var ready = false, selected = false
        private var readyWaiter: Once<Void>?, selectWaiter: Once<Void>?
        private var failure: Error?

        func waitForReady(_ once: Once<Void>) {
            if let failure { once.resume(.failure(failure)) } else if ready { once.resume(.success(())) } else { readyWaiter = once }
        }
        func waitForSelect(_ once: Once<Void>) {
            if let failure { once.resume(.failure(failure)) } else if selected { once.resume(.success(())) } else { selectWaiter = once }
        }
        func markReady() { ready = true; readyWaiter?.resume(.success(())); readyWaiter = nil }
        /// Returns false once the session's first selection has already been seen.
        func markSelected() -> Bool {
            if selected { return false }
            selected = true; selectWaiter?.resume(.success(())); selectWaiter = nil
            return true
        }
        func fail(_ error: Error) {
            failure = error
            readyWaiter?.resume(.failure(error)); selectWaiter?.resume(.failure(error))
            readyWaiter = nil; selectWaiter = nil
        }
    }

    /// Pages arriving during one scan, and the waiter for the end of the scan.
    private final class Collector {
        let once: Once<([URL], Error?)>
        var urls: [URL] = []
        var watchdog: DispatchWorkItem?
        init(once: Once<([URL], Error?)>) { self.once = once }
    }

    /// A scan with no page and no completion for this long is given up.
    static let inactivityLimit: TimeInterval = 600

    public init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    /// Starts looking for scanners. Call on the main thread.
    @MainActor public func start() {
        let browser = ICDeviceBrowser()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
        browser.start()
        self.browser = browser
    }

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async { self.changeHandler = handler }
    }

    public func listScanners() async -> [ScannerInfo] { await currentScanners() }

    @MainActor private func currentScanners() -> [ScannerInfo] {
        for id in devices.keys where infos[id] == nil && !busy.contains(id) {
            Task { await self.probe(id) }  // retry devices whose settings couldn't be read yet
        }
        return devices.keys.compactMap { infos[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments {
        try await performScan(scannerID, settings)
    }

    // MARK: Discovery

    static func id(for device: ICDevice) -> String {
        CapabilityMapping.scannerID(persistentID: device.persistentIDString, uuid: device.uuidString,
                                    name: device.name ?? "Scanner")
    }

    @MainActor private func probe(_ id: String) async {
        guard let device = devices[id], !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        let name = device.name ?? "Scanner"
        do {
            try await openSession(device)
            defer { device.requestCloseSession(options: [:]) { _ in } }
            var units: [UnitCapabilities] = []
            let types = device.availableFunctionalUnitTypes.compactMap { ICScannerFunctionalUnitType(rawValue: $0.uintValue) }
            for type in types where type == .flatbed || type == .documentFeeder {
                try await select(device, type)
                let unit = device.selectedFunctionalUnit
                units.append(UnitCapabilities(
                    source: type == .documentFeeder ? .feeder : .flatbed,
                    duplex: (unit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning ?? false,
                    bitDepths: Array(unit.supportedBitDepths), resolutions: Array(unit.supportedResolutions),
                    preferredResolutions: Array(unit.preferredResolutions)))
            }
            guard let info = CapabilityMapping.scannerInfo(id: id, name: name, units: units) else {
                log("\(name) has no flatbed or document feeder; not offered.")
                return
            }
            infos[id] = info
            log("Found \(name): \(info.sources.map(\.rawValue).joined(separator: ", ")), \(info.resolutions) dpi.")
            changeHandler?()
        } catch {
            log("Couldn't read the settings of \(name): \(error.localizedDescription)")
        }
    }

    // MARK: Scanning

    @MainActor private func performScan(_ id: String, _ settings: ScanSettings) async throws -> ScanDocuments {
        guard let device = devices[id], let info = infos[id] else {
            throw ProtocolError(503, "That scanner isn't connected any more. Check that it's switched on, then try again.")
        }
        guard !busy.contains(id) else {
            throw ProtocolError(503, "\(info.name) is still being set up. Try again in a moment.")
        }
        busy.insert(id)
        defer { busy.remove(id) }

        do { try await openSession(device) } catch {
            throw ProtocolError(503, "Couldn't connect to \(info.name): \(error.localizedDescription). Check that it's "
                + "switched on and that no other app (Image Capture, Preview) is using it. For a network scanner, also "
                + "check System Settings › Privacy & Security › Local Network.")
        }
        defer { device.requestCloseSession(options: [:]) { _ in } }

        let type: ICScannerFunctionalUnitType = settings.source == .feeder ? .documentFeeder : .flatbed
        do { try await select(device, type) } catch let error as ProtocolError { throw error } catch {
            throw ProtocolError(503, "\(info.name) couldn't switch to its \(settings.source.rawValue): \(error.localizedDescription)")
        }
        configure(device.selectedFunctionalUnit, settings)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dossiary-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        device.transferMode = .fileBased
        device.downloadsDirectory = folder
        device.documentName = "page"
        device.documentUTI = (settings.colorMode == .bw ? UTType.png : UTType.jpeg).identifier

        let (urls, error) = try await runScan(device, id: id)
        let pages = try urls.map { PageImage(data: try Data(contentsOf: $0), dpi: settings.resolution) }
        return try ScanOutcome.documents(pages: pages, errorMessage: error?.localizedDescription, source: settings.source)
    }

    @MainActor private func configure(_ unit: ICScannerFunctionalUnit, _ settings: ScanSettings) {
        unit.measurementUnit = .inches
        switch settings.colorMode {
        case .color: unit.pixelDataType = .RGB; unit.bitDepth = .depth8Bits
        case .gray: unit.pixelDataType = .gray; unit.bitDepth = .depth8Bits
        case .bw: unit.pixelDataType = .BW; unit.bitDepth = .depth1Bit
        }
        unit.resolution = settings.resolution
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = .typeDefault
            feeder.duplexScanningEnabled = settings.duplex
            let size = feeder.documentSize
            unit.scanArea = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        } else {
            let size = unit.physicalSize
            unit.scanArea = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }
    }

    @MainActor private func runScan(_ device: ICScannerDevice, id: String) async throws -> ([URL], Error?) {
        try await awaitCallback(timeout: nil) { (once: Once<([URL], Error?)>) in
            let collector = Collector(once: once)
            collectors[id] = collector
            touch(collector, device: device, id: id)
            device.requestScan()
        }
    }

    /// (Re)starts the inactivity watchdog: no page and no completion for `inactivityLimit` ends the scan.
    @MainActor private func touch(_ collector: Collector, device: ICScannerDevice, id: String) {
        collector.watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let current = self.collectors.removeValue(forKey: id) else { return }
            device.cancelScan()
            current.once.resume(.success((current.urls, CallbackTimeout())))
        }
        collector.watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ImageCaptureBackend.inactivityLimit, execute: item)
    }

    // MARK: Session helpers

    /// Opens a session and waits for that session's own start: `deviceDidBecomeReady` (up to 10 s), then the
    /// device's automatic first `didSelect` (up to 2 s; some drivers may not send one). This matters: if a scan
    /// is requested before the session's ready/initial selection arrive, the device writes the page but its
    /// `didScanTo`/`didCompleteScan` callbacks are never delivered and the scan hangs (Canon MF650C over
    /// TCP/IP, 4 of 4 times). A reopened session lists its units at once from cache, so the units can't
    /// stand in for readiness. On failure no session is left open.
    @MainActor private func openSession(_ device: ICScannerDevice) async throws {
        device.delegate = self
        let id = ImageCaptureBackend.id(for: device)
        let start = SessionStart()
        sessionStarts[id] = start
        defer { if sessionStarts[id] === start { sessionStarts.removeValue(forKey: id) } }
        let _: Void = try await awaitCallback(timeout: 30) { once in
            device.requestOpenSession(options: [:]) { error in
                once.resume(error.map { .failure($0) } ?? .success(()))
            }
        }
        do {
            let _: Void = try await awaitCallback(timeout: 10) { once in start.waitForReady(once) }
            do {
                let _: Void = try await awaitCallback(timeout: 2) { once in start.waitForSelect(once) }
            } catch is CallbackTimeout {}  // no automatic selection: go on
        } catch {
            device.requestCloseSession(options: [:]) { _ in }
            throw error
        }
    }

    @MainActor private func select(_ device: ICScannerDevice, _ type: ICScannerFunctionalUnitType) async throws {
        if device.selectedFunctionalUnit.type == type { return }
        let id = ImageCaptureBackend.id(for: device)
        let _: Void = try await awaitCallback(timeout: 30) { once in
            selectWaiters[id] = (type, once)
            device.requestSelect(type)
        }
        guard device.selectedFunctionalUnit.type == type else {
            let unit = type == .documentFeeder ? Source.feeder.rawValue : Source.flatbed.rawValue
            throw ProtocolError(503, "\(device.name ?? "The scanner") couldn't switch to its \(unit).")
        }
    }
}

extension ImageCaptureBackend: ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        let id = ImageCaptureBackend.id(for: scanner)
        devices[id] = scanner
        scanner.delegate = self
        Task { @MainActor in await self.probe(id) }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        forget(device)
    }
}

extension ImageCaptureBackend: ICScannerDeviceDelegate {
    public func didRemove(_ device: ICDevice) { forget(device) }

    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    public func deviceDidBecomeReady(_ device: ICDevice) {
        sessionStarts[ImageCaptureBackend.id(for: device)]?.markReady()
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        let id = ImageCaptureBackend.id(for: scanner)
        // The session's own automatic first selection is consumed by the session-start wait.
        if let start = sessionStarts[id], start.markSelected() { return }
        // A unit is also selected unprompted right after the device appears; only the requested one counts.
        guard let waiter = selectWaiters[id], error != nil || functionalUnit.type == waiter.type else { return }
        selectWaiters.removeValue(forKey: id)
        waiter.once.resume(error.map { .failure($0) } ?? .success(()))
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        let id = ImageCaptureBackend.id(for: scanner)
        guard let collector = collectors[id] else { return }
        collector.urls.append(url)
        MainActor.assumeIsolated { touch(collector, device: scanner, id: id) }
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        let id = ImageCaptureBackend.id(for: scanner)
        guard let collector = collectors.removeValue(forKey: id) else { return }
        collector.watchdog?.cancel()
        collector.once.resume(.success((collector.urls, error)))
    }

    private func forget(_ device: ICDevice) {
        let id = ImageCaptureBackend.id(for: device)
        devices.removeValue(forKey: id)
        infos.removeValue(forKey: id)
        let gone = ProtocolError(503, "\(device.name ?? "The scanner") was disconnected.")
        sessionStarts.removeValue(forKey: id)?.fail(gone)
        selectWaiters.removeValue(forKey: id)?.once.resume(.failure(gone))
        if let collector = collectors.removeValue(forKey: id) {
            collector.watchdog?.cancel()
            collector.once.resume(.success((collector.urls, gone)))
        }
        log("\(device.name ?? "A scanner") went away.")
        changeHandler?()
    }
}
