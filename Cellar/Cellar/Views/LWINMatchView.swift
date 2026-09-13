import SwiftUI

/// Presents ranked LWIN candidates for the current label fields and returns the
/// one the user picks. Loading the database is done off the main thread.
struct LWINMatchView: View {
    let producer: String
    let name: String
    let region: String
    let vintage: Int?
    var onPick: (LWINRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var matches: [LWINMatch] = []
    @State private var loading = true
    @State private var usingSample = false

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text("Matching…") }
                } else if matches.isEmpty {
                    ContentUnavailableView {
                        Label("No LWIN match", systemImage: "questionmark.circle")
                    } description: {
                        Text("Edit the producer or name and try again, or add the full LWIN database (see README).")
                    }
                } else {
                    ForEach(matches) { m in
                        Button {
                            onPick(m.record)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.record.title).fontWeight(.medium)
                                let place = [m.record.region, m.record.country]
                                    .filter { !$0.isEmpty }.joined(separator: ", ")
                                if !place.isEmpty {
                                    Text(place).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("LWIN \(m.record.lwin7) · \(m.percent)% match")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                if usingSample {
                    Section {
                        Text("Matching against the bundled sample list. Drop the full Liv-ex LWIN.csv into Resources/ for complete coverage.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("LWIN match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await run() }
        }
    }

    private func run() async {
        let db = LWINDatabase.shared
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                db.loadIfNeeded()
                cont.resume()
            }
        }
        matches = LWINMatcher(database: db)
            .match(producer: producer, name: name, region: region, vintage: vintage)
        usingSample = db.usingSampleData
        loading = false
    }
}
