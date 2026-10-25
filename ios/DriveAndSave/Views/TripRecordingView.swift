import SwiftUI

struct TripRecordingView: View {
    @EnvironmentObject private var backend: BackendViewModel
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = TripRecordingService()
    @AppStorage("developerMode") private var developerMode = false
    @State private var selectedMode: TripRecordingService.Mode = .device
    private var simulatorMode: Bool { selectedMode == .simulator }
    private var walkingMode: Bool { selectedMode == .walking }
    @State private var mountingConfirmed = false
    @State private var began = false
    @State private var receipt: Trip?
    @State private var savedTrip: Trip?
    @State private var pendingTrip: Trip?
    @State private var saveError: String?
    @State private var showDebug = false
    private var savedRecordingDeleted: Bool { savedTrip.map { !model.isLocalTrip($0) } ?? false }
    var body: some View {
        ScrollViewReader { scroll in
            Screen {
                VStack(alignment: .leading, spacing: 24) {
                    if savedRecordingDeleted {
                        Label("Local recording deleted", systemImage: "trash").foregroundStyle(DS.secondary)
                        Text("Any uploaded receipt and league results are unchanged.").foregroundStyle(DS.secondary)
                    } else if let savedTrip {
                        Label("Trip saved on this iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(DS.mint)
                        NavigationLink { TripReceiptView(trip: savedTrip) } label: {
                            Label("Open trip receipt", systemImage: "receipt").font(.headline).frame(maxWidth: .infinity).padding()
                        }.buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("openReceipt")
                        Text("You can also find it in History. Eligible drives upload when you choose Get estimate on the receipt.").foregroundStyle(DS.secondary)
                    } else if began {
                        recordingContent
                    } else {
                        setupContent
                    }
                }.id("recordingTop")
            }
            .onChange(of: began) { _, recordingBegan in
                if recordingBegan { scroll.scrollTo("recordingTop", anchor: .top) }
            }
            .navigationTitle(savedRecordingDeleted ? "Recording deleted" : walkingMode ? "Walking Test" : savedTrip != nil ? "Trip saved" : began ? "Trip recording" : "Before you drive")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(began && savedTrip == nil)
            .onAppear { if !began { recorder.prepare(mode: selectedMode) } }
            .onDisappear {
                if recorder.isRecording { recorder.endForInterruption(reason: "Recording screen was left. Recording ended; return to save the partial trip.") }
                else { recorder.stopHardware() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    if began && savedTrip == nil { recorder.endForInterruption() }
                    else { recorder.prepare(mode: selectedMode) }
                }
            }
            .sheet(isPresented: $showDebug) { NavigationStack { MotionDebugView(recorder: recorder) } }
            .alert("Trip not saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("Retry save") { finish() }
                Button("Keep here", role: .cancel) { }
            } message: { Text(saveError ?? "") }
            .navigationDestination(item: $receipt) { trip in TripReceiptView(trip: trip) }
        }
    }

    private var setupContent: some View {
        Group {
            if developerMode {
                Picker("Recording mode", selection: $selectedMode) {
                    Text("Driving").tag(TripRecordingService.Mode.device)
                    Text("Walking Test").tag(TripRecordingService.Mode.walking)
                    Text("Demo Drive").tag(TripRecordingService.Mode.simulator)
                }.pickerStyle(.segmented).accessibilityIdentifier("recordingMode")
                    .onChange(of: selectedMode) { _, _ in
                        mountingConfirmed = false
                        recorder.prepare(mode: selectedMode)
                    }
            }
            Text(walkingMode ? "Walking GPS Test" : "Start Trip").font(.largeTitle.bold())
            Surface {
                Label(walkingMode ? "GPS only" : "Only interact while parked", systemImage: walkingMode ? "figure.walk" : "checkmark.shield.fill").font(.headline).foregroundStyle(DS.mint)
                Text(walkingMode ? "Walk outdoors. Phone angle can change; no calibration needed." : "Secure the phone in a flat mount, screen facing up and top edge pointing toward the front of the car. Start before driving. Stop only after parking.")
                Text(walkingMode ? "GPS distance and time only. No driving events, fuel estimates, or league scores. Stop walking before reviewing." : "Keep Drive Save open. Locking the phone or leaving the app ends capture; return to save the partial trip.").font(.subheadline).foregroundStyle(DS.secondary)
                if walkingMode { Text("Keep this screen open. Locking the phone or leaving the app ends capture; return to save.").font(.caption).foregroundStyle(DS.secondary) }
            }
            Surface {
                if simulatorMode { Text("Generates a synthetic route and events. Saved trips are marked SIMULATED.").font(.caption).foregroundStyle(DS.mint) }
                else {
                    Text(recorder.locationStatus).font(.subheadline).foregroundStyle(DS.secondary)
                    if recorder.authorization == .notDetermined {
                        Button("Enable location") { recorder.requestLocation() }.buttonStyle(.bordered).accessibilityIdentifier("enableLocation")
                    }
                    Text("Without location access, only elapsed time is saved. Enable Precise Location in Settings for better GPS.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            if !walkingMode {
                Surface {
                    Toggle("I’m parked, securely mounted, and the top edge points forward", isOn: $mountingConfirmed).accessibilityIdentifier("mountConfirmed")
                        .onChange(of: mountingConfirmed) { _, _ in recorder.prepare(mode: selectedMode) }
                    Text(recorder.calibrationStatus).font(.subheadline).foregroundStyle(DS.secondary)
                    ProgressView(value: recorder.calibrationProgress).tint(DS.mint)
                    Button(recorder.isCalibrated ? "Recalibrate mount" : "Calibrate mounted phone") { recorder.calibrate() }
                        .disabled(!mountingConfirmed).buttonStyle(.bordered).accessibilityIdentifier("calibrate")
                    if developerMode { Text(recorder.motionStatus).font(.caption).foregroundStyle(DS.secondary) }
                    Text("Without calibration, GPS trips save but driving events are unavailable.").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            Button {
                recorder.start(context: backend.recordingContext())
                began = recorder.isRecording
            } label: {
                Label(walkingMode ? "Start Walking Test" : simulatorMode ? "Start simulated trip" : "Start recording", systemImage: "record.circle")
                    .font(.headline).frame(maxWidth: .infinity).padding(12)
            }.buttonStyle(IgnitionButtonStyle()).disabled((!walkingMode && !mountingConfirmed) || !recorder.canStart).accessibilityIdentifier("beginRecording")
        }
    }

    private var recordingContent: some View {
        Group {
            if simulatorMode { DemoNotice() }
            if walkingMode { Label("Walking Test · Core Location", systemImage: "figure.walk").foregroundStyle(DS.mint).font(.headline) }
            Surface {
                Label(recorder.isRecording ? "Recording · foreground only" : "Recording ended", systemImage: recorder.isRecording ? "record.circle" : "pause.circle")
                    .font(.headline).foregroundStyle(DS.mint)
                LiveTelemetryView(recorder: recorder, mountingConfirmed: mountingConfirmed)
                Text(recorder.locationStatus).font(.caption).foregroundStyle(DS.secondary)
                if recorder.measurementsIncomplete {
                    Label("Measurements incomplete · some trip details may be unavailable", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Text(walkingMode ? "Stop walking before reviewing or saving your Walking Test." : "Keep your attention on the road. Review details only after parking.").font(.headline).foregroundStyle(DS.secondary)
            if let interruption = recorder.interruption { Text(interruption).font(.subheadline).foregroundStyle(.orange) }
            Button(walkingMode ? "Stop & save Walking Test" : "Stop & save · I’m parked") { finish() }
                .font(.headline).buttonStyle(IgnitionButtonStyle()).accessibilityIdentifier("stopTrip")
            if developerMode {
                Text("Driving events: \(recorder.eventCountLabel)").font(.caption).foregroundStyle(DS.secondary)
                Text("GPS accuracy: \(recorder.accuracyLabel)").font(.caption).foregroundStyle(DS.secondary).accessibilityIdentifier("gpsAccuracy")
                Text(recorder.calibrationLabel).font(.caption).foregroundStyle(DS.secondary)
                Text(recorder.detectionStatus).font(.caption).foregroundStyle(DS.secondary).accessibilityIdentifier("detectionStatus")
            }
            if developerMode && !walkingMode {
            DisclosureGroup("Sensor diagnostics") {
                Button("View live sensor measurements") { showDebug = true }.padding(.vertical)
                Text("Open only while stationary. Readings do not measure fuel consumption.").font(.caption).foregroundStyle(DS.secondary)
            }
            }
            if developerMode && !walkingMode && !recorder.events.isEmpty {
                Surface {
                    Eyebrow(text: "Candidate events")
                    ForEach(recorder.events.suffix(5)) { event in
                        HStack { Text(event.kind.label); Spacer(); Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption) }
                    }
                }
            }
        }
    }

    private func finish() {
        if pendingTrip == nil { pendingTrip = recorder.finish() }
        guard let trip = pendingTrip else { return }
        do { try model.save(trip); savedTrip = trip; receipt = trip }
        catch { saveError = "The trip remains in memory. Retry before leaving this screen. \(error.localizedDescription)" }
    }
}

struct MotionDebugView: View {
    @ObservedObject var recorder: TripRecordingService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Screen {
            Text("Parked use only").font(.headline).foregroundStyle(DS.mint)
            Text(recorder.motionStatus).foregroundStyle(DS.secondary)
            if let sample = recorder.latestMotion {
                Surface {
                    Text(sample.timestamp.formatted(date: .omitted, time: .standard)).font(.caption)
                    Text("Uptime: \(sample.uptime, specifier: "%.2f") s")
                    vector("User acceleration · g", sample.userAcceleration)
                    vector("Rotation rate · rad/s", sample.rotationRate)
                    vector("Attitude · roll/pitch/yaw rad", sample.attitude)
                    Text("Forward: \(sample.forwardAcceleration.map { String(format: "%.3f m/s²", $0) } ?? "Uncalibrated")")
                    Text("Lateral: \(sample.lateralAcceleration.map { String(format: "%.3f m/s²", $0) } ?? "Uncalibrated")")
                }.font(.system(.caption, design: .monospaced))
            } else { Text("No motion samples available. Calibrate a mounted real iPhone or start a simulated trip.") }
            Text("Candidate thresholds: braking \(recorder.configuration.brakingThreshold, specifier: "%.1f"), acceleration \(recorder.configuration.accelerationThreshold, specifier: "%.1f"), cornering \(recorder.configuration.corneringThreshold, specifier: "%.1f") m/s². Sustained for \(recorder.configuration.minimumDuration, specifier: "%.1f") s; cooldown \(recorder.configuration.cooldown, specifier: "%.1f") s per event type. Values are provisional.").font(.caption).foregroundStyle(DS.secondary)
        }.navigationTitle("Sensor debug").toolbar { Button("Done") { dismiss() } }
    }
    private func vector(_ title: String, _ value: Vector3) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).foregroundStyle(DS.secondary); Text(String(format: "x %.3f  y %.3f  z %.3f", value.x, value.y, value.z)) }
    }
}
