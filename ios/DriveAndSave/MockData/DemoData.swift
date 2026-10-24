import Foundation

enum DemoData {
    static let snapshot = AppSnapshot(trips: [
        trip("Campus → downtown", days: 0, miles: 8.4, minutes: 21, braking: 2, acceleration: 1, excess: 0.045),
        trip("The grocery run", days: 1, miles: 5.2, minutes: 16, braking: 0, acceleration: 1, excess: 0.015),
        trip("Weekend in the mountains", days: 2, miles: 42.6, minutes: 58, braking: 3, acceleration: 2, excess: 0.12),
        trip("Home → campus", days: 3, miles: 12.1, minutes: 27, braking: 1, acceleration: 0, excess: 0.025),
        trip("Coffee with the crew", days: 4, miles: 4.8, minutes: 14, braking: 1, acceleration: 2, excess: 0.055),
        trip("Library nights", days: 5, miles: 7.3, minutes: 19, braking: 2, acceleration: 2, excess: 0.08)
    ], crews: [
        Crew(id: UUID(), name: "Mint Condition", symbol: "leaf.fill", members: 5, reductionPercent: 24, isYourCrew: false),
        Crew(id: UUID(), name: "Nittany Cruisers", symbol: "bolt.shield.fill", members: 4, reductionPercent: 21, isYourCrew: true),
        Crew(id: UUID(), name: "Coast Collective", symbol: "wind", members: 6, reductionPercent: 17, isYourCrew: false),
        Crew(id: UUID(), name: "Happy Valley", symbol: "mountain.2.fill", members: 4, reductionPercent: 12, isYourCrew: false)
    ])
    private static func trip(_ title: String, days: Int, miles: Double, minutes: Int, braking: Int, acceleration: Int, excess: Double) -> Trip {
        Trip(id: UUID(), title: title, date: Calendar.current.date(byAdding: .day, value: -days, to: Date())!, distanceMiles: miles, durationMinutes: minutes, harshBraking: braking, rapidAcceleration: acceleration, mpg: 28, fuelPrice: 3.65, modeledExcessGallons: excess, source: .simulated)
    }
}
