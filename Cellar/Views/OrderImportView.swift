import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

extension OrderEmail: Identifiable {}

/// Import purchases from a merchant's order email: the email is pasted, picked as
/// a file, or shared in from Mail; it's read into lines; the person checks each
/// line, says which collection the bottles go to, and imports.
struct OrderImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \CellarCollection.name) private var collections: [CellarCollection]

    /// An email that arrived from the share sheet; nil starts at the paste step.
    var email: OrderEmail?
    /// Called once the bottles are saved and the person has closed the summary.
    var onImported: (() -> Void)?

    @State private var reading = false
    @State private var error: String?
    @State private var loaded = false
    @State private var choosingFile = false
    @State private var screenshots: [PhotosPickerItem] = []

    // The reviewed order
    @State private var lines: [OrderLineDraft] = []
    @State private var merchant = ""
    @State private var orderDate = Date.now
    @State private var currency = "USD"
    @State private var saved: OrderImporter.Result?

    private var includedBottles: Int { lines.filter(\.include).reduce(0) { $0 + $1.quantity } }

    var body: some View {
        NavigationStack {
            Form {
                if lines.isEmpty {
                    sourceSections
                } else {
                    reviewSections
                }
            }
            .navigationTitle("Import order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !lines.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { save() }
                            .disabled(includedBottles == 0)
                    }
                }
            }
            .fileImporter(isPresented: $choosingFile,
                          allowedContentTypes: [.emailMessage, .pdf, .html, .plainText, .text],
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let email = OrderReader.email(fromFile: data, fileExtension: url.pathExtension) else {
                    error = "Couldn't read any text from that file."
                    return
                }
                Task { await read(email) }
            }
            .onChange(of: screenshots) { _, items in
                guard !items.isEmpty else { return }
                Task { await readScreenshots(items) }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                if let email { await read(email) }
            }
            .alert("Imported", isPresented: Binding(get: { saved != nil }, set: { if !$0 { saved = nil } })) {
                Button("OK") {
                    dismiss()
                    onImported?()
                }
            } message: {
                let r = saved ?? .init()
                Text("\(r.bottles) bottle\(r.bottles == 1 ? "" : "s") added\(r.wines > 0 ? ", \(r.wines) new wine\(r.wines == 1 ? "" : "s")" : ""). Prices are being looked up.")
            }
        }
    }

    // MARK: - Step 1: get the email

    @ViewBuilder private var sourceSections: some View {
        if !OrderReader.isAvailable {
            Section {
                Text("Reading order emails uses the pricing server. Set one up in Settings first.")
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            if reading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the order…").foregroundStyle(.secondary)
                }
            } else {
                PhotosPicker(selection: $screenshots, maxSelectionCount: 10, matching: .images) {
                    Label("Choose screenshots…", systemImage: "photo.on.rectangle")
                }
                .disabled(!OrderReader.isAvailable)
                PasteButton(payloadType: String.self) { strings in
                    guard let raw = strings.first else { return }
                    let email = OrderEmail.from(raw: raw)
                    Task { await read(email) }
                }
                .disabled(!OrderReader.isAvailable)
                Button {
                    choosingFile = true
                } label: {
                    Label("Choose a file (.eml, PDF)…", systemImage: "doc")
                }
                .disabled(!OrderReader.isAvailable)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        } footer: {
            Text("""
            Works with any mail app, including Gmail: open the order email, take screenshots that cover \
            the bottles and prices (scroll for a long order), then choose them here. Or copy the email's \
            text and tap Paste, or pick a saved .eml or PDF.

            Screenshots are read on this phone; only their text, or the email you paste, is sent to your \
            pricing server to be read. Vino Cellar never opens your mailbox.
            """)
        }
    }

    // MARK: - Step 2: review

    @ViewBuilder private var reviewSections: some View {
        Section("Order") {
            TextField("Bought from", text: $merchant)
            DatePicker("Date bought", selection: $orderDate, displayedComponents: .date)
        }

        if collections.count > 1 {
            Section {
                Menu {
                    ForEach(collections) { collection in
                        Button(collection.name) {
                            for i in lines.indices { lines[i].placeAll(in: collection.id) }
                        }
                    }
                    Button("No collection") {
                        for i in lines.indices { lines[i].placeAll(in: nil) }
                    }
                } label: {
                    Label("Put every bottle in…", systemImage: "archivebox")
                }
            } footer: {
                Text("Or split each wine between collections below.")
            }
        }

        ForEach($lines) { $line in
            lineSection($line)
        }
    }

    private func lineSection(_ line: Binding<OrderLineDraft>) -> some View {
        Section {
            Toggle(isOn: line.include) {
                HStack(spacing: 12) {
                    ZStack {
                        WineThumbnail(imageData: line.wrappedValue.picture, type: line.wrappedValue.type,
                                      width: 40, height: 54, corner: 6)
                        if line.wrappedValue.lookingForPicture { ProgressView() }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.wrappedValue.title).lineLimit(2)
                        Text("\(line.wrappedValue.quantity) × \(line.wrappedValue.price.map { Money.string($0, currency: currency) } ?? "no price")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if line.wrappedValue.include {
                TextField("Producer", text: line.producer)
                TextField("Cuvée / name", text: line.name)
                TextField("Vintage (blank = NV)", text: line.vintageText)
                    .keyboardType(.numberPad)
                TextField("Region", text: line.region)
                TextField("Country", text: line.country)
                WineTypePicker(selection: line.type)
                Stepper("Quantity: \(line.wrappedValue.quantity)", value: line.quantity, in: 1...240)
                BottleSizePicker(selection: line.size)
                HStack {
                    Text("Price paid (per bottle)")
                    Spacer()
                    TextField("0.00", text: line.priceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                if collections.count > 1 {
                    ForEach(collections) { collection in
                        Stepper("\(collection.name): \(line.wrappedValue.count(in: collection.id))",
                                value: Binding(get: { line.wrappedValue.count(in: collection.id) },
                                               set: { line.wrappedValue.setCount($0, in: collection.id) }),
                                in: 0...line.wrappedValue.quantity)
                    }
                    if line.wrappedValue.unplaced > 0 {
                        Text("\(line.wrappedValue.unplaced) bottle\(line.wrappedValue.unplaced == 1 ? "" : "s") with no collection")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if line.wrappedValue.picture != nil {
                    Button("Remove picture", role: .destructive) { line.wrappedValue.picture = nil }
                }
            }
        }
    }

    // MARK: - Actions

    private func read(_ email: OrderEmail) async {
        guard !email.isEmpty else {
            error = "There was no text to read. Copy the email's text and try again."
            return
        }
        error = nil
        reading = true
        defer { reading = false }
        do {
            let order = try await OrderReader.read(email)
            merchant = order.merchant
            orderDate = order.orderDate ?? email.sentDate ?? .now
            currency = order.currency
            let start: UUID? = collections.count == 1
                ? collections.first?.id
                : CollectionMemory.defaultCollection(in: context)?.id
            lines = order.items.map { item in
                var line = OrderLineDraft(item)
                line.placeAll(in: start)
                line.lookingForPicture = true
                return line
            }
            await findPictures(order.items)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Screenshots of the email, read on the phone in the order they were picked.
    private func readScreenshots(_ items: [PhotosPickerItem]) async {
        reading = true
        var pages: [String] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            let lines = await ImageTextRecognizer.recognize(in: image)
            if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
        }
        screenshots = []
        reading = false
        guard !pages.isEmpty else {
            error = "Couldn't find any text in those pictures."
            return
        }
        await read(OrderEmail(text: pages.joined(separator: "\n\n")))
    }

    /// The email's own photo for each line, else one from the web; a few at a time.
    private func findPictures(_ items: [OrderReader.Item]) async {
        let ids = lines.map(\.id)
        await withTaskGroup(of: (UUID, Data?).self) { group in
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let (id, item) = (ids[next], items[next])
                next += 1
                group.addTask { (id, await OrderReader.picture(for: item)) }
            }
            for _ in 0..<3 { addNext() }
            for await (id, data) in group {
                if let i = lines.firstIndex(where: { $0.id == id }) {
                    lines[i].picture = data
                    lines[i].lookingForPicture = false
                }
                addNext()
            }
        }
    }

    private func save() {
        let result = OrderImporter.save(lines, merchant: merchant.trimmingCharacters(in: .whitespaces),
                                        orderDate: orderDate, currency: currency,
                                        collections: collections, into: context)
        if collections.count > 1, let first = lines.first(where: \.include),
           let id = first.split.max(by: { $0.value < $1.value })?.key {
            CollectionMemory.remember(collections.first { $0.id == id })
        }
        saved = result
    }
}
