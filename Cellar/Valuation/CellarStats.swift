import Foundation

/// Pure aggregation over the cellar. Kept free of SwiftData query machinery so
/// it is trivially unit-testable: hand it wines, get totals back.
struct CellarStats {
    let bottleCount: Int
    let wineCount: Int
    let totalValue: Decimal
    let valuedBottleCount: Int      // bottles that contributed a real value
    let byType: [(type: WineType, value: Decimal, bottles: Int)]
    /// Price paid for in-stock bottles that have one recorded.
    let paidTotal: Decimal
    let pricedBottleCount: Int
    /// Bottles with both a price paid and a real estimate — the only ones a gain can be measured on.
    let comparableBottleCount: Int
    /// Estimated value minus price paid, over the comparable bottles.
    let gain: Decimal
    /// What was paid for the comparable bottles (the base for the gain percentage).
    let gainBasisPaid: Decimal

    /// `scope` limits the totals to one collection (or unassigned bottles).
    init(wines: [Wine], scope: CollectionScope = .all) {
        var total = Decimal(0)
        var bottles = 0
        var valued = 0
        var typeValue: [WineType: Decimal] = [:]
        var typeBottles: [WineType: Int] = [:]
        var winesWithStock = 0
        var paidSum = Decimal(0), gainSum = Decimal(0), gainPaid = Decimal(0)
        var priced = 0, comparable = 0

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
                if let paid = bottle.purchasePrice {
                    paidSum += paid
                    priced += 1
                    // Without an estimate the value just echoes the price paid, so no gain to show.
                    if unit > 0 {
                        comparable += 1
                        gainSum += v - paid
                        gainPaid += paid
                    }
                }
            }
        }

        self.bottleCount = bottles
        self.wineCount = winesWithStock
        self.totalValue = total
        self.valuedBottleCount = valued
        self.paidTotal = paidSum
        self.pricedBottleCount = priced
        self.comparableBottleCount = comparable
        self.gain = gainSum
        self.gainBasisPaid = gainPaid
        self.byType = WineType.allCases.compactMap { t in
            guard let b = typeBottles[t], b > 0 else { return nil }
            return (t, typeValue[t] ?? 0, b)
        }
    }

    /// True when at least one in-stock bottle has no value — the total is a
    /// floor, not a full figure. The UI uses this to caveat the number.
    var hasUnvaluedBottles: Bool { valuedBottleCount < bottleCount }

    /// Gain as a fraction of what was paid, when there's anything to compare.
    var gainPercent: Double? {
        gainBasisPaid > 0 ? (gain / gainBasisPaid as NSDecimalNumber).doubleValue : nil
    }

    /// "+$60.00 (+42.9%)" or "-$30.00 (-37.5%)"; nil when no bottle has both a price paid and an estimate.
    var gainDescription: String? {
        guard comparableBottleCount > 0 else { return nil }
        let magnitude = gain < 0 ? -gain : gain
        var text = (gain < 0 ? "-" : "+") + Money.string(magnitude)
        if let percent = gainPercent { text += String(format: " (%+.1f%%)", percent * 100) }
        return text
    }
}
