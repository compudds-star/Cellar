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

/// Which collection new bottles start in, chosen in Settings.
enum CollectionDefault: Hashable {
    case lastUsed
    case noCollection
    case collection(UUID)

    init(storage: String?) {
        switch storage {
        case nil, "lastUsed": self = .lastUsed
        case "none": self = .noCollection
        case let raw?: self = UUID(uuidString: raw).map(CollectionDefault.collection) ?? .lastUsed
        }
    }

    var storage: String {
        switch self {
        case .lastUsed: return "lastUsed"
        case .noCollection: return "none"
        case .collection(let id): return id.uuidString
        }
    }
}

/// Default collection for new bottles: the Settings choice, or the last one used.
enum CollectionMemory {
    static let key = "cellar.lastCollectionID"
    static let defaultKey = "defaults.collection"

    static var defaultChoice: CollectionDefault {
        get { CollectionDefault(storage: UserDefaults.standard.string(forKey: defaultKey)) }
        set { UserDefaults.standard.set(newValue.storage, forKey: defaultKey) }
    }

    static func remember(_ collection: CellarCollection?) {
        UserDefaults.standard.set(collection?.id.uuidString, forKey: key)
    }

    static func lastUsed(in context: ModelContext) -> CellarCollection? {
        guard let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) else { return nil }
        return collection(id, in: context)
    }

    /// The collection new bottles start in. A deleted default collection gives nil.
    static func defaultCollection(in context: ModelContext) -> CellarCollection? {
        switch defaultChoice {
        case .lastUsed: return lastUsed(in: context)
        case .noCollection: return nil
        case .collection(let id): return collection(id, in: context)
        }
    }

    private static func collection(_ id: UUID, in context: ModelContext) -> CellarCollection? {
        let descriptor = FetchDescriptor<CellarCollection>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}

/// Moves bottles between collections in bulk. Only the bottles passed (or the
/// wines' in-stock bottles within a scope) move; consumed, gifted, and sold bottles
/// keep their history.
enum CollectionMover {
    /// Moves each wine's in-stock bottles that fall within `scope`. Returns how many changed.
    @discardableResult
    static func move(bottlesOf wines: [Wine], in scope: CollectionScope, to collection: CellarCollection?) -> Int {
        move(wines.flatMap { $0.inStockBottles(in: scope) }, to: collection)
    }

    /// Moves specific bottles. Bottles already in `collection` don't count.
    @discardableResult
    static func move(_ bottles: [Bottle], to collection: CellarCollection?) -> Int {
        var moved = 0
        for bottle in bottles where bottle.collection?.id != collection?.id {
            bottle.collection = collection
            moved += 1
        }
        return moved
    }
}
