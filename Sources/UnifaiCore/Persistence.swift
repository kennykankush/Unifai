import Foundation

public struct StateRepository {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("state.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> PersistentState {
        guard FileManager.default.fileExists(atPath: file.path) else { return PersistentState() }
        let state = try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: file))
        guard state.schemaVersion == 1 else { throw ValidationError.message("This data was written by a newer Unifai version. The file has been preserved.") }
        return state
    }
    public func save(_ state: PersistentState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
