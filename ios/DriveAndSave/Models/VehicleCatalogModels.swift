import Foundation

struct VehicleMakesResponse: Decodable { let makes: [String] }
struct VehicleModelsResponse: Decodable { let make: String; let models: [String] }
struct VehicleYearsResponse: Decodable { let make: String; let model: String; let years: [Int] }

struct VehicleChoice: Hashable {
    let make: String
    let model: String
    let year: Int
}

/// Render typed fields, but retain and upload the entire original object, including unknown keys.
struct CatalogVehicle: Codable, Equatable {
    struct Specifications: Decodable, Equatable {
        let fuel_type: String
        let vehicle_type: String?
        let engine_displacement_l: Double?
        let cylinders: Int?
        let rated_horsepower: Double?
        let transmission: String?
        let gears: Int?
        let drive: String?
        let test_weight_lb: Double?
    }
    struct MPG: Decodable, Equatable {
        let city: Double?
        let highway: Double?
        let combined: Double?
        let is_estimate: Bool
    }
    struct Parameter: Decodable, Equatable {
        let key: String; let value: Double; let unit: String; let method: String; let is_estimate: Bool
    }
    struct Source: Decodable, Equatable {
        let dataset: String; let test_vehicle_id: String?; let test_configuration: Int?; let configurations_tested: Int
    }
    struct Details: Decodable, Equatable {
        let vehicle_id: UUID
        let make: String
        let model: String
        let year: Int
        let supported: Bool
        let specs: Specifications
        let mpg: MPG
        let parameters: [Parameter]
        let flags: [String]
        let source: Source
    }
    let row: VehicleRow
    let details: Details
    var choice: VehicleChoice { .init(make: details.make, model: details.model, year: details.year) }
    var title: String { "\(details.year) \(details.make) \(details.model)" }
    var supportsFuelModel: Bool { details.supported && !details.parameters.isEmpty }
    init(row: VehicleRow) throws {
        self.row = row
        self.details = try APIJSON.decoder().decode(Details.self, from: APIJSON.encoder().encode(row))
    }
    init(from decoder: Decoder) throws { try self.init(row: VehicleRow(from: decoder)) }
    func encode(to encoder: Encoder) throws { try row.encode(to: encoder) }
}

struct SavedVehicleSelection: Codable {
    let row: VehicleRow
    let confirmed: Bool
    let synced: Bool
}

extension Dictionary where Key == String, Value == JSONValue {
    var vehicleTitle: String {
        [self["year"] ?? self["model_year"], self["make"], self["model"]]
            .compactMap { $0?.display }.joined(separator: " ")
    }
}
