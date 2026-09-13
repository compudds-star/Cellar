import SwiftUI
import VisionKit
import Vision
import UIKit

/// Live label scanner built on VisionKit's `DataScannerViewController`. It reads
/// text off the label continuously; when the user taps "Use this label" the
/// sheet reads a sharp still photo and tops it up with these live lines.
///
/// Availability: DataScanner needs a device with the Neural Engine and a camera.
/// Always gate on `DataScannerViewController.isSupported && .isAvailable` and
/// fall back to the photo-OCR path (`ImageTextRecognizer`) otherwise.
/// Shared, observable sink for recognized text. The SwiftUI layer owns it and
/// reads `lines` when the user taps capture; the scanner coordinator fills it.
final class ScanBuffer: ObservableObject {
    @Published private(set) var lines: [LabelTextLine] = []
    /// Set by the representable so the SwiftUI layer can grab a still frame.
    weak var scanner: DataScannerViewController?

    /// Merge the text currently in view. Keeps the largest size seen per line and
    /// drops partial reads ("Opus" once "Opus One" has been read), so jitter and
    /// half-read words don't pile up.
    func ingest(_ newLines: [LabelTextLine]) {
        var merged = lines
        for line in newLines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = text.lowercased()
            guard !key.isEmpty else { continue }
            if let i = merged.firstIndex(where: { $0.text.lowercased() == key }) {
                merged[i].height = max(merged[i].height, line.height)
            } else if merged.contains(where: { $0.text.lowercased().contains(key) }) {
                continue
            } else {
                merged.removeAll { key.contains($0.text.lowercased()) }
                merged.append(LabelTextLine(text: text, height: line.height))
            }
        }
        if merged != lines { lines = merged }
    }
    func reset() { lines = [] }

    /// Capture a still photo of the current frame (the scanned label).
    @MainActor
    func capturePhoto() async -> UIImage? {
        try? await scanner?.capturePhoto()
    }
}

struct LabelScannerView: UIViewControllerRepresentable {
    let buffer: ScanBuffer

    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text(languages: ImageTextRecognizer.preferredLanguages)],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        context.coordinator.scanner = scanner
        buffer.scanner = scanner
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        weak var scanner: DataScannerViewController?
        let buffer: ScanBuffer

        init(buffer: ScanBuffer) { self.buffer = buffer }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            ingest(allItems, in: dataScanner)
        }
        func dataScanner(_ dataScanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            ingest(allItems, in: dataScanner)
        }

        private func ingest(_ items: [RecognizedItem], in dataScanner: DataScannerViewController) {
            let viewHeight = max(dataScanner.view.bounds.height, 1)
            let lines: [LabelTextLine] = items.compactMap {
                guard case let .text(text) = $0 else { return nil }
                // Height along the text's own left edge, so tilted text measures right.
                let b = text.bounds
                let h = hypot(b.bottomLeft.x - b.topLeft.x, b.bottomLeft.y - b.topLeft.y)
                return LabelTextLine(text: text.transcript, height: Double(h / viewHeight))
            }
            buffer.ingest(lines)
        }
    }
}

/// Still-image OCR: the accurate path used on the captured label photo, a picked
/// photo, and when the live scanner is unsupported.
enum ImageTextRecognizer {
    /// Languages wine labels are usually printed in.
    static let preferredLanguages = ["en-US", "fr-FR", "it-IT", "es-ES", "de-DE", "pt-BR"]

    static func recognize(in image: UIImage) async -> [String] {
        await recognizeLines(in: image).map(\.text)
    }

    /// Reads each line with its printed size. Honors the photo's orientation
    /// (camera photos are stored sideways), uses the label languages above, and
    /// biases recognition toward wine vocabulary (`LabelVocabulary`).
    static func recognizeLines(in image: UIImage, customWords: [String]? = nil) async -> [LabelTextLine] {
        guard let cg = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let words = customWords ?? LabelVocabulary.words()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                if VNRecognizeTextRequest.supportedRevisions.contains(VNRecognizeTextRequestRevision3) {
                    request.revision = VNRecognizeTextRequestRevision3
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                if let supported = try? request.supportedRecognitionLanguages() {
                    let languages = preferredLanguages.filter(supported.contains)
                    if !languages.isEmpty { request.recognitionLanguages = languages }
                }
                request.customWords = words
                let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { obs -> LabelTextLine? in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    return LabelTextLine(text: text, height: Double(obs.boundingBox.height))
                }
                continuation.resume(returning: lines)
            }
        }
    }
}

/// Words Vision should expect on a wine label: grapes, regions, and — when the
/// LWIN list is small enough to pass along — producer and wine names.
enum LabelVocabulary {
    static func words(database: LWINDatabase = .shared) -> [String] {
        var set = Set<String>()
        func add(_ s: String) {
            for w in s.split(whereSeparator: { !$0.isLetter }) where w.count >= 4 {
                set.insert(String(w).capitalized)
            }
        }
        LabelParser.varietals.forEach(add)
        LabelParser.regionCountry.keys.forEach(add)
        if database.isLoaded, database.records.count <= 5_000 {
            for record in database.records {
                add(record.producerName)
                add(record.wine)
            }
        }
        return set.sorted()
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
