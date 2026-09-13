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

final class LWINCSVFormatTests: XCTestCase {

    func testParsesSpreadsheetStyleCSV() {
        // BOM + CRLF line endings (Excel/Numbers export), a quoted comma, an escaped
        // quote, and retired rows that must be skipped.
        let csv = "\u{FEFF}LWIN,STATUS,DISPLAY_NAME,PRODUCER_NAME,WINE,COUNTRY,REGION,FIRST_VINTAGE\r\n"
            + "1000001,Live,\"Opus One, Napa Valley\",Opus One,\"The \"\"One\"\"\",USA,California,1979\r\n"
            + "1000002,Deleted,Old Wine,Old,Old,USA,California,1990\r\n"
            + "1000003,Combined,Merged Wine,Merged,Merged,France,Bordeaux,1990\r\n"
            + "10000011979,Live,Opus One 1979,Opus One,Opus One,USA,California,1979\r\n"
        let records = LWINCSV.parse(csv)
        XCTAssertEqual(records.map(\.lwin7), ["1000001"])
        XCTAssertEqual(records.first?.displayName, "Opus One, Napa Valley")
        XCTAssertEqual(records.first?.wine, "The \"One\"")
        XCTAssertEqual(records.first?.firstVintage, 1979)
    }

    func testLineEndingsAndQuotedNewlines() {
        XCTAssertEqual(LWINCSV.splitRows("a,b\r\nc,d\re,f\ng,\"h\ni\"\n\n"),
                       [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h\ni"]])
    }

    func testConcurrentLoadIngestsOnce() throws {
        // loadIfNeeded prefers the full LWIN.csv when it's bundled, else the sample.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "LWIN", withExtension: "csv")
            ?? Bundle.main.url(forResource: "lwin_sample", withExtension: "csv"))
        let expected = LWINCSV.parse(data: try Data(contentsOf: url)).count
        let db = LWINDatabase()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in db.loadIfNeeded() }
        XCTAssertTrue(db.isLoaded)
        XCTAssertEqual(db.records.count, expected)
    }

    func testMatchingBeforeLoadReturnsNothing() {
        XCTAssertEqual(LWINMatcher(database: LWINDatabase()).match(producer: "Opus One", name: ""), [])
    }
}

final class LWINRankingTests: XCTestCase {

    private func rec(_ lwin7: String, _ display: String, title: String = "", producer: String,
                     wine: String = "", country: String = "France", region: String = "Bordeaux") -> LWINRecord {
        LWINRecord(lwin7: lwin7, displayName: display, producerName: producer, wine: wine,
                   country: country, region: region, colour: "Red", type: "Still",
                   firstVintage: nil, finalVintage: nil, producerTitle: title)
    }

    func testFlagshipBeatsSecondWineAndClassificationWords() {
        let db = LWINDatabase(records: [
            rec("1522619", "Margaux du Chateau Margaux, Margaux", title: "Chateau", producer: "Margaux",
                wine: "Margaux du Chateau Margaux"),
            rec("1015245", "Chateau Siran, Margaux", title: "Chateau", producer: "Siran"),
            rec("1012781", "Chateau Margaux Premier Cru Classe, Margaux", title: "Chateau", producer: "Margaux"),
        ])
        let matches = LWINMatcher(database: db).bestMatches(producer: "Chateau Margaux", name: "", region: "Bordeaux")
        XCTAssertEqual(matches.first?.record.lwin7, "1012781")
    }

    func testBylineInNameStillFindsTheWine() {
        let db = LWINDatabase(records: [
            rec("1122662", "Opus One, Napa Valley", producer: "Opus One", country: "United States", region: "California"),
            rec("1260805", "Opus One, Overture MV, Napa Valley", producer: "Opus One", wine: "Overture MV",
                country: "United States", region: "California"),
            rec("1305760", "Baron Philippe de Rothschild, Huertas, Colchagua Valley",
                producer: "Baron Philippe de Rothschild", wine: "Huertas", country: "Chile", region: "Colchagua"),
        ])
        let matches = LWINMatcher(database: db).bestMatches(
            producer: "OPUS ONE", name: "Robert Mondavi & Baron Philippe de Rothschild",
            region: "Napa Valley", vintage: 2018)
        XCTAssertEqual(matches.first?.record.lwin7, "1122662")
        XCTAssertEqual(LWINMatcher.confidentPick(matches)?.record.lwin7, "1122662")
    }

    func testCloseRunnerUpBlocksAutoPick() {
        let a = rec("1000001", "A", producer: "A"), b = rec("1000002", "B", producer: "B")
        XCTAssertNil(LWINMatcher.confidentPick([LWINMatch(record: a, score: 1, rank: 1.10),
                                                LWINMatch(record: b, score: 1, rank: 1.08)]))
        XCTAssertNil(LWINMatcher.confidentPick([LWINMatch(record: a, score: 0.7, rank: 0.7)]))
        XCTAssertEqual(LWINMatcher.confidentPick([LWINMatch(record: a, score: 0.9, rank: 0.9)])?.record, a)
    }

    func testNAFieldsReadAsBlank() {
        let records = LWINCSV.parse("LWIN,DISPLAY_NAME,PRODUCER_TITLE,PRODUCER_NAME,WINE\n1000001,Schieferkopf,NA,Schieferkopf,NA\n")
        XCTAssertEqual(records.first?.producerTitle, "")
        XCTAssertEqual(records.first?.wine, "")
    }
}
