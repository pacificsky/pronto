import XCTest
import SwiftUI
import AppKit
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
            ("loading", .init(state: .loading,
                              pendingBrewTarget: nil, busy: false, error: nil)),
        ]

        // Measure each state's *own* fitting height instead of guessing a
        // shared render height — this is also the evidence behind the
        // `SettingsView` window frame (see the arithmetic below and
        // `SettingsView.swift`'s `.frame` comment).
        var measured: [(String, CGFloat)] = []
        for (name, form) in states {
            let height = autoreleasepool {
                Self.measuredFittingHeight(form)
            }
            measured.append((name, height))
            print("[MachineSettingsRenderTests] \(name) form fitting height: \(height)pt")
        }

        let tallest = measured.max { $0.1 < $1.1 }!
        print("[MachineSettingsRenderTests] tallest form state: \(tallest.0) at \(tallest.1)pt")

        // Chrome (tab bar + inter-view spacing + version footer) is
        // state-independent, but `SettingsView`'s per-tab structs are
        // `private` to SettingsView.swift and unreachable from this test
        // file even with @testable import. Instead of duplicating their
        // internals, `ChromeProbe` below reproduces `SettingsView.body`'s
        // non-form scaffolding modifier-for-modifier around the *real*
        // `MachineSettingsForm` for the tallest state, so subtracting that
        // same form's bare fitting height isolates exactly the chrome
        // `SettingsView` adds around whichever tab is showing.
        guard let tallestForm = states.first(where: { $0.0 == tallest.0 })?.1 else {
            XCTFail("missing form for tallest state \(tallest.0)")
            return
        }
        let composedHeight = Self.measuredFittingHeight(ChromeProbe(machineTab: tallestForm))
        let chrome = composedHeight - tallest.1
        print("[MachineSettingsRenderTests] composed (chrome + \(tallest.0) form) fitting height: \(composedHeight)pt")
        print("[MachineSettingsRenderTests] chrome (tab bar + spacing + footer): \(chrome)pt")
        print("[MachineSettingsRenderTests] tallest form (\(tallest.1)pt) + chrome (\(chrome)pt) = \(tallest.1 + chrome)pt")

        for (name, form) in states {
            let height = measured.first { $0.0 == name }!.1
            try autoreleasepool {
                guard let png = Self.renderPNG(form.frame(width: 600, height: height), height: height) else {
                    XCTFail("render failed for \(name)")
                    return
                }
                try png.write(to: dir.appendingPathComponent("machine-tab-\(name).png"))
            }
        }
    }

    /// Structural clone of `SettingsView.body`'s non-form chrome — the
    /// `VStack(spacing: 8) { TabView { ... }; versionFooter.padding(.bottom, 12) }`
    /// wrapper — parameterized on the Machine tab's content so the *real*
    /// `MachineSettingsForm` for a given state can be measured inside it. Kept
    /// modifier-for-modifier identical to `SettingsView.body` (same VStack
    /// spacing, same three `tabItem`s, same footer font/padding) so the
    /// measured chrome matches the real window; the Account/Privacy tabs are
    /// stand-ins since their content doesn't affect the Machine tab's chrome
    /// (the tab bar's height is fixed by AppKit regardless of which tab is
    /// selected or what the other tabs contain).
    private struct ChromeProbe<MachineTab: View>: View {
        let machineTab: MachineTab

        var body: some View {
            VStack(spacing: 8) {
                TabView(selection: .constant(1)) {
                    Color.clear
                        .tabItem { Label("Account", systemImage: "person.circle") }
                        .tag(0)
                    machineTab
                        .tabItem { Label("Machine", systemImage: "dial.medium") }
                        .tag(1)
                    Color.clear
                        .tabItem { Label("Privacy", systemImage: "hand.raised") }
                        .tag(2)
                }
                Text("Pronto 0.0.0")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 12)
            }
        }
    }

    /// Reads the `NSHostingView`'s ideal height for `view` fixed at `width`
    /// (min 200, matching the render floor below). Same real-window
    /// requirement as `renderPNG` — a grouped `Form` is List-backed and
    /// doesn't lay out (or report a correct `fittingSize`) without being
    /// attached to a real window — so this shares that workaround, just with
    /// a generously tall initial frame (2000pt) so no row is clipped out of
    /// the layout pass before `fittingSize` is read.
    @MainActor
    private static func measuredFittingHeight<V: View>(_ view: V, width: CGFloat = 600) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let height = hosting.fittingSize.height
        window.orderOut(nil)
        window.contentView = nil
        return max(height, 200)
    }

    /// `ImageRenderer` alone produces a blank image for `.formStyle(.grouped)`
    /// content: a grouped `Form` is List-backed, and List/Table content doesn't
    /// lay out its rows without being attached to a real window (verified with a
    /// throwaway repro — `ImageRenderer` on a bare `Form { Section {...} }
    /// .formStyle(.grouped)` renders blank, while the same content hosted in a
    /// real (offscreen, borderless) `NSWindow` renders correctly). So route
    /// through an actual window instead of `ImageRenderer`.
    @MainActor
    private static func renderPNG<V: View>(_ view: V, width: CGFloat = 600, height: CGFloat = 500) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Give the List/Form a runloop turn to finish laying out its rows.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            return nil
        }
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.orderOut(nil)
        window.contentView = nil
        return bitmap.representation(using: .png, properties: [:])
    }
}
