# SimKit

Network throttling, mock endpoints, and UserDefaults management SDK for iOS Simulator.

## Installation

### Swift Package Manager

Add to your Package.swift:

```swift
dependencies: [
    .package(url: "https://github.com/ealtaca/SimKitSDK.git", from: "1.0.0")
]
```

Or in Xcode:
1. File > Add Package Dependencies
2. URL: `https://github.com/ealtaca/SimKitSDK.git`
3. Version: 1.0.0

## Usage

### AppDelegate Setup

```swift
import SimKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Enable SimKit
        SimKit.shared.enable()

        return true
    }
}
```

### SwiftUI App Setup

```swift
import SwiftUI
import SimKit

@main
struct MyApp: App {
    init() {
        SimKit.shared.enable()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

## Features

### Network Throttling
Control network speed in the simulator with SimKit macOS app:
- WiFi, LTE, 4G, 3G, 2G profiles
- Custom bandwidth and latency settings
- Offline mode simulation

### Mock Endpoints
Mock API responses:
- URL pattern matching (exact, contains, regex, prefix, suffix)
- HTTP method filtering
- Custom response headers and body
- Response delay simulation

### Network Logging
View all network requests in SimKit app:
- Request/Response details
- Timing information
- Mocked request indicators

### UserDefaults Monitoring
Real-time UserDefaults editing:
- Read/write values
- Type conversion (Bool, Int, Double, String, Date)
- Suite support

## Requirements

- iOS 14.0+
- macOS 12.0+
- Swift 5.9+

## License

MIT License
