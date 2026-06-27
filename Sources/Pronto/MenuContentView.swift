import SwiftUI
import Angstrom

/// The popover shown when the menu-bar icon is clicked.
struct MenuContentView: View {
    @Environment(MachineController.self) private var controller
    @Environment(\.openSettings) private var openSettings

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
        .task { controller.bootstrap() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.selectedMachine?.displayName ?? "La Marzocco")
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    private var controls: some View {
        HStack(spacing: 10) {
            powerButton(title: "Turn On", on: true,
                        tint: .green, active: controller.power.isOn)
            powerButton(title: "Turn Off", on: false,
                        tint: .orange, active: controller.power == .off)
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

    private func powerButton(title: String, on: Bool, tint: Color, active: Bool) -> some View {
        // Spinner appears only on the button whose direction is being confirmed.
        let isPending = controller.pendingTarget == (on ? .on : .off)
        return Button {
            on ? controller.turnOn() : controller.turnOff()
        } label: {
            HStack {
                Spacer()
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "power")
                }
                Text(title)
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? tint : Color.secondary.opacity(0.5))
        .disabled(controller.busy || active)
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
