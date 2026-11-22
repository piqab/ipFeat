import XCTest
@testable import ipFeat

@MainActor
final class EngineManagerTests: XCTestCase {
    func testReleaseLookupFallsBackToMixedProxyButNotProbe() {
        let root = configuration(final: "proxy")
        XCTAssertEqual(EngineManager.releaseProxyPorts(in: root), [38_999, 2_080])
    }

    func testReleaseLookupDoesNotFallbackThroughDifferentRoute() {
        let root = configuration(final: "direct")
        XCTAssertEqual(EngineManager.releaseProxyPorts(in: root), [38_999])
    }

    func testManagedServiceRecognizesCurrentSymlinkAndExcludesSleep() {
        let path = "/Library/Application Support/ipFeat/engines/current"
        XCTAssertTrue(NetworkServiceManager.isManagedEngineCommand(
            "\(path) run -c /tmp/sing-box-base.json", expectedPath: path))
        XCTAssertFalse(NetworkServiceManager.isManagedEngineCommand("/bin/sleep 2", expectedPath: path))
        XCTAssertFalse(NetworkServiceManager.isManagedEngineCommand(
            "/opt/homebrew/bin/sing-box run -c /tmp/other.json", expectedPath: path))
    }

    private func configuration(final: String) -> [String: Any] {
        [
            "inbounds": [
                ["tag": "ipfeat-updater", "type": "socks", "listen": "127.0.0.1", "listen_port": 38_999],
                ["tag": "mixed-in", "type": "mixed", "listen": "127.0.0.1", "listen_port": 2_080]
            ],
            "route": [
                "final": final,
                "rules": [["inbound": ["ipfeat-updater"], "action": "route", "outbound": "proxy"]]
            ]
        ]
    }
}
