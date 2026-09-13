import XCTest
import SwiftData
@testable import Cellar

final class WineDraftTests: XCTestCase {

    func testLoadsAndSavesAWine() throws {
        let container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self,
            CellarCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let wine = Wine(name: "Grange", producer: "Penfolds", varietal: "Shiraz", region: "South Australia",
                        country: "Australia", vintage: 2016, type: .red, lwin7: "1004285", notes: "Gift",
                        manualEstimatedValue: 800, rating: 4)
        ctx.insert(wine)

        var draft = WineDraft(wine: wine)
        XCTAssertEqual(draft.vintageText, "2016")
        XCTAssertEqual(draft.estimateText, "800")
        XCTAssertEqual(draft.rating, 4)
        XCTAssertEqual(draft.lwin7, "1004285")

        // Notes alone don't change what the wine is.
        draft.notes = "Birthday gift "
        XCTAssertFalse(draft.apply(to: wine))
        XCTAssertEqual(wine.notes, "Birthday gift")

        // A new vintage does; cleared estimate and rating become nil.
        draft.producer = "  Penfolds Wines "
        draft.vintageText = " 2018 "
        draft.type = .white
        draft.estimateText = ""
        draft.rating = 0
        XCTAssertTrue(draft.apply(to: wine))
        XCTAssertEqual(wine.producer, "Penfolds Wines")
        XCTAssertEqual(wine.vintage, 2018)
        XCTAssertEqual(wine.type, .white)
        XCTAssertNil(wine.manualEstimatedValue)
        XCTAssertNil(wine.rating)

        // Clearing the LWIN also counts as a new identity.
        draft = WineDraft(wine: wine)
        draft.lwin7 = nil
        XCTAssertTrue(draft.apply(to: wine))
        XCTAssertNil(wine.lwin7)
    }

    func testValidation() {
        var draft = WineDraft()
        XCTAssertFalse(draft.canSave)                 // needs a producer or name
        draft.producer = "Acme"
        XCTAssertTrue(draft.canSave)

        for bad in ["20x5", "99999", "15"] {
            draft.vintageText = bad
            XCTAssertTrue(draft.vintageIsInvalid, bad)
            XCTAssertFalse(draft.canSave, bad)
        }
        for ok in ["", "NV", "nv", "2015"] {
            draft.vintageText = ok
            XCTAssertFalse(draft.vintageIsInvalid, ok)
        }
        draft.vintageText = "NV"
        XCTAssertNil(draft.vintage)

        draft.estimateText = "abc"
        XCTAssertTrue(draft.estimateIsInvalid)
        XCTAssertFalse(draft.canSave)
        draft.estimateText = "$1,250.00"
        XCTAssertEqual(draft.estimate, 1250)
        XCTAssertTrue(draft.canSave)
    }
}
