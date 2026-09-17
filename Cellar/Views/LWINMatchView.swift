import SwiftUI

/// Presents ranked LWIN candidates for the current label fields and returns the
/// one the user picks. The search bar starts with the label's producer and name;
/// editing it (fixing a misread word, say) re-matches without leaving the sheet.
/// A 7- or 11-digit LWIN finds that wine directly. Loading and matching run off
/// the main thread.
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
    @State private var query = ""
    @State private var didSeedQuery = false

    /// The label's own fields, as first shown in the search bar.
    private var initialQuery: String {
        [producer, name].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            List {
                if loading && matches.isEmpty {
                    HStack { ProgressView(); Text("Matching…") }
                } else if matches.isEmpty {
                    ContentUnavailableView {
                        Label("No LWIN match", systemImage: "questionmark.circle")
                    } description: {
                        Text("Check the spelling in the search bar, or search by producer alone.")
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

                Section {
                    if usingSample {
                        Text("Matching against a small sample list. Add the full Liv-ex database with scripts/import_lwin.py for complete coverage.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Required credit: LWIN is licensed CC BY 4.0; the bundled file is a filtered subset.
                    Text("LWIN data © [Liv-ex](https://www.liv-ex.com/lwin/), licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Retired codes and unused columns removed.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("LWIN match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Producer, wine, or LWIN")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onAppear {
                if !didSeedQuery { query = initialQuery; didSeedQuery = true }
            }
            .task(id: query) { await run() }
        }
    }

    private func run() async {
        guard didSeedQuery else { return }
        let db = LWINDatabase.shared
        let firstRun = !db.isLoaded
        // Let typing settle before re-matching; a new keystroke cancels this task.
        if !firstRun && query != initialQuery {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        loading = true
        let text = query.trimmingCharacters(in: .whitespaces)
        let useLabelFields = text == initialQuery
        let (producer, name, region, vintage) = (producer, name, region, vintage)
        let found: [LWINMatch] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                db.loadIfNeeded()
                let matcher = LWINMatcher(database: db)
                if let code = Self.lwinCode(in: text) {
                    let hits = db.records.filter { $0.lwin7 == code }
                        .map { LWINMatch(record: $0, score: 1, rank: 1) }
                    cont.resume(returning: hits)
                } else if useLabelFields {
                    // The label's fields, split as scanned: also scores the producer alone.
                    cont.resume(returning: matcher.bestMatches(
                        producer: producer, name: name, region: region, vintage: vintage))
                } else {
                    cont.resume(returning: matcher.match(
                        producer: text, name: "", region: region, vintage: vintage))
                }
            }
        }
        if Task.isCancelled { return }
        matches = found
        usingSample = db.usingSampleData
        loading = false
    }

    /// The 7-digit wine code from a typed LWIN7 or LWIN11, if that's what the query is.
    static func lwinCode(in text: String) -> String? {
        guard text.allSatisfy(\.isNumber), text.count == 7 || text.count == 11 else { return nil }
        return String(text.prefix(7))
    }
}
