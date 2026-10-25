import Foundation
import SwiftUI

private final class CatalogCredentials: CredentialStore {
    var credential: StoredCredential?
    func load() throws -> StoredCredential? { credential }
    func save(_ credential: StoredCredential) throws { self.credential = credential }
    func clear() throws { credential = nil }
}
private final class CatalogStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
                captured.httpBody = data
            }
            let (status, data) = try Self.handler(captured)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
@main struct VehicleCatalogTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw BackendError.invalidInput("FAILED: " + label) }
        checks += 1; print("PASS: " + label)
    }
    static func fixture(_ name: String) throws -> CatalogVehicle {
        try APIJSON.decoder().decode(CatalogVehicle.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/\(name).json")))
    }
    @MainActor static func main() async throws {
        let mazda = try fixture("catalog-mazda5"), tesla = try fixture("catalog-cybertruck")
        try check(mazda.title == "2012 Mazda MAZDA5" && mazda.details.mpg.combined == 25, "deployed catalog vehicle, MPG and specs decode")
        try check(tesla.details.mpg.combined == nil && !tesla.supportsFuelModel && tesla.details.parameters.isEmpty, "unsupported electric car has no invented MPG or eligibility")
        var extended = mazda.row
        extended["future_metadata"] = .object(["variants": .array([.object(["unknown": .number(42)])])])
        let complete = try CatalogVehicle(row: extended)
        let encoded = try APIJSON.encoder().encode(complete)
        try check(try APIJSON.decoder().decode(VehicleRow.self, from: encoded) == extended, "entire vehicle object including unknown nested fields survives encoding")
        try check(extended.vehicleTitle == mazda.title, "profile uses catalog year rather than only legacy model_year")
        let selection = SavedVehicleSelection(row: extended, confirmed: true, synced: true)
        let restored = try JSONDecoder().decode(SavedVehicleSelection.self, from: JSONEncoder().encode(selection))
        try check(restored.row == extended && restored.confirmed && restored.synced, "saved catalog snapshot round-trips without losing parameters or source")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogStub.self]
        let credentials = CatalogCredentials()
        credentials.credential = StoredCredential(userID: UUID(), nickname: "Catalog test", token: "test-only", isDemoAccount: false)
        let client = BackendAPIClient(mode: .remote(URL(string: "https://catalog.invalid")!), session: URLSession(configuration: config), credentialStore: credentials)
        var saved: VehicleRow?
        CatalogStub.handler = { request in
            let url = request.url!, path = url.path
            if path.hasPrefix("/vehicles/") { try check(request.value(forHTTPHeaderField: "Authorization") == nil, "catalog requests are public") }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if path == "/vehicles/makes" { return (200, Data(#"{"makes":["Mazda","Tesla"]}"#.utf8)) }
            if path == "/vehicles/models" {
                try check(items.first?.name == "make" && items.first?.value == "Lexus", "brand query uses exact contract name")
                return (200, Data(#"{"make":"Lexus","models":["RX 450h+ AWD"]}"#.utf8))
            }
            if path == "/vehicles/years" {
                try check(items.first(where: { $0.name == "model" })?.value == "RX / & # 450h+ AWD" && url.absoluteString.contains("%2B"), "special model characters and literal plus are safely URL encoded")
                return (200, Data(#"{"make":"Lexus","model":"RX / & # 450h+ AWD","years":[2026,2025]}"#.utf8))
            }
            if path == "/vehicles/details" {
                try check(Set(items.map(\.name)) == ["make", "model", "year"], "details uses only documented make, model and year fields")
                return (200, encoded)
            }
            try check(path == "/users/me/vehicle" && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only", "vehicle save/restore use protected existing route")
            if request.httpMethod == "PUT" {
                saved = try APIJSON.decoder().decode(VehicleRow.self, from: request.httpBody!)
                return (200, try APIJSON.encoder().encode(saved!))
            }
            return (200, try APIJSON.encoder().encode(saved!))
        }
        try check(try await client.vehicleMakes() == ["Mazda", "Tesla"], "makes response decoded")
        try check(try await client.vehicleModels(make: "Lexus") == ["RX 450h+ AWD"], "models response decoded")
        try check(try await client.vehicleYears(make: "Lexus", model: "RX / & # 450h+ AWD") == [2026,2025], "years preserve backend newest-first ordering")
        let fetched = try await client.vehicleDetails(mazda.choice)
        _ = try await client.putVehicle(fetched.row)
        try check(saved == extended, "PUT sends exact full details object, not a synthesized subset")
        try check(try await client.getVehicle() == extended, "server saved vehicle can be restored")
        CatalogStub.handler = { _ in (200, Data(#"{"makes":[]}"#.utf8)) }
        try check(try await client.vehicleMakes().isEmpty, "empty catalog remains empty")
        CatalogStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await client.vehicleMakes(); throw BackendError.invalidInput("Network failure hidden") }
        catch is URLError { try check(true, "network errors remain retryable and are not replaced by demo data") }
        CatalogStub.handler = { _ in (404, Data(#"{"error":{"code":"vehicle_not_found","message":"Not in catalog"}}"#.utf8)) }
        do { _ = try await client.vehicleDetails(mazda.choice); throw BackendError.invalidInput("404 hidden") }
        catch BackendError.server(404, let body) { try check(body?.code == "vehicle_not_found", "unknown vehicle details preserve backend error") }
        CatalogStub.handler = { _ in throw BackendError.invalidInput("Must not call network") }
        var trip = try APIJSON.decoder().decode(APITripPayload.self, from: Data(contentsOf: URL(fileURLWithPath: "DriveAndSave/MockData/Backend/sample-trip.json")))
        trip.source = "recorded"; trip.is_demo = false
        do { _ = try await client.upload(trip, vehicle: tesla.row); throw BackendError.invalidInput("Unsupported upload allowed") }
        catch BackendError.invalidInput(let message) { try check(message.contains("not supported"), "unsupported real fuel upload rejected before network access") }
        let picker = VehiclePickerViewModel()
        picker.selectMake("Mazda"); picker.selectModel("MAZDA5"); picker.selectYear(2012)
        await picker.loadDetails { _ in mazda }
        try check(picker.vehicle == mazda && !picker.isLoading, "picker loads full details before save")
        picker.selectYear(2012)
        try check(picker.vehicle == mazda, "reselecting the same year keeps loaded details and save available")
        picker.selectMake("Tesla")
        try check(picker.model == nil && picker.year == nil && picker.vehicle == nil, "changing brand clears model, year and old details")
        picker.selectModel("Cybertruck AWD"); picker.selectYear(2026)
        await picker.loadDetails { _ in tesla }
        picker.selectModel("Different model")
        try check(picker.year == nil && picker.vehicle == nil, "changing model clears year and old details")
        picker.selectMake("Mazda"); picker.selectModel("MAZDA5"); picker.selectYear(2012)
        await picker.loadDetails { _ in picker.selectMake("Tesla"); return mazda }
        try check(picker.vehicle == nil && !picker.isLoading, "stale detail response cannot restore a previous selection")
        picker.selectModel("Cybertruck AWD"); picker.selectYear(2026)
        await picker.loadDetails { _ in throw URLError(.timedOut) }
        try check(picker.error != nil && picker.vehicle == nil && !picker.isLoading, "detail error stops loading and leaves save unavailable")
        await picker.loadDetails { _ in tesla }
        try check(picker.error == nil && picker.vehicle == tesla, "retry successfully replaces error with real details")
        print("\(checks) vehicle catalog checks passed.")
    }
}
