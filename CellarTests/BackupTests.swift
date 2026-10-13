import XCTest
import SwiftData
@testable import Cellar

final class BackupTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Wine.self, Bottle.self, ValuationSnapshot.self, PurchaseOption.self, TastingNote.self,
            CellarCollection.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    /// Capture → encode → decode → restore into an empty store gives back the same cellar.
    func testRoundTripKeepsEverything() throws {
        let source = try makeContext()
        let home = CellarCollection(name: "Home")
        source.insert(home)
        let wine = Wine(name: "Monte Bello", producer: "Ridge", vintage: 2019, type: .red,
                        labelImage: Data([1, 2, 3, 4]), manualEstimatedValue: Decimal(string: "275.50"),
                        rating: 5)
        wine.communityScore = 96
        source.insert(wine)
        let bottle = Bottle(size: .magnum, purchasePrice: Decimal(string: "230.10"), storageLocation: "Rack 3",
                            drinkFrom: 2027, drinkTo: 2045)
        source.insert(bottle)
        wine.bottles.append(bottle)
        bottle.collection = home
        let drunk = Bottle(status: .consumed)
        drunk.consumedDate = Date(timeIntervalSince1970: 1_700_000_000)
        source.insert(drunk)
        wine.bottles.append(drunk)
        let snap = ValuationSnapshot(averagePrice: Decimal(string: "281.25")!, currency: "USD", source: "test")
        source.insert(snap)
        wine.valuations.append(snap)
        let note = TastingNote(score: 5, text: "Cassis, cedar")
        source.insert(note)
        wine.tastingNotes.append(note)
        try source.save()

        let data = try CellarArchive.capture(from: source).encoded()
        let archive = try CellarArchive.decode(data)

        let target = try makeContext()
        target.insert(Wine(name: "Replaced"))
        try target.save()
        try archive.restore(into: target)

        let wines = try target.fetch(FetchDescriptor<Wine>())
        XCTAssertEqual(wines.count, 1)
        let restored = try XCTUnwrap(wines.first)
        XCTAssertEqual(restored.id, wine.id)
        XCTAssertEqual(restored.producer, "Ridge")
        XCTAssertEqual(restored.vintage, 2019)
        XCTAssertEqual(restored.labelImage, Data([1, 2, 3, 4]))
        XCTAssertEqual(restored.manualEstimatedValue, Decimal(string: "275.50"))
        XCTAssertEqual(restored.communityScore, 96)
        XCTAssertEqual(restored.bottles.count, 2)
        XCTAssertEqual(restored.inStockCount, 1)
        let kept = try XCTUnwrap(restored.inStockBottles.first)
        XCTAssertEqual(kept.size, .magnum)
        XCTAssertEqual(kept.purchasePrice, Decimal(string: "230.10"))
        XCTAssertEqual(kept.collection?.name, "Home")
        XCTAssertEqual(kept.collection?.id, home.id)
        XCTAssertEqual(restored.latestValuation?.averagePrice, Decimal(string: "281.25"))
        XCTAssertEqual(restored.tastingNotes.first?.text, "Cassis, cedar")
        XCTAssertEqual(try target.fetch(FetchDescriptor<CellarCollection>()).count, 1)
    }

    func testFileNamesReadBack() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        for kind in BackupFile.Kind.allCases {
            let name = BackupStore.fileName(date: date, kind: kind)
            let parsed = BackupStore.parse(fileName: name)
            XCTAssertEqual(parsed?.date, date)
            XCTAssertEqual(parsed?.kind, kind)
        }
        XCTAssertNil(BackupStore.parse(fileName: "notes.txt"))
    }

    /// "Restore from a File…": a backup copied anywhere reads back; anything else is refused clearly.
    func testPickedFileReadsBackOrIsRefused() throws {
        let source = try makeContext()
        source.insert(Wine(name: "Grand Vin", producer: "Château Margaux", vintage: 2015))
        try source.save()
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backup = dir.appending(path: "copied.vinocellarbackup")
        try CellarArchive.capture(from: source).encoded().write(to: backup)
        let archive = try BackupStore.read(pickedFile: backup)
        XCTAssertEqual(archive.wines.map(\.producer), ["Château Margaux"])

        let junk = dir.appending(path: "junk.vinocellarbackup")
        try Data("not a backup".utf8).write(to: junk)
        XCTAssertThrowsError(try BackupStore.read(pickedFile: junk)) { error in
            guard case BackupError.notABackup = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testNewerVersionIsRefused() throws {
        var archive = CellarArchive(createdAt: .now, collections: [], wines: [])
        archive.version = CellarArchive.currentVersion + 1
        XCTAssertThrowsError(try CellarArchive.decode(archive.encoded()))
    }
}
