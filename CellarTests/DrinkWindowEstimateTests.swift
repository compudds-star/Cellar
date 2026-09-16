import XCTest
@testable import Cellar

final class DrinkWindowEstimateTests: XCTestCase {

    func testRegionWinsOverVarietal() {
        // A Napa Cabernet ages longer than a Cabernet from anywhere.
        let napa = DrinkWindowEstimate.window(vintage: 2018, type: .red,
                                              varietal: "Cabernet Sauvignon", region: "Napa Valley", country: "USA")
        XCTAssertEqual(napa, DrinkWindow(from: 2023, to: 2038))
    }

    func testVarietalUsedWithoutAKnownRegion() {
        let window = DrinkWindowEstimate.window(vintage: 2020, type: .white, varietal: "Sauvignon Blanc")
        XCTAssertEqual(window, DrinkWindow(from: 2021, to: 2024))
    }

    func testFallsBackToTheType() {
        let window = DrinkWindowEstimate.window(vintage: 2021, type: .rose)
        XCTAssertEqual(window, DrinkWindow(from: 2021, to: 2023))
    }

    func testVintagePortAgesForDecades() {
        let window = DrinkWindowEstimate.window(vintage: 2016, type: .fortified, region: "Douro", country: "Portugal")
        XCTAssertEqual(window, DrinkWindow(from: 2026, to: 2056))
    }

    func testAccentsAndCaseAreIgnored() {
        let plain = DrinkWindowEstimate.window(vintage: 2015, type: .red, region: "cote-rotie")
        let accented = DrinkWindowEstimate.window(vintage: 2015, type: .red, region: "Côte-Rôtie")
        XCTAssertEqual(plain, accented)
        XCTAssertEqual(accented, DrinkWindow(from: 2021, to: 2037))
    }

    func testNonVintageHasNoWindow() {
        XCTAssertNil(DrinkWindowEstimate.window(vintage: nil, type: .sparkling, region: "Champagne"))
    }

    func testSpiritsHaveNoWindow() {
        // Spirits don't age in the bottle, so a distillation year proves nothing.
        XCTAssertNil(DrinkWindowEstimate.window(vintage: 2015, type: .whisky))
    }

    func testWindowLabelAndContains() {
        let window = DrinkWindow(from: 2024, to: 2038)
        XCTAssertEqual(window.label, "2024–2038")
        XCTAssertTrue(window.contains(2030))
        XCTAssertFalse(window.contains(2039))
    }

    func testReadsAWineDirectly() {
        let wine = Wine(name: "Barolo", producer: "Test", varietal: "Nebbiolo",
                        region: "Barolo", country: "Italy", vintage: 2016, type: .red)
        XCTAssertEqual(DrinkWindowEstimate.window(for: wine), DrinkWindow(from: 2024, to: 2046))
    }
}
