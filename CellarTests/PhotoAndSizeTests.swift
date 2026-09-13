import XCTest
import UIKit
@testable import Cellar

final class BottleSizeTests: XCTestCase {

    // Unit and UI tests share the host app's UserDefaults; start from the built-in defaults.
    override func setUp() {
        super.setUp()
        clearSettings()
    }

    override func tearDown() {
        clearSettings()
        super.tearDown()
    }

    private func clearSettings() {
        UserDefaults.standard.removeObject(forKey: BottleDefaults.wineKey)
        UserDefaults.standard.removeObject(forKey: BottleDefaults.spiritKey)
    }

    func testSettingsChangeTheDefaultSizes() {
        BottleDefaults.wine = .magnum
        BottleDefaults.spirit = .seventy
        XCTAssertEqual(BottleSize.defaultSize(for: .red), .magnum)
        XCTAssertEqual(BottleSize.defaultSize(for: .gin), .seventy)
    }

    func testSavedSizesStillReadBack() {
        for raw in ["split", "half", "standard", "magnum", "doubleMagnum", "jeroboam", "imperial"] {
            XCTAssertNotNil(BottleSize(rawValue: raw), raw)
        }
    }

    func testGroupsListEverySizeOnce() {
        let grouped = BottleSize.Group.allCases.flatMap(\.sizes)
        XCTAssertEqual(grouped.count, BottleSize.allCases.count)
        XCTAssertEqual(Set(grouped), Set(BottleSize.allCases))
        XCTAssertEqual(BottleSize.Group.standard.sizes.prefix(2), [.standard, .liter])
    }

    func testDefaultsAndValueScaling() {
        XCTAssertEqual(BottleSize.defaultSize(for: .red), .standard)
        XCTAssertEqual(BottleSize.defaultSize(for: .sparkling), .standard)
        XCTAssertEqual(BottleSize.defaultSize(for: .whisky), .liter)
        XCTAssertEqual(BottleSize.seventy.milliliters, 700)
        XCTAssertEqual(BottleSize.handle.milliliters, 1750)
        XCTAssertEqual(BottleSize.nebuchadnezzar.milliliters, 15000)
        let liter = Bottle(size: .liter).estimatedValue(unitValue: 60) as NSDecimalNumber
        XCTAssertEqual(liter.doubleValue, 80, accuracy: 0.01)   // 60 per 750 mL → 80 per liter
    }
}

final class PhotoEditingTests: XCTestCase {

    private func assertRect(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: 1e-9, "minX", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 1e-9, "minY", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 1e-9, "width", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 1e-9, "height", file: file, line: line)
    }

    func testFittedRectCentersAspectFit() {
        assertRect(PhotoEditing.fittedRect(imageSize: CGSize(width: 400, height: 200),
                                           in: CGRect(x: 0, y: 0, width: 300, height: 300)),
                   CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    func testMoveStaysInsideImage() {
        assertRect(PhotoEditing.move(CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), by: CGSize(width: 0.5, height: -0.9)),
                   CGRect(x: 0.6, y: 0, width: 0.4, height: 0.4))
    }

    func testResizeKeepsOppositeCornerAndMinimumSize() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let minSize = CGSize(width: 0.1, height: 0.1)
        assertRect(PhotoEditing.resize(start, corner: .topLeading, by: CGSize(width: 0.1, height: 0.2), minSize: minSize),
                   CGRect(x: 0.3, y: 0.4, width: 0.5, height: 0.4))
        // Can't cross the opposite corner or leave the image.
        assertRect(PhotoEditing.resize(start, corner: .bottomTrailing, by: CGSize(width: -0.9, height: 0.9), minSize: minSize),
                   CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.8))
    }

    func testCropBoxFollowsRotation() {
        assertRect(PhotoEditing.rotatedLeft(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
                   CGRect(x: 0.2, y: 0.6, width: 0.4, height: 0.3))
    }

    /// 400×200: left half red, right half blue.
    private func splitImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        }
    }

    /// Red and blue of the pixel at (x, y), origin top-left.
    private func pixel(_ image: UIImage, x: Int, y: Int) -> (red: UInt8, blue: UInt8) {
        let cg = image.cgImage!
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        }
        return (px[0], px[2])
    }

    func testCropTakesTheSelectedPixels() {
        let cropped = PhotoEditing.crop(splitImage(), to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(cropped.cgImage?.width, 200)
        XCTAssertEqual(cropped.cgImage?.height, 200)
        XCTAssertGreaterThan(pixel(cropped, x: 20, y: 100).blue, 200)
        XCTAssertLessThan(pixel(cropped, x: 20, y: 100).red, 60)
    }

    func testRotateLeftTurnsCounterClockwise() {
        let rotated = PhotoEditing.rotateLeft(splitImage())
        XCTAssertEqual(rotated.cgImage?.width, 200)
        XCTAssertEqual(rotated.cgImage?.height, 400)
        XCTAssertGreaterThan(pixel(rotated, x: 100, y: 300).red, 200)   // left half is now the bottom
        XCTAssertGreaterThan(pixel(rotated, x: 100, y: 100).blue, 200)  // right half is now the top
    }

    func testNormalizesPhotoOrientation() {
        let sideways = UIImage(cgImage: splitImage().cgImage!, scale: 1, orientation: .right)
        let upright = PhotoEditing.normalized(sideways)
        XCTAssertEqual(upright.imageOrientation, .up)
        XCTAssertEqual(upright.cgImage?.width, 200)
        XCTAssertEqual(upright.cgImage?.height, 400)
    }
}
