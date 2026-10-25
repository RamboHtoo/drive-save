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
    func putVehicle(_ row: VehicleRow) async throws -> VehicleRow {
        let data = try APIJSON.encoder().encode(row)
        guard (1...200).contains(row.count), data.count < 20_000 else { throw BackendError.invalidInput("Vehicle must be a complete JSON object with 1–200 fields under 20 KB.") }
        selectedVehicle = row
        if case .mock = mode { return row }
        return try APIJSON.decoder().decode(VehicleRow.self, from: await request("users/me/vehicle", method: "PUT", body: data))
    }
    func getVehicle() async throws -> VehicleRow {
        if case .mock = mode { guard let selectedVehicle else { throw BackendError.invalidInput("No vehicle selected.") }; return selectedVehicle }
        return try APIJSON.decoder().decode(VehicleRow.self, from: await request("users/me/vehicle", method: "GET"))
    }
    func upload(_ payload: APITripPayload, vehicle: VehicleRow) async throws -> APITripCreated {
        if case .remote = mode {
            guard payload.is_demo == demoOnly else { throw BackendError.invalidInput("Demo uploads require an isolated replay account; real uploads require the normal driver account.") }
        }
        try TripUploadBuilder.validate(payload)
        _ = try await putVehicle(vehicle) // Must precede pricing, including after auth recovery.
        let data = try APIJSON.encoder().encode(payload)
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
        return try APIJSON.decoder().decode(APITripCreated.self, from: await request("trips", method: "POST", body: data))
    }
    func receipt(tripID: UUID) async throws -> APIReceipt {
        if case .mock = mode {
            guard let found = mockUploads.values.first(where: { $0.1.trip_id == tripID }) else { throw BackendError.server(404, nil) }
            return found.2
        }
        return try APIJSON.decoder().decode(APIReceipt.self, from: await request("trips/\(tripID)/receipt", method: "GET"))
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
    func league(id: UUID) async throws -> APILeague {
        if case .mock = mode { guard let mockLeague else { throw BackendError.server(404, nil) }; return mockLeague }
        return try APIJSON.decoder().decode(APILeague.self, from: await request("crews/\(id)", method: "GET"))
    }
    func leaderboard(id: UUID) async throws -> APILeaderboard {
        if case .mock = mode { return APILeaderboard(crew_id: id, crew_name: mockLeague?.name ?? "Offline league", member_count: mockLeague?.member_count ?? 0, active: mockLeague?.canRank ?? false, period: "week", generated_at: Date(), standings: [], is_demo: true, is_estimate: true) }
        return try APIJSON.decoder().decode(APILeaderboard.self, from: await request("leaderboard", method: "GET"))
    }
    private func request(_ path: String, method: String, body: Data? = nil, protected: Bool = true, recover: Bool = true, query: [URLQueryItem] = []) async throws -> Data {
        guard case .remote(let baseURL) = mode, baseURL.scheme == "https" else { throw BackendError.invalidInput("Remote API requires HTTPS.") }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BackendError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if protected {
            _ = try identity()
            guard let credential else { throw BackendError.expiredSession }
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        if response.statusCode == 401 && protected {
            guard recover, let old = credential, old.isDemoAccount else { throw BackendError.expiredSession }
            _ = try await replaceCredential(nickname: old.nickname, demoAccount: true)
            resetNotice = "The server rejected the saved session and may have been reset. A new demo user was registered. Previous server trips and league membership may no longer exist; local history is safe."
            if let selectedVehicle { _ = try await self.request("users/me/vehicle", method: "PUT", body: APIJSON.encoder().encode(selectedVehicle), recover: false) }
            return try await self.request(path, method: method, body: body, protected: protected, recover: false, query: query)
        }
        guard (200...299).contains(response.statusCode) else { throw BackendError.server(response.statusCode, (try? APIJSON.decoder().decode(APIErrorEnvelope.self, from: data))?.error) }
        return data
    }
}
