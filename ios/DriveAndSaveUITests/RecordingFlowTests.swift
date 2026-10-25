import XCTest

final class ScrollLayoutTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testLeaguesFooterAndStatusScrollAboveNativeTabBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--isolated-api-test"]
        app.launchOffline()
        app.tabBars.buttons["Leagues"].tap()

        let status = app.staticTexts["Offline mock user registered. No network request was made."]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        // Reach the actual content end, including wrapped status text, on any screen size.
        for _ in 0..<4 { app.scrollViews.firstMatch.swipeUp() }
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(status.isHittable)
        XCTAssertGreaterThan(status.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(status.frame.maxY, tabBar.frame.minY,
                                 "The entire final status message must clear the floating tab bar")
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Walking Tests, demo replays,")).firstMatch
        XCTAssertTrue(footer.isHittable)
        XCTAssertLessThanOrEqual(footer.frame.maxY, tabBar.frame.minY)
        XCTAssertGreaterThanOrEqual(app.scrollViews.firstMatch.frame.maxY, tabBar.frame.minY,
                                    "No extra fixed-height band may shrink the scroll viewport")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Leagues bottom — full status above native navigation"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["Trip history"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["startTrip"].exists)
    }
}

final class RecordingFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSimulatedRecordingPersistsAndExistingScreensOpen() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.buttons["startTrip"].tap()
        let simulated = app.segmentedControls.buttons["Demo Drive"]
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
        app.launchOffline()
        app.tabBars.buttons["History"].tap()
        for _ in 0..<3 where !app.staticTexts["Simulator test drive"].firstMatch.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Simulator test drive"].firstMatch.exists)
        app.staticTexts["Simulator test drive"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Estimate pending"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Leagues"].tap()
        XCTAssertTrue(app.staticTexts["Less waste.\nMore bragging rights."].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Drive Save"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLeavingForegroundEndsRecording() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Demo Drive"].tap()
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
        app.launchOffline()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Demo Drive"].tap()
        app.switches["mountConfirmed"].tap()
        app.swipeUp()
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Leagues"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Recording ended"].waitForExistence(timeout: 5))
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["Estimate pending"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeniedPermissionCanFinishWithoutDistance() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.buttons["startTrip"].tap()
        let enable = app.buttons["enableLocation"]
        if enable.waitForExistence(timeout: 2) {
            enable.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = springboard.buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 5) { deny.tap() }
        }
        XCTAssertTrue(app.staticTexts["Location denied · distance unavailable"].waitForExistence(timeout: 5))
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

final class WalkingFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testWalkingDeniedSavesReloadsAndExcludesDrivingAndCrew() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.tabBars.buttons["Leagues"].tap()
        let rankingPredicate = NSPredicate(format: "label MATCHES %@", "[0-9]+% improvement")
        let before = app.staticTexts.matching(rankingPredicate).allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(before.isEmpty)
        app.tabBars.buttons["Home"].tap()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Walking Test"].tap()
        XCTAssertTrue(app.staticTexts["Walking GPS Test"].exists)
        XCTAssertFalse(app.buttons["calibrate"].exists)
        XCTAssertFalse(app.switches["mountConfirmed"].exists)
        if app.buttons["enableLocation"].exists {
            app.buttons["enableLocation"].tap()
            let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 5) { deny.tap() }
        }
        XCTAssertTrue(app.staticTexts["Location denied · distance unavailable"].waitForExistence(timeout: 5))
        if !app.buttons["beginRecording"].isHittable { app.swipeUp() }
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Disabled"].exists)
        XCTAssertTrue(app.staticTexts["Unavailable"].exists)
        let stop = app.buttons["stopTrip"]
        for _ in 0..<5 where !stop.isHittable { app.swipeUp() }
        XCTAssertLessThanOrEqual(stop.frame.maxY, app.tabBars.firstMatch.frame.minY, "Save control must stay above the native tab bar")
        stop.tap()
        XCTAssertTrue(app.staticTexts["No fuel estimate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Estimate pending"].exists)
        XCTAssertFalse(app.staticTexts["Driving moments"].exists)
        app.terminate()
        app.launchOffline()
        app.tabBars.buttons["History"].tap()
        let filter = app.switches["includeWalkingTests"]
        let viewport = app.scrollViews.firstMatch
        func nudge(up: Bool) {
            let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.4))
            let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.4 : 0.7))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        for _ in 0..<12 {
            if filter.frame.minY <= app.navigationBars.firstMatch.frame.maxY + 8 { nudge(up: false) }
            else if filter.frame.maxY >= viewport.frame.maxY - 16 { nudge(up: true) }
            else { break }
        }
        XCTAssertEqual(app.switches["includeWalkingTests"].value as? String, "0")
        XCTAssertFalse(app.staticTexts["Walking Test"].exists)
        app.switches["includeWalkingTests"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["includeWalkingTests"].value as? String, "1")
        let walkingRow = app.staticTexts["Walking Test"].firstMatch
        for _ in 0..<8 {
            if walkingRow.exists {
                if walkingRow.frame.minY <= app.navigationBars.firstMatch.frame.maxY { nudge(up: false); continue }
                if walkingRow.frame.maxY < app.scrollViews.firstMatch.frame.maxY - 16 { break }
            }
            nudge(up: true)
        }
        if !app.staticTexts["Walking Test"].firstMatch.exists {
            print("HISTORY DEBUG: " + app.debugDescription)
            let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
        }
        XCTAssertTrue(app.staticTexts["Walking Test"].firstMatch.exists)
        app.staticTexts["Walking Test"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No fuel estimate"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Leagues"].tap()
        let after = app.staticTexts.matching(rankingPredicate).allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(before, after)
    }
}

/// Run separately with simulator location permission granted and a simctl walking route active.
/// This tests the real Core Location code path using OS-simulated coordinates, not physical GPS accuracy.
final class WalkingGPSRouteTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testWalkingWithCoreLocationRoute() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Walking Test"].tap()
        if !app.buttons["beginRecording"].isHittable { app.swipeUp() }
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        let distance = NSPredicate { _, _ in
            app.staticTexts.allElementsBoundByIndex.contains { $0.label.hasSuffix(" mi") && $0.label != "0.00 mi" }
        }
        expectation(for: distance, evaluatedWith: nil)
        waitForExpectations(timeout: 35)
        XCTAssertTrue(app.staticTexts["gpsAccuracy"].exists)
        XCTAssertTrue(app.staticTexts["Disabled"].exists)
        let recordingImage = XCTAttachment(screenshot: app.screenshot())
        recordingImage.name = "Walking Test recording"
        recordingImage.lifetime = .keepAlways
        add(recordingImage)
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["No fuel estimate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Driving moments"].exists)
        let receiptImage = XCTAttachment(screenshot: app.screenshot())
        receiptImage.name = "Walking Test receipt"
        receiptImage.lifetime = .keepAlways
        add(receiptImage)
    }
}

final class BackendFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    private func tap(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        element.tap()
    }
    @MainActor
    func testOfflineRegistrationVehicleReplayReceiptAndLeague() throws {
        let app = XCUIApplication(); app.launchOffline()
        app.buttons["API & Vehicle"].tap()
        XCTAssertTrue(app.staticTexts["Signed in as HackPSU Demo"].waitForExistence(timeout: 5))
        tap(app.buttons["loadVehicleExample"], app: app)
        tap(app.buttons["saveVehicle"], app: app)
        tap(app.buttons["uploadReplay"], app: app)
        for _ in 0..<3 where !app.staticTexts["PLACEHOLDER PRICING"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["PLACEHOLDER PRICING"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["cost_model: flat_per_event"].exists)
        XCTAssertTrue(app.staticTexts["is_estimate: true"].exists)
        app.tabBars.buttons["Leagues"].tap()
        app.buttons["Create League"].tap()
        app.textFields["leagueName"].tap(); app.textFields["leagueName"].typeText("Offline Test League")
        app.buttons["createLeague"].tap()
        XCTAssertTrue(app.staticTexts["Current league: Offline Test League"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["1 members · Unranked — needs 4+ members"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Individual driver rankings"].exists)
    }
}

/// Opt-in remote registration through the actual welcome UI, with an isolated test identity.
final class RemoteAuthenticationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testDedicatedDemoRegistrationPersistsInKeychain() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--account-test-id=" + UUID().uuidString]
        app.launch()
        let field = app.textFields["welcomeNickname"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let nickname = "iOS Welcome Demo " + String(UUID().uuidString.prefix(6))
        field.tap(); field.typeText(nickname)
        app.buttons["welcomeRegister"].tap()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 30))
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, nickname)
        let id = app.staticTexts["profileUserID"].label
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 10))
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, nickname)
        XCTAssertEqual(app.staticTexts["profileUserID"].label, id)
    }
}

/// Every offline test uses a fresh Keychain/local API namespace, never an existing driver account.
private extension XCUIApplication {
    @MainActor
    func launchOffline() {
        if !launchArguments.contains(where: { $0.hasPrefix("--account-test-id=") }) {
            launchArguments.append("--account-test-id=" + UUID().uuidString)
        }
        launch()
        let nickname = textFields["welcomeNickname"]
        if nickname.waitForExistence(timeout: 3) {
            nickname.tap(); nickname.typeText("HackPSU Demo")
            switches["offlineOnboarding"].tap()
            buttons["welcomeRegister"].tap()
            XCTAssertTrue(buttons["startTrip"].waitForExistence(timeout: 10))
        }
    }
}
