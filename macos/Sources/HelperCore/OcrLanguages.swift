import Foundation

/// The protocol's Tesseract-style OCR codes and the Vision languages they stand for.
public enum OcrLanguages {
    public static let all: [(code: String, vision: String)] = [
        ("deu", "de-DE"), ("eng", "en-US"), ("fra", "fr-FR"), ("spa", "es-ES"),
        ("chi_sim", "zh-Hans"), ("chi_tra", "zh-Hant"),
    ]
    /// The helper's choice when a request names no languages.
    public static let defaultCodes = ["deu", "eng"]

    public static func visionLanguage(for code: String) -> String? { all.first { $0.code == code }?.vision }

    /// The codes a real scanner offers: those whose Vision language this Mac supports, in `all` order.
    public static func offered(supportedVision: [String]) -> [String] {
        all.filter { supportedVision.contains($0.vision) }.map(\.code)
    }

    /// Vision languages for a request's codes, in request order; the default codes when none are given.
    public static func visionLanguages(for codes: [String]) -> [String] {
        (codes.isEmpty ? defaultCodes : codes).compactMap(visionLanguage(for:))
    }
}
