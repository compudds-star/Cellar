import XCTest
import SwiftData
@testable import Cellar

final class SharedWineParserTests: XCTestCase {

    func testVivinoPageTitle() {
        let item = SharedWineParser.draft(title: "2015 Château Margaux - Red Wine | Vivino", text: nil,
                                          url: URL(string: "https://www.vivino.com/US/en/chateau-margaux/w/1100?year=2015"))
        XCTAssertEqual(item.producer, "Château Margaux")
        XCTAssertEqual(item.vintage, 2015)
        XCTAssertEqual(item.sourceURL, "https://www.vivino.com/US/en/chateau-margaux/w/1100?year=2015")
    }

    func testVivinoShareMessage() {
        let text = "Check out this wine: Opus One 2018 on Vivino https://www.vivino.com/w/1122662"
        let url = SharedWineParser.firstURL(in: text)
        XCTAssertEqual(url?.host, "www.vivino.com")
        let item = SharedWineParser.draft(title: nil, text: text, url: url)
        XCTAssertEqual(item.producer, "Opus One")
        XCTAssertEqual(item.vintage, 2018)
    }

    func testLinkOnly() {
        let wineSearcher = SharedWineParser.draft(title: nil, text: nil,
                                                  url: URL(string: "https://www.wine-searcher.com/find/opus+one/2018/usa"))
        XCTAssertEqual(wineSearcher.producer, "Opus One")
        XCTAssertEqual(wineSearcher.vintage, 2018)

        let vivino = SharedWineParser.draft(title: nil, text: nil,
                                            url: URL(string: "https://www.vivino.com/US/en/chateau-margaux-margaux/w/1100?year=2015"))
        XCTAssertEqual(vivino.producer, "Chateau Margaux Margaux")
        XCTAssertEqual(vivino.vintage, 2015)
    }

    func testPageTitleFromHTMLAndSparkling() {
        let html = #"<html><head><meta property="og:title" content="Krug Grande Cuv&#233;e Brut Champagne | Wine-Searcher"><title>ignored</title></head></html>"#
        let title = SharedWineParser.titleFromHTML(html)
        XCTAssertEqual(title, "Krug Grande Cuvée Brut Champagne | Wine-Searcher")
        let item = SharedWineParser.draft(title: title, text: nil, url: nil)
        XCTAssertEqual(item.producer, "Krug Grande Cuvée Brut Champagne")
        XCTAssertEqual(item.typeRaw, WineType.sparkling.rawValue)
        XCTAssertEqual(item.country, "France")
        XCTAssertEqual(SharedWineParser.titleFromHTML("<title>Opus One &amp; Friends</title>"), "Opus One & Friends")
    }
}

final class SharedImportTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    func testStoreRoundTrip() throws {
        var item = PendingImport()
        item.producer = "Round Trip"
        item.destination = .cellar
        try SharedImportStore.save(item, imageData: Data([1, 2, 3]), baseURL: base)

        let loaded = SharedImportStore.load(baseURL: base)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.item.producer, "Round Trip")
        XCTAssertEqual(loaded.first?.imageData, Data([1, 2, 3]))

        SharedImportStore.remove(loaded[0].item, baseURL: base)
        XCTAssertTrue(SharedImportStore.load(baseURL: base).isEmpty)
    }

    @MainActor
    func testImporterAddsToWishlistAndCellar() async throws {
        let container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self,
            CellarCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        var wish = PendingImport()
        wish.producer = "Share Test Wishlist"
        wish.vintage = 2019
        wish.sourceURL = "https://www.vivino.com/w/1"
        var cellar = PendingImport()
        cellar.producer = "Share Test Cellar"
        cellar.destination = .cellar
        cellar.typeRaw = WineType.whisky.rawValue
        try SharedImportStore.save(wish, imageData: nil, baseURL: base)
        try SharedImportStore.save(cellar, imageData: nil, baseURL: base)

        let wines = await PendingImporter.importAll(into: ctx, baseURL: base)
        XCTAssertEqual(wines.count, 2)

        let wishlistWine = try XCTUnwrap(wines.first { $0.producer == "Share Test Wishlist" })
        XCTAssertTrue(wishlistWine.isWishlist)
        XCTAssertTrue(wishlistWine.bottles.isEmpty)
        XCTAssertEqual(wishlistWine.vintage, 2019)
        XCTAssertTrue(wishlistWine.notes.contains("vivino.com"))

        let cellarWine = try XCTUnwrap(wines.first { $0.producer == "Share Test Cellar" })
        XCTAssertFalse(cellarWine.isWishlist)
        XCTAssertEqual(cellarWine.inStockCount, 1)
        XCTAssertEqual(cellarWine.type, .whisky)
        XCTAssertEqual(cellarWine.bottles.first?.size, BottleSize.defaultSize(for: .whisky))

        XCTAssertTrue(SharedImportStore.load(baseURL: base).isEmpty, "imported files should be removed")
    }
}
