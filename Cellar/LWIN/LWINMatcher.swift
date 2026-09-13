import Foundation

struct LWINMatch: Identifiable, Equatable {
    let record: LWINRecord
    let score: Double        // 0…1, for display
    /// Uncapped ranking value. `score` is capped at 1, which flattens close
    /// matches into ties; ranking uses this instead.
    var rank: Double = 0
    var id: String { record.lwin7 }
    var percent: Int { Int((score * 100).rounded()) }
}

/// Scores LWIN records against parsed label fields. Token-overlap based: a blend
/// of query recall (how much of the query the record covers) and Jaccard (how
/// tightly they overlap), with a small bonus for a matching region and a penalty
/// for a vintage outside the wine's known years. Deterministic and dependency-free → unit-testable.
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
            var rank = 0.7 * recall + 0.3 * jaccard

            let rec = database.records[idx]
            if !regionTokens.isEmpty {
                let recRegion = LWINText.tokens([rec.region, rec.country].joined(separator: " "))
                if !regionTokens.isDisjoint(with: recRegion) { rank += 0.10 }
            }
            // A vintage outside the wine's known years argues against it. In range is
            // neutral: few records carry vintage years, so rewarding it would favour
            // those over otherwise identical ones (a second wine over the grand vin).
            if let v = vintage, let first = rec.firstVintage {
                let last = rec.finalVintage ?? thisYear
                if v < first || v > last { rank -= 0.10 }
            }

            let score = min(rank, 1.0)
            if score >= minimumScore {
                scored.append(LWINMatch(record: rec, score: score, rank: rank))
            }
        }
        return Array(Self.ordered(scored).prefix(limit))
    }

    /// Like `match`, but also scores the producer alone (slightly discounted) and
    /// keeps each wine's best result. Label scans often read a byline or grape into
    /// `name` ("Robert Mondavi & Baron Philippe de Rothschild"), which would
    /// otherwise drag the right wine down.
    func bestMatches(producer: String,
                     name: String,
                     region: String = "",
                     vintage: Int? = nil,
                     limit: Int = 8,
                     minimumScore: Double = 0.15) -> [LWINMatch] {
        var best: [String: LWINMatch] = [:]
        func consider(_ m: LWINMatch) {
            if (best[m.id]?.rank ?? -.infinity) < m.rank { best[m.id] = m }
        }
        match(producer: producer, name: name, region: region, vintage: vintage,
              limit: 50, minimumScore: minimumScore).forEach(consider)
        let hasBoth = !producer.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
        if hasBoth {
            for m in match(producer: producer, name: "", region: region, vintage: vintage,
                           limit: 50, minimumScore: minimumScore) {
                let rank = m.rank * 0.95
                consider(LWINMatch(record: m.record, score: min(rank, 1), rank: rank))
            }
        }
        return Array(Self.ordered(Array(best.values)).prefix(limit))
    }

    /// The match to adopt without asking: confident, and clearly ahead of the runner-up.
    static func confidentPick(_ matches: [LWINMatch]) -> LWINMatch? {
        guard let best = matches.first, best.score >= 0.8 else { return nil }
        if matches.count > 1, best.rank - matches[1].rank < 0.05 { return nil }
        return best
    }

    /// Tightest match first. Equal ranks prefer the shorter wine name, then title —
    /// the flagship ("Chateau Margaux") over its second wine or a special cuvée.
    static func ordered(_ matches: [LWINMatch]) -> [LWINMatch] {
        matches.sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.record.wine.count != $1.record.wine.count { return $0.record.wine.count < $1.record.wine.count }
            return $0.record.title.count < $1.record.title.count
        }
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
