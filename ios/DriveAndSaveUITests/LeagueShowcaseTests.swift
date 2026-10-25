import XCTest

final class LeagueShowcaseTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testSixMembersInSameLeagueWithExplicitSyntheticCosts() throws {
        let app = XCUIApplication(); app.launchOffline(presenterNickname: "Htoo")
        app.openMain("Leagues")
        app.buttons["Create League"].tap()
        app.textFields["leagueName"].tap(); app.textFields["leagueName"].typeText("Existing Htoo fixture league")
        app.buttons["createLeague"].tap()
        XCTAssertTrue(app.staticTexts["Current league: Existing Htoo fixture league"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.tap()
        let show = app.buttons["openLeagueShowcase"]
        app.scrollFullyIntoView(show); show.tap()
        XCTAssertTrue(app.staticTexts["showcaseMemberCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["showcaseMemberCount"].label, "6 members")
        XCTAssertTrue(app.staticTexts["Offline fixture · no server data"].exists)
        for (name, cost, rank) in [("Alex", "$1.85", "01"), ("Jordan", "$2.40", "02"), ("Sam", "$3.12", "03"), ("Taylor", "$4.30", "04"), ("Casey", "$5.75", "05")] {
            let row = app.otherElements["standing-" + name + " · Synthetic demo"]
            app.scrollFullyIntoView(row)
            XCTAssertTrue(row.exists)
            XCTAssertTrue(row.staticTexts[cost].exists)
            XCTAssertTrue(row.staticTexts[rank].exists)
            XCTAssertTrue(row.staticTexts["SYNTHETIC DEMO · supplied example · excluded from genuine competition"].exists)
        }
        let current = app.otherElements["currentDriverStanding"]
        app.scrollFullyIntoView(current)
        XCTAssertTrue(current.staticTexts["Htoo"].exists)
        XCTAssertTrue(current.staticTexts["Not ranked"].exists)
        XCTAssertTrue(current.staticTexts["Recorded scored trips only · no example costs added"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Htoo unranked with five tagged examples in existing fixture league"; shot.lifetime = .keepAlways; add(shot)
        app.openMain("Leagues")
        XCTAssertTrue(app.staticTexts["Existing Htoo fixture league"].exists)
        XCTAssertTrue(app.staticTexts["1 member · 4 needed to rank"].exists, "Read-only offline showcase never alters membership or genuine competition")
    }
}
