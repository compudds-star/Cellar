import SwiftUI
import SwiftData
import PhotosUI

/// Add a wine to the cellar — either by scanning a label (pre-fills the fields)
/// or entering everything by hand. Same form both ways; scanning only seeds it.
struct AddWineFlow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    // Wine fields
    @State private var producer = ""
    @State private var name = ""
    @State private var varietal = ""
    @State private var region = ""
    @State private var country = ""
    @State private var vintageText = ""
    @State private var type: WineType = .red
    @State private var notes = ""
    @State private var labelImage: Data?

    // Valuation + inventory
    @State private var estimateText = ""
    @State private var quantity = 1
    @State private var size: BottleSize = .standard
    @State private var priceText = ""
    @State private var storageLocation = ""

    @State private var showingScanner = false
    @State private var photoItem: PhotosPickerItem?

    private var canSave: Bool {
        !producer.trimmingCharacters(in: .whitespaces).isEmpty
        || !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan label", systemImage: "camera.viewfinder")
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(labelImage == nil ? "Add label photo" : "Change label photo",
                              systemImage: "photo")
                    }
                    if let labelImage, let ui = UIImage(data: labelImage) {
                        Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 160)
                    }
                }

                Section("Wine") {
                    TextField("Producer", text: $producer)
                    TextField("Cuvée / name", text: $name)
                    TextField("Varietal", text: $varietal)
                    TextField("Region", text: $region)
                    TextField("Country", text: $country)
                    TextField("Vintage (blank = NV)", text: $vintageText)
                        .keyboardType(.numberPad)
                    Picker("Type", selection: $type) {
                        ForEach(WineType.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("Estimated value") {
                    HStack {
                        Text("Per 750 mL")
                        Spacer()
                        TextField("0.00", text: $estimateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Manual estimate. You can update it any time; online pricing can fill this in later.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Add to cellar") {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...240)
                    Picker("Size", selection: $size) {
                        ForEach(BottleSize.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Text("Price paid (each)")
                        Spacer()
                        TextField("0.00", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Storage location", text: $storageLocation)
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .navigationTitle("Add wine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingScanner) {
                ScanSheet { parsed in apply(parsed) }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        labelImage = ImageResizer.jpeg(from: data, maxDimension: 1200)
                    }
                }
            }
        }
    }

    private func apply(_ parsed: ParsedLabel) {
        if !parsed.producer.isEmpty { producer = parsed.producer }
        if !parsed.name.isEmpty { name = parsed.name }
        if !parsed.varietal.isEmpty { varietal = parsed.varietal }
        if !parsed.region.isEmpty { region = parsed.region }
        if !parsed.country.isEmpty { country = parsed.country }
        if let v = parsed.vintage { vintageText = String(v) }
        type = parsed.type
    }

    private func save() {
        let wine = Wine(
            name: name.trimmingCharacters(in: .whitespaces),
            producer: producer.trimmingCharacters(in: .whitespaces),
            varietal: varietal.trimmingCharacters(in: .whitespaces),
            region: region.trimmingCharacters(in: .whitespaces),
            country: country.trimmingCharacters(in: .whitespaces),
            vintage: Int(vintageText),
            type: type,
            labelImage: labelImage,
            notes: notes,
            manualEstimatedValue: Decimal(string: estimateText))
        context.insert(wine)

        let price = Decimal(string: priceText)
        for _ in 0..<quantity {
            let bottle = Bottle(size: size,
                                purchasePrice: price,
                                purchaseDate: price != nil ? .now : nil,
                                storageLocation: storageLocation)
            bottle.wine = wine
            context.insert(bottle)
        }
        dismiss()
    }
}

/// Downscales/re-encodes image data so label photos don't bloat the store.
enum ImageResizer {
    static func jpeg(from data: Data, maxDimension: CGFloat, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }
}
