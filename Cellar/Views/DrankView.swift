import SwiftUI
import SwiftData

/// Bottles you've finished. A wine lands here on its own once nothing is left in
/// stock, keeping its notes, rating, photo and prices; from here it can go back to
/// the cellar (you bought another) or onto the wishlist.
struct DrankView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Wine.createdAt, order: .reverse)])
    private var wines: [Wine]

    @State private var searchText = ""

    private var drank: [Wine] {
        wines.filter { wine in
            guard wine.isDrank else { return false }
            return searchText.isEmpty
                || wine.displayTitle.localizedCaseInsensitiveContains(searchText)
                || wine.varietal.localizedCaseInsensitiveContains(searchText)
                || wine.region.localizedCaseInsensitiveContains(searchText)
        }
        .sorted(by: Wine.alphabeticalOrder)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !wines.contains(where: \.isDrank) {
                    ContentUnavailableView {
                        Label("Nothing drunk yet", systemImage: "wineglass")
                    } description: {
                        Text("Mark a bottle Consumed and its wine moves here once the last one is gone.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(drank) { wine in
                                NavigationLink(value: wine) {
                                    WineRow(wine: wine)
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        WishlistMove.toCellar(wine, context: context)
                                    } label: {
                                        Label("Move to cellar", systemImage: "tray.and.arrow.down")
                                    }
                                    .tint(.green)
                                    Button {
                                        WishlistMove.toWishlist(wine)
                                    } label: {
                                        Label("Wishlist", systemImage: "star")
                                    }
                                    .tint(.yellow)
                                }
                            }
                            .onDelete(perform: delete)
                        } header: {
                            Text("\(drank.count) wine\(drank.count == 1 ? "" : "s")")
                                .textCase(nil)
                        } footer: {
                            Text("Swipe a wine right to put it back in the cellar or on the wishlist.")
                        }
                    }
                }
            }
            .navigationTitle("Drank")
            .searchable(text: $searchText, prompt: "Search drunk wines")
            .navigationDestination(for: Wine.self) { WineDetailView(wine: $0) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { context.delete(drank[index]) }
    }
}
