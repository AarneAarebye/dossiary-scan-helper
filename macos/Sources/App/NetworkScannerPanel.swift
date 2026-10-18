import AppKit
import HelperCore

/// "Add network scanner…": pick a scanix500-server found on the network (or type its address), check its
/// fingerprint, and pair by pressing the scanner's Scan button or with a code from `sudo scanix500-server pair`.
final class NetworkScannerPanel: NSPanel {
    private let store: RemoteServerStore
    private let pairing = RemotePairing()
    private let discovery = RemoteDiscovery()
    private let onPaired: () -> Void
    private let serverPopup = NSPopUpButton()
    private let addressField = NSTextField(string: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: L("Looking for scan servers on the network…"))
    private let codeField = NSTextField(string: "")
    private let buttonPairButton = NSButton(title: L("Pair using the Scan button"), target: nil, action: nil)
    private let codePairButton = NSButton(title: L("Pair with code"), target: nil, action: nil)
    private var probe: RemoteProbe?
    private var busy = false

    init(store: RemoteServerStore, onPaired: @escaping () -> Void) {
        self.store = store
        self.onPaired = onPaired
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = L("Add network scanner")
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        addressField.placeholderString = L("or enter an address, such as scanner.local")
        codeField.placeholderString = L("6-digit code")
        let connect = NSButton(title: L("Connect"), target: self, action: #selector(connectChosen))
        buttonPairButton.target = self; buttonPairButton.action = #selector(pairWithButton)
        codePairButton.target = self; codePairButton.action = #selector(pairWithCode)
        let codeRow = NSStackView(views: [codeField, codePairButton])
        let stack = NSStackView(views: [serverPopup, addressField, connect, detailLabel, buttonPairButton, codeRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        contentView = stack
        discovery.onChange = { [weak self] in self?.refreshPopup() }
        setPairingEnabled(false)
    }

    func show() {
        probe = nil
        detailLabel.stringValue = L("Looking for scan servers on the network…")
        setPairingEnabled(false)
        discovery.start()
        refreshPopup()
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        discovery.stop()
        super.close()
    }

    private func refreshPopup() {
        serverPopup.removeAllItems()
        for server in discovery.servers {
            serverPopup.addItem(withTitle: server.name)
            serverPopup.lastItem?.representedObject = "\(server.host):\(server.port)"
        }
        if discovery.servers.isEmpty { serverPopup.addItem(withTitle: L("No scan servers found yet")) }
    }

    private func setPairingEnabled(_ on: Bool) {
        buttonPairButton.isEnabled = on && !busy
        codePairButton.isEnabled = on && !busy
        codeField.isEnabled = on && !busy
    }

    private func chosenAddress() -> (String, Int)? {
        let typed = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        let text = typed.isEmpty ? (serverPopup.selectedItem?.representedObject as? String ?? "") : typed
        guard !text.isEmpty else { return nil }
        if let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) {
            return (String(text[..<colon]), port)
        }
        return (text, 8767)
    }

    @objc private func connectChosen() {
        guard let (host, port) = chosenAddress() else { detailLabel.stringValue = L("Choose a scan server or enter its address."); return }
        detailLabel.stringValue = L("Connecting to %@…", host)
        Task { @MainActor in
            do {
                let found = try await pairing.probe(host: host, port: port)
                probe = found
                detailLabel.stringValue = L("%1$@ at %2$@", found.name, host) + "\n"
                    + L("Fingerprint: %@", RemoteFingerprint.display(found.fingerprint)) + "\n"
                    + L("The fingerprint should match the output of “scanix500-server status” on the Pi. Then click the button below and, within 2 minutes, press the Scan button on the iX500—or enter a code from “sudo scanix500-server pair”.")
                setPairingEnabled(true)
            } catch {
                probe = nil
                detailLabel.stringValue = L.errorText(error)
                setPairingEnabled(false)
            }
        }
    }

    @objc private func pairWithButton() {
        guard let probe else { return }
        detailLabel.stringValue = L("Press the Scan button on the iX500 within 2 minutes…")
        run { [pairing] in try await pairing.pairByButton(probe, client: Host.current().localizedName ?? "Mac") }
    }

    @objc private func pairWithCode() {
        guard let probe else { return }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        detailLabel.stringValue = L("Pairing…")
        run { [pairing] in try await pairing.pairByCode(probe, code: code, client: Host.current().localizedName ?? "Mac") }
    }

    private func run(_ pair: @escaping () async throws -> String) {
        guard let probe else { return }
        busy = true
        setPairingEnabled(true)
        Task { @MainActor in
            defer { busy = false; setPairingEnabled(self.probe != nil) }
            do {
                let token = try await pair()
                try store.add(RemoteServer(name: probe.name, host: probe.host, port: probe.port,
                                           fingerprint: probe.fingerprint), token: token)
                Log.shared.write("Paired with the network scanner \(probe.name) (\(probe.host)).")
                onPaired()
                close()
            } catch {
                detailLabel.stringValue = L.errorText(error)
            }
        }
    }
}
