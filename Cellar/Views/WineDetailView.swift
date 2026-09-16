import SwiftUI
import SwiftData
import PhotosUI

struct WineDetailView: View {
    @Bindable var wine: Wine
    @Environment(\.modelContext) private var context
    @State private var estimateText = ""
    @State private var editingEstimate = false
    @State private var refreshing = false
    @State private var errorMessage: String?
    @State private var addingBottles = false
    @State private var editingBottle: Bottle?
    @State private var pickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var editingPhoto = false
    @State private var takingPhoto = false
    @State private var editingWine = false
    @State private var movingBottles = false

    /// Name the score for what it is: Wine-Searcher aggregates critics, Vivino
    /// averages drinkers. Older snapshots don't say, so they stay generic.
    private var scoreLabel: String {
        let source = wine.latestValuation?.source ?? ""
        if source.contains("wine-searcher") { return "Critic score" }
        if source.contains("vivino") { return "Community score" }
        return "Critic / community"
    }

    var body: some View {
        List {
            Section {
                headerImage
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipped()
                    .overlay(alignment: .topTrailing) { photoMenu.padding(10) }
            }
            .listRowInsets(EdgeInsets())

            Section {
                VStack(spacing: 10) {
                    StarRating(rating: Binding(get: { wine.rating ?? 0 },
                                               set: { wine.rating = $0 > 0 ? $0 : nil }),
                               size: 30)
                    if let score = wine.communityScore {
                        HStack(spacing: 8) {
                            ScoreBadge(score: score, large: true)
                            Text(scoreLabel).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Details") {
                detailRow("Varietal", wine.varietal)
                detailRow("Region", [wine.region, wine.country].filter { !$0.isEmpty }.joined(separator: ", "))
                detailRow("Type", wine.type.label)
                detailRow("Vintage", wine.vintage.map(String.init) ?? "NV")
                if let window = DrinkWindowEstimate.window(for: wine) {
                    detailRow("Peak drinking", window.label)
                }
                detailRow("LWIN", wine.lwin11 ?? wine.lwin7 ?? "")
            }

            Section("Value") {
                HStack {
                    Text("Per 750 mL estimate")
                    Spacer()
                    if editingEstimate {
                        TextField("0.00", text: $estimateText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Button("Set") {
                            wine.manualEstimatedValue = Decimal(string: estimateText)
                            editingEstimate = false
                        }
                    } else {
                        Text(wine.hasValuation ? Money.string(wine.estimatedUnitValue) : "—")
                            .foregroundStyle(.secondary)
                        Button("Edit") {
                            estimateText = wine.manualEstimatedValue.map { "\($0)" } ?? ""
                            editingEstimate = true
                        }
                    }
                }
                HStack {
                    Text("In-stock total")
                    Spacer()
                    Text(Money.string(wine.totalEstimatedValue)).fontWeight(.semibold)
                }
                if let paid = wine.totalPaidInStock {
                    HStack {
                        Text("You paid")
                        Spacer()
                        Text(Money.string(paid)).foregroundStyle(.secondary)
                    }
                }
                if let best = wine.bestOfferPrice {
                    HStack {
                        Text("Best online price")
                        Spacer()
                        Text(Money.string(best)).foregroundStyle(.green)
                    }
                }
                if let snap = wine.latestValuation {
                    Text("From \(snap.source), \(snap.asOf.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if PriceLookup.shared.inFlight.contains(wine.id) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking up price…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await refreshPrice() }
                } label: {
                    HStack {
                        Label("Refresh price online", systemImage: "arrow.clockwise")
                        if refreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(refreshing)
            }

            if wine.isWishlist {
                Section {
                    Button {
                        WishlistMove.toCellar(wine, context: context)
                    } label: {
                        Label("Move to cellar", systemImage: "tray.and.arrow.down")
                    }
                }
            }

            Section("Tasting notes") {
                ForEach(wine.tastingNotes.sorted { $0.date > $1.date }) { note in
                    TastingNoteRow(note: note)
                }
                .onDelete(perform: deleteNotes)
                Button {
                    let note = TastingNote(text: "")
                    context.insert(note)
                    wine.tastingNotes.append(note)
                } label: {
                    Label("Add note", systemImage: "plus")
                }
            }

            Section("Bottles (\(wine.inStockCount) in stock)") {
                ForEach(wine.bottles.sorted { $0.addedAt < $1.addedAt }) { bottle in
                    BottleRow(bottle: bottle) {
                        endEditing()
                        editingBottle = bottle
                    }
                }
                Button {
                    endEditing()
                    addingBottles = true
                } label: {
                    Label("Add a bottle", systemImage: "plus")
                }
                if wine.inStockCount > 0 {
                    Button {
                        endEditing()
                        movingBottles = true
                    } label: {
                        Label("Move bottles…", systemImage: "archivebox")
                    }
                }
            }

            Section {
                NavigationLink {
                    WhereToBuyView(wine: wine)
                } label: {
                    Label("Where to buy", systemImage: "map")
                }
            }

            if !wine.notes.isEmpty {
                Section("Notes") { Text(wine.notes) }
            }
        }
        .navigationTitle(wine.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    endEditing()
                    editingWine = true
                }
            }
        }
        .sheet(isPresented: $editingWine) {
            WineEditorView(wine: wine)
        }
        .sheet(isPresented: $movingBottles) {
            MoveBottlesSheet(wine: wine)
        }
        // Scrolling puts the keyboard away, so a focused tasting note doesn't pin the
        // page (focus returns to it when the bottle editor closes).
        .scrollDismissesKeyboard(.immediately)
        .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    wine.labelImage = ImageResizer.jpeg(from: data, maxDimension: 1200)
                }
                pickedPhoto = nil
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraCaptureView { image in
                wine.labelImage = ImageResizer.jpeg(from: image, maxDimension: 1200)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $editingPhoto) {
            if let data = wine.labelImage, let ui = UIImage(data: data) {
                PhotoEditorView(image: ui) { edited in
                    wine.labelImage = ImageResizer.jpeg(from: edited, maxDimension: 1200, quality: 0.85)
                }
            }
        }
        .sheet(isPresented: $addingBottles) {
            BottleEditorView(wine: wine)
        }
        .sheet(item: $editingBottle) { bottle in
            BottleEditorView(wine: wine, bottle: bottle)
        }
        .alert("Couldn't fetch price", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refreshPrice() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let updated = try await ValuationCoordinator.refresh(wine, context: context, force: true)
            if !updated {
                errorMessage = "No pricing was returned for this wine."
            }
        } catch let error as ValuationError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Add, replace, crop/rotate, or remove the wine's label photo.
    private var photoMenu: some View {
        Menu {
            if CameraCaptureView.isAvailable {
                Button {
                    takingPhoto = true
                } label: {
                    Label(wine.labelImage == nil ? "Take photo" : "Take new photo", systemImage: "camera")
                }
            }
            Button {
                pickingPhoto = true
            } label: {
                Label(wine.labelImage == nil ? "Choose from Photos" : "Replace from Photos", systemImage: "photo")
            }
            if wine.labelImage != nil {
                Button {
                    editingPhoto = true
                } label: {
                    Label("Edit photo", systemImage: "crop")
                }
                Button(role: .destructive) {
                    wine.labelImage = nil
                } label: {
                    Label("Remove photo", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "camera.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
        }
        .accessibilityLabel("Photo options")
    }

    /// Puts the keyboard away before opening the bottle editor. Otherwise focus
    /// returns to a tasting note when the sheet closes and the keyboard pops back up.
    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func deleteNotes(at offsets: IndexSet) {
        let sorted = wine.tastingNotes.sorted { $0.date > $1.date }
        for index in offsets { context.delete(sorted[index]) }
    }

    @ViewBuilder
    private var headerImage: some View {
        if let data = wine.labelImage, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .accessibilityLabel("Label photo")
                .accessibilityIdentifier("wineHeaderPhoto")
                .accessibilityValue("\(Int(ui.size.width))×\(Int(ui.size.height))" as String)
        } else if let s = wine.imageURL, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { headerPlaceholder }
            }
        } else {
            headerPlaceholder
        }
    }

    private var headerPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [wine.type.tint.opacity(0.85), wine.type.tint.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "wineglass.fill")
                .font(.system(size: 64)).foregroundStyle(.white.opacity(0.9))
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value)
            }
        }
    }
}

struct TastingNoteRow: View {
    @Bindable var note: TastingNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(note.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                StarRating(rating: Binding(get: { note.score ?? 0 },
                                           set: { note.score = $0 > 0 ? $0 : nil }),
                           size: 16)
            }
            TextField("Tasting note", text: $note.text, axis: .vertical)
                .lineLimit(1...6)
        }
    }
}

struct BottleRow: View {
    @Bindable var bottle: Bottle
    /// Opens the bottle editor (price paid, date, storage, drink window).
    var onEdit: () -> Void = {}

    var body: some View {
        HStack {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bottle.size.label).font(.subheadline)
                    let place = [bottle.collection?.name ?? "", bottle.storageLocation]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    if !place.isEmpty {
                        Text(place).font(.caption).foregroundStyle(.secondary)
                    }
                    if let price = bottle.purchasePrice {
                        let date = bottle.purchaseDate.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
                        Text("Paid \(Money.string(price))\(date)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Add price paid").font(.caption).foregroundStyle(.tint)
                    }
                    if bottle.drinkFrom != nil || bottle.drinkTo != nil {
                        Text("Drink \(bottle.drinkFrom.map(String.init) ?? "…")–\(bottle.drinkTo.map(String.init) ?? "…")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit bottle")
            Menu {
                ForEach(BottleStatus.allCases) { s in
                    Button(s.label) {
                        bottle.status = s
                        bottle.consumedDate = (s == .consumed) ? .now : nil
                    }
                }
            } label: {
                Text(bottle.status.label)
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(bottle.status.isInCellar ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }
}
