//
//  MockEndpoint.swift
//  SimKit
//
//  Mock endpoint configuration for intercepting and returning predefined responses
//

import Foundation

/// Represents a mock endpoint configuration
public struct MockEndpoint: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var urlPattern: String // Regex pattern or exact URL
    public var method: HTTPMethod
    public var matchType: URLMatchType
    public var statusCode: Int
    public var headers: [String: String]
    public var responseBody: String
    public var responseBodyFilePath: String? // Optional file path for large responses
    public var delayMs: Int // Response delay in milliseconds

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        urlPattern: String,
        method: HTTPMethod = .get,
        matchType: URLMatchType = .exact,
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        responseBody: String = "{}",
        responseBodyFilePath: String? = nil,
        delayMs: Int = 0
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.urlPattern = urlPattern
        self.method = method
        self.matchType = matchType
        self.statusCode = statusCode
        self.headers = headers
        self.responseBody = responseBody
        self.responseBodyFilePath = responseBodyFilePath
        self.delayMs = delayMs
    }

    /// Get the actual response body (from file if path is set, otherwise use inline body)
    public func getResponseBody() -> String {
        if let filePath = responseBodyFilePath {
            // Validate file path to prevent arbitrary file access
            // Only allow reading from Documents directory
            guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                print("[SimKit] ⚠️ Failed to get documents directory")
                return responseBody
            }

            let documentsPathString = documentsPath.path
            let normalizedFilePath = (filePath as NSString).standardizingPath

            // Ensure the file path is within Documents directory
            guard normalizedFilePath.hasPrefix(documentsPathString) else {
                print("[SimKit] 🚨 Security: Attempted to read file outside Documents directory: \(filePath)")
                return responseBody
            }

            // Check if file exists and is readable
            guard FileManager.default.fileExists(atPath: normalizedFilePath),
                  FileManager.default.isReadableFile(atPath: normalizedFilePath) else {
                print("[SimKit] ⚠️ File not found or not readable: \(filePath)")
                return responseBody
            }

            // Read and return file content
            if let data = try? Data(contentsOf: URL(fileURLWithPath: normalizedFilePath)),
               let content = String(data: data, encoding: .utf8) {
                return content
            } else {
                print("[SimKit] ⚠️ Failed to read file content: \(filePath)")
            }
        }
        return responseBody
    }

    /// Check if this mock matches the given request
    public func matches(url: URL, method: String) -> Bool {
        guard enabled else { return false }
        guard self.method.rawValue.uppercased() == method.uppercased() else { return false }

        let urlString = url.absoluteString

        switch matchType {
        case .exact:
            return urlString == urlPattern
        case .contains:
            return urlString.contains(urlPattern)
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: urlPattern) else {
                return false
            }
            let range = NSRange(urlString.startIndex..., in: urlString)
            return regex.firstMatch(in: urlString, range: range) != nil
        case .prefix:
            return urlString.hasPrefix(urlPattern)
        case .suffix:
            return urlString.hasSuffix(urlPattern)
        }
    }

    public enum HTTPMethod: String, Codable, CaseIterable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
        case patch = "PATCH"
        case head = "HEAD"
        case options = "OPTIONS"
    }

    public enum URLMatchType: String, Codable, CaseIterable {
        case exact = "Exact"
        case contains = "Contains"
        case prefix = "Starts With"
        case suffix = "Ends With"
        case regex = "Regex"
    }
}

/// Manager for mock endpoints
public class MockEndpointManager {
    public static let shared = MockEndpointManager()

    private var endpoints: [MockEndpoint] = []
    private let queue = DispatchQueue(label: "com.simkit.mockendpoints", attributes: .concurrent)
    private var fileURL: URL?
    private var lastModificationDate: Date?

    private init() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[SimKit] ❌ Failed to get documents directory")
            return
        }

        fileURL = documentsPath.appendingPathComponent("simbooster_mock_endpoints.json")

        loadEndpoints()
        print("[SimKit] 🎯 MockEndpointManager initialized with \(endpoints.count) endpoints")

        // Start monitoring file for changes
        startMonitoring()
    }

    private func startMonitoring() {
        // Check for file changes every 0.5 seconds for quick response
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    private func checkForUpdates() {
        guard let fileURL = fileURL else { return }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let modificationDate = attributes[.modificationDate] as? Date {
                if lastModificationDate == nil || modificationDate > lastModificationDate! {
                    print("[SimKit] 🔄 Mock endpoints file changed, reloading...")
                    loadEndpoints()
                    lastModificationDate = modificationDate
                }
            }
        } catch {
            // File doesn't exist yet, that's ok
        }
    }

    /// Find matching mock endpoint for a request
    public func findMatch(for url: URL, method: String) -> MockEndpoint? {
        return queue.sync {
            print("[SimKit] 🔍 Checking \(endpoints.count) mock endpoints for \(method) \(url.absoluteString)")
            for endpoint in endpoints {
                print("[SimKit]   - Checking '\(endpoint.name)': enabled=\(endpoint.enabled), pattern='\(endpoint.urlPattern)', matchType=\(endpoint.matchType.rawValue)")
                if endpoint.matches(url: url, method: method) {
                    print("[SimKit]   ✅ MATCHED!")
                    return endpoint
                }
            }
            print("[SimKit]   ❌ No match found")
            return nil
        }
    }

    /// Get all endpoints
    public func getAllEndpoints() -> [MockEndpoint] {
        return queue.sync {
            return endpoints
        }
    }

    /// Add or update an endpoint
    public func saveEndpoint(_ endpoint: MockEndpoint) {
        queue.async(flags: .barrier) {
            if let index = self.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
                self.endpoints[index] = endpoint
            } else {
                self.endpoints.append(endpoint)
            }

            // Persist on main thread to avoid UserDefaults issues
            let endpointsCopy = self.endpoints
            DispatchQueue.main.async {
                self.persistEndpoints(endpointsCopy)
            }
        }
    }

    /// Remove an endpoint
    public func removeEndpoint(_ endpoint: MockEndpoint) {
        queue.async(flags: .barrier) {
            self.endpoints.removeAll { $0.id == endpoint.id }

            // Persist on main thread to avoid UserDefaults issues
            let endpointsCopy = self.endpoints
            DispatchQueue.main.async {
                self.persistEndpoints(endpointsCopy)
            }
        }
    }

    /// Load endpoints from file (shared with SimKit macOS app)
    private func loadEndpoints() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[SimKit] ❌ Failed to get documents directory for loading endpoints")
            return
        }

        let filePath = documentsPath.appendingPathComponent("simbooster_mock_endpoints.json")

        guard FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              let decoded = try? JSONDecoder().decode([MockEndpoint].self, from: data) else {
            print("[SimKit] 📋 No mock endpoints file found at: \(documentsPath.appendingPathComponent("simbooster_mock_endpoints.json").path)")
            return
        }

        // Use sync with barrier for immediate loading (critical for init and checkForUpdates)
        // This ensures endpoints are available before returning
        queue.sync(flags: .barrier) {
            self.endpoints = decoded
            print("[SimKit] 📋 Loaded \(decoded.count) mock endpoints from file")
        }
    }

    /// Save endpoints to file (must be called on main thread)
    private func persistEndpoints(_ endpoints: [MockEndpoint]) {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[SimKit] ❌ Failed to get documents directory for persisting endpoints")
            return
        }

        let filePath = documentsPath.appendingPathComponent("simbooster_mock_endpoints.json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(endpoints)
            try data.write(to: filePath, options: .atomic)
            print("[SimKit] 💾 Saved \(endpoints.count) mock endpoints to file: \(filePath.path)")
        } catch {
            print("[SimKit] ❌ Failed to save mock endpoints: \(error)")
        }
    }
}
