import Foundation

/// Text normalization shared by the loader and matcher: fold accents, lowercase,
/// tokenize on non-alphanumerics, drop short/stop tokens. Keeping it in one place
/// guarantees the index and the query are tokenized identically.
enum LWINText {
    static let stopwords: Set<String> = [
        "the", "de", "du", "des", "di", "da", "del", "el", "la", "le", "les",
        "of", "and", "et", "vin", "wine"
    ]

    static func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
    }

    static func tokens(_ s: String) -> Set<String> {
        let parts = normalize(s)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(parts.filter { $0.count >= 2 && !stopwords.contains($0) })
    }
}

/// In-memory LWIN index. Loads once from a bundled CSV and builds an inverted
/// token index so matching scores only the handful of records that share a
/// token with the query, not all ~200k rows.
///
/// Loading precedence (first found wins):
///   1. `LWIN.csv`         — the full Liv-ex download the user drops in Resources/
///   2. `lwin_sample.csv`  — the small bundled sample (demo/tests)
///
/// `loadIfNeeded()` does file I/O + parsing; call it off the main thread.
final class LWINDatabase {
    static let shared = LWINDatabase()

    private(set) var records: [LWINRecord] = []
    private var recordTokens: [Set<String>] = []
    private var invertedIndex: [String: [Int]] = [:]
    private(set) var isLoaded = false
    /// Set when the full LWIN.csv was found (vs. the tiny bundled sample), so the
    /// UI can nudge the user to add the real database.
    private(set) var usingSampleData = false

    init() {}

    /// Test / preview seam: build directly from records, no file I/O.
    init(records: [LWINRecord]) {
        ingest(records)
        isLoaded = true
    }

    func loadIfNeeded(bundle: Bundle = .main) {
        guard !isLoaded else { return }
        defer { isLoaded = true }

        if let url = bundle.url(forResource: "LWIN", withExtension: "csv"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            ingest(LWINCSV.parse(text))
            usingSampleData = false
        } else if let url = bundle.url(forResource: "lwin_sample", withExtension: "csv"),
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            ingest(LWINCSV.parse(text))
            usingSampleData = true
        }
    }

    private func ingest(_ recs: [LWINRecord]) {
        records.reserveCapacity(records.count + recs.count)
        for rec in recs {
            let idx = records.count
            records.append(rec)
            let toks = LWINText.tokens([rec.producerName, rec.wine, rec.displayName].joined(separator: " "))
            recordTokens.append(toks)
            for t in toks { invertedIndex[t, default: []].append(idx) }
        }
    }

    /// Indices of records that share at least one token with the query.
    func candidateIndices(for queryTokens: Set<String>) -> Set<Int> {
        var set = Set<Int>()
        for t in queryTokens {
            if let ids = invertedIndex[t] { set.formUnion(ids) }
        }
        return set
    }

    func tokens(at index: Int) -> Set<String> { recordTokens[index] }
}

/// Parser for the Liv-ex LWIN CSV. Maps columns by header NAME (not position),
/// tolerating extra columns and a couple of header aliases, so the same code
/// reads both the tiny bundled sample and the full official download.
enum LWINCSV {
    static func parse(_ text: String) -> [LWINRecord] {
        var rows = splitRows(text)
        guard !rows.isEmpty else { return [] }

        let header = rows.removeFirst().map {
            $0.trimmingCharacters(in: .whitespaces).uppercased()
        }
        func col(_ names: [String]) -> Int? {
            for n in names { if let i = header.firstIndex(of: n) { return i } }
            return nil
        }
        guard let cLwin = col(["LWIN", "LWIN7", "LWIN_7"]) else { return [] }
        let cDisplay = col(["DISPLAY_NAME", "DISPLAYNAME"])
        let cProducer = col(["PRODUCER_NAME", "PRODUCER"])
        let cWine = col(["WINE"])
        let cCountry = col(["COUNTRY"])
        let cRegion = col(["REGION"])
        let cColour = col(["COLOUR", "COLOR"])
        let cType = col(["TYPE"])
        let cFirst = col(["FIRST_VINTAGE", "FIRSTVINTAGE"])
        let cFinal = col(["FINAL_VINTAGE", "LATEST_VINTAGE", "FINALVINTAGE"])

        var out: [LWINRecord] = []
        var seen = Set<String>()
        for fields in rows {
            func f(_ i: Int?) -> String {
                guard let i, i < fields.count else { return "" }
                return fields[i].trimmingCharacters(in: .whitespaces)
            }
            // A row's LWIN may be 7/11/16/18 digits; the first 7 are the wine.
            let lwin7 = String(f(cLwin).prefix(7))
            guard lwin7.count == 7, lwin7.allSatisfy(\.isNumber) else { continue }
            guard seen.insert(lwin7).inserted else { continue }   // one row per wine
            out.append(LWINRecord(
                lwin7: lwin7,
                displayName: f(cDisplay),
                producerName: f(cProducer),
                wine: f(cWine),
                country: f(cCountry),
                region: f(cRegion),
                colour: f(cColour),
                type: f(cType),
                firstVintage: Int(f(cFirst)),
                finalVintage: Int(f(cFinal))))
        }
        return out
    }

    /// CSV → rows of fields, honoring quoted fields with embedded commas,
    /// escaped quotes (""), and newlines inside quotes.
    static func splitRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\""); i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); field = ""; rows.append(row); row = []
                case "\r": break
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        // Drop fully-empty trailing rows.
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
