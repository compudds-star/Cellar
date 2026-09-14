import SwiftUI

// Shared with the CellarShare extension.

/// Wine styles and spirit categories. Stored by raw value, so adding cases never
/// needs a migration.
enum WineType: String, Codable, CaseIterable, Identifiable {
    case red, white, rose, sparkling, dessert, fortified, orange
    case whisky, brandy, rum, gin, vodka, tequila, liqueur, spirit
    case other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rose: return "Rosé"
        case .brandy: return "Brandy & Cognac"
        case .tequila: return "Tequila & Mezcal"
        case .spirit: return "Other spirit"
        default: return rawValue.capitalized
        }
    }
    /// Accent used for placeholder tiles and small type cues.
    var tint: Color {
        switch self {
        case .red, .fortified: return Color(red: 0.44, green: 0.08, blue: 0.18)
        case .white: return Color(red: 0.80, green: 0.70, blue: 0.35)
        case .rose: return Color(red: 0.90, green: 0.55, blue: 0.60)
        case .sparkling: return Color(red: 0.86, green: 0.74, blue: 0.42)
        case .dessert: return Color(red: 0.70, green: 0.45, blue: 0.18)
        case .orange: return Color(red: 0.85, green: 0.55, blue: 0.25)
        case .whisky: return Color(red: 0.72, green: 0.45, blue: 0.15)
        case .brandy: return Color(red: 0.55, green: 0.30, blue: 0.12)
        case .rum: return Color(red: 0.45, green: 0.25, blue: 0.10)
        case .gin: return Color(red: 0.35, green: 0.60, blue: 0.65)
        case .vodka: return Color(red: 0.55, green: 0.62, blue: 0.72)
        case .tequila: return Color(red: 0.62, green: 0.68, blue: 0.30)
        case .liqueur: return Color(red: 0.60, green: 0.25, blue: 0.45)
        case .spirit: return Color(red: 0.40, green: 0.40, blue: 0.45)
        case .other: return Color.gray
        }
    }

    /// Distilled spirits (vs. wine, fortified wine, sake, cider…).
    var isSpirit: Bool {
        switch self {
        case .whisky, .brandy, .rum, .gin, .vodka, .tequila, .liqueur, .spirit: return true
        default: return false
        }
    }
    static var wines: [WineType] { allCases.filter { !$0.isSpirit } }
    static var spirits: [WineType] { allCases.filter(\.isSpirit) }

    /// Type implied by an LWIN record's TYPE (as written by scripts/import_lwin.py:
    /// "Sparkling", "Fortified (Port)", "Spirit (Whiskies)", …) and COLOUR. Nil when
    /// the record doesn't say, so the caller keeps its current type.
    init?(lwinType: String, colour: String) {
        let t = lwinType.lowercased()
        let c = colour.lowercased()
        if t.contains("sparkling") { self = .sparkling }
        else if t.contains("fortified") { self = .fortified }
        else if t.contains("spirit") {
            if t.contains("whisk") { self = .whisky }
            else if ["brandy", "cognac", "armagnac"].contains(where: t.contains) { self = .brandy }
            else if t.contains("rum") { self = .rum }
            else if t.contains("gin") { self = .gin }
            else if t.contains("vodka") { self = .vodka }
            else if t.contains("tequila") || t.contains("mezcal") { self = .tequila }
            else if t.contains("liqueur") { self = .liqueur }
            else { self = .spirit }
        }
        else if ["cider", "sake", "vermouth"].contains(where: t.contains) { self = .other }
        else if c.contains("ros") { self = .rose }
        else if c.contains("white") { self = .white }
        else if c.contains("red") { self = .red }
        else { return nil }
    }
}
