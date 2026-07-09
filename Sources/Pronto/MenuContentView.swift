import SwiftUI
import Angstrom

/// The popover shown when the menu-bar icon is clicked.
struct MenuContentView: View {
    @Environment(MachineController.self) private var controller
    @Environment(\.openSettings) private var openSettings

    /// Muted action-button tints — a soft sage for "on", a warm amber for "off".
    /// Mid-toned (not ultra-light pastel) so the white button label stays legible.
    private static let turnOnTint = Color(red: 0.40, green: 0.62, blue: 0.47)
    private static let turnOffTint = Color(red: 0.85, green: 0.58, blue: 0.34)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch controller.connection {
            case .notConfigured:
                notConfigured
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                failed(message)
            case .connected:
                if controller.isMachineOffline {
                    machineOfflineNote
                } else if controller.selectedMachine?.supportsPower ?? true {
                    if !controller.boilers.isEmpty { boilerSection }
                    controls
                } else {
                    statusOnlyNote
                }
            }

            if let actionError = controller.actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
        // Reconcile when the popover opens — but only if it could matter (socket
        // down or data past its freshness window); healthy opens cost no traffic.
        .onAppear { controller.refreshNow() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot
                .padding(.top, 4) // align the dot with the title's cap height
            VStack(alignment: .leading, spacing: 1) {
                Text(machineTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if controller.connection == .connected {
                liveIndicator
            }
        }
    }

    @ViewBuilder private var statusDot: some View {
        if controller.pendingTarget != nil {
            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
        } else {
            // While warming, the dot pulses — motion (not the amber hue, which would
            // clash with the amber Turn-Off button) signals "actively heating up".
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.black.opacity(0.08)))
                .opacity(controller.isWarmingUp && warmPulse ? 0.3 : 1)
                .onAppear { setWarmPulse(controller.isWarmingUp) }
                .onChange(of: controller.isWarmingUp) { _, warming in setWarmPulse(warming) }
        }
    }

    @State private var warmPulse = false

    private func setWarmPulse(_ warming: Bool) {
        if warming {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { warmPulse = true }
        } else {
            withAnimation(.default) { warmPulse = false }
        }
    }

    /// Per-boiler warm-up rows, shown while the machine is on. Each row names a
    /// boiler with its heating state and a rough ETA (`Heating · 4m`) or `Ready`,
    /// so "on" no longer reads as "ready to brew" the instant power flips.
    private var boilerSection: some View {
        VStack(spacing: 6) {
            ForEach(controller.boilers) { boiler in
                HStack(spacing: 8) {
                    Image(systemName: boiler.symbol)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(boiler.name)
                    Spacer(minLength: 8)
                    Text(boiler.detail)
                        .foregroundStyle(boiler.status == .ready ? Color.green : Color.secondary)
                }
                .font(.caption)
            }
        }
    }

    /// A single, state-aware power button. The current state is already conveyed by
    /// the header (dot + status line) and the menu-bar glyph, so this region is
    /// purely "what can I do next" — the button's label, colour, and action all
    /// follow `powerAction`.
    private var controls: some View {
        Button {
            switch powerAction {
            case .turnOn: controller.turnOn()
            case .turnOff: controller.turnOff()
            case .none: break
            }
        } label: {
            HStack(spacing: 8) {
                Spacer()
                if controller.pendingTarget != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "power")
                }
                Text(powerActionLabel)
                Spacer()
            }
            .fontWeight(.semibold)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(powerActionTint)
        .disabled(controller.busy || powerAction == .none)
    }

    private enum PowerAction { case turnOn, turnOff, none }

    /// Maps the current power state to the single sensible action.
    private var powerAction: PowerAction {
        if controller.pendingTarget != nil { return .none } // command in flight
        switch controller.power {
        case .on: return .turnOff
        case .off, .other: return .turnOn   // .other (e.g. EcoMode): wake to ready
        case .unknown: return .none         // state unknown — don't guess a direction
        }
    }

    private var powerActionLabel: String {
        if let target = controller.pendingTarget {
            return target.isOn ? "Turning On…" : "Turning Off…"
        }
        switch powerAction {
        case .turnOn: return "Turn On"
        case .turnOff: return "Turn Off"
        case .none: return "Status Unavailable"
        }
    }

    private var powerActionTint: Color {
        switch powerAction {
        case .turnOn: return Self.turnOnTint
        case .turnOff: return Self.turnOffTint
        case .none:
            // Keep the target colour while a command reconciles; grey when unknown.
            if let target = controller.pendingTarget {
                return target.isOn ? Self.turnOnTint : Self.turnOffTint
            }
            return Color.gray.opacity(0.4)
        }
    }

    /// Shown instead of the power button when the machine itself has dropped off
    /// La Marzocco's cloud (physically switched off, unplugged, or off Wi-Fi).
    /// The cloud can't reach it, so no remote action is possible — and the mode
    /// it reports is frozen at last-known, which the header no longer shows.
    private var machineOfflineNote: some View {
        Label {
            Text(machineOfflineDetail)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var machineOfflineDetail: String {
        if let last = controller.machineLastConnected {
            let time = last.formatted(date: .omitted, time: .shortened)
            return "The machine hasn’t been reachable since \(time). Check its power switch and Wi-Fi."
        }
        return "The machine isn’t reachable by La Marzocco’s cloud. Check its power switch and Wi-Fi."
    }

    /// Shown for devices that report status but can't be powered remotely
    /// (e.g. grinders). The current state still appears in the header.
    private var statusOnlyNote: some View {
        Label("Status only — this device can't be powered on or off remotely.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your La Marzocco account to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Settings…") { showSettings() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Retry") { Task { await controller.connect() } }
                Button("Settings…") { showSettings() }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if controller.machines.count > 1 {
                Picker("Machine", selection: Binding(
                    get: { controller.selectedSerial ?? "" },
                    set: { controller.selectMachine($0) }
                )) {
                    ForEach(controller.machines) { machine in
                        Text("\(machine.displayName) — \(machine.modelName)").tag(machine.serialNumber)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 8) {
                Button { showSettings() } label: {
                    Text("Settings…").frame(maxWidth: .infinity)
                }

                Button { NSApp.terminate(nil) } label: {
                    Text("Quit").frame(maxWidth: .infinity)
                }
            }
            .font(.callout)
        }
    }

    /// Small connection badge. Green "Live" when the websocket is *actually*
    /// connected (`isSocketConnected` — real socket health, not just the
    /// subscription, which stays nominally active across silent drops); amber
    /// "Stale" when the socket is down and the last-known data has outlived the
    /// grace window; dimmed "Polling" otherwise (socket down/reconnecting, or
    /// live updates never started, with data still recent).
    @ViewBuilder private var liveIndicator: some View {
        if controller.isDataStale {
            Label("Stale", systemImage: "clock.badge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(staleHelp)
        } else if controller.isSocketConnected {
            Label("Live", systemImage: "bolt.horizontal.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .help("Live updates over websocket are active.")
        } else {
            Label("Polling", systemImage: "bolt.horizontal")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Not receiving live updates; showing last fetched status.")
        }
    }

    private var staleHelp: String {
        if let last = controller.lastUpdateAt {
            let minutes = max(1, Int(Date().timeIntervalSince(last) / 60))
            return "Connection lost — last update \(minutes)m ago. Reconnecting…"
        }
        return "Connection lost — reconnecting…"
    }

    // MARK: Helpers

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// Header title. Prefers a user-set machine name, then the friendly model name
    /// ("Linea Micra") — the cloud often leaves `name` empty, in which case
    /// `displayName` falls back to the cryptic serial, which we'd rather not headline.
    private var machineTitle: String {
        guard let machine = controller.selectedMachine else { return "La Marzocco" }
        if !machine.name.isEmpty, machine.name != machine.serialNumber { return machine.name }
        if !machine.modelName.isEmpty { return machine.modelName }
        return machine.displayName
    }

    private var statusText: String {
        if let target = controller.pendingTarget {
            return target.isOn ? "Turning on…" : "Turning off…"
        }
        // Offline trumps the mode-derived state: the cloud's last-known mode is
        // frozen at whatever the machine reported before it vanished.
        if controller.isMachineOffline { return "Machine offline" }
        let canPower = controller.selectedMachine?.supportsPower ?? true
        switch controller.power {
        case .on:
            guard canPower else { return "On" }
            if controller.isWarmingUp {
                if let eta = controller.readyEtaMinutes { return "Heating up — ready in ~\(eta) min" }
                return "Heating up…"
            }
            return "On — ready to brew"
        case .off: return "Off (standby)"
        case .other(let m): return m
        case .unknown:
            return controller.connection == .connected ? "Status unavailable" : "Not connected"
        }
    }

    private var statusColor: Color {
        if controller.isMachineOffline { return .secondary }
        switch controller.power {
        case .on: return controller.isWarmingUp ? .orange : .green
        case .off: return .secondary
        case .other: return .yellow
        case .unknown: return .red.opacity(0.6)
        }
    }
}
