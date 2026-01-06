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

- iOS 13.0+
- macOS 10.15+
- Swift 5.9+

## Configuration

### Info.plist Setup

Add the following to your iOS app's Info.plist to allow local networking:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

## Troubleshooting

### Connection Error: -1005 (Network connection lost)

If you see `URLError code: -1005` in logs:

1. **Ensure SimKit macOS app is running**
   ```bash
   lsof -i :47263
   ```
   You should see SimKit listening on port 47263.

2. **Check that both apps are on the same Mac**
   - SDK uses `127.0.0.1` (localhost)
   - iOS Simulator and SimKit macOS app must be on the same computer

3. **Verify Info.plist has ATS exceptions**
   - Add both `NSAllowsLocalNetworking` and `NSAllowsArbitraryLoads`

4. **Check macOS Firewall settings**
   - System Settings → Network → Firewall
   - Allow incoming connections for SimKit app

5. **Only works in iOS Simulator**
   - SDK does not work on physical devices
   - Localhost routing only works in Simulator

## License

MIT License
