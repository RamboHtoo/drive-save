import SwiftUI

@MainActor
final class TestCalculationViewModel: ObservableObject {
    let vehicle: VehicleRow
    private let service: TestCalculationService
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var receipt: APIReceipt?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notScored = false
    @Published private(set) var clientTripID: UUID?
    private var attempt: SyntheticCalculationAttempt?
    private var serverTripID: UUID?
    init(vehicle: VehicleRow, service: TestCalculationService) { self.vehicle = vehicle; self.service = service }
    func startIfNeeded() async { if clientTripID == nil { await newTest() } }
    func newTest() async {
        guard !isRunning else { return }
        clientTripID = UUID(); attempt = nil; serverTripID = nil; receipt = nil
        await execute()
    }
    func retry() async { await execute() }
    private func execute() async {
        guard !isRunning, let clientTripID else { return }
        isRunning = true; errorMessage = nil; notScored = false
        defer { isRunning = false }
        do {
            if attempt == nil {
                status = "Loading backend sample…"
                attempt = try await service.prepare(clientTripID: clientTripID)
            }
            try Task.checkCancellation()
            if serverTripID == nil, let attempt {
                status = "Submitting isolated demo test…"
                serverTripID = try await service.upload(attempt, vehicle: vehicle)
            }
            try Task.checkCancellation()
            if let serverTripID {
                status = "Fetching server receipt…"
                receipt = try await service.receipt(tripID: serverTripID)
            }
        } catch is CancellationError { errorMessage = "Test cancelled. Retry to continue this test." }
        catch BackendError.server(_, let body) where body?.code == "trip_not_scored" {
            notScored = true
            errorMessage = "The server could not price this sample. No fuel cost was calculated.\n\(body?.message ?? "trip_not_scored")"
        } catch {
            errorMessage = status.replacingOccurrences(of: "…", with: "") + " failed. " + error.localizedDescription
        }
    }
}
