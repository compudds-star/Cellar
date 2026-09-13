import Foundation
import SwiftData

/// A named group of bottles in one place — "Home", "Beach house", "Storage unit".
/// A bottle belongs to at most one collection; `Bottle.storageLocation` is the spot
/// within it (rack, shelf).
@Model
final class CellarCollection {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Deleting a collection keeps its bottles; they just become unassigned.
    @Relationship(deleteRule: .nullify, inverse: \Bottle.collection)
    var bottles: [Bottle]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.bottles = []
    }
}

/// Which bottles a total covers.
enum CollectionScope: Hashable {
    case all
    case collection(CellarCollection)
    case unassigned

    func includes(_ bottle: Bottle) -> Bool {
        switch self {
        case .all: return true
        case .collection(let c): return bottle.collection?.id == c.id
        case .unassigned: return bottle.collection == nil
        }
    }

    var title: String {
        switch self {
        case .all: return "All collections"
        case .collection(let c): return c.name
        case .unassigned: return "No collection"
        }
    }
}

enum CollectionStore {
    /// Creates a collection with a trimmed name, or returns the existing one with
    /// the same name (ignoring case). Nil for a blank name.
    @discardableResult
    static func create(named raw: String, in context: ModelContext) -> CellarCollection? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<CellarCollection>())) ?? []
        if let existing = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let collection = CellarCollection(name: name)
        context.insert(collection)
        return collection
    }
}

/// Remembers the collection bottles were last added to, so the next add defaults to it.
enum CollectionMemory {
    static let key = "cellar.lastCollectionID"

    static func remember(_ collection: CellarCollection?) {
        UserDefaults.standard.set(collection?.id.uuidString, forKey: key)
    }

    static func lastUsed(in context: ModelContext) -> CellarCollection? {
        guard let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) else { return nil }
        let descriptor = FetchDescriptor<CellarCollection>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
