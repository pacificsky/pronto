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
