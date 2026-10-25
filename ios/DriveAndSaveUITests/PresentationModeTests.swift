import XCTest

final class PresentationModeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOfflineSampleAcrossScreensRestoresActualLeagueAndHome() throws {
        let app = XCUIApplication()
        app.launchOffline(developerMode: false, presenterNickname: "Htoo")
        let actualHome = app.staticTexts["homeFinancialValue"].label
        app.openMain("Leagues")
        app.buttons["Create League"].tap()
        app.textFields["leagueName"].tap(); app.textFields["leagueName"].typeText("Actual Test League")
        app.buttons["createLeague"].tap()
        XCTAssertTrue(app.staticTexts["Current league: Actual Test League"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 member · 4 needed to rank"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy invite"].exists)
        let toggle = app.switches["presentationMode"]
        app.scrollFullyIntoView(toggle); toggle.tap()
        XCTAssertTrue(app.staticTexts["sampleLeagueHeadline"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Copy invite"].exists)
        for (name, amount) in [("Htoo", "$1.42"), ("Alex", "$1.85"), ("Jordan", "$2.40"), ("Sam", "$3.12"), ("Taylor", "$4.30"), ("Casey", "$5.75")] {
            let nameLabel = app.staticTexts[name]
            XCTAssertTrue(nameLabel.exists, "Missing sample player \(name)")
            app.scrollFullyIntoView(nameLabel)
            XCTAssertTrue(app.staticTexts[amount].exists)
        }
        let leagueImage = XCTAttachment(screenshot: app.screenshot()); leagueImage.name = "Presentation League"; leagueImage.lifetime = .keepAlways; add(leagueImage)
        app.openMain("Home")
        XCTAssertEqual(app.staticTexts["sampleHomeCost"].label, "$1.42")
        XCTAssertFalse(app.buttons["startTrip"].exists)
        XCTAssertTrue(app.staticTexts["Htoo · 2015 Audi A4"].exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Presentation Home"; home.lifetime = .keepAlways; add(home)
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["sampleProfileName"].label, "Htoo")
        XCTAssertEqual(app.staticTexts["sampleProfileVehicle"].label, "2015 Audi A4")
        XCTAssertEqual(app.staticTexts["sampleProfileCost"].label, "$1.42")
        XCTAssertTrue(app.switches["developerMode"].exists, "Developer Mode remains available")
        app.openAdvancedSettings()
        XCTAssertTrue(app.buttons["developerCalculation"].exists, "Test Calculation remains accessible")
        app.openMain("History")
        XCTAssertEqual(app.staticTexts["sampleHistoryCost"].label, "$1.42")
        for title in ["Morning commute", "Home from campus", "Coffee and errands", "Across town", "Campus commute", "Evening drive", "Grocery run", "Weekend outing"] { XCTAssertTrue(app.staticTexts[title].exists) }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'historyTrip-'")).firstMatch.exists)
        app.openMain("Leagues")
        app.scrollFullyIntoView(toggle); toggle.tap()
        XCTAssertTrue(app.staticTexts["1 member · 4 needed to rank"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["leagueHeadline"].label, "Actual Test League")
        XCTAssertTrue(app.buttons["Copy invite"].exists)
        app.openMain("Home")
        XCTAssertEqual(app.staticTexts["homeFinancialValue"].label, actualHome)
        XCTAssertTrue(app.buttons["startTrip"].exists)
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, "Htoo")
        XCTAssertFalse(app.staticTexts["sampleProfileVehicle"].exists)
    }
}
