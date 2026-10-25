import XCTest

final class HomeDesignTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testHomeProvenanceRecordingAndProfileRemainAccessible() throws {
        let app = XCUIApplication()
        app.launchOffline(developerMode: false)
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["homeFinancialValue"].exists)
        XCTAssertTrue(app.staticTexts["DEMO · SIMULATED DATA"].exists)
        XCTAssertFalse(app.staticTexts["Recent drives"].exists)
        XCTAssertFalse(app.staticTexts["Your championship"].exists)
        XCTAssertFalse(app.buttons["API & Vehicle"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Home instrument panel"; screenshot.lifetime = .keepAlways; add(screenshot)
        let start = app.buttons["startTrip"]
        for _ in 0..<3 where !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.buttons["beginRecording"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["recordingMode"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "HackPSU Demo")
        XCTAssertFalse(app.staticTexts["profileUserID"].exists)
        XCTAssertFalse(app.buttons["openAdvancedSettings"].exists)
        XCTAssertFalse(app.buttons["loadVehicleExample"].exists)
        let vehicle = app.buttons["myVehicle"]
        app.scrollFullyIntoView(vehicle); vehicle.tap()
        XCTAssertTrue(app.buttons["chooseVehicle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["testCalculation"].exists)
        XCTAssertFalse(app.textViews["vehicleJSON"].exists)
    }
}

final class LeagueDesignTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testChampionshipRowsInviteAndSecondaryNavigation() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.openMain("Leagues")
        XCTAssertTrue(app.staticTexts["leagueHeadline"].waitForExistence(timeout: 5))
        let top = XCTAttachment(screenshot: app.screenshot()); top.name = "Championship demo grid"; top.lifetime = .keepAlways; add(top)
        app.buttons["Create League"].tap()
        XCTAssertFalse(app.buttons["nav-Home"].exists)
        app.textFields["leagueName"].tap(); app.textFields["leagueName"].typeText("APEX / 04")
        app.buttons["createLeague"].tap()
        XCTAssertTrue(app.staticTexts["Current league: APEX / 04"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["1 member · 4 needed to rank"].waitForExistence(timeout: 5))
        for _ in 0..<4 { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(app.otherElements["currentDriverStanding"].exists)
        XCTAssertTrue(app.staticTexts["YOU"].exists)
        let grid = XCTAttachment(screenshot: app.screenshot()); grid.name = "Current driver under four members"; grid.lifetime = .keepAlways; add(grid)
    }
}

final class ReceiptDesignTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testDemoReceiptHasNoInventedTimelineAndNoPrimaryRail() throws {
        let app = XCUIApplication()
        app.launchOffline(developerMode: false)
        app.openMain("History")
        XCTAssertFalse(app.buttons["Cost trend"].exists)
        let trip = app.buttons["historyTrip-Campus → downtown"]
        XCTAssertTrue(trip.waitForExistence(timeout: 5))
        for _ in 0..<16 {
            let upper = app.navigationBars.firstMatch.frame.maxY
            let lower = app.otherElements["primaryNavigation"].frame.minY
            if trip.frame.minY > upper && trip.frame.maxY < lower { break }
            let up = trip.frame.maxY >= lower
            let scroll = app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.4))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.4 : 0.7)))
        }
        trip.tap()
        XCTAssertTrue(app.staticTexts["Estimated fuel impact"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nav-Home"].exists)
        XCTAssertTrue(app.staticTexts["DEMO · SIMULATED DATA"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Editorial local receipt"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertFalse(app.otherElements["tripTimeline"].exists)
        let assumptions = app.buttons["How it’s calculated"]
        app.scrollFullyIntoView(assumptions); assumptions.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Baseline fuel cost uses distance")).firstMatch.exists)
        XCTAssertFalse(app.buttons["receiptAdvancedSettings"].exists)
        XCTAssertFalse(app.buttons["Export API JSON"].exists)

    }
}

final class LargeTypeDesignTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testAccessibilityTypeCanReachHomeFooterAboveNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchOffline()
        let footer = app.staticTexts["Set up and review trips only when safely parked."]
        for _ in 0..<30 {
            if footer.isHittable && footer.frame.maxY < app.otherElements["primaryNavigation"].frame.minY && footer.frame.minY > app.buttons["openProfile"].frame.maxY { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(footer.isHittable)
        XCTAssertGreaterThan(footer.frame.minY, 0)
        XCTAssertLessThanOrEqual(footer.frame.maxY, app.otherElements["primaryNavigation"].frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Accessibility XXXL footer and navigation"; shot.lifetime = .keepAlways; add(shot)
        app.openMain("Leagues")
        XCTAssertTrue(app.staticTexts["leagueHeadline"].waitForExistence(timeout: 5))
    }
}
