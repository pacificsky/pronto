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

    /// Matches `SettingsView`'s window width, so what's rendered here is
    /// exactly what the real Machine tab lays out at (including its own
    /// `.settingsTabPadding()`, since `MachineSettingsForm.body` applies that
    /// itself).
    private static let windowWidth: CGFloat = 480

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

        // Every state has intrinsic height now (plain VStacks, no List-backed
        // Form), so — unlike the old fixed-440pt window — each state simply
        // renders at its own fitting height; there's no shared frame height
        // to reconcile across tabs/states anymore.
        for (name, form) in states {
            try autoreleasepool {
                let height = Self.measuredFittingHeight(form)
                print("[MachineSettingsRenderTests] \(name) form fitting height: \(height)pt")
                guard let png = Self.renderPNG(form, height: height) else {
                    XCTFail("render failed for \(name)")
                    return
                }
                try png.write(to: dir.appendingPathComponent("machine-tab-\(name).png"))
            }
        }
    }

    /// Reads the `NSHostingView`'s ideal height for `view` fixed at
    /// `windowWidth`. Hosted in a real (offscreen, borderless) `NSWindow`
    /// with a generously tall initial frame (2000pt) so no row is clipped
    /// out of the layout pass before `fittingSize` is read.
    @MainActor
    private static func measuredFittingHeight<V: View>(_ view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: windowWidth))
        hosting.frame = NSRect(x: 0, y: 0, width: windowWidth, height: 2000)
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

    /// Renders `view` at `windowWidth`×`height` via a real (offscreen,
    /// borderless) `NSWindow` + `NSHostingView`, rather than `ImageRenderer`
    /// directly — kept from the grouped-`Form` era, where `ImageRenderer`
    /// alone produced a blank image for List-backed content; this path is
    /// proven to work for both, so it stays even though the content is now
    /// plain `VStack`s with no List underneath.
    @MainActor
    private static func renderPNG<V: View>(_ view: V, height: CGFloat) -> Data? {
        // Top-align: the real window has no extra height beyond its content
        // (`fixedSize` sizes it exactly), so this only matters when a short
        // state's measured height is clamped up to the 200pt floor below —
        // without it, `.frame`'s default `.center` alignment would misleadingly
        // pad the mock symmetrically instead of matching production's
        // flush-to-top layout.
        let hosting = NSHostingView(rootView: view.frame(width: windowWidth, height: height, alignment: .top))
        hosting.frame = NSRect(x: 0, y: 0, width: windowWidth, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        // Give the view a runloop turn to finish laying out.
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
