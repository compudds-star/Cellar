import Foundation
import SwiftData

/// One line of an order as the person reviews it: the wine, how many, what was
/// paid, and how the bottles are split across collections.
struct OrderLineDraft: Identifiable, Equatable {
    let id = UUID()
    var include = true
    var producer: String
    var name: String
    var varietal: String
    var region: String
    var country: String
    var vintageText: String
    var type: WineType
    var quantity: Int {
        didSet {
            quantity = max(1, quantity)
            followQuantity(from: oldValue)
        }
    }
    var size: BottleSize
    var priceText: String
    var criticScore: Int?
    var productURL: String?
    var imageURL: String?
    /// Filled while reviewing: the email's photo, or one found online.
    var picture: Data?
    var lookingForPicture = false
    /// Bottles per collection id. Whatever isn't placed has no collection.
    var split: [UUID: Int] = [:]

    init(_ item: OrderReader.Item) {
        producer = item.producer
        name = item.name
        varietal = item.varietal
        region = item.region
        country = item.country
        vintageText = item.vintage.map(String.init) ?? ""
        type = item.type
        quantity = max(1, item.quantity)
        size = item.bottleML.map { BottleSize.nearest(milliliters: Double($0)) } ?? .defaultSize(for: item.type)
        priceText = item.unitPrice.map { "\($0)" } ?? ""
        criticScore = item.criticScore
        productURL = item.productURL
        imageURL = item.imageURL
    }

    var vintage: Int? { Int(vintageText.trimmingCharacters(in: .whitespaces)) }
    var price: Decimal? { BottleDraft.decimal(from: priceText) }
    var title: String {
        let head = [producer, name].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(vintage.map(String.init) ?? "NV") \(head.isEmpty ? "Unknown wine" : head)"
    }

    var placed: Int { split.values.reduce(0, +) }
    var unplaced: Int { max(0, quantity - placed) }

    func count(in collection: UUID) -> Int { split[collection] ?? 0 }

    /// Sets one collection's count, never letting the total exceed the quantity.
    mutating func setCount(_ count: Int, in collection: UUID) {
        let others = placed - self.count(in: collection)
        split[collection] = min(max(0, count), quantity - others)
    }

    /// Every bottle to one collection (or none).
    mutating func placeAll(in collection: UUID?) {
        split = collection.map { [$0: quantity] } ?? [:]
    }

    /// Keeps the split valid when the quantity changes. Bottles all bound for one
    /// collection stay that way; otherwise a drop takes bottles back from the
    /// largest share first, and extra bottles start unplaced.
    private mutating func followQuantity(from old: Int) {
        let shares = split.filter { $0.value > 0 }
        if shares.count == 1, let only = shares.first, only.value == old {
            split = [only.key: quantity]
            return
        }
        var excess = placed - quantity
        while excess > 0, let largest = split.max(by: { $0.value < $1.value }), largest.value > 0 {
            let take = min(excess, largest.value)
            split[largest.key] = largest.value - take
            excess -= take
        }
    }
}

extension BottleSize {
    /// The listed size closest to a volume (1.5 L → Magnum).
    static func nearest(milliliters ml: Double) -> BottleSize {
        let preferred: [BottleSize] = [.standard, .magnum, .half, .liter, .seventy, .doubleMagnum,
                                       .halfLiter, .split, .handle, .miniature, .twoHundred, .rehoboam,
                                       .imperial, .salmanazar, .balthazar, .nebuchadnezzar]
        return preferred.min { abs($0.milliliters - ml) < abs($1.milliliters - ml) } ?? .standard
    }
}

/// Saves reviewed order lines into the cellar.
enum OrderImporter {
    struct Result: Equatable {
        var wines = 0
        var bottles = 0
    }

    /// Each included line becomes bottles of a wine — added to the wine already in
    /// the cellar (or on the wishlist, which then moves to the cellar) when it's
    /// the same producer, name and vintage, else a new wine. Bottles carry the
    /// order's date and price and go to their collections; the merchant becomes a
    /// "where to buy" option.
    @MainActor
    @discardableResult
    static func save(_ lines: [OrderLineDraft], merchant: String, orderDate: Date?, currency: String,
                     collections: [CellarCollection], into context: ModelContext,
                     lookUpPrices: Bool = true) -> Result {
        var result = Result()
        let existing = (try? context.fetch(FetchDescriptor<Wine>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })

        for line in lines where line.include {
            let producer = line.producer.trimmingCharacters(in: .whitespaces)
            let name = line.name.trimmingCharacters(in: .whitespaces)
            guard !producer.isEmpty || !name.isEmpty else { continue }

            let wine: Wine
            if let match = existing.first(where: { sameWine($0, producer: producer, name: name, vintage: line.vintage) }) {
                wine = match
                if wine.isWishlist { wine.isWishlist = false }
                if wine.labelImage == nil { wine.labelImage = line.picture }
            } else {
                wine = Wine(name: name,
                            producer: producer,
                            varietal: line.varietal.trimmingCharacters(in: .whitespaces),
                            region: line.region.trimmingCharacters(in: .whitespaces),
                            country: line.country.trimmingCharacters(in: .whitespaces),
                            vintage: line.vintage,
                            type: line.type,
                            labelImage: line.picture,
                            notes: merchant.isEmpty ? "" : "Bought from \(merchant)")
                context.insert(wine)
                if let pick = LWINMatcher.confidentPick(
                    LWINMatcher().bestMatches(producer: producer, name: name, region: wine.region,
                                              vintage: wine.vintage, limit: 2)) {
                    wine.lwin7 = pick.record.lwin7
                    if wine.region.isEmpty { wine.region = pick.record.region }
                    if wine.country.isEmpty { wine.country = pick.record.country }
                }
                result.wines += 1
            }
            if wine.communityScore == nil, let score = line.criticScore { wine.communityScore = score }

            let window = DrinkWindowEstimate.window(vintage: wine.vintage, type: wine.type, varietal: wine.varietal,
                                                    region: wine.region, country: wine.country)
            var destinations: [CellarCollection?] = []
            for (id, count) in line.split.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                destinations += Array(repeating: byID[id], count: count)
            }
            destinations += Array(repeating: nil, count: line.unplaced)
            for collection in destinations.prefix(line.quantity) {
                let bottle = Bottle(size: line.size,
                                    purchasePrice: line.price,
                                    purchaseDate: orderDate ?? .now,
                                    drinkFrom: window?.from,
                                    drinkTo: window?.to)
                context.insert(bottle)
                wine.bottles.append(bottle)
                bottle.collection = collection
                result.bottles += 1
            }

            if !merchant.isEmpty, !wine.purchaseOptions.contains(where: { $0.merchantName == merchant }) {
                let option = PurchaseOption(merchantName: merchant, price: line.price, currency: currency,
                                            productURL: line.productURL)
                context.insert(option)
                wine.purchaseOptions.append(option)
            }
            if lookUpPrices {
                Task { DrinkWindowNotifier.schedule(for: wine) }
                PriceLookup.start(for: wine, context: context)
            }
        }
        return result
    }

    /// Same producer, name and vintage, ignoring case and accents.
    static func sameWine(_ wine: Wine, producer: String, name: String, vintage: Int?) -> Bool {
        func key(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
        }
        return wine.vintage == vintage && key(wine.producer) == key(producer) && key(wine.name) == key(name)
    }
}
