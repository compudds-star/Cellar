import Foundation
import SwiftData

/// One-time fixes to data saved by earlier versions of the app.
enum DataCleanup {
    static let titleCaseKey = "cleanup.titleCaseAllCapsNames.v1"

    /// Title-cases producers and names saved in all caps (scans before scans were
    /// title-cased): "OPUS ONE" → "Opus One". Mixed case is left as typed. Runs once, so
    /// capitals typed afterwards stay. Returns how many wines changed.
    @discardableResult
    static func titleCaseAllCapsNames(in context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: titleCaseKey),
              let wines = try? context.fetch(FetchDescriptor<Wine>()) else { return 0 }
        var changed = 0
        for wine in wines {
            let producer = LabelParser.titleCasedIfAllCaps(wine.producer)
            let name = LabelParser.titleCasedIfAllCaps(wine.name)
            guard producer != wine.producer || name != wine.name else { continue }
            wine.producer = producer
            wine.name = name
            changed += 1
        }
        defaults.set(true, forKey: titleCaseKey)
        return changed
    }
}
