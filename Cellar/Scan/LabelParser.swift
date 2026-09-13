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

/// One OCR'd line plus how big it was printed, so the parser can prefer the
/// most prominent text — producers and cuvées are set largest on a label.
struct LabelTextLine: Equatable {
    var text: String
    /// Line height as a fraction of the image (or view) height; 0 = unknown.
    var height: Double = 0
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

    /// Phrases that mark a line as boilerplate rather than a producer or cuvée.
    static let metaMarkers: [String] = [
        "ml", "alc", "vol", "%", "750", "product of", "produce of", "bottled by",
        "mis en bouteille", "imported by", "sulfite", "sulphite", "government warning",
        "contains", "appellation", "denominazione", "denominación", "estate bottled",
        "red wine", "white wine", "table wine", "vin rouge", "vin blanc", "vino rosso",
        "vino tinto", "www.", ".com", "scotch whisky", "single malt", "blended scotch",
        "straight bourbon", "proof"
    ]

    static func parse(lines rawLines: [String]) -> ParsedLabel {
        parse(textLines: rawLines.map { LabelTextLine(text: $0) })
    }

    static func parse(textLines: [LabelTextLine]) -> ParsedLabel {
        var result = ParsedLabel()
        result.rawLines = textLines.map(\.text)

        let cleaned = textLines
            .map { LabelTextLine(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), height: $0.height) }
            .filter { !$0.text.isEmpty }
        let texts = cleaned.map(\.text)
        let words = normalizedWords(texts.joined(separator: " "))
        let wordSet = Set(words)

        // Vintage: a 4-digit year in a plausible range. Non-vintage stays nil.
        result.vintage = findVintage(in: texts)

        // Varietal (tolerates small OCR slips).
        if let v = varietals.first(where: { matches(phrase: $0, in: words) }) {
            result.varietal = titleCased(v)
            result.type = wineType(forVarietal: v)
        }

        // Region + country. Most specific (longest) wins: "Châteauneuf-du-Pape" over "Rhône".
        let regions = regionCountry.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        if let region = regions.first(where: { matches(phrase: $0, in: words) }) {
            result.region = titleCased(region)
            result.country = regionCountry[region] ?? ""
        }

        // Sparkling / rosé hints override the varietal-derived type (whole words only).
        let sparkling: Set<String> = ["champagne", "brut", "prosecco", "spumante", "cava",
                                      "sparkling", "cremant", "sekt", "franciacorta"]
        let rose: Set<String> = ["rose", "rosado", "rosato"]
        if !wordSet.isDisjoint(with: sparkling) {
            result.type = .sparkling
        } else if !wordSet.isDisjoint(with: rose) {
            result.type = .rose
        }

        // Spirits override wine cues ("Grande Champagne Cognac" is brandy, not sparkling).
        if let spirit = spiritType(words: words, texts: texts) {
            result.type = spirit
        }

        // Producer / name: the most prominent lines that aren't the vintage,
        // boilerplate, or just the grape/region we already found. Labels print the
        // producer and cuvée largest, so rank by size; unknown sizes keep reading order.
        let candidates = cleaned.filter { line in
            let lower = line.text.lowercased()
            let lineWords = normalizedWords(line.text)
            let isNumeric = line.text.filter(\.isLetter).count < 2
            let isMeta = metaMarkers.contains { lower.contains($0) }
            let isFieldOnly = [result.varietal, result.region].contains { field in
                !field.isEmpty && normalizedWords(field).count == lineWords.count
                    && matches(phrase: field, in: lineWords)
            }
            return !isNumeric && !isMeta && !isFieldOnly && line.text.count >= 3
        }
        let ranked = candidates.enumerated()
            .sorted { $0.element.height != $1.element.height
                ? $0.element.height > $1.element.height : $0.offset < $1.offset }
            .map(\.element.text)
        if let first = ranked.first { result.producer = first }
        if ranked.count > 1 { result.name = ranked[1] }

        return result
    }

    /// Combines a still-photo read with what the live scanner saw. Photo lines
    /// come first (sharper, reliable sizes); live lines are added only when the
    /// photo missed them — e.g. text around the curve of the bottle — with size
    /// unknown so they never outrank the photo. No photo text → live lines as-is.
    static func mergeLines(photo: [LabelTextLine], live: [LabelTextLine]) -> [LabelTextLine] {
        guard !photo.isEmpty else { return live }
        let photoKeys = photo.map { normalizedWords($0.text).joined(separator: " ") }
        var out = photo
        for line in live {
            let key = normalizedWords(line.text).joined(separator: " ")
            guard !key.isEmpty, !photoKeys.contains(where: { $0.contains(key) }) else { continue }
            out.append(LabelTextLine(text: line.text, height: 0))
        }
        return out
    }

    // MARK: - Helpers

    static func findVintage(in lines: [String]) -> Int? {
        let currentYear = Calendar.current.component(.year, from: .now)
        // OCR often reads a zero as the letter O ("2O15").
        let pattern = try? NSRegularExpression(pattern: "\\b(19|2[0Oo])[0-9Oo]{2}\\b")
        // "Since 1902" / "Est. 1998" is the founding year, not the vintage.
        let founding: Set<String> = ["since", "est", "established", "founded", "depuis", "dal", "desde", "seit"]
        for line in lines {
            guard let re = pattern else { break }
            if !founding.isDisjoint(with: normalizedWords(line)) { continue }
            let range = NSRange(line.startIndex..., in: line)
            for m in re.matches(in: line, range: range) {
                guard let r = Range(m.range, in: line) else { continue }
                let digits = line[r].replacingOccurrences(of: "O", with: "0")
                    .replacingOccurrences(of: "o", with: "0")
                if let year = Int(digits), year >= 1900, year <= currentYear + 1 {
                    return year
                }
            }
        }
        return nil
    }

    /// Accent-folded, lowercased words (letters and digits only).
    static func normalizedWords(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// True if `phrase` appears in `words`, allowing typical OCR slips: words of
    /// 6–8 letters may be one edit off, 9+ letters two. Words of 5 letters or
    /// fewer must match exactly, so "cava" doesn't fire on "casa" or "syrah" on "sarah".
    static func matches(phrase: String, in words: [String]) -> Bool {
        let target = normalizedWords(phrase)
        guard !target.isEmpty, words.count >= target.count else { return false }
        for start in 0...(words.count - target.count) {
            var ok = true
            for (i, t) in target.enumerated() {
                let w = words[start + i]
                guard w != t else { continue }
                let allowed = t.count <= 5 ? 0 : (t.count >= 9 ? 2 : 1)
                if allowed == 0 || editDistance(w, t, limit: allowed) > allowed { ok = false; break }
            }
            if ok { return true }
        }
        return false
    }

    /// Levenshtein distance, bailing out once it exceeds `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            var rowMin = cur[0]
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            prev = cur
        }
        return prev[b.count]
    }

    /// Spirit category from style words on the label, else "some spirit" when the
    /// stated strength is spirit-level (wine tops out around 22%).
    static func spiritType(words: [String], texts: [String]) -> WineType? {
        let set = Set(words)
        if !set.isDisjoint(with: ["whisky", "whiskey", "scotch", "bourbon"])
            || matches(phrase: "single malt", in: words) { return .whisky }
        if !set.isDisjoint(with: ["cognac", "armagnac", "brandy", "calvados", "pisco"]) { return .brandy }
        if !set.isDisjoint(with: ["rum", "rhum"]) { return .rum }
        if set.contains("gin") { return .gin }
        if set.contains("vodka") { return .vodka }
        if !set.isDisjoint(with: ["tequila", "mezcal", "mescal"]) { return .tequila }
        if !set.isDisjoint(with: ["liqueur", "amaro", "schnapps"]) { return .liqueur }
        if let abv = highestABV(in: texts), abv >= 30 { return .spirit }
        return nil
    }

    /// Largest "NN%" / "NN.N %" on the label, if any.
    static func highestABV(in lines: [String]) -> Double? {
        guard let re = try? NSRegularExpression(pattern: "(\\d{1,2}(?:[.,]\\d{1,2})?)\\s*%") else { return nil }
        var best: Double?
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for m in re.matches(in: line, range: range) {
                guard let r = Range(m.range(at: 1), in: line),
                      let v = Double(line[r].replacingOccurrences(of: ",", with: ".")) else { continue }
                best = max(best ?? v, v)
            }
        }
        return best
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
