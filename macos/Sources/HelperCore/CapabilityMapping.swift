import Foundation
import UniformTypeIdentifiers

/// What one functional unit (flatbed or document feeder) reported.
public struct UnitCapabilities: Equatable, Sendable {
    public var source: Source
    public var duplex: Bool
    public var bitDepths: [Int]
    public var resolutions: [Int]
    public var preferredResolutions: [Int]
    public var physicalSizeMM: SizeMM?

    public init(source: Source, duplex: Bool, bitDepths: [Int], resolutions: [Int], preferredResolutions: [Int],
                physicalSizeMM: SizeMM? = nil) {
        self.source = source; self.duplex = duplex; self.bitDepths = bitDepths
        self.resolutions = resolutions; self.preferredResolutions = preferredResolutions
        self.physicalSizeMM = physicalSizeMM
    }
}

/// ImageCaptureCore capabilities -> protocol values. Pure, so it can be tested without a scanner.
public enum CapabilityMapping {
    public static let standardResolutions = [75, 100, 150, 200, 240, 300, 400, 600, 1200]

    public static func scannerID(persistentID: String?, uuid: String?, name: String) -> String {
        "ic:" + (persistentID ?? uuid ?? name)
    }

    public static func scannerInfo(id: String, name: String, units: [UnitCapabilities]) -> ScannerInfo? {
        let ordered = units.filter { $0.source == .feeder } + units.filter { $0.source == .flatbed }
        guard !ordered.isEmpty else { return nil }

        let depths = Set(ordered.flatMap(\.bitDepths))
        var colorModes: [ColorMode] = []
        if depths.isEmpty || depths.contains(8) { colorModes += [.color, .gray] }
        if depths.contains(1) { colorModes.append(.bw) }
        if colorModes.isEmpty { colorModes = [.color] }

        // Input order (as ImageCaptureCore listed the units), so "the first unit" is the device's own first one.
        let perUnit = units.map { unit -> [Int] in
            let standard = unit.resolutions.filter { standardResolutions.contains($0) }
            if !standard.isEmpty { return standard }
            if !unit.preferredResolutions.isEmpty { return unit.preferredResolutions }
            return unit.resolutions
        }
        var common = Set(perUnit[0])
        for list in perUnit.dropFirst() { common.formIntersection(list) }
        var resolutions = (common.isEmpty ? Set(perUnit[0]) : common).sorted()
        if resolutions.isEmpty { resolutions = [300] }

        let flatbed = units.first { $0.source == .flatbed }
        var formats = ["pdf"]
        var areas: [String] = []
        if let flatbed {
            formats = ["pdf", "jpeg", "png"]
            areas = [Areas.full]
            if let size = flatbed.physicalSizeMM {
                areas += Areas.fitting(widthMM: size.width, heightMM: size.height)
            }
        }
        return ScannerInfo(id: id, name: name, sources: ordered.map(\.source),
                           duplex: ordered.first { $0.source == .feeder }?.duplex ?? false,
                           colorModes: colorModes, resolutions: resolutions, extras: [],
                           formats: formats, areas: areas, fullAreaMM: flatbed?.physicalSizeMM)
    }

    /// The file type Image Capture writes for a scan: the requested image format, or for a PDF scan JPEG
    /// pages (PNG for black & white, which JPEG can't hold).
    public static func documentType(format: String, colorMode: ColorMode) -> UTType {
        switch format {
        case "png": return .png
        case "jpeg": return .jpeg
        default: return colorMode == .bw ? .png : .jpeg
        }
    }

    /// The scan area in inches for a flatbed whose glass is `glass` inches: `full`, no area or an unknown id
    /// is the whole glass; a fixed area is clamped to the glass.
    public static func scanAreaInches(area: String?, glass: (width: Double, height: Double))
        -> (width: Double, height: Double) {
        guard let area, area != Areas.full, let named = Areas.named(area) else { return glass }
        return (min(named.widthMM / 25.4, glass.width), min(named.heightMM / 25.4, glass.height))
    }
}
