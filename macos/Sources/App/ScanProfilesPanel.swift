import AppKit
import HelperCore

/// The list of scan profiles with New…, Edit…, Delete and Done.
final class ScanProfilesPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ScanProfileStore
    private let scanners: () -> [ScannerInfo]
    private let onChange: () -> Void
    private let table = NSTableView()
    private var form: ProfileFormPanel?
    private var editButton = NSButton()
    private var deleteButton = NSButton()

    init(store: ScanProfileStore, scanners: @escaping () -> [ScannerInfo], onChange: @escaping () -> Void) {
        self.store = store
        self.scanners = scanners
        self.onChange = onChange
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = L("Scan profiles")
        isReleasedWhenClosed = false
        build()
    }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.width = 420
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(editClicked)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let new = NSButton(title: L("New…"), target: self, action: #selector(newClicked))
        editButton = NSButton(title: L("Edit…"), target: self, action: #selector(editClicked))
        deleteButton = NSButton(title: L("Delete"), target: self, action: #selector(deleteClicked))
        let done = NSButton(title: L("Done"), target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [new, editButton, deleteButton, NSView(), done])
        buttons.spacing = 8
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
    }

    func show() {
        table.reloadData()
        updateButtons()
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private var selected: ScanProfile? {
        let row = table.selectedRow
        let all = store.profiles
        return all.indices.contains(row) ? all[row] : nil
    }

    private func updateButtons() {
        editButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let profile = store.profiles[row]
        return NSTextField(labelWithString: L("Scan: %1$@ (%2$@)", profile.name, profile.scannerName))
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func newClicked() {
        let available = scanners()
        guard let first = available.first else {
            let alert = NSAlert()
            alert.messageText = L("No scanners are available yet. Add a network scanner or connect one first.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let blank = ScanProfile(name: "", scannerID: first.id, scannerName: first.name,
                                destination: ButtonScanFolder.defaultURL.path, source: .flatbed, colorMode: .color,
                                resolution: 300)
        open(scanners: available, draft: ScanProfileRules.normalized(blank, for: first))
    }

    @objc private func editClicked() {
        guard let profile = selected else { return }
        var available = scanners()
        if !available.contains(where: { $0.id == profile.scannerID }) {
            available.append(ScanProfileRules.placeholderScanner(for: profile))   // off or unreachable: keep its choices
        }
        open(scanners: available, draft: profile)
    }

    private func open(scanners: [ScannerInfo], draft: ScanProfile) {
        let panel = ProfileFormPanel(scanners: scanners, draft: draft) { [weak self] profile in
            guard let self else { return }
            do { try store.save(profile) } catch {
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            table.reloadData()
            updateButtons()
            onChange()
        }
        form = panel
        panel.show()
    }

    @objc private func deleteClicked() {
        guard let profile = selected else { return }
        do { try store.remove(id: profile.id) } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        table.reloadData()
        updateButtons()
        onChange()
    }

    @objc private func doneClicked() { close() }
}
