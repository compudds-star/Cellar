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
        tap(star("3 stars", in: "note-rating"))
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
        // Collections are alphabetical: Beach rows come before Home rows.
        reveal(beachRow)
        XCTAssertTrue(beachRow.waitForExistence(timeout: 5), "Beach total should be $100.00")
        reveal(homeRow)
        XCTAssertTrue(homeRow.waitForExistence(timeout: 5), "Home total should be $200.00")
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
        // Long menus scroll, and off-screen items aren't in the tree until scrolled to
        // (the simulator collects many test collections over runs).
        var scrolls = 0
        while !item.waitForExistence(timeout: scrolls == 0 ? 3 : 1), scrolls < 10 {
            let visibleItem = app.buttons.matching(NSPredicate(format: "label != ''")).element(boundBy: 0)
            let menu = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : visibleItem
            menu.swipeUp(velocity: .slow)
            scrolls += 1
        }
        XCTAssertTrue(item.exists, "\(pickerLabel) option \(option) missing")
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

    /// Move a cellar wine to the Wishlist from Edit, then back: bottles and price paid survive.
    func testMoveWineToWishlistAndBack() {
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let producer = "Roundtrip \(stamp)"

        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Add"].tap()
        type(producer, into: app.textFields["Producer"])
        type("90", into: app.textFields["0.00"].firstMatch)
        let stepper = app.steppers.firstMatch
        reveal(stepper)
        stepper.buttons["Increment"].tap()
        type("40", into: app.textFields.matching(identifier: "0.00").element(boundBy: 1))
        app.navigationBars["Add wine"].buttons["Save"].tap()

        searchCellar(for: producer).tap()
        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit wine"].waitForExistence(timeout: 5), "editor didn't open")
        tap(app.buttons["Move to Wishlist"])
        let confirm = app.sheets.buttons["Move to Wishlist"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation missing")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Edit wine"].waitForNonExistence(timeout: 5))
        if app.navigationBars.buttons["Cellar"].exists { app.navigationBars.buttons["Cellar"].tap() }
        clearCellarSearch()

        app.tabBars.buttons["Wishlist"].tap()
        let wishRow = cell(containing: producer)
        if !wishRow.waitForExistence(timeout: 3) { reveal(wishRow) }
        XCTAssertTrue(wishRow.exists, "wine not on the Wishlist")
        snapshot("21-moved-to-wishlist")
        // Back to the cellar from the Wishlist wine's Edit screen.
        wishRow.tap()
        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit wine"].waitForExistence(timeout: 5), "editor didn't open from the Wishlist")
        tap(app.buttons["Move to Cellar"])
        let confirmCellar = app.sheets.buttons["Move to Cellar"]
        XCTAssertTrue(confirmCellar.waitForExistence(timeout: 5), "Move to Cellar confirmation missing")
        confirmCellar.tap()
        XCTAssertTrue(app.navigationBars["Edit wine"].waitForNonExistence(timeout: 5))
        if app.navigationBars.buttons["Wishlist"].exists { app.navigationBars.buttons["Wishlist"].tap() }
        XCTAssertTrue(wishRow.waitForNonExistence(timeout: 5), "wine still on the Wishlist")

        app.tabBars.buttons["Cellar"].tap()
        searchCellar(for: producer).tap()
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Bottles (2 in stock)")).firstMatch
        reveal(header)
        XCTAssertTrue(header.exists, "bottles should come back without a duplicate")
        XCTAssertTrue(app.descendants(matching: .any)
                        .matching(NSPredicate(format: "label CONTAINS %@", "Paid $40.00")).firstMatch.exists,
                      "price paid lost")
    }

    /// Share a page from Safari to the Wishlist through the share extension.
    func testShareFromSafariAddsToWishlist() throws {
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let extra = "Shared \(stamp)"
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()

        let addressCandidates = [safari.textFields["Address"], safari.buttons["Address"],
                                 safari.textFields["TabBarItemTitle"], safari.buttons["TabBarItemTitle"],
                                 safari.otherElements["TabBarItemTitle"]]
        guard let address = addressCandidates.first(where: { $0.waitForExistence(timeout: 3) }) else {
            XCTFail("Safari address bar not found")
            return
        }
        address.tap()
        safari.typeText("https://example.com\n")
        guard safari.staticTexts["Example Domain"].waitForExistence(timeout: 30) else {
            throw XCTSkip("Safari couldn't load example.com (offline?)")
        }

        let shareCandidates = [safari.buttons["ShareButton"], safari.buttons["Share"]]
        guard let share = shareCandidates.first(where: { $0.waitForExistence(timeout: 3) }) else {
            XCTFail("Safari share button not found")
            return
        }
        share.tap()
        let cellarActivity = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Cellar' AND (elementType == %d OR elementType == %d)",
                                  XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue))
            .firstMatch
        XCTAssertTrue(cellarActivity.waitForExistence(timeout: 10), "Cellar isn't in the share sheet")
        snapshot("22-share-sheet", of: safari)
        cellarActivity.tap()

        let sheetBar = safari.navigationBars["Add to Cellar"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 15), "share extension didn't open")
        let nameField = safari.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Cuv'")).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "extension form didn't load")
        nameField.tap()
        nameField.typeText(extra)
        snapshot("23-share-extension", of: safari)
        let save = sheetBar.buttons["Save"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 15)
        save.tap()
        XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 10))

        app.activate()
        let added = app.alerts["Added from another app"]
        XCTAssertTrue(added.waitForExistence(timeout: 15), "app didn't import the shared wine")
        added.buttons["OK"].tap()
        app.tabBars.buttons["Wishlist"].tap()
        let row = cell(containing: extra)
        if !row.waitForExistence(timeout: 3) { reveal(row) }
        XCTAssertTrue(row.exists, "shared wine not on the Wishlist")
    }

    /// Tapping inside existing text in Edit wine puts the cursor there, not at the end.
    /// Taps two letters into the producer, types a marker, and checks where it landed.
    func testTapPlacesCursorInText() {
        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let producer = "Cursor \(stamp)"

        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Add"].tap()
        type(producer, into: app.textFields["Producer"])
        app.navigationBars["Add wine"].buttons["Save"].tap()

        searchCellar(for: producer).tap()
        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit wine"].waitForExistence(timeout: 5), "editor didn't open")

        let field = app.textFields["Producer"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // About two characters in from the start of the text ("Cu|rsor …").
        field.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: field.frame.height / 2))
            .tap()
        field.typeText("#")
        let value = field.value as? String ?? ""
        snapshot("24-cursor-tap")
        XCTAssertTrue(value.contains("#"), "marker wasn't typed: \(value)")
        // iOS snaps a first tap to the nearest word edge, so "#Cursor …" is correct here.
        XCTAssertFalse(value.hasSuffix("#"), "cursor jumped to the end instead of the tap: \(value)")

        app.navigationBars["Edit wine"].buttons["Cancel"].tap()
    }

    /// The invite screen renders a scannable code and offers to send it, so a friend
    /// can be set up without typing an endpoint or a token.
    func testInviteFriendShowsCodeAndCanShareIt() {
        app.tabBars.buttons["Cellar"].tap()
        app.navigationBars["Cellar"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "settings didn't open")

        let invite = app.buttons["Invite a friend"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5), "no invite row in Settings")
        invite.tap()

        XCTAssertTrue(app.navigationBars["Invite a friend"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Setup QR code"].waitForExistence(timeout: 5), "QR code didn't render")
        XCTAssertTrue(app.buttons["Share code and link"].exists, "no way to send the invite")

        // Copying is the fallback when a chat app won't linkify cellar://.
        app.buttons["Copy link"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3))

        app.navigationBars["Invite a friend"].buttons["Settings"].tap()
        // The build someone is running, under their device id — at the foot of a
        // long form, so scroll to it first.
        let version = app.staticTexts["app-version"]
        for _ in 0..<4 where !version.exists { app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 5), "no version line in Settings")
        XCTAssertTrue(version.label.hasPrefix("Version "), "unexpected version line: \(version.label)")
        app.navigationBars["Settings"].buttons["Cancel"].tap()
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
        // Rows read "<producer and cuvée>, <vintage>, …": the old producer must be gone.
        XCTAssertFalse(cell(containing: "\(producer),").exists, "old name still listed")
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

    /// The owner's caps, set from the phone: unlock the hidden controls, hand over
    /// the admin token, read what the server enforces, and change it. Skipped
    /// unless the proxy is running with ADMIN_TOKEN=admin123.
    func testOwnerSetsMonthlyCapOnTheServer() throws {
        try XCTSkipUnless(proxyIsRunning(), "Start the proxy: cd proxy && PROVIDER=mock npm start")

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
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))

        app.navigationBars["Cellar"].buttons["Settings"].tap()
        let version = app.staticTexts["app-version"]
        for _ in 0..<4 where !version.exists { app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 5))

        // A phone that already holds the admin token keeps the controls on show, so
        // the hidden-by-default check and the unlock only apply before that.
        // (A section header's case is styled, so assert on the fields themselves.)
        let tokenField = app.secureTextFields["Admin token from the server"]
        let monthly = app.textFields["Monthly cap per device"]
        if !monthly.exists {
            XCTAssertFalse(tokenField.exists, "owner controls visible before unlocking")
            for _ in 0..<5 { version.tap() }
            for _ in 0..<3 where !tokenField.exists { app.swipeUp() }
            XCTAssertTrue(tokenField.waitForExistence(timeout: 5),
                          "five taps didn't reveal the owner controls")
            tokenField.tap()
            tokenField.typeText("admin123")
            app.buttons["Save token"].tap()
        }

        // The caps the server is enforcing come back and fill the fields.
        XCTAssertTrue(monthly.waitForExistence(timeout: 10), "server caps never loaded")
        XCTAssertEqual(monthly.value as? String, "7", "the field should show what the server enforces")

        // Tapping puts the cursor wherever it lands, so select the whole value
        // before replacing it rather than assuming deletes reach it.
        monthly.tap()
        monthly.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) {
            app.menuItems["Select All"].tap()
        }
        monthly.typeText("42")
        XCTAssertEqual(monthly.value as? String, "42", "the cap field didn't take the new value")

        app.buttons["Apply to server"].tap()
        XCTAssertTrue(app.staticTexts["Saved. The server is enforcing these now."]
                        .waitForExistence(timeout: 10), "the server didn't take the new cap")

        // Leave the phone as it was found, so the next run re-tests the unlock.
        let forget = app.buttons["Forget admin token"]
        for _ in 0..<3 where !forget.exists { app.swipeUp() }
        if forget.exists { forget.tap() }
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5), "the token wasn't forgotten")
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
        // The score badge sits under the label photo, so it's the first sign the
        // lookup landed; the provenance line is further down the screen.
        let badge = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Score '")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 30), "price wasn't looked up automatically")
        XCTAssertFalse(app.alerts["Couldn't fetch price"].exists)
        snapshot("10-score-badge-detail")

        // A List renders lazily, so the Value section has to be scrolled into
        // view before its provenance line exists to query.
        let provenance = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From '")).firstMatch
        reveal(provenance)
        XCTAssertTrue(provenance.exists, "no provenance line for the fetched price")
        snapshot("09-price-refreshed")

        app.navigationBars.buttons["Cellar"].tap()
        let rowBadge = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Score '")).firstMatch
        XCTAssertTrue(rowBadge.waitForExistence(timeout: 5), "no score badge in the list row")
        snapshot("11-score-badge-list")

        // "Refresh Prices" under the cellar value re-prices the whole cellar at once.
        clearCellarSearch()
        let refreshAll = app.buttons["Refresh Prices"]
        XCTAssertTrue(refreshAll.waitForExistence(timeout: 5), "no Refresh Prices button under the cellar value")
        refreshAll.tap()
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Updated '")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 60), "refresh-all never finished")
        XCTAssertFalse(app.alerts["Couldn't refresh prices"].exists)
        snapshot("13-refreshed-all-prices")
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

    /// A star inside a named rating control. Scoping by identifier keeps this
    /// independent of how many other star controls are on screen: the wine's own
    /// rating sits at the top of the detail screen, and scrolling recycles it in
    /// and out of the hierarchy, which makes "the last star labelled X" a race.
    private func star(_ label: String, in identifier: String) -> XCUIElement {
        let flat = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, label))
        if flat.count > 0 { return flat.element(boundBy: 0) }
        // SwiftUI may keep the identifier on the container instead of the stars.
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(labeled label: String, last: Bool = false) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        return last ? matches.element(boundBy: max(matches.count - 1, 0)) : matches.firstMatch
    }

    /// Hides the keyboard, then scrolls toward the element until it's hittable.
    private func reveal(_ element: XCUIElement) {
        dismissKeyboard()
        var swipes = 0
        while !isComfortablyVisible(element) && swipes < 20 {
            if element.exists {
                if element.frame.minY < app.frame.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            } else {
                // Off-screen rows aren't in the tree: look further down first, then back up.
                if swipes < 8 { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) }
            }
            swipes += 1
        }
    }

    /// On screen with room to tap: below the navigation bar, above the bottom edge and
    /// tab bar, and not under the keyboard. (`isHittable` alone accepts elements sitting
    /// on the very bottom edge, where a tap misses.)
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

    private func tap(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func type(_ text: String, into element: XCUIElement) {
        reveal(element)
        element.tap()
        element.typeText(text)
    }

    private func snapshot(_ name: String, of target: XCUIApplication? = nil) {
        let shot = XCTAttachment(screenshot: (target ?? app).screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
