import XCTest
@testable import Cellar

final class LWINMatcherTests: XCTestCase {

    private func sampleDB() -> LWINDatabase {
        LWINDatabase(records: [
            LWINRecord(lwin7: "9000007", displayName: "Opus One", producerName: "Opus One",
                       wine: "Napa Valley", country: "USA", region: "Napa Valley",
                       colour: "Red", type: "Still", firstVintage: 1979, finalVintage: nil),
            LWINRecord(lwin7: "9000017", displayName: "Cloudy Bay Sauvignon Blanc",
                       producerName: "Cloudy Bay", wine: "Sauvignon Blanc",
                       country: "New Zealand", region: "Marlborough",
                       colour: "White", type: "Still", firstVintage: 1985, finalVintage: nil),
            LWINRecord(lwin7: "9000010", displayName: "Penfolds Grange", producerName: "Penfolds",
                       wine: "Grange", country: "Australia", region: "South Australia",
                       colour: "Red", type: "Still", firstVintage: 1951, finalVintage: nil)
        ])
    }

    func testBestMatchRanksFirst() {
        let m = LWINMatcher(database: sampleDB())
        let results = m.match(producer: "Cloudy Bay", name: "Sauvignon Blanc",
                              region: "Marlborough", vintage: 2022)
        XCTAssertEqual(results.first?.record.lwin7, "9000017")
        XCTAssertGreaterThan(results.first?.score ?? 0, 0.5)
    }

    func testPartialAndFuzzyStillMatches() {
        let m = LWINMatcher(database: sampleDB())
        // OCR often mangles case/spacing; token overlap should still find Opus One.
        let results = m.match(producer: "OPUS ONE", name: "")
        XCTAssertEqual(results.first?.record.lwin7, "9000007")
    }

    func testNoMatchBelowThreshold() {
        let m = LWINMatcher(database: sampleDB())
        XCTAssertTrue(m.match(producer: "Nonexistent Winery", name: "Zzzzz").isEmpty)
    }

    func testLWIN11Composition() {
        XCTAssertEqual(LWINMatcher.lwin11(lwin7: "9000007", vintage: 2015), "90000072015")
        XCTAssertEqual(LWINMatcher.lwin11(lwin7: "9000015", vintage: nil), "90000151000") // NV → 1000
        XCTAssertNil(LWINMatcher.lwin11(lwin7: "ABC", vintage: 2015))
        XCTAssertNil(LWINMatcher.lwin11(lwin7: "9000007", vintage: 999))
    }
}

final class LWINCSVTests: XCTestCase {

    func testParsesHeaderByNameAndQuotedFields() {
        let csv = """
        LWIN,DISPLAY_NAME,PRODUCER_NAME,WINE,COUNTRY,REGION,COLOUR,TYPE,FIRST_VINTAGE,FINAL_VINTAGE
        9000001,"Château Lafite, Rothschild",Château Lafite Rothschild,Grand Vin,France,Pauillac,Red,Still,1800,
        90000072015,Opus One,Opus One,Napa Valley,USA,Napa Valley,Red,Still,1979,
        """
        let recs = LWINCSV.parse(csv)
        XCTAssertEqual(recs.count, 2)
        // Quoted field with an embedded comma is preserved.
        XCTAssertEqual(recs[0].displayName, "Château Lafite, Rothschild")
        // An 11-digit LWIN is truncated to its 7-digit wine identity.
        XCTAssertEqual(recs[1].lwin7, "9000007")
    }

    func testAcceptsHeaderAliases() {
        let csv = """
        LWIN,DISPLAY_NAME,PRODUCER,WINE,COUNTRY,REGION,COLOR,TYPE,FIRSTVINTAGE,LATEST_VINTAGE
        9000010,Penfolds Grange,Penfolds,Grange,Australia,South Australia,Red,Still,1951,2020
        """
        let recs = LWINCSV.parse(csv)
        XCTAssertEqual(recs.first?.producerName, "Penfolds")
        XCTAssertEqual(recs.first?.finalVintage, 2020)
    }

    func testSkipsRowsWithNonNumericLWIN() {
        let csv = """
        LWIN,DISPLAY_NAME,PRODUCER_NAME,WINE,COUNTRY,REGION,COLOUR,TYPE,FIRST_VINTAGE,FINAL_VINTAGE
        NOTACODE,Bad Row,X,Y,France,Bordeaux,Red,Still,,
        9000002,Good Row,Producer,Wine,France,Margaux,Red,Still,,
        """
        let recs = LWINCSV.parse(csv)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.lwin7, "9000002")
    }
}
