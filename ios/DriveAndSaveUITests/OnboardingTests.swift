import XCTest

final class OnboardingTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testFirstLaunchPersistenceLeagueAndExplicitReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--account-test-id=" + UUID().uuidString]
        app.launch()
        let nickname = app.textFields["welcomeNickname"]
        XCTAssertTrue(nickname.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["welcomeRegister"].isEnabled)
        let welcome = XCTAttachment(screenshot: app.screenshot()); welcome.name = "First launch welcome"; welcome.lifetime = .keepAlways; add(welcome)
        nickname.tap(); nickname.typeText("Walking Buddy")
        app.buttons["Developer options"].tap()
        app.switches["offlineOnboarding"].tap()
        app.buttons["welcomeRegister"].tap()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 10))
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "Walking Buddy")
        XCTAssertFalse(app.staticTexts["profileUserID"].exists)
        app.openAdvancedSettings()
        let originalID = app.staticTexts["profileUserID"].label
        app.openMain("Leagues")
        app.buttons["Create League"].tap()
        app.textFields["leagueName"].tap(); app.textFields["leagueName"].typeText("Four Friends")
        app.buttons["createLeague"].tap()
        XCTAssertTrue(app.staticTexts["Current league: Four Friends"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["1 member · 4 needed to rank"].waitForExistence(timeout: 5))
        let copy = app.buttons["Copy invite"]
        for _ in 0..<4 where !copy.isHittable { app.swipeUp() }
        copy.tap()
        XCTAssertTrue(app.buttons["Invite copied"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["welcomeNickname"].exists)
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "Walking Buddy")
        XCTAssertTrue(app.staticTexts["Four Friends"].waitForExistence(timeout: 5))
        app.openAdvancedSettings()
        XCTAssertEqual(app.staticTexts["profileUserID"].label, originalID)
        let reset = app.buttons["resetTestAccount"]
        app.scrollFullyIntoView(reset)
        XCTAssertFalse(app.buttons["nav-Home"].exists)
        XCTAssertLessThanOrEqual(reset.frame.maxY, app.frame.maxY)
        reset.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.textFields["welcomeNickname"].exists)
        reset.tap()
        app.buttons["Reset sign-in & choose a new nickname"].tap()
        XCTAssertTrue(app.textFields["welcomeNickname"].waitForExistence(timeout: 5))
        let newName = app.textFields["welcomeNickname"]
        newName.tap(); newName.typeText("Different Driver")
        // Reset retains the chosen offline mode.
        app.buttons["welcomeRegister"].tap()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 10))
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "Different Driver")
        XCTAssertFalse(app.staticTexts["Four Friends"].exists)
        app.openAdvancedSettings()
        XCTAssertNotEqual(app.staticTexts["profileUserID"].label, originalID)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Advanced account after explicit test reset"; shot.lifetime = .keepAlways; add(shot)
    }
}
