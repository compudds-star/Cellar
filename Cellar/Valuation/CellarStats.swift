import Foundation

/// Pure aggregation over the cellar. Kept free of SwiftData query machinery so
/// it is trivially unit-testable: hand it wines, get totals back.
struct CellarStats {
    let bottleCount: Int
    let wineCount: Int
    let totalValue: Decimal
    let valuedBottleCount: Int      // bottles that contributed a real value
    let byType: [(type: WineType, value: Decimal, bottles: Int)]

    /// `scope` limits the totals to one collection (or unassigned bottles).
    init(wines: [Wine], scope: CollectionScope = .all) {
        var total = Decimal(0)
        var bottles = 0
        var valued = 0
        var typeValue: [WineType: Decimal] = [:]
        var typeBottles: [WineType: Int] = [:]
        var winesWithStock = 0

        for wine in wines {
            let unit = wine.estimatedUnitValue
            let inStock = wine.inStockBottles(in: scope)
            if !inStock.isEmpty { winesWithStock += 1 }
            for bottle in inStock {
                bottles += 1
                let v = bottle.estimatedValue(unitValue: unit)
                total += v
                if v > 0 { valued += 1 }
                typeValue[wine.type, default: 0] += v
                typeBottles[wine.type, default: 0] += 1
            }
        }

        self.bottleCount = bottles
        self.wineCount = winesWithStock
        self.totalValue = total
        self.valuedBottleCount = valued
        self.byType = WineType.allCases.compactMap { t in
            guard let b = typeBottles[t], b > 0 else { return nil }
            return (t, typeValue[t] ?? 0, b)
        }
    }

    /// True when at least one in-stock bottle has no value — the total is a
    /// floor, not a full figure. The UI uses this to caveat the number.
    var hasUnvaluedBottles: Bool { valuedBottleCount < bottleCount }
}
