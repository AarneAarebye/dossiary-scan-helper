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
    private let languagesField = NSTextField()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var grid = NSGridView()
    private enum Row: Int { case name, scanner, folder, source, duplex, color, resolution, format, area, ocr, languages }

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
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 12

        func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
        let rows: [[NSView]] = [
            [label(L("Name")), nameField], [label(L("Scanner")), scannerPopup], [label(L("Folder")), folderRow],
            [label(L("Source")), sourcePopup], [NSView(), duplexBox], [label(L("Mode")), colorPopup],
            [label(L("Resolution")), resolutionPopup], [label(L("Format")), formatPopup], [label(L("Paper size")), areaPopup],
            [NSView(), ocrBox], [label(L("OCR languages (codes, e.g. deu, eng)")), languagesField],
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
        for box in [duplexBox, ocrBox] { box.target = self; box.action = #selector(controlChanged(_:)) }
        messageLabel.textColor = .systemRed
        let stack = NSStackView(views: [grid, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        languagesField.widthAnchor.constraint(equalToConstant: 280).isActive = true
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
        languagesField.stringValue = draft.ocrLanguages.joined(separator: ", ")
        grid.row(at: Row.source.rawValue).isHidden = o.sources.count < 2
        grid.row(at: Row.duplex.rawValue).isHidden = !o.duplexOffered
        grid.row(at: Row.area.rawValue).isHidden = o.areas.isEmpty
        let ocrShown = o.ocrOffered && draft.format == "pdf"
        grid.row(at: Row.ocr.rawValue).isHidden = !ocrShown
        grid.row(at: Row.languages.rawValue).isHidden = !(ocrShown && draft.ocr)
    }

    private func fill(_ popup: NSPopUpButton, _ items: [(String, String)], selected: String?) {
        popup.removeAllItems()
        for (value, title) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        if let index = items.firstIndex(where: { $0.0 == selected }) { popup.selectItem(at: index) }
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
        draft.ocrLanguages = languagesField.stringValue.split(whereSeparator: { ", ".contains($0) }).map(String.init)
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
