import Foundation
import XCTest
import ReoBabyKit

final class VersionTests: XCTestCase {
    /// Releases bump Resources/Info.plist; ReoBaby.version (what `reobaby version` says on
    /// Linux) must move with it.
    func testVersionMatchesTheAppsInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        XCTAssertEqual(ReoBaby.version, info?["CFBundleShortVersionString"] as? String)
    }
}
