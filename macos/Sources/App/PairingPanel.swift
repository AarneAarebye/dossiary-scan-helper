import AppKit
import HelperCore

/// A small window showing the pairing code and how long it stays valid. Closes when the code is used or expires.
final class PairingPanel: NSPanel {
    private let pairing: PairingStore
    private let codeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(pairing: PairingStore) {
        self.pairing = pairing
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 170),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L("Pair a browser")
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false  // NSPanel hides on deactivate by default; the code must stay visible while typing it in the browser
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        codeLabel.alignment = .center
        detailLabel.alignment = .center
        let stack = NSStackView(views: [codeLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
    }

    func show() {
        _ = pairing.openWindow()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        guard let code = pairing.activeCode else { finish(); return }
        codeLabel.stringValue = code
        if pairing.isFake {
            detailLabel.stringValue = L("Fake scanner mode: this code always works.")
        } else {
            detailLabel.stringValue = L("Type this code in Dossiary's scan dialog.") + "\n" + L("Seconds left: %lld", pairing.secondsLeft ?? 0)
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }

    override func close() {
        if !pairing.isFake { pairing.closeWindow() }
        finish()
        super.close()
    }
}
