import AppKit
import HelperCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let runtime: HelperRuntime
    private var statusItem: NSStatusItem?
    private var scanners: [ScannerInfo] = []
    private lazy var pairingPanel = PairingPanel(pairing: runtime.pairing)
    private lazy var networkPanel: NetworkScannerPanel? = runtime.remoteStore.map { store in
        NetworkScannerPanel(store: store) { [weak self] in self?.refreshScanners() }
    }

    private lazy var profilesPanel = ScanProfilesPanel(store: runtime.profileStore, scanners: { [weak self] in self?.scanners ?? [] },
                                                       onChange: { })
    private var lastProfileScan: String?
    private var profileProblem: String?

    private let notifier = PickupNotifier()

    init(runtime: HelperRuntime) {
        self.runtime = runtime
        runtime.buttonScanPickup?.onPickedUp = { [notifier] scan in notifier.notify(scan) }
        runtime.buttonScanPickup?.onButtonPress = { [setting = runtime.buttonPressSetting] press in
            if setting?.isOn == true { ButtonPressSound.play(press) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try runtime.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Dossiary Scan Helper couldn't start")
            alert.informativeText = "\(error)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon(filled: false)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        runtime.router.onScanningChanged = { [weak self] scanning in
            DispatchQueue.main.async { self?.setScanningIcon(scanning) }
        }
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

    private static func icon(filled: Bool) -> NSImage? {
        NSImage(systemSymbolName: filled ? "scanner.fill" : "scanner", accessibilityDescription: "Dossiary Scan Helper")
    }

    private var iconTimer: Timer?

    /// While any scan runs the menu bar icon alternates between the outline and the filled scanner.
    private func setScanningIcon(_ scanning: Bool) {
        iconTimer?.invalidate()
        iconTimer = nil
        statusItem?.button?.image = Self.icon(filled: scanning)
        guard scanning else { return }
        var filled = true
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            filled.toggle()
            self?.statusItem?.button?.image = Self.icon(filled: filled)
        }
    }

    private func refreshScanners() {
        Task { [weak self] in
            guard let self else { return }
            let all = await runtime.router.offeredScanners()
            await MainActor.run { self.scanners = all }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshScanners()
        menu.removeAllItems()
        let entries = MenuModel.entries(scanners: scanners, port: runtime.options.port, fake: runtime.options.fakeScanners,
                                        pairedCount: runtime.pairing.pairedCount,
                                        startAtLogin: LoginItem.isAvailable ? LoginItem.isEnabled : nil,
                                        networkServers: runtime.remote.map { remote in
                                            remote.servers.map { NetworkServerEntry(id: $0.id, name: $0.name, status: remote.statuses[$0.id]) }
                                        },
                                        buttonScanFolder: runtime.buttonScanFolder?.url.lastPathComponent,
                                        lastButtonScan: runtime.buttonScanPickup?.lastScan?.name,
                                        buttonScanProblem: runtime.buttonScanPickup?.lastProblem,
                                        buttonSound: runtime.buttonPressSetting?.isOn,
                                        profiles: runtime.profileStore.profiles.map {
                                            ProfileMenuEntry(id: $0.id, name: $0.name, scannerName: $0.scannerName,
                                                             scanning: runtime.profileRunner.runningProfileID == $0.id)
                                        },
                                        profileScanRunning: runtime.profileRunner.isRunning,
                                        lastProfileScan: lastProfileScan,
                                        profileProblem: profileProblem,
                                        texts: L)
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
        case .scanWithProfile(let id):
            guard let profile = runtime.profileStore.profile(id: id) else { return }
            Task { [weak self] in
                guard let self else { return }
                let outcome = await runtime.profileRunner.run(profile)
                await MainActor.run { self.profileScanFinished(outcome) }
            }
        case .editProfiles:
            profilesPanel.show()
        case .pair:
            pairingPanel.show()
        case .forget:
            do {
                try runtime.pairing.forgetAll()
                Log.shared.write("Forgot all paired browsers.")
            } catch {
                Log.shared.write(error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = L("Couldn't forget paired browsers")
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
        case .addNetworkScanner:
            networkPanel?.show()
        case .toggleButtonSound:
            runtime.buttonPressSetting?.set(!(runtime.buttonPressSetting?.isOn ?? true))
        case .chooseButtonScanFolder:
            guard let folder = runtime.buttonScanFolder else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = folder.url
            panel.prompt = L("Choose")
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url { folder.choose(url) }
        case .removeNetworkScanner(let id):
            do {
                try runtime.remoteStore?.remove(id: id)
                Log.shared.write("Removed a network scanner.")
                refreshScanners()
            } catch {
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func profileScanFinished(_ outcome: ProfileScanOutcome) {
        switch outcome {
        case .saved(let files, _, _):
            lastProfileScan = files.first?.lastPathComponent
            profileProblem = nil
        case .partial(let files, _):
            lastProfileScan = files.first?.lastPathComponent
            profileProblem = L.profileScanProblemLine(outcome)
        case .failed, .problem:
            profileProblem = L.profileScanProblemLine(outcome)
        }
        let summary = L.profileScanSummary(outcome)
        notifier.notify(title: summary.title, body: summary.body)
    }
}
