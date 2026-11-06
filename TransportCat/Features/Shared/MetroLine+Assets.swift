import Foundation

extension MetroLine {
    /// Lowercased asset key shared by the `train-`, `badge-`, `station-` and
    /// `terminal-` image sets produced by `scripts/render-assets.sh` (S7):
    /// "L9N" is `badge-l9n`, "FM" is `train-fm`.
    var assetKey: String { displayName.lowercased() }
}
