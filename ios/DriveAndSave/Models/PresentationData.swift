import Foundation
import Combine

/// A session-only display choice. It has no account, persistence, or API dependency.
@MainActor
final class PresentationState: ObservableObject {
    @Published var isEnabled = false
}

/// Display-only values deliberately cannot be passed to TripUploadBuilder or an API client.
/// No Trip, APITripPayload, receipt, vehicle record, account ID, or Codable conformance.
enum PresentationData {
    struct SampleTrip: Identifiable {
        let id: String
        let title: String
        let timeLabel: String
        let costCents: Int
        let distanceTenths: Int
        var cost: String { PresentationData.dollars(costCents) }
        var distance: String { String(format: "%.1f mi", Double(distanceTenths) / 10) }
    }
    struct Player: Identifiable {
        let name: String
        let costCents: Int
        var id: String { "sample-" + name.lowercased() }
        var cost: String { PresentationData.dollars(costCents) }
        var isPresenter: Bool { name == PresentationData.presenter }
    }
    static let presenter = "Htoo"
    static let vehicle = "2015 Audi A4"
    static let improvement = "18% less waste"
    static let trips: [SampleTrip] = [
        .init(id: "sample-1", title: "Morning commute", timeLabel: "Monday · morning", costCents: 12, distanceTenths: 72),
        .init(id: "sample-2", title: "Home from campus", timeLabel: "Monday · evening", costCents: 18, distanceTenths: 85),
        .init(id: "sample-3", title: "Coffee and errands", timeLabel: "Tuesday · afternoon", costCents: 9, distanceTenths: 46),
        .init(id: "sample-4", title: "Across town", timeLabel: "Wednesday · morning", costCents: 24, distanceTenths: 113),
        .init(id: "sample-5", title: "Campus commute", timeLabel: "Thursday · morning", costCents: 15, distanceTenths: 68),
        .init(id: "sample-6", title: "Evening drive", timeLabel: "Thursday · evening", costCents: 20, distanceTenths: 91),
        .init(id: "sample-7", title: "Grocery run", timeLabel: "Friday · afternoon", costCents: 11, distanceTenths: 54),
        .init(id: "sample-8", title: "Weekend outing", timeLabel: "Saturday · afternoon", costCents: 33, distanceTenths: 105)
    ]
    static var weeklyCostCents: Int { trips.reduce(0) { $0 + $1.costCents } }
    static var weeklyCost: String { dollars(weeklyCostCents) }
    static var weeklyDistance: String { String(format: "%.1f", Double(trips.reduce(0) { $0 + $1.distanceTenths }) / 10) }
    static var players: [Player] {
        [Player(name: presenter, costCents: weeklyCostCents),
         Player(name: "Alex", costCents: 185), Player(name: "Jordan", costCents: 240),
         Player(name: "Sam", costCents: 312), Player(name: "Taylor", costCents: 430),
         Player(name: "Casey", costCents: 575)].sorted {
            $0.costCents == $1.costCents ? $0.name < $1.name : $0.costCents < $1.costCents
        }
    }
    static func rank(of player: Player) -> Int {
        Set(players.filter { $0.costCents < player.costCents }.map(\.costCents)).count + 1
    }
    static var presenterRank: String { "#\(rank(of: players.first(where: \.isPresenter)!)) of \(players.count)" }
    static func dollars(_ cents: Int) -> String { String(format: "$%d.%02d", cents / 100, cents % 100) }
}
