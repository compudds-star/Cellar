import Foundation
import SwiftData
import os

/// One backup file, as listed in Settings → Backup.
struct BackupFile: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case automatic = "Automatic"
        case manual = "Manual"
        case beforeRestore = "Before restore"
    }

    /// Where the real file lives (never the `.name.icloud` placeholder).
    var url: URL
    var date: Date
    var kind: Kind
    /// Unknown until iCloud has downloaded the file to this phone.
    var size: Int?
    var id: URL { url }
}

/// Backups are files in the app's iCloud Drive folder ("Vino Cellar" in the Files
/// app), so they survive losing or wiping the phone and can be copied out by hand.
/// With iCloud Drive off they go to the app's own Documents folder instead — still
/// a guard against a damaged database, but not against losing the phone, which the
/// Backup screen says.
///
/// Everything here touches the file system or iCloud and can block, so callers
/// run it off the main thread.
enum BackupStore {
    static let containerID = "iCloud.com.doony.cellar"
    static let fileExtension = "vinocellarbackup"
    /// Automatic backups kept: two weeks of dailies. Manual and before-restore
    /// backups are only removed by the user.
    static let automaticToKeep = 14

    private static let log = Logger(subsystem: "com.doony.cellar", category: "backup")

    // MARK: Location

    struct Folder {
        var url: URL
        var isICloud: Bool
    }

    static func folder() throws -> Folder {
        let fm = FileManager.default
        if let container = fm.url(forUbiquityContainerIdentifier: containerID) {
            // Documents/ is the part of the container shown in iCloud Drive.
            let url = container.appending(path: "Documents", directoryHint: .isDirectory)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return Folder(url: url, isICloud: true)
        }
        let url = URL.documentsDirectory.appending(path: "Backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return Folder(url: url, isICloud: false)
    }

    // MARK: Names

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// "Vino Cellar 2026-10-13 14.30.05 Automatic.vinocellarbackup" — the date and
    /// kind are read back from the name, so listing never has to open a file that
    /// may not be downloaded yet.
    static func fileName(date: Date, kind: BackupFile.Kind) -> String {
        "Vino Cellar \(nameFormatter.string(from: date)) \(kind.rawValue).\(fileExtension)"
    }

    static func parse(fileName raw: String) -> (date: Date, kind: BackupFile.Kind)? {
        guard raw.hasSuffix("." + fileExtension), raw.hasPrefix("Vino Cellar ") else { return nil }
        let stem = raw.dropFirst("Vino Cellar ".count).dropLast(fileExtension.count + 1)
        guard stem.count > 20 else { return nil }
        let datePart = String(stem.prefix(19))
        let kindPart = String(stem.dropFirst(20))
        guard let date = nameFormatter.date(from: datePart),
              let kind = BackupFile.Kind(rawValue: kindPart) else { return nil }
        return (date, kind)
    }

    // MARK: List

    /// Newest first. Files iCloud hasn't downloaded yet show up as
    /// ".<name>.icloud" placeholders; they're listed under their real name.
    static func list() throws -> [BackupFile] {
        let folder = try folder()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        var files: [BackupFile] = []
        for raw in names {
            var name = raw
            var downloaded = true
            if raw.hasPrefix("."), raw.hasSuffix(".icloud") {
                name = String(raw.dropFirst().dropLast(".icloud".count))
                downloaded = false
            }
            guard let parsed = parse(fileName: name) else { continue }
            let url = folder.url.appending(path: name)
            let size = downloaded ? (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize : nil
            if files.contains(where: { $0.url == url }) { continue }
            files.append(BackupFile(url: url, date: parsed.date, kind: parsed.kind, size: size))
        }
        return files.sorted { $0.date > $1.date }
    }

    // MARK: Write

    /// Backs up everything in `container`. Uses its own context so it can run on
    /// a background thread while the app is in use.
    @discardableResult
    static func backUp(_ container: ModelContainer, kind: BackupFile.Kind, at date: Date = .now) throws -> BackupFile {
        let archive = try CellarArchive.capture(from: ModelContext(container), at: date)
        if kind == .automatic, archive.wines.isEmpty {
            // Never let an empty (perhaps just-wiped) cellar push good backups out.
            throw BackupError.emptyCellar
        }
        let data = try archive.encoded()
        let folder = try folder()
        let url = folder.url.appending(path: fileName(date: date, kind: kind))
        try coordinate(writing: url) { try data.write(to: $0, options: .atomic) }
        log.info("Backed up \(archive.wines.count) wines (\(data.count) bytes) to \(folder.isICloud ? "iCloud" : "local", privacy: .public)")
        if kind == .automatic { pruneAutomatic() }
        return BackupFile(url: url, date: date, kind: kind, size: data.count)
    }

    static func delete(_ file: BackupFile) throws {
        var coordError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file.url, options: .forDeleting, error: &coordError) { url in
            do { try FileManager.default.removeItem(at: url) } catch { removeError = error }
        }
        if let error = coordError ?? removeError { throw error }
    }

    private static func pruneAutomatic() {
        guard let files = try? list() else { return }
        for old in files.filter({ $0.kind == .automatic }).dropFirst(automaticToKeep) {
            try? delete(old)
        }
    }

    // MARK: Read

    static func read(_ file: BackupFile) throws -> CellarArchive {
        try read(at: file.url)
    }

    /// A backup picked in the Files app — anywhere, not just the backup folder.
    static func read(pickedFile url: URL) throws -> CellarArchive {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try read(at: url)
    }

    /// Downloads the file from iCloud if needed (up to a minute), then decodes it.
    private static func read(at fileURL: URL) throws -> CellarArchive {
        let fm = FileManager.default
        if fm.isUbiquitousItem(at: fileURL) {
            try? fm.startDownloadingUbiquitousItem(at: fileURL)
            let deadline = Date.now.addingTimeInterval(60)
            while !isDownloaded(fileURL) {
                guard Date.now < deadline else { throw BackupError.downloadTimedOut }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        var data = Data()
        var coordError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordError) { url in
            do { data = try Data(contentsOf: url) } catch { readError = error }
        }
        if let error = coordError ?? readError { throw error }
        do {
            return try CellarArchive.decode(data)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.notABackup
        }
    }

    private static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        return status == .current || status == .downloaded
    }

    private static func coordinate(writing url: URL, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { url in
            do { try body(url) } catch { writeError = error }
        }
        if let error = coordError ?? writeError { throw error }
    }
}

// MARK: - Automatic backups

/// Once a day, when the app comes to the front, if the user hasn't turned it off.
enum AutomaticBackup {
    static let enabledKey = "backup.automatic"
    static let lastKey = "backup.lastAutomatic"
    static let interval: TimeInterval = 24 * 60 * 60

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var lastBackup: Date? {
        get { UserDefaults.standard.object(forKey: lastKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }

    static func isDue(now: Date = .now) -> Bool {
        guard isEnabled else { return false }
        guard let last = lastBackup else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    private static let running = OSAllocatedUnfairLock(initialState: false)

    /// Runs in the background; failures are logged and retried next launch.
    static func runIfDue(_ container: ModelContainer) {
        guard isDue() else { return }
        let claimed = running.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard claimed else { return }
        Task.detached(priority: .utility) {
            defer { running.withLock { $0 = false } }
            do {
                let file = try BackupStore.backUp(container, kind: .automatic)
                lastBackup = file.date
            } catch BackupError.emptyCellar {
                // Nothing to save yet; check again next time.
            } catch {
                Logger(subsystem: "com.doony.cellar", category: "backup")
                    .error("Automatic backup failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
