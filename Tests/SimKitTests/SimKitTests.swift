import XCTest
@testable import SimKit

final class SimKitTests: XCTestCase {

    func testSimKitSharedInstance() {
        let instance = SimKit.shared
        XCTAssertNotNil(instance)
    }

    func testNetworkSettingsDefault() {
        let settings = NetworkSettings.default
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.profile, .wifi)
    }

    func testNetworkProfiles() {
        XCTAssertEqual(NetworkProfile.wifi.typicalLatencyMs, 10)
        XCTAssertEqual(NetworkProfile.threeG.typicalLatencyMs, 200)
        XCTAssertEqual(NetworkProfile.offline.bandwidth.downloadKBps, 0)
    }

    func testMockEndpointMatching() {
        let endpoint = MockEndpoint(
            name: "Test API",
            urlPattern: "api.example.com",
            method: .get,
            matchType: .contains
        )

        let url = URL(string: "https://api.example.com/users")!
        XCTAssertTrue(endpoint.matches(url: url, method: "GET"))
        XCTAssertFalse(endpoint.matches(url: url, method: "POST"))
    }
}
