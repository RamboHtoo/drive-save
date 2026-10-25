import Foundation

/// Display-only illustration. Never a Trip, APIReceipt, upload payload, or stored score.
struct SampleTripReceipt {
    struct Line: Identifiable {
        let label: String
        let cents: Int
        var id: String { label }
        var amount: String { String(format: "$%d.%02d", cents / 100, cents % 100) }
    }
    static let vehicle = "2012 Mazda MAZDA5"
    static let vehicleDetails: [(String, String)] = [
        ("Fuel", "Gasoline"), ("Engine", "2.5 L"), ("Cylinders", "4"),
        ("Power", "157 hp"), ("Transmission", "Semi-Automatic"),
        ("Drive", "Front-Wheel Drive"), ("Combined MPG", "25"),
        ("City MPG", "22.1"), ("Highway MPG", "29.7")
    ]
    // Fixed presentation examples, not inferred from this recording's sensor events.
    static let lines: [Line] = [
        .init(label: "Acceleration", cents: 16), .init(label: "Braking", cents: 11),
        .init(label: "Turning", cents: 0), .init(label: "High-speed driving", cents: 15)
    ]
    static var total: String { Line(label: "Total", cents: lines.reduce(0) { $0 + $1.cents }).amount }
    static func isAvailable(for trip: Trip) -> Bool {
        trip.source == .measured && trip.recording != nil && !trip.isWalkingTest
    }
    let recordedDate: Date
    let distance: String
    let duration: String
    let partialDistance: Bool
    let incompleteMeasurements: Bool
    init(trip: Trip) {
        recordedDate = trip.date
        distance = trip.distanceLabel
        duration = trip.durationLabel
        partialDistance = trip.recording?.distanceIsPartial == true
        incompleteMeasurements = trip.measurementsIncomplete
    }
}
