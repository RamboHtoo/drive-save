import Foundation

enum DataSource: String, Codable { case simulated, measured }

enum TripActivity: String, Codable { case driving, walkingTest }

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
    // Optional for compatibility with existing saved trips; missing values mean driving.
    var activity: TripActivity? = nil
    var clientTripID: UUID? = nil
    var isWalkingTest: Bool { activity == .walkingTest }
    var displayTitle: String { isWalkingTest ? "Walking Test" : title }
    var isDriving: Bool { !isWalkingTest }
    // Candidate input only; final scoring eligibility must be agreed with analytics.
    var isCrewCandidate: Bool { isDriving && source == .measured && recording != nil }
    var measurementsIncomplete: Bool {
        guard let recording else { return false }
        return recording.measurementsIncomplete ?? (!recording.distanceAvailable || recording.distanceIsPartial || (!isWalkingTest && !recording.motionAvailable))
    }
    var eventCountLabel: String {
        if isWalkingTest { return "Disabled" }
        if let recording, !recording.motionAvailable { return "Unavailable" }
        return "\(eventCount)"
    }
    var sharpTurns: Int { recording?.events.filter { $0.kind == .sharpTurn }.count ?? 0 }
    var eventCount: Int { harshBraking + rapidAcceleration + sharpTurns }
    var hasEstimate: Bool { isDriving && recording == nil && source == .simulated }
    // Presentation only: a zero/unknown distance is not evidence of a completed drive.
    var hasUsableDistance: Bool {
        distanceMiles.isFinite && distanceMiles > 0 && recording?.distanceAvailable != false
    }
    var isIncompleteRecording: Bool { !hasEstimate && !hasUsableDistance }
    var distanceLabel: String {
        if !hasUsableDistance { return "Unavailable" }
        if distanceMiles < 0.01 { return "<0.01 mi" }
        return String(format: "%.2f mi", distanceMiles)
    }
    var durationLabel: String {
        guard let recording else { return "\(durationMinutes) min" }
        let seconds = Int(recording.elapsedSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var provenanceLabel: String { if isWalkingTest { return source == .simulated ? "Walking Test · SIMULATED GPS" : "Walking Test · DEVICE GPS" }; return source == .measured ? "RECORDED · DEVICE SENSORS" : "SIMULATED · DEMO" }
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


extension Array where Element == Trip {
    var drivingOnly: [Trip] { filter(\.isDriving) }
    var crewCandidates: [Trip] { filter(\.isCrewCandidate) }
}
