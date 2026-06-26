import Foundation
import SwiftUI
import Angstrom

/// High-level connection state for the UI.
enum ConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case failed(String)
}

/// Observable view-model that owns the cloud client and the machine's live state.
@MainActor
final class MachineController: ObservableObject {
    @Published private(set) var connection: ConnectionState = .notConfigured
    @Published private(set) var power: PowerState = .unknown
    @Published private(set) var machines: [Machine] = []
    @Published var selectedSerial: String?
    @Published private(set) var busy = false
    @Published private(set) var lastRefresh: Date?

    private var config = Persistence.loadConfig()
    private var client: LaMarzoccoCloudClient?
    private var pollTask: Task<Void, Never>?
    private var booted = false

    private static let pollInterval: UInt64 = 30 * 1_000_000_000 // 30s

    var hasCredentials: Bool { config.isComplete }
    var username: String { config.username }

    var selectedMachine: Machine? {
        machines.first { $0.serialNumber == selectedSerial }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !booted else { return }
        booted = true
        selectedSerial = config.selectedSerial
        if config.isComplete {
            Task { await connect() }
        } else {
            connection = .notConfigured
        }
    }

    /// (Re)build the client from stored credentials and load machines + status.
    func connect() async {
        guard config.isComplete else { connection = .notConfigured; return }
        connection = .connecting
        stopPolling()

        let key = Persistence.loadOrCreateInstallationKey()
        let client = LaMarzoccoCloudClient(username: config.username,
                                           password: config.password,
                                           installationKey: key,
                                           registered: Persistence.isRegistered)
        self.client = client

        do {
            let found = try await client.connect()
            Persistence.isRegistered = await client.isRegistered
            machines = found
            // Keep a valid selection.
            if selectedSerial == nil || !found.contains(where: { $0.serialNumber == selectedSerial }) {
                selectedSerial = found.first?.serialNumber
                Persistence.saveSelectedSerial(selectedSerial)
            }
            connection = .connected
            await refreshStatus()
            startPolling()
        } catch {
            connection = .failed((error as? LaMarzoccoError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Settings

    func saveCredentials(username: String, password: String) {
        config.username = username
        config.password = password
        Persistence.saveCredentials(username: username, password: password)
        Task { await connect() }
    }

    func selectMachine(_ serial: String) {
        selectedSerial = serial
        Persistence.saveSelectedSerial(serial)
        Task { await refreshStatus() }
    }

    func signOut() {
        stopPolling()
        Persistence.clearAll()
        config = Persistence.loadConfig()
        client = nil
        machines = []
        selectedSerial = nil
        power = .unknown
        connection = .notConfigured
    }

    // MARK: - Commands

    func turnOn() { Task { await setPower(on: true) } }
    func turnOff() { Task { await setPower(on: false) } }

    private func setPower(on: Bool) async {
        guard let client, let serial = selectedSerial, !busy else { return }
        // Only coffee machines accept the power command; grinders manage their
        // own standby. The UI hides the buttons, but guard here too.
        guard selectedMachine?.supportsPower ?? true else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.setPower(serial: serial, on: on)
            power = on ? .on : .off // optimistic
            // Confirm with the server shortly after.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshStatus()
        } catch {
            connection = .failed((error as? LaMarzoccoError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func refreshStatus() async {
        guard let client, let serial = selectedSerial else { return }
        do {
            power = try await client.powerState(serial: serial)
            lastRefresh = Date()
            if connection != .connected { connection = .connected }
        } catch LaMarzoccoError.authenticationFailed {
            connection = .failed(LaMarzoccoError.authenticationFailed.errorDescription ?? "Auth failed")
        } catch {
            // Transient network blips shouldn't nuke the UI; keep last known state.
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MachineController.pollInterval)
                if Task.isCancelled { break }
                await self?.refreshStatus()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
