import Foundation
import Observation
import OSLog
import Angstrom
import AngstromUI

/// Unified-logging channel for the cloud client + live connection. View it with
/// `log stream --predicate 'subsystem == "blog.pacificsky.pronto"'` or Console.app.
private let log = Logger(subsystem: "blog.pacificsky.pronto", category: "lamarzocco")

/// High-level connection state for the UI.
enum ConnectionState: Equatable {
    case notConfigured
    case connecting
    case connected
    case failed(String)
}

/// One boiler's heating progress, for the popover's warm-up rows.
///
/// `readyAt` is the cloud's absolute estimate of when the boiler reaches
/// temperature (Angstrom's `…Boiler.readyStartTime`), so the ETA stays correct at
/// render time and refreshes as websocket pushes update the dashboard.
struct BoilerReadiness: Identifiable {
    enum Kind { case coffee, steam }

    let kind: Kind
    let status: BoilerStatus
    let readyAt: Date?

    var id: Kind { kind }
    var name: String { kind == .coffee ? "Coffee boiler" : "Steam boiler" }
    var symbol: String { kind == .coffee ? "cup.and.saucer.fill" : "humidity.fill" }

    /// Whole minutes until `date`, rounded up, or `nil` if it's already past.
    static func minutes(until date: Date) -> Int? {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    /// Right-aligned status for the row, e.g. `Heating · 4m`, `Ready`.
    var detail: String {
        switch status {
        case .heatingUp:
            if let m = readyAt.flatMap(Self.minutes(until:)) { return "Heating · \(m)m" }
            return "Heating up"
        case .ready: return "Ready"
        case .standby: return "Standby"
        case .off: return "Off"
        case .noWater: return "No water"
        case .other(let v): return v
        }
    }
}

/// Observable view-model that owns the cloud client and the selected machine's
/// live state.
///
/// Status arrives over Angstrom's websocket via `LaMarzoccoMachine` (the
/// `AngstromUI` device layer), so the UI reflects changes — including ones made
/// at the machine itself, the official app, or a schedule — without polling.
/// `power` is derived from the live `dashboard`; reading it through SwiftUI tracks
/// the nested `@Observable` machine automatically.
@MainActor
@Observable
final class MachineController {
    /// App-wide instance, brought up at launch by the `AppDelegate` and shared
    /// with the SwiftUI scenes — so the connection's lifetime is the app's, not
    /// the popover's.
    static let shared = MachineController()

    private(set) var connection: ConnectionState = .notConfigured
    private(set) var machines: [Machine] = []
    private(set) var selectedSerial: String?
    private(set) var busy = false
    /// The power state a freshly-issued command is waiting on. Non-nil while a
    /// command is in flight — the UI shows a pending (spinner) state rather than
    /// flipping `power` before the cloud confirms.
    private(set) var pendingTarget: PowerState?
    /// Set when a command was rejected or couldn't be confirmed. Cleared when the
    /// next command starts.
    private(set) var actionError: String?

    /// The live, observable view of the selected machine. Its `dashboard` is kept
    /// current by the websocket; `power` is derived from it.
    private(set) var device: LaMarzoccoMachine?

    @ObservationIgnored private var config = Persistence.loadConfig()
    @ObservationIgnored private var client: LaMarzoccoCloudClient?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var booted = false

    /// Selected machine's power, derived from the live dashboard.
    var power: PowerState { device?.powerState ?? .unknown }

    /// The selected machine's boilers and their heating progress, taken from the
    /// live dashboard. Empty unless the machine is on (off/standby boilers are
    /// noise). `setPower` flips `power` to `.on` the moment the mode is
    /// `BrewingMode`, but the boilers can still be `.heatingUp` for minutes after —
    /// these rows surface that gap.
    var boilers: [BoilerReadiness] {
        guard power == .on, let dash = device?.dashboard else { return [] }
        var result: [BoilerReadiness] = []
        if let coffee = dash.coffeeBoiler {
            result.append(.init(kind: .coffee, status: coffee.status, readyAt: coffee.readyStartTime))
        }
        if let steam = dash.steamBoilerLevel {
            result.append(.init(kind: .steam, status: steam.status, readyAt: steam.readyStartTime))
        } else if let steam = dash.steamBoilerTemperature {
            result.append(.init(kind: .steam, status: steam.status, readyAt: steam.readyStartTime))
        }
        return result
    }

    /// On, but at least one boiler is still heating — distinct from fully `.ready`.
    var isWarmingUp: Bool { boilers.contains { $0.status == .heatingUp } }

    /// Combined "ready in ~N min" for the status line: minutes until the last
    /// still-heating boiler reaches temperature. `nil` once everything is ready.
    var readyEtaMinutes: Int? {
        let latest = boilers.compactMap { $0.status == .heatingUp ? $0.readyAt : nil }.max()
        return latest.flatMap(BoilerReadiness.minutes(until:))
    }

    /// Whether the live websocket subscription is active. Stays `true` across
    /// transient socket drops (the client auto-reconnects underneath).
    var isLive: Bool { device?.isLive ?? false }

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

    /// (Re)build the client from stored credentials, load machines, and bring the
    /// selected machine live.
    func connect() async {
        guard config.isComplete else { connection = .notConfigured; return }
        connection = .connecting

        let key = Persistence.loadOrCreateInstallationKey()
        let client = LaMarzoccoCloudClient(username: config.username,
                                           password: config.password,
                                           installationKey: key,
                                           registered: Persistence.isRegistered,
                                           logHandler: { msg in log.info("\(msg, privacy: .public)") })
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
            startLive()
        } catch {
            log.error("connect failed: \(error.localizedDescription, privacy: .public)")
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
        guard serial != selectedSerial else { return }
        selectedSerial = serial
        Persistence.saveSelectedSerial(serial)
        startLive()
    }

    func signOut() {
        commandTask?.cancel(); commandTask = nil
        liveTask?.cancel(); liveTask = nil
        let previous = device
        device = nil
        Task { await previous?.stop() }
        pendingTarget = nil
        actionError = nil
        Persistence.clearAll()
        config = Persistence.loadConfig()
        client = nil
        machines = []
        selectedSerial = nil
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
        guard let device, let machine = selectedMachine, !busy else { return }
        // Only coffee machines accept the power command; grinders manage their own
        // standby. The UI hides the buttons, but guard here too.
        guard machine.supportsPower else { return }
        let target: PowerState = on ? .on : .off

        busy = true
        actionError = nil
        pendingTarget = target
        defer {
            pendingTarget = nil
            busy = false
        }

        // With a live websocket the command awaits the machine's confirmation
        // frame (≤10s) and throws on rejection/timeout; `LaMarzoccoMachine` also
        // applies an optimistic dashboard update, so `power` reflects the target
        // on return. With no socket it's fire-and-forget plus the optimistic flip.
        do {
            try await device.setPower(on: on)
        } catch LaMarzoccoError.authenticationFailed {
            connection = .failed(LaMarzoccoError.authenticationFailed.errorDescription ?? "Auth failed")
        } catch LaMarzoccoError.commandTimedOut {
            actionError = "Couldn’t confirm the machine turned \(on ? "on" : "off") in time."
        } catch let LaMarzoccoError.commandFailed(status, _) {
            actionError = "The machine rejected the \(on ? "on" : "off") command (\(status))."
        } catch {
            actionError = (error as? LaMarzoccoError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Live updates

    /// Tear down any previous machine and bring the selected one live.
    private func startLive() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in await self?.activateMachine() }
    }

    private func activateMachine() async {
        let previous = device
        device = nil
        await previous?.stop()

        guard let client, let serial = selectedSerial else { return }
        let machine = LaMarzoccoMachine(serialNumber: serial, client: client)
        device = machine

        // A dashboard must exist before `start()` or early websocket pushes (which
        // carry no machine identity) are dropped — so load it once first.
        do {
            try await machine.refreshDashboard()
        } catch LaMarzoccoError.authenticationFailed {
            connection = .failed(LaMarzoccoError.authenticationFailed.errorDescription ?? "Auth failed")
            return
        } catch {
            // Best-effort: the live socket may still deliver a first update.
        }

        // A newer selection superseded us while awaiting — don't open a socket.
        if Task.isCancelled { await machine.stop(); return }

        do {
            try await machine.start()
            log.notice("live websocket up for \(serial, privacy: .public)")
        } catch {
            log.error("websocket start failed: \(error.localizedDescription, privacy: .public)")
            // Live updates are best-effort; we already have a one-shot dashboard
            // and the underlying socket self-heals on reconnect.
        }
    }
}
