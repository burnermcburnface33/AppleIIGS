import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var speedSelection: GSSpeed = .normal
    @State private var colorMonitor: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Performance") {
                    Picker("Speed", selection: $speedSelection) {
                        Text("1 MHz (Apple ][)").tag(GSSpeed.slow)
                        Text("2.8 MHz (GS Normal)").tag(GSSpeed.normal)
                        Text("8 MHz (Zip)").tag(GSSpeed.fast)
                        Text("Unlimited").tag(GSSpeed.unlimited)
                    }
                    .onChange(of: speedSelection) { _, newValue in
                        emu.bridge.setSpeed(newValue)
                    }

                    LabeledContent("Current performance", value: String(format: "%.2f MHz", emu.currentMHz))
                }

                Section("Display") {
                    Toggle("Color monitor", isOn: $colorMonitor)
                        .onChange(of: colorMonitor) { _, newValue in
                            emu.bridge.setColorMonitor(newValue)
                        }
                }

                Section("Machine") {
                    Button("Soft reset") { emu.reset() }
                    Button("Cold boot (wipe RAM)") { emu.coldBoot() }
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                speedSelection = emu.bridge.speed()
            }
        }
    }
}
