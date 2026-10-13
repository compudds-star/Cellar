import Foundation
import SwiftData

/// The whole cellar as plain values — wines with their bottles, prices, offers,
/// tasting notes and label photos, plus the collections bottles live in. A backup
/// file is this archive as a binary property list, so photos stay raw bytes
/// rather than ballooning into base64.
///
/// Money is kept as strings: `Decimal`'s own Codable form differs between
/// encoders, and a backup has to read back exactly what was written.
struct CellarArchive: Codable {
    static let currentVersion = 1

    var version = CellarArchive.currentVersion
    var createdAt: Date
    var collections: [CollectionRecord]
    var wines: [WineRecord]

    var bottleCount: Int { wines.reduce(0) { $0 + $1.bottles.count } }

    struct CollectionRecord: Codable {
        var id: UUID
        var name: String
        var createdAt: Date
    }

    struct WineRecord: Codable {
        var id: UUID
        var name: String
        var producer: String
        var varietal: String
        var region: String
        var country: String
        var vintage: Int?
        var lwin7: String?
        var typeRaw: String
        var labelImage: Data?
        var imageURL: String?
        var notes: String
        var manualEstimatedValue: String?
        var rating: Int?
        var communityScore: Int?
        var isWishlist: Bool
        var createdAt: Date
        var bottles: [BottleRecord]
        var valuations: [ValuationRecord]
        var offers: [OfferRecord]
        var tastingNotes: [NoteRecord]
    }

    struct BottleRecord: Codable {
        var id: UUID
        var collectionID: UUID?
        var sizeRaw: String
        var statusRaw: String
        var purchasePrice: String?
        var purchaseDate: Date?
        var storageLocation: String
        var drinkFrom: Int?
        var drinkTo: Int?
        var consumedDate: Date?
        var addedAt: Date
    }

    struct ValuationRecord: Codable {
        var id: UUID
        var asOf: Date
        var averagePrice: String
        var minPrice: String?
        var maxPrice: String?
        var currency: String
        var source: String
    }

    struct OfferRecord: Codable {
        var id: UUID
        var merchantName: String
        var price: String?
        var currency: String
        var productURL: String?
        var latitude: Double?
        var longitude: Double?
        var addressLine: String?
        var inStock: Bool
        var fetchedAt: Date
    }

    struct NoteRecord: Codable {
        var id: UUID
        var date: Date
        var score: Int?
        var text: String
    }
}

// MARK: - Capture

extension CellarArchive {
    /// Everything currently in `context`.
    static func capture(from context: ModelContext, at date: Date = .now) throws -> CellarArchive {
        let collections = try context.fetch(FetchDescriptor<CellarCollection>())
        let wines = try context.fetch(FetchDescriptor<Wine>())
        return CellarArchive(
            createdAt: date,
            collections: collections.map { CollectionRecord(id: $0.id, name: $0.name, createdAt: $0.createdAt) },
            wines: wines.map(WineRecord.init))
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> CellarArchive {
        let archive = try PropertyListDecoder().decode(CellarArchive.self, from: data)
        guard archive.version <= currentVersion else { throw BackupError.newerVersion }
        return archive
    }
}

private extension CellarArchive.WineRecord {
    init(_ wine: Wine) {
        self.init(
            id: wine.id, name: wine.name, producer: wine.producer, varietal: wine.varietal,
            region: wine.region, country: wine.country, vintage: wine.vintage, lwin7: wine.lwin7,
            typeRaw: wine.typeRaw, labelImage: wine.labelImage, imageURL: wine.imageURL,
            notes: wine.notes, manualEstimatedValue: wine.manualEstimatedValue.map(money),
            rating: wine.rating, communityScore: wine.communityScore, isWishlist: wine.isWishlist,
            createdAt: wine.createdAt,
            bottles: wine.bottles.map {
                .init(id: $0.id, collectionID: $0.collection?.id, sizeRaw: $0.sizeRaw,
                      statusRaw: $0.statusRaw, purchasePrice: $0.purchasePrice.map(money),
                      purchaseDate: $0.purchaseDate, storageLocation: $0.storageLocation,
                      drinkFrom: $0.drinkFrom, drinkTo: $0.drinkTo, consumedDate: $0.consumedDate,
                      addedAt: $0.addedAt)
            },
            valuations: wine.valuations.map {
                .init(id: $0.id, asOf: $0.asOf, averagePrice: money($0.averagePrice),
                      minPrice: $0.minPrice.map(money), maxPrice: $0.maxPrice.map(money),
                      currency: $0.currency, source: $0.source)
            },
            offers: wine.purchaseOptions.map {
                .init(id: $0.id, merchantName: $0.merchantName, price: $0.price.map(money),
                      currency: $0.currency, productURL: $0.productURL, latitude: $0.latitude,
                      longitude: $0.longitude, addressLine: $0.addressLine, inStock: $0.inStock,
                      fetchedAt: $0.fetchedAt)
            },
            tastingNotes: wine.tastingNotes.map {
                .init(id: $0.id, date: $0.date, score: $0.score, text: $0.text)
            })
    }
}

private func money(_ value: Decimal) -> String { "\(value)" }
private func money(_ text: String) -> Decimal? { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) }

// MARK: - Restore

extension CellarArchive {
    /// Replaces everything in `context` with this archive and saves. Ids are kept,
    /// so a restored wine is the same wine (same reminders, same collection links).
    func restore(into context: ModelContext) throws {
        for wine in try context.fetch(FetchDescriptor<Wine>()) { context.delete(wine) }
        for collection in try context.fetch(FetchDescriptor<CellarCollection>()) { context.delete(collection) }
        try context.save()

        var collectionsByID: [UUID: CellarCollection] = [:]
        for record in collections {
            let collection = CellarCollection(name: record.name)
            collection.id = record.id
            collection.createdAt = record.createdAt
            context.insert(collection)
            collectionsByID[record.id] = collection
        }

        for record in wines {
            let wine = Wine(name: record.name, producer: record.producer, varietal: record.varietal,
                            region: record.region, country: record.country, vintage: record.vintage,
                            lwin7: record.lwin7, labelImage: record.labelImage, notes: record.notes,
                            manualEstimatedValue: record.manualEstimatedValue.flatMap(money),
                            rating: record.rating, isWishlist: record.isWishlist)
            wine.id = record.id
            wine.typeRaw = record.typeRaw
            wine.imageURL = record.imageURL
            wine.communityScore = record.communityScore
            wine.createdAt = record.createdAt
            context.insert(wine)

            for b in record.bottles {
                let bottle = Bottle(purchasePrice: b.purchasePrice.flatMap(money), purchaseDate: b.purchaseDate,
                                    storageLocation: b.storageLocation, drinkFrom: b.drinkFrom, drinkTo: b.drinkTo)
                bottle.id = b.id
                bottle.sizeRaw = b.sizeRaw
                bottle.statusRaw = b.statusRaw
                bottle.consumedDate = b.consumedDate
                bottle.addedAt = b.addedAt
                context.insert(bottle)
                wine.bottles.append(bottle)
                bottle.collection = b.collectionID.flatMap { collectionsByID[$0] }
            }
            for v in record.valuations {
                let snapshot = ValuationSnapshot(averagePrice: money(v.averagePrice) ?? 0,
                                                 minPrice: v.minPrice.flatMap(money),
                                                 maxPrice: v.maxPrice.flatMap(money),
                                                 currency: v.currency, source: v.source, asOf: v.asOf)
                snapshot.id = v.id
                context.insert(snapshot)
                wine.valuations.append(snapshot)
            }
            for o in record.offers {
                let offer = PurchaseOption(merchantName: o.merchantName, price: o.price.flatMap(money),
                                           currency: o.currency, productURL: o.productURL,
                                           latitude: o.latitude, longitude: o.longitude,
                                           addressLine: o.addressLine, inStock: o.inStock)
                offer.id = o.id
                offer.fetchedAt = o.fetchedAt
                context.insert(offer)
                wine.purchaseOptions.append(offer)
            }
            for n in record.tastingNotes {
                let note = TastingNote(date: n.date, score: n.score, text: n.text)
                note.id = n.id
                context.insert(note)
                wine.tastingNotes.append(note)
            }
        }
        try context.save()
    }
}

enum BackupError: LocalizedError {
    case newerVersion
    case downloadTimedOut
    case emptyCellar
    case notABackup

    var errorDescription: String? {
        switch self {
        case .notABackup:
            return "That file isn't a Vino Cellar backup, or it's damaged."
        case .newerVersion:
            return "This backup was made by a newer version of Vino Cellar. Update the app, then try again."
        case .downloadTimedOut:
            return "The backup didn't finish downloading from iCloud. Check your connection and try again."
        case .emptyCellar:
            return "Your cellar is empty, so there's nothing to back up yet."
        }
    }
}
