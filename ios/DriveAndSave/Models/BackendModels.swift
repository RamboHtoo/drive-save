import Foundation

/// Exact backend wire keys; keep separate from persisted sensor models.
enum APIJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected timezone-aware ISO 8601 date")) }
            return date
        }
        return decoder
    }
}

indirect enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var display: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return d.rounded() == d ? String(format: "%.0f", d) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return String(data: (try? APIJSON.encoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
        }
    }
}
typealias VehicleRow = [String: JSONValue]

struct APIUser: Codable { let user_id: UUID; let nickname: String; let token: String }
/// GET /users/{user_id}/progress. Money is calculated exclusively by the server.
struct APIProgress: Codable, Equatable {
    let user_id: UUID
    let trips_counted: Int
    let baseline_trips_needed: Int
    let baseline_waste_per_mile_usd: Double?
    let current_waste_per_mile_usd: Double?
    let improvement_pct: Double?
    let est_savings_usd: Double
    let weekly: [APIWeeklyPoint]
    let is_estimate: Bool

    var hasSavings: Bool {
        trips_counted > 0 && baseline_trips_needed == 0 && baseline_waste_per_mile_usd != nil && current_waste_per_mile_usd != nil && improvement_pct != nil
    }
    var availability: String {
        if trips_counted == 0 { return "No scored trips yet." }
        if baseline_trips_needed > 0 { return "\(baseline_trips_needed) more scored \(baseline_trips_needed == 1 ? "trip" : "trips") to set your baseline." }
        if baseline_waste_per_mile_usd == 0 { return "No savings baseline available." }
        return "No weekly savings estimate yet."
    }
}
struct APIWeeklyPoint: Codable, Equatable {
    let week_start: String // A calendar date, not a timestamp.
    let miles: Double
    let waste_per_mile_usd: Double
}

extension Double {
    /// Preserve server precision: many receipts are less than one cent.
    var receiptDollars: String { formatted(.currency(code: "USD").precision(.fractionLength(2...4))) }
}

struct APIIdentity: Equatable { let userID: UUID; let nickname: String }
struct APISpeedSample: Codable, Hashable {
    let ts: Date
    let sample_seq: Int
    let speed_mps: Double?
    let speed_accuracy_mps: Double?
    enum CodingKeys: String, CodingKey { case ts, sample_seq, speed_mps, speed_accuracy_mps }
    init(ts: Date, sample_seq: Int, speed_mps: Double?, speed_accuracy_mps: Double?) {
        self.ts = ts; self.sample_seq = sample_seq
        self.speed_mps = speed_mps.flatMap { $0.isFinite && (0...53.6448).contains($0) ? $0 : nil }
        self.speed_accuracy_mps = speed_accuracy_mps.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ts: try c.decode(Date.self, forKey: .ts), sample_seq: try c.decode(Int.self, forKey: .sample_seq), speed_mps: try c.decodeIfPresent(Double.self, forKey: .speed_mps), speed_accuracy_mps: try c.decodeIfPresent(Double.self, forKey: .speed_accuracy_mps))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts); try c.encode(sample_seq, forKey: .sample_seq)
        if let speed_mps { try c.encode(speed_mps, forKey: .speed_mps) } else { try c.encodeNil(forKey: .speed_mps) }
        if let speed_accuracy_mps { try c.encode(speed_accuracy_mps, forKey: .speed_accuracy_mps) } else { try c.encodeNil(forKey: .speed_accuracy_mps) }
    }
}
struct APITripEvent: Codable, Hashable {
    let event_id: UUID
    let type: String
    let ts: Date
    let detector_version: String
    let peak_g: Double
    let speed_before_mph: Double
    let speed_after_mph: Double
    let duration_s: Double?
    let heading_change_deg: Double?
}
struct APITripPayload: Codable {
    var client_trip_id: UUID
    let started_at: Date
    let ended_at: Date
    let distance_mi: Double
    let avg_speed_mph: Double
    var source: String
    var is_demo: Bool
    let events: [APITripEvent]
    let speed_samples: [APISpeedSample]
    // Optional for backward compatibility. Never assert completeness for old recordings.
    var events_complete: Bool? = nil
    var detector_version: String? = nil
}
struct APITripCreated: Codable { let trip_id: UUID; let receipt_url: String; let duplicate: Bool }
struct APIReceiptEvent: Codable, Hashable {
    let type: String; let ts: Date; let speed_before_mph: Double; let speed_after_mph: Double; let cost_usd: Double
}
struct APIAssumption: Codable, Hashable {
    let key: String; let value: Double; let unit: String; let source_url: String?; let as_of: String; let is_estimate: Bool
}
struct APIReceipt: Codable, Hashable {
    var trip_id: UUID
    let distance_mi: Double
    let events: [APIReceiptEvent]
    let avoidable_cost_usd: Double
    let cost_model: String
    let assumptions: [APIAssumption]
    let is_estimate: Bool
    var is_demo: Bool
    var high_speed_cost_usd: Double? = nil
    var vehicle: String? = nil
    var label: String? = nil
    var notes: [String]? = nil
}
struct APILeagueMember: Codable, Identifiable { let user_id: UUID; let nickname: String; let joined_at: Date; var id: UUID { user_id } }
struct APILeague: Codable, Identifiable {
    let crew_id: UUID; let name: String; let join_code: String?; var members: [APILeagueMember]; var member_count: Int; var active: Bool; let is_demo: Bool
    var id: UUID { crew_id }
    var canRank: Bool { active && member_count >= 4 }
}
struct APIStanding: Codable, Identifiable {
    var state: String? = nil
    var availability: String {
        switch state {
        case "zero_baseline": return "No baseline waste"
        case "no_weekly_trips": return "No weekly trips"
        case "ready": return "Ready"
        default: return "Awaiting baseline"
        }
    }
    let rank: Int?
    let user_id: UUID
    let nickname: String
    let improvement_pct: Double?
    let est_savings_usd: Double
    let trips_counted: Int
    var id: UUID { user_id }
}
struct APILeaderboard: Codable {
    let crew_id: UUID
    let crew_name: String
    let member_count: Int
    let active: Bool
    let period: String
    let generated_at: Date
    let standings: [APIStanding]
    let is_demo: Bool
    let is_estimate: Bool
}
struct APIErrorEnvelope: Decodable {
    struct Body: Decodable {
        struct Detail: Decodable { let loc: [JSONValue]; let msg: String; let type: String }
        let code: String; let message: String; let details: [Detail]?
    }
    let error: Body
}
enum BackendError: LocalizedError {
    case server(Int, APIErrorEnvelope.Body?), invalidResponse, invalidInput(String), expiredSession, keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .server(let status, let body):
            let prefix = body?.code == "trip_not_scored" ? "Trip not scored. No estimate was produced. " : status == 409 ? "Trip conflict. The saved upload was not changed. " : status == 422 ? "Validation failed. " : ""
            let details = body?.details?.map { $0.loc.map(\.display).joined(separator: ".") + ": " + $0.msg }.joined(separator: "\n") ?? ""
            return prefix + (body?.message ?? "Server returned HTTP \(status).") + (details.isEmpty ? "" : "\n" + details)
        case .invalidResponse: return "The server returned an unexpected response."
        case .invalidInput(let text): return text
        case .expiredSession: return "Sign-in expired or the server was reset. Your saved identity was kept. To create a new test account, use the confirmed reset in Profile. Local trips are safe."
        case .keychain(let status):
            if status == -34018 { return "Secure sign-in requires app signing and Keychain entitlements. Build and run with signing enabled in Xcode." }
            return "The secure credential store is unavailable. Unlock your iPhone and retry."
        }
    }
}

enum BackendFixtures {
    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { throw BackendError.invalidInput("Bundled backend fixture missing: \(name)") }
        return try APIJSON.decoder().decode(type, from: Data(contentsOf: url))
    }
}
