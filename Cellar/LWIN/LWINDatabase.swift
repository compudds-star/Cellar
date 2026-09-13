import Foundation

/// Text normalization shared by the loader and matcher: fold accents, lowercase,
/// tokenize on non-alphanumerics, drop short/stop tokens. Keeping it in one place
/// guarantees the index and the query are tokenized identically.
enum LWINText {
    static let stopwords: Set<String> = [
        "the", "de", "du", "des", "di", "da", "del", "el", "la", "le", "les",
        "of", "and", "et", "vin", "wine",
        // Liv-ex keeps "Port" out of the wine name ("Dow's" / "Vintage"), but labels print it.
        "port", "porto",
        // Age statements reduce to the number ("16 Years Old", "Aged 16 Years" → "16").
        "year", "years", "yr", "yrs", "yo", "old", "aged"
    ]

    static func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
    }

    static func tokens(_ s: String) -> Set<String> {
        let parts = normalize(s)
            .split { !$0.isLetter && !$0.isNumber }
            .map { ageNumber(String($0)) }
        return Set(parts.filter { $0.count >= 2 && !stopwords.contains($0) })
    }

    /// "16yo" / "16y" / "16yrs" → "16", so LWIN's "Single Malt 16YO" matches a
    /// label's "16 Years Old". Other tokens pass through unchanged.
    static func ageNumber(_ token: String) -> String {
        let digits = token.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return token }
        let suffix = String(token.dropFirst(digits.count))
        return ["yo", "y", "yr", "yrs", "year", "years"].contains(suffix) ? String(digits) : token
    }
}

/// In-memory LWIN index. Loads once from a bundled CSV and builds an inverted
/// token index so matching scores only the handful of records that share a
/// token with the query, not all ~200k rows. Tokens are interned (stored once,
/// referenced by id), which keeps the full database's index compact.
///
/// Loading precedence (first found wins):
///   1. `LWIN.csv`         — the full Liv-ex database (scripts/import_lwin.py)
///   2. `lwin_sample.csv`  — the small bundled sample (demo/tests)
///
/// `loadIfNeeded()` does file I/O + parsing; call it off the main thread. It is
/// safe to call from several places at once — later callers wait for the first
/// load — and the data is read-only once `isLoaded` is true.
final class LWINDatabase {
    static let shared = LWINDatabase()

    private(set) var records: [LWINRecord] = []
    private var idForToken: [String: Int32] = [:]
    private var tokenStrings: [String] = []
    private var recordTokenIDs: [[Int32]] = []   // per record, sorted
    private var postings: [[Int32]] = []         // token id -> record indices
    /// Set when the full LWIN.csv was found (vs. the tiny bundled sample), so the
    /// UI can nudge the user to add the real database.
    private(set) var usingSampleData = false

    private let loadLock = NSLock()    // serializes loading
    private let stateLock = NSLock()   // guards `loaded`; never held for long
    private var loaded = false

    /// True once loading has finished. Cheap to call from the main thread.
    var isLoaded: Bool { stateLock.withLock { loaded } }

    init() {}

    /// Test / preview seam: build directly from records, no file I/O.
    init(records: [LWINRecord]) {
        ingest(records)
        loaded = true
    }

    func loadIfNeeded(bundle: Bundle = .main) {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !isLoaded else { return }

        // Memory-mapped: the full file is tens of MB, parsed straight from bytes.
        if let url = bundle.url(forResource: "LWIN", withExtension: "csv"),
           let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            ingest(LWINCSV.parse(data: data))
            usingSampleData = false
        } else if let url = bundle.url(forResource: "lwin_sample", withExtension: "csv"),
                  let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            ingest(LWINCSV.parse(data: data))
            usingSampleData = true
        }
        stateLock.withLock { loaded = true }
    }

    private func ingest(_ recs: [LWINRecord]) {
        records.reserveCapacity(records.count + recs.count)
        recordTokenIDs.reserveCapacity(recordTokenIDs.count + recs.count)
        for rec in recs {
            let index = Int32(records.count)
            records.append(rec)
            var ids: [Int32] = []
            // Identity words only: DISPLAY_NAME also carries classification and
            // appellation ("Premier Cru Classe, Margaux") that would dilute matches.
            let identity = [rec.producerTitle, rec.producerName, rec.wine].joined(separator: " ")
            let source = identity.trimmingCharacters(in: .whitespaces).isEmpty ? rec.displayName : identity
            for token in LWINText.tokens(source) {
                let id: Int32
                if let existing = idForToken[token] {
                    id = existing
                } else {
                    id = Int32(tokenStrings.count)
                    idForToken[token] = id
                    tokenStrings.append(token)
                    postings.append([])
                }
                ids.append(id)
                postings[Int(id)].append(index)
            }
            ids.sort()
            recordTokenIDs.append(ids)
        }
    }

    /// Indices of records that share at least one token with the query.
    func candidateIndices(for queryTokens: Set<String>) -> Set<Int> {
        var set = Set<Int>()
        for token in queryTokens {
            guard let id = idForToken[token] else { continue }
            for index in postings[Int(id)] { set.insert(Int(index)) }
        }
        return set
    }

    /// Interned ids of the query tokens this database knows (unknown ones can't match).
    func tokenIDs(for queryTokens: Set<String>) -> Set<Int32> {
        Set(queryTokens.compactMap { idForToken[$0] })
    }

    func tokenIDs(at index: Int) -> [Int32] { recordTokenIDs[index] }

    func tokens(at index: Int) -> Set<String> {
        Set(recordTokenIDs[index].map { tokenStrings[Int($0)] })
    }
}

/// Parser for the Liv-ex LWIN CSV. Maps columns by header NAME (not position),
/// tolerating extra columns and a couple of header aliases, so the same code
/// reads both the tiny bundled sample and the full official download.
enum LWINCSV {
    /// STATUS values for LWINs that were retired or merged into another code.
    static let retiredStatuses: Set<String> = ["deleted", "combined"]

    static func parse(_ text: String) -> [LWINRecord] {
        parse(data: Data(text.utf8))
    }

    /// Parses row by row straight from bytes, so the ~200k-row file never becomes
    /// one big String or [[String]] in memory.
    static func parse(data: Data) -> [LWINRecord] {
        var header: [String]?
        var cLwin: Int?, cStatus: Int?, cDisplay: Int?, cTitle: Int?, cProducer: Int?, cWine: Int?
        var cCountry: Int?, cRegion: Int?, cColour: Int?, cType: Int?, cFirst: Int?, cFinal: Int?
        var out: [LWINRecord] = []
        var seen = Set<String>()

        forEachRow(in: data) { fields in
            guard header != nil else {
                let h = fields.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                header = h
                func col(_ names: [String]) -> Int? {
                    for name in names { if let i = h.firstIndex(of: name) { return i } }
                    return nil
                }
                cLwin = col(["LWIN", "LWIN7", "LWIN_7"])
                cStatus = col(["STATUS"])
                cDisplay = col(["DISPLAY_NAME", "DISPLAYNAME"])
                cTitle = col(["PRODUCER_TITLE"])
                cProducer = col(["PRODUCER_NAME", "PRODUCER"])
                cWine = col(["WINE"])
                cCountry = col(["COUNTRY"])
                cRegion = col(["REGION"])
                cColour = col(["COLOUR", "COLOR"])
                cType = col(["TYPE"])
                cFirst = col(["FIRST_VINTAGE", "FIRSTVINTAGE"])
                cFinal = col(["FINAL_VINTAGE", "LATEST_VINTAGE", "FINALVINTAGE"])
                return
            }
            guard let cLwin else { return }
            func f(_ i: Int?) -> String {
                guard let i, i < fields.count else { return "" }
                let value = fields[i].trimmingCharacters(in: .whitespaces)
                return value == "NA" ? "" : value   // Liv-ex writes "NA" for blanks
            }
            if retiredStatuses.contains(f(cStatus).lowercased()) { return }
            // A row's LWIN may be 7/11/16/18 digits; the first 7 are the wine.
            let lwin7 = String(f(cLwin).prefix(7))
            guard lwin7.count == 7, lwin7.allSatisfy(\.isNumber) else { return }
            guard seen.insert(lwin7).inserted else { return }   // one row per wine
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
                finalVintage: Int(f(cFinal)),
                producerTitle: f(cTitle)))
        }
        return out
    }

    /// CSV → rows of fields, honoring quoted fields with embedded commas,
    /// escaped quotes (""), and newlines inside quotes.
    static func splitRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        forEachRow(in: Data(text.utf8)) { rows.append($0) }
        return rows
    }

    /// Calls `body` with each row's fields. Handles quoted fields (embedded
    /// commas, "" escapes, newlines), LF / CRLF / CR line endings — spreadsheet
    /// exports use CRLF — and a UTF-8 byte-order mark. Fully empty rows are skipped.
    static func forEachRow(in data: Data, _ body: ([String]) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
            var field: [UInt8] = []
            field.reserveCapacity(256)
            var row: [String] = []
            var inQuotes = false
            while i < n {
                let c = bytes[i]
                if inQuotes {
                    if c == 0x22 {                                   // "
                        if i + 1 < n, bytes[i + 1] == 0x22 { field.append(0x22); i += 1 }
                        else { inQuotes = false }
                    } else {
                        field.append(c)
                    }
                } else {
                    switch c {
                    case 0x22:                                       // "
                        inQuotes = true
                    case 0x2C:                                       // ,
                        row.append(String(decoding: field, as: UTF8.self))
                        field.removeAll(keepingCapacity: true)
                    case 0x0A, 0x0D:                                 // \n, \r
                        row.append(String(decoding: field, as: UTF8.self))
                        field.removeAll(keepingCapacity: true)
                        if !(row.count == 1 && row[0].isEmpty) { body(row) }
                        row.removeAll(keepingCapacity: true)
                        if c == 0x0D, i + 1 < n, bytes[i + 1] == 0x0A { i += 1 }
                    default:
                        field.append(c)
                    }
                }
                i += 1
            }
            if !field.isEmpty || !row.isEmpty {
                row.append(String(decoding: field, as: UTF8.self))
                if !(row.count == 1 && row[0].isEmpty) { body(row) }
            }
        }
    }
}
