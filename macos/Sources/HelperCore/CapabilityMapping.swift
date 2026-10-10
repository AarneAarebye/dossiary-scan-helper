import Foundation

/// What one functional unit (flatbed or document feeder) reported.
public struct UnitCapabilities: Equatable, Sendable {
    public var source: Source
    public var duplex: Bool
    public var bitDepths: [Int]
    public var resolutions: [Int]
    public var preferredResolutions: [Int]

    public init(source: Source, duplex: Bool, bitDepths: [Int], resolutions: [Int], preferredResolutions: [Int]) {
        self.source = source; self.duplex = duplex; self.bitDepths = bitDepths
        self.resolutions = resolutions; self.preferredResolutions = preferredResolutions
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

        return ScannerInfo(id: id, name: name, sources: ordered.map(\.source),
                           duplex: ordered.first { $0.source == .feeder }?.duplex ?? false,
                           colorModes: colorModes, resolutions: resolutions, extras: [])
    }
}
