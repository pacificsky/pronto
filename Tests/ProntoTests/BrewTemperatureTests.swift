import XCTest
@testable import Pronto

/// The brew-temperature stepper's arithmetic: values must stay inside the
/// machine-reported bounds and land on the step grid, and the display string
/// pairs machine-native °C with a whole-degree °F hint.
final class BrewTemperatureTests: XCTestCase {

    func testClampsBelowMin() {
        XCTAssertEqual(BrewTemperature.clamped(80, min: 85, max: 104, step: 0.5), 85)
    }

    func testClampsAboveMax() {
        XCTAssertEqual(BrewTemperature.clamped(110, min: 85, max: 104, step: 0.5), 104)
    }

    func testSnapsToStepGridAnchoredAtMin() {
        XCTAssertEqual(BrewTemperature.clamped(94.3, min: 85, max: 104, step: 0.5), 94.5)
    }

    func testOnGridValuePassesThrough() {
        XCTAssertEqual(BrewTemperature.clamped(94.0, min: 85, max: 104, step: 0.5), 94.0)
    }

    func testSnapNeverExceedsMax() {
        // Grid anchored at min can overshoot max after rounding; must re-clamp.
        XCTAssertEqual(BrewTemperature.clamped(103.9, min: 85, max: 104.1, step: 0.5), 104.0)
    }

    func testZeroStepOnlyClamps() {
        XCTAssertEqual(BrewTemperature.clamped(94.3, min: 85, max: 104, step: 0), 94.3)
    }

    func testDisplayShowsCelsiusWithFahrenheitHint() {
        // 94 °C = 201.2 °F → whole-degree hint.
        XCTAssertEqual(BrewTemperature.display(celsius: 94.0), "94.0 °C · 201 °F")
    }

    func testDisplayKeepsOneCelsiusDecimal() {
        XCTAssertEqual(BrewTemperature.display(celsius: 94.5), "94.5 °C · 202 °F")
    }
}
