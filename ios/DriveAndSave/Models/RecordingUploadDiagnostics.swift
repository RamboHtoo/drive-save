import Foundation

/// Local transport evidence only. Never sent to the scoring API; never contains credentials.
struct TripUploadTrace: Codable {
    enum Stage: String, Codable {
        case preflight = "Local preflight"
        case vehicle = "Vehicle PUT / account validation"
        case post = "POST /trips"
        case receipt = "GET trip receipt"
        case complete = "Receipt received"
    }
    let requestedAt: Date
    var stage: Stage = .preflight
    var postAttemptedAt: Date?
    var postAttemptCount = 0
    var lastError: String?
}

enum RecordingUploadState: String {
    case notEligible = "Not eligible for upload"
    case ready = "Ready to upload"
    case attempted = "Upload not confirmed"
    case accepted = "Uploaded · receipt pending"
    case notScored = "Uploaded but not scored"
    case scored = "Successfully scored"
    case offline = "Offline demo · no backend upload"
}

/// Read-only projection of saved sensor evidence and account-scoped transport evidence.
struct RecordingUploadDiagnostics {
    let state: RecordingUploadState
    let transport: String
    let preflightFailure: String?
    let trace: TripUploadTrace?
    let serverTripID: UUID?
    let serverReason: String?
    let legacyAttemptUnknown: Bool
    let isRemote: Bool

    init(preflightFailure: String?, trace: TripUploadTrace?, serverTripID: UUID?, hasReceipt: Bool,
         serverReason: String?, legacyAttemptUnknown: Bool = false, isRemote: Bool) {
        self.preflightFailure = preflightFailure; self.trace = trace; self.serverTripID = serverTripID
        self.serverReason = serverReason; self.legacyAttemptUnknown = legacyAttemptUnknown; self.isRemote = isRemote
        if !isRemote { state = preflightFailure == nil ? .offline : .notEligible; transport = "Offline mode · no backend POST" }
        else if serverTripID != nil {
            state = hasReceipt ? .scored : serverReason != nil ? .notScored : .accepted
            transport = "Server accepted"
        } else if trace?.postAttemptedAt != nil {
            state = preflightFailure == nil ? .attempted : .notEligible
            transport = "Upload attempted · server acceptance unconfirmed"
        } else {
            state = preflightFailure == nil ? .ready : .notEligible
            transport = legacyAttemptUnknown ? "Unknown legacy upload attempt · no acceptance recorded" : "Local-only · no POST attempt recorded in this account"
        }
    }

    func summary(for trip: Trip) -> String {
        var lines = ["Upload: \(transport)", "Receipt state: \(state.rawValue)",
                     "Preflight: \(preflightFailure ?? "Passed local checks; backend validation still required")",
                     "Connection: \(isRemote ? "Remote" : "Offline mock")",
                     "Client trip ID: \((trip.clientTripID ?? trip.id).uuidString)"]
        if let trace {
            lines += ["Estimate requested: \(trace.requestedAt.ISO8601Format())", "Last stage: \(trace.stage.rawValue)",
                      "POST attempts: \(trace.postAttemptCount)", "Last POST attempt: \(trace.postAttemptedAt?.ISO8601Format() ?? "None recorded")"]
            if let error = trace.lastError { lines.append("Last attempt failure: \(error)") }
        }
        if let serverTripID { lines.append("Server trip ID: \(serverTripID.uuidString)") }
        if let serverReason { lines.append("Server scoring refusal: \(serverReason)") }
        guard let recording = trip.recording else { return (lines + ["Recording evidence: unavailable (legacy)"]).joined(separator: "\n") }
        let all = recording.speedSamples ?? []
        let valid = all.filter { GPSScoringWindow.valid($0) && $0.ts.timeIntervalSince1970.isFinite }.sorted { $0.ts < $1.ts }
        func seconds(_ value: Double?) -> String { value.flatMap { $0.isFinite ? String(format: "%.3f s", $0) : nil } ?? "Unavailable" }
        let largestGPSGap = zip(valid, valid.dropFirst()).map { $1.ts.timeIntervalSince($0.ts) }.max()
        let sampleCount = recording.speedSamples == nil ? "Unknown (legacy; no speed sample archive)" : "\(all.count) total / \(valid.count) valid speed + accuracy"
        lines += ["GPS samples: \(sampleCount)",
                  "GPS leading edge: \(seconds(valid.first.map { $0.ts.timeIntervalSince(trip.date) }))",
                  "GPS trailing edge: \(seconds(valid.last.map { recording.endedAt.timeIntervalSince($0.ts) }))",
                  "Largest valid-speed GPS gap: \(seconds(largestGPSGap))",
                  "GPS observations outside button interval: \(all.filter { $0.ts < trip.date || $0.ts > recording.endedAt }.count)"]
        do { _ = try GPSScoringWindow(samples: all, startedAt: trip.date, endedAt: recording.endedAt) }
        catch { lines.append("GPS preflight failure: \(error.localizedDescription)") }
        let motion = recording.motionSamples.filter { $0.uptime.isFinite }.sorted { $0.uptime < $1.uptime }
        let largestMotionGap = zip(motion, motion.dropFirst()).map { $1.uptime - $0.uptime }.max()
        lines += ["Motion samples: \(motion.count); calibrated finite axes: \(motion.filter { $0.forwardAcceleration?.isFinite == true && $0.lateralAcceleration?.isFinite == true }.count)",
                  "Largest observed motion gap: \(seconds(largestMotionGap))",
                  "Calibration at end: \(recording.calibrationValidAtEnd.map { $0 ? "Valid" : "Invalid" } ?? "Unknown (legacy)")",
                  "Calibration setup: \(recording.calibrationDescription)",
                  "events_complete: \(recording.eventsComplete.map(String.init) ?? "Unknown (legacy)")",
                  "detector_version: \(recording.detectorVersion ?? "Unknown (legacy)")",
                  "Saved GPS-window motion coverage: \(recording.observedGPSWindowComplete.map(String.init) ?? "Unknown (legacy)")"]
        if let coverage = recording.detectorCoverage {
            lines.append("Motion uptime span: \(seconds(coverage.firstObservation)) to \(seconds(coverage.lastObservation))")
            if let runs = coverage.runs {
                let ineligible = runs.filter { !$0.eligible }
                lines.append("Ineligible motion runs: \(ineligible.count)")
                for reason in Set(ineligible.map { $0.reason ?? "Eligibility reason unavailable in this older recording" }).sorted() { lines.append("Monitoring history (includes startup): \(reason)") }
                if let first = valid.first, let last = valid.last {
                    let from = coverage.startedUptime + first.ts.timeIntervalSince(trip.date)
                    let through = coverage.startedUptime + last.ts.timeIntervalSince(trip.date)
                    if coverage.firstObservation.map({ $0 > from }) ?? true { lines.append("Coverage failure: no motion observation at/before GPS window start") }
                    if coverage.lastObservation.map({ $0 < through }) ?? true { lines.append("Coverage failure: no motion observation at/after GPS window end") }
                    if ineligible.contains(where: { $0.last >= from && $0.first <= through }) { lines.append("Coverage failure: ineligible monitoring overlaps GPS scoring window") }
                    if zip(runs, runs.dropFirst()).contains(where: { $1.first - $0.last > 1 && $0.last < through && $1.first > from }) { lines.append("Coverage failure: motion gap over 1 second intersects GPS scoring window") }
                }
            } else { lines.append("Motion eligibility evidence: unknown (legacy)") }
            lines += coverage.failures.map { "Detector interruption: " + $0 }
        } else { lines.append("Motion coverage evidence: unknown (legacy)") }
        lines += recording.interruptions.map { "Recording interruption: " + $0 }
        if let status = recording.detectionStatus { lines.append("Detector status at finish: \(status)") }
        if let quality = recording.gpsQuality {
            lines += ["Position GPS startup: \(seconds(quality.startupSeconds)); trailing: \(seconds(quality.trailingSeconds)); largest gap: \(seconds(quality.maximumGapSeconds))"]
        }
        return lines.joined(separator: "\n")
    }
}
