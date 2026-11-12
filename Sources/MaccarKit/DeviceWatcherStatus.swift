import Foundation
import CoreGraphics

public enum DeviceWatcherStatus: Equatable, Sendable {
    case stopped
    case waitingForDevice(targetName: String?)
    case autoRetryPaused(targetName: String)
    case disconnectedManually(targetName: String)
    case connecting(targetName: String)
    case connected(deviceName: String, displayID: CGDirectDisplayID?, mirrored: Bool)
    case error(message: String)

    public var displayText: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .waitingForDevice(let target):
            if let t = target, !t.isEmpty {
                return "Waiting for '\(t)' on USB..."
            }
            return "No iPad registered (Click to register)"
        case .autoRetryPaused(let target):
            return "Auto-retry paused ('\(target)' unreachable — plug in USB or click Reconnect)"
        case .disconnectedManually(let target):
            return "Disconnected ('\(target)' paused — click Reconnect)"
        case .connecting(let target):
            return "Connecting to '\(target)'..."
        case .connected(let name, _, let mirrored):
            let mirrorNote = mirrored ? " (Mirrored)" : " (Mirror pending — click Reconnect to retry)"
            return "Connected: \(name)\(mirrorNote)"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
}
