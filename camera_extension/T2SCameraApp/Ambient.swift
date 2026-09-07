import Foundation

/// The air the camera is looking through, and what follows from it.
///
/// These are not decoration. The radiometric model uses air temperature and
/// humidity to work out how much of the signal the air itself contributed,
/// and they are among the parameters committed to the camera. They also give
/// the dew point, which is the number that matters when you are looking for
/// damp rather than for heat.
struct Ambient: Equatable {
    var airTemp: Double = 20
    /// Relative humidity, in percent.
    var humidity: Double = 50
    var reflectedTemp: Double = 20
    /// Metres to the subject. The model clamps this at 20.
    var distance: Double = 1

    /// Dew point in Celsius, by the Magnus formula.
    ///
    /// A surface at or below this pulls water out of the air. Building
    /// inspection is largely the hunt for those surfaces: condensation forms
    /// there first, and mould follows. The constants are the usual ones for
    /// the range a room lives in; outside roughly -45 to 60C they drift.
    ///
    /// Below freezing this is the dew point over water, not the frost point
    /// over ice, which sits about a degree higher. For hunting condensation
    /// indoors the distinction does not arise.
    var dewPoint: Double {
        let b = 17.62, c = 243.12
        let rh = Swift.min(Swift.max(humidity, 1), 100)
        let gamma = log(rh / 100) + (b * airTemp) / (c + airTemp)
        return c * gamma / (b - gamma)
    }
}
