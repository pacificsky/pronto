import SwiftUI
import AppKit

@main
struct ProntoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = MachineController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(controller)
        } label: {
            // The menu bar renders this as a monochrome template image (tints are
            // dropped), so on/off is conveyed by markedly different glyphs:
            // a full cup when running vs a sleep symbol in standby.
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
        switch controller.power {
        case .on, .other: return "cup.and.saucer.fill" // running / brewing
        case .off: return "powersleep"                 // standby
        case .unknown: return "cup.and.saucer"         // not connected / unknown
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pure menu-bar agent: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}
