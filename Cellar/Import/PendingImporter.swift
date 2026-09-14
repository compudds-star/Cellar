import Foundation
import SwiftData
import UIKit

/// Brings in wines shared from other apps (see CellarShare). Each pending item becomes a
/// Wishlist wine or a Cellar wine with one bottle; then its file is removed.
enum PendingImporter {
    @MainActor
    @discardableResult
    static func importAll(into context: ModelContext, baseURL: URL? = nil) async -> [Wine] {
        var imported: [Wine] = []
        for (item, imageData) in SharedImportStore.load(baseURL: baseURL) {
            let wine = Wine(name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            producer: item.producer.trimmingCharacters(in: .whitespacesAndNewlines),
                            varietal: item.varietal,
                            region: item.region,
                            country: item.country,
                            vintage: item.vintage,
                            type: WineType(rawValue: item.typeRaw) ?? .other,
                            labelImage: imageData,
                            notes: item.sourceURL.map { "Imported from \($0)" } ?? "",
                            isWishlist: item.destination == .wishlist)
            context.insert(wine)

            // A shared photo with nothing typed: read the label, as the Add form does.
            if wine.producer.isEmpty, wine.name.isEmpty, let data = imageData, let image = UIImage(data: data) {
                let parsed = LabelParser.parse(textLines: await ImageTextRecognizer.recognizeLines(in: image))
                wine.producer = parsed.producer
                wine.name = parsed.name
                if wine.vintage == nil { wine.vintage = parsed.vintage }
                if wine.varietal.isEmpty { wine.varietal = parsed.varietal }
                if wine.region.isEmpty { wine.region = parsed.region }
                if wine.country.isEmpty { wine.country = parsed.country }
                wine.type = parsed.type
            }

            if let pick = LWINMatcher.confidentPick(
                LWINMatcher().bestMatches(producer: wine.producer, name: wine.name, region: wine.region,
                                          vintage: wine.vintage, limit: 2)) {
                wine.lwin7 = pick.record.lwin7
                if wine.region.isEmpty { wine.region = pick.record.region }
                if wine.country.isEmpty { wine.country = pick.record.country }
            }

            if item.destination == .cellar {
                let bottle = Bottle(size: .defaultSize(for: wine.type))
                context.insert(bottle)
                wine.bottles.append(bottle)
                bottle.collection = CollectionMemory.defaultCollection(in: context)
            }
            PriceLookup.start(for: wine, context: context)
            SharedImportStore.remove(item, baseURL: baseURL)
            imported.append(wine)
        }
        return imported
    }
}
