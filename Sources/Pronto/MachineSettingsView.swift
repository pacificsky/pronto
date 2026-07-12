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
        if brew == nil && steam == nil {
            // Both nil is also the transient state right after launch/machine-switch
            // while the dashboard hasn't loaded yet — don't claim "no controls" for
            // a machine we haven't heard from.
            if controller.device?.dashboard == nil { return .loading }
            return .noControls
        }
        return .controls(brew: brew, steam: steam)
    }
}

/// Pure rendering of the Machine tab: plain values in, callbacks out.
struct MachineSettingsForm: View {
    enum MachineState {
        case notConnected
        case machineOffline
        /// Connected but the dashboard hasn't loaded yet — distinct from
        /// `.noControls` so a Micra owner doesn't briefly read a wrong claim about
        /// their machine while the first dashboard fetch is still in flight.
        case loading
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
        VStack(alignment: .leading, spacing: 20) {
            switch state {
            case .notConnected:
                note("Connect your La Marzocco account in the Account tab to control the machine.")
            case .machineOffline:
                note("The machine isn’t reachable by La Marzocco’s cloud. Check its power switch and Wi-Fi.")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading machine settings…").foregroundStyle(.secondary)
                }
            case .noControls:
                note("This device has no remotely adjustable boiler settings.")
            case .controls(let brew, let steam):
                if let brew { brewGroup(brew) }
                if let steam { steamGroup(steam) }
            }

            if let error {
                errorGroup(error)
            }
        }
        .settingsTabPadding()
    }

    // MARK: Groups

    private func brewGroup(_ brew: BrewBoilerSetting) -> some View {
        SettingsGroup("Coffee Boiler") {
            SettingsRow(help: String(format: "%.0f–%.0f °C in %.1f° steps, as reported by the machine.",
                                      brew.min, brew.max, brew.step)) {
                // Show the in-flight edit while the debounce/confirmation runs, so
                // clicks feel instant; fall back to the machine-confirmed target.
                let shown = pendingBrewTarget ?? brew.target
                // Cloud bounds are untrusted input: `ClosedRange` traps if min > max, so
                // a degenerate range disables stepping (single-point range) instead of
                // crashing the Settings window.
                let bounds = brew.min <= brew.max ? brew.min...brew.max : brew.target...brew.target
                LabeledContent("Target temperature") {
                    HStack(spacing: 8) {
                        if pendingBrewTarget != nil, busy {
                            ProgressView().controlSize(.small)
                        }
                        Text(BrewTemperature.display(celsius: shown))
                            .monospacedDigit()
                        Stepper(value: Binding(
                            get: { shown },
                            set: { onBrewTemperature(BrewTemperature.clamped($0, min: brew.min, max: brew.max, step: brew.step)) }
                        ), in: bounds, step: brew.step) {
                            EmptyView()
                        }
                        .labelsHidden()
                    }
                }
            }
        }
    }

    private func steamGroup(_ steam: SteamBoilerSetting) -> some View {
        SettingsGroup("Steam Boiler") {
            if steam.enabledSupported {
                SettingsRow(help: "Turn off when you’re only pulling shots.") {
                    Toggle("Steam boiler", isOn: Binding(
                        get: { steam.enabled },
                        set: { onSteamEnabled($0) }
                    ))
                    .toggleStyle(FullWidthToggleStyle())
                    .tint(.green)
                    .disabled(busy)
                }
            }
            if let level = steam.level {
                SettingsRow {
                    // A bare `Picker(.segmented)` doesn't push its segments to
                    // the trailing edge on its own — unlike `LabeledContent`/
                    // `Toggle`, its internal layout just hugs the label, so
                    // wrap it in `LabeledContent` to get the same
                    // label-leading / control-trailing split as every other row.
                    LabeledContent("Steam level") {
                        Picker("Steam level", selection: Binding(
                            get: { level },
                            set: { onSteamLevel($0) }
                        )) {
                            Text("1").tag(SteamLevel.level1)
                            Text("2").tag(SteamLevel.level2)
                            Text("3").tag(SteamLevel.level3)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(busy || !steam.enabled)
                    }
                }
            }
            if busy, pendingBrewTarget == nil {
                SettingsRow {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the machine to confirm…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func errorGroup(_ error: String) -> some View {
        SettingsGroup {
            SettingsRow {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
