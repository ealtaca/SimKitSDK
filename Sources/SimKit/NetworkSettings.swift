//
//  NetworkSettings.swift
//  SimKit
//
//  Network throttling configuration
//

import Foundation

/// Network throttling settings that can be controlled from SimKit app
public struct NetworkSettings: Codable {

    /// Whether throttling is enabled
    public var enabled: Bool

    /// Network profile preset
    public var profile: NetworkProfile

    /// Custom bandwidth limits (if profile is .custom)
    public var customBandwidth: BandwidthLimit?

    /// Latency in milliseconds
    public var latencyMs: Int

    /// Packet loss percentage (0-100)
    public var packetLossPercent: Int

    public init(
        enabled: Bool = false,
        profile: NetworkProfile = .wifi,
        customBandwidth: BandwidthLimit? = nil,
        latencyMs: Int = 0,
        packetLossPercent: Int = 0
    ) {
        self.enabled = enabled
        self.profile = profile
        self.customBandwidth = customBandwidth
        self.latencyMs = latencyMs
        self.packetLossPercent = packetLossPercent
    }

    /// Default settings (no throttling)
    public static let `default` = NetworkSettings()
}

/// Predefined network profiles
public enum NetworkProfile: String, Codable, CaseIterable {
    case wifi = "WiFi"
    case lte = "LTE"
    case fourG = "4G"
    case threeG = "3G"
    case twoG = "2G (Edge)"
    case lossy = "Lossy Network"
    case highLatency = "High Latency"
    case custom = "Custom"
    case offline = "Offline"

    /// Bandwidth limits for this profile
    public var bandwidth: BandwidthLimit {
        switch self {
        case .wifi:
            return BandwidthLimit(downloadKBps: 10_000, uploadKBps: 5_000) // 10 MB/s down, 5 MB/s up
        case .lte:
            return BandwidthLimit(downloadKBps: 6_000, uploadKBps: 3_000) // 6 MB/s down, 3 MB/s up
        case .fourG:
            return BandwidthLimit(downloadKBps: 3_000, uploadKBps: 1_500) // 3 MB/s down, 1.5 MB/s up
        case .threeG:
            return BandwidthLimit(downloadKBps: 750, uploadKBps: 250) // 750 KB/s down, 250 KB/s up
        case .twoG:
            return BandwidthLimit(downloadKBps: 30, uploadKBps: 15) // 30 KB/s down, 15 KB/s up (Edge)
        case .lossy:
            return BandwidthLimit(downloadKBps: 2_000, uploadKBps: 1_000) // 2 MB/s down, 1 MB/s up with packet loss
        case .highLatency:
            return BandwidthLimit(downloadKBps: 5_000, uploadKBps: 2_000) // 5 MB/s down, 2 MB/s up with high latency
        case .custom:
            return BandwidthLimit(downloadKBps: 1_000, uploadKBps: 500) // Default for custom
        case .offline:
            return BandwidthLimit(downloadKBps: 0, uploadKBps: 0) // No network
        }
    }

    /// Typical latency for this profile
    public var typicalLatencyMs: Int {
        switch self {
        case .wifi: return 10
        case .lte: return 50
        case .fourG: return 100
        case .threeG: return 200
        case .twoG: return 400
        case .lossy: return 150
        case .highLatency: return 800 // Satellite-like latency
        case .custom: return 0
        case .offline: return 0
        }
    }

    /// Typical packet loss percentage for this profile
    public var typicalPacketLoss: Int {
        switch self {
        case .lossy: return 10
        case .twoG: return 2
        case .highLatency: return 1
        default: return 0
        }
    }
}

/// Bandwidth limits in KB/s
public struct BandwidthLimit: Codable {
    /// Download speed in KB/s
    public var downloadKBps: Int

    /// Upload speed in KB/s
    public var uploadKBps: Int

    public init(downloadKBps: Int, uploadKBps: Int) {
        self.downloadKBps = downloadKBps
        self.uploadKBps = uploadKBps
    }
}
