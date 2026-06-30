import Foundation
import Sentry

/// Opt-in crash reporting via Sentry, configured so **no user-private data ever
/// leaves the device** — not the La Marzocco account (email/password) nor machine
/// information (serials, names, live status).
///
/// The guarantee is layered:
///  1. **Minimize collection.** Sentry's defaults gather data that, in Pronto, *is*
///     the private data — network breadcrumbs carry request URLs (LM URLs embed the
///     serial), failed-request capture carries the same, a screenshot of Settings
///     would show the password field. All of that is disabled in `start()`.
///  2. **Scrub what's left.** `beforeSend`/`beforeBreadcrumb` route every outgoing
///     event and breadcrumb through ``SensitiveDataScrubber`` — the last line of
///     defense, and the one that runs even on native crashes (serialized and sent
///     on next launch).
///  3. **Opt-in + no DSN by default.** Reporting starts only when the user enables
///     it *and* a DSN is baked into the bundle. Local/dev builds ship no DSN, so
///     Sentry never initializes there.
enum CrashReporting {
    /// DSN baked into the bundle at build time (`make-app.sh` writes `SentryDSN`
    /// from the `SENTRY_DSN` env var). Absent/empty in dev builds → reporting off.
    private static var dsn: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Start Sentry if the user has opted in. Called once at launch.
    static func startIfEnabled() {
        guard Persistence.crashReportingEnabled else { return }
        start()
    }

    /// Toggle reporting at runtime (from the Settings switch). Persists the choice
    /// and starts/stops the SDK so the change takes effect without a relaunch.
    static func setEnabled(_ enabled: Bool) {
        Persistence.crashReportingEnabled = enabled
        if enabled { start() } else { SentrySDK.close() }
    }

    private static func start() {
        guard let dsn else { return } // no DSN baked in → nothing to start
        let scrubber = SensitiveDataScrubber.shared
        SentrySDK.start { o in
            o.dsn = dsn

            // — Privacy: never attach personal data —
            o.sendDefaultPii = false        // no IP / user identifiers
            // (attachScreenshot / attachViewHierarchy are iOS-only and would
            // capture the password field — they don't exist on the macOS SDK, so
            // there's nothing to capture here. Kept off by their absence.)

            // — Privacy: kill collectors that, for Pronto, gather private data —
            // LM request URLs embed the machine serial (…/things/{serial}/…), so
            // any network-derived breadcrumb or captured request leaks it.
            o.enableNetworkBreadcrumbs = false
            o.enableNetworkTracking = false
            o.enableCaptureFailedRequests = false
            o.enableSwizzling = false       // disables auto network/UI breadcrumbs
            o.enableAutoSessionTracking = false
            // (device name — "<name>'s MacBook" — rides on the event as
            // `serverName`; the scrubber nulls it on every outgoing event.)

            // — Privacy: scrub anything that still makes it into an event —
            o.beforeBreadcrumb = { crumb in scrubber.scrub(crumb) }
            o.beforeSend = { event in scrubber.scrub(event) }
        }
    }
}
