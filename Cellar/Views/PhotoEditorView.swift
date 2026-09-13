import SwiftUI
import UIKit

/// Geometry and pixel work for the photo editor. Crop rects are normalized to the
/// image (0…1, origin top-left), so they survive layout changes and rotation.
enum PhotoEditing {
    enum Corner: String, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Aspect-fit rect for an image of `imageSize`, centered in `container`.
    static func fittedRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Moves the crop box, keeping it inside the image.
    static func move(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var r = rect.offsetBy(dx: delta.width, dy: delta.height)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        return r
    }

    /// Drags one corner. The opposite corner stays put, the box stays inside the
    /// image, and it never gets smaller than `minSize`.
    static func resize(_ rect: CGRect, corner: Corner, by delta: CGSize, minSize: CGSize) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let leading = corner == .topLeading || corner == .bottomLeading
        let top = corner == .topLeading || corner == .topTrailing
        if leading {
            minX = min(max(minX + delta.width, 0), maxX - minSize.width)
        } else {
            maxX = max(min(maxX + delta.width, 1), minX + minSize.width)
        }
        if top {
            minY = min(max(minY + delta.height, 0), maxY - minSize.height)
        } else {
            maxY = max(min(maxY + delta.height, 1), minY + minSize.height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where the crop box lands after the photo turns 90° counter-clockwise.
    static func rotatedLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
    }

    /// Redraws the photo upright at scale 1, so pixel crops line up with what's shown.
    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.scale != 1 else { return image }
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    /// Turns the photo 90° counter-clockwise.
    static func rotateLeft(_ image: UIImage) -> UIImage {
        let source = normalized(image)
        let newSize = CGSize(width: source.size.height, height: source.size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { ctx in
            ctx.cgContext.translateBy(x: 0, y: newSize.height)
            ctx.cgContext.rotate(by: -.pi / 2)
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
    }

    /// Crops the photo to a normalized rect.
    static func crop(_ image: UIImage, to rect: CGRect) -> UIImage {
        let source = normalized(image)
        let r = rect.intersection(unit)
        guard !r.isNull, r.width > 0, r.height > 0, let cg = source.cgImage else { return source }
        let pixels = CGRect(x: r.minX * CGFloat(cg.width), y: r.minY * CGFloat(cg.height),
                            width: r.width * CGFloat(cg.width), height: r.height * CGFloat(cg.height)).integral
        guard let cropped = cg.cropping(to: pixels) else { return source }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

/// Crop and rotate a label photo: drag a corner to resize the crop box, drag
/// inside it to move it, and rotate in 90° steps.
struct PhotoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: (UIImage) -> Void

    @State private var image: UIImage
    @State private var crop = PhotoEditing.unit
    @State private var cropAtDragStart: CGRect?

    init(image: UIImage, onDone: @escaping (UIImage) -> Void) {
        _image = State(initialValue: PhotoEditing.normalized(image))
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = PhotoEditing.fittedRect(
                    imageSize: image.size,
                    in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 24, dy: 24))
                let box = CGRect(x: frame.minX + crop.minX * frame.width,
                                 y: frame.minY + crop.minY * frame.height,
                                 width: crop.width * frame.width,
                                 height: crop.height * frame.height)
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .accessibilityHidden(true)

                    // Dim everything outside the crop box.
                    Path { p in
                        p.addRect(frame)
                        p.addRect(box)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    cropBox
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let start = cropAtDragStart ?? crop
                                    cropAtDragStart = start
                                    crop = PhotoEditing.move(start, by: normalized(value.translation, in: frame))
                                }
                                .onEnded { _ in cropAtDragStart = nil })

                    ForEach(PhotoEditing.Corner.allCases, id: \.self) { corner in
                        handle(corner, box: box, frame: frame)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Edit photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(PhotoEditing.crop(image, to: crop))
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        image = PhotoEditing.rotateLeft(image)
                        crop = PhotoEditing.rotatedLeft(crop)
                    } label: {
                        Label("Rotate left", systemImage: "rotate.left")
                    }
                    Spacer()
                    Button("Reset") { crop = PhotoEditing.unit }
                        .disabled(crop == PhotoEditing.unit)
                }
            }
        }
    }

    /// White frame with rule-of-thirds guides; dragging inside moves it.
    private var cropBox: some View {
        Rectangle()
            .stroke(Color.white, lineWidth: 2)
            .overlay {
                GeometryReader { g in
                    Path { p in
                        for i in 1..<3 {
                            let x = g.size.width * CGFloat(i) / 3
                            let y = g.size.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel("Crop area")
            .accessibilityIdentifier("cropBox")
    }

    private func handle(_ corner: PhotoEditing.Corner, box: CGRect, frame: CGRect) -> some View {
        let point: CGPoint
        switch corner {
        case .topLeading: point = CGPoint(x: box.minX, y: box.minY)
        case .topTrailing: point = CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeading: point = CGPoint(x: box.minX, y: box.maxY)
        case .bottomTrailing: point = CGPoint(x: box.maxX, y: box.maxY)
        }
        return Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = cropAtDragStart ?? crop
                        cropAtDragStart = start
                        // Keep the box at least 44 points on screen.
                        let minSize = CGSize(width: 44 / max(frame.width, 1), height: 44 / max(frame.height, 1))
                        crop = PhotoEditing.resize(start, corner: corner,
                                                   by: normalized(value.translation, in: frame), minSize: minSize)
                    }
                    .onEnded { _ in cropAtDragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Crop corner")
            .accessibilityIdentifier("cropHandle.\(corner.rawValue)")
    }

    private func normalized(_ translation: CGSize, in frame: CGRect) -> CGSize {
        CGSize(width: translation.width / max(frame.width, 1), height: translation.height / max(frame.height, 1))
    }
}

#if DEBUG
/// Test-only assets (UI tests can't drive the system photo picker).
enum UITestFixtures {
    /// A portrait 900×1200 label photo.
    static func labelPhotoJPEG() -> Data? {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.95, green: 0.92, blue: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.44, green: 0.08, blue: 0.18, alpha: 1).setFill()
            ctx.fill(CGRect(x: 120, y: 300, width: 660, height: 520))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 110),
                                                        .foregroundColor: UIColor.white]
            ("OPUS ONE" as NSString).draw(at: CGPoint(x: 175, y: 470), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
#endif
