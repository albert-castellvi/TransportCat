import Foundation

/// Operator-agnostic map content (spec S11).
///
/// FGC is the first mode to expose what it draws as plain values, so the future
/// global mode can compose several operators without knowing their state
/// classes. Metro and bus keep their own models until they migrate.
struct MapLineLayer: Identifiable, Equatable {
    /// Stable identity of the layer, unique across operators.
    let id: String
    /// Operator name (for example "FGC").
    let `operator`: String
    /// Line code as the operator publishes it, after any alias resolution.
    let code: String
    /// Line colour as a hex string without `#`.
    let colorHex: String
    /// Colour of text drawn on top of `colorHex`, hex without `#`.
    let textColorHex: String
    /// Ordered polylines of the line's physical route. Empty when the source
    /// has no shape.
    let polylines: [[GeoPoint]]
}

/// One live vehicle on the map, independent of its operator (spec S11).
struct MapVehicle: Identifiable, Equatable {
    /// Stable identity across polls, so the marker can glide instead of being
    /// replaced.
    let id: String
    /// Line the vehicle belongs to, as the line chips label it.
    let lineCode: String
    /// Colour of the marker, matching its line.
    let colorHex: String
    /// Drawn position: snapped to the line when the GPS point belongs to it.
    let position: GeoPoint
    /// Direction of travel in degrees clockwise from north.
    let heading: Double
    /// Short text shown next to the marker (usually the destination).
    let label: String
}
