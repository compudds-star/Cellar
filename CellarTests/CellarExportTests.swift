import XCTest
import SwiftData
@testable import Cellar

final class CellarExportTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self, CellarCollection.self,
            configurations: config)
        return ModelContext(container)
    }

    func testCSVHeaderAndRow() throws {
        let ctx = try makeContext()
        let wine = Wine(name: "Grange", producer: "Penfolds", varietal: "Shiraz",
                        region: "South Australia", country: "Australia", vintage: 2016,
                        type: .red, manualEstimatedValue: 800, rating: 4)
        ctx.insert(wine)
        let bottle = Bottle(size: .standard, purchasePrice: 750, storageLocation: "Rack 1",
                            drinkFrom: 2026, drinkTo: 2045)
        bottle.wine = wine
        ctx.insert(bottle)
        let home = CellarCollection(name: "Home")
        ctx.insert(home)
        bottle.collection = home

        let csv = CellarCSVExporter.csv(for: [wine])
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, CellarCSVExporter.columns.joined(separator: ","))
        XCTAssertEqual(lines.count, 2)
        let row = lines[1]
        XCTAssertTrue(row.contains("Penfolds"))
        XCTAssertTrue(row.contains("2016"))
        XCTAssertTrue(row.contains(",Rack 1,Home,"))   // storage, then collection
        XCTAssertTrue(row.contains("2026"))   // drink from
        XCTAssertTrue(row.contains(",4,"))    // rating (1–5)
    }

    func testCSVEscapesCommas() throws {
        let ctx = try makeContext()
        let wine = Wine(name: "Reserve, Special", producer: "Acme", vintage: 2020, type: .red)
        ctx.insert(wine)
        let csv = CellarCSVExporter.csv(for: [wine])
        // The name with a comma must be quoted so columns stay aligned.
        XCTAssertTrue(csv.contains("\"Reserve, Special\""))
    }

    func testEmptyCellarIsHeaderOnly() {
        let csv = CellarCSVExporter.csv(for: [])
        XCTAssertEqual(csv, CellarCSVExporter.columns.joined(separator: ","))
    }
}
