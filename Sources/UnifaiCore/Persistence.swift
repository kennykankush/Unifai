import Foundation

public struct StateRepository {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("state.json") }
    public var backupDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    public static let recentBackupLimit = 30
    public static let dailyBackupLimit = 14
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> PersistentState {
        guard FileManager.default.fileExists(atPath: file.path) else { return PersistentState() }
        return try decode(Data(contentsOf: file))
    }
    private func decode(_ data: Data) throws -> PersistentState {
        let state = try JSONDecoder().decode(PersistentState.self, from: data)
        guard state.schemaVersion == 1 else { throw ValidationError.message("This data was written by a newer Unifai version. The file has been preserved.") }
        return state
    }
    public func save(_ state: PersistentState, now: Date = .now) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        _ = try decode(data)
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            _ = try decode(previous) // Never overwrite corrupt or newer-schema data.
            if previous == data { return }
            try backup(previous, now: now)
        }
        try writePrivate(data, to: file)
        // Retention failure must not make a successful state write look like a failed transaction.
        try? prune()
    }

    public struct Backup: Identifiable {
        public var id: String
        public var savedAt: Date
        public var accounts: Int
        public var payments: Int
        public var daily: Bool
    }

    public func backups() throws -> [Backup] {
        try backupFiles().compactMap { url in
            guard let data = try? Data(contentsOf: url), let state = try? decode(data) else { return nil }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            return Backup(id: url.lastPathComponent, savedAt: values.contentModificationDate ?? .distantPast,
                          accounts: state.accounts.count, payments: state.payments.count,
                          daily: url.lastPathComponent.hasPrefix("daily-"))
        }.sorted { $0.savedAt > $1.savedAt }
    }

    /// Explicit recovery only. The displaced file is preserved byte-for-byte, even if corrupt.
    public func restore(backup name: String, now: Date = .now) throws -> PersistentState {
        guard let selected = try backupFiles().first(where: { $0.lastPathComponent == name }) else {
            throw ValidationError.message("That backup is unavailable. Choose another saved copy.")
        }
        let data = try Data(contentsOf: selected)
        let restored = try decode(data)
        if FileManager.default.fileExists(atPath: file.path) {
            try prepareBackups()
            let preserved = backupDirectory.appendingPathComponent("preserved-\(stamp(now))-\(UUID().uuidString).json")
            try writePrivate(Data(contentsOf: file), to: preserved)
        }
        try writePrivate(data, to: file)
        return restored
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        // Set permissions on the temporary file before the atomic rename as well as on the result.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ValidationError.message("Could not create a private file for saving.")
        }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func prepareBackups() throws {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)
    }

    private func stamp(_ date: Date) -> String { String(format: "%020.6f", date.timeIntervalSince1970) }

    private func backup(_ data: Data, now: Date) throws {
        try prepareBackups()
        let recent = backupDirectory.appendingPathComponent("recent-\(stamp(now))-\(UUID().uuidString).json")
        try writePrivate(data, to: recent)
        let daily = backupDirectory.appendingPathComponent("daily-\(RateTable.dayFormatter.string(from: now)).json")
        if !FileManager.default.fileExists(atPath: daily.path) { try writePrivate(data, to: daily) }
    }

    private func backupFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { url in
                let name = url.lastPathComponent
                guard name.range(of: #"^(daily-[0-9]{4}-[0-9]{2}-[0-9]{2}|(recent|preserved)-[0-9.]+-[A-Fa-f0-9-]{36})\.json$"#, options: .regularExpression) != nil else { return false }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
    }

    private func prune() throws {
        let files = try backupFiles()
        for (prefix, limit) in [("recent-", Self.recentBackupLimit), ("daily-", Self.dailyBackupLimit)] {
            let matching = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in matching.dropFirst(limit) { try FileManager.default.removeItem(at: old) }
        }
    }
}
