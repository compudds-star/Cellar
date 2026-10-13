import XCTest
import SwiftData
@testable import Cellar

final class OrderImportTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self,
            CellarCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        ctx = ModelContext(container)
    }

    // MARK: - Reading the email

    private let eml = """
    From: =?utf-8?Q?K=26L_Wine_Merchants?= <orders@klwines.com>
    Subject: =?utf-8?B?WW91ciBvcmRlciDigJQgIzEyMzQ1?=
    Date: Sat, 12 Sep 2026 14:03:11 -0700
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="XYZ"

    --XYZ
    Content-Type: text/plain; charset=utf-8

    Plain version
    --XYZ
    Content-Type: text/html; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    <html><head><style>p{color:red}</style></head><body>
    <img src=3D"https://cdn.example.com/logo.png" alt=3D"K&amp;L logo">
    <img src=3D"https://track.example.com/o.gif" width=3D"1" height=3D"1">
    <table><tr><td><img src=3D"https://cdn.example.com/lynch.jpg" alt=3D"2019 Lynch-Bages"></td>
    <td><a href=3D"https://www.klwines.com/p/1234">2019 Ch=C3=A2teau Lynch-Bages</a></td>
    <td>Qty 6</td><td>$129.99</td></tr></table>
    <p>Subtotal&nbsp;$779.94</p>
    </body></html>
    --XYZ--
    """

    func testReadsMultipartQuotedPrintableEmail() throws {
        let email = OrderEmail.from(raw: eml)
        XCTAssertEqual(email.subject, "Your order — #12345")
        XCTAssertEqual(email.from, "K&L Wine Merchants <orders@klwines.com>")
        XCTAssertNotNil(email.sentDate)
        XCTAssertTrue(email.text.contains("Château Lynch-Bages"), email.text)
        XCTAssertTrue(email.text.contains("[https://www.klwines.com/p/1234]"), email.text)
        XCTAssertTrue(email.text.contains("Subtotal $779.94"), email.text)
        XCTAssertFalse(email.text.contains("color:red"))
        XCTAssertFalse(email.text.contains("Plain version"), "HTML is preferred")
        // Logo and tracking pixel are dropped; the bottle stays.
        XCTAssertEqual(email.images, [.init(url: "https://cdn.example.com/lynch.jpg", alt: "2019 Lynch-Bages")])
    }

    func testPlainTextAndOrderDetection() {
        let receipt = "Order confirmation\nQty 2  Ridge Monte Bello 2018  $250.00\nTotal $500.00"
        XCTAssertTrue(OrderEmail.looksLikeOrder(receipt))
        XCTAssertEqual(OrderEmail.from(raw: receipt).text, receipt)
        XCTAssertFalse(OrderEmail.looksLikeOrder("Check out this wine! https://vivino.com/w/123"))
    }

    func testBase64BodyAndEntities() {
        let html = "<p>Ros&eacute; &amp; Champagne &#8212; &#x2713;</p>"
        let raw = """
        Subject: Receipt
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        \(Data(html.utf8).base64EncodedString())
        """
        XCTAssertEqual(OrderEmail.from(raw: raw).text, "Rosé & Champagne — ✓")
    }

    func testSharedOrderStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let email = OrderEmail(text: "Order 1", subject: "S")
        try SharedOrderStore.save(email, baseURL: dir)
        XCTAssertEqual(SharedOrderStore.load(baseURL: dir), [email])
        SharedOrderStore.remove(email, baseURL: dir)
        XCTAssertTrue(SharedOrderStore.load(baseURL: dir).isEmpty)
    }

    // MARK: - Splitting bottles between collections

    private func line(quantity: Int = 6, price: Decimal? = 30) -> OrderLineDraft {
        OrderLineDraft(OrderReader.Item(producer: "Ridge", name: "Monte Bello", vintage: 2018,
                                        type: .red, quantity: quantity, unitPrice: price, bottleML: 1500))
    }

    func testSplitNeverExceedsQuantity() {
        let home = UUID(), beach = UUID()
        var draft = line()
        XCTAssertEqual(draft.size, .magnum)
        draft.placeAll(in: home)
        XCTAssertEqual(draft.count(in: home), 6)
        draft.setCount(4, in: beach)           // only room once home gives some up
        XCTAssertEqual(draft.count(in: beach), 0)
        draft.setCount(2, in: home)
        draft.setCount(10, in: beach)
        XCTAssertEqual(draft.count(in: beach), 4)
        XCTAssertEqual(draft.unplaced, 0)

        draft.quantity = 3                     // drop takes from the largest share first
        XCTAssertEqual(draft.placed, 3)
        XCTAssertEqual(draft.count(in: home), 2)
        XCTAssertEqual(draft.count(in: beach), 1)

        draft.quantity = 5                     // extra bottles start unplaced
        XCTAssertEqual(draft.unplaced, 2)
    }

    func testAllInOneCollectionFollowsQuantity() {
        let home = UUID()
        var draft = line()
        draft.placeAll(in: home)
        draft.quantity = 12
        XCTAssertEqual(draft.count(in: home), 12)
    }

    // MARK: - Saving

    @MainActor
    func testSaveSplitsBottlesAndMergesWithExistingWine() throws {
        let home = CellarCollection(name: "Home"), beach = CellarCollection(name: "Beach house")
        ctx.insert(home)
        ctx.insert(beach)
        let wished = Wine(name: "Monte Bello", producer: "RIDGE", vintage: 2018, isWishlist: true)
        ctx.insert(wished)

        var ridge = line()
        ridge.setCount(4, in: home.id)
        ridge.setCount(2, in: beach.id)
        var other = OrderLineDraft(OrderReader.Item(producer: "Domaine Tempier", name: "Bandol Rosé",
                                                    vintage: 2023, type: .rose, quantity: 2, unitPrice: 45))
        other.placeAll(in: nil)
        var skipped = line(quantity: 1)
        skipped.include = false

        let date = OrderReader.day("2026-09-12")!
        let result = OrderImporter.save([ridge, other, skipped], merchant: "K&L", orderDate: date, currency: "USD",
                                        collections: [home, beach], into: ctx, lookUpPrices: false)
        XCTAssertEqual(result, .init(wines: 1, bottles: 8))

        // The wishlist Ridge got the bottles and moved to the cellar.
        XCTAssertFalse(wished.isWishlist)
        XCTAssertEqual(wished.inStockBottles(in: .collection(home)).count, 4)
        XCTAssertEqual(wished.inStockBottles(in: .collection(beach)).count, 2)
        XCTAssertTrue(wished.bottles.allSatisfy { $0.purchasePrice == 30 && $0.purchaseDate == date && $0.size == .magnum })
        XCTAssertEqual(wished.purchaseOptions.map(\.merchantName), ["K&L"])

        let wines = try ctx.fetch(FetchDescriptor<Wine>())
        let tempier = try XCTUnwrap(wines.first { $0.producer == "Domaine Tempier" })
        XCTAssertEqual(tempier.type, .rose)
        XCTAssertEqual(tempier.inStockBottles(in: .unassigned).count, 2)
    }
}
