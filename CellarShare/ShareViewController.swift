import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Share-sheet entry point: reads the shared page, message, link, or photo, lets you
/// check the wine and pick Wishlist or Cellar, then leaves it for Cellar to import the
/// next time it comes to the front (the extension can't open the app's database).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareImportModel()
        let root = ShareImportView(
            model: model,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            },
            onSaved: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.load(from: items) }
    }
}

@MainActor
final class ShareImportModel: ObservableObject {
    @Published var item = PendingImport()
    @Published var vintageText = ""
    @Published var loading = true
    @Published var error: String?
    @Published var imageData: Data?

    var canSave: Bool {
        !loading && (!item.producer.trimmingCharacters(in: .whitespaces).isEmpty
                     || !item.name.trimmingCharacters(in: .whitespaces).isEmpty
                     || imageData != nil)
    }

    func load(from items: [NSExtensionItem]) async {
        var title: String?
        var text: String?
        var url: URL?
        for extensionItem in items {
            if title == nil, let t = extensionItem.attributedTitle?.string, !t.isEmpty { title = t }
            if text == nil, let t = extensionItem.attributedContentText?.string, !t.isEmpty { text = t }
            for provider in extensionItem.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
                }
                if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
                }
                if imageData == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    imageData = await loadImage(provider)
                }
            }
        }
        // Vivino shares a message with the link inside it.
        if url == nil, let text { url = SharedWineParser.firstURL(in: text) }
        let hasWords = [title, text].compactMap { $0 }.contains { !SharedWineParser.clean($0).isEmpty }
        if !hasWords, let url, url.scheme?.hasPrefix("http") == true {
            title = await fetchTitle(url)
        }
        item = SharedWineParser.draft(title: title, text: text, url: url)
        vintageText = item.vintage.map(String.init) ?? ""
        loading = false
    }

    func save() -> Bool {
        item.vintage = Int(vintageText.trimmingCharacters(in: .whitespaces))
        do {
            try SharedImportStore.save(item, imageData: imageData)
            return true
        } catch {
            self.error = "Couldn't save for Cellar: \(error.localizedDescription)"
            return false
        }
    }

    private func loadImage(_ provider: NSItemProvider) async -> Data? {
        guard let value = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) else { return nil }
        let image: UIImage?
        switch value {
        case let url as URL: image = (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
        case let data as Data: image = UIImage(data: data)
        case let uiImage as UIImage: image = uiImage
        default: image = nil
        }
        guard let image else { return nil }
        let scale = min(1, 1200 / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
            .jpegData(compressionQuality: 0.8)
    }

    /// A shared link with no words (e.g. from Vivino): read the page's title.
    private func fetchTitle(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return SharedWineParser.titleFromHTML(String(decoding: data.prefix(600_000), as: UTF8.self))
    }
}

struct ShareImportView: View {
    @ObservedObject var model: ShareImportModel
    let onCancel: () -> Void
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if model.loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading what you shared…").foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Picker("Add to", selection: $model.item.destination) {
                            Text("Wishlist").tag(PendingImport.Destination.wishlist)
                            Text("Cellar").tag(PendingImport.Destination.cellar)
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Wine") {
                        TextField("Producer", text: $model.item.producer)
                        TextField("Cuvée / name", text: $model.item.name)
                        TextField("Vintage (blank = NV)", text: $model.vintageText)
                            .keyboardType(.numberPad)
                        Picker("Type", selection: $model.item.typeRaw) {
                            Section("Wine") {
                                ForEach(WineType.wines) { Text($0.label).tag($0.rawValue) }
                            }
                            Section("Spirits") {
                                ForEach(WineType.spirits) { Text($0.label).tag($0.rawValue) }
                            }
                        }
                    }
                    if let data = model.imageData, let image = UIImage(data: data) {
                        Section("Photo") {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                        }
                    }
                    if let source = model.item.sourceURL {
                        Section("From") {
                            Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red)
                    }
                    Section {
                        Text("It's added the next time you open Cellar, which also looks up its price.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add to Cellar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.save() { onSaved() }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
    }
}
