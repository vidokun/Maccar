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
            // Unmirrored is not "pending a retry": nothing will retry it automatically once
            // the failure budget is spent, and the state is simply wrong rather than
            // unfinished. Naming the action is more honest than promising a retry.
            let mirrorNote = mirrored ? " (Mirrored)" : " (Not mirrored — click Reconnect)"
            return "Connected: \(name)\(mirrorNote)"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
}
