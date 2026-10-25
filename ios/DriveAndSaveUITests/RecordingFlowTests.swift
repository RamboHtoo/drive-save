import XCTest

final class ScrollLayoutTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testLeaguesFooterAndStatusScrollAboveNativeTabBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--isolated-api-test"]
        app.launchOffline()
        app.openMain("Leagues")

        XCTAssertTrue(app.staticTexts["No league joined"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Offline mock user registered. No network request was made."].exists)
        XCTAssertFalse(app.staticTexts["Example standings"].exists)
        let footer = app.staticTexts["Create or join a league. 4 members needed to rank."]
        app.scrollFullyIntoView(footer)
        XCTAssertLessThanOrEqual(footer.frame.maxY, app.otherElements["primaryNavigation"].frame.minY)

        app.openMain("History")
        XCTAssertTrue(app.navigationBars["Trip history"].waitForExistence(timeout: 5))
        app.openMain("Home")
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
        app.confirmParkedMount()
        let calibrate = app.buttons["calibrate"]
        if !calibrate.isHittable { app.swipeUp() }
        app.scrollFullyIntoView(calibrate)
        calibrate.tap()
        let start = app.buttons["beginRecording"]
        if !start.isHittable { app.swipeUp() }
        app.scrollFullyIntoView(start)
        start.tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        // The deterministic source produces acceleration, braking and turn candidates in 12 seconds.
        let elapsed = app.staticTexts["elapsedTime"]
        let enoughTime = NSPredicate { _, _ in (((elapsed.value as? String) ?? elapsed.label).components(separatedBy: ":").last.flatMap(Int.init) ?? 0) >= 13 }
        expectation(for: enoughTime, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.staticTexts["liveGPSSpeed"].label, "Simulated GPS speed")
        XCTAssertEqual(app.staticTexts["liveGPSSpeed"].value as? String, "Unavailable", "The synthetic fixture has no observed GPS speed accuracy")
        XCTAssertTrue(app.staticTexts["Simulated vehicle acceleration"].exists)
        XCTAssertEqual(app.staticTexts["liveForwardAcceleration"].label, "Forward")
        XCTAssertEqual(app.staticTexts["liveLateralAcceleration"].label, "Lateral")
        let signedG = "^(positive|negative) [0-9]+\\.[0-9]{3} g$"
        XCTAssertNotNil((app.staticTexts["liveForwardAcceleration"].value as? String)?.range(of: signedG, options: .regularExpression))
        XCTAssertTrue(app.staticTexts["liveTripDistance"].value as? String != "Unavailable")
        app.scrollFullyIntoView(app.staticTexts["elapsedTime"])
        let telemetry = XCTAttachment(screenshot: app.screenshot()); telemetry.name = "Live telemetry · synthetic fixture"; telemetry.lifetime = .keepAlways; add(telemetry)
        let stop = app.buttons["stopTrip"]
        if !stop.isHittable { app.swipeUp() }
        stop.tap()
        XCTAssertTrue(app.staticTexts["Simulator test drive"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["receiptEstimateState"].label, "Not eligible for upload")
        XCTAssertTrue(app.staticTexts["DEMO · SIMULATED DATA"].exists)
        XCTAssertFalse(app.otherElements["tripTimeline"].exists)
        app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Trip saved on this iPhone"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.tap()
        XCTAssertTrue(app.buttons["startTrip"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchOffline()
        app.openMain("History")
        for _ in 0..<3 where !app.staticTexts["Simulator test drive"].firstMatch.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Simulator test drive"].firstMatch.exists)
        app.staticTexts["Simulator test drive"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["receiptEstimateState"].waitForExistence(timeout: 5))
        XCTAssertTrue(["Not eligible for upload", "Incomplete recording"].contains(app.staticTexts["receiptEstimateState"].label))
        app.openMain("Leagues")
        XCTAssertTrue(app.staticTexts["leagueHeadline"].waitForExistence(timeout: 5))
        app.openMain("Home")
        XCTAssertTrue(app.staticTexts["Drive Save"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLocalRecordingShowsDeveloperUploadDiagnostics() throws {
        let app = XCUIApplication(); app.launchOffline()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Demo Drive"].tap()
        app.confirmParkedMount()
        app.scrollFullyIntoView(app.buttons["beginRecording"]); app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.buttons["stopTrip"].waitForExistence(timeout: 5))
        app.scrollFullyIntoView(app.buttons["stopTrip"]); app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["tripUploadState"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["tripUploadState"].label, "Not eligible for upload")
        let diagnostics = app.buttons["recordingDiagnostics"]
        app.scrollFullyIntoView(diagnostics); diagnostics.tap()
        let summary = app.staticTexts["recordingUploadSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        for field in ["Offline mode · no backend POST", "Preflight:", "GPS samples:", "Largest valid-speed GPS gap:", "Motion samples:", "Calibration at end:", "events_complete:", "detector_version:"] {
            XCTAssertTrue(summary.label.contains(field), "Missing diagnostic field: " + field)
        }
        XCTAssertFalse(app.buttons["Upload / retry & fetch receipt"].exists, "Ineligible fixtures must stay local")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Developer recording upload diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate(); app.launchOffline(developerMode: false)
        app.openMain("History")
        let recording = app.buttons.matching(identifier: "historyTrip-Simulator test drive").firstMatch
        app.scrollFullyIntoView(recording); recording.tap()
        XCTAssertFalse(app.buttons["recordingDiagnostics"].exists, "Technical summary is hidden during ordinary app use")
        XCTAssertFalse(app.staticTexts["recordingUploadSummary"].exists)
    }

    @MainActor
    func testLeavingForegroundEndsRecording() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Demo Drive"].tap()
        app.confirmParkedMount()
        app.swipeUp()
        app.scrollFullyIntoView(app.buttons["beginRecording"])
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Recording ended"].waitForExistence(timeout: 5))
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["receiptEstimateState"].waitForExistence(timeout: 5))
        XCTAssertTrue(["Not eligible for upload", "Incomplete recording"].contains(app.staticTexts["receiptEstimateState"].label))
    }

    @MainActor
    func testRecordingHasFocusedNavigationAndStillEndsOnInterruption() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Demo Drive"].tap()
        app.confirmParkedMount()
        app.swipeUp()
        app.scrollFullyIntoView(app.buttons["beginRecording"])
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nav-Home"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Recording ended"].waitForExistence(timeout: 5))
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["receiptEstimateState"].waitForExistence(timeout: 5))
        XCTAssertTrue(["Not eligible for upload", "Incomplete recording"].contains(app.staticTexts["receiptEstimateState"].label))
    }

    @MainActor
    func testDeletingFreshRecordingUpdatesSaveScreen() throws {
        let app = XCUIApplication(); app.launchOffline()
        app.buttons["startTrip"].tap()
        app.segmentedControls.buttons["Walking Test"].tap()
        let start = app.buttons["beginRecording"]
        app.scrollFullyIntoView(start); start.tap()
        XCTAssertTrue(app.buttons["stopTrip"].waitForExistence(timeout: 5))
        let stop = app.buttons["stopTrip"]
        app.scrollFullyIntoView(stop); stop.tap()
        XCTAssertTrue(app.staticTexts["No fuel estimate"].waitForExistence(timeout: 5))
        let remove = app.buttons["deleteLocalTrip"]
        app.scrollFullyIntoView(remove); remove.tap()
        app.alerts.buttons["Delete from this iPhone"].tap()
        XCTAssertTrue(app.staticTexts["Local recording deleted"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["openReceipt"].exists)
        XCTAssertFalse(app.staticTexts["Trip saved on this iPhone"].exists)
    }

    @MainActor
    func testRecordingKeepsStartingVehicleAfterProfileChangeAndRelaunch() throws {
        let app = XCUIApplication(); app.launchOffline()
        func selectVehicle(brand: String, model: String, year: String) {
            app.buttons["openProfile"].tap()
            app.scrollFullyIntoView(app.buttons["myVehicle"]); app.buttons["myVehicle"].tap()
            app.scrollFullyIntoView(app.buttons["chooseVehicle"]); app.buttons["chooseVehicle"].tap()
            app.buttons["selectVehicleBrand"].tap(); app.buttons["vehicleOption-" + brand].tap()
            app.buttons["selectVehicleModel"].tap(); app.buttons["vehicleOption-" + model].tap()
            app.buttons["selectVehicleYear"].tap(); app.buttons["vehicleOption-" + year].tap()
            app.scrollFullyIntoView(app.buttons["saveCatalogVehicle"]); app.buttons["saveCatalogVehicle"].tap()
            XCTAssertTrue(app.navigationBars["My Vehicle"].waitForExistence(timeout: 5))
            app.openMain("Home")
        }
        selectVehicle(brand: "Mazda", model: "MAZDA5", year: "2012")
        app.buttons["startTrip"].tap(); app.segmentedControls.buttons["Demo Drive"].tap()
        app.confirmParkedMount()
        app.scrollFullyIntoView(app.buttons["beginRecording"]); app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.buttons["stopTrip"].waitForExistence(timeout: 5))
        let elapsed = app.staticTexts["elapsedTime"]
        expectation(for: NSPredicate { _, _ in (((elapsed.value as? String) ?? elapsed.label).components(separatedBy: ":").last.flatMap(Int.init) ?? 0) >= 2 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.scrollFullyIntoView(app.buttons["stopTrip"]); app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["Vehicle recorded: 2012 Mazda MAZDA5"].waitForExistence(timeout: 5))
        app.openMain("Home")
        selectVehicle(brand: "Tesla", model: "Cybertruck AWD", year: "2026")
        app.terminate(); app.launchOffline()
        app.openMain("History")
        let saved = app.buttons.matching(identifier: "historyTrip-Simulator test drive").firstMatch
        app.scrollFullyIntoView(saved); saved.tap()
        XCTAssertTrue(app.staticTexts["Vehicle recorded: 2012 Mazda MAZDA5"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Vehicle recorded: 2026 Tesla Cybertruck AWD"].exists)
        XCTAssertEqual(app.staticTexts["receiptEstimateState"].label, "Not eligible for upload")
    }

    @MainActor
    func testTelemetryAtAccessibilityTextSizeKeepsStopReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchOffline()
        app.buttons["startTrip"].tap(); app.segmentedControls.buttons["Walking Test"].tap()
        app.scrollFullyIntoView(app.buttons["beginRecording"]); app.buttons["beginRecording"].tap()
        for id in ["elapsedTime", "liveTripDistance", "liveGPSSpeed", "liveForwardAcceleration", "liveLateralAcceleration"] {
            let metric = app.staticTexts[id]
            // At accessibility XXXL these form several screens. Reveal them in reading order.
            for _ in 0..<16 where !metric.isHittable { app.swipeUp() }
            XCTAssertTrue(metric.exists && metric.isHittable, "Telemetry must remain readable with large accessibility text")
            if id == "liveGPSSpeed" {
                XCTAssertEqual(metric.label, "GPS speed")
                XCTAssertEqual(metric.value as? String, "Unavailable")
            }
        }
        let stop = app.buttons["stopTrip"]
        app.scrollFullyIntoView(stop); XCTAssertTrue(stop.isHittable); stop.tap()
        XCTAssertTrue(app.staticTexts["No fuel estimate"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeniedPermissionCanFinishWithoutDistance() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.openMain("History")
        let previousRecordings = app.buttons.matching(identifier: "historyTrip-Recorded drive").count
        app.openMain("Home")
        app.buttons["startTrip"].tap()
        let enable = app.buttons["enableLocation"]
        if enable.waitForExistence(timeout: 2) {
            enable.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = springboard.buttons["Don’t Allow"]
            if deny.waitForExistence(timeout: 5) { deny.tap() }
        }
        XCTAssertTrue(app.staticTexts["Location denied · distance unavailable"].waitForExistence(timeout: 5))
        app.confirmParkedMount()
        app.swipeUp()
        app.scrollFullyIntoView(app.buttons["beginRecording"])
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["liveTripDistance"].value as? String, "Unavailable")
        app.buttons["stopTrip"].tap()
        XCTAssertTrue(app.staticTexts["Recorded drive"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["receiptEstimateState"].label, "Incomplete recording")
        XCTAssertFalse(app.staticTexts["0.00 mi"].exists)
        app.openMain("History")
        let recordings = app.buttons.matching(identifier: "historyTrip-Recorded drive")
        XCTAssertEqual(recordings.count, previousRecordings + 1)
        let latest = recordings.element(boundBy: 0)
        app.scrollFullyIntoView(latest); latest.tap()
        XCTAssertEqual(app.staticTexts["receiptEstimateState"].label, "Incomplete recording")
        let remove = app.buttons["deleteLocalTrip"]
        app.scrollFullyIntoView(remove); remove.tap()
        XCTAssertTrue(app.alerts["Delete local recording?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Recorded drive"].exists)
        remove.tap(); app.alerts.buttons["Delete from this iPhone"].tap()
        XCTAssertTrue(app.navigationBars["Trip history"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "historyTrip-Recorded drive").count, previousRecordings)
        app.terminate(); app.launchOffline()
        app.openMain("History")
        XCTAssertEqual(app.buttons.matching(identifier: "historyTrip-Recorded drive").count, previousRecordings)
    }
}

final class WalkingFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testWalkingDeniedSavesReloadsAndExcludesDrivingAndCrew() throws {
        let app = XCUIApplication()
        app.launchOffline()
        app.openMain("Leagues")
        let rankingPredicate = NSPredicate(format: "label MATCHES %@", "[0-9]+% improvement")
        let before = app.staticTexts.matching(rankingPredicate).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(before.isEmpty, "No fictional standings should appear before joining a league")
        app.openMain("Home")
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
        app.scrollFullyIntoView(app.buttons["beginRecording"])
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["liveTripDistance"].value as? String, "Unavailable")
        let disabledEvents = app.staticTexts["Driving events: Disabled"]
        for _ in 0..<8 where !disabledEvents.isHittable { app.swipeUp() }
        XCTAssertTrue(disabledEvents.exists)
        let stop = app.buttons["stopTrip"]
        for _ in 0..<5 where !stop.isHittable { app.swipeUp() }
        XCTAssertFalse(app.buttons["nav-Home"].exists, "Recording is a focused secondary destination")
        XCTAssertLessThanOrEqual(stop.frame.maxY, app.frame.maxY, "Save control must remain within the screen")
        stop.tap()
        XCTAssertTrue(app.staticTexts["No fuel estimate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Estimate pending"].exists)
        XCTAssertFalse(app.staticTexts["Driving moments"].exists)
        app.terminate()
        app.launchOffline()
        app.openMain("History")
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
        app.openMain("Leagues")
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
        app.scrollFullyIntoView(app.buttons["beginRecording"])
        app.buttons["beginRecording"].tap()
        XCTAssertTrue(app.staticTexts["Recording · foreground only"].waitForExistence(timeout: 5))
        let distance = NSPredicate { _, _ in
            app.staticTexts.allElementsBoundByIndex.contains {
                let value = ($0.value as? String) ?? $0.label
                return value.hasSuffix(" mi") && value != "0.00 mi"
            }
        }
        expectation(for: distance, evaluatedWith: nil)
        waitForExpectations(timeout: 35)
        XCTAssertTrue(app.staticTexts["gpsAccuracy"].exists)
        XCTAssertTrue(app.staticTexts["Driving events: Disabled"].exists)
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
    func testOfflineVehicleToolsAndLeague() throws {
        let app = XCUIApplication(); app.launchOffline()
        app.buttons["openProfile"].tap()
        app.openAdvancedSettings()
        XCTAssertTrue(app.staticTexts["Signed in as HackPSU Demo"].waitForExistence(timeout: 5))
        tap(app.buttons["loadVehicleExample"], app: app)
        tap(app.buttons["saveVehicle"], app: app)
        XCTAssertTrue(app.buttons["developerCalculation"].exists)
        XCTAssertFalse(app.buttons["uploadReplay"].exists)
        XCTAssertFalse(app.staticTexts["CONTRACT DEMO REPLAY"].exists)
        app.openMain("Leagues")
        app.buttons["Create League"].tap()
        app.textFields["leagueName"].tap(); app.textFields["leagueName"].typeText("Offline Test League")
        app.buttons["createLeague"].tap()
        XCTAssertTrue(app.staticTexts["Current league: Offline Test League"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["1 member · 4 needed to rank"].waitForExistence(timeout: 5))
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
        app.openAdvancedSettings()
        let id = app.staticTexts["profileUserID"].label
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openProfile"].waitForExistence(timeout: 10))
        app.buttons["openProfile"].tap()
        XCTAssertEqual(app.staticTexts["profileNickname"].label, nickname)
        app.openAdvancedSettings()
        XCTAssertEqual(app.staticTexts["profileUserID"].label, id)
    }
}

/// Every offline test uses a fresh Keychain/local API namespace, never an existing driver account.
extension XCUIApplication {
    @MainActor
    func openAdvancedSettings() {
        enableDeveloperMode()
        let link = buttons["openAdvancedSettings"]
        scrollFullyIntoView(link); link.tap()
        XCTAssertTrue(staticTexts["profileUserID"].waitForExistence(timeout: 5))
    }
    @MainActor
    func scrollFullyIntoView(_ element: XCUIElement) {
        for _ in 0..<18 {
            let upper = navigationBars.firstMatch.exists ? navigationBars.firstMatch.frame.maxY : 60
            let lower = buttons["nav-Home"].exists ? otherElements["primaryNavigation"].frame.minY : frame.maxY - 24
            if element.frame.minY > upper + 4 && element.frame.maxY < lower - 4 { break }
            let up = element.frame.maxY >= lower - 4
            let scroll = scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.4))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.4 : 0.7)))
        }
    }
    @MainActor
    func confirmParkedMount() {
        let toggle = switches["mountConfirmed"]
        scrollFullyIntoView(toggle)
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(toggle.value as? String, "1")
    }
    @MainActor
    func openMain(_ name: String) {
        let destination = buttons["nav-" + name]
        for _ in 0..<8 where !destination.exists {
            let back = navigationBars.buttons.matching(identifier: "BackButton").firstMatch
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.tap()
    }
    @MainActor
    func launchOffline(developerMode: Bool = true, presenterNickname: String = "HackPSU Demo") {
        if !launchArguments.contains(where: { $0.hasPrefix("--account-test-id=") }) {
            launchArguments.append("--account-test-id=" + UUID().uuidString)
        }
        launch()
        let nickname = textFields["welcomeNickname"]
        if nickname.waitForExistence(timeout: 3) {
            nickname.tap(); nickname.typeText(presenterNickname + "\n")
            buttons["Developer options"].tap()
            switches["offlineOnboarding"].tap()
            let register = buttons["welcomeRegister"]
            for _ in 0..<12 {
                let upper = navigationBars.firstMatch.frame.maxY
                if register.frame.minY > upper && register.frame.maxY < frame.maxY - 24 { break }
                let scroll = scrollViews.firstMatch
                let up = register.frame.maxY >= frame.maxY - 24
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.4))
                    .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.4 : 0.7)))
            }
            register.tap()
            XCTAssertTrue(buttons["startTrip"].waitForExistence(timeout: 10))
        }
        buttons["openProfile"].tap()
        let toggle = switches["developerMode"]
        scrollFullyIntoView(toggle)
        if (toggle.value as? String == "1") != developerMode { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        openMain("Home")
    }
    @MainActor
    func enableDeveloperMode() {
        let toggle = switches["developerMode"]
        scrollFullyIntoView(toggle)
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
    }
}
