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

        for (name, form) in states {
            try autoreleasepool {
                guard let png = Self.renderPNG(form.frame(width: 600, height: 500)) else {
                    XCTFail("render failed for \(name)")
                    return
                }
                try png.write(to: dir.appendingPathComponent("machine-tab-\(name).png"))
            }
        }
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
