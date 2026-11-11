import Foundation

/// What the profile form offers for a scanner and the choices made so far.
public struct ProfileOptions: Equatable, Sendable {
    public var sources: [Source]
    public var duplexOffered: Bool
    public var colorModes: [ColorMode]
    public var resolutions: [Int]
    public var formats: [String]
    public var areas: [String]
    public var ocrOffered: Bool
    public var ocrLanguages: [String]
}

/// The rules of PROTOCOL.md "Request validation" applied to profiles: what a scanner offers, how to make a profile
/// fit a scanner, and the POST /scan body a profile stands for.
public enum ScanProfileRules {
    /// Duplex only from a duplex feeder; images only from the flatbed and never JPEG in black and white;
    /// OCR is offered when the scanner lists languages (the caller also needs format "pdf").
    public static func options(for scanner: ScannerInfo, source: Source, colorMode: ColorMode) -> ProfileOptions {
        let formats = scanner.formats.filter { format in
            if format == "pdf" { return true }
            if source == .feeder { return false }
            return !(format == "jpeg" && colorMode == .bw)
        }
        return ProfileOptions(sources: scanner.sources, duplexOffered: scanner.duplex && source == .feeder,
                              colorModes: scanner.colorModes, resolutions: scanner.resolutions, formats: formats,
                              areas: scanner.areas, ocrOffered: !scanner.ocrLanguages.isEmpty,
                              ocrLanguages: scanner.ocrLanguages)
    }

    /// `profile` made to fit `scanner`: every choice the scanner doesn't offer is replaced by the nearest or first
    /// one it does. Idempotent.
    public static func normalized(_ profile: ScanProfile, for scanner: ScannerInfo) -> ScanProfile {
        var p = profile
        p.scannerID = scanner.id
        p.scannerName = scanner.name
        if !scanner.sources.contains(p.source) { p.source = scanner.sources.first ?? .flatbed }
        if !scanner.colorModes.contains(p.colorMode) { p.colorMode = scanner.colorModes.first ?? .color }
        let o = options(for: scanner, source: p.source, colorMode: p.colorMode)
        if !o.resolutions.contains(p.resolution) { p.resolution = nearest(p.resolution, in: o.resolutions) }
        if !o.formats.contains(p.format) { p.format = "pdf" }
        p.duplex = p.duplex && o.duplexOffered
        if o.areas.isEmpty { p.area = nil }
        else if p.area.map(o.areas.contains) != true { p.area = o.areas[0] }
        if let area = p.area, let size = areaSize(area, of: scanner),
           Areas.isOverLimit(Areas.pixelCount(widthMM: size.width, heightMM: size.height, dpi: p.resolution)) {
            // The validator's size limit: the highest offered resolution that fits, or the lowest there is.
            let fitting = o.resolutions.filter {
                !Areas.isOverLimit(Areas.pixelCount(widthMM: size.width, heightMM: size.height, dpi: $0))
            }
            p.resolution = fitting.max() ?? o.resolutions.min() ?? p.resolution
        }
        if p.format == "pdf" && o.ocrOffered {
            p.ocrLanguages = p.ocrLanguages.filter(o.ocrLanguages.contains)
            if p.ocr && p.ocrLanguages.isEmpty { p.ocrLanguages = defaultLanguages(offered: o.ocrLanguages) }
        } else {
            p.ocr = false
            p.ocrLanguages = []
        }
        if !p.ocr { p.ocrLanguages = [] }
        return p
    }

    /// The POST /scan body for a profile already normalized to its scanner; defaults are left out.
    public static func requestBody(_ p: ScanProfile) -> [String: Any] {
        var body: [String: Any] = ["scanner": p.scannerID, "source": p.source.rawValue,
                                   "colorMode": p.colorMode.rawValue, "resolution": p.resolution]
        if p.duplex { body["duplex"] = true }
        if p.format != "pdf" { body["format"] = p.format }
        if let area = p.area { body["area"] = area }
        if p.ocr { body["ocr"] = true; body["ocrLanguages"] = p.ocrLanguages }
        return body
    }

    /// A stand-in for a scanner that is off or unreachable: it offers exactly the profile's own choices, so the form
    /// can still change the name and folder without touching the rest.
    public static func placeholderScanner(for p: ScanProfile) -> ScannerInfo {
        ScannerInfo(id: p.scannerID, name: p.scannerName, sources: [p.source], duplex: p.duplex, colorModes: [p.colorMode],
                    resolutions: [p.resolution], extras: [], ocrLanguages: p.ocr ? p.ocrLanguages : [],
                    formats: [p.format], areas: p.area.map { [$0] } ?? [])
    }

    /// The size of an area when it is known, as the validator knows it; nil means the limit cannot be checked.
    private static func areaSize(_ area: String, of scanner: ScannerInfo) -> SizeMM? {
        if area == Areas.full { return scanner.fullAreaMM }
        return Areas.named(area).map { SizeMM(width: $0.widthMM, height: $0.heightMM) }
    }

    private static func nearest(_ value: Int, in list: [Int]) -> Int {
        list.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    private static func defaultLanguages(offered: [String]) -> [String] {
        let preferred = ["deu", "eng"].filter(offered.contains)
        return preferred.isEmpty ? Array(offered.prefix(1)) : preferred
    }
}
