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
        app.switches["offlineOnboarding"].tap()
        app.buttons["welcomeRegister"].tap()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 10))
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "Walking Buddy")
        let originalID = app.staticTexts["profileUserID"].label
        app.openMain("Leagues")
        app.buttons["Create League"].tap()
        app.textFields["leagueName"].tap(); app.textFields["leagueName"].typeText("Four Friends")
        app.buttons["createLeague"].tap()
        XCTAssertTrue(app.staticTexts["Current league: Four Friends"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["1 members · Unranked — needs 4+ members"].waitForExistence(timeout: 5))
        let copy = app.buttons["Copy invite"]
        for _ in 0..<4 where !copy.isHittable { app.swipeUp() }
        copy.tap()
        XCTAssertTrue(app.buttons["Invite copied"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["welcomeNickname"].exists)
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "Walking Buddy")
        XCTAssertEqual(app.staticTexts["profileUserID"].label, originalID)
        XCTAssertTrue(app.staticTexts["Four Friends"].waitForExistence(timeout: 5))
        let reset = app.buttons["resetTestAccount"]
        for _ in 0..<4 { app.scrollViews.firstMatch.swipeUp() }
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
        XCTAssertNotEqual(app.staticTexts["profileUserID"].label, originalID)
        XCTAssertFalse(app.staticTexts["Four Friends"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Profile after explicit test reset"; shot.lifetime = .keepAlways; add(shot)
    }
}
