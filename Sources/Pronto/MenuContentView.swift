import SwiftUI
import Angstrom

/// The popover shown when the menu-bar icon is clicked.
struct MenuContentView: View {
    @EnvironmentObject private var controller: MachineController
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
                controls
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

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.black.opacity(0.08)))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            powerButton(title: "Turn On", on: true,
                        tint: .green, active: controller.power.isOn)
            powerButton(title: "Turn Off", on: false,
                        tint: .orange, active: controller.power == .off)
        }
    }

    private func powerButton(title: String, on: Bool, tint: Color, active: Bool) -> some View {
        Button {
            on ? controller.turnOn() : controller.turnOff()
        } label: {
            HStack {
                Spacer()
                if controller.busy {
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
                        Text(machine.displayName).tag(machine.serialNumber)
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
        switch controller.power {
        case .on: return "On — ready to brew"
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
