import XCTest

/// End-to-end click-through of the three tabs. Each step attaches a screenshot
/// so a run can be reviewed visually (xcresulttool export attachments).
final class CellarSmokeUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissSystemAlerts()
    }

    func testClickThroughAllTabs() {
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let producer = "Smoke \(stamp)"
        let wishProducer = "Wish \(stamp)"

        // MARK: Cellar — add a wine by hand with rating, value, and a drink window
        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add wine"].waitForExistence(timeout: 5))
        type(producer, into: app.textFields["Producer"])
        type("Reserve", into: app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Cuv")).firstMatch)
        type("Cabernet Sauvignon", into: app.textFields["Varietal"])
        type("2015", into: app.textFields["Vintage (blank = NV)"])
        tap(element(labeled: "4 stars"))
        type("80", into: app.textFields["0.00"].firstMatch)
        type("65", into: app.textFields.matching(identifier: "0.00").element(boundBy: 1))
        type("2024", into: app.textFields["Drink from (year)"])
        type("2035", into: app.textFields["Drink to (year)"])
        snapshot("01-add-wine-form")
        app.navigationBars["Add wine"].buttons["Save"].tap()

        let row = searchCellar(for: producer)
        snapshot("02-cellar-list")

        // MARK: Detail — tasting note, extra bottle, where to buy
        row.tap()
        tap(app.buttons["Add note"])
        let noteField = app.textFields["Tasting note"]
        XCTAssertTrue(noteField.waitForExistence(timeout: 5), "tasting note row not added")
        type("Dark cherry, firm tannins", into: noteField)
        tap(element(labeled: "3 stars", last: true))
        tap(app.buttons["Add a bottle"])
        XCTAssertTrue(app.navigationBars["Add bottles"].waitForExistence(timeout: 5), "bottle editor didn't open")
        type("72", into: app.textFields["0.00"].firstMatch)
        snapshot("03a-add-bottle")
        app.navigationBars["Add bottles"].buttons["Save"].tap()
        // Section headers are uppercased in the accessibility label.
        let bottlesHeader = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", "Bottles (2 in stock)")).firstMatch
        XCTAssertTrue(bottlesHeader.waitForExistence(timeout: 5), "second bottle not added")
        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label CONTAINS %@", "Paid $72.00")).firstMatch
                        .waitForExistence(timeout: 5), "price paid not shown on the new bottle")
        snapshot("03-wine-detail")

        tap(app.buttons["Where to buy"])
        XCTAssertTrue(app.navigationBars["Where to buy"].waitForExistence(timeout: 5))
        dismissSystemAlerts()
        _ = app.staticTexts["Directions"].waitForExistence(timeout: 10)
        snapshot("04-where-to-buy")
        app.navigationBars["Where to buy"].buttons.firstMatch.tap()   // back
        app.navigationBars.buttons["Cellar"].tap()                     // back to list
        clearCellarSearch()

        // MARK: Wishlist — add, then move to cellar
        app.navigationBars["Cellar"].buttons["Add"].tap()
        app.segmentedControls.buttons["Wishlist"].tap()   // not the tab bar item
        type(wishProducer, into: app.textFields["Producer"])
        app.navigationBars["Add wine"].buttons["Save"].tap()

        app.tabBars.buttons["Wishlist"].tap()
        let wishRow = cell(containing: wishProducer)
        if !wishRow.waitForExistence(timeout: 3) { reveal(wishRow) }   // alphabetical: may be off-screen
        XCTAssertTrue(wishRow.exists, "wishlist item missing")
        snapshot("05-wishlist")
        wishRow.swipeRight()
        app.buttons["Move to cellar"].tap()
        XCTAssertTrue(wishRow.waitForNonExistence(timeout: 5), "item still on wishlist")

        app.tabBars.buttons["Cellar"].tap()
        searchCellar(for: wishProducer)
        clearCellarSearch()

        // MARK: Value — dashboard + CSV/PDF export
        app.tabBars.buttons["Value"].tap()
        XCTAssertTrue(app.navigationBars["Value"].waitForExistence(timeout: 5))
        snapshot("06-value")
        let gainRow = app.staticTexts["Gain"]
        reveal(gainRow)
        XCTAssertTrue(gainRow.exists, "gain row missing on the Value tab")
        XCTAssertTrue(app.staticTexts["You paid"].exists, "paid total missing on the Value tab")
        snapshot("06b-value-gain")
        app.swipeDown(velocity: .fast)
        for (menuItem, name) in [("Export CSV", "07-export-csv"), ("Export PDF summary", "08-export-pdf")] {
            app.navigationBars["Value"].buttons["Export"].tap()
            app.buttons[menuItem].tap()
            XCTAssertFalse(app.alerts["Export failed"].waitForExistence(timeout: 2))
            let share = app.otherElements["ActivityListView"]
            XCTAssertTrue(share.waitForExistence(timeout: 10), "share sheet did not appear for \(menuItem)")
            snapshot(name)
            if app.buttons["Close"].exists { app.buttons["Close"].tap() }
            else { app.swipeDown(velocity: .fast) }
            XCTAssertTrue(share.waitForNonExistence(timeout: 5))
        }
    }

    /// Two collections, bottles in each, and a separate total for each on the Value tab.
    func testCollectionsTotalSeparately() {
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let home = "Home \(stamp)", beach = "Beach \(stamp)", producer = "Coll \(stamp)"

        app.tabBars.buttons["Value"].tap()
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'collections'")).firstMatch)
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 5), "collections screen didn't open")
        for name in [home, beach] {
            app.navigationBars["Collections"].buttons["New collection"].tap()
            let field = app.alerts.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(name)
            app.alerts.buttons["Create"].tap()
        }
        XCTAssertTrue(app.staticTexts[beach].waitForExistence(timeout: 5), "collection not created")
        snapshot("13-collections")
        app.navigationBars["Collections"].buttons.firstMatch.tap()

        // Two bottles at Home, valued at 100 each.
        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Add"].tap()
        type(producer, into: app.textFields["Producer"])
        type("100", into: app.textFields["0.00"].firstMatch)
        let stepper = app.steppers.firstMatch
        reveal(stepper)
        stepper.buttons["Increment"].tap()
        chooseCollection(home)
        app.navigationBars["Add wine"].buttons["Save"].tap()

        // One more bottle at the beach.
        searchCellar(for: producer).tap()
        tap(app.buttons["Add a bottle"])
        XCTAssertTrue(app.navigationBars["Add bottles"].waitForExistence(timeout: 5))
        chooseCollection(beach)
        app.navigationBars["Add bottles"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Bottles (3 in stock)"))
                        .firstMatch.waitForExistence(timeout: 5), "third bottle not added")

        app.tabBars.buttons["Value"].tap()
        let homeRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", home, "$200.00")).firstMatch
        let beachRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", beach, "$100.00")).firstMatch
        reveal(homeRow)
        XCTAssertTrue(homeRow.waitForExistence(timeout: 5), "Home total should be $200.00")
        XCTAssertTrue(beachRow.exists, "Beach total should be $100.00")
        snapshot("14-collection-totals")
        homeRow.tap()
        XCTAssertTrue(app.navigationBars[home].waitForExistence(timeout: 5), "collection breakdown didn't open")
        snapshot("15-collection-detail")
    }

    private func chooseCollection(_ name: String) {
        choose(name, in: "Collection")
    }

    /// Picks `option` from the form's menu picker whose label starts with `pickerLabel`.
    private func choose(_ option: String, in pickerLabel: String) {
        let picker = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", pickerLabel)).firstMatch
        reveal(picker)
        picker.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(pickerLabel) option \(option) missing")
        item.tap()
    }

    /// Replaces a text field's contents: focus it, Select All from the edit menu, type over it.
    private func replaceText(in field: XCUIElement, with text: String) {
        reveal(field)
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.0)
            let selectAll = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Select All'")).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "Select All menu didn't appear")
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
    }

    /// Bulk moves: select wines in the Cellar list and move their bottles, then move
    /// one bottle out from the wine's page.
    func testMoveBottlesToCollection() {
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let wineA = "MoveA \(stamp)", wineB = "MoveB \(stamp)", cabin = "Cabin \(stamp)"

        func addWine(_ producer: String, bottles: Int) {
            app.tabBars.buttons["Cellar"].tap()
            app.navigationBars["Cellar"].buttons["Add"].tap()
            type(producer, into: app.textFields["Producer"])
            type("50", into: app.textFields["0.00"].firstMatch)
            let stepper = app.steppers.firstMatch
            reveal(stepper)
            for _ in 1..<bottles { stepper.buttons["Increment"].tap() }
            choose("None", in: "Collection")
            app.navigationBars["Add wine"].buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Add wine"].waitForNonExistence(timeout: 5), "\(producer) not saved")
        }
        func cabinRow(bottles: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", cabin, bottles)).firstMatch
        }

        addWine(wineA, bottles: 2)
        addWine(wineB, bottles: 1)

        app.navigationBars["Cellar"].buttons["Select"].tap()
        searchCellar(for: stamp)
        cell(containing: wineA).tap()
        cell(containing: wineB).tap()
        let moveMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move to'")).firstMatch
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 5), "Move to menu missing")
        snapshot("19-select-wines")
        moveMenu.tap()
        app.buttons["New collection…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(cabin)
        app.alerts.buttons["Create & move"].tap()

        app.tabBars.buttons["Value"].tap()
        let threeBottles = cabinRow(bottles: "3 bottles")
        reveal(threeBottles)
        XCTAssertTrue(threeBottles.waitForExistence(timeout: 5), "cabin should hold 3 bottles")
        XCTAssertTrue(threeBottles.label.contains("$150.00"), threeBottles.label)

        app.tabBars.buttons["Cellar"].tap()
        clearCellarSearch()
        searchCellar(for: wineA).tap()
        tap(app.buttons["Move bottles…"])
        XCTAssertTrue(app.navigationBars["Move bottles"].waitForExistence(timeout: 5), "move sheet didn't open")
        app.buttons.matching(identifier: "moveBottleRow").firstMatch.tap()
        choose("None", in: "Collection")
        snapshot("20-move-bottles")
        app.navigationBars["Move bottles"].buttons["Move"].tap()

        app.tabBars.buttons["Value"].tap()
        let twoBottles = cabinRow(bottles: "2 bottles")
        reveal(twoBottles)
        XCTAssertTrue(twoBottles.waitForExistence(timeout: 5), "cabin should hold 2 bottles after moving one out")
    }

    /// Settings defaults for new bottles: wine and spirit sizes drive the Add form.
    func testSettingsBottleSizeDefaults() {
        func setSizes(wine: String, spirits: String) {
            app.tabBars.buttons["Cellar"].tap()
            app.navigationBars["Cellar"].buttons["Settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "settings didn't open")
            choose(wine, in: "Wine bottle size")
            choose(spirits, in: "Spirits bottle size")
            app.navigationBars["Settings"].buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        }
        func sizePickerText() -> String {
            let picker = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Size'")).firstMatch
            reveal(picker)
            return "\(picker.label) \(picker.value as? String ?? "")"
        }

        setSizes(wine: "Magnum (1.5 L)", spirits: "700 mL")
        app.navigationBars["Cellar"].buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add wine"].waitForExistence(timeout: 5))
        XCTAssertTrue(sizePickerText().contains("Magnum"), "wine default not applied: \(sizePickerText())")
        choose("Whisky", in: "Type")
        XCTAssertTrue(sizePickerText().contains("700 mL"), "spirits default not applied: \(sizePickerText())")
        snapshot("18-settings-defaults")
        app.navigationBars["Add wine"].buttons["Cancel"].tap()

        // Put the built-in defaults back for other tests.
        setSizes(wine: "Standard (750 mL)", spirits: "Liter (1 L)")
    }

    /// Edit a saved wine: rename it, change vintage and type, and see the page update.
    func testEditSavedWine() {
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let producer = "Edit \(stamp)", edited = "Edited \(stamp)"

        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Add"].tap()
        type(producer, into: app.textFields["Producer"])
        type("2015", into: app.textFields["Vintage (blank = NV)"])
        app.navigationBars["Add wine"].buttons["Save"].tap()
        searchCellar(for: producer).tap()

        let detailBar = app.navigationBars["2015 \(producer)"]
        XCTAssertTrue(detailBar.waitForExistence(timeout: 5))
        detailBar.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit wine"].waitForExistence(timeout: 5), "wine editor didn't open")
        replaceText(in: app.textFields["Producer"], with: edited)
        replaceText(in: app.textFields["Vintage (blank = NV)"], with: "2016")
        choose("White", in: "Type")
        snapshot("16-edit-wine")
        app.navigationBars["Edit wine"].buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["2016 \(edited)"].waitForExistence(timeout: 5), "title didn't update")
        XCTAssertTrue(app.staticTexts["White"].exists, "type didn't update")
        snapshot("17-edited-wine")
        app.navigationBars["2016 \(edited)"].buttons["Cellar"].tap()
        clearCellarSearch()
        searchCellar(for: stamp)
        XCTAssertTrue(cell(containing: edited).exists, "edited name not listed")
        XCTAssertFalse(cell(containing: "2015 \(producer)").exists, "old name still listed")
        clearCellarSearch()
    }

    /// Crop and rotate a label photo in the Add form. The system photo picker can't be
    /// driven from a test, so a debug-only launch flag seeds a 900×1200 label photo.
    func testEditAndCropLabelPhoto() {
        app.terminate()
        app.launchArguments = ["-UITestSeedLabelPhoto"]
        app.launch()
        dismissSystemAlerts()

        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Add"].tap()
        let photo = app.images["labelPhoto"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "seeded photo missing")
        XCTAssertEqual(photo.value as? String, "900×1200")

        app.buttons["Edit photo"].tap()
        XCTAssertTrue(app.navigationBars["Edit photo"].waitForExistence(timeout: 5), "photo editor didn't open")
        let corner = app.descendants(matching: .any)["cropHandle.topLeading"]
        XCTAssertTrue(corner.waitForExistence(timeout: 5))
        let start = corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 120)))
        snapshot("10-crop")
        app.buttons["Rotate left"].tap()
        snapshot("11-rotated")
        app.navigationBars["Edit photo"].buttons["Done"].tap()

        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let edited = photo.value as? String ?? ""
        let dims = edited.split(separator: "×").compactMap { Int($0) }
        XCTAssertEqual(dims.count, 2, "unexpected size: \(edited)")
        if dims.count == 2 {
            XCTAssertGreaterThan(dims[0], dims[1], "rotated photo should be landscape: \(edited)")
            XCTAssertLessThan(dims[0], 1200, "crop should shrink the photo: \(edited)")
        }
        snapshot("12-edited-photo")
    }

    /// Online pricing through a plain-http dev proxy on this Mac. Skipped unless
    /// the proxy is running: `cd proxy && PROVIDER=mock npm start`.
    func testPricingViaLocalProxy() throws {
        try XCTSkipUnless(proxyIsRunning(), "Start the proxy: cd proxy && PROVIDER=mock npm start")
        let producer = "Opus One \(Int(Date().timeIntervalSince1970) % 100000)"

        // Settings must accept an http:// endpoint for a local proxy.
        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Settings"].tap()
        let endpoint = app.textFields.firstMatch
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        if let existing = endpoint.value as? String, existing.hasPrefix("http") {
            endpoint.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        endpoint.typeText("http://127.0.0.1:8787")
        app.navigationBars["Settings"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5),
                      "Settings rejected the http endpoint")

        app.navigationBars["Cellar"].buttons["Add"].tap()
        type(producer, into: app.textFields["Producer"])
        type("2018", into: app.textFields["Vintage (blank = NV)"])
        app.navigationBars["Add wine"].buttons["Save"].tap()
        searchCellar(for: producer).tap()

        // Saving the wine started a lookup automatically — no Refresh tap needed.
        let provenance = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From '")).firstMatch
        XCTAssertTrue(provenance.waitForExistence(timeout: 30), "price wasn't looked up automatically")
        XCTAssertFalse(app.alerts["Couldn't fetch price"].exists)
        snapshot("09-price-refreshed")
    }

    private func proxyIsRunning() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8787/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return ok
    }

    // MARK: - Helpers

    private func dismissSystemAlerts() {
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }
    }

    /// The Cellar list is alphabetical, so a newly added wine may be off-screen: search for it.
    @discardableResult
    private func searchCellar(for text: String) -> XCUIElement {
        let field = app.searchFields["Search wines"]
        if !field.waitForExistence(timeout: 2) { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(field.waitForExistence(timeout: 3), "cellar search field missing")
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText(text)
        let searchKey = app.keyboards.buttons["search"]
        if searchKey.exists { searchKey.tap() }
        let row = cell(containing: text)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(text) not found in the cellar")
        return row
    }

    /// Ends a Cellar search so the full list and toolbar come back.
    private func clearCellarSearch() {
        let cancel = app.navigationBars.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else if app.buttons["Cancel"].firstMatch.exists {
            app.buttons["Cancel"].firstMatch.tap()
        }
    }

    private func cell(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func element(labeled label: String, last: Bool = false) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        return last ? matches.element(boundBy: max(matches.count - 1, 0)) : matches.firstMatch
    }

    /// Hides the keyboard, then scrolls toward the element until it's hittable.
    private func reveal(_ element: XCUIElement) {
        dismissKeyboard()
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 12 {
            if element.exists && element.frame.minY < app.frame.midY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
            swipes += 1
        }
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        } else {
            app.navigationBars.firstMatch.tap()
        }
    }

    private func tap(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func type(_ text: String, into element: XCUIElement) {
        reveal(element)
        element.tap()
        element.typeText(text)
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
