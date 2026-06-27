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
                if controller.selectedMachine?.supportsPower ?? true {
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
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot
                .padding(.top, 4) // align the dot with the title's cap height
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.selectedMachine?.displayName ?? "La Marzocco")
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
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.black.opacity(0.08)))
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

            HStack {
                Button {
                    Task { await controller.refreshStatus() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(controller.connection != .connected)

                Spacer()

                Button("Settings…") { showSettings() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
    }

    /// Small live-connection badge: filled bolt when the websocket subscription is
    /// active, a dimmed slashed bolt while it's only REST (e.g. socket couldn't open).
    private var liveIndicator: some View {
        Label(controller.isLive ? "Live" : "Polling",
              systemImage: controller.isLive ? "bolt.horizontal.fill" : "bolt.horizontal")
            .font(.caption2)
            .foregroundStyle(controller.isLive ? .green : .secondary)
            .help(controller.isLive
                  ? "Live updates over websocket are active."
                  : "Not receiving live updates; showing last fetched status.")
    }

    // MARK: Helpers

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private var statusText: String {
        if let target = controller.pendingTarget {
            return target.isOn ? "Turning on…" : "Turning off…"
        }
        let canPower = controller.selectedMachine?.supportsPower ?? true
        switch controller.power {
        case .on: return canPower ? "On — ready to brew" : "On"
        case .off: return "Off (standby)"
        case .other(let m): return m
        case .unknown:
            return controller.connection == .connected ? "Status unavailable" : "Not connected"
        }
    }

    private var statusColor: Color {
        switch controller.power {
        case .on: return .green
        case .off: return .secondary
        case .other: return .yellow
        case .unknown: return .red.opacity(0.6)
        }
    }
}
