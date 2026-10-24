import Foundation

struct APIClient {
    enum Mode { case mock; case live(baseURL: URL) }
    enum APIError: LocalizedError {
        case invalidResponse, httpStatus(Int), insecureURL
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The server returned an invalid response."
            case .httpStatus(let code): return "Could not load your data (HTTP \(code))."
            case .insecureURL: return "The server URL must use HTTPS."
            }
        }
    }
    let mode: Mode
    var isMock: Bool { if case .mock = mode { return true }; return false }
    func fetchSnapshot() async throws -> AppSnapshot {
        switch mode {
        case .mock: return DemoData.snapshot
        case .live(let baseURL):
            guard baseURL.scheme == "https" else { throw APIError.insecureURL }
            let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("ios/snapshot"))
            guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { throw APIError.httpStatus(response.statusCode) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AppSnapshot.self, from: data)
        }
    }
}


/// Provisional upload contract. No automatic upload: routes contain sensitive location data.
struct TripUploadRequest: Codable {
    let schemaVersion: Int
    let trip: Trip
    init(trip: Trip) { schemaVersion = 1; self.trip = trip }
}

extension APIClient {
    /// Confirm this provisional endpoint and authentication with the backend team before enabling.
    func uploadTrip(_ trip: Trip) async throws {
        switch mode {
        case .mock: return
        case .live(let baseURL):
            guard baseURL.scheme == "https" else { throw APIError.insecureURL }
            var request = URLRequest(url: baseURL.appendingPathComponent("ios/trips"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(TripUploadRequest(trip: trip))
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { throw APIError.httpStatus(response.statusCode) }
        }
    }
}
