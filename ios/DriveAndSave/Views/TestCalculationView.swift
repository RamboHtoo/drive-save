import SwiftUI

struct TestCalculationView: View {
    @StateObject private var model: TestCalculationViewModel
    init(vehicle: VehicleRow, service: TestCalculationService) {
        _model = StateObject(wrappedValue: TestCalculationViewModel(vehicle: vehicle, service: service))
    }
    var body: some View {
        Screen {
            Eyebrow(text: "Synthetic / Demo").accessibilityIdentifier("calculationDemoLabel")
            Text("Backend sample · no iPhone sensor recording. No league impact.").font(.caption).foregroundStyle(DS.secondary)
            Surface {
                Eyebrow(text: "Selected vehicle")
                Text(model.vehicle.vehicleTitle.isEmpty ? "Saved vehicle profile" : model.vehicle.vehicleTitle).font(.headline)
                if model.vehicle["supported"] == .bool(false) {
                    Text("Unsupported car · the backend may use a reference vehicle. See the pricing vehicle below.").font(.caption).foregroundStyle(.orange)
                }
            }
            if model.isRunning { ProgressView(model.status).accessibilityIdentifier("calculationProgress") }
            if let receipt = model.receipt {
                BackendReceiptCard(receipt: receipt, mock: false, showDetailsLink: false, syntheticCalculation: true)
                NavigationLink("Advanced Settings") {
                    Screen {
                        ReceiptServerDetails(receipt: receipt)
                        if let id = model.clientTripID { Text("Test ID: \(id.uuidString)").font(.caption.monospaced()).textSelection(.enabled) }
                    }.navigationTitle("Advanced Settings").navigationBarTitleDisplayMode(.inline)
                }
            }
            if let error = model.errorMessage {
                Text(model.notScored ? "Trip not scored" : "Test unavailable").font(DS.section).foregroundStyle(.orange)
                Text(error).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("calculationError")
                if !model.notScored { Button("Retry") { Task { await model.retry() } }.buttonStyle(IgnitionButtonStyle()) }
            }
            if !model.isRunning {
                Button("New Test") { Task { await model.newTest() } }.buttonStyle(.bordered).accessibilityIdentifier("newCalculationTest")
            }
        }.navigationTitle("Test Calculation").navigationBarTitleDisplayMode(.inline)
            .task { await model.startIfNeeded() }
    }
}
