import AppKit
import HelperCore

/// One scan profile as a form. Every popup shows only what the chosen scanner offers: any change re-reads the
/// choices through `ScanProfileRules.normalized` and refills the popups.
final class ProfileFormPanel: NSPanel {
    private let scanners: [ScannerInfo]
    private var draft: ScanProfile
    private let onSave: (ScanProfile) -> Void

    private let nameField = NSTextField()
    private let scannerPopup = NSPopUpButton()
    private let folderField = NSTextField()
    private let sourcePopup = NSPopUpButton()
    private let duplexBox = NSButton(checkboxWithTitle: L("Scan both sides"), target: nil, action: nil)
    private let colorPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let areaPopup = NSPopUpButton()
    private let ocrBox = NSButton(checkboxWithTitle: L("Make the PDF searchable (OCR)"), target: nil, action: nil)
    private let dossiaryBox = NSButton(checkboxWithTitle: L("Also send to Dossiary"), target: nil, action: nil)
    private let languagesPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var offeredLanguages: [String] = []
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var grid = NSGridView()
    private enum Row: Int { case name, scanner, folder, dossiary, source, duplex, color, resolution, format, area, ocr, languages }

    /// `scanners` are the scanners to choose from; `draft` the profile to edit (a new one is already normalized).
    init(scanners: [ScannerInfo], draft: ScanProfile, onSave: @escaping (ScanProfile) -> Void) {
        self.scanners = scanners
        self.draft = draft
        self.onSave = onSave
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = L("Scan profiles")
        isReleasedWhenClosed = false
        build()
        reload()
        fitToContent()
    }

    /// Resizes the window to what the visible rows need, keeping its top-left corner.
    private func fitToContent() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let top = frame.maxY
        setContentSize(content.fittingSize)
        setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
    }

    private var scanner: ScannerInfo? { scanners.first { $0.id == draft.scannerID } }

    private func build() {
        let chooseFolder = NSButton(title: L("Choose"), target: self, action: #selector(chooseFolderClicked))
        folderField.isEditable = false
        let folderRow = NSStackView(views: [folderField, chooseFolder])
        folderRow.spacing = 8
        let save = NSButton(title: L("Save"), target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.spacing = 12

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.alignment = .right
            field.preferredMaxLayoutWidth = 150
            field.widthAnchor.constraint(equalToConstant: 150).isActive = true
            return field
        }
        let rows: [[NSView]] = [
            [label(L("Name")), nameField], [label(L("Scanner")), scannerPopup], [label(L("Folder")), folderRow],
            [NSView(), dossiaryBox],
            [label(L("Source")), sourcePopup], [NSView(), duplexBox], [label(L("Mode")), colorPopup],
            [label(L("Resolution")), resolutionPopup], [label(L("Format")), formatPopup], [label(L("Paper size")), areaPopup],
            [NSView(), ocrBox], [label(L("OCR languages")), languagesPopup],
        ]
        grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        for popup in [scannerPopup, sourcePopup, colorPopup, resolutionPopup, formatPopup, areaPopup] {
            popup.target = self
            popup.action = #selector(controlChanged(_:))
        }
        scannerPopup.action = #selector(scannerChanged)
        for box in [duplexBox, ocrBox, dossiaryBox] { box.target = self; box.action = #selector(controlChanged(_:)) }
        messageLabel.textColor = .systemRed
        let stack = NSStackView(views: [grid, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        contentView = container
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        languagesPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        folderField.widthAnchor.constraint(equalToConstant: 200).isActive = true
    }

    /// Fills every control from `draft` and hides what the scanner doesn't offer.
    private func reload() {
        nameField.stringValue = draft.name
        folderField.stringValue = draft.destination
        fill(scannerPopup, scanners.map { ($0.id, $0.name) }, selected: draft.scannerID)
        guard let scanner else { return }
        let o = ScanProfileRules.options(for: scanner, source: draft.source, colorMode: draft.colorMode)
        fill(sourcePopup, o.sources.map { ($0.rawValue, $0 == .flatbed ? L("Flatbed") : L("Feeder")) }, selected: draft.source.rawValue)
        fill(colorPopup, o.colorModes.map { ($0.rawValue, Self.colorTitle($0)) }, selected: draft.colorMode.rawValue)
        fill(resolutionPopup, o.resolutions.map { (String($0), L("%lld dpi", $0)) }, selected: String(draft.resolution))
        fill(formatPopup, o.formats.map { ($0, $0.uppercased()) }, selected: draft.format)
        fill(areaPopup, o.areas.map { ($0, Self.areaTitle($0)) }, selected: draft.area)
        duplexBox.state = draft.duplex ? .on : .off
        ocrBox.state = draft.ocr ? .on : .off
        dossiaryBox.state = draft.sendToDossiary ? .on : .off
        fillLanguages(offered: o.ocrLanguages)
        grid.row(at: Row.dossiary.rawValue).isHidden = !(DossiaryHandOver.isInstalled || draft.sendToDossiary)
        grid.row(at: Row.source.rawValue).isHidden = o.sources.count < 2
        grid.row(at: Row.duplex.rawValue).isHidden = !o.duplexOffered
        grid.row(at: Row.area.rawValue).isHidden = o.areas.isEmpty
        let ocrShown = o.ocrOffered && draft.format == "pdf"
        grid.row(at: Row.ocr.rawValue).isHidden = !ocrShown
        grid.row(at: Row.languages.rawValue).isHidden = !(ocrShown && draft.ocr)
        fitToContent()
    }

    private func fill(_ popup: NSPopUpButton, _ items: [(String, String)], selected: String?) {
        popup.removeAllItems()
        for (value, title) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        if let index = items.firstIndex(where: { $0.0 == selected }) { popup.selectItem(at: index) }
    }

    /// A pull-down of the offered languages, each a checkable item; the title lists the chosen ones.
    private func fillLanguages(offered: [String]) {
        offeredLanguages = offered
        languagesPopup.removeAllItems()
        let names = offered.map { Self.languageName($0) }
        let picked = offered.filter { draft.ocrLanguages.contains($0) }
        languagesPopup.addItem(withTitle: picked.map { Self.languageName($0) }.joined(separator: ", "))
        for (code, name) in zip(offered, names) {
            let item = NSMenuItem(title: name, action: #selector(languageToggled(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = draft.ocrLanguages.contains(code) ? .on : .off
            languagesPopup.menu?.addItem(item)
        }
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    @objc private func languageToggled(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        readControls()
        if draft.ocrLanguages.contains(code) { draft.ocrLanguages.removeAll { $0 == code } }
        else { draft.ocrLanguages = offeredLanguages.filter { draft.ocrLanguages.contains($0) || $0 == code } }
        if let scanner { draft = ScanProfileRules.normalized(draft, for: scanner) }
        reload()
    }

    private func chosen(_ popup: NSPopUpButton) -> String? { popup.selectedItem?.representedObject as? String }

    private static func colorTitle(_ mode: ColorMode) -> String {
        switch mode {
        case .color: return L("Color")
        case .gray: return L("Grayscale")
        case .bw: return L("Black and white")
        }
    }

    private static func areaTitle(_ id: String) -> String { id == Areas.full ? L("The whole glass") : (Areas.named(id)?.label ?? id) }

    private func readControls() {
        draft.name = nameField.stringValue
        draft.destination = folderField.stringValue
        if let s = chosen(sourcePopup).flatMap(Source.init(rawValue:)) { draft.source = s }
        draft.duplex = duplexBox.state == .on
        if let c = chosen(colorPopup).flatMap(ColorMode.init(rawValue:)) { draft.colorMode = c }
        if let r = chosen(resolutionPopup).flatMap(Int.init) { draft.resolution = r }
        if let f = chosen(formatPopup) { draft.format = f }
        draft.area = chosen(areaPopup)
        draft.ocr = ocrBox.state == .on
        draft.sendToDossiary = dossiaryBox.state == .on
    }

    @objc private func scannerChanged() {
        readControls()
        draft.scannerID = chosen(scannerPopup) ?? draft.scannerID
        if let scanner { draft = ScanProfileRules.normalized(draft, for: scanner) }
        reload()
    }

    @objc private func controlChanged(_ sender: Any?) {
        readControls()
        if let scanner { draft = ScanProfileRules.normalized(draft, for: scanner) }
        reload()
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folderField.stringValue)
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { folderField.stringValue = url.path }
    }

    @objc private func saveClicked() {
        readControls()
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { messageLabel.stringValue = L("Give the profile a name."); return }
        guard let scanner else { messageLabel.stringValue = L("Choose a scanner."); return }
        if draft.destination.isEmpty { messageLabel.stringValue = L("Choose a folder."); return }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        onSave(ScanProfileRules.normalized(draft, for: scanner))
        close()
    }

    @objc private func cancelClicked() { close() }

    func show() {
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
