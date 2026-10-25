import SwiftUI

@MainActor
final class VehiclePickerViewModel: ObservableObject {
    @Published private(set) var make: String?
    @Published private(set) var model: String?
    @Published private(set) var year: Int?
    @Published private(set) var vehicle: CatalogVehicle?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    var choice: VehicleChoice? {
        guard let make, let model, let year else { return nil }
        return .init(make: make, model: model, year: year)
    }
    func selectMake(_ value: String) {
        guard make != value else { return }
        make = value; model = nil; year = nil; vehicle = nil; isLoading = false; error = nil
    }
    func selectModel(_ value: String) {
        guard model != value else { return }
        model = value; year = nil; vehicle = nil; isLoading = false; error = nil
    }
    func selectYear(_ value: Int) {
        guard year != value else { return }
        year = value; vehicle = nil; isLoading = false; error = nil
    }
    func loadDetails(using fetch: (VehicleChoice) async throws -> CatalogVehicle) async {
        guard let requested = choice else { vehicle = nil; isLoading = false; error = nil; return }
        isLoading = true; error = nil; vehicle = nil
        defer { if choice == requested { isLoading = false } }
        do {
            let result = try await fetch(requested)
            try Task.checkCancellation()
            guard choice == requested else { return }
            vehicle = result
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, choice == requested else { return }
            self.error = error.localizedDescription
        }
    }
}
