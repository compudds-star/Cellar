import Foundation
import SwiftData

// MARK: - Enums

enum WineType: String, Codable, CaseIterable, Identifiable {
    case red, white, rose, sparkling, dessert, fortified, orange, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rose: return "Rosé"
        default: return rawValue.capitalized
        }
    }
}

/// Standard bottle formats with their volume in millilitres. The mL is used to
/// pro-rate value against a 750 mL reference price (a magnum is ~2x a 750).
enum BottleSize: String, Codable, CaseIterable, Identifiable {
    case split          // 187 mL
    case half           // 375 mL
    case standard       // 750 mL
    case magnum         // 1.5 L
    case doubleMagnum   // 3 L
    case jeroboam       // 3 L (sparkling) / 4.5 L (still) — we use 3 L
    case imperial       // 6 L

    var id: String { rawValue }
    var milliliters: Double {
        switch self {
        case .split: return 187.5
        case .half: return 375
        case .standard: return 750
        case .magnum: return 1500
        case .doubleMagnum, .jeroboam: return 3000
        case .imperial: return 6000
        }
    }
    var label: String {
        switch self {
        case .split: return "Split (187 mL)"
        case .half: return "Half (375 mL)"
        case .standard: return "Standard (750 mL)"
        case .magnum: return "Magnum (1.5 L)"
        case .doubleMagnum: return "Double Magnum (3 L)"
        case .jeroboam: return "Jeroboam (3 L)"
        case .imperial: return "Imperial (6 L)"
        }
    }
    /// Multiplier vs. a standard 750 mL price.
    var priceFactor: Double { milliliters / 750.0 }
}

enum BottleStatus: String, Codable, CaseIterable, Identifiable {
    case inStock, consumed, gifted, sold
    var id: String { rawValue }
    var label: String { rawValue == "inStock" ? "In stock" : rawValue.capitalized }
    var isInCellar: Bool { self == .inStock }
}

// MARK: - Wine (the label/vintage identity)

@Model
final class Wine {
    var id: UUID
    var name: String
    var producer: String
    var varietal: String
    var region: String
    var country: String
    /// nil = non-vintage (NV), common for Champagne.
    var vintage: Int?
    var typeRaw: String
    /// JPEG of the label the user scanned/added. Kept small (resized on save).
    @Attribute(.externalStorage) var labelImage: Data?
    var notes: String
    /// A manual override for the per-750mL estimated value. When set, it wins
    /// over any valuation snapshot. This is the offline-first source of truth.
    var manualEstimatedValue: Decimal?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Bottle.wine)
    var bottles: [Bottle]
    @Relationship(deleteRule: .cascade, inverse: \ValuationSnapshot.wine)
    var valuations: [ValuationSnapshot]
    @Relationship(deleteRule: .cascade, inverse: \PurchaseOption.wine)
    var purchaseOptions: [PurchaseOption]

    init(name: String,
         producer: String = "",
         varietal: String = "",
         region: String = "",
         country: String = "",
         vintage: Int? = nil,
         type: WineType = .red,
         labelImage: Data? = nil,
         notes: String = "",
         manualEstimatedValue: Decimal? = nil) {
        self.id = UUID()
        self.name = name
        self.producer = producer
        self.varietal = varietal
        self.region = region
        self.country = country
        self.vintage = vintage
        self.typeRaw = type.rawValue
        self.labelImage = labelImage
        self.notes = notes
        self.manualEstimatedValue = manualEstimatedValue
        self.createdAt = .now
        self.bottles = []
        self.valuations = []
        self.purchaseOptions = []
    }

    var type: WineType {
        get { WineType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    var displayTitle: String {
        let v = vintage.map { String($0) } ?? "NV"
        let head = [producer, name].filter { !$0.isEmpty }.joined(separator: " ")
        return head.isEmpty ? "\(v) Unknown wine" : "\(v) \(head)"
    }

    // MARK: Valuation

    /// Most recent enrichment snapshot (once a ValuationService is wired up).
    var latestValuation: ValuationSnapshot? {
        valuations.max(by: { $0.asOf < $1.asOf })
    }

    /// Estimated value of a single STANDARD (750 mL) bottle, in the app's
    /// currency. Precedence: manual override → latest snapshot → 0 (unknown).
    /// Per-bottle value applies the size factor on top of this.
    var estimatedUnitValue: Decimal {
        if let manual = manualEstimatedValue { return manual }
        if let snap = latestValuation { return snap.averagePrice }
        return 0
    }

    /// True when we have no valuation at all — surfaced in the UI so the user
    /// knows the cellar total is understated.
    var hasValuation: Bool {
        manualEstimatedValue != nil || latestValuation != nil
    }

    var inStockBottles: [Bottle] { bottles.filter { $0.status.isInCellar } }
    var inStockCount: Int { inStockBottles.count }

    /// Total estimated value of the in-stock bottles of this wine.
    var totalEstimatedValue: Decimal {
        inStockBottles.reduce(Decimal(0)) { $0 + $1.estimatedValue(unitValue: estimatedUnitValue) }
    }
}

// MARK: - Bottle (a physical bottle in the cellar)

@Model
final class Bottle {
    var id: UUID
    var wine: Wine?
    var sizeRaw: String
    var statusRaw: String
    var purchasePrice: Decimal?
    var purchaseDate: Date?
    var storageLocation: String   // "Rack 3, Row B" etc.
    /// Optional drink-by window for cellar-management reminders.
    var drinkFrom: Int?
    var drinkTo: Int?
    var consumedDate: Date?
    var addedAt: Date

    init(size: BottleSize = .standard,
         status: BottleStatus = .inStock,
         purchasePrice: Decimal? = nil,
         purchaseDate: Date? = nil,
         storageLocation: String = "",
         drinkFrom: Int? = nil,
         drinkTo: Int? = nil) {
        self.id = UUID()
        self.sizeRaw = size.rawValue
        self.statusRaw = status.rawValue
        self.purchasePrice = purchasePrice
        self.purchaseDate = purchaseDate
        self.storageLocation = storageLocation
        self.drinkFrom = drinkFrom
        self.drinkTo = drinkTo
        self.addedAt = .now
    }

    var size: BottleSize {
        get { BottleSize(rawValue: sizeRaw) ?? .standard }
        set { sizeRaw = newValue.rawValue }
    }
    var status: BottleStatus {
        get { BottleStatus(rawValue: statusRaw) ?? .inStock }
        set { statusRaw = newValue.rawValue }
    }

    /// Estimated value of THIS bottle given the wine's per-750mL unit value,
    /// scaled by bottle size. Falls back to what was paid if no estimate.
    func estimatedValue(unitValue: Decimal) -> Decimal {
        if unitValue > 0 {
            return unitValue * Decimal(size.priceFactor)
        }
        return purchasePrice ?? 0
    }
}

// MARK: - ValuationSnapshot (populated later by a ValuationService)

@Model
final class ValuationSnapshot {
    var id: UUID
    var wine: Wine?
    var asOf: Date
    var averagePrice: Decimal
    var minPrice: Decimal?
    var maxPrice: Decimal?
    var currency: String
    /// e.g. "manual", "wine-searcher" — provenance for the number.
    var source: String

    init(averagePrice: Decimal,
         minPrice: Decimal? = nil,
         maxPrice: Decimal? = nil,
         currency: String = "USD",
         source: String,
         asOf: Date = .now) {
        self.id = UUID()
        self.asOf = asOf
        self.averagePrice = averagePrice
        self.minPrice = minPrice
        self.maxPrice = maxPrice
        self.currency = currency
        self.source = source
    }
}

// MARK: - PurchaseOption (where to buy — populated later by a PurchaseService)

@Model
final class PurchaseOption {
    var id: UUID
    var wine: Wine?
    var merchantName: String
    var price: Decimal?
    var currency: String
    var productURL: String?
    /// Physical store coordinates for map/directions, when known.
    var latitude: Double?
    var longitude: Double?
    var addressLine: String?
    var inStock: Bool
    var fetchedAt: Date

    init(merchantName: String,
         price: Decimal? = nil,
         currency: String = "USD",
         productURL: String? = nil,
         latitude: Double? = nil,
         longitude: Double? = nil,
         addressLine: String? = nil,
         inStock: Bool = true) {
        self.id = UUID()
        self.merchantName = merchantName
        self.price = price
        self.currency = currency
        self.productURL = productURL
        self.latitude = latitude
        self.longitude = longitude
        self.addressLine = addressLine
        self.inStock = inStock
        self.fetchedAt = .now
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }
}
