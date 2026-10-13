import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Backup: automatic daily backups to iCloud Drive, "Back Up Now",
/// and restoring from any backup in the list or a backup file picked in Files
/// (one copied elsewhere, or sent from another phone). Changes here apply immediately —
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
    @State private var pickingFile = false
    /// A picked file, already read, waiting for the user to confirm.
    @State private var pickedArchive: CellarArchive?

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
                Button {
                    pickingFile = true
                } label: {
                    Label("Restore from a File…", systemImage: "doc.badge.arrow.up")
                }
                .disabled(busy != nil)
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
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.vinoCellarBackup]) { result in
            switch result {
            case .success(let url): Task { await open(url) }
            case .failure(let error): message = "Couldn't open that file: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Restore this backup?",
                            isPresented: Binding(get: { pickedArchive != nil },
                                                 set: { if !$0 { pickedArchive = nil } }),
                            titleVisibility: .visible,
                            presenting: pickedArchive) { archive in
            Button("Replace My Cellar", role: .destructive) {
                Task { await apply(archive) }
            }
        } message: { archive in
            Text("This file is a backup from \(archive.createdAt.formatted(date: .abbreviated, time: .shortened)) with \(winesText(archive)). Your cellar will be replaced with it; your current cellar is backed up first, so you can go back.")
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
        do {
            // Read first, so a backup that can't be opened never costs the current cellar.
            let archive = try await Task.detached { try BackupStore.read(file) }.value
            await apply(archive)
        } catch {
            message = "Restore failed: \(error.localizedDescription) Your cellar wasn't changed."
        }
    }

    /// Reads a file picked in Files, then asks before restoring it.
    private func open(_ url: URL) async {
        busy = "open"
        defer { busy = nil }
        do {
            pickedArchive = try await Task.detached { try BackupStore.read(pickedFile: url) }.value
        } catch {
            message = "Couldn't restore that file: \(error.localizedDescription) Your cellar wasn't changed."
        }
    }

    /// Saves the current cellar as a "Before restore" backup, then replaces it.
    private func apply(_ archive: CellarArchive) async {
        busy = "restore"
        defer { busy = nil }
        let container = context.container
        do {
            try context.save()
            if !wines.isEmpty {
                _ = try await Task.detached {
                    try BackupStore.backUp(container, kind: .beforeRestore)
                }.value
            }
            try archive.restore(into: context)
            await DrinkWindowNotifier.rescheduleAll(for: (try? context.fetch(FetchDescriptor<Wine>())) ?? [])
            message = "Restored \(winesText(archive)) from \(archive.createdAt.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            message = "Restore failed: \(error.localizedDescription) Your cellar wasn't changed."
        }
        await reload()
    }

    private func winesText(_ archive: CellarArchive) -> String {
        let w = archive.wines.count, b = archive.bottleCount
        return "\(w) wine\(w == 1 ? "" : "s") and \(b) bottle\(b == 1 ? "" : "s")"
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { files[$0] }
        files.remove(atOffsets: offsets)
        Task.detached {
            for file in doomed { try? BackupStore.delete(file) }
        }
    }
}

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations) so Files knows the extension.
    static let vinoCellarBackup = UTType(exportedAs: "com.doony.cellar.backup")
}
