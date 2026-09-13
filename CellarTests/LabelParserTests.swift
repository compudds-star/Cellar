import XCTest
import SwiftData
import UIKit
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

extension LabelParserTests {

    func testLargestPrintBecomesProducer() {
        let parsed = LabelParser.parse(textLines: [
            LabelTextLine(text: "Napa Valley", height: 0.03),
            LabelTextLine(text: "Robert Mondavi & Baron Philippe de Rothschild", height: 0.02),
            LabelTextLine(text: "OPUS ONE", height: 0.12),
            LabelTextLine(text: "2018", height: 0.05),
            LabelTextLine(text: "Red Wine", height: 0.025),
        ])
        XCTAssertEqual(parsed.producer, "OPUS ONE")
        XCTAssertEqual(parsed.name, "Robert Mondavi & Baron Philippe de Rothschild")
        XCTAssertEqual(parsed.region, "Napa Valley")
        XCTAssertEqual(parsed.vintage, 2018)
    }

    func testOCRTyposStillMatchGrapeAndRegion() {
        let parsed = LabelParser.parse(lines: ["Chateau Montelena", "Cabernet Sauvignan", "Napa Valey", "2019"])
        XCTAssertEqual(parsed.varietal, "Cabernet Sauvignon")
        XCTAssertEqual(parsed.region, "Napa Valley")
        XCTAssertEqual(parsed.country, "USA")
        XCTAssertEqual(parsed.producer, "Chateau Montelena")
        XCTAssertEqual(parsed.name, "")   // grape and region lines aren't names
    }

    func testShortWordsNeedExactMatch() {
        XCTAssertNotEqual(LabelParser.parse(lines: ["Casa Lapostolle", "Excavation Hill"]).type, .sparkling)
        XCTAssertEqual(LabelParser.parse(lines: ["Sarah's Vineyard"]).varietal, "")
    }

    func testVintageFixesLetterOAndSkipsFoundingYear() {
        XCTAssertEqual(LabelParser.findVintage(in: ["Since 1902", "2O15"]), 2015)
        XCTAssertNil(LabelParser.findVintage(in: ["Est. 1998", "Reserve"]))
    }

    func testMostSpecificRegionWins() {
        let parsed = LabelParser.parse(lines: ["Domaine du Pégau", "Châteauneuf-du-Pape", "Vallée du Rhône"])
        XCTAssertEqual(LabelParser.normalizedWords(parsed.region), ["chateauneuf", "du", "pape"])
        XCTAssertEqual(parsed.country, "France")
        XCTAssertEqual(parsed.producer, "Domaine du Pégau")
    }

    func testMergeKeepsPhotoAndAddsMissedLiveText() {
        let photo = [LabelTextLine(text: "OPUS ONE", height: 0.1), LabelTextLine(text: "2018", height: 0.04)]
        let live = [LabelTextLine(text: "Opus One", height: 0.3), LabelTextLine(text: "Napa Valley", height: 0.2)]
        let merged = LabelParser.mergeLines(photo: photo, live: live)
        XCTAssertEqual(merged.map(\.text), ["OPUS ONE", "2018", "Napa Valley"])
        XCTAssertEqual(merged.last?.height, 0)
        XCTAssertEqual(LabelParser.mergeLines(photo: [], live: live), live)
    }

    func testLiveBufferDropsPartialReads() {
        let buffer = ScanBuffer()
        buffer.ingest([LabelTextLine(text: "Opus", height: 0.05)])
        buffer.ingest([LabelTextLine(text: "Opus One", height: 0.08), LabelTextLine(text: "2018", height: 0.03)])
        buffer.ingest([LabelTextLine(text: "OPUS ONE", height: 0.10), LabelTextLine(text: "One", height: 0.09)])
        XCTAssertEqual(buffer.lines.map(\.text), ["Opus One", "2018"])
        XCTAssertEqual(buffer.lines.first?.height, 0.10)
    }
}

/// Real Vision OCR on a rendered label (runs in the simulator, no camera).
final class ImageTextRecognizerTests: XCTestCase {

    private func labelImage() -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            func draw(_ s: String, _ points: CGFloat, _ y: CGFloat, bold: Bool = false) {
                let font = bold ? UIFont.boldSystemFont(ofSize: points) : UIFont.systemFont(ofSize: points)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                let width = (s as NSString).size(withAttributes: attrs).width
                (s as NSString).draw(at: CGPoint(x: (size.width - width) / 2, y: y), withAttributes: attrs)
            }
            draw("OPUS ONE", 150, 300, bold: true)
            draw("2018", 96, 560)
            draw("Napa Valley", 60, 760)
            draw("Cabernet Sauvignon", 60, 880)
            draw("750 mL  14.5% alc/vol", 36, 1300)
        }
    }

    /// The same label stored sideways with orientation `.right` — how the camera
    /// saves a portrait photo (pixels rotated 90° counter-clockwise).
    private func sideways(_ image: UIImage) -> UIImage {
        let cg = image.cgImage!
        let w = cg.width, h = cg.height
        let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return UIImage(cgImage: ctx.makeImage()!, scale: 1, orientation: .right)
    }

    func testReadsLabelAndRanksByPrintSize() async {
        let lines = await ImageTextRecognizer.recognizeLines(in: labelImage(), customWords: [])
        let parsed = LabelParser.parse(textLines: lines)
        XCTAssertEqual(parsed.producer.uppercased(), "OPUS ONE", "lines: \(lines)")
        XCTAssertEqual(parsed.vintage, 2018, "lines: \(lines)")
        XCTAssertEqual(parsed.varietal, "Cabernet Sauvignon")
        XCTAssertEqual(parsed.region, "Napa Valley")
    }

    func testHonorsPhotoOrientation() async {
        let lines = await ImageTextRecognizer.recognizeLines(in: sideways(labelImage()), customWords: [])
        let parsed = LabelParser.parse(textLines: lines)
        XCTAssertEqual(parsed.producer.uppercased(), "OPUS ONE", "lines: \(lines)")
        XCTAssertEqual(parsed.vintage, 2018, "lines: \(lines)")
    }
}

final class CellarStatsTests: XCTestCase {

    /// In-memory context so relationship mutation is backed by a real store —
    /// mutating `@Model` relationships on unattached instances is unsupported.
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self, CellarCollection.self,
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
