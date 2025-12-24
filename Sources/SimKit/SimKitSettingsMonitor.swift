//
//  SimKitSettingsMonitor.swift
//  SimKit
//
//  Monitors settings file written by SimKit app and updates network configuration
//

import Foundation

/// Monitors settings file for changes from SimKit app
class SimKitSettingsMonitor {

    private(set) var currentSettings = NetworkSettings.default
    private var fileMonitor: DispatchSourceFileSystemObject?
    private let settingsFileURL: URL

    init() {
        // Settings file location in app's documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        settingsFileURL = documentsPath.appendingPathComponent("simbooster_settings.json")

        // Create default settings file if it doesn't exist
        if !FileManager.default.fileExists(atPath: settingsFileURL.path) {
            writeDefaultSettings()
        }

        // Load initial settings
        loadSettings()
    }

    /// Start monitoring settings file for changes
    func startMonitoring() {
        // Create file descriptor for monitoring
        let fileDescriptor = open(settingsFileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[SimKit] ⚠️ Could not open settings file for monitoring")
            return
        }

        // Create dispatch source to monitor file changes
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .background)
        )

        source.setEventHandler { [weak self] in
            self?.loadSettings()
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileMonitor = source

        print("[SimKit] 👀 Monitoring settings file at: \(settingsFileURL.path)")
    }

    /// Stop monitoring settings file
    func stopMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
        print("[SimKit] ⏹️ Stopped monitoring settings file")
    }

    /// Load settings from file
    private func loadSettings() {
        do {
            let data = try Data(contentsOf: settingsFileURL)
            let decoder = JSONDecoder()
            currentSettings = try decoder.decode(NetworkSettings.self, from: data)

            let statusEmoji = currentSettings.enabled ? "🟢" : "⚪️"
            print("[SimKit] \(statusEmoji) Settings updated: \(currentSettings.profile.rawValue), Latency: \(currentSettings.latencyMs)ms")
        } catch {
            print("[SimKit] ⚠️ Failed to load settings: \(error)")
            // Keep using current settings
        }
    }

    /// Write default settings to file
    private func writeDefaultSettings() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(NetworkSettings.default)
            try data.write(to: settingsFileURL, options: .atomic)
            print("[SimKit] 📝 Created default settings file")
        } catch {
            print("[SimKit] ❌ Failed to create default settings: \(error)")
        }
    }
}
