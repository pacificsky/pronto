import XCTest
import Observation
@testable import Pronto

/// The Machine-tab command surface. No cloud device is attached in unit tests,
/// so these cover the observable state machine around the debounce: pending
/// value publishes immediately (stepper feels instant), re-queues supersede,
/// and the debounced send clears the pending value even with no device.
@MainActor
final class MachineSettingsControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MachineController.brewTemperatureDebounce = .milliseconds(50)
    }

    override func tearDown() {
        MachineController.brewTemperatureDebounce = .seconds(1)
        super.tearDown()
    }

    func testQueueBrewTemperaturePublishesPendingImmediately() {
        let controller = MachineController()

        var observationFired = false
        withObservationTracking {
            _ = controller.pendingBrewTarget
        } onChange: {
            observationFired = true
        }

        controller.queueBrewTemperature(94.5)
        XCTAssertTrue(observationFired, "SwiftUI must re-render the stepper on queue")
        XCTAssertEqual(controller.pendingBrewTarget, 94.5)
    }

    func testRequeueSupersedesPendingValue() {
        let controller = MachineController()
        controller.queueBrewTemperature(94.5)
        controller.queueBrewTemperature(95.0)
        XCTAssertEqual(controller.pendingBrewTarget, 95.0)
    }

    func testDebouncedSendClearsPendingWithoutDevice() async throws {
        let controller = MachineController()
        controller.queueBrewTemperature(94.5)
        // Debounce is 50 ms in tests; give the send task ample slack.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(controller.pendingBrewTarget)
    }

    func testSettingsAreNilWhenNotConnected() {
        let controller = MachineController()
        XCTAssertNil(controller.brewBoilerSetting)
        XCTAssertNil(controller.steamBoilerSetting)
    }
}
