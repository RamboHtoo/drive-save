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
    /// Removes only this device's persisted copy. No network or server state is involved.
    func delete(id: UUID) throws {
        let trips = try load()
        guard trips.contains(where: { $0.id == id }) else { return }
        try save(trips.filter { $0.id != id })
    }
    func save(_ trips: [Trip]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(trips)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
