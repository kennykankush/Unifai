import XCTest
@testable import UnifaiCore

final class BackupTests: XCTestCase {
    private func repository() -> StateRepository {
        StateRepository(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/test-data/\(UUID())"))
    }
    func testSaveKeepsPreviousStateAndPrivatePermissions() throws {
        let repo = repository()
        var state = PersistentState()
        try repo.save(state)
        XCTAssertTrue(try repo.backups().isEmpty)
        state.displayCurrency = "SGD"; try repo.save(state)
        let copies = try repo.backups()
        XCTAssertEqual(copies.count, 2)
        let old = try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: repo.backupDirectory.appendingPathComponent(copies[0].id)))
        XCTAssertNil(old.displayCurrency)
        XCTAssertEqual(try repo.load(), state)
        for url in [repo.file] + copies.map({ repo.backupDirectory.appendingPathComponent($0.id) }) {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
        try repo.save(state)
        XCTAssertEqual(try repo.backups().count, 2, "No-op saves do not consume recovery points")
    }
    func testRecoveryPreservesCorruptCurrentBytesAndRejectsPathTraversal() throws {
        let repo = repository(); var state = PersistentState()
        try repo.save(state); state.displayCurrency = "SGD"; try repo.save(state)
        let name = try XCTUnwrap(repo.backups().first?.id)
        let damaged = Data("damaged state, preserve me".utf8)
        try damaged.write(to: repo.file)
        XCTAssertThrowsError(try repo.save(state))
        XCTAssertEqual(try Data(contentsOf: repo.file), damaged)
        XCTAssertThrowsError(try repo.restore(backup: "../state.json"))
        let restored = try repo.restore(backup: name)
        XCTAssertNil(restored.displayCurrency)
        let preserved = try FileManager.default.contentsOfDirectory(at: repo.backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("preserved-") }
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), damaged)
        XCTAssertEqual(try repo.load(), restored)
    }
    func testBackupFailurePreventsOverwritingCurrentState() throws {
        let repo = repository(); var state = PersistentState()
        try repo.save(state)
        let before = try Data(contentsOf: repo.file)
        try Data("blocked backup directory".utf8).write(to: repo.backupDirectory)
        state.displayCurrency = "SGD"
        XCTAssertThrowsError(try repo.save(state))
        XCTAssertEqual(try Data(contentsOf: repo.file), before)
    }
    func testRetentionKeepsRecentAndDailyCopiesWithoutDeletingOtherFiles() throws {
        let repo = repository(); var state = PersistentState()
        let now = Date()
        try repo.save(state)
        try FileManager.default.createDirectory(at: repo.backupDirectory, withIntermediateDirectories: true)
        let unrelated = repo.backupDirectory.appendingPathComponent("my-receipt.json")
        try Data("keep".utf8).write(to: unrelated)
        for index in 0..<45 {
            state.monthlyBudget = Money(Decimal(index + 1), "USD")
            try repo.save(state, now: now.addingTimeInterval(Double(index) * 86400))
        }
        let copies = try repo.backups()
        XCTAssertEqual(copies.filter(\.daily).count, StateRepository.dailyBackupLimit)
        XCTAssertEqual(copies.filter { !$0.daily }.count, StateRepository.recentBackupLimit)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }
}
