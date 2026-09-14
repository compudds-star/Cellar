import Foundation

// Shared with the CellarShare extension.

/// Turns what another app shares — a page title, a Vivino share message, a link — into
/// a first guess at the wine. The user checks it in the share sheet before saving.
enum SharedWineParser {
    static let siteNames = ["vivino", "wine-searcher", "wine searcher", "cellartracker", "delectable",
                            "total wine", "total wine & more", "wine.com", "k&l wines", "drizly",
                            "the whisky exchange", "master of malt"]
    static let styleSegments: Set<String> = ["wine", "red wine", "white wine", "rosé wine", "rose wine",
                                             "sparkling wine", "dessert wine", "fortified wine", "buy online", "shop"]

    static func draft(title: String?, text: String?, url: URL?) -> PendingImport {
        var item = PendingImport()
        item.sourceURL = url?.absoluteString
        item.sharedText = text
        let raw = [title, text].compactMap { $0 }.map(clean).first { !$0.isEmpty } ?? slugText(from: url) ?? ""
        let parsed = LabelParser.parse(lines: [raw])
        item.vintage = parsed.vintage ?? url.flatMap(vintageFromQuery)
        item.typeRaw = parsed.type.rawValue
        item.varietal = parsed.varietal
        item.region = parsed.region
        item.country = parsed.country
        // Producer vs. cuvée can't be split reliably from a title: keep it together.
        item.producer = LabelParser.titleCasedIfAllCaps(removingYear(raw, parsed.vintage))
        return item
    }

    /// Strips links, share boilerplate ("Check out … on Vivino"), site names, and style
    /// labels ("Red Wine") from a title or message.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"(?i)^\s*(check out|look at|have you tried|i found|found)(\s+this\s+(wine|bottle))?\s*[:\-–]?\s*"#,
            with: "", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"(?i)\s+(on|via|from|at)\s+(vivino|wine-searcher|cellartracker|delectable)\b.*$"#,
            with: "", options: .regularExpression)
        let segments = t.components(separatedBy: " | ")
            .flatMap { $0.components(separatedBy: " - ") }
            .flatMap { $0.components(separatedBy: " – ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kept = segments.filter { segment in
            let lower = segment.lowercased()
            return !segment.isEmpty
                && !siteNames.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") })
                && !styleSegments.contains(lower)
        }
        return kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Words from a link when that's all there is: Wine-Searcher "/find/opus+one/2018",
    /// Vivino "/chateau-margaux-margaux/w/1100", or a hyphenated last path part.
    static func slugText(from url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        var words: String?
        if host.contains("wine-searcher"), let i = parts.firstIndex(of: "find"), i + 1 < parts.count {
            words = parts[i + 1].replacingOccurrences(of: "+", with: " ")
            if i + 2 < parts.count, let year = Int(parts[i + 2]), (1000...9999).contains(year) {
                words = (words ?? "") + " \(year)"
            }
        } else if host.contains("vivino"), let i = parts.firstIndex(of: "w"), i > 0 {
            words = parts[i - 1].replacingOccurrences(of: "-", with: " ")
        } else if let last = parts.last(where: { $0.contains("-") }) {
            words = last.replacingOccurrences(of: "-", with: " ")
        }
        guard let words, !words.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return words.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func vintageFromQuery(_ url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { ["year", "vintage"].contains($0.name.lowercased()) }?
            .value.flatMap { Int($0) }
    }

    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    /// The page's og:title, else its <title>.
    static func titleFromHTML(_ html: String) -> String? {
        let patterns = [#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
                        #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']"#,
                        #"<title[^>]*>([^<]+)</title>"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let value = decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                               "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        guard let re = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") else { return t }
        while let match = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let whole = Range(match.range, in: t), let numberRange = Range(match.range(at: 1), in: t) {
            let number = String(t[numberRange])
            let value = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
            let replacement = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            t.replaceSubrange(whole, with: replacement)
        }
        return t
    }

    static func removingYear(_ s: String, _ year: Int?) -> String {
        guard let year else { return s }
        return s.replacingOccurrences(of: "\\b\(year)\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
