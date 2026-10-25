import Foundation

/// The backend fixture is authoritative. Only trip/event identities and demo provenance are changed.
struct SyntheticCalculationAttempt {
    let clientTripID: UUID
    let body: Data
    init(fixture: Data, clientTripID: UUID) throws {
        var object = try APIJSON.decoder().decode([String: JSONValue].self, from: fixture)
        guard !Self.containsCoordinates(.object(object)) else {
            throw BackendError.invalidInput("The backend sample contains coordinates. This test will not upload location data.")
        }
        object["client_trip_id"] = .string(clientTripID.uuidString)
        object["source"] = .string("synthetic")
        object["is_demo"] = .bool(true)
        // The deployed schema keys events globally by timestamp + event_id.
        // Give each test its own event identities without altering any observation.
        if case .array(let events) = object["events"] {
            object["events"] = .array(try events.map { value in
                guard case .object(var event) = value else { throw BackendError.invalidInput("The backend sample contains an invalid event.") }
                event["event_id"] = .string(UUID().uuidString)
                return .object(event)
            })
        }
        let data = try APIJSON.encoder().encode(object)
        let payload = try APIJSON.decoder().decode(APITripPayload.self, from: data)
        guard payload.events_complete == true, let version = payload.detector_version,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.events.allSatisfy({ $0.detector_version == version && $0.duration_s != nil }),
              !payload.speed_samples.isEmpty else {
            throw BackendError.invalidInput("The backend sample is missing complete detector metadata, event durations, or GPS samples. No replacement values were generated.")
        }
        try TripUploadBuilder.validate(payload)
        self.clientTripID = clientTripID; self.body = data
    }
    private static func containsCoordinates(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            return object.contains { ["latitude", "longitude", "lat", "lon", "coordinates"].contains($0.key.lowercased()) || containsCoordinates($0.value) }
        case .array(let values): return values.contains(where: containsCoordinates)
        default: return false
        }
    }
}
