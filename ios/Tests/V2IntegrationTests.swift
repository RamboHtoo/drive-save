import Foundation

/// Controlled timestamps only; no physical sensor accuracy or financial claims.
@main struct V2IntegrationTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw BackendError.invalidInput("FAIL: " + message) }
        checks += 1
    }
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func sample(_ t: Double, _ speed: Double? = 10, _ accuracy: Double? = 1) -> APISpeedSample {
            .init(ts: start.addingTimeInterval(t), sample_seq: Int(t * 100), speed_mps: speed, speed_accuracy_mps: accuracy)
        }
        func window(_ samples: [APISpeedSample], end: Double = 11) -> Bool {
            (try? GPSScoringWindow(samples: samples, startedAt: start, endedAt: start.addingTimeInterval(end))) != nil
        }
        try check(window([sample(0.625), sample(10.625)]), "asynchronous button edges accepted")
        try check(window([sample(3), sample(8)]), "exact three-second edges accepted")
        try check(!window([sample(3.01), sample(8)]), "leading edge beyond three seconds rejected")
        try check(!window([sample(1), sample(7.99)]), "trailing edge beyond three seconds rejected")
        try check(!window([sample(1, nil), sample(10)]), "missing speed is not an observation")
        try check(!window([sample(1, 10, 2.01), sample(10)]), "inaccurate speed is not an observation")
        try check(!window([sample(1, 53.65), sample(10)]), "overrange speed rejected")
        try check(!window([sample(1, 10, -1), sample(10)]), "unknown speed accuracy rejected")
        try check(!window([sample(1), sample(10), sample(-0.1, nil)]), "even unusable readings must remain inside session")
        try check(!window([sample(1), sample(10), sample(11.01)]), "post-stop readings rejected")
        try check(window([sample(1), sample(10)]), "detailed sparse coverage remains backend decision")
        try check(GPSScoringWindow.valid(sample(1, 0, 0)), "actual zero speed is valid")
        try check(GPSScoringWindow.valid(sample(1, 53.6448, 2)), "inclusive speed and accuracy limits")
        try check(GPSScoringWindow.freshSpeed(sample(1, 0), at: start.addingTimeInterval(4)) == 0, "fresh red-light stop supports monitoring")
        try check(GPSScoringWindow.freshSpeed(sample(1, 0), at: start.addingTimeInterval(4.01)) == nil, "stale stop never implies stationary")
        try check(GPSScoringWindow.freshSpeed(nil, at: start) == nil, "missing GPS stays unknown")
        try check(GPSScoringWindow.freshSpeed(sample(1), at: start) == nil, "future reading cannot establish current monitoring")
        var coverage = DetectorCoverage(startedUptime: 100)
        for i in 1...109 { coverage.observe(uptime: 100 + Double(i) / 10, eligible: i >= 7) }
        try check(coverage.complete(from: 100.625, through: 110.625), "real motion inside button edges covers observed GPS interval")
        try check(!coverage.complete(from: 100, through: 111), "button-edge coverage is never invented")
        var stop = DetectorCoverage(startedUptime: 0)
        for i in 0...100 {
            let t = Double(i) / 10
            stop.observe(uptime: t, eligible: GPSScoringWindow.freshSpeed(sample(t, 0), at: start.addingTimeInterval(t)) != nil)
        }
        try check(stop.complete(from: 0.1, through: 9.9), "continuous motion plus verified low speed stays complete")
        var missing = DetectorCoverage(startedUptime: 0)
        for i in 0...100 { missing.observe(uptime: Double(i) / 10, eligible: i != 50) }
        try check(!missing.complete(from: 0.1, through: 9.9), "missing GPS or calibration observation prevents complete interval")
        var gap = DetectorCoverage(startedUptime: 0)
        for t in [0.1, 1.0, 2.01, 3.0] { gap.observe(uptime: t) }
        try check(!gap.complete(from: 0.2, through: 2.9), "unexplained motion gap over one second rejected")
        coverage.invalidate("Mount angle changed")
        try check(!coverage.complete(from: 100.625, through: 110.625), "calibration loss remains a failure")
        stop.invalidate("App interrupted")
        try check(!stop.complete(from: 0.1, through: 9.9), "genuine interruption remains a failure")
        let old = try JSONDecoder().decode(DetectorCoverage.self, from: Data("{\"startedUptime\":0,\"firstObservation\":0,\"lastObservation\":10,\"failures\":[]}".utf8))
        try check(!old.complete(from: 1, through: 9), "legacy coverage without eligible runs remains unknown")
        var quality = GPSQualityTracker(startedAt: start)
        try check(!quality.summary(through: start.addingTimeInterval(12)).isPartial, "startup waiting is not permanently latched partial")
        for t in [0.6, 1.6, 2.6] { quality.observe(start.addingTimeInterval(t)) }
        try check(!quality.summary(through: start.addingTimeInterval(3)).isPartial, "continuous measurements recover from transient callback errors")
        try check(quality.summary(through: start.addingTimeInterval(6)).isPartial, "actual trailing GPS gap is partial")
        quality.observe(start.addingTimeInterval(7))
        try check(quality.summary(through: start.addingTimeInterval(7)).maximumGapSeconds > 4, "real interior gap retained after recovery")
        var late = GPSQualityTracker(startedAt: start)
        late.observe(start.addingTimeInterval(4))
        try check(late.summary(through: start.addingTimeInterval(5)).isPartial, "late first reliable fix honestly marks partial")
        var filter = GPSDistanceFilter()
        func point(_ t: Double, _ lat: Double, accuracy: Double = 4) -> GPSPoint {
            .init(timestamp: start.addingTimeInterval(t), latitude: lat, longitude: -77, accuracyMeters: accuracy, speedMetersPerSecond: nil)
        }
        _ = filter.accept(point(0, 40), startedAt: start, now: start)
        let moved = filter.accept(point(1, 40.0001), startedAt: start, now: start.addingTimeInterval(1))
        try check((moved?.addedMeters ?? 0) > 0, "valid position distance does not require an invented speed")
        let missingDistance = filter.accept(point(5, 40.0003), startedAt: start, now: start.addingTimeInterval(5))
        try check(missingDistance?.gap == true && missingDistance?.addedMeters == 0, "GPS gap never bridged with invented distance")
        try check(filter.accept(point(6, 40.0004, accuracy: 36), startedAt: start, now: start.addingTimeInterval(6)) == nil, "poor position accuracy excluded")
        try check(filter.accept(point(6, 40.0004), startedAt: start, now: start.addingTimeInterval(20)) == nil, "stale position excluded")
        print("\(checks) v2 GPS/motion integration checks passed")
    }
}
