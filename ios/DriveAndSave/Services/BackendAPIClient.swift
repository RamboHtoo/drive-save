import Foundation

/// Contract fetched from backend/docs/api.md and deployed OpenAPI. Tokens never leave this actor except in request headers.
actor BackendAPIClient {
    enum Mode { case mock; case remote(URL) }
    private let mode: Mode
    private let demoOnly: Bool
    private let session: URLSession
    private let credentialStore: any CredentialStore
    private var credential: StoredCredential?
    private var selectedVehicle: VehicleRow?
    private var resetNotice: String?
    private var mockLeague: APILeague?
    private var mockUploads: [UUID: (Data, APITripCreated, APIReceipt)] = [:]
    init(mode: Mode = .mock, demoOnly: Bool = false, session: URLSession = .shared, mockLeague: APILeague? = nil, credentialStore: (any CredentialStore)? = nil) {
        self.mockLeague = mockLeague
        self.mode = mode; self.demoOnly = demoOnly; self.session = session; self.credentialStore = credentialStore ?? KeychainCredentialStore(account: { if case .mock = mode { return "offline-mock" }; return "https://drivesave.nuhylabs.com" }())
    }
    func identity() throws -> APIIdentity? {
        if credential == nil { credential = try credentialStore.load() }
        return credential.map { APIIdentity(userID: $0.userID, nickname: $0.nickname) }
    }
    func takeResetNotice() -> String? { defer { resetNotice = nil }; return resetNotice }
    @discardableResult
    func register(nickname: String, demoAccount: Bool) async throws -> APIIdentity {
        guard try identity() == nil else { throw BackendError.invalidInput("An account already exists. Use Profile’s development account reset to register a different user.") }
        return try await replaceCredential(nickname: nickname, demoAccount: demoAccount)
    }
    func resetLocalAccount() throws {
        try credentialStore.clear()
        credential = nil; mockLeague = nil; selectedVehicle = nil; resetNotice = nil
    }
    private func replaceCredential(nickname: String, demoAccount: Bool) async throws -> APIIdentity {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...32).contains(name.count) else { throw BackendError.invalidInput("Nickname must have 1–32 characters.") }
        let user: APIUser
        if case .mock = mode { user = APIUser(user_id: UUID(), nickname: name, token: "offline-mock") }
        else { user = try APIJSON.decoder().decode(APIUser.self, from: await request("users", method: "POST", body: APIJSON.encoder().encode(["nickname": name]), protected: false)) }
        let stored = StoredCredential(userID: user.user_id, nickname: user.nickname, token: user.token, isDemoAccount: demoAccount)
        try credentialStore.save(stored)
        credential = stored; mockLeague = nil
        return APIIdentity(userID: user.user_id, nickname: user.nickname)
    }
    func vehicleMakes() async throws -> [String] {
        if case .mock = mode { return ["Mazda", "Tesla"] }
        return try APIJSON.decoder().decode(VehicleMakesResponse.self, from: await request("vehicles/makes", method: "GET", protected: false)).makes
    }
    func vehicleModels(make: String) async throws -> [String] {
        if case .mock = mode { return try mockCatalog().filter { $0.details.make == make }.map { $0.details.model } }
        return try APIJSON.decoder().decode(VehicleModelsResponse.self, from: await request("vehicles/models", method: "GET", protected: false, query: [.init(name: "make", value: make)])).models
    }
    func vehicleYears(make: String, model: String) async throws -> [Int] {
        if case .mock = mode { return try mockCatalog().filter { $0.details.make == make && $0.details.model == model }.map { $0.details.year }.sorted(by: >) }
        return try APIJSON.decoder().decode(VehicleYearsResponse.self, from: await request("vehicles/years", method: "GET", protected: false, query: [.init(name: "make", value: make), .init(name: "model", value: model)])).years
    }
    func vehicleDetails(_ choice: VehicleChoice) async throws -> CatalogVehicle {
        if case .mock = mode {
            guard let row = try mockCatalog().first(where: { $0.choice == choice }) else { throw BackendError.server(404, nil) }
            return row
        }
        let vehicle = try APIJSON.decoder().decode(CatalogVehicle.self, from: await request("vehicles/details", method: "GET", protected: false, query: [.init(name: "make", value: choice.make), .init(name: "model", value: choice.model), .init(name: "year", value: String(choice.year))]))
        guard vehicle.choice == choice else { throw BackendError.invalidResponse }
        return vehicle
    }
    private func mockCatalog() throws -> [CatalogVehicle] {
        try ["catalog-mazda5", "catalog-cybertruck"].map { try BackendFixtures.load($0, as: CatalogVehicle.self) }
    }
    func putVehicle(_ row: VehicleRow, expectedOwnerID: UUID? = nil) async throws -> VehicleRow {
        try checkOwner(expectedOwnerID)
        let data = try APIJSON.encoder().encode(row)
        guard (1...200).contains(row.count), data.count < 20_000 else { throw BackendError.invalidInput("Vehicle must be a complete JSON object with 1–200 fields under 20 KB.") }
        if case .mock = mode { selectedVehicle = row; return row }
        let saved = try APIJSON.decoder().decode(VehicleRow.self, from: await request("users/me/vehicle", method: "PUT", body: data, recover: expectedOwnerID == nil))
        try checkOwner(expectedOwnerID)
        selectedVehicle = saved
        return saved
    }
    func getVehicle() async throws -> VehicleRow {
        if case .mock = mode { guard let selectedVehicle else { throw BackendError.invalidInput("No vehicle selected.") }; return selectedVehicle }
        return try APIJSON.decoder().decode(VehicleRow.self, from: await request("users/me/vehicle", method: "GET"))
    }
    func upload(_ payload: APITripPayload, vehicle: VehicleRow, expectedOwnerID: UUID? = nil, willPost: (@Sendable () async throws -> Void)? = nil) async throws -> APITripCreated {
        if case .remote = mode {
            guard payload.is_demo == demoOnly else { throw BackendError.invalidInput("Demo uploads require an isolated replay account; real uploads require the normal driver account.") }
        }
        return try await uploadBody(payload, data: APIJSON.encoder().encode(payload), vehicle: vehicle, expectedOwnerID: expectedOwnerID, willPost: willPost)
    }
    /// Calculation tests may only run through an isolated demo client, never the driver's client.
    func ensureCalculationIdentity(driverID: UUID) async throws {
        guard demoOnly else { throw BackendError.invalidInput("Calculation tests require an isolated demo account.") }
        if try identity() == nil { _ = try await register(nickname: "Drive Save Calculation Demo", demoAccount: true) }
        guard let testIdentity = try identity(), testIdentity.userID != driverID else { throw BackendError.invalidInput("The test account must be different from your driver account.") }
    }
    func uploadSyntheticFixture(_ data: Data, vehicle: VehicleRow) async throws -> APITripCreated {
        let payload = try APIJSON.decoder().decode(APITripPayload.self, from: data)
        guard demoOnly, payload.source == "synthetic", payload.is_demo else {
            throw BackendError.invalidInput("Calculation tests must use an isolated account and a synthetic/demo fixture.")
        }
        return try await uploadBody(payload, data: data, vehicle: vehicle)
    }
    private func uploadBody(_ payload: APITripPayload, data: Data, vehicle: VehicleRow, expectedOwnerID: UUID? = nil, willPost: (@Sendable () async throws -> Void)? = nil) async throws -> APITripCreated {
        try TripUploadBuilder.validate(payload)
        if !payload.is_demo && vehicle["supported"] == .bool(false) {
            throw BackendError.invalidInput("This vehicle is not supported for fuel estimates. Your trip remains on this iPhone.")
        }
        guard payload.is_demo || expectedOwnerID != nil else {
            throw BackendError.invalidInput("Genuine uploads require the recording-start account identity.")
        }
        try checkOwner(expectedOwnerID)
        _ = try await putVehicle(vehicle, expectedOwnerID: expectedOwnerID)
        try checkOwner(expectedOwnerID) // Actor may reenter while the PUT is in flight.
        if case .mock = mode {
            if let previous = mockUploads[payload.client_trip_id] {
                guard previous.0 == data else { throw BackendError.server(409, nil) }
                return APITripCreated(trip_id: previous.1.trip_id, receipt_url: previous.1.receipt_url, duplicate: true)
            }
            let id = UUID()
            let result = APITripCreated(trip_id: id, receipt_url: "/trips/\(id)/receipt", duplicate: false)
            let events = payload.events.map { APIReceiptEvent(type: $0.type, ts: $0.ts, speed_before_mph: $0.speed_before_mph, speed_after_mph: $0.speed_after_mph, cost_usd: 1) }
            let receipt = APIReceipt(trip_id: id, distance_mi: payload.distance_mi, events: events, avoidable_cost_usd: Double(events.count), cost_model: "flat_per_event", assumptions: [.init(key: "cost_per_event", value: 1, unit: "USD/event", source_url: nil, as_of: "2026-10-24", is_estimate: true)], is_estimate: true, is_demo: true)
            mockUploads[payload.client_trip_id] = (data, result, receipt)
            return result
        }
        let created = try APIJSON.decoder().decode(APITripCreated.self, from: await request("trips", method: "POST", body: data, recover: expectedOwnerID == nil, willSend: willPost))
        try checkOwner(expectedOwnerID)
        return created
    }
    func progress() async throws -> APIProgress {
        guard let owner = try identity()?.userID else { throw BackendError.expiredSession }
        guard case .remote = mode else { throw BackendError.invalidInput("Progress requires Online mode.") }
        // A self-only URL must never be retried with a replacement user's identity.
        let progress = try APIJSON.decoder().decode(APIProgress.self, from: await request("users/\(owner)/progress", method: "GET", recover: false))
        guard progress.user_id == owner else { throw BackendError.invalidResponse }
        return progress
    }
    private func checkOwner(_ expected: UUID?) throws {
        if let expected, try identity()?.userID != expected { throw BackendError.expiredSession }
    }
    func receipt(tripID: UUID, expectedOwnerID: UUID? = nil) async throws -> APIReceipt {
        try checkOwner(expectedOwnerID)
        if case .mock = mode {
            guard let found = mockUploads.values.first(where: { $0.1.trip_id == tripID }) else { throw BackendError.server(404, nil) }
            return found.2
        }
        let receipt = try APIJSON.decoder().decode(APIReceipt.self, from: await request("trips/\(tripID)/receipt", method: "GET", recover: expectedOwnerID == nil))
        try checkOwner(expectedOwnerID)
        return receipt
    }
    func createLeague(name: String) async throws -> APILeague {
        guard !demoOnly else { throw BackendError.invalidInput("Isolated replay accounts cannot create or join competition leagues.") }
        guard (1...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw BackendError.invalidInput("League name must have 1–40 characters.") }
        if case .mock = mode {
            let id = try identity() ?? APIIdentity(userID: UUID(), nickname: "You")
            let league = APILeague(crew_id: UUID(), name: name, join_code: "DEMO42", members: [.init(user_id: id.userID, nickname: id.nickname, joined_at: Date())], member_count: 1, active: false, is_demo: true)
            mockLeague = league; return league
        }
        return try APIJSON.decoder().decode(APILeague.self, from: await request("crews", method: "POST", body: APIJSON.encoder().encode(["name": name])))
    }
    func joinLeague(id: UUID, code: String) async throws -> APILeague {
        guard !demoOnly else { throw BackendError.invalidInput("Isolated replay accounts cannot create or join competition leagues.") }
        if case .mock = mode {
            guard let league = mockLeague, league.crew_id == id, league.join_code == code.uppercased() else { throw BackendError.invalidInput("Offline mock supports the league created in this session only.") }
            return league
        }
        return try APIJSON.decoder().decode(APILeague.self, from: await request("crews/\(id)/join", method: "POST", body: APIJSON.encoder().encode(["join_code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()])))
    }
    func league(id: UUID, expectedOwnerID: UUID? = nil) async throws -> APILeague {
        try checkOwner(expectedOwnerID)
        if case .mock = mode { guard let mockLeague else { throw BackendError.server(404, nil) }; return mockLeague }
        let value = try APIJSON.decoder().decode(APILeague.self, from: await request("crews/\(id)", method: "GET", recover: expectedOwnerID == nil))
        try checkOwner(expectedOwnerID)
        return value
    }
    func leaderboard(id: UUID) async throws -> APILeaderboard {
        try await currentLeaderboard() // Compatibility argument; never sent as a guessed league ID.
    }
    func currentLeaderboard(expectedOwnerID: UUID? = nil) async throws -> APILeaderboard {
        try checkOwner(expectedOwnerID)
        if case .mock = mode { guard let id = mockLeague?.crew_id else { throw BackendError.server(404, nil) }; return APILeaderboard(crew_id: id, crew_name: mockLeague?.name ?? "Offline league", member_count: mockLeague?.member_count ?? 0, active: mockLeague?.canRank ?? false, period: "week", generated_at: Date(), standings: [], is_demo: true, is_estimate: true) }
        let value = try APIJSON.decoder().decode(APILeaderboard.self, from: await request("leaderboard", method: "GET", recover: expectedOwnerID == nil))
        try checkOwner(expectedOwnerID)
        return value
    }
    func costLeaderboard() async throws -> APILeaderboard {
        if case .mock = mode { return try await currentLeaderboard() }
        do {
            return try APIJSON.decoder().decode(APILeaderboard.self, from: await request("leaderboard/costs", method: "GET"))
        } catch BackendError.server(404, let body) where body == nil {
            // The currently deployed API may not have the reviewed extension yet.
            return try await currentLeaderboard()
        }
    }
    func leagueShowcase() async throws -> APILeaderboard {
        guard case .remote = mode else { throw BackendError.invalidInput("Use the explicitly labeled offline fixture in the view model.") }
        return try APIJSON.decoder().decode(APILeaderboard.self, from: await request("leaderboard/demo", method: "GET", recover: false))
    }

    private func request(_ path: String, method: String, body: Data? = nil, protected: Bool = true, recover: Bool = true, query: [URLQueryItem] = [], willSend: (@Sendable () async throws -> Void)? = nil) async throws -> Data {
        guard case .remote(let baseURL) = mode, baseURL.scheme == "https" else { throw BackendError.invalidInput("Remote API requires HTTPS.") }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw BackendError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if protected {
            _ = try identity()
            guard let credential else { throw BackendError.expiredSession }
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        }
        try await willSend?() // Persist attempt immediately before handing the prepared request to URLSession.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        if response.statusCode == 401 && protected {
            guard recover, let old = credential, old.isDemoAccount else { throw BackendError.expiredSession }
            _ = try await replaceCredential(nickname: old.nickname, demoAccount: true)
            resetNotice = "The server rejected the saved session and may have been reset. A new demo user was registered. Previous server trips and league membership may no longer exist; local history is safe."
            if let selectedVehicle { _ = try await self.request("users/me/vehicle", method: "PUT", body: APIJSON.encoder().encode(selectedVehicle), recover: false) }
            return try await self.request(path, method: method, body: body, protected: protected, recover: false, query: query, willSend: willSend)
        }
        guard (200...299).contains(response.statusCode) else { throw BackendError.server(response.statusCode, (try? APIJSON.decoder().decode(APIErrorEnvelope.self, from: data))?.error) }
        return data
    }
}
