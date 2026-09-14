import SwiftUI
import SwiftData

/// A saved wine's editable details, kept as text while the form is open.
struct WineDraft: Equatable {
    var producer = ""
    var name = ""
    var varietal = ""
    var region = ""
    var country = ""
    var vintageText = ""
    var type: WineType = .red
    var lwin7: String?
    var rating = 0
    var estimateText = ""
    var notes = ""

    init() {}

    init(wine: Wine) {
        producer = wine.producer
        name = wine.name
        varietal = wine.varietal
        region = wine.region
        country = wine.country
        vintageText = wine.vintage.map(String.init) ?? ""
        type = wine.type
        lwin7 = wine.lwin7
        rating = wine.rating ?? 0
        estimateText = wine.manualEstimatedValue.map { "\($0)" } ?? ""
        notes = wine.notes
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nil for a blank or "NV" vintage.
    var vintage: Int? { Int(Self.trimmed(vintageText)) }
    var vintageIsInvalid: Bool {
        let text = Self.trimmed(vintageText)
        guard !text.isEmpty, text.uppercased() != "NV" else { return false }
        return !(vintage.map { (1000...9999).contains($0) } ?? false)
    }

    var estimate: Decimal? { BottleDraft.decimal(from: estimateText) }
    var estimateIsInvalid: Bool { !Self.trimmed(estimateText).isEmpty && estimate == nil }

    var canSave: Bool {
        !(Self.trimmed(producer).isEmpty && Self.trimmed(name).isEmpty) && !vintageIsInvalid && !estimateIsInvalid
    }

    /// Writes the draft onto the wine. Returns true when what the wine *is* changed
    /// (producer, name, vintage, or LWIN), so its market price needs a fresh lookup.
    @discardableResult
    func apply(to wine: Wine) -> Bool {
        let newProducer = Self.trimmed(producer), newName = Self.trimmed(name)
        let identityChanged = newProducer != wine.producer || newName != wine.name
            || vintage != wine.vintage || lwin7 != wine.lwin7
        wine.producer = newProducer
        wine.name = newName
        wine.varietal = Self.trimmed(varietal)
        wine.region = Self.trimmed(region)
        wine.country = Self.trimmed(country)
        wine.vintage = vintage
        wine.type = type
        wine.lwin7 = lwin7
        wine.rating = rating > 0 ? rating : nil
        wine.manualEstimatedValue = estimate
        wine.notes = Self.trimmed(notes)
        return identityChanged
    }
}

/// Edit a saved wine's details, LWIN, rating, estimate, and notes. Bottles and the
/// label photo are edited on the wine's page.
struct WineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let wine: Wine
    @State private var draft: WineDraft
    @State private var showingLWIN = false
    @State private var confirmingMove = false

    init(wine: Wine) {
        self.wine = wine
        _draft = State(initialValue: WineDraft(wine: wine))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wine") {
                    TextField("Producer", text: $draft.producer)
                    TextField("Cuvée / name", text: $draft.name)
                    TextField("Varietal", text: $draft.varietal)
                    TextField("Region", text: $draft.region)
                    TextField("Country", text: $draft.country)
                    TextField("Vintage (blank = NV)", text: $draft.vintageText)
                        .keyboardType(.numberPad)
                    if draft.vintageIsInvalid {
                        Text("Enter a 4-digit year, or leave blank for NV.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    WineTypePicker(selection: $draft.type)
                }

                Section("Wine identity (LWIN)") {
                    if let lwin7 = draft.lwin7 {
                        HStack {
                            Text("LWIN \(lwin7)")
                            Spacer()
                            Button("Change") { showingLWIN = true }
                                .buttonStyle(.borderless)
                            Button("Clear", role: .destructive) { draft.lwin7 = nil }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Button {
                            showingLWIN = true
                        } label: {
                            Label("Find LWIN match", systemImage: "checkmark.seal")
                        }
                        .disabled(draft.producer.trimmingCharacters(in: .whitespaces).isEmpty
                                  && draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Your rating") {
                    HStack {
                        StarRating(rating: $draft.rating)
                        Spacer()
                        if draft.rating > 0 {
                            Button("Clear") { draft.rating = 0 }
                                .font(.caption).buttonStyle(.borderless)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Per 750 mL")
                        Spacer()
                        TextField("0.00", text: $draft.estimateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if draft.estimateIsInvalid {
                        Text("Enter an amount like 65 or 65.50.")
                            .font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Estimated value")
                } footer: {
                    Text("Your own estimate. Leave blank to use online pricing.")
                }

                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Button {
                        confirmingMove = true
                    } label: {
                        if wine.isWishlist {
                            Label("Move to Cellar", systemImage: "tray.and.arrow.down")
                        } else {
                            Label("Move to Wishlist", systemImage: "star")
                        }
                    }
                    .disabled(!draft.canSave)
                } footer: {
                    Text(wine.isWishlist
                         ? "Adds it to your cellar with its bottles, or one new bottle if it has none."
                         : "Keeps every detail, photo, price, and bottle. It stops counting toward your cellar value until you move it back.")
                }
            }
            .confirmationDialog(wine.isWishlist ? "Move to Cellar?" : "Move to Wishlist?",
                                isPresented: $confirmingMove, titleVisibility: .visible) {
                Button(wine.isWishlist ? "Move to Cellar" : "Move to Wishlist") {
                    applyEdits()
                    if wine.isWishlist {
                        WishlistMove.toCellar(wine, context: context)
                    } else {
                        WishlistMove.toWishlist(wine)
                    }
                    dismiss()
                }
            } message: {
                Text(moveMessage)
            }
            .navigationTitle("Edit wine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!draft.canSave)
                }
            }
            .sheet(isPresented: $showingLWIN) {
                LWINMatchView(producer: draft.producer, name: draft.name, region: draft.region,
                              vintage: draft.vintage) { record in
                    draft.lwin7 = record.lwin7
                    if draft.region.isEmpty { draft.region = record.region }
                    if draft.country.isEmpty { draft.country = record.country }
                }
            }
        }
    }

    private var moveMessage: String {
        let count = wine.inStockCount
        let bottles = "\(count) bottle\(count == 1 ? "" : "s")"
        if wine.isWishlist {
            return count == 0
                ? "One bottle is added at your default size and collection. Your edits are saved too."
                : "Its \(bottles) in stock come back with it. Your edits are saved too."
        }
        return count == 0
            ? "Your edits are saved too."
            : "Its \(bottles) in stock stay with it. Your edits are saved too."
    }

    private func save() {
        applyEdits()
        dismiss()
    }

    private func applyEdits() {
        let identityChanged = draft.apply(to: wine)
        // A different wine needs its own price, even if the old one was fetched recently.
        if identityChanged { PriceLookup.start(for: wine, context: context, force: true) }
        // Drink-window reminders include the wine's name.
        Task { DrinkWindowNotifier.schedule(for: wine) }
    }
}

/// Type picker grouped into Wine and Spirits.
struct WineTypePicker: View {
    @Binding var selection: WineType

    var body: some View {
        Picker("Type", selection: $selection) {
            Section("Wine") {
                ForEach(WineType.wines) { Text($0.label).tag($0) }
            }
            Section("Spirits") {
                ForEach(WineType.spirits) { Text($0.label).tag($0) }
            }
        }
    }
}
