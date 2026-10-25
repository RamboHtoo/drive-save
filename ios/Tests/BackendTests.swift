import Foundation

final class MemoryCredentialStore: CredentialStore {
    var credential: StoredCredential?
    func clear() throws { credential = nil }
    func load() throws -> StoredCredential? { credential }
    func save(_ credential: StoredCredential) throws { self.credential = credential }
}
final class BackendStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = data
            }
            let (status, data) = try Self.handler(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct BackendContractTests {
    static var passes = 0
    static func check(_ condition: Bool, _ text: String) throws {
        guard condition else { throw BackendError.invalidInput("TEST FAILED: " + text) }
        passes += 1; print("PASS: " + text)
    }
    static func fixture<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
        try APIJSON.decoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/\(name).json")))
    }
    static func main() async throws {
        var trip = try fixture("sample-trip", APITripPayload.self)
        let vehicle = try fixture("sample-vehicle", VehicleRow.self)
        let receipt = try fixture("sample-receipt", APIReceipt.self)
        try TripUploadBuilder.validate(trip)
        try check(trip.events.count == 3 && trip.speed_samples.count == 63, "backend trip fixture decodes and validates")
        try check(trip.speed_samples[41].speed_mps == nil && trip.speed_samples[41].speed_accuracy_mps == nil, "invalid GPS speeds and accuracy normalize to null")
        let body = try APIJSON.encoder().encode(trip)
        let text = String(decoding: body, as: UTF8.self)
        try check(!text.contains("latitude") && !text.contains("longitude") && !text.contains("cost_usd"), "trip wire payload contains no coordinates or dollar inputs")
        try check(text.contains("Z") && text.contains("\"speed_mps\":null"), "wire timestamps are UTC and invalid readings encode null")
        try check(vehicle["target_coef_a_lbf"] == .number(25.28) && vehicle.count == 17, "complete EPA fixture row retained with exact analytics keys")
        try check(receipt.cost_model == "flat_per_event" && receipt.avoidable_cost_usd == 3 && receipt.is_estimate, "actual placeholder receipt and assumptions decode")
        let roundtrip = try APIJSON.decoder().decode(APITripPayload.self, from: body)
        try check(roundtrip.client_trip_id == trip.client_trip_id && roundtrip.events == trip.events, "trip and event UUIDs remain stable after serialization")
        let unchangedID = trip.client_trip_id
        trip.source = "replayed"; trip.is_demo = true
        try TripUploadBuilder.validate(trip)
        try check(trip.client_trip_id == unchangedID, "retry/replay labeling does not change an existing client UUID")
        var bad = trip; bad.is_demo = false
        do { try TripUploadBuilder.validate(bad); throw BackendError.invalidInput("Expected replay rejection") }
        catch BackendError.invalidInput(let message) { try check(message != "Expected replay rejection", "unlabeled replay rejected") }
        var walking = DemoData.snapshot.trips[0]; walking.activity = .walkingTest
        do { _ = try TripUploadBuilder.payload(for: walking); throw BackendError.invalidInput("Expected walking rejection") }
        catch BackendError.invalidInput(let message) { try check(message.contains("Walking"), "Walking Tests rejected before network access") }
        do { _ = try TripUploadBuilder.payload(for: DemoData.snapshot.trips[0]); throw BackendError.invalidInput("Expected legacy rejection") }
        catch BackendError.invalidInput(let message) { try check(message.contains("older"), "legacy trips without required metadata rejected") }
        let measuredEvents = trip.events.map { event -> DrivingEvent in
            let kind: DrivingEventKind = event.type == "harsh_brake" ? .harshBraking : event.type == "rapid_accel" ? .rapidAcceleration : .sharpTurn
            return DrivingEvent(id: event.event_id, timestamp: event.ts, kind: kind, magnitude: event.peak_g * 9.80665, detectorVersion: event.detector_version, durationSeconds: event.duration_s, peakG: event.peak_g)
        }
        let details = RecordingDetails(endedAt: trip.ended_at, elapsedSeconds: trip.ended_at.timeIntervalSince(trip.started_at), distanceAvailable: true, distanceIsPartial: false, motionAvailable: true, calibrationDescription: "Unit test", events: measuredEvents, motionSamples: [], gpsPoints: [], interruptions: [], measurementsIncomplete: false, speedSamples: trip.speed_samples)
        let local = Trip(id: UUID(), title: "Contract unit test", date: trip.started_at, distanceMiles: trip.distance_mi, durationMinutes: 18, harshBraking: 1, rapidAcceleration: 1, mpg: 28, fuelPrice: 3.65, modeledExcessGallons: 0, source: .measured, recording: details, activity: .driving, clientTripID: trip.client_trip_id)
        let converted = try TripUploadBuilder.payload(for: local)
        try check(converted.source == "recorded" && !converted.is_demo && converted.events.map(\.type) == ["harsh_brake", "rapid_accel", "sharp_turn"], "recorded local trip maps exact event types and real provenance")
        try check(converted.events.allSatisfy { $0.duration_s != nil && $0.peak_g > 0 && $0.speed_before_mph >= 0 && $0.speed_after_mph >= 0 }, "event duration, peak and before/after GPS evidence serialize")
        try check(converted.events.last?.heading_change_deg == nil, "unavailable heading change is omitted, not invented")
        var replayLocal = local; replayLocal = Trip(id: local.id, title: local.title, date: local.date, distanceMiles: local.distanceMiles, durationMinutes: 18, harshBraking: 1, rapidAcceleration: 1, mpg: 28, fuelPrice: 3.65, modeledExcessGallons: 0, source: .simulated, recording: details, activity: .driving, clientTripID: local.clientTripID)
        let replayConverted = try TripUploadBuilder.payload(for: replayLocal)
        try check(replayConverted.source == "replayed" && replayConverted.is_demo, "simulated recording never becomes a real API trip")
        let savedPayload = try JSONDecoder().decode(APITripPayload.self, from: JSONEncoder().encode(converted))
        try check(try APIJSON.encoder().encode(savedPayload) == APIJSON.encoder().encode(converted), "request body remains identical after local persistence for retries")
        let boardData = Data("{\"crew_id\":\"00000000-0000-0000-0000-000000000001\",\"crew_name\":\"Demo League\",\"member_count\":4,\"active\":true,\"period\":\"week\",\"generated_at\":\"2026-10-24T20:00:00Z\",\"standings\":[{\"rank\":null,\"user_id\":\"00000000-0000-0000-0000-000000000002\",\"nickname\":\"Driver\",\"improvement_pct\":null,\"est_savings_usd\":0,\"trips_counted\":0}],\"is_demo\":true,\"is_estimate\":true}".utf8)
        let board = try APIJSON.decoder().decode(APILeaderboard.self, from: boardData)
        try check(board.standings.first?.rank == nil && board.standings.first?.improvement_pct == nil && board.is_demo, "updated member leaderboard preserves unranked drivers and demo marker")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BackendStub.self]
        let session = URLSession(configuration: config)
        let credentials = MemoryCredentialStore()
        let userID = UUID()
        var registrations = 0; var vehicleWrites = 0; var uploads = 0; var receiptReads = 0
        var uploadedBody: Data?
        BackendStub.handler = { request in
            if request.url!.path == "/users" {
                registrations += 1
                return (201, try APIJSON.encoder().encode(APIUser(user_id: userID, nickname: "Dedicated Demo", token: "test-token-\(registrations)")))
            }
            if registrations == 1 { return (401, Data("{\"error\":{\"code\":\"invalid_token\",\"message\":\"Reset\"}}".utf8)) }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-2" else { throw BackendError.invalidInput("Authentication header test failed") }
            if request.url!.path == "/users/me/vehicle" {
                vehicleWrites += 1
                return (200, try APIJSON.encoder().encode(vehicle))
            }
            if request.url!.path == "/trips" {
                uploads += 1
                guard vehicleWrites > 0 else { throw BackendError.invalidInput("Vehicle was not uploaded first") }
                if let old = uploadedBody, old != request.httpBody { throw BackendError.invalidInput("Retry body changed") }
                uploadedBody = request.httpBody
                return (uploads == 1 ? 201 : 200, try APIJSON.encoder().encode(APITripCreated(trip_id: receipt.trip_id, receipt_url: "/trips/\(receipt.trip_id)/receipt", duplicate: uploads > 1)))
            }
            if request.url!.path.hasSuffix("/receipt") { receiptReads += 1; return (200, try APIJSON.encoder().encode(receipt)) }
            throw BackendError.invalidInput("Unexpected endpoint in test")
        }
        let api = BackendAPIClient(mode: .remote(URL(string: "https://example.invalid")!), demoOnly: true, session: session, credentialStore: credentials)
        _ = try await api.register(nickname: "Dedicated Demo", demoAccount: true)
        let created = try await api.upload(trip, vehicle: vehicle)
        let duplicate = try await api.upload(trip, vehicle: vehicle)
        _ = try await api.receipt(tripID: created.trip_id)
        try check(registrations == 2 && credentials.credential?.userID == userID, "401 demo recovery registers once and saves user identity")
        try check(created.duplicate == false && duplicate.duplicate == true && uploadedBody != nil, "201 and duplicate 200 preserve identical trip body")
        try check(vehicleWrites >= 2 && receiptReads == 1, "vehicle precedes upload and receipt endpoint is fetched")
        try check(await api.takeResetNotice() != nil, "server reset notice is available for UI")
        do { _ = try await api.createLeague(name: "Forbidden replay league"); throw BackendError.invalidInput("Expected isolated account rejection") }
        catch BackendError.invalidInput(let message) { try check(message.contains("Isolated replay"), "replay account cannot enter league competition") }
        for status in [409, 422] {
            BackendStub.handler = { _ in (status, Data("{\"error\":{\"code\":\"validation_error\",\"message\":\"Review trip\",\"details\":[{\"loc\":[\"body\",\"events\",0,\"peak_g\"],\"msg\":\"invalid peak\",\"type\":\"value_error\"}]}}".utf8)) }
            do { _ = try await api.getVehicle(); throw BackendError.invalidInput("Expected HTTP failure") }
            catch BackendError.server(let actual, let details) { try check(actual == status && details?.details?.first?.loc.count == 4, "HTTP \(status) retains field details") }
        }
        BackendStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await api.getVehicle(); throw BackendError.invalidInput("Expected offline failure") }
        catch let error as URLError { try check(error.code == .notConnectedToInternet, "network loss remains retryable") }
        let restored = BackendAPIClient(mode: .remote(URL(string: "https://example.invalid")!), session: session, credentialStore: credentials)
        try check(try await restored.identity()?.userID == userID, "fresh client restores saved identity without a registration request")
        do { _ = try await restored.register(nickname: "Overwrite", demoAccount: false); throw BackendError.invalidInput("Expected overwrite rejection") }
        catch BackendError.invalidInput(let message) { try check(message.contains("already exists"), "existing identity cannot silently be overwritten") }
        try await restored.resetLocalAccount()
        try check(try await restored.identity() == nil && credentials.credential == nil, "explicit reset clears only the selected credential store")
        BackendStub.handler = { _ in (500, Data()) }
        do { _ = try await restored.register(nickname: "Retry", demoAccount: false); throw BackendError.invalidInput("Expected registration failure") }
        catch BackendError.server(let code, _) { try check(code == 500 && credentials.credential == nil, "failed registration does not create or persist an identity") }
        let protectedStore = MemoryCredentialStore()
        let protectedID = UUID()
        try protectedStore.save(StoredCredential(userID: protectedID, nickname: "Keep Me", token: "unit-token", isDemoAccount: false))
        var unexpectedRegistrations = 0
        BackendStub.handler = { request in
            if request.url?.path == "/users" { unexpectedRegistrations += 1 }
            return (401, Data())
        }
        let protectedClient = BackendAPIClient(mode: .remote(URL(string: "https://example.invalid")!), session: session, credentialStore: protectedStore)
        do { _ = try await protectedClient.getVehicle(); throw BackendError.invalidInput("Expected expired session") }
        catch BackendError.expiredSession { try check(unexpectedRegistrations == 0 && protectedStore.credential?.userID == protectedID, "401 never silently replaces an ordinary driver identity") }
        let mockCredentials = MemoryCredentialStore()
        let mock = BackendAPIClient(credentialStore: mockCredentials)
        let mockUser = try await mock.register(nickname: "Offline", demoAccount: false)
        let mockRestored = BackendAPIClient(credentialStore: mockCredentials)
        try check(try await mockRestored.identity() == mockUser, "offline identity persists through its own credential store")
        let remoteEmpty = BackendAPIClient(mode: .remote(URL(string: "https://example.invalid")!), credentialStore: MemoryCredentialStore())
        try check(try await remoteEmpty.identity() == nil, "offline account does not become a remote identity")
        let sharedInvite = "Join my Drive Save league: Friends\nLeague ID: \(userID.uuidString)\nInvite code: DEMO42"
        try check(LeagueInvitation.parse(sharedInvite)?.id == userID && LeagueInvitation.parse(sharedInvite)?.code == "DEMO42", "shared invitation resolves exact league ID and code")
        try check(LeagueInvitation.parse("DEMO42") == nil, "code-only invite is not fabricated into a league ID")
        // Live progress uses the authenticated driver's endpoint, never the legacy demo snapshot.
        let progressStore = MemoryCredentialStore()
        let progressID = UUID()
        try progressStore.save(.init(userID: progressID, nickname: "Progress QA", token: "progress-unit-token", isDemoAccount: false))
        let progressClient = BackendAPIClient(mode: .remote(URL(string: "https://example.invalid")!), session: session, credentialStore: progressStore)
        func progressData(count: Int = 0, needed: Int = 3, baseline: Double? = nil, current: Double? = nil, improvement: Double? = nil, savings: Double = 0, owner: UUID? = nil) throws -> Data {
            try APIJSON.encoder().encode(APIProgress(user_id: owner ?? progressID, trips_counted: count, baseline_trips_needed: needed, baseline_waste_per_mile_usd: baseline, current_waste_per_mile_usd: current, improvement_pct: improvement, est_savings_usd: savings, weekly: [], is_estimate: true))
        }
        BackendStub.handler = { request in
            guard request.httpMethod == "GET", request.url?.path.lowercased() == "/users/\(progressID)/progress".lowercased(), request.url?.query == nil,
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer progress-unit-token" else { throw BackendError.invalidResponse }
            return (200, try progressData())
        }
        let empty = try await progressClient.progress()
        try check(empty.user_id == progressID && !empty.hasSavings && empty.availability == "No scored trips yet.", "progress uses exact self-only endpoint with Bearer auth and a clean empty state")
        let baseline = try APIJSON.decoder().decode(APIProgress.self, from: progressData(count: 1, needed: 2))
        try check(!baseline.hasSavings && baseline.availability.contains("2 more scored trips"), "baseline collection never presents a zero-dollar savings claim")
        let ready = try APIJSON.decoder().decode(APIProgress.self, from: progressData(count: 4, needed: 0, baseline: 0.02, current: 0.03, improvement: -50, savings: -0.0624))
        try check(ready.hasSavings && ready.est_savings_usd == -0.0624 && ready.est_savings_usd.receiptDollars.contains("0.0624"), "signed server savings retain negative values and sub-cent precision")
        let noWeekly = try APIJSON.decoder().decode(APIProgress.self, from: progressData(count: 3, needed: 0, baseline: 0.02))
        try check(!noWeekly.hasSavings && noWeekly.availability == "No weekly savings estimate yet.", "completed baseline without weekly results stays unpriced")
        let zeroBaseline = try APIJSON.decoder().decode(APIProgress.self, from: progressData(count: 4, needed: 0, baseline: 0, current: 0.01))
        try check(!zeroBaseline.hasSavings, "zero-baseline server state is not misrepresented as ready savings")
        let readyZero = try APIJSON.decoder().decode(APIProgress.self, from: progressData(count: 4, needed: 0, baseline: 0.02, current: 0.02, improvement: 0))
        try check(readyZero.hasSavings, "a genuine ready zero-dollar result remains displayable")
        BackendStub.handler = { _ in (200, try progressData(owner: UUID())) }
        do { _ = try await progressClient.progress(); throw BackendError.invalidInput("Expected owner mismatch rejection") }
        catch BackendError.invalidResponse { try check(true, "another user's progress cannot be displayed") }
        BackendStub.handler = { _ in (401, Data()) }
        do { _ = try await progressClient.progress(); throw BackendError.invalidInput("Expected expired progress session") }
        catch BackendError.expiredSession { try check(progressStore.credential?.userID == progressID, "progress 401 preserves the driver identity for explicit recovery") }
        BackendStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await progressClient.progress(); throw BackendError.invalidInput("Expected progress network failure") }
        catch let error as URLError { try check(error.code == .notConnectedToInternet, "progress network failures propagate without mock fallback") }
        let updatedStandingData = Data("{\"rank\":null,\"user_id\":\"\(progressID)\",\"nickname\":\"QA\",\"improvement_pct\":null,\"est_savings_usd\":0,\"trips_counted\":0,\"state\":\"no_weekly_trips\"}".utf8)
        let waiting = try APIJSON.decoder().decode(APIStanding.self, from: updatedStandingData)
        try check(waiting.availability == "No weekly trips" && waiting.rank == nil, "individual standings display the returned readiness state without invented ranks")
        BackendStub.handler = { _ in (409, Data("{\"error\":{\"code\":\"trip_not_scored\",\"message\":\"event_recording_incomplete\"}}".utf8)) }
        do { _ = try await progressClient.receipt(tripID: UUID()); throw BackendError.invalidInput("Expected unscored receipt") }
        catch let error as BackendError { try check(error.localizedDescription.contains("No estimate was produced") && error.localizedDescription.contains("event_recording_incomplete"), "unscored receipts retain the actual server reason without a fallback amount") }
        print("\(passes) backend contract checks passed.")
    }
}
