import Foundation

// Legacy Home snapshot preview adapter. Authenticated contract traffic uses BackendAPIClient.
// The app keeps this client in mock mode; no backend snapshot endpoint is assumed.
struct APIClient {
    /// Supply confirmed endpoints, authentication headers, and contract adapters from the backend team.
    /// No URL paths, final request schema, or response schema are assumed here.
    struct RemoteConfiguration {
        let snapshotURL: URL
        let tripUploadURL: URL
        let snapshotMethod: String
        let tripUploadMethod: String
        var headers: [String: String] = [:]
        let encodeTrip: (Trip) throws -> Data
        let decodeSnapshot: (Data) throws -> AppSnapshot
    }
    enum Mode { case mock; case remote(RemoteConfiguration) }
    enum UploadResult { case mockPreview(Data), remoteAccepted }
    enum APIError: LocalizedError {
        case invalidResponse, httpStatus(Int), insecureURL
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The server returned an invalid response."
            case .httpStatus(let code): return "The server returned HTTP \(code)."
            case .insecureURL: return "The server URL must use HTTPS."
            }
        }
    }
    let mode: Mode
    var session: URLSession = .shared
    var isMock: Bool { if case .mock = mode { return true }; return false }

    func fetchSnapshot() async throws -> AppSnapshot {
        switch mode {
        case .mock: return DemoData.snapshot
        case .remote(let configuration):
            let data = try await perform(url: configuration.snapshotURL, method: configuration.snapshotMethod, configuration: configuration)
            return try configuration.decodeSnapshot(data)
        }
    }

    /// Never called automatically. Mock returns a local preview, not a successful network upload.
    func uploadTrip(_ trip: Trip) async throws -> UploadResult {
        switch mode {
        case .mock: return .mockPreview(try TripExportPayload(trip: trip).jsonData())
        case .remote(let configuration):
            let body = try configuration.encodeTrip(trip)
            _ = try await perform(url: configuration.tripUploadURL, method: configuration.tripUploadMethod, body: body, configuration: configuration)
            return .remoteAccepted
        }
    }

    private func perform(url: URL, method: String, body: Data? = nil, configuration: RemoteConfiguration) async throws -> Data {
        guard url.scheme == "https", url.host != nil else { throw APIError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (key, value) in configuration.headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw APIError.httpStatus(response.statusCode) }
        return data
    }
}
