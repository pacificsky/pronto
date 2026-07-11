import SwiftUI
import Angstrom

/// The Settings "Machine" tab: live boiler settings for the selected machine.
/// A thin controller adapter around ``MachineSettingsForm`` — the form itself is
/// value-driven so every state renders offline (ImageRenderer) with no cloud.
struct MachineSettingsView: View {
    @Environment(MachineController.self) private var controller

    var body: some View {
        MachineSettingsForm(state: state,
                            pendingBrewTarget: controller.pendingBrewTarget,
                            busy: controller.machineSettingBusy,
                            error: controller.machineSettingError,
                            onBrewTemperature: { controller.queueBrewTemperature($0) },
                            onSteamEnabled: { controller.setSteamEnabled($0) },
                            onSteamLevel: { controller.setSteamLevel($0) })
            // Same conditional reconcile as the popover: free when the socket is
            // healthy and the data fresh.
            .onAppear { controller.refreshNow() }
    }

    private var state: MachineSettingsForm.MachineState {
        guard controller.connection == .connected else { return .notConnected }
        if controller.isMachineOffline { return .machineOffline }
        let brew = controller.brewBoilerSetting
        let steam = controller.steamBoilerSetting
        if brew == nil && steam == nil { return .noControls }
        return .controls(brew: brew, steam: steam)
    }
}

/// Pure rendering of the Machine tab: plain values in, callbacks out.
struct MachineSettingsForm: View {
    enum MachineState {
        case notConnected
        case machineOffline
        /// Connected but nothing controllable (grinders: no boiler widgets).
        case noControls
        case controls(brew: BrewBoilerSetting?, steam: SteamBoilerSetting?)
    }

    let state: MachineState
    let pendingBrewTarget: Double?
    let busy: Bool
    let error: String?
    var onBrewTemperature: (Double) -> Void = { _ in }
    var onSteamEnabled: (Bool) -> Void = { _ in }
    var onSteamLevel: (SteamLevel) -> Void = { _ in }

    var body: some View {
        Form {
            switch state {
            case .notConnected:
                note("Connect your La Marzocco account in the Account tab to control the machine.")
            case .machineOffline:
                note("The machine isn’t reachable by La Marzocco’s cloud. Check its power switch and Wi-Fi.")
            case .noControls:
                note("This device has no remotely adjustable boiler settings.")
            case .controls(let brew, let steam):
                if let brew { brewSection(brew) }
                if let steam { steamSection(steam) }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.columns) // match SettingsView
    }

    // MARK: Sections

    private func brewSection(_ brew: BrewBoilerSetting) -> some View {
        Section("Coffee Boiler") {
            // Show the in-flight edit while the debounce/confirmation runs, so
            // clicks feel instant; fall back to the machine-confirmed target.
            let shown = pendingBrewTarget ?? brew.target
            Stepper(value: Binding(
                get: { shown },
                set: { onBrewTemperature(BrewTemperature.clamped($0, min: brew.min, max: brew.max, step: brew.step)) }
            ), in: brew.min...brew.max, step: brew.step) {
                LabeledContent("Target temperature") {
                    HStack(spacing: 6) {
                        if pendingBrewTarget != nil, busy {
                            ProgressView().controlSize(.small)
                        }
                        Text(BrewTemperature.display(celsius: shown))
                            .monospacedDigit()
                    }
                }
            }
            Text(String(format: "%.0f–%.0f °C in %.1f° steps, as reported by the machine.",
                        brew.min, brew.max, brew.step))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func steamSection(_ steam: SteamBoilerSetting) -> some View {
        Section("Steam Boiler") {
            if steam.enabledSupported {
                Toggle("Steam boiler", isOn: Binding(
                    get: { steam.enabled },
                    set: { onSteamEnabled($0) }
                ))
                .disabled(busy)
                Text("Turn off when you’re only pulling shots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let level = steam.level {
                Picker("Steam level", selection: Binding(
                    get: { level },
                    set: { onSteamLevel($0) }
                )) {
                    Text("1").tag(SteamLevel.level1)
                    Text("2").tag(SteamLevel.level2)
                    Text("3").tag(SteamLevel.level3)
                }
                .pickerStyle(.segmented)
                .disabled(busy || !steam.enabled)
            }
            if busy, pendingBrewTarget == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the machine to confirm…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
