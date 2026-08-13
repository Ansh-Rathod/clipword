import AppKit
import Vision

enum OCRService {
    static func recognizeText(from imageData: Data) async -> String? {
        guard let image = NSImage(data: imageData),
              let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let strings = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                continuation.resume(returning: strings)
            }
            request.recognitionLevel = .fast
            let handler = VNImageRequestHandler(ciImage: ciImage)
            try? handler.perform([request])
        }
    }
}
