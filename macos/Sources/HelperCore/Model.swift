import Foundation

public enum Source: String, Sendable { case flatbed, feeder }
public enum ColorMode: String, Sendable { case color, gray, bw }

/// One entry of GET /scanners.
public struct ScannerInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var sources: [Source]
    public var duplex: Bool
    public var colorModes: [ColorMode]
    public var resolutions: [Int]
    public var extras: [String]

    public init(id: String, name: String, sources: [Source], duplex: Bool, colorModes: [ColorMode],
                resolutions: [Int], extras: [String]) {
        self.id = id; self.name = name; self.sources = sources; self.duplex = duplex
        self.colorModes = colorModes; self.resolutions = resolutions; self.extras = extras
    }

    public var json: [String: Any] {
        ["id": id, "name": name, "sources": sources.map(\.rawValue), "duplex": duplex,
         "colorModes": colorModes.map(\.rawValue), "resolutions": resolutions, "extras": extras]
    }
}

/// A validated POST /scan request, with every default filled in.
public struct ScanSettings: Equatable, Sendable {
    public var source: Source
    public var duplex: Bool
    public var colorMode: ColorMode
    public var resolution: Int
    public var extras: [String: Bool]

    public init(source: Source, duplex: Bool, colorMode: ColorMode, resolution: Int, extras: [String: Bool]) {
        self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.extras = extras
    }

    public func extra(_ name: String) -> Bool { extras[name] ?? false }
}

/// A protocol error: the HTTP status plus a message for a person.
public struct ProtocolError: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}
