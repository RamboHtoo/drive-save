import Foundation

/// Legacy local debug archive; it can contain GPS coordinates. Never upload this format.
/// Production requests use TripUploadBuilder and APITripPayload instead.
struct TripExportPayload: Codable {
    let id: UUID
    let activity: TripActivity
    let source: DataSource
    let startedAt: Date
    let endedAt: Date?
    let elapsedSeconds: Double
    let distanceMiles: Double?
    let measurementsIncomplete: Bool
    let excludedFromCrewScoring: Bool
    let recording: RecordingDetails?

    init(trip: Trip) {
        id = trip.id
        activity = trip.activity ?? .driving
        source = trip.source
        startedAt = trip.date
        endedAt = trip.recording?.endedAt
        elapsedSeconds = trip.recording?.elapsedSeconds ?? Double(trip.durationMinutes * 60)
        distanceMiles = trip.recording?.distanceAvailable == false ? nil : trip.distanceMiles
        measurementsIncomplete = trip.measurementsIncomplete
        excludedFromCrewScoring = !trip.isCrewCandidate
        recording = trip.recording
    }
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
