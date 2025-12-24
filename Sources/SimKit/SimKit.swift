//
//  SimKit.swift
//  SimKit
//
//  iOS Framework for network monitoring, throttling, and UserDefaults editing
//  Works seamlessly with SimKit macOS app via socket communication
//

import Foundation

/// Main entry point for SimKit SDK
/// Add this single line to your AppDelegate to enable network monitoring, throttling, and UserDefaults editing
public class SimKit {

    public static let shared = SimKit()

    private var isEnabled = false
    private let bridgeClient = SimBridgeClient.shared
    private let userDefaultsMonitor = UserDefaultsMonitor.shared

    /// Cached network settings from socket
    private var cachedSettings: SDKNetworkSettings = .default

    private init() {}

    /// Enable SimKit network monitoring, throttling, and UserDefaults editing
    /// Call this in your AppDelegate's application(_:didFinishLaunchingWithOptions:)
    ///
    /// Example:
    /// ```swift
    /// #if DEBUG
    /// SimKit.shared.enable()
    /// #endif
    /// ```
    public func enable() {
        guard !isEnabled else {
            print("[SimKit] Already enabled")
            return
        }

        // Start socket connection to macOS app
        print("[SimKit] 🔌 Connecting to macOS SimKit app...")
        bridgeClient.start()

        // Set up config update callbacks
        bridgeClient.onNetworkSettingsUpdated = { [weak self] settings in
            self?.cachedSettings = settings
            print("[SimKit] ⚙️ Network settings updated: \(settings.profile), latency: \(settings.latencyMs)ms")
        }

        bridgeClient.onMockEndpointsUpdated = { endpoints in
            print("[SimKit] 🎭 Mock endpoints updated: \(endpoints.count) endpoints")
        }

        // Register custom URLProtocol to intercept all network requests
        print("[SimKit] 🔧 Registering SimKitURLProtocol...")
        URLProtocol.registerClass(SimKitURLProtocol.self)
        print("[SimKit] 🔧 URLProtocol registered")

        // Start monitoring for UserDefaults commands from SimKit app
        userDefaultsMonitor.startMonitoring()
        print("[SimKit] 📝 UserDefaults monitoring enabled")

        isEnabled = true
        print("[SimKit] ✅ Enabled - Network monitoring, throttling, and mocking active via socket")
    }

    /// Disable SimKit
    public func disable() {
        guard isEnabled else { return }

        URLProtocol.unregisterClass(SimKitURLProtocol.self)
        bridgeClient.stop()
        userDefaultsMonitor.stopMonitoring()

        isEnabled = false
        print("[SimKit] ⏹️ Disabled")
    }

    /// Current network settings from macOS app (via socket)
    public var currentSettings: SDKNetworkSettings {
        return bridgeClient.getNetworkSettings()
    }

    /// Current mock endpoints from macOS app (via socket)
    public var mockEndpoints: [SDKMockEndpoint] {
        return bridgeClient.getMockEndpoints()
    }

    /// Find matching mock endpoint for a request
    public func findMockEndpoint(for url: URL, method: String) -> SDKMockEndpoint? {
        return bridgeClient.findMockEndpoint(for: url, method: method)
    }

    /// Path to the UserDefaults command file
    /// SimKit app writes commands to this file to change UserDefaults values
    public var userDefaultsCommandFilePath: String {
        return userDefaultsMonitor.commandFilePath
    }

    /// Send network request log to macOS app
    internal func logNetworkRequest(_ request: NetworkRequest) {
        bridgeClient.sendNetworkLog(request)
    }
}
