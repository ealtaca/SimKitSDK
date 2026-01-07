//
//  SimBridgeClient.swift
//  SimKit
//
//  WebSocket client for bidirectional communication with macOS SimKit app
//  Handles:
//  - Receiving mock endpoints and network settings from macOS
//  - Sending network request logs to macOS
//  - Maintaining persistent connection with automatic reconnect
//

import Foundation

/// WebSocket client for communication with macOS SimKit app
class SimBridgeClient: NSObject {

    static let shared = SimBridgeClient()

    /// WebSocket server URL - iOS Simulator connects to macOS host
    /// Note: In iOS Simulator, localhost/127.0.0.1 correctly routes to macOS host
    private let serverURL = URL(string: "ws://127.0.0.1:47263")!

    /// Bundle ID of the iOS app
    private let bundleID: String

    /// SDK version
    private let sdkVersion = "1.0.6"

    /// WebSocket task
    private var webSocket: URLSessionWebSocketTask?

    /// URL session for WebSocket
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Connection state
    private(set) var isConnected = false

    /// Queue for operations
    private let queue = DispatchQueue(label: "com.simkit.bridge", qos: .userInteractive)

    /// Current mock endpoints received from macOS
    private var mockEndpoints: [SDKMockEndpoint] = []
    private let mockEndpointsLock = NSLock()

    /// Current network settings received from macOS
    private var networkSettings: SDKNetworkSettings = .default
    private let settingsLock = NSLock()

    /// Callbacks for configuration updates
    var onMockEndpointsUpdated: (([SDKMockEndpoint]) -> Void)?
    var onNetworkSettingsUpdated: ((SDKNetworkSettings) -> Void)?

    /// Reconnect timer
    private var reconnectWorkItem: DispatchWorkItem?
    private let reconnectInterval: TimeInterval = 1.0  // Reduced from 2.0 for faster reconnect

    /// Maximum reconnect attempts before giving up temporarily
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 30  // Try for ~30 seconds then slow down

    private override init() {
        bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        super.init()
        print("[SimKit] SimBridgeClient initialized for \(bundleID)")
        appendLog("[SimKit] SimBridgeClient initialized for \(bundleID)")
    }

    /// Append log to file for debugging
    private func appendLog(_ message: String) {
        print(message)
        let logFile = "/tmp/simkit_client_debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let fileHandle = FileHandle(forWritingAtPath: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logFile))
            }
        }
    }

    // MARK: - Connection Management

    /// Start the client and connect to macOS server
    func start() {
        queue.async { [weak self] in
            self?.connect()
        }
    }

    /// Stop the client
    func stop() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        disconnect()
    }

    /// Whether a connection attempt is in progress
    private var isConnecting = false

    /// Connect to the macOS server via WebSocket
    private func connect() {
        guard !isConnected else {
            appendLog("[SimKit] Already connected, skipping connect()")
            return
        }

        guard !isConnecting else {
            appendLog("[SimKit] Connection already in progress, skipping")
            return
        }

        isConnecting = true

        // Only log first few connection attempts to avoid spam
        if reconnectAttempts < 3 {
            appendLog("[SimKit] 🔌 Connecting to WebSocket server at \(serverURL)... (attempt \(reconnectAttempts + 1))")
        }

        // Properly close any existing WebSocket connection
        if let existingSocket = webSocket {
            appendLog("[SimKit] 🔧 Closing existing WebSocket before creating new one")
            existingSocket.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
        }

        // Create new WebSocket task
        appendLog("[SimKit] 🔧 Creating new WebSocket task")
        let task = urlSession.webSocketTask(with: serverURL)
        webSocket = task

        // Resume the task to start connection
        appendLog("[SimKit] 🔧 Calling task.resume() to initiate WebSocket handshake")
        task.resume()
        appendLog("[SimKit] 🔧 task.resume() called, waiting for didOpenWithProtocol callback")

        // Set connection timeout - if not connected within 5 seconds, retry
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            if self.isConnecting && !self.isConnected {
                // Only log first few timeouts
                if self.reconnectAttempts < 3 {
                    print("[SimKit] ⏰ Connection timeout after 5s, didOpenWithProtocol was never called")
                }
                self.isConnecting = false

                // Properly close timed-out WebSocket
                if let socket = self.webSocket {
                    socket.cancel(with: .normalClosure, reason: nil)
                    self.webSocket = nil
                }

                self.scheduleReconnect()
            }
        }

        // Start receiving messages (will wait for connection)
        receiveMessage()
    }

    /// Disconnect from server
    private func disconnect() {
        guard isConnected else { return }

        isConnected = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        print("[SimKit] 📴 Disconnected from macOS server")
    }

    /// Schedule reconnection attempt with exponential backoff
    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()

        reconnectAttempts += 1

        // Calculate delay with exponential backoff
        let delay: TimeInterval
        if reconnectAttempts <= maxReconnectAttempts {
            delay = reconnectInterval  // Fast reconnect (1 second)
        } else {
            // Slow down after many attempts (5 seconds)
            delay = 5.0
        }

        // Only log first few reconnect attempts and then every 10th
        if reconnectAttempts <= 3 || reconnectAttempts % 10 == 0 {
            print("[SimKit] 🔄 Reconnect attempt \(reconnectAttempts) scheduled in \(delay)s...")
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnectWorkItem = workItem

        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Sending Messages

    /// Send handshake to server
    private func sendHandshake() {
        // Get simulator UDID from environment variable (set by iOS Simulator)
        let simulatorUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        let payload = HandshakePayload(bundleID: bundleID, sdkVersion: sdkVersion, simulatorUDID: simulatorUDID)
        let message = ClientMessage.handshake(payload)
        sendMessage(message)
    }

    /// Send network request log to server
    func sendNetworkLog(_ request: NetworkRequest) {
        let payload = NetworkLogPayload(bundleID: bundleID, request: request)
        let message = ClientMessage.networkLog(payload)
        sendMessage(message)
    }

    /// Send clear requests command
    func sendClearRequests() {
        let payload = ClearPayload(bundleID: bundleID)
        let message = ClientMessage.clearRequests(payload)
        sendMessage(message)
    }

    /// Send heartbeat
    private func sendHeartbeat() {
        let message = ClientMessage.heartbeat
        sendMessage(message)
    }

    /// Send message to server
    private func sendMessage(_ message: ClientMessage) {
        queue.async { [weak self] in
            guard let self = self, self.isConnected else { return }

            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(message)

                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    self.webSocket?.send(.string(jsonString)) { error in
                        if let error = error {
                            print("[SimKit] Failed to send message: \(error)")
                        }
                    }
                }
            } catch {
                print("[SimKit] Failed to encode message: \(error)")
            }
        }
    }

    // MARK: - Receiving Messages

    /// Receive message from WebSocket
    private func receiveMessage() {
        guard let webSocket = webSocket else {
            print("[SimKit] ⚠️ WebSocket is nil, cannot receive")
            return
        }

        webSocket.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                // If we received a message, connection is definitely open
                if !self.isConnected {
                    print("[SimKit] 🔌 WebSocket connection confirmed via message receipt")
                    self.isConnected = true
                    self.isConnecting = false
                    self.sendHandshake()
                }

                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.handleReceivedData(data)
                    }
                case .data(let data):
                    self.handleReceivedData(data)
                @unknown default:
                    break
                }

                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                print("[SimKit] WebSocket receive error: \(error)")
                self.handleDisconnect()
            }
        }
    }

    /// Handle received data
    private func handleReceivedData(_ data: Data) {
        let decoder = JSONDecoder()

        guard let message = try? decoder.decode(ServerMessage.self, from: data) else {
            print("[SimKit] Failed to decode server message")
            if let str = String(data: data, encoding: .utf8) {
                print("[SimKit] Raw: \(str.prefix(200))")
            }
            return
        }

        switch message {
        case .config(let payload):
            handleConfigUpdate(payload)
        }
    }

    /// Handle configuration update from macOS
    private func handleConfigUpdate(_ config: ConfigPayload) {
        print("[SimKit] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[SimKit] 📥 CONFIG RECEIVED FROM MACOS")
        print("[SimKit] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Update mock endpoints
        mockEndpointsLock.lock()
        mockEndpoints = config.mockEndpoints.map { bridged in
            SDKMockEndpoint(
                id: bridged.id,
                name: bridged.name,
                enabled: bridged.enabled,
                urlPattern: bridged.urlPattern,
                method: bridged.method,
                matchType: bridged.matchType,
                statusCode: bridged.statusCode,
                headers: bridged.headers,
                responseBody: bridged.responseBody,
                delayMs: bridged.delayMs
            )
        }
        let endpoints = mockEndpoints
        mockEndpointsLock.unlock()

        // Update network settings
        settingsLock.lock()
        let oldSettings = networkSettings
        networkSettings = SDKNetworkSettings(
            enabled: config.networkSettings.enabled,
            profile: config.networkSettings.profile,
            latencyMs: config.networkSettings.latencyMs,
            packetLossPercent: config.networkSettings.packetLossPercent,
            downloadKBps: config.networkSettings.downloadKBps,
            uploadKBps: config.networkSettings.uploadKBps
        )
        let settings = networkSettings
        settingsLock.unlock()

        // Log network settings details
        print("[SimKit] 🌐 NETWORK SETTINGS:")
        print("[SimKit]    Enabled: \(settings.enabled)")
        print("[SimKit]    Profile: \(settings.profile)")
        print("[SimKit]    Latency: \(settings.latencyMs)ms")
        print("[SimKit]    Packet Loss: \(settings.packetLossPercent)%")
        print("[SimKit]    Download: \(settings.downloadKBps) KBps")
        print("[SimKit]    Upload: \(settings.uploadKBps) KBps")
        if settings.isOffline {
            print("[SimKit]    ⚠️ OFFLINE MODE ACTIVE")
        }

        // Log if settings changed
        if oldSettings.profile != settings.profile || oldSettings.enabled != settings.enabled {
            print("[SimKit] 🔄 Settings changed: \(oldSettings.profile) → \(settings.profile)")
        }

        // Log mock endpoints
        print("[SimKit] 🎭 MOCK ENDPOINTS: \(endpoints.count) total")
        for (index, mock) in endpoints.prefix(5).enumerated() {
            let status = mock.enabled ? "✅" : "❌"
            print("[SimKit]    \(index + 1). \(status) [\(mock.method)] \(mock.name) → \(mock.urlPattern)")
        }
        if endpoints.count > 5 {
            print("[SimKit]    ... and \(endpoints.count - 5) more")
        }

        print("[SimKit] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        // Notify listeners on main thread
        DispatchQueue.main.async { [weak self] in
            self?.onMockEndpointsUpdated?(endpoints)
            self?.onNetworkSettingsUpdated?(settings)
        }
    }

    /// Handle disconnect
    private func handleDisconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Skip if already handling disconnect
            guard self.isConnected || self.isConnecting else {
                return  // Silently skip duplicate disconnect
            }

            self.isConnected = false
            self.isConnecting = false

            // Properly close WebSocket with normal closure code
            if let socket = self.webSocket {
                socket.cancel(with: .normalClosure, reason: nil)
                self.webSocket = nil
            }

            // Only log first disconnect
            if self.reconnectAttempts == 0 {
                print("[SimKit] 📴 Disconnected from SimKit app, will retry in background")
            }
            self.scheduleReconnect()
        }
    }

    // MARK: - Public API

    /// Get current mock endpoints
    func getMockEndpoints() -> [SDKMockEndpoint] {
        mockEndpointsLock.lock()
        defer { mockEndpointsLock.unlock() }
        return mockEndpoints
    }

    /// Get current network settings
    func getNetworkSettings() -> SDKNetworkSettings {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return networkSettings
    }

    /// Find matching mock endpoint for a request
    func findMockEndpoint(for url: URL, method: String) -> SDKMockEndpoint? {
        mockEndpointsLock.lock()
        defer { mockEndpointsLock.unlock() }

        for endpoint in mockEndpoints where endpoint.enabled {
            if endpoint.matches(url: url, method: method) {
                return endpoint
            }
        }
        return nil
    }
}

// MARK: - URLSessionWebSocketDelegate

extension SimBridgeClient: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        appendLog("[SimKit] ✅ WebSocket didOpenWithProtocol called! Protocol: \(`protocol` ?? "none")")

        queue.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = true
            self.isConnecting = false
            self.reconnectAttempts = 0  // Reset on successful connection
            self.appendLog("[SimKit] 📤 Sending handshake...")
            self.sendHandshake()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        appendLog("[SimKit] 📴 WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonStr)")
        handleDisconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // Only log errors on first few attempts
            if reconnectAttempts < 3 {
                appendLog("[SimKit] ⚠️ Connection error: \(error.localizedDescription)")
            }
            handleDisconnect()
        }
    }
}

// MARK: - Protocol Messages (must match macOS server)

/// Messages sent from iOS SDK (client) to macOS (server)
private enum ClientMessage: Codable {
    case handshake(HandshakePayload)
    case networkLog(NetworkLogPayload)
    case clearRequests(ClearPayload)
    case heartbeat

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case handshake
        case networkLog
        case clearRequests
        case heartbeat
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .handshake(let payload):
            try container.encode(MessageType.handshake, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .networkLog(let payload):
            try container.encode(MessageType.networkLog, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .clearRequests(let payload):
            try container.encode(MessageType.clearRequests, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .heartbeat:
            try container.encode(MessageType.heartbeat, forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .handshake:
            let payload = try container.decode(HandshakePayload.self, forKey: .payload)
            self = .handshake(payload)
        case .networkLog:
            let payload = try container.decode(NetworkLogPayload.self, forKey: .payload)
            self = .networkLog(payload)
        case .clearRequests:
            let payload = try container.decode(ClearPayload.self, forKey: .payload)
            self = .clearRequests(payload)
        case .heartbeat:
            self = .heartbeat
        }
    }
}

/// Messages sent from macOS (server) to iOS SDK (client)
private enum ServerMessage: Codable {
    case config(ConfigPayload)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case config
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .config:
            let payload = try container.decode(ConfigPayload.self, forKey: .payload)
            self = .config(payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .config(let payload):
            try container.encode(MessageType.config, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - Payload Models

private struct HandshakePayload: Codable {
    let bundleID: String
    let sdkVersion: String
    let simulatorUDID: String?  // Simulator UDID for per-simulator request tracking
}

private struct ConfigPayload: Codable {
    let mockEndpoints: [BridgedMockEndpoint]
    let networkSettings: BridgedNetworkSettings
}

private struct NetworkLogPayload: Codable {
    let bundleID: String
    let request: NetworkRequest
}

private struct ClearPayload: Codable {
    let bundleID: String
}

private struct BridgedMockEndpoint: Codable {
    let id: UUID
    var name: String
    var enabled: Bool
    var urlPattern: String
    var method: String
    var matchType: String
    var statusCode: Int
    var headers: [String: String]
    var responseBody: String
    var delayMs: Int
}

private struct BridgedNetworkSettings: Codable {
    var enabled: Bool
    var profile: String
    var latencyMs: Int
    var packetLossPercent: Int
    var downloadKBps: Int
    var uploadKBps: Int
}

// MARK: - SDK Data Models

/// Mock endpoint received from macOS
public struct SDKMockEndpoint {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var urlPattern: String
    public var method: String
    public var matchType: String
    public var statusCode: Int
    public var headers: [String: String]
    public var responseBody: String
    public var delayMs: Int

    /// Check if this mock matches the given request
    public func matches(url: URL, method: String) -> Bool {
        guard enabled else { return false }
        guard self.method.uppercased() == method.uppercased() else { return false }

        let urlString = url.absoluteString

        switch matchType {
        case "Exact":
            return urlString == urlPattern
        case "Contains":
            return urlString.contains(urlPattern)
        case "Starts With":
            return urlString.hasPrefix(urlPattern)
        case "Ends With":
            return urlString.hasSuffix(urlPattern)
        case "Regex":
            guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return false }
            let range = NSRange(urlString.startIndex..., in: urlString)
            return regex.firstMatch(in: urlString, range: range) != nil
        default:
            return false
        }
    }
}

/// Network settings received from macOS
public struct SDKNetworkSettings {
    public var enabled: Bool
    public var profile: String
    public var latencyMs: Int
    public var packetLossPercent: Int
    public var downloadKBps: Int
    public var uploadKBps: Int

    public var isOffline: Bool {
        return enabled && profile == "Offline"
    }

    public static let `default` = SDKNetworkSettings(
        enabled: false,
        profile: "WiFi",
        latencyMs: 0,
        packetLossPercent: 0,
        downloadKBps: 10000,
        uploadKBps: 5000
    )
}
