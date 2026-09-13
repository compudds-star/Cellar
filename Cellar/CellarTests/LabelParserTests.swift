import XCTest
import SwiftData
@testable import Cellar

final class LabelParserTests: XCTestCase {

    func testVintageExtraction() {
        XCTAssertEqual(LabelParser.findVintage(in: ["CHÂTEAU", "2015", "Bordeaux"]), 2015)
        XCTAssertNil(LabelParser.findVintage(in: ["Champagne", "Brut", "NV"]))
        // Out-of-range numbers are ignored.
        XCTAssertNil(LabelParser.findVintage(in: ["Lot 1847-A", "750"]))
    }

    func testVarietalAndType() {
        let parsed = LabelParser.parse(lines: ["Kim Crawford", "Sauvignon Blanc", "Marlborough", "2022"])
        XCTAssertEqual(parsed.varietal, "Sauvignon Blanc")
        XCTAssertEqual(parsed.type, .white)
        XCTAssertEqual(parsed.region, "Marlborough")
        XCTAssertEqual(parsed.country, "New Zealand")
        XCTAssertEqual(parsed.vintage, 2022)
    }

    func testSparklingOverride() {
        let parsed = LabelParser.parse(lines: ["Veuve Clicquot", "Brut", "Champagne"])
        XCTAssertEqual(parsed.type, .sparkling)
        XCTAssertEqual(parsed.country, "France")
        XCTAssertNil(parsed.vintage) // NV
    }

    func testProducerNamePick() {
        let parsed = LabelParser.parse(lines: ["Opus One", "2018", "Napa Valley", "750 mL", "14.5% alc/vol"])
        XCTAssertEqual(parsed.producer, "Opus One")
        XCTAssertEqual(parsed.region, "Napa Valley")
        XCTAssertEqual(parsed.country, "USA")
    }
}

final class CellarStatsTests: XCTestCase {

    /// In-memory context so relationship mutation is backed by a real store —
    /// mutating `@Model` relationships on unattached instances is unsupported.
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self,
            configurations: config)
        return ModelContext(container)
    }

    private func add(_ wine: Wine, bottles: [Bottle], to ctx: ModelContext) {
        ctx.insert(wine)
        for b in bottles { b.wine = wine; ctx.insert(b) }
    }

    func testTotalsAndSizeScaling() throws {
        let ctx = try makeContext()
        let wine = Wine(name: "Test Red", type: .red, manualEstimatedValue: 100)
        add(wine, bottles: [
            Bottle(size: .standard),
            Bottle(size: .magnum),                       // 2x factor
            Bottle(size: .standard, status: .consumed)   // excluded
        ], to: ctx)

        let stats = CellarStats(wines: [wine])
        XCTAssertEqual(stats.bottleCount, 2)
        XCTAssertEqual(stats.totalValue, Decimal(300))    // 100 + 200
        XCTAssertFalse(stats.hasUnvaluedBottles)
    }

    func testUnvaluedFallsBackToPaidPrice() throws {
        let ctx = try makeContext()
        let wine = Wine(name: "No estimate", type: .white)   // no manual value
        add(wine, bottles: [Bottle(size: .standard, purchasePrice: 25)], to: ctx)

        let stats = CellarStats(wines: [wine])
        XCTAssertEqual(stats.totalValue, Decimal(25))
        XCTAssertFalse(stats.hasUnvaluedBottles)             // paid price counts
    }

    func testTrulyUnvaluedIsFlagged() throws {
        let ctx = try makeContext()
        let wine = Wine(name: "Unknown", type: .red)
        add(wine, bottles: [Bottle(size: .standard)], to: ctx)   // no price, no estimate

        let stats = CellarStats(wines: [wine])
        XCTAssertEqual(stats.totalValue, Decimal(0))
        XCTAssertTrue(stats.hasUnvaluedBottles)
    }
}
