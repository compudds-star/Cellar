import XCTest
import SwiftData
@testable import Cellar

final class WineTypeTests: XCTestCase {

    func testLWINTypeMapping() {
        XCTAssertEqual(WineType(lwinType: "Sparkling", colour: "White"), .sparkling)
        XCTAssertEqual(WineType(lwinType: "Fortified (Port)", colour: "Red"), .fortified)
        XCTAssertEqual(WineType(lwinType: "Spirit (Whiskies)", colour: ""), .whisky)
        XCTAssertEqual(WineType(lwinType: "Spirit (Brandy)", colour: ""), .brandy)
        XCTAssertEqual(WineType(lwinType: "Spirit (Rum)", colour: ""), .rum)
        XCTAssertEqual(WineType(lwinType: "Spirit (Gin)", colour: ""), .gin)
        XCTAssertEqual(WineType(lwinType: "Spirit (Vodka)", colour: ""), .vodka)
        XCTAssertEqual(WineType(lwinType: "Spirit (Mezcal)", colour: ""), .tequila)
        XCTAssertEqual(WineType(lwinType: "Spirit (Liqueur)", colour: ""), .liqueur)
        XCTAssertEqual(WineType(lwinType: "Spirit (Bitters)", colour: ""), .spirit)
        XCTAssertEqual(WineType(lwinType: "Sake", colour: ""), .other)
        XCTAssertEqual(WineType(lwinType: "Still", colour: "Rose"), .rose)
        XCTAssertNil(WineType(lwinType: "Still", colour: ""))
    }

    func testWineAndSpiritGroupsCoverEveryType() {
        XCTAssertTrue(WineType.whisky.isSpirit)
        XCTAssertFalse(WineType.fortified.isSpirit)
        XCTAssertEqual(Set(WineType.wines).union(WineType.spirits), Set(WineType.allCases))
        XCTAssertTrue(Set(WineType.wines).isDisjoint(with: WineType.spirits))
    }

    func testSpiritLabelsAreDetected() {
        let macallan = LabelParser.parse(lines: ["THE MACALLAN", "Sherry Oak 18 Years Old",
                                                 "Highland Single Malt Scotch Whisky", "43% vol"])
        XCTAssertEqual(macallan.type, .whisky)
        XCTAssertEqual(macallan.producer, "THE MACALLAN")
        XCTAssertEqual(macallan.name, "Sherry Oak 18 Years Old")
        XCTAssertEqual(LabelParser.parse(lines: ["Rémy Martin", "Fine Champagne Cognac", "VSOP"]).type, .brandy)
        XCTAssertEqual(LabelParser.parse(lines: ["Some Distillery", "Reserve", "45% alc/vol"]).type, .spirit)
        XCTAssertEqual(LabelParser.parse(lines: ["Opus One", "Napa Valley", "14.5% alc/vol"]).type, .red)
    }
}

final class BottleDraftTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self, CellarCollection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testPriceParsing() {
        XCTAssertEqual(BottleDraft.decimal(from: "65"), 65)
        XCTAssertEqual(BottleDraft.decimal(from: "$65.50"), Decimal(string: "65.50"))
        XCTAssertEqual(BottleDraft.decimal(from: "65,50"), Decimal(string: "65.50"))
        XCTAssertEqual(BottleDraft.decimal(from: "1,250.00"), 1250)
        XCTAssertNil(BottleDraft.decimal(from: ""))
        XCTAssertNil(BottleDraft.decimal(from: "abc"))
        var draft = BottleDraft()
        draft.priceText = "12.3.4"
        XCTAssertTrue(draft.priceIsInvalid)
    }

    func testApplyWritesFieldsAndRoundTrips() throws {
        let ctx = try makeContext()
        let bottle = Bottle()
        ctx.insert(bottle)
        var draft = BottleDraft()
        draft.size = .magnum
        draft.priceText = "72.00"
        draft.hasPurchaseDate = false
        draft.storageLocation = " Rack 2 "
        draft.drinkFromText = "2026"
        draft.drinkToText = "2040"
        draft.apply(to: bottle)

        XCTAssertEqual(bottle.size, .magnum)
        XCTAssertEqual(bottle.purchasePrice, 72)
        XCTAssertNil(bottle.purchaseDate)
        XCTAssertEqual(bottle.storageLocation, "Rack 2")
        XCTAssertEqual(bottle.drinkFrom, 2026)
        XCTAssertEqual(bottle.drinkTo, 2040)
        XCTAssertEqual(bottle.status, .inStock)
        XCTAssertEqual(BottleDraft(bottle: bottle).priceText, "72")
    }

    func testTotalPaidCountsInStockBottlesWithAPrice() throws {
        let ctx = try makeContext()
        let wine = Wine(name: "Paid test")
        ctx.insert(wine)
        let bottles = [Bottle(purchasePrice: 50), Bottle(status: .consumed, purchasePrice: 30), Bottle()]
        for b in bottles { ctx.insert(b); wine.bottles.append(b) }
        XCTAssertEqual(wine.totalPaidInStock, 50)
        XCTAssertNil(Wine(name: "Nothing paid").totalPaidInStock)
    }
}
