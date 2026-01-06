//
//  URLSessionConfiguration+Swizzling.swift
//  SimKit
//
//  Method swizzling to automatically inject SimKitURLProtocol into all URLSessionConfiguration instances
//  This ensures all network requests are intercepted, regardless of which SDK creates the URLSession
//

import Foundation

extension URLSessionConfiguration {

    private static var isSwizzled = false

    /// Swizzle URLSessionConfiguration to automatically inject SimKitURLProtocol
    static func injectSimKitProtocol() {
        guard !isSwizzled else {
            print("[SimKit] URLSessionConfiguration already swizzled")
            return
        }

        // Swizzle protocolClasses getter for .default
        swizzleProtocolClasses(
            original: #selector(getter: URLSessionConfiguration.protocolClasses),
            swizzled: #selector(getter: URLSessionConfiguration.simkit_protocolClasses)
        )

        isSwizzled = true
        print("[SimKit] 🔄 URLSessionConfiguration swizzled - SimKitURLProtocol will be injected into all sessions")
    }

    private static func swizzleProtocolClasses(original: Selector, swizzled: Selector) {
        guard let originalMethod = class_getInstanceMethod(URLSessionConfiguration.self, original),
              let swizzledMethod = class_getInstanceMethod(URLSessionConfiguration.self, swizzled) else {
            print("[SimKit] ⚠️ Failed to swizzle URLSessionConfiguration.protocolClasses")
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    /// Swizzled protocolClasses getter that ensures SimKitURLProtocol is always first
    @objc private var simkit_protocolClasses: [AnyClass]? {
        get {
            // Call original implementation (which is now simkit_protocolClasses due to swizzling)
            var originalClasses = self.simkit_protocolClasses ?? []

            // Check if SimKitURLProtocol is already in the list
            let simkitProtocolClass: AnyClass = SimKitURLProtocol.self

            // Remove any existing SimKitURLProtocol instances (to avoid duplicates)
            originalClasses.removeAll { $0 === simkitProtocolClass }

            // Insert SimKitURLProtocol at the beginning (highest priority)
            originalClasses.insert(simkitProtocolClass, at: 0)

            return originalClasses
        }
        set {
            // Forward to original setter
            self.simkit_protocolClasses = newValue
        }
    }
}
