import XCTest
import SwiftData
@testable import Cellar

final class CollectionTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self,
            CellarCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
    }

    private func addBottles(_ wine: Wine, count: Int, to collection: CellarCollection?) {
        for _ in 0..<count {
            let bottle = Bottle()
            ctx.insert(bottle)
            wine.bottles.append(bottle)
            bottle.collection = collection
        }
    }

    func testTotalsPerCollectionAndOverall() {
        let home = CellarCollection(name: "Home"), beach = CellarCollection(name: "Beach house")
        ctx.insert(home)
        ctx.insert(beach)
        let red = Wine(name: "Red", manualEstimatedValue: 100)
        let white = Wine(name: "White", manualEstimatedValue: 40)
        ctx.insert(red)
        ctx.insert(white)
        addBottles(red, count: 2, to: home)
        addBottles(red, count: 1, to: beach)
        addBottles(white, count: 3, to: beach)
        addBottles(white, count: 1, to: nil)

        let all = CellarStats(wines: [red, white])
        XCTAssertEqual(all.totalValue, 460)
        XCTAssertEqual(all.bottleCount, 7)

        let atHome = CellarStats(wines: [red, white], scope: .collection(home))
        XCTAssertEqual(atHome.totalValue, 200)
        XCTAssertEqual(atHome.bottleCount, 2)
        XCTAssertEqual(atHome.wineCount, 1)

        let atBeach = CellarStats(wines: [red, white], scope: .collection(beach))
        XCTAssertEqual(atBeach.totalValue, 220)
        XCTAssertEqual(atBeach.wineCount, 2)

        XCTAssertEqual(CellarStats(wines: [red, white], scope: .unassigned).totalValue, 40)
        XCTAssertEqual(red.totalEstimatedValue(in: .collection(beach)), 100)
    }

    func testDeletingACollectionKeepsItsBottles() throws {
        let home = CellarCollection(name: "Home")
        ctx.insert(home)
        let wine = Wine(name: "Kept")
        ctx.insert(wine)
        addBottles(wine, count: 2, to: home)
        try ctx.save()

        ctx.delete(home)
        try ctx.save()
        XCTAssertEqual(wine.bottles.count, 2)
        XCTAssertTrue(wine.bottles.allSatisfy { $0.collection == nil })
    }

    func testCreateTrimsAndReusesNames() throws {
        let beach = CollectionStore.create(named: "  Beach house ", in: ctx)
        XCTAssertEqual(beach?.name, "Beach house")
        try ctx.save()
        XCTAssertIdentical(CollectionStore.create(named: "beach HOUSE", in: ctx), beach)
        XCTAssertNil(CollectionStore.create(named: "   ", in: ctx))
    }

    func testRemembersLastCollection() throws {
        defer { UserDefaults.standard.removeObject(forKey: CollectionMemory.key) }
        let home = CellarCollection(name: "Home")
        ctx.insert(home)
        try ctx.save()
        CollectionMemory.remember(home)
        XCTAssertEqual(CollectionMemory.lastUsed(in: ctx)?.id, home.id)
        CollectionMemory.remember(nil)
        XCTAssertNil(CollectionMemory.lastUsed(in: ctx))
    }
}
