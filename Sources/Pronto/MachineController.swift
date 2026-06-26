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
    /// The power state a freshly-issued command is waiting for the cloud to
    /// confirm. Non-nil while a command is reconciling — the UI shows a pending
    /// (spinner) state instead of flipping `power` optimistically.
    @Published private(set) var pendingTarget: PowerState?
    /// Set when a command couldn't be confirmed within the retry window. Cleared
    /// when the next command starts.
    @Published var actionError: String?

    private var config = Persistence.loadConfig()
    private var client: LaMarzoccoCloudClient?
    private var pollTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var booted = false

    private static let pollInterval: UInt64 = 30 * 1_000_000_000 // 30s
    /// Confirmation polling after a power command: start at 3s, +1s each round,
    /// up to this many rounds (~75s total) before giving up.
    private static let confirmRetries = 10
    private static let confirmInitialDelay: UInt64 = 3

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
        commandTask?.cancel()
        commandTask = nil
        pendingTarget = nil
        actionError = nil
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

    func turnOn() { startCommand(on: true) }
    func turnOff() { startCommand(on: false) }

    private func startCommand(on: Bool) {
        commandTask?.cancel()
        commandTask = Task { [weak self] in await self?.setPower(on: on) }
    }

    private func setPower(on: Bool) async {
        guard let client, let serial = selectedSerial, !busy else { return }
        // Only coffee machines accept the power command; grinders manage their
        // own standby. The UI hides the buttons, but guard here too.
        guard selectedMachine?.supportsPower ?? true else { return }
        let target: PowerState = on ? .on : .off

        busy = true
        actionError = nil
        pendingTarget = target
        // Pause background polling so it can't write `power` mid-reconcile.
        stopPolling()
        defer {
            pendingTarget = nil
            busy = false
            startPolling()
        }

        // Issue the command. We do NOT flip `power` optimistically — the menu-bar
        // glyph and popover show a pending state until the cloud confirms.
        do {
            try await client.setPower(serial: serial, on: on)
        } catch {
            connection = .failed((error as? LaMarzoccoError)?.errorDescription ?? error.localizedDescription)
            return
        }

        // The cloud dashboard lags the command (machine has to wake and report
        // back), so poll with linear backoff until it reflects the target.
        var latest = power
        var delay = MachineController.confirmInitialDelay
        for _ in 0..<MachineController.confirmRetries {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            if Task.isCancelled { return }
            do {
                let state = try await client.powerState(serial: serial)
                latest = state
                lastRefresh = Date()
                if state == target {
                    power = state // confirmed
                    return
                }
            } catch LaMarzoccoError.authenticationFailed {
                connection = .failed(LaMarzoccoError.authenticationFailed.errorDescription ?? "Auth failed")
                return
            } catch {
                // Transient blip — keep retrying within the window.
            }
            delay += 1
        }

        // Window exhausted: surface whatever the cloud last reported. If it still
        // isn't the target, the command didn't take — tell the user.
        power = latest
        if latest != target {
            actionError = "Couldn’t confirm the machine turned \(on ? "on" : "off"). It still reports \(latest == .off ? "standby" : "another state")."
        }
    }

    func refreshStatus() async {
        guard let client, let serial = selectedSerial else { return }
        // Don't let a poll/manual refresh clobber an in-flight command's state.
        guard pendingTarget == nil else { return }
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
