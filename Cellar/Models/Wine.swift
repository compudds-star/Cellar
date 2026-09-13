import Foundation
import SwiftData
import SwiftUI

// MARK: - Enums

/// Wine styles and spirit categories. Stored by raw value, so adding cases never
/// needs a migration.
enum WineType: String, Codable, CaseIterable, Identifiable {
    case red, white, rose, sparkling, dessert, fortified, orange
    case whisky, brandy, rum, gin, vodka, tequila, liqueur, spirit
    case other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rose: return "Rosé"
        case .brandy: return "Brandy & Cognac"
        case .tequila: return "Tequila & Mezcal"
        case .spirit: return "Other spirit"
        default: return rawValue.capitalized
        }
    }
    /// Accent used for placeholder tiles and small type cues.
    var tint: Color {
        switch self {
        case .red, .fortified: return Color(red: 0.44, green: 0.08, blue: 0.18)
        case .white: return Color(red: 0.80, green: 0.70, blue: 0.35)
        case .rose: return Color(red: 0.90, green: 0.55, blue: 0.60)
        case .sparkling: return Color(red: 0.86, green: 0.74, blue: 0.42)
        case .dessert: return Color(red: 0.70, green: 0.45, blue: 0.18)
        case .orange: return Color(red: 0.85, green: 0.55, blue: 0.25)
        case .whisky: return Color(red: 0.72, green: 0.45, blue: 0.15)
        case .brandy: return Color(red: 0.55, green: 0.30, blue: 0.12)
        case .rum: return Color(red: 0.45, green: 0.25, blue: 0.10)
        case .gin: return Color(red: 0.35, green: 0.60, blue: 0.65)
        case .vodka: return Color(red: 0.55, green: 0.62, blue: 0.72)
        case .tequila: return Color(red: 0.62, green: 0.68, blue: 0.30)
        case .liqueur: return Color(red: 0.60, green: 0.25, blue: 0.45)
        case .spirit: return Color(red: 0.40, green: 0.40, blue: 0.45)
        case .other: return Color.gray
        }
    }

    /// Distilled spirits (vs. wine, fortified wine, sake, cider…).
    var isSpirit: Bool {
        switch self {
        case .whisky, .brandy, .rum, .gin, .vodka, .tequila, .liqueur, .spirit: return true
        default: return false
        }
    }
    static var wines: [WineType] { allCases.filter { !$0.isSpirit } }
    static var spirits: [WineType] { allCases.filter(\.isSpirit) }

    /// Type implied by an LWIN record's TYPE (as written by scripts/import_lwin.py:
    /// "Sparkling", "Fortified (Port)", "Spirit (Whiskies)", …) and COLOUR. Nil when
    /// the record doesn't say, so the caller keeps its current type.
    init?(lwinType: String, colour: String) {
        let t = lwinType.lowercased()
        let c = colour.lowercased()
        if t.contains("sparkling") { self = .sparkling }
        else if t.contains("fortified") { self = .fortified }
        else if t.contains("spirit") {
            if t.contains("whisk") { self = .whisky }
            else if ["brandy", "cognac", "armagnac"].contains(where: t.contains) { self = .brandy }
            else if t.contains("rum") { self = .rum }
            else if t.contains("gin") { self = .gin }
            else if t.contains("vodka") { self = .vodka }
            else if t.contains("tequila") || t.contains("mezcal") { self = .tequila }
            else if t.contains("liqueur") { self = .liqueur }
            else { self = .spirit }
        }
        else if ["cider", "sake", "vermouth"].contains(where: t.contains) { self = .other }
        else if c.contains("ros") { self = .rose }
        else if c.contains("white") { self = .white }
        else if c.contains("red") { self = .red }
        else { return nil }
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
    /// Canonical Liv-ex wine identity (7-digit LWIN), when matched. Stable
    /// dedup/identity key and the handle a pricing API can look the wine up by.
    var lwin7: String?
    var typeRaw: String
    /// JPEG of the label the user scanned/added. Kept small (resized on save).
    @Attribute(.externalStorage) var labelImage: Data?
    /// Fallback label image URL from the pricing database, shown when there's no
    /// scanned photo. Defaulted (not an init param) — set by the pricing refresh.
    var imageURL: String? = nil
    var notes: String
    /// A manual override for the per-750mL estimated value. When set, it wins
    /// over any valuation snapshot. This is the offline-first source of truth.
    var manualEstimatedValue: Decimal?
    /// Your own rating on the 100-point scale (nil = unrated).
    var rating: Int?
    /// Critic/community score from the pricing endpoint (nil until fetched).
    var communityScore: Int?
    /// True = a wine you want but don't own yet (shown on the Wishlist tab,
    /// excluded from cellar value). Owned wines are false. Defaulted so stores
    /// created before this field existed migrate (existing wines = owned).
    var isWishlist: Bool = false
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Bottle.wine)
    var bottles: [Bottle]
    @Relationship(deleteRule: .cascade, inverse: \ValuationSnapshot.wine)
    var valuations: [ValuationSnapshot]
    @Relationship(deleteRule: .cascade, inverse: \PurchaseOption.wine)
    var purchaseOptions: [PurchaseOption]
    @Relationship(deleteRule: .cascade, inverse: \TastingNote.wine)
    var tastingNotes: [TastingNote]

    init(name: String,
         producer: String = "",
         varietal: String = "",
         region: String = "",
         country: String = "",
         vintage: Int? = nil,
         type: WineType = .red,
         lwin7: String? = nil,
         labelImage: Data? = nil,
         notes: String = "",
         manualEstimatedValue: Decimal? = nil,
         rating: Int? = nil,
         isWishlist: Bool = false) {
        self.id = UUID()
        self.name = name
        self.producer = producer
        self.varietal = varietal
        self.region = region
        self.country = country
        self.vintage = vintage
        self.lwin7 = lwin7
        self.typeRaw = type.rawValue
        self.labelImage = labelImage
        self.notes = notes
        self.manualEstimatedValue = manualEstimatedValue
        self.rating = rating
        self.isWishlist = isWishlist
        self.createdAt = .now
        self.bottles = []
        self.valuations = []
        self.purchaseOptions = []
        self.tastingNotes = []
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

    /// Full 11-digit LWIN (wine + vintage), when the wine has a matched identity.
    var lwin11: String? {
        guard let lwin7 else { return nil }
        return LWINMatcher.lwin11(lwin7: lwin7, vintage: vintage)
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

    /// Lowest in-stock online offer price, if any offers have been fetched.
    var bestOfferPrice: Decimal? {
        purchaseOptions.filter { $0.inStock }.compactMap { $0.price }.min()
    }

    var inStockBottles: [Bottle] { bottles.filter { $0.status.isInCellar } }
    var inStockCount: Int { inStockBottles.count }

    /// Total estimated value of the in-stock bottles of this wine.
    var totalEstimatedValue: Decimal {
        inStockBottles.reduce(Decimal(0)) { $0 + $1.estimatedValue(unitValue: estimatedUnitValue) }
    }

    /// What was paid for the in-stock bottles that have a price recorded (nil if none).
    var totalPaidInStock: Decimal? {
        let prices = inStockBottles.compactMap(\.purchasePrice)
        return prices.isEmpty ? nil : prices.reduce(Decimal(0), +)
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
