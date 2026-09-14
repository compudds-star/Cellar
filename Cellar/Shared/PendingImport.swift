import Foundation

// Shared with the CellarShare extension.

/// A wine shared into Cellar from another app (Vivino, Safari…), waiting in the App
/// Group folder until the app next comes to the front and imports it.
struct PendingImport: Codable, Equatable {
    enum Destination: String, Codable, CaseIterable {
        case wishlist, cellar
    }

    var id = UUID()
    var destination: Destination = .wishlist
    var producer = ""
    var name = ""
    var vintage: Int?
    var typeRaw: String = WineType.red.rawValue
    var varietal = ""
    var region = ""
    var country = ""
    var sourceURL: String?
    var sharedText: String?
    /// File name of the shared photo next to the JSON, if any.
    var imageFile: String?
    var createdAt = Date()
}

/// The folder the share extension writes to and the app reads from.
enum SharedImportStore {
    static let appGroup = "group.com.compudds.cellar"

    /// `baseURL` replaces the App Group container (tests).
    static func folder(baseURL: URL? = nil) -> URL? {
        let base = baseURL ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        guard let dir = base?.appendingPathComponent("PendingImports", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ item: PendingImport, imageData: Data?, baseURL: URL? = nil) throws {
        guard let dir = folder(baseURL: baseURL) else { throw CocoaError(.fileNoSuchFile) }
        var item = item
        if let imageData {
            let file = "\(item.id.uuidString).jpg"
            try imageData.write(to: dir.appendingPathComponent(file), options: .atomic)
            item.imageFile = file
        }
        try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("\(item.id.uuidString).json"), options: .atomic)
    }

    /// Pending imports, oldest first, with their photos.
    static func load(baseURL: URL? = nil) -> [(item: PendingImport, imageData: Data?)] {
        guard let dir = folder(baseURL: baseURL),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (item: PendingImport, imageData: Data?)? in
                guard let data = try? Data(contentsOf: url),
                      let item = try? decoder.decode(PendingImport.self, from: data) else { return nil }
                let image = item.imageFile.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
                return (item, image)
            }
            .sorted { $0.item.createdAt < $1.item.createdAt }
    }

    static func remove(_ item: PendingImport, baseURL: URL? = nil) {
        guard let dir = folder(baseURL: baseURL) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(item.id.uuidString).json"))
        if let file = item.imageFile {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }
}
