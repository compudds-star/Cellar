import SwiftUI
import SwiftData

/// A bottle's editable fields, kept as text while the form is open.
struct BottleDraft: Equatable {
    var size: BottleSize = .standard
    var priceText = ""
    var hasPurchaseDate = true
    var purchaseDate = Date.now
    var storageLocation = ""
    var drinkFromText = ""
    var drinkToText = ""
    var quantity = 1
    var collection: CellarCollection?

    init() {}

    init(bottle: Bottle) {
        size = bottle.size
        priceText = bottle.purchasePrice.map { "\($0)" } ?? ""
        hasPurchaseDate = bottle.purchaseDate != nil
        purchaseDate = bottle.purchaseDate ?? .now
        storageLocation = bottle.storageLocation
        drinkFromText = bottle.drinkFrom.map(String.init) ?? ""
        drinkToText = bottle.drinkTo.map(String.init) ?? ""
        collection = bottle.collection
    }

    /// Price paid per bottle; nil when blank or unreadable.
    var price: Decimal? { Self.decimal(from: priceText) }
    var priceIsInvalid: Bool { !priceText.trimmingCharacters(in: .whitespaces).isEmpty && price == nil }

    /// Reads "65", "$65.50", "65,50" or "1,250.00".
    static func decimal(from text: String) -> Decimal? {
        var t = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        if t.contains(".") {
            t.removeAll { $0 == "," }                         // thousands separators
        } else {
            t = t.replacingOccurrences(of: ",", with: ".")    // decimal comma
        }
        guard !t.isEmpty, t.filter({ $0 == "." }).count <= 1 else { return nil }
        return Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Writes the draft onto a bottle. Status and history are left alone.
    func apply(to bottle: Bottle) {
        bottle.size = size
        bottle.purchasePrice = price
        bottle.purchaseDate = hasPurchaseDate ? purchaseDate : nil
        bottle.storageLocation = storageLocation.trimmingCharacters(in: .whitespaces)
        bottle.drinkFrom = Int(drinkFromText.trimmingCharacters(in: .whitespaces))
        bottle.drinkTo = Int(drinkToText.trimmingCharacters(in: .whitespaces))
        bottle.collection = collection
    }
}

/// Add bottles to a wine, or edit one: size, price paid, purchase date, storage,
/// and drink window.
struct BottleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let wine: Wine
    /// The bottle being edited; nil adds new bottles.
    let bottle: Bottle?
    @State private var draft: BottleDraft

    init(wine: Wine, bottle: Bottle? = nil) {
        self.wine = wine
        self.bottle = bottle
        var newBottles = BottleDraft()
        newBottles.size = BottleSize.defaultSize(for: wine.type)
        _draft = State(initialValue: bottle.map(BottleDraft.init(bottle:)) ?? newBottles)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if bottle == nil {
                        Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1...240)
                    }
                    BottleSizePicker(selection: $draft.size)
                }

                Section("Purchase") {
                    HStack {
                        Text("Price paid (per bottle)")
                        Spacer()
                        TextField("0.00", text: $draft.priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if draft.priceIsInvalid {
                        Text("Enter a price like 65 or 65.50.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Toggle("Purchase date", isOn: $draft.hasPurchaseDate.animation())
                    if draft.hasPurchaseDate {
                        DatePicker("Bought on", selection: $draft.purchaseDate,
                                   in: ...Date.now, displayedComponents: .date)
                    }
                }

                Section("Cellar") {
                    CollectionPicker(selection: $draft.collection)
                    TextField("Storage location", text: $draft.storageLocation)
                    HStack {
                        TextField("Drink from (year)", text: $draft.drinkFromText)
                            .keyboardType(.numberPad)
                        Divider()
                        TextField("Drink to (year)", text: $draft.drinkToText)
                            .keyboardType(.numberPad)
                    }
                }
            }
            .onAppear {
                // New bottles start in the default collection (Settings).
                if bottle == nil, draft.collection == nil {
                    draft.collection = CollectionMemory.defaultCollection(in: context)
                }
            }
            .navigationTitle(bottle == nil ? "Add bottles" : "Edit bottle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(draft.priceIsInvalid)
                }
            }
        }
    }

    private func save() {
        if let bottle {
            draft.apply(to: bottle)
        } else {
            for _ in 0..<draft.quantity {
                let new = Bottle()
                context.insert(new)
                draft.apply(to: new)
                wine.bottles.append(new)
            }
            CollectionMemory.remember(draft.collection)
            // New bottles are a good moment to refresh the wine's market price.
            PriceLookup.start(for: wine, context: context)
        }
        Task { DrinkWindowNotifier.schedule(for: wine) }
        dismiss()
    }
}

/// Size picker grouped into Standard / Small / Large format.
struct BottleSizePicker: View {
    @Binding var selection: BottleSize
    var title = "Size"

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(BottleSize.Group.allCases) { group in
                Section(group.title) {
                    ForEach(group.sizes) { Text($0.label).tag($0) }
                }
            }
        }
    }
}
