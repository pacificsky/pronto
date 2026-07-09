import Foundation
import Observation
import OSLog
import AppKit
import Network
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

    /// How often to reconcile the dashboard over REST while connected. Since
    /// Angstrom 1.2.0 the library re-fetches the dashboard after every websocket
    /// reconnect and recycles zombie sockets via enforced ping/pong, so this poll
    /// is no longer the primary healer for missed pushes — just a belt-and-braces
    /// sweep, hence hourly (negligible LM cloud load). The popover also refreshes
    /// on open (``refreshNow()``), so what the user looks at is always current.
    static let reconcileInterval: Duration = .seconds(60 * 60)

    /// Grace period before a websocket gap is surfaced as "Stale". The badge is
    /// keyed off Angstrom's truthful `isConnected`; without a grace, the routine
    /// CloudFront flow recycle (~40 min cadence, reconnects in seconds) would
    /// flash the stale state as noise. Disconnected with data older than this is
    /// honestly stale.
    static let staleGrace: TimeInterval = 2 * 60

    /// Popover-open refreshes are skipped while the socket is connected and the
    /// last update is younger than this. With a healthy socket the data is current
    /// by construction (pushes + reconnect refresh), so most opens cost nothing;
    /// past this age a refresh guards the one gap the socket can't see — a push
    /// the cloud silently never sent.
    static let viewRefreshAge: TimeInterval = 10 * 60

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

    // `lazy` so constructing the controller doesn't touch the Keychain — the read
    // happens at `bootstrap()` in the app, and unit tests that never bootstrap
    // stay free of Keychain ACL prompts.
    @ObservationIgnored private lazy var config = Persistence.loadConfig()
    @ObservationIgnored private var client: LaMarzoccoCloudClient?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// Last-seen network reachability, so we only reconnect on a genuine
    /// offline→online transition (not every path update). Starts `true` so the
    /// launch-time connect isn't duplicated by an initial "satisfied" callback.
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var booted = false

    /// Selected machine's power, derived from the live dashboard.
    var power: PowerState { device?.powerState ?? .unknown }

    /// The selected machine's boilers and their heating progress, taken from the
    /// live dashboard. Empty unless the machine is on (off/standby boilers are
    /// noise). `setPower` flips `power` to `.on` the moment the mode is
    /// `BrewingMode`, but the boilers can still be `.heatingUp` for minutes after —
    /// these rows surface that gap.
    var boilers: [BoilerReadiness] {
        // Offline: any boiler widgets still present are frozen last-known values,
        // not live heating state (and `isWarmingUp` must not pulse from them).
        guard power == .on, !isMachineOffline, let dash = device?.dashboard else { return [] }
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

    /// Whether the **machine itself** is offline from La Marzocco's cloud —
    /// physically switched off, unplugged, or off Wi-Fi. Distinct from our own
    /// socket health (``isSocketConnected``): our link can be perfectly live while
    /// the machine is gone. The cloud then serves a husk dashboard — top-level
    /// `connected: false`, widgets reduced to a frozen `CMMachineStatus` — so the
    /// mode-derived ``power`` is last-known, not live, and must not be trusted.
    /// (Angstrom 1.3.0 keeps the flag current across websocket pushes too, but a
    /// disconnect is still only *discovered* by a REST refresh — see the
    /// `isMachineConnected` docs.)
    var isMachineOffline: Bool { device?.isMachineConnected == false }

    /// When the machine last (re)connected to the cloud, from the dashboard
    /// envelope — shown as "last connected" context while offline.
    var machineLastConnected: Date? { device?.machineLastConnectionDate }

    /// Whether the live websocket subscription is active. Stays `true` across
    /// transient socket drops (the client auto-reconnects underneath).
    var isLive: Bool { device?.isLive ?? false }

    /// Truthful socket health (Angstrom 1.2.0+): unlike ``isLive``, flips `false`
    /// during silent drops and zombie-socket gaps while auto-reconnect works.
    var isSocketConnected: Bool { device?.isConnected ?? false }

    /// When the dashboard last changed from the cloud — a REST refresh or an
    /// applied websocket push. Stamped by Angstrom; `nil` until the first load.
    var lastUpdateAt: Date? { device?.lastUpdateAt }

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
        registerSensitiveDataForScrubbing()
        // Resilience: keep last-known state fresh and recover the live connection
        // across sleep/wake, network changes, and silently-dropped pushes. These
        // run for the app's lifetime and no-op until a machine is connected.
        startReconcileLoop()
        installWakeObserver()
        startPathMonitoring()
        if config.isComplete {
            Task { await connect() }
        } else {
            connection = .notConfigured
        }
    }

    /// Feed the account email and machine serials/names to the Sentry scrubber so
    /// they're redacted from any crash report. Always called (cheap, and harmless
    /// when reporting is off) so the literals are present if the user opts in
    /// later. See ``SensitiveDataScrubber``.
    private func registerSensitiveDataForScrubbing() {
        var values: [String?] = [config.username]
        values += machines.map(\.serialNumber)
        values += machines.map(\.displayName)
        SensitiveDataScrubber.shared.register(values)
    }

    /// Whether the user has opted in to anonymous crash reporting (Settings).
    /// Toggling starts/stops Sentry immediately — see ``CrashReporting``.
    ///
    /// Stored (not computed over UserDefaults) so the `@Observable` macro tracks
    /// it — a computed property reading Persistence directly fires no observation,
    /// so the Settings Toggle would persist the click but never re-render.
    var crashReportingEnabled: Bool = Persistence.crashReportingEnabled {
        didSet { CrashReporting.setEnabled(crashReportingEnabled) }
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
            registerSensitiveDataForScrubbing()
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
        registerSensitiveDataForScrubbing()
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
        SensitiveDataScrubber.shared.reset()
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
        // A cloud command can't reach an offline machine — it would only hang
        // until `commandTimedOut`. The UI replaces the button with a note, but
        // guard against the race where a push flips `connected` mid-click.
        guard !isMachineOffline else {
            actionError = "The machine is offline — check its power switch and Wi-Fi."
            return
        }
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

    // MARK: - Resilience (reconcile poll, wake, reachability)

    /// True when the data on screen can no longer be trusted as current: the
    /// socket is actually down (Angstrom's truthful `isConnected`) and the last
    /// cloud update is older than ``staleGrace``. While `isConnected` is true the
    /// data *is* current — any change is pushed, and 1.2.0 re-fetches the
    /// dashboard on every reconnect — so no time-based check is needed then.
    var isDataStale: Bool {
        guard connection == .connected, let device else { return false }
        if device.isConnected { return false }
        guard let last = device.lastUpdateAt else { return true }
        return Date().timeIntervalSince(last) > Self.staleGrace
    }

    /// Periodic REST reconcile. Runs for the app's lifetime; no-ops unless a
    /// machine is live and connected.
    private func startReconcileLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.reconcileInterval)
                if Task.isCancelled { return }
                await self?.reconcile()
            }
        }
    }

    /// Conditional reconcile for when the user looks (popover open). No-op while
    /// the socket is connected and the data is younger than ``viewRefreshAge`` —
    /// in that state the dashboard is current by construction, and refreshing on
    /// every open would be pointless API traffic. Fetches only when it could
    /// plausibly matter: socket down, nothing loaded yet, or data old enough that
    /// a silently-dropped push could be hiding behind a healthy-looking socket.
    func refreshNow() {
        guard let device, connection == .connected else { return }
        if device.isConnected, let last = device.lastUpdateAt,
           Date().timeIntervalSince(last) < Self.viewRefreshAge { return }
        Task { await reconcile() }
    }

    private func reconcile() async {
        guard let device, connection == .connected else { return }
        do {
            try await device.refreshDashboard()
        } catch LaMarzoccoError.authenticationFailed {
            connection = .failed(LaMarzoccoError.authenticationFailed.errorDescription ?? "Auth failed")
        } catch {
            // Transient — keep last-known state. If the socket is also dead, the
            // stale indicator trips and a wake/reachability event forces a cycle.
            log.debug("reconcile refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Bring the connection back to a *verified* state. Used on wake and when
    /// network reachability returns: we don't trust the existing socket (it may be
    /// a half-open zombie the client can't detect), so force a full cycle.
    /// ``startLive()`` tears the old socket down, re-fetches the dashboard, and
    /// opens a fresh subscription. If we never fully connected (client absent or
    /// not `.connected`), do a full ``connect()`` instead so machines/selection are
    /// re-established first.
    private func ensureFreshConnection() {
        guard config.isComplete else { return }
        if client == nil || connection != .connected {
            Task { await connect() }
        } else {
            startLive()
        }
    }

    /// Reconnect on system wake. A socket that "survived" sleep is unreliable — the
    /// peer may have dropped it while we were suspended, leaving a half-open
    /// connection the client can't tell from a healthy one — so we cycle it. Only
    /// full wakes post `didWakeNotification` (not the brief DarkWake maintenance
    /// windows), so this doesn't churn overnight.
    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                log.notice("system wake — forcing a fresh connection")
                self.ensureFreshConnection()
            }
        }
    }

    /// Reconnect when connectivity is regained (e.g. Wi-Fi returns after being
    /// offline), and avoid pointless reconnect churn while there's no network.
    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.handlePathUpdate(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "blog.pacificsky.pronto.pathmonitor"))
        pathMonitor = monitor
    }

    private func handlePathUpdate(satisfied: Bool) {
        let regained = satisfied && !pathSatisfied
        pathSatisfied = satisfied
        if regained {
            log.notice("network reachability regained — forcing a fresh connection")
            ensureFreshConnection()
        }
    }
}
