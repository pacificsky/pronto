# Boiler Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Machine" tab to Pronto's Settings with brew-boiler temperature, steam boiler on/off, and steam level 1/2/3 controls, per `docs/superpowers/specs/2026-07-10-boiler-controls-design.md`.

**Architecture:** Pronto-only change (Angstrom 1.5.0 already ships the commands and streams the state). `MachineController` gains dashboard-computed reads plus three command methods following the existing `setPower` pattern, with a controller-owned 1 s debounce for temperature. `SettingsView` splits into macOS toolbar tabs (Account / Machine / Privacy); the Machine tab is a value-driven form so every state renders offline via ImageRenderer.

**Tech Stack:** Swift 5.9+ / SwiftUI, Observation framework (`@Observable`, NOT `ObservableObject`), XCTest, Angstrom + AngstromUI 1.5.0 (pinned — do not bump).

## Global Constraints

- macOS **14** deployment target — no macOS 15-only API (e.g. use `.tabItem`, NOT the macOS 15 `Tab` initializer).
- Build with `swift build`; tests with `swift test`. `./make-app.sh` is the real app-bundle build.
- Views observe the controller via `@Environment(MachineController.self)` (Observation), never `@EnvironmentObject`.
- Never put account emails, serials, or machine names in log/error messages (Sentry scrubbing guarantee).
- All temperature values are **°C** on the wire and in state; °F appears only in display strings.
- No new persistence — all values live on the machine/cloud.
- Work on a feature branch `boiler-controls` off `main` (create in Task 1, Step 0). Commit after every task.

---

### Task 1: `BrewTemperature` pure helper (clamp/step + display formatting)

**Files:**
- Create: `Sources/Pronto/BrewTemperature.swift`
- Test: `Tests/ProntoTests/BrewTemperatureTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces (used by Tasks 3's view):
  - `BrewTemperature.clamped(_ value: Double, min: Double, max: Double, step: Double) -> Double`
  - `BrewTemperature.display(celsius: Double) -> String` — e.g. `"94.0 °C · 201 °F"`

- [ ] **Step 0: Create the feature branch**

```bash
cd /Users/aakash/src/pronto && git checkout -b boiler-controls
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/ProntoTests/BrewTemperatureTests.swift`:

```swift
import XCTest
@testable import Pronto

/// The brew-temperature stepper's arithmetic: values must stay inside the
/// machine-reported bounds and land on the step grid, and the display string
/// pairs machine-native °C with a whole-degree °F hint.
final class BrewTemperatureTests: XCTestCase {

    func testClampsBelowMin() {
        XCTAssertEqual(BrewTemperature.clamped(80, min: 85, max: 104, step: 0.5), 85)
    }

    func testClampsAboveMax() {
        XCTAssertEqual(BrewTemperature.clamped(110, min: 85, max: 104, step: 0.5), 104)
    }

    func testSnapsToStepGridAnchoredAtMin() {
        XCTAssertEqual(BrewTemperature.clamped(94.3, min: 85, max: 104, step: 0.5), 94.5)
    }

    func testOnGridValuePassesThrough() {
        XCTAssertEqual(BrewTemperature.clamped(94.0, min: 85, max: 104, step: 0.5), 94.0)
    }

    func testSnapNeverExceedsMax() {
        // Grid anchored at min can overshoot max after rounding; must re-clamp.
        XCTAssertEqual(BrewTemperature.clamped(103.9, min: 85, max: 104.1, step: 0.5), 104.0)
    }

    func testZeroStepOnlyClamps() {
        XCTAssertEqual(BrewTemperature.clamped(94.3, min: 85, max: 104, step: 0), 94.3)
    }

    func testDisplayShowsCelsiusWithFahrenheitHint() {
        // 94 °C = 201.2 °F → whole-degree hint.
        XCTAssertEqual(BrewTemperature.display(celsius: 94.0), "94.0 °C · 201 °F")
    }

    func testDisplayKeepsOneCelsiusDecimal() {
        XCTAssertEqual(BrewTemperature.display(celsius: 94.5), "94.5 °C · 202 °F")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/aakash/src/pronto && swift test --filter BrewTemperatureTests 2>&1 | tail -20`
Expected: compile FAILURE — `cannot find 'BrewTemperature' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Pronto/BrewTemperature.swift`:

```swift
import Foundation

/// Pure arithmetic + formatting for the brew-temperature stepper. The machine
/// reports its own `min`/`max`/`step` (cloud dashboard widget), so the UI never
/// invents bounds; this type keeps values inside them and on the step grid.
/// Free of UI and controller state so it's unit-testable.
enum BrewTemperature {
    /// Clamp `value` into `min...max`, snapped onto the step grid anchored at
    /// `min`. The grid can overshoot `max` after rounding, so re-clamp at the end.
    static func clamped(_ value: Double, min: Double, max: Double, step: Double) -> Double {
        guard min <= max else { return value }
        let bounded = Swift.min(Swift.max(value, min), max)
        guard step > 0 else { return bounded }
        let steps = ((bounded - min) / step).rounded()
        return Swift.min(min + steps * step, max)
    }

    /// Display string for the control: machine-native °C with one decimal, plus
    /// a whole-degree °F hint — e.g. `94.0 °C · 201 °F`.
    static func display(celsius: Double) -> String {
        let fahrenheit = celsius * 9 / 5 + 32
        return String(format: "%.1f °C · %.0f °F", celsius, fahrenheit)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BrewTemperatureTests 2>&1 | tail -5`
Expected: `Test Suite 'BrewTemperatureTests' passed` — 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Pronto/BrewTemperature.swift Tests/ProntoTests/BrewTemperatureTests.swift
git commit -m "Add BrewTemperature clamp/step/display helper

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `MachineController` machine-settings surface (reads, writes, debounce)

**Files:**
- Modify: `Sources/Pronto/MachineController.swift` (structs near `BoilerReadiness` ~line 57; state properties near `actionError` ~line 107; computed reads after `boilers` ~line 151; commands after the power `setPower` method ~line 351; cleanup in `signOut()` ~line 287)
- Test: `Tests/ProntoTests/MachineSettingsControllerTests.swift`

**Interfaces:**
- Consumes (Angstrom/AngstromUI 1.5.0, already imported):
  - `device.dashboard?.coffeeBoiler: CoffeeBoiler?` — `.targetTemperature/.targetTemperatureMin/.targetTemperatureMax/.targetTemperatureStep: Double`
  - `device.dashboard?.steamBoilerLevel: SteamBoilerLevel?` — `.enabled/.enabledSupported: Bool`, `.targetLevel: SteamLevel`, `.targetLevelSupported: Bool`
  - `device.dashboard?.steamBoilerTemperature: SteamBoilerTemperature?` — `.enabled/.enabledSupported: Bool` (GS3 family; no level)
  - `device.setCoffeeTargetTemperature(celsius: Double)`, `device.setSteam(on: Bool)`, `device.setSteamTargetLevel(_: SteamLevel)` — all `async throws`, await the machine's confirmation frame, apply optimistic dashboard updates
  - `SteamLevel` enum: `.level1/.level2/.level3` (`String` raw, `CaseIterable`)
- Produces (used by Task 3's view):
  - `struct BrewBoilerSetting: Equatable { let target, min, max, step: Double }` (top-level, in MachineController.swift)
  - `struct SteamBoilerSetting: Equatable { let enabled: Bool; let enabledSupported: Bool; let level: SteamLevel? }` (top-level)
  - `controller.brewBoilerSetting: BrewBoilerSetting?`, `controller.steamBoilerSetting: SteamBoilerSetting?`
  - `controller.pendingBrewTarget: Double?`, `controller.machineSettingBusy: Bool`, `controller.machineSettingError: String?`
  - `controller.queueBrewTemperature(_ celsius: Double)`, `controller.setSteamEnabled(_ on: Bool)`, `controller.setSteamLevel(_ level: SteamLevel)`
  - `MachineController.brewTemperatureDebounce: Duration` (static **var**, default `.seconds(1)` — tests shrink it)

- [ ] **Step 1: Write the failing test**

Create `Tests/ProntoTests/MachineSettingsControllerTests.swift`:

```swift
import XCTest
import Observation
@testable import Pronto

/// The Machine-tab command surface. No cloud device is attached in unit tests,
/// so these cover the observable state machine around the debounce: pending
/// value publishes immediately (stepper feels instant), re-queues supersede,
/// and the debounced send clears the pending value even with no device.
@MainActor
final class MachineSettingsControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MachineController.brewTemperatureDebounce = .milliseconds(50)
    }

    override func tearDown() {
        MachineController.brewTemperatureDebounce = .seconds(1)
        super.tearDown()
    }

    func testQueueBrewTemperaturePublishesPendingImmediately() {
        let controller = MachineController()

        var observationFired = false
        withObservationTracking {
            _ = controller.pendingBrewTarget
        } onChange: {
            observationFired = true
        }

        controller.queueBrewTemperature(94.5)
        XCTAssertTrue(observationFired, "SwiftUI must re-render the stepper on queue")
        XCTAssertEqual(controller.pendingBrewTarget, 94.5)
    }

    func testRequeueSupersedesPendingValue() {
        let controller = MachineController()
        controller.queueBrewTemperature(94.5)
        controller.queueBrewTemperature(95.0)
        XCTAssertEqual(controller.pendingBrewTarget, 95.0)
    }

    func testDebouncedSendClearsPendingWithoutDevice() async throws {
        let controller = MachineController()
        controller.queueBrewTemperature(94.5)
        // Debounce is 50 ms in tests; give the send task ample slack.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(controller.pendingBrewTarget)
    }

    func testSettingsAreNilWhenNotConnected() {
        let controller = MachineController()
        XCTAssertNil(controller.brewBoilerSetting)
        XCTAssertNil(controller.steamBoilerSetting)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MachineSettingsControllerTests 2>&1 | tail -20`
Expected: compile FAILURE — `value of type 'MachineController' has no member 'queueBrewTemperature'` (and friends).

- [ ] **Step 3: Add the value structs**

In `Sources/Pronto/MachineController.swift`, directly after the `BoilerReadiness` struct closes (after its closing `}` around line 57), insert:

```swift
/// Brew-boiler target temperature with the machine-reported bounds, for the
/// Settings Machine tab. All values are °C, straight off the dashboard widget —
/// the UI never invents a range.
struct BrewBoilerSetting: Equatable {
    let target: Double
    let min: Double
    let max: Double
    let step: Double
}

/// Steam-boiler switches for the Settings Machine tab. `level` is `nil` on
/// machines whose steam boiler has no 1/2/3 level control (e.g. the GS3 family,
/// which reports `steamBoilerTemperature` instead).
struct SteamBoilerSetting: Equatable {
    let enabled: Bool
    let enabledSupported: Bool
    let level: SteamLevel?
}
```

- [ ] **Step 4: Add state properties and the debounce interval**

In `MachineController`, directly after the `actionError` property (line ~107), insert:

```swift
    /// How long the brew-temperature stepper waits after the last click before
    /// sending one coalesced command — rapid steps 94→96 cost a single API call.
    /// Static `var` (not `let`) only so tests can shrink it.
    static var brewTemperatureDebounce: Duration = .seconds(1)

    /// The brew temperature the debounced stepper is waiting to send (or awaiting
    /// confirmation of). Non-nil while an edit is in flight — the stepper displays
    /// it so clicks feel instant without lying about confirmed machine state.
    private(set) var pendingBrewTarget: Double?
    /// True while a Machine-tab command awaits the machine's confirmation frame.
    private(set) var machineSettingBusy = false
    /// Set when a Machine-tab command was rejected or couldn't be confirmed.
    /// Cleared when the next edit starts. Kept separate from `actionError` so
    /// popover and Settings errors can't clobber each other.
    private(set) var machineSettingError: String?
```

And with the other `@ObservationIgnored` task vars (near `commandTask`, line ~118), insert:

```swift
    @ObservationIgnored private var brewTempTask: Task<Void, Never>?
    @ObservationIgnored private var steamTask: Task<Void, Never>?
```

- [ ] **Step 5: Add the computed reads**

In `MachineController`, directly after the `readyEtaMinutes` property (line ~161), insert:

```swift
    /// Brew-boiler target + machine-reported bounds from the live dashboard, or
    /// `nil` when there's nothing controllable (not connected, machine offline,
    /// or no coffee-boiler widget — e.g. grinders).
    var brewBoilerSetting: BrewBoilerSetting? {
        guard connection == .connected, !isMachineOffline,
              let coffee = device?.dashboard?.coffeeBoiler else { return nil }
        return BrewBoilerSetting(target: coffee.targetTemperature,
                                 min: coffee.targetTemperatureMin,
                                 max: coffee.targetTemperatureMax,
                                 step: coffee.targetTemperatureStep)
    }

    /// Steam-boiler switches from the live dashboard. Level-based machines
    /// (Micra / Mini R) report `steamBoilerLevel`; the GS3 family reports
    /// `steamBoilerTemperature` (toggle only, `level` = nil). `nil` when there's
    /// no steam boiler to control.
    var steamBoilerSetting: SteamBoilerSetting? {
        guard connection == .connected, !isMachineOffline,
              let dash = device?.dashboard else { return nil }
        if let steam = dash.steamBoilerLevel {
            return SteamBoilerSetting(enabled: steam.enabled,
                                      enabledSupported: steam.enabledSupported,
                                      level: steam.targetLevelSupported ? steam.targetLevel : nil)
        }
        if let steam = dash.steamBoilerTemperature {
            return SteamBoilerSetting(enabled: steam.enabled,
                                      enabledSupported: steam.enabledSupported,
                                      level: nil)
        }
        return nil
    }
```

- [ ] **Step 6: Add the command methods**

In `MachineController`, directly after the private `setPower(on:)` method closes (line ~351), insert:

```swift
    // MARK: - Machine settings commands (Settings › Machine tab)

    /// Debounced brew-temperature edit. Every stepper click lands here; the
    /// command goes out once, ``brewTemperatureDebounce`` after the last click.
    func queueBrewTemperature(_ celsius: Double) {
        pendingBrewTarget = celsius
        machineSettingError = nil
        brewTempTask?.cancel()
        brewTempTask = Task { [weak self] in
            try? await Task.sleep(for: Self.brewTemperatureDebounce)
            guard !Task.isCancelled else { return }
            await self?.sendBrewTemperature(celsius)
        }
    }

    private func sendBrewTemperature(_ celsius: Double) async {
        defer {
            // A newer click may have re-queued while this send was in flight —
            // only clear the pending display if it's still ours.
            if pendingBrewTarget == celsius { pendingBrewTarget = nil }
        }
        await runMachineSetting("temperature") {
            try await $0.setCoffeeTargetTemperature(celsius: celsius)
        }
    }

    /// Steam toggle — immediate send; a toggle is a single discrete action.
    func setSteamEnabled(_ on: Bool) {
        machineSettingError = nil
        steamTask?.cancel()
        steamTask = Task { [weak self] in
            await self?.runMachineSetting("steam") { try await $0.setSteam(on: on) }
        }
    }

    /// Steam level 1/2/3 — immediate send, same as the toggle.
    func setSteamLevel(_ level: SteamLevel) {
        machineSettingError = nil
        steamTask?.cancel()
        steamTask = Task { [weak self] in
            await self?.runMachineSetting("steam level") { try await $0.setSteamTargetLevel(level) }
        }
    }

    /// Shared plumbing for Machine-tab commands: offline guard, busy flag, and
    /// the same error mapping as the power path. `what` names the setting in
    /// error copy ("temperature", "steam", "steam level").
    private func runMachineSetting(_ what: String,
                                   _ command: (LaMarzoccoMachine) async throws -> Void) async {
        guard let device else { return }
        // A cloud command can't reach an offline machine — the UI hides the
        // controls, but guard against a push flipping `connected` mid-click.
        guard !isMachineOffline else {
            machineSettingError = "The machine is offline — check its power switch and Wi-Fi."
            return
        }
        machineSettingBusy = true
        defer { machineSettingBusy = false }
        do {
            try await command(device)
        } catch LaMarzoccoError.authenticationFailed {
            connection = .failed(LaMarzoccoError.authenticationFailed.errorDescription ?? "Auth failed")
        } catch LaMarzoccoError.commandTimedOut {
            machineSettingError = "Couldn’t confirm the \(what) change in time."
        } catch let LaMarzoccoError.commandFailed(status, _) {
            machineSettingError = "The machine rejected the \(what) change (\(status))."
        } catch is CancellationError {
            // Superseded by a newer edit — not an error.
        } catch {
            machineSettingError = (error as? LaMarzoccoError)?.errorDescription ?? error.localizedDescription
        }
    }
```

- [ ] **Step 7: Clean up in `signOut()`**

In `signOut()` (line ~287), after the existing `commandTask?.cancel(); commandTask = nil` line, add:

```swift
        brewTempTask?.cancel(); brewTempTask = nil
        steamTask?.cancel(); steamTask = nil
        pendingBrewTarget = nil
        machineSettingBusy = false
        machineSettingError = nil
```

- [ ] **Step 8: Run the new tests, then the full suite**

Run: `swift test --filter MachineSettingsControllerTests 2>&1 | tail -5`
Expected: 4 tests pass.

Run: `swift test 2>&1 | tail -5`
Expected: all suites pass (scrubber + crash-toggle tests unaffected).

- [ ] **Step 9: Commit**

```bash
git add Sources/Pronto/MachineController.swift Tests/ProntoTests/MachineSettingsControllerTests.swift
git commit -m "Add machine-settings surface to MachineController

Dashboard-computed reads (brew target + bounds, steam enabled/level with
capability flags) and three commands following the setPower pattern. Brew
temperature debounces 1s in the controller so stepping 94→96 sends one
command; steam toggle/level send immediately.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `MachineSettingsView` (value-driven Machine tab + ImageRenderer harness)

**Files:**
- Create: `Sources/Pronto/MachineSettingsView.swift`
- Test: `Tests/ProntoTests/MachineSettingsRenderTests.swift` (opt-in mock renderer, not assertions)

**Interfaces:**
- Consumes (from Tasks 1–2): `BrewTemperature.clamped(_:min:max:step:)`, `BrewTemperature.display(celsius:)`, `BrewBoilerSetting`, `SteamBoilerSetting`, `controller.brewBoilerSetting/steamBoilerSetting/pendingBrewTarget/machineSettingBusy/machineSettingError`, `controller.queueBrewTemperature(_:)/setSteamEnabled(_:)/setSteamLevel(_:)`, `controller.refreshNow()`, `SteamLevel.level1/.level2/.level3`.
- Produces (used by Task 4): `struct MachineSettingsView: View` (no-arg init; reads `@Environment(MachineController.self)`). Also `MachineSettingsForm` + `MachineSettingsForm.MachineState` (value-driven, for renders/previews).

- [ ] **Step 1: Create the view**

Create `Sources/Pronto/MachineSettingsView.swift`:

```swift
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
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Add the opt-in render harness**

Create `Tests/ProntoTests/MachineSettingsRenderTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Pronto

/// Not a correctness test — an opt-in mock renderer for UI iteration (render
/// variants offline instead of blind rebuild-and-eyeball). Skipped unless
/// RENDER_MOCKS=1:
///
///     RENDER_MOCKS=1 RENDER_DIR=/tmp swift test --filter MachineSettingsRenderTests
///
/// writes machine-tab-<state>.png for every Machine-tab state to RENDER_DIR.
@MainActor
final class MachineSettingsRenderTests: XCTestCase {

    func testRenderMockStates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDER_MOCKS"] == "1")
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_DIR"] ?? "/tmp",
                      isDirectory: true)

        let brew = BrewBoilerSetting(target: 94.0, min: 85, max: 104, step: 0.5)
        let steamOn = SteamBoilerSetting(enabled: true, enabledSupported: true, level: .level2)
        let steamOff = SteamBoilerSetting(enabled: false, enabledSupported: true, level: .level2)
        let steamNoLevel = SteamBoilerSetting(enabled: true, enabledSupported: true, level: nil)

        let states: [(String, MachineSettingsForm)] = [
            ("controls", .init(state: .controls(brew: brew, steam: steamOn),
                               pendingBrewTarget: nil, busy: false, error: nil)),
            ("pending-temp", .init(state: .controls(brew: brew, steam: steamOn),
                                   pendingBrewTarget: 95.5, busy: true, error: nil)),
            ("steam-off", .init(state: .controls(brew: brew, steam: steamOff),
                                pendingBrewTarget: nil, busy: false, error: nil)),
            ("no-level-gs3", .init(state: .controls(brew: brew, steam: steamNoLevel),
                                   pendingBrewTarget: nil, busy: false, error: nil)),
            ("error", .init(state: .controls(brew: brew, steam: steamOn),
                            pendingBrewTarget: nil, busy: false,
                            error: "The machine rejected the steam level change (403).")),
            ("machine-offline", .init(state: .machineOffline,
                                      pendingBrewTarget: nil, busy: false, error: nil)),
            ("not-connected", .init(state: .notConnected,
                                    pendingBrewTarget: nil, busy: false, error: nil)),
            ("no-controls", .init(state: .noControls,
                                  pendingBrewTarget: nil, busy: false, error: nil)),
        ]

        for (name, form) in states {
            let renderer = ImageRenderer(content: form.padding(20).frame(width: 420))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("render failed for \(name)")
                continue
            }
            try png.write(to: dir.appendingPathComponent("machine-tab-\(name).png"))
        }
    }
}
```

- [ ] **Step 4: Render the mock states and inspect them**

Run (RENDER_DIR must exist; use the session scratchpad when executing manually):

```bash
RENDER_MOCKS=1 RENDER_DIR=/tmp swift test --filter MachineSettingsRenderTests 2>&1 | tail -3
ls /tmp/machine-tab-*.png
```

Expected: test passes, 8 PNGs written. **View each PNG** (Read tool) and check: stepper row with `94.0 °C · 201 °F`, range caption, toggle + segmented 1/2/3 with 2 selected, level picker greyed in `steam-off`, sensible notes in the three note states, no clipped or overlapping text at 420 pt width. Fix layout issues before committing.

- [ ] **Step 5: Verify plain `swift test` skips the harness**

Run: `swift test --filter MachineSettingsRenderTests 2>&1 | tail -3`
Expected: 1 test **skipped** (so CI never renders).

- [ ] **Step 6: Commit**

```bash
git add Sources/Pronto/MachineSettingsView.swift Tests/ProntoTests/MachineSettingsRenderTests.swift
git commit -m "Add Machine settings tab view (value-driven, offline-renderable)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Restructure `SettingsView` into Account / Machine / Privacy tabs

**Files:**
- Modify: `Sources/Pronto/SettingsView.swift` (whole-file restructure; all existing sections are kept, just regrouped)

**Interfaces:**
- Consumes: `MachineSettingsView` (Task 3, no-arg init).
- Produces: `SettingsView` keeps its no-arg init and stays the root of the `Settings` scene in `ProntoApp.swift` — **no change needed in `ProntoApp.swift`**.

- [ ] **Step 1: Restructure the view**

Rewrite `Sources/Pronto/SettingsView.swift` — the body becomes a `TabView` (`.tabItem`, NOT the macOS 15 `Tab` init); the account/status/privacy sections move verbatim into tab structs; the version footer stays outside the `TabView` so it shows on every tab:

```swift
import SwiftUI
import Angstrom

/// Settings window: Account (credentials + connection), Machine (live boiler
/// controls), and Privacy (crash reporting) tabs, with the version footer
/// visible on every tab.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            TabView {
                AccountSettingsTab()
                    .tabItem { Label("Account", systemImage: "person.circle") }
                MachineSettingsView()
                    .padding(.top, 8)
                    .tabItem { Label("Machine", systemImage: "dial.medium") }
                PrivacySettingsTab()
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
            }
            versionFooter
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// App version footer so users can see (and copy, for bug reports) exactly
    /// which build they're on. Reads `CFBundleShortVersionString`, which
    /// `make-app.sh` derives from the git tag (e.g. "0.4.0").
    @ViewBuilder
    private var versionFooter: some View {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        Text("Pronto \(version)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Account tab: La Marzocco credentials + connection status + machine picker.
/// Content unchanged from the pre-tab Settings window.
private struct AccountSettingsTab: View {
    @Environment(MachineController.self) private var controller

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            if controller.hasCredentials {
                signedInSection
            } else {
                credentialsSection
            }

            Section("Status") {
                LabeledContent("Connection") {
                    connectionLabel
                }
                if !controller.machines.isEmpty {
                    Picker("Machine", selection: Binding(
                        get: { controller.selectedSerial ?? "" },
                        set: { controller.selectMachine($0) }
                    )) {
                        ForEach(controller.machines) { machine in
                            Text("\(machine.displayName) — \(machine.modelName)").tag(machine.serialNumber)
                        }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(.top, 8)
    }

    /// Shown once credentials are stored: the account is read-only here. To change
    /// the password, sign out and sign back in.
    @ViewBuilder
    private var signedInSection: some View {
        Section("La Marzocco Account") {
            LabeledContent("Signed in as") {
                Text(controller.username).textSelection(.enabled)
            }

            Button(role: .destructive) {
                controller.signOut()
                email = ""
                password = ""
            } label: {
                Text("Sign Out & Clear Credentials")
            }
        }
    }

    /// Shown when no credentials are stored (fresh install or after sign-out).
    @ViewBuilder
    private var credentialsSection: some View {
        Section("La Marzocco Account") {
            TextField("Email", text: $email)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
            Text("The same email and password you use in the official La Marzocco app. Stored in your macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                controller.saveCredentials(username: email.trimmingCharacters(in: .whitespaces),
                                           password: password)
            } label: {
                Text("Save & Connect")
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty)
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch controller.connection {
        case .notConfigured:
            Text("Not configured").foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}

/// Privacy tab: opt-in, anonymous crash reporting. Defaults off. The caption
/// states the privacy guarantee that `SensitiveDataScrubber` enforces.
private struct PrivacySettingsTab: View {
    @Environment(MachineController.self) private var controller

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Send anonymous crash reports", isOn: Binding(
                    get: { controller.crashReportingEnabled },
                    set: { controller.crashReportingEnabled = $0 }
                ))
                Text("Helps fix crashes. Never includes your La Marzocco account or machine details — only the crash itself. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .padding(.top, 8)
    }
}
```

- [ ] **Step 2: Build and run the full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build complete, all tests pass (CrashReportingToggle tests exercise the same controller property the Privacy tab binds to).

- [ ] **Step 3: Build the app bundle and eyeball the Settings window**

```bash
./make-app.sh && open dist/Pronto.app
```

Open Settings from the popover. Check: three toolbar tabs render; each tab's content is complete and the window resizes sanely between tabs; the version footer shows on all tabs. Known risk: `TabView` inside `.fixedSize(horizontal: false, vertical: true)` can mis-measure height on macOS — if a tab renders clipped or zero-height, remove `.fixedSize` from `SettingsView` and instead give the `TabView` an explicit `.frame(minHeight: 320)`; re-verify.

- [ ] **Step 4: Commit**

```bash
git add Sources/Pronto/SettingsView.swift
git commit -m "Split Settings into Account / Machine / Privacy tabs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Update CLAUDE.md and README scope statements

**Files:**
- Modify: `CLAUDE.md` ("Constraints & scope" section, and the `MenuContentView.swift / SettingsView.swift` architecture bullet)
- Modify: `README.md` (feature list — check its exact wording at execution time; keep the unofficial-app trademark disclaimer intact)

**Interfaces:**
- Consumes: nothing. Produces: nothing (docs only).

- [ ] **Step 1: Update CLAUDE.md scope bullet**

In `CLAUDE.md` under "Constraints & scope", replace:

```
- Scope is power on/off + live status only — steam boiler, temperature, and
  schedules are intentionally excluded. Grinders (Pico/Swan) are **status-only**:
```

with:

```
- Scope is power on/off, live status, and boiler settings (brew temperature,
  steam on/off, steam level on machines that support it — Settings › Machine
  tab) — schedules are intentionally excluded. Grinders (Pico/Swan) are
  **status-only**:
```

- [ ] **Step 2: Update the CLAUDE.md architecture bullet**

In the `**MenuContentView.swift / SettingsView.swift**` bullet, replace:

```
- **`MenuContentView.swift` / `SettingsView.swift`** — the popover (status + a
  single state-aware power button) and the credentials/machine-selection window.
```

with:

```
- **`MenuContentView.swift` / `SettingsView.swift` / `MachineSettingsView.swift`**
  — the popover (status + a single state-aware power button) and the Settings
  window (Account / Machine / Privacy tabs). The Machine tab holds live boiler
  settings: brew target temperature (machine-reported min/max/step, °C with °F
  hint, debounced ~1s in the controller so stepping sends one command), steam
  on/off, and steam level 1/2/3 (`steamBoilerLevel` machines only; GS3-family
  gets the toggle, grinders neither). `MachineSettingsForm` is value-driven so
  every state renders offline (`RENDER_MOCKS=1 swift test --filter
  MachineSettingsRenderTests`).
```

- [ ] **Step 3: Update README feature list**

Read `README.md`, find the feature list, and add three bullets (adapt to the list's existing voice; keep the trademark disclaimer untouched):

```markdown
- Set the brew boiler's target temperature (within the machine's own range)
- Turn the steam boiler on or off — skip it when you're only pulling shots
- Set the steam level (1/2/3) on machines that support it (Linea Micra / Mini R)
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document boiler controls in CLAUDE.md and README

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end verification against the real machine

**Files:** none (verification only; fix-up commits if issues surface).

**Interfaces:**
- Consumes: the finished app from Tasks 1–5.

- [ ] **Step 1: Full build + test sweep**

```bash
swift test 2>&1 | tail -5 && ./make-app.sh 2>&1 | tail -3
```

Expected: all tests pass; `dist/Pronto.app` builds and is signed.

- [ ] **Step 2: Launch and stream logs**

```bash
open dist/Pronto.app
/usr/bin/log stream --predicate 'subsystem == "blog.pacificsky.pronto"' --info &
```

- [ ] **Step 3: Manual E2E checklist (needs the real Micra + LM account)**

This step needs the user (real machine + official LM app on their phone). Ask them to run through it rather than guessing:

1. Settings › Machine shows the stepper with the Micra's real range, the steam toggle, and level picker with the current level selected.
2. Step the temperature twice quickly → exactly **one** command in the log after ~1 s; the LM app shows the new target.
3. Change steam level in Pronto → LM app reflects it; spinner shows while confirming.
4. Toggle steam off in Pronto → LM app shows steam boiler off; level picker greys out.
5. Change the steam level in the **LM app** → Pronto's Machine tab updates live (websocket push, no reopen needed).
6. Turn the machine's physical switch off → Machine tab swaps to the offline note; controls gone.

- [ ] **Step 4: Wrap up the branch**

When the checklist passes, use superpowers:finishing-a-development-branch (expect: push `boiler-controls`, open a PR per the usual shipping workflow — branch → PR → merge when green).
