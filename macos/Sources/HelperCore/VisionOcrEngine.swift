import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Real text recognition: Vision's accurate recognizer on each page, the lines drawn as invisible text over
/// the unchanged page image. A page Vision can't read is left without text; only an unreadable image fails.
public struct VisionOcrEngine: OcrEngine {
    public init() {}

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

    public func makeSearchable(_ input: OcrJobInput) async throws -> Data {
        let languages = OcrLanguages.visionLanguages(for: input.languages)
        var text: [[OcrLine]] = []
        for page in input.pages {
            guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProtocolError(500, "A scanned page couldn't be read for text recognition.")
            }
            text.append((try? VisionOcrEngine.recognize(image, languages: languages)) ?? [])
        }
        return try PdfBuilder.makePdf(input.pages, text: text)
    }
}
