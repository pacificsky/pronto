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
            // in standby, and a cup with an exclamation badge when the machine
            // itself is offline from the cloud.
            if controller.isMachineOffline {
                Image(nsImage: Self.offlineMenuBarImage)
            } else {
                Image(systemName: menuBarSymbol)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }

    /// Outline cup with a small exclamation badge at the top-right — "machine
    /// offline". Composed by hand because no `cup.and.saucer.badge.exclamationmark`
    /// SF Symbol exists; drawn as a template image so the menu bar renders it
    /// correctly in light/dark/monochrome.
    static let offlineMenuBarImage: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy)
        guard
            let cup = NSImage(systemSymbolName: "cup.and.saucer",
                              accessibilityDescription: "Machine offline")?
                .withSymbolConfiguration(config),
            let badge = NSImage(systemSymbolName: "exclamationmark",
                                accessibilityDescription: nil)?
                .withSymbolConfiguration(badgeConfig)
        else {
            // Both symbols ship with macOS 11+; if resolution somehow fails,
            // fall back to the plain outline cup rather than crash.
            return NSImage(systemSymbolName: "cup.and.saucer",
                           accessibilityDescription: "Machine offline") ?? NSImage()
        }
        let size = NSSize(width: cup.size.width + 2, height: cup.size.height + 4)
        let image = NSImage(size: size, flipped: false) { _ in
            cup.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            badge.draw(at: NSPoint(x: size.width - badge.size.width,
                                   y: size.height - badge.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }()

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
        // Release-safe: only crashes when launched with `-SentryCrashTest YES` and
        // crash reporting is active — used to validate symbolication on a shipped
        // build. No-op for normal launches.
        CrashReporting.fireCrashTestIfRequested()
        // Bring the cloud connection (and live websocket) up at launch and keep it
        // for the app's lifetime — not gated on the popover appearing.
        MainActor.assumeIsolated { MachineController.shared.bootstrap() }
    }
}
