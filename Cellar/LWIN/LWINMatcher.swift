import Foundation

struct LWINMatch: Identifiable, Equatable {
    let record: LWINRecord
    let score: Double        // 0…1
    var id: String { record.lwin7 }
    var percent: Int { Int((score * 100).rounded()) }
}

/// Scores LWIN records against parsed label fields. Token-overlap based: a blend
/// of query recall (how much of the query the record covers) and Jaccard (how
/// tightly they overlap), with small bonuses for a matching region and a
/// plausible vintage. Deterministic and dependency-free → unit-testable.
struct LWINMatcher {
    let database: LWINDatabase

    init(database: LWINDatabase = .shared) { self.database = database }

    func match(producer: String,
               name: String,
               region: String = "",
               vintage: Int? = nil,
               limit: Int = 8,
               minimumScore: Double = 0.15) -> [LWINMatch] {
        // Still loading (e.g. called from the Add form right after launch): no matches yet.
        guard database.isLoaded else { return [] }
        let queryTokens = LWINText.tokens([producer, name].joined(separator: " "))
        guard !queryTokens.isEmpty else { return [] }
        let queryIDs = database.tokenIDs(for: queryTokens)
        let regionTokens = LWINText.tokens(region)
        let thisYear = Calendar.current.component(.year, from: .now)

        var scored: [LWINMatch] = []
        for idx in database.candidateIndices(for: queryTokens) {
            let recIDs = database.tokenIDs(at: idx)
            let inter = recIDs.reduce(0) { $0 + (queryIDs.contains($1) ? 1 : 0) }
            guard inter > 0 else { continue }

            // Unknown query tokens still count against recall and in the union.
            let recall = Double(inter) / Double(queryTokens.count)
            let jaccard = Double(inter) / Double(queryTokens.count + recIDs.count - inter)
            var score = 0.7 * recall + 0.3 * jaccard

            let rec = database.records[idx]
            if !regionTokens.isEmpty {
                let recRegion = LWINText.tokens([rec.region, rec.country].joined(separator: " "))
                if !regionTokens.isDisjoint(with: recRegion) { score += 0.10 }
            }
            if let v = vintage, let first = rec.firstVintage {
                let last = rec.finalVintage ?? thisYear
                if v >= first, v <= last { score += 0.05 }
            }

            let clamped = min(score, 1.0)
            if clamped >= minimumScore {
                scored.append(LWINMatch(record: rec, score: clamped))
            }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Compose the 11-digit LWIN (wine + vintage). Non-vintage uses Liv-ex's
    /// "1000" convention. Returns nil for a malformed 7-digit code.
    static func lwin11(lwin7: String, vintage: Int?) -> String? {
        guard lwin7.count == 7, lwin7.allSatisfy(\.isNumber) else { return nil }
        let v = vintage ?? 1000
        guard v >= 1000, v <= 9999 else { return nil }
        return lwin7 + String(v)
    }
}
