import Foundation

/// One wine identity from the Liv-ex LWIN reference database.
///
/// LWIN (Liv-ex Wine Identification Number) is the wine world's ISBN: a 7-digit
/// code identifies the *wine* (producer + brand/vineyard). Longer codes append
/// vintage (LWIN11), then pack/bottle size (LWIN16/18). We key on the 7-digit
/// wine identity and compose the vintage ourselves (`LWINMatcher.lwin11`).
struct LWINRecord: Identifiable, Equatable, Hashable {
    let lwin7: String
    let displayName: String
    let producerName: String
    let wine: String
    let country: String
    let region: String
    let colour: String       // Red / White / Rosé / …
    let type: String         // Still / Sparkling / Fortified / …
    let firstVintage: Int?
    let finalVintage: Int?

    var id: String { lwin7 }

    /// Best human label, falling back to producer + cuvée if DISPLAY_NAME is blank.
    var title: String {
        if !displayName.isEmpty { return displayName }
        return [producerName, wine].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
