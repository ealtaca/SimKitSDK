//
//  UserDefaultsMonitor.swift
//  SimKit
//
//  Monitors for UserDefaults change commands from SimKit app
//  Enables real-time UserDefaults editing without app restart
//

import Foundation

/// Monitors for UserDefaults change commands from SimKit app
/// This enables real-time editing of UserDefaults values
public class UserDefaultsMonitor {

    public static let shared = UserDefaultsMonitor()

    private var fileMonitor: DispatchSourceFileSystemObject?
    private let commandFileURL: URL
    private var lastProcessedCommand: String = ""

    /// Notification posted when a UserDefault value is changed by SimKit
    public static let valueChangedNotification = Notification.Name("SimKitUserDefaultValueChanged")

    private init() {
        // Command file location in app's documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        commandFileURL = documentsPath.appendingPathComponent("simbooster_userdefaults_command.json")
    }

    /// Start monitoring for UserDefaults commands
    func startMonitoring() {
        // Create command file if it doesn't exist
        if !FileManager.default.fileExists(atPath: commandFileURL.path) {
            createEmptyCommandFile()
        }

        // Create file descriptor for monitoring
        let fileDescriptor = open(commandFileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[SimKit] UserDefaults: Could not open command file for monitoring")
            return
        }

        // Create dispatch source to monitor file changes
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.global(qos: .userInitiated)
        )

        source.setEventHandler { [weak self] in
            self?.processCommand()
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileMonitor = source

        print("[SimKit] UserDefaults: Monitoring command file at: \(commandFileURL.path)")
    }

    /// Stop monitoring for UserDefaults commands
    func stopMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
        print("[SimKit] UserDefaults: Stopped monitoring")
    }

    /// Process a UserDefaults command from the file
    private func processCommand() {
        do {
            let data = try Data(contentsOf: commandFileURL)

            // Check if this is a new command (not already processed)
            let commandString = String(data: data, encoding: .utf8) ?? ""
            guard commandString != lastProcessedCommand && !commandString.isEmpty else {
                return
            }
            lastProcessedCommand = commandString

            // Parse the command
            guard let command = try? JSONDecoder().decode(UserDefaultsCommand.self, from: data) else {
                print("[SimKit] UserDefaults: Invalid command format")
                return
            }

            // Execute the command
            executeCommand(command)

        } catch {
            // File might be in the process of being written, ignore
        }
    }

    /// Execute a UserDefaults command
    private func executeCommand(_ command: UserDefaultsCommand) {
        let defaults: UserDefaults

        if let suiteName = command.suite, !suiteName.isEmpty {
            defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults.standard
        } else {
            defaults = UserDefaults.standard
        }

        switch command.action {
        case "set":
            setValue(command.value, forKey: command.key, type: command.type, in: defaults)
            print("[SimKit] UserDefaults: Set '\(command.key)' = '\(command.value ?? "nil")' (\(command.type ?? "auto"))")

        case "delete":
            defaults.removeObject(forKey: command.key)
            print("[SimKit] UserDefaults: Deleted '\(command.key)'")

        case "sync":
            // Force synchronize to ensure values are written
            defaults.synchronize()
            print("[SimKit] UserDefaults: Synchronized")

        default:
            print("[SimKit] UserDefaults: Unknown action: \(command.action)")
        }

        // Post notification so the app can react to the change
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.valueChangedNotification,
                object: nil,
                userInfo: [
                    "key": command.key,
                    "action": command.action,
                    "suite": command.suite ?? ""
                ]
            )
        }
    }

    /// Set a value with proper type conversion
    private func setValue(_ value: Any?, forKey key: String, type: String?, in defaults: UserDefaults) {
        guard let value = value else {
            defaults.removeObject(forKey: key)
            return
        }

        switch type?.lowercased() {
        case "bool", "boolean":
            if let boolValue = value as? Bool {
                defaults.set(boolValue, forKey: key)
            } else if let stringValue = value as? String {
                let isTrue = stringValue.lowercased() == "true" || stringValue == "1" || stringValue.lowercased() == "yes"
                defaults.set(isTrue, forKey: key)
            } else if let intValue = value as? Int {
                defaults.set(intValue != 0, forKey: key)
            }

        case "int", "integer":
            if let intValue = value as? Int {
                defaults.set(intValue, forKey: key)
            } else if let stringValue = value as? String, let intValue = Int(stringValue) {
                defaults.set(intValue, forKey: key)
            }

        case "float", "double", "number":
            if let doubleValue = value as? Double {
                defaults.set(doubleValue, forKey: key)
            } else if let stringValue = value as? String, let doubleValue = Double(stringValue) {
                defaults.set(doubleValue, forKey: key)
            }

        case "string":
            if let stringValue = value as? String {
                defaults.set(stringValue, forKey: key)
            } else {
                defaults.set("\(value)", forKey: key)
            }

        case "date":
            if let dateValue = value as? Date {
                defaults.set(dateValue, forKey: key)
            } else if let stringValue = value as? String {
                // Try to parse ISO8601 date
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: stringValue) {
                    defaults.set(date, forKey: key)
                }
            }

        default:
            // Auto-detect type
            if let boolValue = value as? Bool {
                defaults.set(boolValue, forKey: key)
            } else if let intValue = value as? Int {
                defaults.set(intValue, forKey: key)
            } else if let doubleValue = value as? Double {
                defaults.set(doubleValue, forKey: key)
            } else if let stringValue = value as? String {
                defaults.set(stringValue, forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }

        // Force sync to persist immediately
        defaults.synchronize()
    }

    /// Create an empty command file
    private func createEmptyCommandFile() {
        let emptyCommand = """
        {"action": "sync", "key": "", "timestamp": 0}
        """
        try? emptyCommand.write(to: commandFileURL, atomically: true, encoding: .utf8)
    }

    /// Get the command file path (for SimKit app to write to)
    public var commandFilePath: String {
        return commandFileURL.path
    }
}

// MARK: - Command Structure

/// Structure representing a UserDefaults command from SimKit
struct UserDefaultsCommand: Codable {
    let action: String      // "set", "delete", "sync"
    let key: String         // The UserDefaults key
    let value: AnyCodableValue?  // The value to set
    let type: String?       // Type hint: "bool", "int", "float", "string", "date"
    let suite: String?      // Optional suite name (nil = standard)
    let timestamp: TimeInterval  // Timestamp to detect new commands
}

/// A type-erased Codable value
struct AnyCodableValue: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encode("\(value)")
        }
    }
}

extension AnyCodableValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.value = value
    }
}

extension AnyCodableValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.value = value
    }
}

extension AnyCodableValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self.value = value
    }
}

extension AnyCodableValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self.value = value
    }
}
