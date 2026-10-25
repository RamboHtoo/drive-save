import Foundation

private final class VehicleSmokeCredentials: CredentialStore {
    private var value: StoredCredential?
    func load() throws -> StoredCredential? { value }
    func save(_ credential: StoredCredential) throws { value = credential }
    func clear() throws { value = nil }
}
/// Opt-in: creates one dedicated test user and saves a catalog vehicle; no trips or league changes.
@main struct VehicleCatalogLiveSmoke {
    static func main() async throws {
        guard CommandLine.arguments.contains("--live") else { print("Skipped. Pass --live to use a dedicated test account."); return }
        let store = VehicleSmokeCredentials()
        let api = BackendAPIClient(mode: .remote(URL(string: "https://drivesave.nuhylabs.com")!), credentialStore: store)
        guard try await api.vehicleMakes().contains("Mazda"),
              try await api.vehicleModels(make: "Mazda").contains("MAZDA5"),
              try await api.vehicleYears(make: "Mazda", model: "MAZDA5").contains(2012) else { throw BackendError.invalidResponse }
        let details = try await api.vehicleDetails(.init(make: "Mazda", model: "MAZDA5", year: 2012))
        _ = try await api.register(nickname: "iOS Vehicle Test " + String(UUID().uuidString.prefix(6)), demoAccount: true)
        let saved = try await api.putVehicle(details.row)
        guard saved == details.row else { throw BackendError.invalidResponse }
        let reopened = BackendAPIClient(mode: .remote(URL(string: "https://drivesave.nuhylabs.com")!), credentialStore: store)
        guard try await reopened.getVehicle() == details.row else { throw BackendError.invalidResponse }
        print("PASS: live brand/model/year/details, dedicated test-account PUT, and restored server vehicle. No trips or league changes.")
    }
}
