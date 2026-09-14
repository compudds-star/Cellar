import SwiftUI
import SwiftData

struct WishlistView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Wine.createdAt, order: .reverse)])
    private var wines: [Wine]

    private var wishlist: [Wine] { wines.filter { $0.isWishlist }.sorted(by: Wine.alphabeticalOrder) }

    var body: some View {
        NavigationStack {
            Group {
                if wishlist.isEmpty {
                    ContentUnavailableView {
                        Label("Wishlist is empty", systemImage: "star")
                    } description: {
                        Text("Add a wine and choose “Wishlist” to track bottles you want.")
                    }
                } else {
                    List {
                        ForEach(wishlist) { wine in
                            NavigationLink(value: wine) {
                                WineRow(wine: wine)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    moveToCellar(wine)
                                } label: {
                                    Label("Move to cellar", systemImage: "tray.and.arrow.down")
                                }
                                .tint(.green)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Wishlist")
            .navigationDestination(for: Wine.self) { WineDetailView(wine: $0) }
        }
    }

    /// Promote a wishlist wine into the cellar: clear the flag and add one bottle.
    private func moveToCellar(_ wine: Wine) {
        WishlistMove.toCellar(wine, context: context)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(wishlist[index]) }
    }
}
