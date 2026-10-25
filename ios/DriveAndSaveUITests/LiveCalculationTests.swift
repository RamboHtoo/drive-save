import XCTest

/// Explicit opt-in live API UI check: new test driver + a separate calculation identity, never a real league.
final class LiveCalculationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testSavedVehicleToIsolatedServerReceipt() throws {
        guard ProcessInfo.processInfo.environment["DRIVE_SAVE_LIVE_CALCULATION"] == "1" else {
            throw XCTSkip("Opt-in live test. Set TEST_RUNNER_DRIVE_SAVE_LIVE_CALCULATION=1 when running xcodebuild.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--account-test-id=" + UUID().uuidString]
        app.launch()
        let name = app.textFields["welcomeNickname"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Calculation QA " + String(UUID().uuidString.prefix(6)) + "\n")
        app.buttons["welcomeRegister"].tap()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["progressEmptyState"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["homeFinancialValue"].label, "—")
        XCTAssertEqual(app.staticTexts["progressEmptyState"].label, "No scored trips yet.")
        XCTAssertFalse(app.staticTexts["DEMO · SIMULATED DATA"].exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Online Home empty progress"; home.lifetime = .keepAlways; add(home)
        app.buttons["openProfile"].tap()
        app.scrollFullyIntoView(app.buttons["myVehicle"]); app.buttons["myVehicle"].tap()
        app.buttons["chooseVehicle"].tap()
        app.buttons["selectVehicleBrand"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Toyota")
        XCTAssertTrue(app.buttons["vehicleOption-Toyota"].waitForExistence(timeout: 30)); app.buttons["vehicleOption-Toyota"].tap()
        app.buttons["selectVehicleModel"].tap()
        let modelSearch = app.searchFields.firstMatch
        XCTAssertTrue(modelSearch.waitForExistence(timeout: 5))
        modelSearch.tap(); modelSearch.typeText("CAMRY")
        XCTAssertTrue(app.buttons["vehicleOption-CAMRY"].waitForExistence(timeout: 30)); app.buttons["vehicleOption-CAMRY"].tap()
        app.buttons["selectVehicleYear"].tap()
        let yearSearch = app.searchFields.firstMatch
        XCTAssertTrue(yearSearch.waitForExistence(timeout: 5))
        yearSearch.tap(); yearSearch.typeText("2020")
        XCTAssertTrue(app.buttons["vehicleOption-2020"].waitForExistence(timeout: 30)); app.buttons["vehicleOption-2020"].tap()
        XCTAssertTrue(app.buttons["saveCatalogVehicle"].waitForExistence(timeout: 30))
        app.scrollFullyIntoView(app.buttons["saveCatalogVehicle"]); app.buttons["saveCatalogVehicle"].tap()
        XCTAssertTrue(app.navigationBars["My Vehicle"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.tap()
        app.openAdvancedSettings()
        let calculation = app.buttons["developerCalculation"]
        app.scrollFullyIntoView(calculation); calculation.tap()
        let test = app.buttons["testCalculation"]
        app.scrollFullyIntoView(test)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: test)
        waitForExpectations(timeout: 30)
        test.tap()
        XCTAssertTrue(app.staticTexts["calculationDemoLabel"].waitForExistence(timeout: 5))
        let vehicle = app.staticTexts["calculationPricingVehicle"]
        let completed = NSPredicate { _, _ in vehicle.exists || app.staticTexts["calculationError"].exists }
        expectation(for: completed, evaluatedWith: nil); waitForExpectations(timeout: 60)
        if !vehicle.exists, app.staticTexts["calculationError"].label.contains("500") {
            // A transient server error is retried as the same logical trip, never a new UUID.
            app.buttons["Retry"].tap()
            expectation(for: completed, evaluatedWith: nil); waitForExpectations(timeout: 60)
        }
        XCTAssertTrue(vehicle.exists, app.staticTexts["calculationError"].exists ? app.staticTexts["calculationError"].label : "Receipt not returned")
        XCTAssertTrue(vehicle.label.localizedCaseInsensitiveContains("Toyota"))
        XCTAssertTrue(vehicle.label.localizedCaseInsensitiveContains("CAMRY"))
        XCTAssertTrue(app.staticTexts["Estimated avoidable fuel cost"].exists)
        XCTAssertTrue(app.staticTexts["calculationModel"].exists)
        XCTAssertFalse(app.buttons["nav-Home"].exists)
        app.scrollFullyIntoView(vehicle)
        let receipt = XCTAttachment(screenshot: app.screenshot()); receipt.name = "Live synthetic calculation receipt"; receipt.lifetime = .keepAlways; add(receipt)
        let assumptions = app.buttons["How it’s calculated"]
        app.scrollFullyIntoView(assumptions); assumptions.tap()
        let assumption = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Marginal Wheel Efficiency:")).firstMatch
        XCTAssertTrue(assumption.waitForExistence(timeout: 5))
        // Driver's own identity/selection still exist; test results are outside local driving history.
        app.openMain("Home")
        XCTAssertTrue(app.staticTexts["progressEmptyState"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["homeFinancialValue"].label, "—", "Isolated synthetic calculations must not affect driver savings")
        XCTAssertEqual(app.staticTexts["progressEmptyState"].label, "No scored trips yet.")
        app.buttons["openProfile"].tap()
        XCTAssertTrue(app.staticTexts["profileNickname"].label.hasPrefix("Calculation QA"))
        XCTAssertEqual(app.staticTexts["profileVehicleTitle"].label, "2020 Toyota CAMRY")
    }
}
