import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    @Published private(set) var crews: [Crew] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private let store = TripStore()
    private var localTrips: [Trip] = []
    let client: APIClient
    init(client: APIClient = APIClient(mode: .mock)) { self.client = client }
    var drivingTrips: [Trip] { trips.drivingOnly }
    var crewCandidateTrips: [Trip] { trips.crewCandidates }
    var estimatedTrips: [Trip] { trips.filter { $0.hasEstimate } }
    var avoidableCost: Double { estimatedTrips.reduce(0) { $0 + $1.avoidableCost } }
    var miles: Double { estimatedTrips.reduce(0) { $0 + $1.distanceMiles } }
    private func merge(_ remote: [Trip], _ local: [Trip]) -> [Trip] {
        let localIDs = Set(local.map(\.id))
        return (remote.filter { !localIDs.contains($0.id) } + local).sorted { $0.date > $1.date }
    }
    func save(_ trip: Trip) throws {
        var updated = try store.load().filter { $0.id != trip.id }
        updated.insert(trip, at: 0)
        try store.save(updated)
        localTrips = updated
        trips = merge(trips.filter { $0.id != trip.id }, updated)
    }
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            localTrips = try store.load()
            trips = merge(trips, localTrips)
            let snapshot = try await client.fetchSnapshot()
            trips = merge(snapshot.trips, localTrips)
            crews = snapshot.crews.sorted { $0.reductionPercent > $1.reductionPercent }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
