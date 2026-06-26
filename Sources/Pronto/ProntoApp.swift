import SwiftUI
import AppKit

@main
struct ProntoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = MachineController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(controller)
        } label: {
            // Filled + green when on, outline + neutral when off — glanceable at a
            // glance. The fill/outline difference survives even if the menu bar
            // templates the tint to monochrome; the color is the bonus signal.
            Image(systemName: menuBarSymbol)
                .foregroundStyle(menuBarTint)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }

    /// Cup symbol reflecting the selected machine's power state.
    private var menuBarSymbol: String {
        controller.power.isOn ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    /// Icon tint, mirroring the in-popover status dot.
    private var menuBarTint: Color {
        switch controller.power {
        case .on: return .green
        case .other: return .yellow
        case .off, .unknown: return .primary
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pure menu-bar agent: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}
