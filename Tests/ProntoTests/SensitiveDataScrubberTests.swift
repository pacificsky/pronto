import XCTest
import Sentry
@testable import Pronto

/// Proves the privacy guarantee: a Sentry event seeded with account/machine data
/// in every field comes out with none of it — neither registered literals nor
/// pattern-matched values survive into the serialized payload that would be sent.
final class SensitiveDataScrubberTests: XCTestCase {

    private let email = "secret.user@example.com"
    private let serial = "LM998877"
    private let machineName = "Kitchen Micra"

    /// Recursively concatenate every value (and key) of a serialized event so a
    /// leak in *any* field fails the test, not just the ones we thought to check.
    private func dump(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let arr as [Any]: return arr.map(dump).joined(separator: "\n")
        case let dict as [String: Any]:
            return dict.map { "\($0)=\(dump($1))" }.joined(separator: "\n")
        default: return String(describing: value)
        }
    }

    func testScrubsRegisteredDataFromEveryEventField() {
        let scrubber = SensitiveDataScrubber()
        scrubber.register([email, serial, machineName])

        let event = Event()
        event.message = SentryMessage(formatted: "crash while talking to \(email)")
        let exception = Exception(value: "Auth failed for \(email) on \(serial)", type: "NSException")
        event.exceptions = [exception]

        let crumb = Breadcrumb()
        crumb.message = "GET /things/\(serial)/dashboard"
        crumb.data = ["url": "https://gw.lamarzocco.io/things/\(serial)/dashboard",
                      "account": email]
        event.breadcrumbs = [crumb]

        event.extra = ["account": email, "serial": serial, "machine": machineName]
        event.tags = ["serial": serial]
        event.serverName = "Aakash's MacBook"
        event.user = { let u = User(); u.email = email; return u }()

        let scrubbed = scrubber.scrub(event)
        let blob = dump(scrubbed.serialize())

        XCTAssertFalse(blob.contains(email), "email leaked: \(blob)")
        XCTAssertFalse(blob.contains(serial), "serial leaked: \(blob)")
        XCTAssertFalse(blob.contains(machineName), "machine name leaked: \(blob)")
        XCTAssertTrue(blob.contains(SensitiveDataScrubber.placeholder), "nothing was redacted")
        // Identity fields are dropped outright.
        XCTAssertNil(scrubbed.user)
        XCTAssertNil(scrubbed.serverName)
    }

    func testScrubsUnregisteredValuesByPattern() {
        let scrubber = SensitiveDataScrubber() // nothing registered
        let out = scrubber.redact("contact me@foo.io about machine MR123456 now")
        XCTAssertFalse(out.contains("me@foo.io"), out)
        XCTAssertFalse(out.contains("MR123456"), out)
    }

    func testResetForgetsRegisteredLiterals() {
        let scrubber = SensitiveDataScrubber()
        scrubber.register([machineName]) // not pattern-matchable, only literal
        XCTAssertFalse(scrubber.redact("at \(machineName)").contains(machineName))
        scrubber.reset()
        XCTAssertTrue(scrubber.redact("at \(machineName)").contains(machineName))
    }
}
