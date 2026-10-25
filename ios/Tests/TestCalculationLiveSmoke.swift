import Foundation

private final class CalculationSmokeCredentials: CredentialStore {
    var value: StoredCredential?
    func load() throws -> StoredCredential? { value }
    func save(_ credential: StoredCredential) throws { value = credential }
    func clear() throws { value = nil }
}
/// Opt-in. Only an isolated test identity is registered. No league endpoints are used.
@main struct TestCalculationLiveSmoke {
    static func main() async {
        do { try await run() }
        catch { print("FAIL: " + error.localizedDescription); exit(1) }
    }
    static func run() async throws {
        guard CommandLine.arguments.contains("--live") else { print("Skipped; --live creates an isolated demo calculation."); return }
        let store = CalculationSmokeCredentials()
        let api = BackendAPIClient(mode: .remote(URL(string: "https://drivesave.nuhylabs.com")!), demoOnly: true, credentialStore: store)
        print("Stage: fetching catalog")
        guard try await api.vehicleModels(make: "Toyota").contains("CAMRY"), try await api.vehicleYears(make: "Toyota", model: "CAMRY").contains(2020) else { throw BackendError.invalidResponse }
        let vehicle = try await api.vehicleDetails(.init(make: "Toyota", model: "CAMRY", year: 2020))
        let runner = TestCalculationService(api: api, driverID: UUID())
        print("Stage: downloading backend fixture")
        let attempt = try await runner.prepare(clientTripID: UUID())
        print("Stage: isolated account setup, vehicle PUT and synthetic upload")
        let id = try await runner.upload(attempt, vehicle: vehicle.row)
        guard try await api.getVehicle() == vehicle.row else { throw BackendError.invalidResponse }
        print("Stage: fetching receipt")
        let receipt = try await runner.receipt(tripID: id)
        print("PASS: live synthetic sample uploaded with complete detector metadata and GPS samples under an isolated demo account.")
        print("Selected: \(vehicle.title)")
        print("Server pricing vehicle: \(receipt.vehicle ?? "Not reported")")
        print("Server estimate: \(receipt.avoidable_cost_usd.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))")
        print("Model: \(receipt.cost_model)")
        print(receipt.label ?? "Estimate; accuracy not validated")
        print("Assumptions: \(receipt.assumptions.count); notes: \(receipt.notes?.count ?? 0); demo: \(receipt.is_demo)")
        guard receipt.vehicle?.localizedCaseInsensitiveContains("Toyota") == true,
              receipt.vehicle?.localizedCaseInsensitiveContains("CAMRY") == true,
              receipt.is_demo, !receipt.assumptions.isEmpty else { throw BackendError.invalidResponse }
        // Identical retry must return the same trip and receipt, not another calculation.
        let retriedID = try await runner.upload(attempt, vehicle: vehicle.row)
        guard retriedID == id else { throw BackendError.invalidResponse }
        print("PASS: identical retry returned the original trip. No real driver account or league was touched.")
    }
}
