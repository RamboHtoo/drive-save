import SwiftUI

private struct SavedUpload: Codable {
    let payload: APITripPayload
    let vehicle: VehicleRow
    var owner: UUID
    var serverTripID: UUID?
    var receipt: APIReceipt?
    let mock: Bool
    var insufficientReason: String? = nil
}
private struct BackendLocalState: Codable {
    var remoteMode: Bool?
    var baseURL: String?
    var offlineLeague: APILeague?
    var vehicle: VehicleRow?
    var vehicleConfirmed = false
    var vehicleSelections: [String: SavedVehicleSelection]?
    var leagueByUser: [String: UUID] = [:]
    var uploads: [String: SavedUpload] = [:]
    var replay: APITripPayload?
    var uploadTraces: [String: TripUploadTrace]? = nil
}

@MainActor
final class BackendViewModel: ObservableObject {
    @Published private(set) var isRemote = true
    @Published private(set) var isRestoringAccount = true
    @Published var recoveryMessage: String?
    @Published private(set) var identity: APIIdentity?
    @Published private(set) var isBusy = false
    @Published private(set) var vehicle: VehicleRow?
    @Published private(set) var vehicleConfirmed = false
    @Published private(set) var league: APILeague?
    @Published private(set) var standings: [APIStanding] = []
    @Published private(set) var leaderboardIsDemo = false
    @Published private(set) var leaderboardMetric: String?
    @Published private(set) var notice: String?
    @Published private(set) var consumerErrorMessage: String?
    @Published var errorMessage: String?
    @Published private var revision = 0
    @Published private(set) var progress: APIProgress?
    @Published private(set) var progressError: String?
    @Published private(set) var isRefreshingProgress = false
    @Published private(set) var progressContext = 0
    private var progressRequest = 0

    private func clearProgress() {
        progressRequest += 1; progressContext += 1
        progress = nil; progressError = nil; isRefreshingProgress = false
    }
    func refreshProgress() async {
        guard isRemote, let owner = identity?.userID else { return }
        progressRequest += 1
        let request = progressRequest, context = progressContext, client = api
        isRefreshingProgress = true; progressError = nil
        defer { if request == progressRequest { isRefreshingProgress = false } }
        do {
            let loaded = try await client.progress()
            guard request == progressRequest, context == progressContext, identity?.userID == owner, isRemote else { return }
            progress = loaded
        } catch {
            guard request == progressRequest, context == progressContext, identity?.userID == owner, isRemote else { return }
            if Task.isCancelled { return }
            progress = nil // Never substitute demo values or a different account's cached money.
            progressError = error.localizedDescription
        }
    }
    private let credentialSuffix: String = {
        let arguments = ProcessInfo.processInfo.arguments
        if let id = arguments.first(where: { $0.hasPrefix("--account-test-id=") }) { return "#" + id }
        return arguments.contains("--isolated-api-test") ? "#ui-api-test" : ""
    }()
    private var api = BackendAPIClient()
    private var replayAPI = BackendAPIClient(demoOnly: true)
    private var remoteURL = "https://drivesave.nuhylabs.com"
    private var state = BackendLocalState()
    private let fileURL: URL
    init(storageURL: URL? = nil) {
        fileURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DriveSave/backend-state\(credentialSuffix).json")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) { state = try JSONDecoder().decode(BackendLocalState.self, from: Data(contentsOf: fileURL)) }
            vehicle = state.vehicle; vehicleConfirmed = state.vehicleConfirmed
        } catch { errorMessage = "Saved API settings could not be read. \(error.localizedDescription)" }
    }
    func restoreAccount() async {
        guard isRestoringAccount else { return }
        await connect(remote: state.remoteMode ?? true, baseURL: state.baseURL ?? remoteURL)
        isRestoringAccount = false
        if identity != nil { await refreshLeague(); await refreshMyVehicle() }
    }
    var connectionURL: String { remoteURL }
    func resetAccount() async {
        await run {
            try await api.resetLocalAccount()
            if !isRemote { state.offlineLeague = nil; try persist() }
            clearProgress(); identity = nil; vehicle = nil; vehicleConfirmed = false; league = nil; standings = []; notice = nil
        }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic, .completeFileProtection])
        revision += 1
    }
    private func key(_ id: UUID) -> String { "\(isRemote ? remoteURL : "mock"):\(id.uuidString)" }
    private func run(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; consumerErrorMessage = nil
        defer { isBusy = false }
        do { try await operation() }
        catch let error as URLError { errorMessage = "Network unavailable or interrupted. Check your connection and retry. Saved trips remain on this device. \(error.localizedDescription)" }
        catch let error as BackendError { errorMessage = error.localizedDescription; consumerErrorMessage = error.consumerMessage }
        catch { errorMessage = error.localizedDescription }
        do {
            let updated = try await api.identity()
            if identity != updated { clearProgress(); identity = updated; try restoreLocalVehicle(); league = nil; standings = [] }
            if let message = await api.takeResetNotice() { notice = message; recoveryMessage = message; league = nil; standings = [] }
        } catch { errorMessage = error.localizedDescription }
    }
    func connect(remote: Bool, baseURL: String, client: BackendAPIClient? = nil) async {
        await run {
            let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !remote || (url?.scheme == "https" && url?.host != nil && url?.user == nil && url?.password == nil && url?.query == nil && url?.fragment == nil) else { throw BackendError.invalidInput("Enter a valid HTTPS API base URL.") }
            api = client ?? BackendAPIClient(mode: remote ? .remote(url!) : .mock, mockLeague: remote ? nil : state.offlineLeague, credentialStore: KeychainCredentialStore(account: baseURL + credentialSuffix + (remote ? "" : "#offline-mock")))
            replayAPI = BackendAPIClient(mode: remote ? .remote(url!) : .mock, demoOnly: true, credentialStore: KeychainCredentialStore(account: baseURL + credentialSuffix + (remote ? "" : "#offline-mock") + "#isolated-replay"))
            remoteURL = baseURL
            clearProgress(); isRemote = remote; identity = nil; league = nil; standings = []
            notice = remote ? "Remote API selected. Register or restore your saved Keychain session before uploading." : "Offline mock API selected. Nothing is sent to the server."
            identity = try await api.identity()
            try restoreLocalVehicle()
            state.remoteMode = remote; state.baseURL = baseURL; try persist()
        }
    }
    func register(nickname: String, demoAccount: Bool) async {
        await run { clearProgress(); identity = try await api.register(nickname: nickname, demoAccount: demoAccount); try restoreLocalVehicle(); league = nil; standings = []; notice = isRemote ? "Registered. Credentials saved securely in Keychain." : "Offline mock user registered. No network request was made." }
    }
    func selectVehicle(json: String, confirmed: Bool) {
        do {
            let data = Data(json.utf8)
            let row = try APIJSON.decoder().decode(VehicleRow.self, from: data)
            guard !row.isEmpty, row.count <= 200, data.count < 20_000 else { throw BackendError.invalidInput("EPA row must contain 1–200 fields and be under 20 KB.") }
            guard let owner = identity?.userID else { throw BackendError.invalidInput("Complete welcome registration first.") }
            try storeVehicle(row, confirmed: confirmed, synced: false, owner: owner)
            notice = "Vehicle row saved locally with its original field names."
        } catch { errorMessage = error.localizedDescription }
    }
    func updateVehicle() async {
        await run {
            guard identity != nil, let vehicle else { throw BackendError.invalidInput("Register and select an EPA vehicle row first.") }
            let saved = try await api.putVehicle(vehicle)
            guard let owner = try await api.identity()?.userID else { throw BackendError.expiredSession }
            try storeVehicle(saved, confirmed: vehicleConfirmed, synced: true, owner: owner)
            notice = "Vehicle profile uploaded. Future trips use this vehicle snapshot."
        }
    }
    func fetchVehicle() async {
        await run {
            let row = try await api.getVehicle()
            guard let owner = try await api.identity()?.userID else { throw BackendError.expiredSession }
            try storeVehicle(row, confirmed: false, synced: true, owner: owner)
            notice = "Server vehicle loaded. Confirm it matches your vehicle before a real upload."
        }
    }
    // Catalog requests are public and keep their loading/error state in the picker.
    func vehicleMakes() async throws -> [String] { try await api.vehicleMakes() }
    func vehicleModels(make: String) async throws -> [String] { try await api.vehicleModels(make: make) }
    func vehicleYears(make: String, model: String) async throws -> [Int] { try await api.vehicleYears(make: make, model: model) }
    func vehicleDetails(_ choice: VehicleChoice) async throws -> CatalogVehicle { try await api.vehicleDetails(choice) }

    func saveCatalogVehicle(_ selected: CatalogVehicle) async -> Bool {
        var savedSuccessfully = false
        await run {
            guard identity != nil else { throw BackendError.expiredSession }
            let row = try await api.putVehicle(selected.row)
            let saved = try CatalogVehicle(row: row)
            guard saved.choice == selected.choice, let owner = try await api.identity()?.userID else { throw BackendError.invalidResponse }
            try storeVehicle(row, confirmed: true, synced: true, owner: owner)
            notice = isRemote ? "Vehicle saved." : "Vehicle saved in offline demo only."
            savedSuccessfully = true
        }
        return savedSuccessfully
    }

    func refreshMyVehicle() async {
        guard identity != nil, isRemote else { return }
        // Advanced imports are drafts until explicitly uploaded; don't replace a user's pending edit.
        if let owner = identity?.userID, state.vehicleSelections?[key(owner)]?.synced == false { return }
        await run {
            guard let owner = identity?.userID else { return }
            do {
                let row = try await api.getVehicle()
                let currentOwner = try await api.identity()?.userID ?? owner
                try storeVehicle(row, confirmed: (try? CatalogVehicle(row: row)) != nil, synced: true, owner: currentOwner)
            } catch BackendError.server(404, let body) where body?.code == "vehicle_not_set" {
                try storeVehicle(nil, confirmed: false, synced: true, owner: try await api.identity()?.userID ?? owner)
            }
        }
    }

    var canTestCalculation: Bool {
        guard isRemote, let owner = identity?.userID, vehicle != nil else { return false }
        return state.vehicleSelections?[key(owner)]?.synced == true
    }
    func calculationService() throws -> TestCalculationService {
        guard canTestCalculation, let driverID = identity?.userID, let url = URL(string: remoteURL) else {
            throw BackendError.invalidInput("Save your vehicle to the online account before testing a calculation.")
        }
        let isolated = BackendAPIClient(mode: .remote(url), demoOnly: true,
            credentialStore: KeychainCredentialStore(account: remoteURL + credentialSuffix + "#calculation-demo-" + driverID.uuidString))
        return TestCalculationService(api: isolated, driverID: driverID)
    }

    private func restoreLocalVehicle() throws {
        // Migrate the legacy single-vehicle cache only into the currently saved account/mode.
        if state.vehicleSelections == nil {
            var selections: [String: SavedVehicleSelection] = [:]
            if let owner = identity?.userID, let row = state.vehicle,
               (state.remoteMode ?? true) == isRemote, (state.baseURL ?? remoteURL) == remoteURL {
                selections[key(owner)] = .init(row: row, confirmed: state.vehicleConfirmed, synced: false)
            }
            state.vehicleSelections = selections
            state.vehicle = nil; state.vehicleConfirmed = false
            try persist()
        }
        let saved = identity.flatMap { state.vehicleSelections?[key($0.userID)] }
        vehicle = saved?.row; vehicleConfirmed = saved?.confirmed ?? false
    }

    private func storeVehicle(_ row: VehicleRow?, confirmed: Bool, synced: Bool, owner: UUID) throws {
        let previous = state
        if state.vehicleSelections == nil { state.vehicleSelections = [:] }
        state.vehicleSelections?[key(owner)] = row.map { .init(row: $0, confirmed: confirmed, synced: synced) }
        do { try persist() } catch { state = previous; throw error }
        if vehicle != row { clearProgress() }
        vehicle = row; vehicleConfirmed = confirmed
    }

    func receipt(for trip: Trip) -> APIReceipt? {
        _ = revision
        guard let id = trip.clientTripID, let record = state.uploads[key(id)], record.mock == !isRemote else { return nil }
        if !record.payload.is_demo && record.owner != identity?.userID { return nil }
        return record.receipt
    }
    var replayReceipt: APIReceipt? {
        _ = revision
        guard let replay = state.replay, let record = state.uploads[key(replay.client_trip_id)] else { return nil }
        if !record.payload.is_demo && record.owner != identity?.userID { return nil }
        return record.receipt
    }
    private var recordingAccountScope: String { isRemote ? remoteURL : "mock" }
    func recordingContext() -> RecordingContext? {
        guard let owner = identity?.userID else { return nil }
        return RecordingContext(ownerID: owner, accountScope: recordingAccountScope, vehicle: vehicle, vehicleConfirmed: vehicleConfirmed)
    }
    func insufficientReason(for trip: Trip) -> String? {
        _ = revision
        if let id = trip.clientTripID, let record = state.uploads[key(id)],
           record.mock == !isRemote, record.payload.is_demo || record.owner == identity?.userID,
           let reason = record.insufficientReason { return reason }
        if let reason = TripUploadBuilder.scoringIssue(for: trip) { return reason }
        do { _ = try TripUploadBuilder.payload(for: trip); return nil }
        catch { return error.localizedDescription }
    }
    private func validateRecordingContext(_ trip: Trip) throws -> RecordingContext {
        guard let context = trip.recordingContext else {
            throw BackendError.invalidInput("This older recording has no recording-start account and vehicle snapshot. Keep it locally for inspection; record a new trip to upload.")
        }
        try context.validate(ownerID: identity?.userID, accountScope: recordingAccountScope)
        guard let row = context.vehicle, context.vehicleConfirmed else {
            throw BackendError.invalidInput("No confirmed vehicle was selected when this recording began. Select My Vehicle before your next drive.")
        }
        guard let catalog = try? CatalogVehicle(row: row), catalog.supportsFuelModel else {
            throw BackendError.invalidInput("The vehicle selected when recording began does not support fuel estimates.")
        }
        return context
    }
    private func prepareUpload(_ trip: Trip) throws -> (APITripPayload, RecordingContext?) {
        // Use exactly the same order for UI diagnostics and the real upload gate.
        let context = trip.source == .measured ? try validateRecordingContext(trip) : nil
        if let reason = TripUploadBuilder.scoringIssue(for: trip) { throw BackendError.invalidInput(reason) }
        return (try TripUploadBuilder.payload(for: trip), context)
    }
    func unsupportedReason(for trip: Trip) -> String? {
        do { _ = try prepareUpload(trip); return nil }
        catch { return error.localizedDescription }
    }
    private func traceKey(for trip: Trip) -> String? {
        identity.map { key(trip.clientTripID ?? trip.id) + ":" + $0.userID.uuidString }
    }
    private func updateTrace(_ traceKey: String?, stage: TripUploadTrace.Stage? = nil, post: Bool = false, failure: Error? = nil) throws {
        guard let traceKey, var trace = state.uploadTraces?[traceKey] else { return }
        if let stage { trace.stage = stage }
        if post { trace.postAttemptedAt = Date(); trace.postAttemptCount += 1 }
        if let failure {
            if case BackendError.server(let status, let body) = failure {
                trace.lastError = "HTTP \(status) [\(body?.code ?? "unknown")]: \(failure.localizedDescription)"
            } else { trace.lastError = failure.localizedDescription }
        }
        state.uploadTraces?[traceKey] = trace
        try persist()
    }
    func uploadDiagnostics(for trip: Trip) -> RecordingUploadDiagnostics {
        _ = revision
        let cached = trip.clientTripID.flatMap { state.uploads[key($0)] }
        let record = cached.flatMap { $0.mock == !isRemote && ($0.payload.is_demo || $0.owner == identity?.userID) ? $0 : nil }
        let trace = traceKey(for: trip).flatMap { state.uploadTraces?[$0] }
        return RecordingUploadDiagnostics(preflightFailure: unsupportedReason(for: trip), trace: trace,
            serverTripID: record?.serverTripID, hasReceipt: record?.receipt != nil,
            serverReason: record?.insufficientReason, legacyAttemptUnknown: record != nil && trace == nil && record?.serverTripID == nil, isRemote: isRemote)
    }
    func upload(trip: Trip) async {
        await run {
            let traceKey = traceKey(for: trip)
            if let traceKey {
                var trace = state.uploadTraces?[traceKey] ?? TripUploadTrace(requestedAt: Date())
                trace.stage = .preflight; trace.lastError = nil
                if state.uploadTraces == nil { state.uploadTraces = [:] }
                state.uploadTraces?[traceKey] = trace
            }
            do {
                if traceKey != nil { try persist() }
                let (payload, context) = try prepareUpload(trip)
                try await submit(payload, recordingContext: context, traceKey: traceKey)
            } catch {
                try? updateTrace(traceKey, failure: error)
                throw error
            }
        }
        await refreshProgress()
    }
    func replayContractFixture() async {
        await run {
            if state.replay == nil {
                var payload = try BackendFixtures.load("sample-trip", as: APITripPayload.self)
                payload.client_trip_id = UUID(); payload.source = "replayed"; payload.is_demo = true
                state.replay = payload; try persist()
            }
            try await submit(state.replay!)
        }
    }
    private func submit(_ payload: APITripPayload, recordingContext: RecordingContext? = nil, traceKey: String? = nil) async throws {
        guard let identity else { throw BackendError.invalidInput("Complete welcome registration first.") }
        if !payload.is_demo {
            guard let recordingContext else { throw BackendError.invalidInput("Missing recording-start identity.") }
            try recordingContext.validate(ownerID: identity.userID, accountScope: recordingAccountScope)
        }
        let uploadKey = key(payload.client_trip_id)
        if state.uploads[uploadKey] == nil {
            guard let vehicle = payload.is_demo ? vehicle : recordingContext?.vehicle else { throw BackendError.invalidInput("Select a vehicle before recording.") }
            if !payload.is_demo, vehicle["supported"] == .bool(false) || (try? CatalogVehicle(row: vehicle))?.supportsFuelModel == false {
                throw BackendError.invalidInput("This vehicle is not supported for fuel estimates. Choose another vehicle in Profile → My Vehicle. Your trip remains saved locally.")
            }
            if !payload.is_demo && recordingContext?.vehicleConfirmed != true { throw BackendError.invalidInput("Confirm the selected EPA row matches your actual vehicle before uploading a real trip.") }
            state.uploads[uploadKey] = SavedUpload(payload: payload, vehicle: vehicle, owner: identity.userID, mock: !isRemote)
            try persist() // Freeze the UUID, full request, and vehicle before the first network attempt.
        }
        var record = state.uploads[uploadKey]!
        let uploadAPI = payload.is_demo ? replayAPI : api
        if try await uploadAPI.identity() == nil, payload.is_demo {
            _ = try await uploadAPI.register(nickname: String(identity.nickname.prefix(18)) + " Replay Demo", demoAccount: true)
        }
        let currentOwner = try await uploadAPI.identity()?.userID
        if record.owner != currentOwner {
            guard payload.is_demo else { throw BackendError.expiredSession }
            record.serverTripID = nil; record.receipt = nil
        }
        let expectedOwner = payload.is_demo ? nil : recordingContext?.ownerID
        if record.serverTripID == nil {
            try updateTrace(traceKey, stage: .vehicle)
            let result = try await uploadAPI.upload(record.payload, vehicle: record.vehicle, expectedOwnerID: expectedOwner, willPost: {
                try await self.updateTrace(traceKey, stage: .post, post: true)
            })
            record.serverTripID = result.trip_id
            record.owner = try await uploadAPI.identity()?.userID ?? identity.userID
            if let expectedOwner, record.owner != expectedOwner { throw BackendError.expiredSession }
            state.uploads[uploadKey] = record; try persist()
            notice = result.duplicate ? "Duplicate upload recognized (200). Fetching the original receipt." : "Trip accepted (201). Fetching receipt."
        }
        try updateTrace(traceKey, stage: .receipt)
        do {
            record.receipt = try await uploadAPI.receipt(tripID: record.serverTripID!, expectedOwnerID: expectedOwner)
            record.insufficientReason = nil
        } catch BackendError.server(let status, let body) where body?.code == "trip_not_scored" {
            let refusal = BackendError.server(status, body)
            record.insufficientReason = "HTTP \(status) [\(body?.code ?? "unknown")]: \(refusal.localizedDescription)"
            try updateTrace(traceKey, failure: refusal)
            state.uploads[uploadKey] = record; try persist()
            // Normal screens use a concise state; the exact response remains in Developer Mode.
            notice = "Insufficient recording data"
            return
        }
        state.uploads[uploadKey] = record; try persist()
        try updateTrace(traceKey, stage: .complete)
        if !isRemote { notice = "Offline mock receipt. No trip was sent to the server." }
        else if payload.is_demo { notice = "Demo replay uploaded under an isolated account that cannot join leagues in this app. Your driver account's rankings are unaffected." }
        if let reset = await uploadAPI.takeResetNotice() { notice = reset; recoveryMessage = reset }
    }
    /// Uses existing authenticated self-scoped leaderboard + private crew APIs.
    /// No token, join code, vehicle or trip is exported, and no account is created.
    func authenticatedLeagueSetup() async throws -> String {
        guard let owner = identity, isRemote else { throw BackendError.invalidInput("Use the existing online Htoo account to verify its league.") }
        let board = try await api.currentLeaderboard(expectedOwnerID: owner.userID) // Server resolves the authenticated caller's league.
        let current = try await api.league(id: board.crew_id, expectedOwnerID: owner.userID)
        guard identity == owner, current.members.contains(where: { $0.user_id == owner.userID && $0.nickname == owner.nickname }) else { throw BackendError.invalidResponse }
        return String(decoding: try APIJSON.encoder().encode([
            "owner_id": owner.userID.uuidString, "owner_nickname": owner.nickname,
            "league_id": current.crew_id.uuidString, "league_name": current.name,
            "verified_at": Date().ISO8601Format(), "verification": "authenticated self leaderboard and private league membership"
        ]), as: UTF8.self)
    }
    func fetchLeagueShowcase() async throws -> APILeaderboard {
        guard let owner = identity, let league else { throw BackendError.invalidInput("Sign in and refresh your existing league first.") }
        let result: APILeaderboard
        if isRemote {
            result = try await api.leagueShowcase()
        } else {
            // Explicit offline fixture only; never used as fallback for a remote error.
            let fixture = try BackendFixtures.load("league-showcase", as: APILeaderboard.self)
            var json = try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(fixture)) as! [String: Any]
            json["crew_id"] = league.crew_id.uuidString; json["crew_name"] = league.name; json["viewer_id"] = owner.userID.uuidString
            var rows = json["standings"] as! [[String: Any]]
            if let index = rows.firstIndex(where: { ($0["is_synthetic_demo"] as? Bool) == false }) {
                rows[index]["user_id"] = owner.userID.uuidString; rows[index]["nickname"] = owner.nickname
            }
            json["standings"] = rows
            result = try APIJSON.decoder().decode(APILeaderboard.self, from: JSONSerialization.data(withJSONObject: json))
        }
        guard identity == owner, result.crew_id == league.crew_id,
              result.ranking_metric == "weekly_avoidable_cost_usd", result.demo_preview == true,
              result.standings.contains(where: { $0.user_id == owner.userID }) else { throw BackendError.invalidResponse }
        return result
    }

    func createLeague(name: String) async {
        var createdSuccessfully = false
        await run {
            guard identity != nil else { throw BackendError.invalidInput("Complete welcome registration first.") }
            let created = try await api.createLeague(name: name)
            league = created; standings = []
            if !isRemote { state.offlineLeague = created }
            if let id = try await api.identity()?.userID { state.leagueByUser[key(id)] = created.crew_id; try persist() }
            notice = "League created. You compete individually; rankings require 4+ members."
            createdSuccessfully = true
        }
        if createdSuccessfully { await refreshLeague() }
    }
    func joinLeague(id: String, code: String) async {
        var joinedSuccessfully = false
        await run {
            guard identity != nil, let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw BackendError.invalidInput("Register and enter the league UUID plus invite code.") }
            let joined = try await api.joinLeague(id: uuid, code: code)
            league = joined; standings = []
            if let userID = try await api.identity()?.userID { state.leagueByUser[key(userID)] = joined.crew_id; try persist() }
            notice = "Joined league. The backend moves you out of any previous league."
            joinedSuccessfully = true
        }
        if joinedSuccessfully { await refreshLeague() }
    }
    func refreshLeague() async {
        await run {
            guard let userID = identity?.userID, let id = league?.crew_id ?? state.leagueByUser[key(userID)] else { return }
            let loaded: APILeague
            do { loaded = try await api.league(id: id) }
            catch let error as BackendError where error.isStalePrivateLeague {
                // Only this exact GET /crews/{id} refusal invalidates this account's cached ID.
                state.leagueByUser.removeValue(forKey: key(userID))
                league = nil; standings = []; leaderboardIsDemo = false
                try persist()
                notice = "Create or join a league."
                return
            }
            league = loaded
            if loaded.canRank {
                let board = try await api.costLeaderboard()
                guard board.crew_id == id else { throw BackendError.invalidResponse }
                var verified = loaded; verified.active = board.active; verified.member_count = board.member_count
                league = verified; leaderboardIsDemo = board.is_demo; leaderboardMetric = board.ranking_metric
                standings = verified.canRank ? board.standings : []
            } else { standings = [] }
        }
    }
}
