import SwiftUI
import AppKit

@main
struct ProntoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = MachineController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(controller)
        } label: {
            // The menu bar renders this as a monochrome template image (tints are
            // dropped), so state is conveyed by markedly different glyphs:
            // a full cup when ready, a thermometer while heating, a sleep symbol
            // in standby.
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }

    /// Symbol reflecting the selected machine's power state. Distinct shapes
    /// (not just fill) so the state reads at a glance in monochrome.
    private var menuBarSymbol: String {
        // A command is in flight — the menu-bar label is a static template image,
        // so a real spinner can't animate here; an hourglass reads as "working".
        if controller.pendingTarget != nil { return "hourglass" }
        // On but still heating — a thermometer reads as "warming up" in monochrome,
        // distinct from the filled cup that means ready-to-brew.
        if controller.isWarmingUp { return "thermometer.medium" }
        switch controller.power {
        case .on, .other: return "cup.and.saucer.fill" // running / ready
        case .off: return "powersleep"                 // standby
        case .unknown: return "cup.and.saucer"         // not connected / unknown
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pure menu-bar agent: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        // Install the crash handler first (if the user opted in) so a crash during
        // bootstrap is still caught. No-op when reporting is off or no DSN is baked
        // into the build.
        CrashReporting.startIfEnabled()
        #if DEBUG
        CrashReporting.fireSelfTestIfRequested()
        #endif
        // Bring the cloud connection (and live websocket) up at launch and keep it
        // for the app's lifetime — not gated on the popover appearing.
        MainActor.assumeIsolated { MachineController.shared.bootstrap() }
    }
}
