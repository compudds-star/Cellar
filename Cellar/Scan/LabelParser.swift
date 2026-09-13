import Foundation

/// Best-guess structured fields extracted from the raw text lines OCR'd off a
/// label. Everything is a guess the user confirms/edits — the parser never
/// blocks saving, it just pre-fills the Add form.
struct ParsedLabel: Equatable {
    var producer: String = ""
    var name: String = ""
    var vintage: Int? = nil
    var varietal: String = ""
    var region: String = ""
    var country: String = ""
    var type: WineType = .red
    /// The raw recognized lines, kept so the user can see what was read.
    var rawLines: [String] = []
}

/// Deterministic, dependency-free heuristics over OCR text. Pure function →
/// fully unit-testable without a camera. This is intentionally conservative:
/// it fills what it is confident about and leaves the rest blank.
enum LabelParser {

    // Common grape varietals (lowercased match). Extend freely.
    static let varietals: [String] = [
        "cabernet sauvignon", "cabernet franc", "sauvignon blanc", "pinot noir",
        "pinot grigio", "pinot gris", "chardonnay", "merlot", "syrah", "shiraz",
        "grenache", "malbec", "tempranillo", "sangiovese", "nebbiolo", "zinfandel",
        "riesling", "gewürztraminer", "gewurztraminer", "viognier", "chenin blanc",
        "gamay", "barbera", "montepulciano", "grüner veltliner", "gruner veltliner",
        "petite sirah", "mourvèdre", "mourvedre", "carmenère", "carmenere", "albariño",
        "albarino", "vermentino", "sémillon", "semillon", "petit verdot"
    ]

    // Region → country map for the regions we recognize on labels.
    static let regionCountry: [String: String] = [
        "napa valley": "USA", "sonoma": "USA", "willamette valley": "USA",
        "paso robles": "USA", "russian river": "USA", "finger lakes": "USA",
        "bordeaux": "France", "burgundy": "France", "bourgogne": "France",
        "champagne": "France", "rhône": "France", "rhone": "France",
        "châteauneuf-du-pape": "France", "chateauneuf-du-pape": "France",
        "sancerre": "France", "chablis": "France", "beaujolais": "France",
        "alsace": "France", "loire": "France", "provence": "France",
        "tuscany": "Italy", "toscana": "Italy", "piedmont": "Italy", "piemonte": "Italy",
        "barolo": "Italy", "barbaresco": "Italy", "chianti": "Italy", "veneto": "Italy",
        "brunello di montalcino": "Italy", "prosecco": "Italy",
        "rioja": "Spain", "ribera del duero": "Spain", "priorat": "Spain",
        "rías baixas": "Spain", "rias baixas": "Spain", "cava": "Spain",
        "douro": "Portugal", "mosel": "Germany", "rheingau": "Germany",
        "mendoza": "Argentina", "maipo": "Chile", "colchagua": "Chile",
        "barossa valley": "Australia", "margaret river": "Australia",
        "marlborough": "New Zealand", "central otago": "New Zealand",
        "stellenbosch": "South Africa"
    ]

    static func parse(lines rawLines: [String]) -> ParsedLabel {
        var result = ParsedLabel()
        result.rawLines = rawLines

        let cleaned = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joinedLower = cleaned.joined(separator: " ").lowercased()

        // Vintage: a 4-digit year in a plausible range. Non-vintage stays nil.
        result.vintage = findVintage(in: cleaned)

        // Varietal.
        if let v = varietals.first(where: { joinedLower.contains($0) }) {
            result.varietal = titleCased(v)
            result.type = wineType(forVarietal: v)
        }

        // Region + country.
        if let (region, country) = regionCountry.first(where: { joinedLower.contains($0.key) }) {
            result.region = titleCased(region)
            result.country = country
        }

        // Sparkling / rosé hints override the varietal-derived type.
        if joinedLower.contains("champagne") || joinedLower.contains("brut")
            || joinedLower.contains("prosecco") || joinedLower.contains("spumante")
            || joinedLower.contains("cava") || joinedLower.contains("sparkling") {
            result.type = .sparkling
        } else if joinedLower.contains("rosé") || joinedLower.contains("rose ")
            || joinedLower.contains(" rosato") {
            result.type = .rose
        }

        // Producer / name: the two longest all-caps-ish lines that aren't the
        // vintage or an obvious volume/ABV line are the best candidates for the
        // brand and cuvée. First becomes producer, second becomes name.
        let nameCandidates = cleaned.filter { line in
            let l = line.lowercased()
            let isYear = Int(line) != nil && line.count == 4
            let isMeta = l.contains("ml") || l.contains("alc") || l.contains("vol")
                || l.contains("%") || l.contains("750") || l.contains("product of")
            return !isYear && !isMeta && line.count >= 3
        }
        if let first = nameCandidates.first { result.producer = first }
        if nameCandidates.count > 1 { result.name = nameCandidates[1] }

        return result
    }

    // MARK: - Helpers

    static func findVintage(in lines: [String]) -> Int? {
        let currentYear = Calendar.current.component(.year, from: .now)
        let pattern = try? NSRegularExpression(pattern: "\\b(19\\d{2}|20\\d{2})\\b")
        for line in lines {
            guard let re = pattern else { break }
            let range = NSRange(line.startIndex..., in: line)
            for m in re.matches(in: line, range: range) {
                if let r = Range(m.range, in: line), let year = Int(line[r]),
                   year >= 1900, year <= currentYear + 1 {
                    return year
                }
            }
        }
        return nil
    }

    static func wineType(forVarietal v: String) -> WineType {
        let whites: Set<String> = [
            "sauvignon blanc", "chardonnay", "pinot grigio", "pinot gris", "riesling",
            "gewürztraminer", "gewurztraminer", "viognier", "chenin blanc",
            "grüner veltliner", "gruner veltliner", "albariño", "albarino",
            "vermentino", "sémillon", "semillon"
        ]
        return whites.contains(v) ? .white : .red
    }

    static func titleCased(_ s: String) -> String {
        s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
