import XCTest

final class HomeDesignTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testHomeProvenanceRecordingAndProfileRemainAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--account-test-id=" + UUID().uuidString]
        app.launch()
        let field = app.textFields["welcomeNickname"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Design Test")
        app.switches["offlineOnboarding"].tap(); app.buttons["welcomeRegister"].tap()
        XCTAssertTrue(app.staticTexts["homeHeadline"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["homeFinancialValue"].exists)
        XCTAssertTrue(app.staticTexts["DEMO · SIMULATED DATA"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Home instrument panel"; screenshot.lifetime = .keepAlways; add(screenshot)
        let start = app.buttons["startTrip"]
        for _ in 0..<3 where !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.segmentedControls["recordingMode"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "Design Test")
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
        XCTAssertTrue(app.staticTexts["1 members · Unranked — needs 4+ members"].waitForExistence(timeout: 5))
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
        app.launchOffline()
        app.openMain("History")
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
        XCTAssertTrue(app.staticTexts["LOCAL / SIMULATED ESTIMATE"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nav-Home"].exists)
        XCTAssertTrue(app.staticTexts["DEMO · SIMULATED DATA"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Editorial local receipt"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.staticTexts["No timestamped observations available."].exists)
        for _ in 0..<5 { app.scrollViews.firstMatch.swipeUp() }
        let assumptions = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "All measurements and excess fuel on this demo receipt")).firstMatch
        XCTAssertTrue(assumptions.exists)
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
