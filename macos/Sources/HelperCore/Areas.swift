import Foundation

/// A size in millimetres.
public struct SizeMM: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Scan areas (PROTOCOL.md "Formats and areas"): the five fixed ids, `full`, and the size limit.
public enum Areas {
    public struct Area: Equatable, Sendable {
        public let id: String
        public let widthMM: Double
        public let heightMM: Double
        /// How messages name it.
        public let label: String
    }

    /// The scanner's own whole scan area, whatever its size.
    public static let full = "full"
    /// The most pixels one scan may have (inclusive); the Pi has about 3.4 GB and a scan peaks near three
    /// times its raw size.
    public static let maxPixels = 100_000_000

    public static let all: [Area] = [
        Area(id: "a4", widthMM: 210, heightMM: 297, label: "A4"),
        Area(id: "a5", widthMM: 148, heightMM: 210, label: "A5"),
        Area(id: "a6", widthMM: 105, heightMM: 148, label: "A6"),
        Area(id: "10x15", widthMM: 100, heightMM: 150, label: "10 x 15 cm"),
        Area(id: "13x18", widthMM: 130, heightMM: 180, label: "13 x 18 cm"),
    ]

    public static func named(_ id: String) -> Area? { all.first { $0.id == id } }

    /// Pixels in a scan of this size: each side rounded to whole pixels.
    public static func pixelCount(widthMM: Double, heightMM: Double, dpi: Int) -> Int {
        Int((widthMM / 25.4 * Double(dpi)).rounded()) * Int((heightMM / 25.4 * Double(dpi)).rounded())
    }

    public static func isOverLimit(_ pixels: Int) -> Bool { pixels > maxPixels }

    /// The fixed ids that fit a glass of this size (within half a millimetre), in table order.
    public static func fitting(widthMM: Double, heightMM: Double) -> [String] {
        all.filter { $0.widthMM <= widthMM + 0.5 && $0.heightMM <= heightMM + 0.5 }.map(\.id)
    }
}
