import SwiftUI
import VisionKit
import Vision
import UIKit

/// Live label scanner built on VisionKit's `DataScannerViewController`. It reads
/// text off the label continuously; the accumulated lines are handed to
/// `LabelParser` when the user taps "Use this label".
///
/// Availability: DataScanner needs a device with the Neural Engine and a camera.
/// Always gate on `DataScannerViewController.isSupported && .isAvailable` and
/// fall back to the photo-OCR path (`ImageTextRecognizer`) otherwise.
/// Shared, observable sink for recognized text. The SwiftUI layer owns it and
/// reads `lines` when the user taps capture; the scanner coordinator fills it.
final class ScanBuffer: ObservableObject {
    @Published private(set) var lines: [String] = []
    private var seenSet: Set<String> = []

    func ingest(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !seenSet.contains(t) else { return }
        seenSet.insert(t)
        lines.append(t)
    }
    func reset() { lines = []; seenSet = [] }
}

struct LabelScannerView: UIViewControllerRepresentable {
    let buffer: ScanBuffer

    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        context.coordinator.scanner = scanner
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        weak var scanner: DataScannerViewController?
        let buffer: ScanBuffer

        init(buffer: ScanBuffer) { self.buffer = buffer }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            ingest(allItems)
        }
        func dataScanner(_ dataScanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            ingest(allItems)
        }

        private func ingest(_ items: [RecognizedItem]) {
            let strings: [String] = items.compactMap {
                if case let .text(text) = $0 { return text.transcript }
                return nil
            }
            // Hop to main: ScanBuffer is @Published (main-actor state).
            DispatchQueue.main.async { strings.forEach(self.buffer.ingest) }
        }
    }
}

/// Still-image OCR fallback for when the live scanner is unsupported, or the
/// user picks a photo. Runs a single `VNRecognizeTextRequest`.
enum ImageTextRecognizer {
    static func recognize(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
            }
        }
    }
}
