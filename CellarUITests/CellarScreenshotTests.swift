import XCTest

/// Builds a presentable cellar and captures the App Store screenshots from it.
///
/// Kept out of the smoke suite because it is slow and destructive-ish: run it on
/// a simulator whose Cellar data has been wiped, or the shots pick up whatever
/// earlier tests left behind.
///
///     xcrun simctl uninstall <device> com.doony.cellar
///     xcodebuild -project Cellar.xcodeproj -scheme Cellar \
///       -destination 'id=<iPhone 16 Pro Max>' \
///       -only-testing:CellarUITests/CellarScreenshotTests \
///       -resultBundlePath /tmp/shots.xcresult test
///     xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path shots/
///
/// `scripts/screenshots.sh` does all of that.
final class CellarScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testCaptureAppStoreScreenshots() throws {
        turnOffOnlinePricing()
        seedCellar()

        // 1 — the cellar, grouped by category
        goToTab("Cellar")
        scrollToTop()
        shot("01-cellar")

        // 2 — a wine's detail page
        let wine = cell(containing: "Château Margaux")
        reveal(wine)
        XCTAssertTrue(wine.exists, "Château Margaux isn't in the list")
        wine.tap()
        // Assert on the navigation bar, whose identifier is the wine's displayTitle.
        // Not on a button by subscript: that matches identifiers, and the detail
        // page's buttons carry labels only — which failed here on a page that had
        // in fact opened perfectly well.
        XCTAssertTrue(app.navigationBars["2015 Château Margaux Grand Vin"].waitForExistence(timeout: 10),
                      "the wine's detail page didn't open")
        shot("02-wine-detail")
        // The back button carries the previous screen's title — never index 0,
        // which on the Cellar screen is the filter menu.
        let back = app.navigationBars.buttons["Cellar"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button on the detail page")
        back.tap()

        // 3 — what it's all worth
        goToTab("Value")
        shot("03-value")

        // 4 — value by type, further down the same page
        app.swipeUp(velocity: .slow)
        app.swipeUp(velocity: .slow)
        shot("04-value-by-type")

        // 5 — the wishlist
        goToTab("Wishlist")
        shot("05-wishlist")

        // 6 — bottles already drunk, with their notes kept
        goToTab("Drank")
        shot("06-drank")
    }

    /// Switches tab and insists it worked — a silent miss here is how six shots of
    /// the same screen got taken.
    private func goToTab(_ name: String) {
        app.tabBars.buttons[name].tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10),
                      "the \(name) tab didn't open")
    }

    /// App Store screenshots are marketing material, so they must not contain
    /// merchant label photography or critic scores fetched from the pricing
    /// service. Pointing the endpoint at a dead local port keeps everything on
    /// screen ours — and unlike clearing the field, it's an ordinary valid value,
    /// so Settings saves and closes without hitting its "blank means off" path.
    private func turnOffOnlinePricing() {
        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let endpoint = app.textFields.firstMatch
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        endpoint.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) {
            app.menuItems["Select All"].tap()
        }
        endpoint.typeText("http://127.0.0.1:9")
        dismissKeyboard()
        app.navigationBars["Settings"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 10),
                      "Settings wouldn't close after pointing pricing at a dead port")
    }

    // MARK: - Seeding

    private func seedCellar() {
        // A cellar with enough breadth that the category headings and the
        // value-by-type bars both have something to show.
        addWine(producer: "Château Margaux", cuvée: "Grand Vin", varietal: "Cabernet Sauvignon",
                region: "Margaux", vintage: "2015", value: "650", paid: "520", quantity: 2, stars: 5)
        addWine(producer: "Ridge", cuvée: "Monte Bello", varietal: "Cabernet Sauvignon",
                region: "Santa Cruz Mountains", vintage: "2019", value: "275", paid: "230",
                quantity: 3, stars: 5)
        addWine(producer: "Domaine Leflaive", cuvée: "Puligny-Montrachet", varietal: "Chardonnay",
                region: "Burgundy", vintage: "2020", value: "180", paid: "150",
                quantity: 2, stars: 4, style: "White")
        addWine(producer: "Taylor's", cuvée: "Vintage Port", varietal: "", region: "Douro",
                vintage: "2011", value: "95", paid: "70", quantity: 2, stars: 4, style: "Fortified")
        addWine(producer: "The Macallan", cuvée: "Sherry Oak 18", varietal: "", region: "Speyside",
                vintage: "", value: "400", paid: "320", quantity: 1, stars: 5, style: "Whisky")

        addWine(producer: "Screaming Eagle", cuvée: "Cabernet Sauvignon", varietal: "",
                region: "Napa Valley", vintage: "2018", value: "3800", paid: "",
                quantity: 0, stars: 0, wishlist: true)

        // One finished bottle, so the Drank tab isn't empty.
        addWine(producer: "Sassicaia", cuvée: "Bolgheri", varietal: "", region: "Tuscany",
                vintage: "2016", value: "260", paid: "210", quantity: 1, stars: 4)
        drinkTheLastBottle(of: "Sassicaia")
    }

    private func addWine(producer: String, cuvée: String, varietal: String, region: String,
                         vintage: String, value: String, paid: String, quantity: Int,
                         stars: Int, style: String? = nil, wishlist: Bool = false) {
        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add wine"].waitForExistence(timeout: 10))

        if wishlist { app.segmentedControls.buttons["Wishlist"].tap() }

        type(producer, into: app.textFields["Producer"])
        type(cuvée, into: app.textFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH %@", "Cuv")).firstMatch)
        if !varietal.isEmpty { type(varietal, into: app.textFields["Varietal"]) }
        if !vintage.isEmpty { type(vintage, into: app.textFields["Vintage (blank = NV)"]) }
        if !region.isEmpty { type(region, into: app.textFields["Region"]) }

        if let style {
            dismissKeyboard()
            let picker = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Type")).firstMatch
            reveal(picker)
            XCTAssertTrue(picker.exists, "no Type picker on the Add form")
            picker.tap()
            let option = app.buttons[style].firstMatch
            let cell = app.staticTexts[style].firstMatch
            if option.waitForExistence(timeout: 5) {
                option.tap()
            } else if cell.waitForExistence(timeout: 5) {
                cell.tap()
            } else {
                XCTFail("couldn't pick the type \(style)")
            }
            // A navigationLink picker pops itself; a menu doesn't need it.
            _ = app.navigationBars["Add wine"].waitForExistence(timeout: 5)
        }

        if stars > 0 {
            dismissKeyboard()
            // Match on the label: a subscript matches identifiers, and the stars
            // carry no identifier — which is why the ratings silently stayed empty.
            let rating = element(labeled: "\(stars) stars")
            reveal(rating)
            XCTAssertTrue(rating.exists, "no \(stars)-star control on the Add form")
            rating.tap()
        }
        if !value.isEmpty { type(value, into: app.textFields["0.00"].firstMatch) }
        if !wishlist, !paid.isEmpty {
            type(paid, into: app.textFields.matching(identifier: "0.00").element(boundBy: 1))
        }
        if !wishlist, quantity > 1 {
            dismissKeyboard()
            let stepper = app.steppers.firstMatch
            reveal(stepper)
            if stepper.exists {
                for _ in 1..<quantity { stepper.buttons.element(boundBy: 1).tap() }
            }
        }

        dismissKeyboard()
        app.navigationBars["Add wine"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Add wine"].waitForNonExistence(timeout: 10),
                      "the Add form didn't close for \(producer)")
    }

    /// Marks a wine's only bottle Consumed, which moves it to the Drank tab.
    private func drinkTheLastBottle(of producer: String) {
        app.tabBars.buttons["Cellar"].tap()
        let row = cell(containing: producer)
        reveal(row)
        guard row.exists else {
            XCTFail("couldn't find \(producer) to finish")
            return
        }
        row.tap()
        // The bottle's status capsule is a menu: In stock → Consumed.
        let status = app.buttons["In stock"]
        reveal(status)
        guard status.exists else {
            XCTFail("no bottle status control on \(producer)")
            return
        }
        status.tap()
        let consumed = app.buttons["Consumed"]
        if consumed.waitForExistence(timeout: 5) { consumed.tap() }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: - Helpers

    private func shot(_ name: String) {
        // Let animations settle so nothing is caught mid-transition.
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(labeled label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A list row. NavigationLink renders as a button, so tapping the row's text
    /// does nothing — it's the button that navigates.
    private func cell(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func type(_ text: String, into field: XCUIElement) {
        reveal(field)
        guard field.exists else {
            XCTFail("missing field for \"\(text)\"")
            return
        }
        field.tap()
        field.typeText(text)
    }

    // The scrolling helpers below are the smoke suite's, which are already proven
    // against these same forms: dismiss the keyboard first, then scroll toward the
    // element rather than blindly swiping.

    private func reveal(_ element: XCUIElement) {
        dismissKeyboard()
        var swipes = 0
        while !isComfortablyVisible(element) && swipes < 20 {
            if element.exists {
                if element.frame.minY < app.frame.midY {
                    app.swipeDown(velocity: .slow)
                } else {
                    app.swipeUp(velocity: .slow)
                }
            } else {
                // Off-screen rows aren't in the tree: look further down first, then back up.
                if swipes < 8 { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) }
            }
            swipes += 1
        }
    }

    private func isComfortablyVisible(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        var bottom = app.frame.maxY - 90
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        return element.frame.maxY <= bottom && element.frame.minY >= app.frame.minY + 100
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        } else {
            app.navigationBars.firstMatch.tap()
        }
    }

    private func scrollToTop() {
        for _ in 0..<8 { app.swipeDown(velocity: .fast) }
    }
}
