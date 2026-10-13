import SwiftUI
import SwiftData

/// Settings → Backup: automatic daily backups to iCloud Drive, "Back Up Now",
/// and restoring from any backup in the list. Changes here apply immediately —
/// they don't wait for Settings' Save.
struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Query private var wines: [Wine]

    @State private var automatic = AutomaticBackup.isEnabled
    @State private var files: [BackupFile] = []
    @State private var isICloud: Bool?
    @State private var busy: String?
    @State private var message: String?
    @State private var restoreCandidate: BackupFile?

    var body: some View {
        Form {
            Section {
                Toggle("Back up automatically", isOn: $automatic)
                    .onChange(of: automatic) { _, on in
                        AutomaticBackup.isEnabled = on
                        if on { AutomaticBackup.runIfDue(context.container) }
                    }
                Button {
                    Task { await backUpNow() }
                } label: {
                    HStack {
                        Label("Back Up Now", systemImage: "icloud.and.arrow.up")
                        if busy != nil { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy != nil || wines.isEmpty)
            } footer: {
                Text("Once a day when you open the app, keeping the last \(BackupStore.automaticToKeep). Backups include everything — wines, bottles, notes, collections, prices and label photos.")
            }

            Section {
                if let isICloud {
                    if isICloud {
                        Label("Saved to iCloud Drive, in the Vino Cellar folder of the Files app.",
                              systemImage: "checkmark.icloud")
                    } else {
                        Label("iCloud Drive is off, so backups stay on this iPhone and won't survive losing it. Turn on iCloud Drive in the Settings app under your name → iCloud.",
                              systemImage: "exclamationmark.icloud")
                            .foregroundStyle(.orange)
                    }
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)

            Section {
                if files.isEmpty {
                    Text(isICloud == nil ? "Looking for backups…" : "No backups yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    Button { restoreCandidate = file } label: { row(file) }
                        .disabled(busy != nil)
                }
                .onDelete(perform: delete)
            } header: {
                Text("Backups")
            } footer: {
                if !files.isEmpty { Text("Tap a backup to restore it. Swipe to delete.") }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("Restore this backup?",
                            isPresented: Binding(get: { restoreCandidate != nil },
                                                 set: { if !$0 { restoreCandidate = nil } }),
                            titleVisibility: .visible,
                            presenting: restoreCandidate) { file in
            Button("Replace My Cellar", role: .destructive) {
                Task { await restore(file) }
            }
        } message: { file in
            Text("Your cellar will be replaced with the backup from \(file.date.formatted(date: .abbreviated, time: .shortened)). Your current cellar is backed up first, so you can go back.")
        }
    }

    private func row(_ file: BackupFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.date.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.primary)
                Text(file.kind.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let size = file.size {
                Text(size.formatted(.byteCount(style: .file)))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "icloud")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("In iCloud")
            }
        }
    }

    // MARK: Actions

    private func reload() async {
        let result = await Task.detached { () -> (Bool, [BackupFile])? in
            guard let folder = try? BackupStore.folder() else { return nil }
            return (folder.isICloud, (try? BackupStore.list()) ?? [])
        }.value
        isICloud = result?.0 ?? false
        files = result?.1 ?? []
    }

    private func backUpNow() async {
        busy = "backup"
        defer { busy = nil }
        let container = context.container
        do {
            try context.save()
            let file = try await Task.detached {
                try BackupStore.backUp(container, kind: .manual)
            }.value
            message = "Backed up \(wines.count) wine\(wines.count == 1 ? "" : "s") (\((file.size ?? 0).formatted(.byteCount(style: .file))))."
        } catch {
            message = "Backup failed: \(error.localizedDescription)"
        }
        await reload()
    }

    private func restore(_ file: BackupFile) async {
        busy = "restore"
        defer { busy = nil }
        let container = context.container
        do {
            try context.save()
            // Read first, so a backup that can't be opened never costs the current cellar.
            let archive = try await Task.detached { try BackupStore.read(file) }.value
            if !wines.isEmpty {
                _ = try await Task.detached {
                    try BackupStore.backUp(container, kind: .beforeRestore)
                }.value
            }
            try archive.restore(into: context)
            await DrinkWindowNotifier.rescheduleAll(for: (try? context.fetch(FetchDescriptor<Wine>())) ?? [])
            message = "Restored \(archive.wines.count) wine\(archive.wines.count == 1 ? "" : "s") and \(archive.bottleCount) bottle\(archive.bottleCount == 1 ? "" : "s") from \(file.date.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            message = "Restore failed: \(error.localizedDescription) Your cellar wasn't changed."
        }
        await reload()
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { files[$0] }
        files.remove(atOffsets: offsets)
        Task.detached {
            for file in doomed { try? BackupStore.delete(file) }
        }
    }
}
