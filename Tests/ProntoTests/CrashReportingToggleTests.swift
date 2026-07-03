import XCTest
import Observation
@testable import Pronto

/// Regression test for the Settings "Send anonymous crash reports" checkbox.
///
/// The Toggle binds to `MachineController.crashReportingEnabled`. SwiftUI only
/// re-renders the checkbox if setting that property fires Observation — which the
/// `@Observable` macro guarantees for stored properties but NOT for computed ones
/// that read UserDefaults directly. When observation doesn't fire, the click still
/// persists but the checkbox visually snaps back, appearing dead.
@MainActor
final class CrashReportingToggleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Persistence.crashReportingEnabled = false
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "crashReportingEnabled")
        super.tearDown()
    }

    /// Mirrors what SwiftUI does: track the property during body evaluation, then
    /// mutate it (the Toggle's binding set). The change must be observed, or the
    /// Settings view never re-renders and the checkbox doesn't take.
    func testTogglingCrashReportingFiresObservation() {
        let controller = MachineController()
        XCTAssertFalse(controller.crashReportingEnabled)

        var observationFired = false
        withObservationTracking {
            _ = controller.crashReportingEnabled
        } onChange: {
            observationFired = true
        }

        controller.crashReportingEnabled = true

        XCTAssertTrue(observationFired,
                      "setting crashReportingEnabled must fire Observation, or the Settings checkbox never updates")
        XCTAssertTrue(controller.crashReportingEnabled, "the new value must read back")
        XCTAssertTrue(Persistence.crashReportingEnabled, "the choice must still persist to UserDefaults")
    }
}
