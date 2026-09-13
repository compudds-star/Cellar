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
                Text(buffer.lines.prefix(3).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white)
                    .lineLimit(2).padding(.horizontal)
            }
            Button {
                let parsed = LabelParser.parse(lines: buffer.lines)
                Task {
                    let image = await buffer.capturePhoto()
                    onParsed(parsed, image)
                    dismiss()
                }
            } label: {
                Label("Use this label", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(buffer.lines.isEmpty)
            .padding()
        }
        .background(.ultraThinMaterial)
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
                    let lines = await ImageTextRecognizer.recognize(in: image)
                    onParsed(LabelParser.parse(lines: lines), image)
                }
                busy = false
                dismiss()
            }
        }
    }
}
