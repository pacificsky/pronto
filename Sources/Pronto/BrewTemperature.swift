import Foundation

/// Pure arithmetic + formatting for the brew-temperature stepper. The machine
/// reports its own `min`/`max`/`step` (cloud dashboard widget), so the UI never
/// invents bounds; this type keeps values inside them and on the step grid.
/// Free of UI and controller state so it's unit-testable.
enum BrewTemperature {
    /// Clamp `value` into `min...max`, snapped onto the step grid anchored at
    /// `min`. The grid can overshoot `max` after rounding, so re-clamp at the end.
    static func clamped(_ value: Double, min: Double, max: Double, step: Double) -> Double {
        guard min <= max else { return value }
        let bounded = Swift.min(Swift.max(value, min), max)
        guard step > 0 else { return bounded }
        let steps = ((bounded - min) / step).rounded()
        return Swift.min(min + steps * step, max)
    }

    /// Display string for the control: machine-native °C with one decimal, plus
    /// a whole-degree °F hint — e.g. `94.0 °C · 201 °F`.
    static func display(celsius: Double) -> String {
        let fahrenheit = celsius * 9 / 5 + 32
        return String(format: "%.1f °C · %.0f °F", celsius, fahrenheit)
    }
}
