//
//  SimKitURLProtocol.swift
//  SimKit
//
//  Custom URLProtocol that intercepts network requests for throttling, mocking, and logging
//  Uses socket-based communication with macOS SimKit app
//

import Foundation

/// Custom URLProtocol that intercepts all network requests
/// Applies throttling and mocking based on settings received via socket
/// Logs requests to macOS app via socket
class SimKitURLProtocol: URLProtocol {

    private static let requestHandledKey = "SimKitURLProtocolHandled"

    private var dataTask: URLSessionDataTask?
    private var receivedData = Data()
    private var response: URLResponse?
    private var startTime: Date?
    private var requestId: UUID?

    // MARK: - URLProtocol Overrides

    /// Determine if this protocol can handle the request
    override class func canInit(with request: URLRequest) -> Bool {
        // Don't handle requests we've already handled (prevent infinite loop)
        if URLProtocol.property(forKey: requestHandledKey, in: request) != nil {
            return false
        }

        // Only handle HTTP/HTTPS requests
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }

        return true
    }

    /// Return canonical version of request (just return as-is)
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    /// Start loading the request
    override func startLoading() {
        startTime = Date()
        requestId = UUID()

        // Mark this request as handled to prevent infinite loop
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.requestHandledKey, in: mutableRequest)

        // Get current settings from socket
        let settings = SimKit.shared.currentSettings

        // Log request start via socket
        logRequestStart()

        // Check for mock endpoint match first (via socket)
        if let url = request.url,
           let method = request.httpMethod {

            if let mockEndpoint = SimKit.shared.findMockEndpoint(for: url, method: method) {
                print("[SimKit] 🎭 Mock matched: \(mockEndpoint.name) for \(method) \(url.absoluteString)")

                // Handle mock response on next run loop to ensure proper callback execution
                DispatchQueue.main.async {
                    self.handleMockResponse(mockEndpoint: mockEndpoint)
                }
                return
            }
        }

        // Check if offline mode
        if settings.isOffline {
            // Simulate offline - fail immediately
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "Simulated offline mode by SimKit"]
            )
            client?.urlProtocol(self, didFailWithError: error)
            logRequestComplete(response: nil, data: nil, error: error)
            return
        }

        // Add latency if configured
        if settings.enabled && settings.latencyMs > 0 {
            let latencySeconds = Double(settings.latencyMs) / 1000.0
            Thread.sleep(forTimeInterval: latencySeconds)
        }

        // Create URLSession with our throttling configuration
        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )

        // Start the actual request
        dataTask = session.dataTask(with: mutableRequest as URLRequest)
        dataTask?.resume()
    }

    /// Stop loading the request
    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    /// Handle mock response
    private func handleMockResponse(mockEndpoint: SDKMockEndpoint) {
        // Apply delay if configured
        if mockEndpoint.delayMs > 0 {
            let delaySeconds = Double(mockEndpoint.delayMs) / 1000.0
            Thread.sleep(forTimeInterval: delaySeconds)
        }

        // Create mock response
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: mockEndpoint.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: mockEndpoint.headers
        )

        // Convert response body string to Data
        let responseData = mockEndpoint.responseBody.data(using: .utf8) ?? Data()

        // Send response to client
        if let response = response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)

        // Log the mock response via socket
        logRequestComplete(
            response: response,
            data: responseData,
            error: nil,
            isMocked: true,
            mockEndpointName: mockEndpoint.name
        )
    }

    // MARK: - Logging via Socket

    private func logRequestStart() {
        guard let id = requestId else { return }

        let networkRequest = NetworkRequest(
            id: id,
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            startTime: startTime ?? Date(),
            status: .loading
        )

        SimKit.shared.logNetworkRequest(networkRequest)
    }

    private func logRequestComplete(
        response: URLResponse?,
        data: Data?,
        error: Error?,
        isMocked: Bool = false,
        mockEndpointName: String? = nil
    ) {
        guard let id = requestId else { return }

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let httpResponse = response as? HTTPURLResponse

        var networkRequest = NetworkRequest(
            id: id,
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            startTime: startTime ?? Date(),
            status: error != nil ? .failed : .completed
        )

        networkRequest.duration = duration
        networkRequest.responseStatusCode = httpResponse?.statusCode
        networkRequest.responseHeaders = httpResponse?.allHeaderFields as? [String: String]
        networkRequest.responseSize = data?.count
        networkRequest.error = error?.localizedDescription
        networkRequest.isMocked = isMocked
        networkRequest.mockEndpointName = mockEndpointName

        // Include response body for smaller responses (up to 1MB)
        if let data = data, data.count <= 1024 * 1024 {
            networkRequest.responseBody = data
        }

        SimKit.shared.logNetworkRequest(networkRequest)
    }
}

// MARK: - URLSessionDataDelegate

extension SimKitURLProtocol: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Apply bandwidth throttling
        let settings = SimKit.shared.currentSettings
        if settings.enabled && settings.downloadKBps > 0 {
            // Throttle by delaying based on data size
            let dataSizeKB = Double(data.count) / 1024.0
            let downloadTimeSeconds = dataSizeKB / Double(settings.downloadKBps)
            Thread.sleep(forTimeInterval: downloadTimeSeconds)
        }

        receivedData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        // Log request completion via socket
        logRequestComplete(response: response, data: receivedData, error: error)
    }
}
