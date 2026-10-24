import Foundation

struct TripStore {
    var fileURL: URL
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DriveSave", isDirectory: true).appendingPathComponent("trips.json")
    }
    func load() throws -> [Trip] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Trip].self, from: Data(contentsOf: fileURL))
    }
    func save(_ trips: [Trip]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(trips)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
