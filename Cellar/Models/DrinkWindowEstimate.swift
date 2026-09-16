import Foundation

/// The years a wine is typically at its best, counted from its vintage.
struct DrinkWindow: Equatable {
    let from: Int
    let to: Int

    /// "2024–2038", for a label next to the bottle's own window.
    var label: String { "\(from)–\(to)" }

    func contains(_ year: Int) -> Bool { year >= from && year <= to }
}

/// Estimates a drinking window from the vintage and what we know about the wine.
///
/// This is a rule of thumb, not a critic's call: an average bottle of the style,
/// stored reasonably. Region wins over grape (a Napa Cabernet and a supermarket
/// Cabernet age differently), grape wins over the bare type, and everything is
/// a span in years added to the vintage. Non-vintage wines and spirits get no
/// window — there's no vintage to count from, and spirits don't age in glass.
enum DrinkWindowEstimate {

    /// Years after the vintage: `start` = drink from, `end` = drink by.
    private struct Span {
        let start: Int
        let end: Int
    }

    static func window(for wine: Wine) -> DrinkWindow? {
        window(vintage: wine.vintage,
               type: wine.type,
               varietal: wine.varietal,
               region: wine.region,
               country: wine.country)
    }

    static func window(vintage: Int?,
                       type: WineType,
                       varietal: String = "",
                       region: String = "",
                       country: String = "") -> DrinkWindow? {
        guard let vintage, vintage > 1800, !type.isSpirit else { return nil }
        let span = span(type: type, varietal: varietal, region: region, country: country)
        return DrinkWindow(from: vintage + span.start, to: vintage + span.end)
    }

    // MARK: - Rules

    /// Classed-growth Bordeaux, Barolo and vintage Port age for decades; most
    /// whites and rosés don't. Keys are matched against the region, the country
    /// and the appellation text, longest first so "Napa Valley" beats "Napa".
    private static let regionSpans: [String: Span] = [
        "pauillac": Span(start: 8, end: 30),
        "margaux": Span(start: 8, end: 30),
        "saint-julien": Span(start: 8, end: 30),
        "saint-estephe": Span(start: 8, end: 30),
        "saint-émilion": Span(start: 6, end: 25),
        "pomerol": Span(start: 6, end: 25),
        "bordeaux": Span(start: 5, end: 20),
        "napa valley": Span(start: 5, end: 20),
        "sonoma": Span(start: 3, end: 12),
        "barolo": Span(start: 8, end: 30),
        "barbaresco": Span(start: 6, end: 25),
        "brunello": Span(start: 8, end: 30),
        "montalcino": Span(start: 8, end: 30),
        "chianti": Span(start: 3, end: 12),
        "rioja": Span(start: 4, end: 18),
        "ribera del duero": Span(start: 5, end: 20),
        "côte de nuits": Span(start: 5, end: 20),
        "côte d'or": Span(start: 4, end: 15),
        "burgundy": Span(start: 4, end: 15),
        "bourgogne": Span(start: 4, end: 15),
        "chablis": Span(start: 3, end: 12),
        "champagne": Span(start: 3, end: 15),
        "hermitage": Span(start: 8, end: 25),
        "côte-rôtie": Span(start: 6, end: 22),
        "châteauneuf-du-pape": Span(start: 5, end: 20),
        "rhône": Span(start: 4, end: 15),
        "sauternes": Span(start: 5, end: 30),
        "douro": Span(start: 10, end: 40),
        "porto": Span(start: 10, end: 40),
        "mosel": Span(start: 3, end: 20),
        "rheingau": Span(start: 3, end: 20),
        "barossa": Span(start: 4, end: 18),
        "mendoza": Span(start: 3, end: 12),
        "marlborough": Span(start: 1, end: 4),
    ]

    private static let varietalSpans: [String: Span] = [
        "cabernet sauvignon": Span(start: 5, end: 20),
        "cabernet franc": Span(start: 4, end: 15),
        "nebbiolo": Span(start: 8, end: 30),
        "sangiovese": Span(start: 4, end: 15),
        "syrah": Span(start: 4, end: 15),
        "shiraz": Span(start: 4, end: 15),
        "tempranillo": Span(start: 4, end: 15),
        "petite sirah": Span(start: 4, end: 15),
        "merlot": Span(start: 3, end: 12),
        "malbec": Span(start: 3, end: 12),
        "pinot noir": Span(start: 3, end: 12),
        "grenache": Span(start: 3, end: 12),
        "zinfandel": Span(start: 2, end: 8),
        "gamay": Span(start: 1, end: 5),
        "riesling": Span(start: 3, end: 15),
        "chenin blanc": Span(start: 3, end: 15),
        "sémillon": Span(start: 3, end: 15),
        "chardonnay": Span(start: 2, end: 8),
        "viognier": Span(start: 1, end: 4),
        "sauvignon blanc": Span(start: 1, end: 4),
        "pinot grigio": Span(start: 1, end: 3),
        "pinot gris": Span(start: 1, end: 3),
    ]

    private static let typeSpans: [WineType: Span] = [
        .red: Span(start: 2, end: 8),
        .white: Span(start: 1, end: 4),
        .rose: Span(start: 0, end: 2),
        .orange: Span(start: 1, end: 5),
        .sparkling: Span(start: 2, end: 10),
        .dessert: Span(start: 5, end: 25),
        .fortified: Span(start: 10, end: 40),
    ]

    private static func span(type: WineType, varietal: String, region: String, country: String) -> Span {
        let haystack = [region, country].joined(separator: " ").folded
        if let hit = longestMatch(in: haystack, among: regionSpans) { return hit }
        if let hit = longestMatch(in: varietal.folded, among: varietalSpans) { return hit }
        return typeSpans[type] ?? Span(start: 1, end: 5)
    }

    /// Most specific key wins, so "cabernet sauvignon" beats "cabernet franc"
    /// on a label that happens to print both.
    private static func longestMatch(in text: String, among table: [String: Span]) -> Span? {
        guard !text.isEmpty else { return nil }
        return table.keys
            .filter { text.contains($0.folded) }
            .max { $0.count < $1.count }
            .flatMap { table[$0] }
    }
}

private extension String {
    /// Lowercased and accent-insensitive, so "Côte-Rôtie" matches "cote-rotie".
    var folded: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
