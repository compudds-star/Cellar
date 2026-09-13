import SwiftUI
import VisionKit
import PhotosUI

/// Presents the live label scanner (or a photo-OCR fallback) and returns the
/// parsed label to the caller.
struct ScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Returns the parsed label plus a still photo of it (nil if capture failed).
    var onParsed: (ParsedLabel, UIImage?) -> Void

    @StateObject private var buffer = ScanBuffer()
    @State private var photoItem: PhotosPickerItem?
    @State private var busy = false

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if scannerAvailable {
                    LabelScannerView(buffer: buffer)
                        .ignoresSafeArea()
                    VStack {
                        Spacer()
                        capturePanel
                    }
                } else {
                    unsupportedFallback
                }
            }
            .navigationTitle("Scan label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var capturePanel: some View {
        VStack(spacing: 8) {
            if !buffer.lines.isEmpty {
                // Largest print first — roughly what will become producer and name.
                Text(buffer.lines.sorted { $0.height > $1.height }.prefix(3).map(\.text).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white)
                    .lineLimit(2).padding(.horizontal)
            }
            Text("Hold the label flat and fill the frame")
                .font(.caption2).foregroundStyle(.white.opacity(0.8))
            Button {
                Task { await useLabel() }
            } label: {
                Group {
                    if busy {
                        ProgressView()
                    } else {
                        Label("Use this label", systemImage: "checkmark.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(buffer.lines.isEmpty || busy)
            .padding()
        }
        .background(.ultraThinMaterial)
    }

    /// Reads the label from a sharp still photo (more accurate than the live
    /// preview), topped up with anything the live scanner caught that the photo
    /// missed.
    private func useLabel() async {
        busy = true
        let image = await buffer.capturePhoto()
        var photoLines: [LabelTextLine] = []
        if let image { photoLines = await ImageTextRecognizer.recognizeLines(in: image) }
        let lines = LabelParser.mergeLines(photo: photoLines, live: buffer.lines)
        onParsed(LabelParser.parse(textLines: lines), image)
        busy = false
        dismiss()
    }

    private var unsupportedFallback: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder").font(.largeTitle)
            Text("Live scanning isn't available on this device.")
                .multilineTextAlignment(.center)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Pick a label photo", systemImage: "photo")
            }
            .buttonStyle(.borderedProminent)
            if busy { ProgressView() }
        }
        .padding()
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            busy = true
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let lines = await ImageTextRecognizer.recognizeLines(in: image)
                    onParsed(LabelParser.parse(textLines: lines), image)
                }
                busy = false
                dismiss()
            }
        }
    }
}
