import Foundation

actor TestCalculationService {
    static let fixtureURL = URL(string: "https://raw.githubusercontent.com/RamboHtoo/drive-save/backend/fixtures/sample-trip.json")!
    private let api: BackendAPIClient
    private let driverID: UUID
    private let fixtureLoader: @Sendable () async throws -> Data
    init(api: BackendAPIClient, driverID: UUID, fixtureLoader: @escaping @Sendable () async throws -> Data = { try await downloadLatestFixture() }) {
        self.api = api; self.driverID = driverID; self.fixtureLoader = fixtureLoader
    }
    static func downloadLatestFixture(session: URLSession = .shared) async throws -> Data {
        var components = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "test", value: UUID().uuidString)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // No API authorization headers are ever sent to the public fixture host.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 1_000_000 else {
            throw BackendError.invalidInput("The latest backend sample could not be loaded. Retry when the sample is available; no offline fixture was submitted.")
        }
        return data
    }
    func prepare(clientTripID: UUID) async throws -> SyntheticCalculationAttempt {
        try await SyntheticCalculationAttempt(fixture: fixtureLoader(), clientTripID: clientTripID)
    }
    func upload(_ attempt: SyntheticCalculationAttempt, vehicle: VehicleRow) async throws -> UUID {
        try await api.ensureCalculationIdentity(driverID: driverID)
        // Reuses authenticated PUT-before-POST and the backend's idempotent trip endpoint.
        return try await api.uploadSyntheticFixture(attempt.body, vehicle: vehicle).trip_id
    }
    func receipt(tripID: UUID) async throws -> APIReceipt {
        let receipt = try await api.receipt(tripID: tripID)
        guard receipt.trip_id == tripID, receipt.is_demo else { throw BackendError.invalidResponse }
        return receipt
    }
}
