import Foundation
import CoreMotion
import CoreLocation
import SwiftUI

@MainActor
final class TripRecordingService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    enum Mode: String, CaseIterable { case device, walking, simulator }
    @Published private(set) var isRecording = false
    @Published private(set) var isCalibrated = false
    @Published private(set) var calibrationProgress = 0.0
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var distanceMiles = 0.0
    @Published private(set) var events: [DrivingEvent] = []
    @Published private(set) var latestMotion: MotionSample?
    @Published private(set) var locationStatus = "Location not requested"
    @Published private(set) var motionStatus = "Motion not started"
    @Published private(set) var calibrationStatus = "Mount flat, with the top edge facing the front of the vehicle."
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var distanceAvailable = false
    @Published private(set) var interruption: String?
    @Published private(set) var mode: Mode = .device
    @Published private(set) var gpsAccuracyMeters: Double?
    @Published private(set) var orientationChanged = false
    let configuration: DetectionConfiguration
    private let motion = CMMotionManager()
    private let location = CLLocationManager()
    private var timer: Timer?
    private var detector: CandidateEventDetector
    private var calibrationRequested = false
    private var calibrationReadings: [Vector3] = []
    private var forward = Vector3.zero
    private var lateral = Vector3.zero
    private var mountedGravity = Vector3.zero
    private var filtered = Vector3.zero
    private var motionSamples: [MotionSample] = []
    private var gpsPoints: [GPSPoint] = []
    private var interruptions: [String] = []
    private var gpsFilter = GPSDistanceFilter()
    private var telemetrySpeed: LiveTelemetryInput.Speed?
    private var lastLocation: CLLocation?
    private var clientTripID: UUID?
    private var speedSamples: [APISpeedSample] = []
    private var softwareSimulatedGPS = false
    private var startedAt: Date?
    private var startedUptime = 0.0
    private var endedAt: Date?
    private var endedUptime: Double?
    private var recordingContext: RecordingContext?
    private var detectorCoverage = DetectorCoverage(startedUptime: 0)
    private var gpsQualityTracker: GPSQualityTracker?
    private var detectorGPS = DetectorGPSHistory()
    private var gpsQualitySummary: GPSQualitySummary? { gpsQualityTracker?.summary(through: endedAt ?? Date()) }
    private var locationWasUnavailable: Bool { gpsQualitySummary?.isPartial == true }
    private var hasMotion = false
    private var demoTick = 0
    private var calibrationTicks = 0
    private var lastMotionUptime: Double?

    init(configuration: DetectionConfiguration = .init()) {
        self.configuration = configuration
        detector = CandidateEventDetector(configuration: configuration)
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 3
        location.activityType = .automotiveNavigation
        location.pausesLocationUpdatesAutomatically = false
        authorization = location.authorizationStatus
    }

    var elapsedLabel: String {
        let seconds = Int(elapsedSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var distanceLabel: String { distanceAvailable ? String(format: "%.2f mi", distanceMiles) : "Unavailable" }
    /// Read-only presentation projection. Does not touch raw samples or detector filtering.
    func liveTelemetryInput(mountingConfirmed: Bool) -> LiveTelemetryInput {
        let vehicleAxesValid = mountingConfirmed && isCalibrated && !orientationChanged
        let acceleration = latestMotion.map { sample in
            let vehicleForward: Double?
            let vehicleLateral: Double?
            if vehicleAxesValid && mode == .device {
                vehicleForward = sample.userAcceleration.dot(forward)
                vehicleLateral = sample.userAcceleration.dot(lateral)
            } else if vehicleAxesValid && mode == .simulator {
                // The existing, explicitly synthetic fixture defines y=forward, x=lateral.
                vehicleForward = sample.userAcceleration.y
                vehicleLateral = sample.userAcceleration.x
            } else { vehicleForward = nil; vehicleLateral = nil }
            return LiveTelemetryInput.Acceleration(timestamp: sample.timestamp, deviceG: sample.userAcceleration, vehicleForwardG: vehicleForward, vehicleLateralG: vehicleLateral)
        }
        return LiveTelemetryInput(isRecording: isRecording, speed: telemetrySpeed, acceleration: acceleration, elapsedSeconds: elapsedSeconds, distanceMiles: distanceAvailable ? distanceMiles : nil, isSynthetic: mode == .simulator || softwareSimulatedGPS)
    }
    var accuracyLabel: String { gpsAccuracyMeters.map { String(format: "±%.0f m · latest reported", $0) } ?? "Waiting for GPS accuracy" }
    var detectionStatus: String {
        if mode == .walking { return "Disabled by design · Walking Test. No driving events or fuel estimates." }
        if mode == .simulator { return "Synthetic driving events · no real motion sensors." }
        if orientationChanged { return "Disabled · phone orientation changed. GPS can continue. Recalibrate for your next driving trip while parked." }
        if !hasMotion { return "Disabled · device motion unavailable. GPS can continue." }
        if !isCalibrated { return "Disabled · mount not calibrated. GPS can continue." }
        if !isLocationAuthorized { return "Disabled · location permission unavailable; GPS speed is required." }
        guard let speed = detectionSpeed(at: Date()) else {
            return "Paused · waiting for fresh GPS speed with valid accuracy."
        }
        if speed < 2 { return "Monitoring · fresh low-speed GPS; harsh-event classification suppressed." }
        return "Active · calibration valid and recent GPS speed available. Candidate events are unvalidated."
    }
    var calibrationLabel: String {
        if mode == .walking { return "Not required · phone angle may change during a Walking Test." }
        if mode == .simulator { return "Synthetic calibration · Demo Drive" }
        if orientationChanged { return "Invalid · phone orientation changed" }
        return isCalibrated ? "Valid · keep the mount fixed" : "Not calibrated · driving events disabled"
    }
    var eventCountLabel: String {
        if mode == .walking { return "Disabled" }
        if mode == .device && !isCalibrated { return "Unavailable" }
        return "\(events.count)"
    }
    var measurementsIncomplete: Bool {
        !distanceAvailable || locationWasUnavailable || !interruptions.isEmpty || (mode == .device && !isCalibrated)
    }
    var canStart: Bool { !isRecording && (mode == .simulator || authorization != .notDetermined) }

    func prepare(mode: Mode) {
        stopHardware()
        telemetrySpeed = nil; detectorGPS = DetectorGPSHistory()
        self.mode = mode
        isCalibrated = false
        calibrationRequested = false
        calibrationReadings = []
        calibrationProgress = 0
        latestMotion = nil
        interruption = nil
        gpsAccuracyMeters = nil
        orientationChanged = false
        location.activityType = mode == .walking ? .fitness : .automotiveNavigation
        location.distanceFilter = kCLDistanceFilterNone // Request frequent GPS updates; filter drift ourselves.
        if mode == .walking {
            hasMotion = false
            motionStatus = "Motion off · Walking Test uses GPS only"
            calibrationStatus = "No mount or calibration needed. Phone angle may change."
            updateAuthorization()
        } else if mode == .simulator {
            hasMotion = true
            motionStatus = "Simulator: generated motion"
            locationStatus = "Simulator: generated GPS"
            calibrationStatus = "Simulator calibration is synthetic; no sensors are used."
        } else {
            hasMotion = motion.isDeviceMotionAvailable
            motionStatus = hasMotion ? "Ready for mounted calibration" : "Device motion unavailable; GPS-only recording is available."
            calibrationStatus = "Mount flat, with the top edge facing the front of the vehicle."
            updateAuthorization()
        }
    }

    func requestLocation() {
        guard mode != .simulator else { return }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        else { updateAuthorization() }
    }

    func calibrate() {
        guard !isRecording, mode != .walking else { return }
        if mode == .simulator {
            isCalibrated = true; calibrationProgress = 1
            calibrationStatus = "Synthetic calibration ready."
            return
        }
        guard hasMotion else { return }
        isCalibrated = false
        calibrationProgress = 0
        calibrationReadings = []
        calibrationTicks = 0
        calibrationRequested = true
        calibrationStatus = "Keep the car parked and the mounted phone still for 2 seconds."
        startMotion()
    }

    func start(context: RecordingContext? = nil) {
        guard canStart else { return }
        calibrationRequested = false
        if !isCalibrated { motion.stopDeviceMotionUpdates() }
        clientTripID = UUID(); speedSamples = []; softwareSimulatedGPS = false
        telemetrySpeed = nil
        startedAt = Date(); startedUptime = ProcessInfo.processInfo.systemUptime
        endedAt = nil; endedUptime = nil; recordingContext = context
        gpsQualityTracker = GPSQualityTracker(startedAt: startedAt!)
        detectorGPS = DetectorGPSHistory()
        detectorCoverage = DetectorCoverage(startedUptime: startedUptime)
        if mode != .device || !isCalibrated || !hasMotion {
            detectorCoverage.invalidate("Calibrated device detector unavailable at start")
        }
        elapsedSeconds = 0; distanceMiles = 0; events = []; motionSamples = []; gpsPoints = []
        interruptions = []; interruption = nil; lastLocation = nil; distanceAvailable = false
        lastMotionUptime = nil
        filtered = .zero; demoTick = 0; gpsFilter = GPSDistanceFilter()
        detector = CandidateEventDetector(configuration: configuration)
        isRecording = true
        gpsFilter.maximumSpeedMetersPerSecond = mode == .walking ? 12 : 65
        if mode != .simulator {
            if isLocationAuthorized { location.startUpdatingLocation(); locationStatus = "Waiting for accurate GPS" }
            if mode == .walking { motionStatus = "Motion off · Walking Test uses GPS only" }
            else if isCalibrated { startMotion() }
            else { motionStatus = "Uncalibrated: candidate detection disabled" }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var isLocationAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    private func startMotion() {
        guard mode == .device, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] sample, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.motionStatus = "Motion unavailable: \(error.localizedDescription)"
                    self.isCalibrated = false; self.calibrationRequested = false
                    if self.isRecording { self.noteInterruption("Motion updates failed; candidate detection stopped.") }
                    self.motion.stopDeviceMotionUpdates()
                } else if let sample { self.consume(sample) }
            }
        }
    }

    private func consume(_ sample: CMDeviceMotion) {
        guard mode == .device, isRecording || calibrationRequested else { return }
        // Core Motion timestamps are monotonic uptime. Map the observed instant to our start
        // clock anchor; callback delivery time is not the sensor observation time.
        if isRecording && sample.timestamp < startedUptime { return }
        let observedAt = isRecording ? (startedAt ?? Date()).addingTimeInterval(sample.timestamp - startedUptime) : Date()
        let acceleration = Vector3(x: sample.userAcceleration.x, y: sample.userAcceleration.y, z: sample.userAcceleration.z)
        let rotation = Vector3(x: sample.rotationRate.x, y: sample.rotationRate.y, z: sample.rotationRate.z)
        let gravity = Vector3(x: sample.gravity.x, y: sample.gravity.y, z: sample.gravity.z)
        let attitude = Vector3(x: sample.attitude.roll, y: sample.attitude.pitch, z: sample.attitude.yaw)
        if calibrationRequested {
            calibrationTicks += 1
            if acceleration.length < 0.035 && rotation.length < 0.06 && abs(gravity.z) > 0.85 {
                calibrationReadings.append(gravity)
            } else {
                calibrationReadings = []
                calibrationStatus = "Keep the phone flat and still, top edge toward the front."
            }
            calibrationProgress = Double(calibrationReadings.count) / 20
            if calibrationReadings.count >= 20 {
                mountedGravity = calibrationReadings.reduce(.zero, +).normalized
                let top = Vector3(x: 0, y: 1, z: 0)
                forward = (top - mountedGravity * top.dot(mountedGravity)).normalized
                let up = mountedGravity * -1
                lateral = Vector3(x: up.y*forward.z-up.z*forward.y, y: up.z*forward.x-up.x*forward.z, z: up.x*forward.y-up.y*forward.x).normalized
                isCalibrated = true; calibrationRequested = false
                calibrationStatus = "Mount calibrated. Keep this position throughout the drive."
                motionStatus = "Calibrated · 10 Hz requested"
                motion.stopDeviceMotionUpdates()
            } else if calibrationTicks >= 150 {
                calibrationRequested = false
                calibrationStatus = "Calibration timed out. Park, secure the phone flat and retry."
                motion.stopDeviceMotionUpdates()
            }
        }
        var forwardValue: Double?
        var lateralValue: Double?
        if isRecording && isCalibrated {
            if gravity.normalized.dot(mountedGravity) < 0.94 {
                isCalibrated = false
                orientationChanged = true
                motionStatus = "Mount angle changed; detection disabled until next trip calibration."
                noteInterruption("Mount angle changed; candidate detection disabled.")
            } else {
                if let lastMotionUptime, sample.timestamp - lastMotionUptime > 1 {
                    detector = CandidateEventDetector(configuration: configuration)
                    filtered = .zero
                    noteInterruption("Motion sample gap; candidate detector reset.")
                }
                filtered = filtered * (1-configuration.smoothingWeight) + acceleration * (9.80665*configuration.smoothingWeight)
                forwardValue = filtered.dot(forward); lateralValue = filtered.dot(lateral)
                // Require recent GPS speed evidence to reduce stationary phone-motion false positives.
                if let speed = detectionSpeed(at: observedAt), speed >= 2 {
                    events += detector.update(forward: forwardValue ?? 0, lateral: lateralValue ?? 0, uptime: sample.timestamp, date: observedAt)
                } else {
                    // Known low speed intentionally suppresses classification. Missing GPS remains unknown.
                    detector = CandidateEventDetector(configuration: configuration)
                }
                lastMotionUptime = sample.timestamp
            }
        }
        let value = MotionSample(timestamp: observedAt, uptime: sample.timestamp, userAcceleration: acceleration, rotationRate: rotation, attitude: attitude, forwardAcceleration: forwardValue, lateralAcceleration: lateralValue)
        latestMotion = value
        if isRecording {
            let monitoringFailure: String?
            if forwardValue?.isFinite != true || lateralValue?.isFinite != true {
                monitoringFailure = "Calibrated finite vehicle-axis motion unavailable"
            } else if detectorGPS.observation(at: observedAt) == nil {
                monitoringFailure = "No GPS speed observation available at motion observation time"
            } else if !GPSScoringWindow.valid(detectorGPS.observation(at: observedAt)!) {
                monitoringFailure = "GPS speed or speed accuracy invalid (requires 0–53.6448 m/s and accuracy 0–2 m/s)"
            } else if detectionSpeed(at: observedAt) == nil {
                monitoringFailure = "GPS speed stale (over 3 s) or later than motion observation"
            } else { monitoringFailure = nil }
            detectorCoverage.observe(uptime: sample.timestamp, eligible: monitoringFailure == nil, reason: monitoringFailure)
            motionSamples.append(value)
        }
    }

    private func detectionSpeed(at date: Date) -> Double? {
        detectorGPS.speed(at: date)
    }

    private func tick() {
        guard isRecording else { return }
        elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedUptime
        if mode == .simulator { simulateTick() }
        else if isLocationAuthorized {
            let secondsWithoutFix = lastLocation.map { Date().timeIntervalSince($0.timestamp) } ?? elapsedSeconds
            if lastLocation != nil && secondsWithoutFix > 3 {
                locationStatus = "GPS interrupted · saved distance is partial"
            } else if lastLocation == nil && secondsWithoutFix > 10 {
                locationStatus = "Waiting for the first reliable GPS fix · try outdoors."
            }
        }
    }

    /// A deterministic test source. It never uses or claims real sensor measurements.
    private func simulateTick() {
        demoTick += 1
        let t = Double(demoTick) / 10
        let phase = demoTick % 120
        let f = phase >= 20 && phase < 40 ? 3.6 : (phase >= 65 && phase < 85 ? -3.6 : 0)
        let l = phase >= 95 && phase < 115 ? 3.6 : 0
        filtered = filtered * (1-configuration.smoothingWeight) + Vector3(x: l, y: f, z: 0) * configuration.smoothingWeight
        let sample = MotionSample(timestamp: Date(), uptime: t, userAcceleration: .init(x: l/9.80665, y: f/9.80665, z: 0), rotationRate: .zero, attitude: .zero, forwardAcceleration: filtered.y, lateralAcceleration: filtered.x)
        latestMotion = sample; motionSamples.append(sample)
        events += detector.update(forward: filtered.y, lateral: filtered.x, uptime: t, date: Date())
        if demoTick % 10 == 0 {
            distanceAvailable = true
            gpsAccuracyMeters = 5
            speedSamples.append(.init(ts: Date(), sample_seq: speedSamples.count, speed_mps: 10, speed_accuracy_mps: nil))
            distanceMiles += 10 / 1609.344
            gpsPoints.append(.init(timestamp: Date(), latitude: 40.7982 + t*0.00009, longitude: -77.8599, accuracyMeters: 5, speedMetersPerSecond: 10))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateAuthorization() }
    private func updateAuthorization() {
        authorization = location.authorizationStatus
        guard mode != .simulator else { return }
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            locationStatus = "Location permitted · foreground only"
            if isRecording { location.startUpdatingLocation() }
        case .denied, .restricted:
            locationStatus = distanceAvailable ? "Location denied · saved distance is partial" : "Location denied · distance unavailable"
            gpsAccuracyMeters = nil
            telemetrySpeed = nil; detectorGPS = DetectorGPSHistory()
            location.stopUpdatingLocation(); lastLocation = nil
            if isRecording { noteInterruption("Location permission unavailable; distance may be missing or partial.") }
        case .notDetermined: locationStatus = "Location permission not requested"
        @unknown default: locationStatus = "Location unavailable"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRecording && mode != .simulator && isLocationAuthorized else { return }
        for point in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            if point.sourceInformation?.isSimulatedBySoftware == true { softwareSimulatedGPS = true }
            detectorGPS.observe(.init(ts: point.timestamp, sample_seq: 0, speed_mps: point.speed, speed_accuracy_mps: point.speedAccuracy))
            if telemetrySpeed == nil || point.timestamp >= telemetrySpeed!.timestamp {
                telemetrySpeed = .init(timestamp: point.timestamp, metersPerSecond: point.speed, accuracyMetersPerSecond: point.speedAccuracy, horizontalAccuracyMeters: point.horizontalAccuracy)
            }
            if mode == .device, point.timestamp >= (startedAt ?? Date()), point.timestamp <= Date(), abs(point.timestamp.timeIntervalSinceNow) <= 10 {
                if speedSamples.count < 21_600 {
                    speedSamples.append(.init(ts: point.timestamp, sample_seq: speedSamples.count, speed_mps: point.speed, speed_accuracy_mps: point.speedAccuracy))
                } else { noteInterruption("Speed sample limit reached. This recording is not eligible for upload.") }
            }
            if point.horizontalAccuracy >= 0, point.horizontalAccuracy.isFinite, abs(point.timestamp.timeIntervalSinceNow) <= 10 {
                gpsAccuracyMeters = point.horizontalAccuracy
            }
            let gps = GPSPoint(timestamp: point.timestamp, latitude: point.coordinate.latitude, longitude: point.coordinate.longitude, accuracyMeters: point.horizontalAccuracy, speedMetersPerSecond: point.speed >= 0 ? point.speed : nil, courseDegrees: point.course >= 0 && point.course.isFinite && point.courseAccuracy >= 0 ? point.course : nil)
            guard let update = gpsFilter.accept(gps, startedAt: startedAt ?? Date(), now: Date()) else {
                if point.horizontalAccuracy > 35 { locationStatus = "GPS accuracy too low · waiting for a fix within 35 m" }
                continue
            }
            distanceMiles += update.addedMeters / 1609.344
            distanceAvailable = distanceAvailable || update.hasDistance
            gpsQualityTracker?.observe(point.timestamp)
            lastLocation = point
            gpsPoints.append(gps)
            locationStatus = locationWasUnavailable ? "Partial GPS distance · gaps excluded" : distanceAvailable ? "GPS recording · filtered distance estimate" : "GPS acquired; waiting for another valid point"
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isRecording else { return }
        telemetrySpeed = nil
        locationStatus = distanceAvailable ? "GPS unavailable · saved distance is partial" : "GPS unavailable · no usable distance yet"
        let locationError = error as? CLError
        if locationError?.code == .denied {
            detectorGPS = DetectorGPSHistory()
            noteInterruption("Location access was denied. Distance may be unavailable or incomplete; enable location in Settings for your next recording.")
        } else {
            // locationUnknown is advisory; actual observation timestamps determine missing coverage.
            locationStatus = locationWasUnavailable ? "GPS unavailable · saved distance is partial" : "GPS temporarily unavailable · waiting for a reliable fix"
        }
        if let error = error as? CLError, error.code == .denied { location.stopUpdatingLocation(); lastLocation = nil }
    }

    func endForInterruption(reason: String = "App left the foreground. Recording ended; review and save after returning.") {
        guard isRecording else { return }
        tick()
        noteInterruption(reason)
        freezeEnd()
        isRecording = false
        stopHardware()
    }

    private func noteInterruption(_ message: String) {
        detectorCoverage.invalidate(message)
        interruption = message
        if !interruptions.contains(message) { interruptions.append(message) }
    }

    private func freezeEnd() {
        guard endedAt == nil else { return }
        endedAt = Date()
        endedUptime = ProcessInfo.processInfo.systemUptime
        elapsedSeconds = max(0, (endedUptime ?? startedUptime) - startedUptime)
    }

    func finish() -> Trip? {
        guard let startedAt else { return nil }
        if isRecording { tick() }
        freezeEnd()
        let finalDetectionStatus = detectionStatus
        isRecording = false
        stopHardware()
        let window = try? GPSScoringWindow(samples: speedSamples, startedAt: startedAt, endedAt: endedAt ?? startedAt)
        let windowComplete = window.map {
            detectorCoverage.complete(from: startedUptime + $0.first.timeIntervalSince(startedAt), through: startedUptime + $0.last.timeIntervalSince(startedAt))
        } ?? false
        let eventsComplete = mode == .device && windowComplete && !CandidateEventDetector.version.isEmpty && events.allSatisfy { $0.detectorVersion == CandidateEventDetector.version }
        let details = RecordingDetails(endedAt: endedAt ?? startedAt, elapsedSeconds: elapsedSeconds, distanceAvailable: distanceAvailable, distanceIsPartial: locationWasUnavailable, motionAvailable: hasMotion && motionSamples.contains { $0.forwardAcceleration != nil }, calibrationDescription: mode == .walking ? "Walking Test: real GPS only. No calibration, driving detection, fuel estimate, or crew scoring." : "Stationary flat mount calibration; phone top edge manually aligned with vehicle front. Candidate events require recent GPS speed ≥ 2 m/s. Thresholds are provisional.", events: events, motionSamples: motionSamples, gpsPoints: gpsPoints, interruptions: interruptions, gpsAccuracyMeters: gpsAccuracyMeters, detectionStatus: finalDetectionStatus, calibrationValidAtEnd: mode == .device ? isCalibrated : nil, measurementsIncomplete: measurementsIncomplete, speedSamples: speedSamples, eventsComplete: eventsComplete, detectorVersion: mode == .device ? CandidateEventDetector.version : nil, detectorCoverage: detectorCoverage, observedGPSWindowComplete: windowComplete, gpsQuality: gpsQualitySummary)
        return Trip(id: UUID(), title: mode == .walking ? "Walking Test" : mode == .simulator ? "Simulator test drive" : "Recorded drive", date: startedAt, distanceMiles: distanceMiles, durationMinutes: Int(elapsedSeconds / 60), harshBraking: events.filter { $0.kind == .harshBraking }.count, rapidAcceleration: events.filter { $0.kind == .rapidAcceleration }.count, mpg: 28, fuelPrice: 3.65, modeledExcessGallons: 0, source: mode == .simulator || softwareSimulatedGPS ? .simulated : .measured, recording: details, activity: mode == .walking ? .walkingTest : .driving, clientTripID: clientTripID, recordingContext: recordingContext)
    }

    func stopHardware() {
        timer?.invalidate(); timer = nil
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        calibrationRequested = false
    }
}
