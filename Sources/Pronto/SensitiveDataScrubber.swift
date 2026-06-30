import Foundation
import Sentry

/// Redacts user-private data from anything bound for Sentry. Two complementary
/// rules, applied to every string in an event or breadcrumb:
///
///  - **Literal** — exact values registered at runtime: the signed-in account
///    email and the known machine serials/names. Precise and authoritative.
///  - **Pattern** — anything email-shaped or serial-shaped, so a leak is caught
///    even before its value has been registered (or for values we never hold).
///
/// Thread-safe: Sentry invokes `beforeSend`/`beforeBreadcrumb` off the main thread.
final class SensitiveDataScrubber: @unchecked Sendable {
    static let shared = SensitiveDataScrubber()

    static let placeholder = "[redacted]"

    private let lock = NSLock()
    private var literals: [String] = []

    /// Email addresses (the account username).
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    /// La Marzocco serials: a two-letter model prefix + six or more digits
    /// (e.g. `LM012345`, `MR123456`). A backstop; registered literals are exact.
    private static let serialPattern = try! NSRegularExpression(
        pattern: #"\b[A-Z]{2}\d{6,}\b"#, options: [])

    // MARK: - Registration

    /// Register exact sensitive values to redact. Skips empties and very short
    /// strings (which would over-redact). Idempotent. Called as credentials and
    /// the machine list load.
    func register(_ values: [String?]) {
        let cleaned = values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }
        guard !cleaned.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for v in cleaned where !literals.contains(v) { literals.append(v) }
    }

    /// Forget all registered literals (on sign-out). Patterns still apply.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        literals.removeAll()
    }

    // MARK: - Redaction

    /// Replace every known literal and matching pattern in `string`.
    func redact(_ string: String) -> String {
        lock.lock()
        let lits = literals
        lock.unlock()

        var out = string
        // Longest-first so a serial contained in a longer value is handled by the
        // longer match first.
        for lit in lits.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: lit, with: Self.placeholder)
        }
        out = Self.replaceMatches(Self.emailPattern, in: out)
        out = Self.replaceMatches(Self.serialPattern, in: out)
        return out
    }

    private static func replaceMatches(_ re: NSRegularExpression, in s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: placeholder)
    }

    /// Recursively redact every `String` inside a JSON-ish value.
    private func redactAny(_ value: Any) -> Any {
        switch value {
        case let s as String: return redact(s)
        case let arr as [Any]: return arr.map(redactAny)
        case let dict as [String: Any]: return dict.mapValues(redactAny)
        default: return value
        }
    }

    private func redactDict(_ dict: [String: Any]) -> [String: Any] {
        dict.mapValues(redactAny)
    }

    // MARK: - Sentry hooks

    /// Scrub an outgoing event in place. Covers the message, every exception
    /// value, attached breadcrumbs, free-form `extra`/`context`/`tags`, and drops
    /// identity fields outright.
    func scrub(_ event: Event) -> Event {
        if let formatted = event.message?.formatted {
            event.message = SentryMessage(formatted: redact(formatted))
        }
        event.exceptions = event.exceptions?.map { exception in
            if let value = exception.value { exception.value = redact(value) }
            return exception
        }
        event.breadcrumbs = event.breadcrumbs?.compactMap { scrub($0) }
        if let extra = event.extra { event.extra = redactDict(extra) }
        if let context = event.context {
            event.context = context.mapValues { redactDict($0) }
        }
        if let tags = event.tags { event.tags = tags.mapValues { redact($0) } }
        // Identity fields are never useful to us and are pure PII — drop them.
        event.user = nil
        event.request = nil
        event.serverName = nil
        return event
    }

    /// Scrub a breadcrumb. Returns `nil` would drop it; we keep but redact.
    func scrub(_ crumb: Breadcrumb) -> Breadcrumb? {
        if let message = crumb.message { crumb.message = redact(message) }
        if let data = crumb.data { crumb.data = redactDict(data) }
        return crumb
    }
}
