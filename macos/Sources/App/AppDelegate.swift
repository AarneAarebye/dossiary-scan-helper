import AppKit
import HelperCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let runtime: HelperRuntime
    private var statusItem: NSStatusItem?
    private var scanners: [ScannerInfo] = []
    private lazy var pairingPanel = PairingPanel(pairing: runtime.pairing)

    init(runtime: HelperRuntime) { self.runtime = runtime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try runtime.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Dossiary Scan Helper couldn't start"
            alert.informativeText = "\(error)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "scanner", accessibilityDescription: "Dossiary Scan Helper")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        runtime.backend.setChangeHandler { [weak self] in DispatchQueue.main.async { self?.refreshScanners() } }
        refreshScanners()
    }

    private var stopped = false
    private var stopping = false

    /// Every quit (the menu, Activity Monitor, logout, SIGTERM) passes here. With a scan under way, this quit
    /// is cancelled while the scan is stopped and its session closed, then the app quits for real. Without one
    /// it quits at once, so a logout isn't held up. (Not `.terminateLater`: that waits in a modal run loop
    /// mode, where the main-queue work stopping a scan never runs.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if stopped || !runtime.hasOpenScannerSessions { return .terminateNow }
        if stopping { return .terminateCancel }  // a second Quit while the first is still stopping the scan
        stopping = true
        Task { @MainActor in
            await runtime.stop()
            stopped = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    private func refreshScanners() {
        Task { [weak self] in
            guard let self else { return }
            let list = await runtime.backend.listScanners()
            await MainActor.run { self.scanners = list }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshScanners()
        menu.removeAllItems()
        let entries = MenuModel.entries(scanners: scanners, port: runtime.options.port, fake: runtime.options.fakeScanners,
                                        pairedCount: runtime.pairing.pairedCount,
                                        startAtLogin: LoginItem.isAvailable ? LoginItem.isEnabled : nil)
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .title(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
                item.isEnabled = false
                menu.addItem(item)
            case .info(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .action(let text, let action, let checked, let enabled):
                let item = NSMenuItem(title: text, action: enabled ? #selector(menuItemChosen(_:)) : nil,
                                      keyEquivalent: action == .quit ? "q" : "")
                item.target = self
                item.representedObject = action
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        switch action {
        case .pair:
            pairingPanel.show()
        case .forget:
            do {
                try runtime.pairing.forgetAll()
                Log.shared.write("Forgot all paired browsers.")
            } catch {
                Log.shared.write(error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "Couldn't forget the paired browsers"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        case .startAtLogin:
            do { try LoginItem.set(!LoginItem.isEnabled) } catch {
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        case .openLog:
            NSWorkspace.shared.open(Log.shared.url)
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
