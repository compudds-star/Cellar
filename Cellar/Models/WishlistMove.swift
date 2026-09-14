import Foundation
import SwiftData

/// Moves a wine between the cellar and the wishlist without losing anything: details,
/// notes, photo, prices, and bottles all go with it.
enum WishlistMove {
    /// Wishlist wines don't count toward cellar value; their bottles are kept for a move back.
    static func toWishlist(_ wine: Wine) {
        wine.isWishlist = true
    }

    /// Back to the cellar. Bottles still in stock are reused; with none, one bottle is
    /// added at the default size and collection.
    @MainActor
    static func toCellar(_ wine: Wine, context: ModelContext) {
        wine.isWishlist = false
        if wine.inStockBottles.isEmpty {
            let bottle = Bottle(size: .defaultSize(for: wine.type))
            context.insert(bottle)
            wine.bottles.append(bottle)
            bottle.collection = CollectionMemory.defaultCollection(in: context)
        }
        PriceLookup.start(for: wine, context: context)
    }
}
