import SwiftUI
import SwiftData
import PhotosUI

/// Add a wine to the cellar — either by scanning a label (pre-fills the fields)
/// or entering everything by hand. Same form both ways; scanning only seeds it.
struct AddWineFlow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    enum Destination: String, CaseIterable, Identifiable {
        case cellar = "Cellar", wishlist = "Wishlist"
        var id: String { rawValue }
    }
    @State private var destination: Destination = .cellar

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
    @State private var rating = 0            // 0 = unrated (100-pt scale)
    @State private var estimateText = ""
    @State private var quantity = 1
    @State private var size: BottleSize = BottleSize.defaultSize(for: .red)
    @State private var priceText = ""
    @State private var storageLocation = ""
    @State private var drinkFromText = ""
    @State private var drinkToText = ""
    /// The window we suggested from the vintage. Kept so a later edit to the
    /// wine can replace our own suggestion without overwriting a year the user
    /// typed themselves.
    @State private var suggestedWindow: DrinkWindow?

    // Reading the label
    @State private var readingLabel = false
    /// Offered when the text was too damaged to identify the bottle. The photo
    /// is only ever sent from this button.
    @State private var offerPhotoRead = false
    @State private var readingError: String?
    /// What we last filled in ourselves, so a better reading can correct our own
    /// guesses without overwriting a word the user typed over them.
    @State private var lastAutoFill = ParsedLabel()

    @State private var showingScanner = false
    @State private var showingLWIN = false
    @State private var photoItem: PhotosPickerItem?
    @State private var editingPhoto = false
    @State private var takingPhoto = false
    @State private var didAutoStartScanner = false
    @State private var collection: CellarCollection?

    // Canonical LWIN identity, once matched.
    @State private var lwin7: String?
    @State private var lwinTitle = ""

    private var vintageInt: Int? { Int(vintageText) }
    private var canMatchLWIN: Bool {
        !producer.trimmingCharacters(in: .whitespaces).isEmpty
        || !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool {
        !producer.trimmingCharacters(in: .whitespaces).isEmpty
        || !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True while the drink-window fields still hold exactly what we suggested,
    /// so the caption explains a suggestion and never the user's own years.
    private var showingSuggestedWindow: Bool {
        guard let window = suggestedWindow else { return false }
        return drinkFromText == String(window.from) && drinkToText == String(window.to)
    }

    /// Fill the drink window from the vintage. Runs whenever the details that
    /// feed the estimate change, but only over blank fields or its own last
    /// suggestion — a year the user typed is never overwritten.
    private func suggestDrinkWindow() {
        let blank = drinkFromText.isEmpty && drinkToText.isEmpty
        guard blank || showingSuggestedWindow else { return }
        let window = DrinkWindowEstimate.window(vintage: vintageInt, type: type,
                                                varietal: varietal, region: region, country: country)
        drinkFromText = window.map { String($0.from) } ?? ""
        drinkToText = window.map { String($0.to) } ?? ""
        suggestedWindow = window
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Save to", selection: $destination) {
                        ForEach(Destination.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

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
                    if CameraCaptureView.isAvailable {
                        Button {
                            takingPhoto = true
                        } label: {
                            Label(labelImage == nil ? "Take label photo" : "Retake label photo",
                                  systemImage: "camera")
                        }
                    }
                    if let labelImage, let ui = UIImage(data: labelImage) {
                        Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 160)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Label photo")
                            .accessibilityIdentifier("labelPhoto")
                            .accessibilityValue("\(Int(ui.size.width))×\(Int(ui.size.height))" as String)
                        HStack {
                            Button {
                                editingPhoto = true
                            } label: {
                                Label("Edit photo", systemImage: "crop")
                            }
                            Spacer()
                            Button(role: .destructive) {
                                self.labelImage = nil
                                photoItem = nil
                            } label: {
                                Label("Remove photo", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if readingLabel || offerPhotoRead || readingError != nil {
                    Section {
                        if readingLabel {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Reading the label…").foregroundStyle(.secondary)
                            }
                        } else if offerPhotoRead {
                            Button {
                                Task { await readLabelPhoto() }
                            } label: {
                                Label("Read the photo instead", systemImage: "sparkle.magnifyingglass")
                            }
                            Text("The text came back too garbled to place. This sends the photo itself to be read — the only time a label picture leaves your phone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let readingError {
                            Text(readingError).font(.caption).foregroundStyle(.orange)
                        }
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
                    WineTypePicker(selection: $type)
                }

                Section("Wine identity (LWIN)") {
                    if let lwin7 {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lwinTitle.isEmpty ? "Matched" : lwinTitle).lineLimit(1)
                                Text("LWIN \(lwin7)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Change") { showingLWIN = true }
                        }
                    } else {
                        Button {
                            showingLWIN = true
                        } label: {
                            Label("Find LWIN match", systemImage: "checkmark.seal")
                        }
                        .disabled(!canMatchLWIN)
                        Text("Optional. Snaps this wine to a canonical identity for de-duping and price lookups.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Your rating") {
                    HStack {
                        StarRating(rating: $rating)
                        Spacer()
                        if rating > 0 {
                            Button("Clear") { rating = 0 }
                                .font(.caption).buttonStyle(.borderless)
                        }
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

                if destination == .cellar {
                Section("Add to cellar") {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...240)
                    BottleSizePicker(selection: $size)
                    CollectionPicker(selection: $collection)
                    HStack {
                        Text("Price paid (per bottle)")
                        Spacer()
                        TextField("0.00", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Storage location", text: $storageLocation)
                    HStack {
                        TextField("Drink from (year)", text: $drinkFromText)
                            .keyboardType(.numberPad)
                        Divider()
                        TextField("Drink to (year)", text: $drinkToText)
                            .keyboardType(.numberPad)
                    }
                    if showingSuggestedWindow {
                        Text("Estimated peak for the style — edit if you disagree.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
                }
            }
            // Suggest a drink window as soon as there's a vintage to count from.
            .onChange(of: vintageText) { suggestDrinkWindow() }
            .onChange(of: varietal) { suggestDrinkWindow() }
            .onChange(of: region) { suggestDrinkWindow() }
            .onChange(of: country) { suggestDrinkWindow() }
            // Follow the type's default size (750 mL wine, 1 L spirits) until the user picks one.
            .onChange(of: type) { oldType, newType in
                suggestDrinkWindow()
                if size == BottleSize.defaultSize(for: oldType) {
                    size = BottleSize.defaultSize(for: newType)
                }
            }
            .onAppear {
                // New bottles start in the default collection (Settings).
                if collection == nil { collection = CollectionMemory.defaultCollection(in: context) }
            }
            .task {
                // Start with the camera: a new bottle usually begins with its label.
                // Cancelling the scan leaves the empty form for typing details instead.
                guard !didAutoStartScanner, labelImage == nil, ScanSheet.liveScanningAvailable else { return }
                didAutoStartScanner = true
                // Let this sheet finish presenting before stacking the scanner on top.
                try? await Task.sleep(for: .milliseconds(350))
                showingScanner = true
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
                ScanSheet { parsed, image in
                    apply(parsed)
                    if let image, let data = image.jpegData(compressionQuality: 0.9) {
                        labelImage = ImageResizer.jpeg(from: data, maxDimension: 1200)
                    }
                    // The heuristics have filled what they can; now let the reader
                    // straighten out the garbled characters and the wrong fields.
                    Task { await refineReading(from: parsed.rawLines) }
                }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraCaptureView { image in
                    Task { await useLabelPhoto(image) }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $editingPhoto) {
                if let data = labelImage, let ui = UIImage(data: data) {
                    PhotoEditorView(image: ui) { edited in
                        labelImage = ImageResizer.jpeg(from: edited, maxDimension: 1200, quality: 0.85)
                    }
                }
            }
            #if DEBUG
            .onAppear {
                // UI tests can't drive the system photo picker; seed a label photo instead.
                if labelImage == nil, ProcessInfo.processInfo.arguments.contains("-UITestSeedLabelPhoto") {
                    labelImage = UITestFixtures.labelPhotoJPEG()
                }
            }
            #endif
            .sheet(isPresented: $showingLWIN) {
                LWINMatchView(producer: producer, name: name, region: region,
                              vintage: vintageInt) { record in
                    applyLWIN(record)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await useLabelPhoto(image)
                    }
                }
            }
        }
    }

    /// Stores a picked or camera photo, and reads the label — but only into an empty
    /// form, never over what the user already typed.
    private func useLabelPhoto(_ image: UIImage) async {
        labelImage = ImageResizer.jpeg(from: image, maxDimension: 1200)
        if producer.isEmpty, name.isEmpty {
            let lines = await ImageTextRecognizer.recognizeLines(in: image)
            if !lines.isEmpty {
                apply(LabelParser.parse(textLines: lines))
                await refineReading(from: lines.map(\.text))
            }
        }
    }

    /// Sends the recognised *text* to be read properly — the photo stays here.
    /// Silent on failure: this only ever improves a form the user can edit, so a
    /// network hiccup shouldn't interrupt them.
    private func refineReading(from lines: [String]) async {
        guard LabelAI.isAvailable, !lines.isEmpty else { return }
        readingLabel = true
        defer { readingLabel = false }
        do {
            let reading = try await LabelAI.refine(lines: lines)
            apply(reading.label, from: reading)
            // Too damaged to identify from the text alone — offer the photo,
            // rather than sending it unasked.
            offerPhotoRead = reading.confidence == .low && labelImage != nil
        } catch {
            offerPhotoRead = labelImage != nil
        }
    }

    /// The photo route, and only from a button the person pressed.
    private func readLabelPhoto() async {
        guard let data = labelImage, let image = UIImage(data: data) else { return }
        readingLabel = true
        defer { readingLabel = false }
        do {
            let reading = try await LabelAI.read(photo: image)
            apply(reading.label, from: reading)
            offerPhotoRead = false
        } catch {
            readingError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A better reading of the same label. Each field is replaced only where it
    /// still holds what we put there (or nothing) — anything the user has typed
    /// over stands, because they can see the bottle and we can't.
    private func apply(_ parsed: ParsedLabel, from reading: LabelAI.Reading) {
        func adopt(_ new: String, _ current: inout String, _ mine: String) {
            guard !new.isEmpty, current.isEmpty || current == mine else { return }
            current = new
        }
        adopt(parsed.producer, &producer, lastAutoFill.producer)
        adopt(parsed.name, &name, lastAutoFill.name)
        adopt(parsed.varietal, &varietal, lastAutoFill.varietal)
        adopt(parsed.region, &region, lastAutoFill.region)
        adopt(parsed.country, &country, lastAutoFill.country)
        if let v = parsed.vintage {
            let mine = lastAutoFill.vintage.map(String.init) ?? ""
            adopt(String(v), &vintageText, mine)
        }
        if type == lastAutoFill.type { type = parsed.type }
        lastAutoFill = parsed
        matchLWIN()
    }

    private func apply(_ parsed: ParsedLabel) {
        if !parsed.producer.isEmpty { producer = parsed.producer }
        if !parsed.name.isEmpty { name = parsed.name }
        if !parsed.varietal.isEmpty { varietal = parsed.varietal }
        if !parsed.region.isEmpty { region = parsed.region }
        if !parsed.country.isEmpty { country = parsed.country }
        if let v = parsed.vintage { vintageText = String(v) }
        type = parsed.type
        lastAutoFill = parsed
        matchLWIN(rawLines: parsed.rawLines)
    }

    /// Snap to an LWIN match only when it's confident AND clearly ahead of the
    /// runner-up; otherwise leave it to "Find LWIN match" so the user picks.
    ///
    /// When the fields don't match anything — which is what happens when OCR
    /// mangled them — try the raw recognised text as one query. The index is
    /// token-based, so a line with two words right out of four can still land on
    /// the correct wine where the tidied fields did not.
    private func matchLWIN(rawLines: [String] = []) {
        guard lwin7 == nil else { return }
        let matcher = LWINMatcher()
        if let pick = LWINMatcher.confidentPick(
            matcher.bestMatches(producer: producer, name: name, region: region,
                                vintage: vintageInt, limit: 2)) {
            applyLWIN(pick.record)
            return
        }
        guard !rawLines.isEmpty else { return }
        let text = rawLines.joined(separator: " ")
        if let pick = LWINMatcher.confidentPick(
            matcher.bestMatches(producer: text, name: "", region: "",
                                vintage: vintageInt, limit: 2)) {
            applyLWIN(pick.record)
        }
    }

    /// Adopt a chosen LWIN record: store the identity and backfill any blank fields.
    private func applyLWIN(_ record: LWINRecord) {
        lwin7 = record.lwin7
        lwinTitle = record.title
        if producer.isEmpty { producer = record.producerName }
        if name.isEmpty { name = record.wine }
        if region.isEmpty { region = record.region }
        if country.isEmpty { country = record.country }
        // Type from the record: sparkling, fortified, spirit category, or colour.
        if let recordType = WineType(lwinType: record.type, colour: record.colour) {
            type = recordType
        }
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
            lwin7: lwin7,
            labelImage: labelImage,
            notes: notes,
            manualEstimatedValue: BottleDraft.decimal(from: estimateText),
            rating: rating > 0 ? rating : nil,
            isWishlist: destination == .wishlist)
        context.insert(wine)

        if destination == .cellar {
            let price = BottleDraft.decimal(from: priceText)
            for _ in 0..<quantity {
                let bottle = Bottle(size: size,
                                    purchasePrice: price,
                                    purchaseDate: price != nil ? .now : nil,
                                    storageLocation: storageLocation,
                                    drinkFrom: Int(drinkFromText),
                                    drinkTo: Int(drinkToText))
                context.insert(bottle)
                wine.bottles.append(bottle)
                bottle.collection = collection
            }
            CollectionMemory.remember(collection)
            // Schedule drink-window reminders for the newly added bottles.
            Task { DrinkWindowNotifier.schedule(for: wine) }
        }
        // Look up the market price in the background (skipped if no endpoint is set).
        PriceLookup.start(for: wine, context: context)
        dismiss()
    }
}

/// Downscales/re-encodes image data so label photos don't bloat the store.
enum ImageResizer {
    static func jpeg(from data: Data, maxDimension: CGFloat, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, maxDimension: maxDimension, quality: quality)
    }

    static func jpeg(from image: UIImage, maxDimension: CGFloat, quality: CGFloat = 0.7) -> Data? {
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
