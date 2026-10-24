import Foundation

enum DataSource: String, Codable { case simulated, measured }

struct Trip: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let date: Date
    let distanceMiles: Double
    let durationMinutes: Int
    let harshBraking: Int
    let rapidAcceleration: Int
    let mpg: Double
    let fuelPrice: Double
    let modeledExcessGallons: Double
    let source: DataSource
    var recording: RecordingDetails? = nil
    var sharpTurns: Int { recording?.events.filter { $0.kind == .sharpTurn }.count ?? 0 }
    var eventCount: Int { harshBraking + rapidAcceleration + sharpTurns }
    var hasEstimate: Bool { recording == nil && source == .simulated }
    var distanceLabel: String {
        if let recording, !recording.distanceAvailable { return "Unavailable" }
        return String(format: "%.2f mi", distanceMiles)
    }
    var durationLabel: String {
        guard let recording else { return "\(durationMinutes) min" }
        let seconds = Int(recording.elapsedSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var provenanceLabel: String { source == .measured ? "RECORDED · DEVICE SENSORS" : "SIMULATED · DEMO" }
    var baselineFuelCost: Double { distanceMiles / mpg * fuelPrice }
    var avoidableCost: Double { modeledExcessGallons * fuelPrice }
    var totalFuelCost: Double { baselineFuelCost + avoidableCost }
}

struct Crew: Identifiable, Codable {
    let id: UUID
    let name: String
    let symbol: String
    let members: Int
    let reductionPercent: Double
    let isYourCrew: Bool
}

struct AppSnapshot: Codable {
    let trips: [Trip]
    let crews: [Crew]
}
