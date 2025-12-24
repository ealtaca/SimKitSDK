//
//  NetworkLogger.swift
//  SimKit
//
//  Logs network requests for display in SimKit app
//  Uses Unix Domain Socket to communicate with macOS SimKit app
//  Not affected by Network Link Conditioner
//

import Foundation

/// Logs all network requests and sends them to SimKit macOS app via Unix Socket
class NetworkLogger {

    static let shared = NetworkLogger()

    private var requests: [NetworkRequest] = []
    private let queue = DispatchQueue(label: "com.simkit.networklogger", attributes: .concurrent)
    private let maxRequests = 500 // Keep last 500 requests
    private let maxDiskSpaceBytes: Int64 = 100 * 1024 * 1024 // 100 MB max for response bodies
    private let responseBodiesDirectory: URL

    /// Unix Domain Socket configuration
    /// Path: /tmp/simkit_network.sock
    /// This path is accessible by both the sandboxed macOS app and iOS Simulator
    private var socketPath: String {
        // /tmp is accessible by both:
        // - Sandboxed macOS apps (can write to /tmp even from sandbox)
        // - iOS Simulator (runs on macOS with access to /tmp)
        return "/tmp/simkit_network.sock"
    }
    private let socketQueue = DispatchQueue(label: "com.simkit.socket", qos: .userInteractive)
    private let bundleID: String

    private init() {
        // Get bundle ID for this app
        bundleID = Bundle.main.bundleIdentifier ?? "unknown"

        // Create directory for storing large response bodies (fallback)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        responseBodiesDirectory = documentsPath.appendingPathComponent("simbooster_responses")

        try? FileManager.default.createDirectory(at: responseBodiesDirectory, withIntermediateDirectories: true)

        // Check if requests file exists and if it's empty (clear signal from SimKit app)
        loadExistingRequests()

        // Start watching for clear signal
        startWatchingForClearSignal()

        print("[SimKit] NetworkLogger initialized with socket at \(socketPath)")
    }

    /// Load existing requests from file (if any)
    private func loadExistingRequests() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let filePath = documentsPath.appendingPathComponent("simbooster_network_requests.json")

        guard FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              !data.isEmpty else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loadedRequests = try decoder.decode([NetworkRequest].self, from: data)

            // If file contains empty array, clear our requests
            if loadedRequests.isEmpty {
                print("[SimKit] 🗑️ Clear signal detected - clearing all requests")
                self.requests = []
                // Clean up response body files
                try? FileManager.default.removeItem(at: responseBodiesDirectory)
                try? FileManager.default.createDirectory(at: responseBodiesDirectory, withIntermediateDirectories: true)
            } else {
                print("[SimKit] 📥 Loaded \(loadedRequests.count) existing requests from file")
                self.requests = loadedRequests
            }
        } catch {
            print("[SimKit] ⚠️ Failed to load existing requests: \(error)")
        }
    }

    /// Watch for clear signal (empty array in file)
    private func startWatchingForClearSignal() {
        // Check every 2 seconds if file was cleared by SimKit app
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForClearSignal()
        }
    }

    private func checkForClearSignal() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let filePath = documentsPath.appendingPathComponent("simbooster_network_requests.json")

        guard FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              !data.isEmpty else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loadedRequests = try decoder.decode([NetworkRequest].self, from: data)

            // Check current requests count with synchronized access
            let hasRequests = queue.sync { !self.requests.isEmpty }

            // If file contains empty array and we have requests, clear signal received
            if loadedRequests.isEmpty && hasRequests {
                queue.async(flags: .barrier) {
                    print("[SimKit] 🗑️ Clear signal detected - clearing all requests")
                    self.requests = []
                    // Clean up response body files
                    try? FileManager.default.removeItem(at: self.responseBodiesDirectory)
                    try? FileManager.default.createDirectory(at: self.responseBodiesDirectory, withIntermediateDirectories: true)
                }
            }
        } catch {
            // Ignore decoding errors during polling
        }
    }

    /// Log start of a network request
    func logRequestStart(request: URLRequest) {
        let networkRequest = NetworkRequest(
            id: UUID(),
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            startTime: Date(),
            status: .loading
        )

        queue.async(flags: .barrier) {
            self.requests.append(networkRequest)

            // Keep only last N requests
            if self.requests.count > self.maxRequests {
                self.requests.removeFirst(self.requests.count - self.maxRequests)
                // Clean up old response body files
                self.cleanupOldResponseBodies()
            }

            // Send to socket AND write to file (for backward compatibility)
            self.sendToSocket(networkRequest)
            self.writeRequestsToSharedFile()
        }

        print("[SimKit] 🌐 \(networkRequest.method) \(networkRequest.url)")
    }

    /// Log completion of a network request
    func logRequestComplete(
        request: URLRequest,
        response: URLResponse?,
        data: Data?,
        error: Error?,
        duration: TimeInterval,
        isMocked: Bool = false,
        mockEndpointName: String? = nil
    ) {
        queue.async(flags: .barrier) {
            // Find the request by URL and update it
            if let index = self.requests.lastIndex(where: { $0.url == request.url?.absoluteString }) {
                var updatedRequest = self.requests[index]
                updatedRequest.duration = duration
                updatedRequest.responseStatusCode = (response as? HTTPURLResponse)?.statusCode
                updatedRequest.responseHeaders = (response as? HTTPURLResponse)?.allHeaderFields as? [String: String] ?? [:]
                updatedRequest.responseSize = data?.count ?? 0
                updatedRequest.isMocked = isMocked
                updatedRequest.mockEndpointName = mockEndpointName

                // Store response body for socket (limited to 1MB)
                if let data = data, data.count <= 1024 * 1024 {
                    updatedRequest.responseBody = data
                }

                if let error = error {
                    updatedRequest.status = .failed
                    updatedRequest.error = error.localizedDescription
                } else {
                    updatedRequest.status = .completed
                }

                self.requests[index] = updatedRequest

                // Save response body to file for large responses
                if let data = data, !data.isEmpty {
                    let requestId = updatedRequest.id
                    let dataSize = data.count

                    if isMocked {
                        // For mocks, save synchronously for immediate UI update
                        let bodyFilePath = self.saveResponseBody(data, requestId: requestId)
                        if let idx = self.requests.firstIndex(where: { $0.id == requestId }) {
                            self.requests[idx].responseBodyFilePath = bodyFilePath
                        }
                        print("[SimKit] 💾 Saved mock response body (\(ByteCountFormatter.string(fromByteCount: Int64(dataSize), countStyle: .binary))) to file")
                    } else {
                        // For regular requests, save asynchronously to avoid blocking
                        DispatchQueue.global(qos: .utility).async {
                            let bodyFilePath = self.saveResponseBody(data, requestId: requestId)

                            // Update the request with file path
                            self.queue.async(flags: .barrier) {
                                if let index = self.requests.firstIndex(where: { $0.id == requestId }) {
                                    self.requests[index].responseBodyFilePath = bodyFilePath
                                    // Re-write metadata with updated file path
                                    self.writeRequestsToSharedFile()
                                }
                            }

                            print("[SimKit] 💾 Saved response body (\(ByteCountFormatter.string(fromByteCount: Int64(dataSize), countStyle: .binary))) to file")
                        }
                    }
                }

                // Send to socket AND write to file
                self.sendToSocket(updatedRequest)
                self.writeRequestsToSharedFile()

                let statusEmoji = updatedRequest.status == .completed ? "✅" : "❌"
                let statusCode = updatedRequest.responseStatusCode.map { "\($0)" } ?? "N/A"
                let sizeInfo = data.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .binary))" } ?? "0 B"
                print("[SimKit] \(statusEmoji) \(updatedRequest.method) \(updatedRequest.url) - \(statusCode) (\(String(format: "%.2f", duration))s, \(sizeInfo))")
            }
        }
    }

    // MARK: - Unix Domain Socket Communication

    /// Send a network request to the macOS socket server
    private func sendToSocket(_ request: NetworkRequest) {
        socketQueue.async { [weak self] in
            guard let self = self else { return }

            // Create socket
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sock >= 0 else {
                // Socket not available - SimKit app might not be running
                return
            }

            defer { close(sock) }

            // Connect to server
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = self.socketPath.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    pathBytes.withUnsafeBufferPointer { src in
                        memcpy(dest, src.baseAddress!, min(src.count, 104))
                    }
                }
            }

            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }

            guard connectResult == 0 else {
                // Connection failed - SimKit app might not be running
                return
            }

            // Encode payload
            let payload = NetworkLogPayload(bundleID: self.bundleID, request: request)

            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(payload)

                // Send length prefix (4 bytes, big endian)
                var length = UInt32(jsonData.count).bigEndian
                let lengthData = withUnsafeBytes(of: &length) { Data($0) }

                _ = lengthData.withUnsafeBytes { ptr in
                    send(sock, ptr.baseAddress!, 4, 0)
                }

                // Send JSON data
                _ = jsonData.withUnsafeBytes { ptr in
                    send(sock, ptr.baseAddress!, jsonData.count, 0)
                }

                // Wait for response (1 byte)
                var response: UInt8 = 0
                recv(sock, &response, 1, 0)

                if response == 1 {
                    print("[SimKit] 🔌 Sent request via socket")
                }
            } catch {
                print("[SimKit] Failed to encode socket payload: \(error)")
            }
        }
    }

    // MARK: - File Operations

    /// Save response body to file and return relative path
    private func saveResponseBody(_ data: Data, requestId: UUID) -> String {
        let fileName = "\(requestId.uuidString).dat"
        let filePath = responseBodiesDirectory.appendingPathComponent(fileName)

        do {
            // Compress if larger than 10 KB (iOS 13+, macOS 10.15+)
            let dataToWrite: Data
            let isCompressed: Bool

            if #available(iOS 13.0, macOS 10.15, *), data.count > 10 * 1024 {
                if let compressed = try? (data as NSData).compressed(using: .lzfse) as Data {
                    dataToWrite = compressed
                    isCompressed = true
                    print("[SimKit] 🗜️ Compressed response from \(data.count) to \(compressed.count) bytes (\(Int(Double(compressed.count) / Double(data.count) * 100))%)")
                } else {
                    dataToWrite = data
                    isCompressed = false
                }
            } else {
                dataToWrite = data
                isCompressed = false
            }

            try dataToWrite.write(to: filePath, options: [.atomic])

            // Save compression flag in metadata
            if isCompressed {
                return fileName + ".lzfse"
            } else {
                return fileName
            }
        } catch {
            print("[SimKit] ❌ Failed to save response body: \(error)")
            return ""
        }
    }

    /// Load response body from file
    func loadResponseBody(fileName: String) -> Data? {
        guard !fileName.isEmpty else { return nil }

        // Check if compressed - ".lzfse" is 6 characters
        let isCompressed = fileName.hasSuffix(".lzfse")
        let actualFileName = isCompressed ? String(fileName.dropLast(6)) : fileName

        let filePath = responseBodiesDirectory.appendingPathComponent(actualFileName)

        guard let data = try? Data(contentsOf: filePath) else {
            return nil
        }

        // Decompress if needed (iOS 13+, macOS 10.15+)
        if isCompressed {
            if #available(iOS 13.0, macOS 10.15, *) {
                return try? (data as NSData).decompressed(using: .lzfse) as Data
            } else {
                print("[SimKit] ⚠️ Compression not available on this OS version")
                return nil
            }
        } else {
            return data
        }
    }

    /// Clean up old response body files
    private func cleanupOldResponseBodies() {
        let currentRequestIds = Set(requests.map { $0.id.uuidString })

        do {
            let files = try FileManager.default.contentsOfDirectory(at: responseBodiesDirectory, includingPropertiesForKeys: [.fileSizeKey])

            var totalSize: Int64 = 0
            var fileSizes: [(url: URL, size: Int64)] = []

            // Calculate total size and collect file sizes
            for file in files {
                let fileName = file.deletingPathExtension().lastPathComponent

                // Remove files not in current requests
                if !currentRequestIds.contains(fileName) {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }

                // Track file sizes for disk space management
                if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let fileSize = attributes[.size] as? Int64 {
                    totalSize += fileSize
                    fileSizes.append((url: file, size: fileSize))
                }
            }

            // If total size exceeds limit, remove oldest files first
            if totalSize > maxDiskSpaceBytes {
                print("[SimKit] ⚠️ Response bodies directory exceeds \(maxDiskSpaceBytes / 1024 / 1024) MB limit (\(totalSize / 1024 / 1024) MB used)")

                // Sort by modification date (oldest first)
                let sortedFiles = fileSizes.sorted { file1, file2 in
                    let date1 = (try? FileManager.default.attributesOfItem(atPath: file1.url.path)[.modificationDate] as? Date) ?? Date.distantPast
                    let date2 = (try? FileManager.default.attributesOfItem(atPath: file2.url.path)[.modificationDate] as? Date) ?? Date.distantPast
                    return date1 < date2
                }

                // Remove oldest files until we're under the limit
                var removedSize: Int64 = 0
                for file in sortedFiles {
                    if totalSize - removedSize <= maxDiskSpaceBytes * 80 / 100 { // Keep at 80% after cleanup
                        break
                    }

                    try? FileManager.default.removeItem(at: file.url)
                    removedSize += file.size
                    print("[SimKit] 🗑️ Removed old response body: \(file.url.lastPathComponent) (\(file.size / 1024) KB)")
                }

                print("[SimKit] ✅ Cleaned up \(removedSize / 1024 / 1024) MB of response bodies")
            }
        } catch {
            print("[SimKit] ⚠️ Failed to cleanup old response bodies: \(error)")
        }
    }

    private var lastWriteTime: Date = Date.distantPast
    private let writeDebounceInterval: TimeInterval = 0.05 // Only write every 0.05s max (fast for mock responses)

    /// Write requests to shared file that SimKit can read (backward compatibility)
    private func writeRequestsToSharedFile() {
        // No debounce - write immediately for real-time updates (especially for mocks)

        // Write on background queue to avoid blocking
        DispatchQueue.global(qos: .utility).async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601

                // Create lightweight metadata (without response bodies)
                let requestMetadata = self.queue.sync { self.requests }
                let data = try encoder.encode(requestMetadata)

                // Write to app's documents directory (SimKit can read from simulator's container)
                if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let filePath = documentsPath.appendingPathComponent("simbooster_network_requests.json")
                    try data.write(to: filePath, options: .atomic)
                }
            } catch {
                print("[SimKit] ❌ Failed to write network requests: \(error)")
            }
        }
    }

    /// Get all logged requests (for internal use)
    func getAllRequests() -> [NetworkRequest] {
        return queue.sync {
            return requests
        }
    }
}

// MARK: - Socket Payload

/// Payload sent to macOS SimKit socket
private struct NetworkLogPayload: Codable {
    let bundleID: String
    let request: NetworkRequest
}

/// Represents a logged network request
struct NetworkRequest: Codable, Identifiable {
    let id: UUID
    let url: String
    let method: String
    let headers: [String: String]
    let body: Data?
    let startTime: Date

    var duration: TimeInterval?
    var responseStatusCode: Int?
    var responseHeaders: [String: String]?
    var responseSize: Int?
    var responseBody: Data?  // For socket communication (small responses only)
    var responseBodyFilePath: String? // File path for large responses
    var status: RequestStatus
    var error: String?
    var isMocked: Bool?
    var mockEndpointName: String?

    enum RequestStatus: String, Codable {
        case loading
        case completed
        case failed
    }

    // Helper to load response body on demand
    func loadResponseBody() -> Data? {
        // First check if we have it in memory
        if let body = responseBody {
            return body
        }
        // Otherwise load from file
        guard let filePath = responseBodyFilePath else { return nil }
        return NetworkLogger.shared.loadResponseBody(fileName: filePath)
    }
}
