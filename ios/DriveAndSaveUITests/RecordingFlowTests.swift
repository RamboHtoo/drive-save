import XCTest

final class RecordingFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSimulatedRecordingPersistsAndExistingScreensOpen() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["startTrip"].tap()
        let simulated = app.switches["simulatorMode"]
        XCTAssertTrue(simulated.waitForExistence(timeout: 5))
        simulated.tap()
        app.switches["mountConfirmed"].tap()
        let calibrate = app.buttons["calibrate"]
        if !calibrate.isHittable { app.swipeUp() }
        calibrate.tap()
        let start = app.buttons["beginRecording"]
        if !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        // The deterministic source produces acceleration, braking and turn candidates in 12 seconds.
        let elapsed = app.staticTexts["elapsedTime"]
        let enoughTime = NSPredicate { _, _ in (elapsed.label.components(separatedBy: ":").last.flatMap(Int.init) ?? 0) >= 13 }
        expectation(for: enoughTime, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        let stop = app.buttons["stopTrip"]
        if !stop.isHittable { app.swipeUp() }
        stop.tap()
        XCTAssertTrue(app.staticTexts["Simulator test drive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Estimate pending"].exists)
        XCTAssertTrue(app.staticTexts["DEMO · SIMULATED DATA"].exists)
        app.terminate()
        app.launch()
        app.tabBars.buttons["History"].tap()
        for _ in 0..<3 where !app.staticTexts["Simulator test drive"].firstMatch.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Simulator test drive"].firstMatch.exists)
        app.staticTexts["Simulator test drive"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Estimate pending"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Crew"].tap()
        XCTAssertTrue(app.staticTexts["Less waste.\nMore bragging rights."].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Drive Save"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLeavingForegroundEndsRecording() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["startTrip"].tap()
        app.switches["simulatorMode"].tap()
        app.switches["mountConfirmed"].tap()
        app.swipeUp()
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Recording ended"].waitForExistence(timeout: 5))
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["Estimate pending"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLeavingRecordingTabEndsCapture() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["startTrip"].tap()
        app.switches["simulatorMode"].tap()
        app.switches["mountConfirmed"].tap()
        app.swipeUp()
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Crew"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Recording ended"].waitForExistence(timeout: 5))
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["Estimate pending"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeniedPermissionCanFinishWithoutDistance() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["startTrip"].tap()
        let enable = app.buttons["enableLocation"]
        if enable.waitForExistence(timeout: 2) {
            enable.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = springboard.buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 5) { deny.tap() }
        }
        XCTAssertTrue(app.staticTexts["Location denied. Distance unavailable; candidate detection needs GPS speed."].waitForExistence(timeout: 5))
        app.switches["mountConfirmed"].tap()
        app.swipeUp()
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unavailable"].exists)
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["Recorded drive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Estimate pending"].exists)
        XCTAssertTrue(app.staticTexts["RECORDED · DEVICE SENSORS"].exists)
    }
}
