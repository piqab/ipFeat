import Foundation
import XCTest
@testable import ipFeat

final class LegacyDataMigrationTests: XCTestCase {
    func testCopiesPersistentFilesAndSkipsNonpersistentPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let new = root.appendingPathComponent("new")
        let pending = old.appendingPathComponent("pending-server-installs")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: old.appendingPathComponent("sing-box.json"))
        try Data("pending".utf8).write(to: pending.appendingPathComponent("server.json"))
        try FileManager.default.createSymbolicLink(
            at: old.appendingPathComponent("child-route.sock"), withDestinationURL: root.appendingPathComponent("missing"))

        try LegacyDataMigration.copyMissingContents(from: old, to: new)

        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("sing-box.json")), "saved")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("pending-server-installs/server.json")), "pending")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("child-route.sock").path))
    }
}
