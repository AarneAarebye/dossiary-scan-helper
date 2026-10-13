import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Real text recognition: Vision's accurate recognizer on each page, the lines drawn as invisible text over
/// the unchanged page image. A page Vision can't read is left without text; only an unreadable image fails.
public struct VisionOcrEngine: OcrEngine {
    let recognizer: @Sendable (CGImage, [String]) throws -> [OcrLine]

    public init() { self.init(recognizer: { try VisionOcrEngine.recognize($0, languages: $1) }) }

    /// Tests pass their own recognizer.
    init(recognizer: @escaping @Sendable (CGImage, [String]) throws -> [OcrLine]) { self.recognizer = recognizer }

    /// The protocol codes this Mac's Vision can recognize.
    public static func offeredCodes() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return OcrLanguages.offered(supportedVision: supported)
    }

    static func recognize(_ image: CGImage, languages: [String]) throws -> [OcrLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OcrLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    /// Vision blocks its thread for seconds per page, so it runs on its own queue, not the cooperative pool.
    private static let workQueue = DispatchQueue(label: "dossiary-scan-helper.vision-ocr", qos: .utility)

    public func makeSearchable(_ input: OcrJobInput) async throws -> Data {
        let languages = OcrLanguages.visionLanguages(for: input.languages)
        let recognizer = self.recognizer
        let pages = input.pages
        let text: [[OcrLine]] = try await withCheckedThrowingContinuation { continuation in
            VisionOcrEngine.workQueue.async {
                continuation.resume(with: Result {
                    try VisionOcrEngine.recognizeAll(pages, languages: languages, recognizer: recognizer)
                })
            }
        }
        return try PdfBuilder.makePdf(input.pages, text: text)
    }

    /// A page recognized without text stays without text; recognition failing on every page fails the job.
    static func recognizeAll(_ pages: [PageImage], languages: [String],
                             recognizer: (CGImage, [String]) throws -> [OcrLine]) throws -> [[OcrLine]] {
        var text: [[OcrLine]] = []
        var failures = 0
        for page in pages {
            let lines: [OcrLine]? = try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ProtocolError(500, "A scanned page couldn't be read for text recognition.")
                }
                return try? recognizer(image, languages)
            }
            if lines == nil { failures += 1 }
            text.append(lines ?? [])
        }
        if !pages.isEmpty && failures == pages.count {
            throw ProtocolError(500, "Text recognition failed on every page.")
        }
        return text
    }
}
