import Foundation
import AppKit
@preconcurrency import Carbon.HIToolbox
import MaccarKit

private let kMaccarHotKeySignature: OSType = 0x4D434152 // "MCAR"
private let kMaccarReconnectHotKeyID: UInt32 = 1

@MainActor
public final class HotKeyManager {
    public static let shared = HotKeyManager()

    public static let primaryShortcutLabel = "⌃⌥⌘R"
    public static let fallbackShortcutLabel = "⌃⌥⇧⌘R"

    public enum RegistrationState: Equatable, Sendable {
        case disabled
        case registered(shortcutLabel: String)
        case conflict(shortcutLabel: String)
    }

    public private(set) var state: RegistrationState = .disabled

    public var currentShortcutLabel: String {
        switch state {
        case .registered(let shortcutLabel):
            return shortcutLabel
        case .disabled, .conflict:
            return Self.primaryShortcutLabel
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (@MainActor () -> Void)?

    private init() {}

    public func register(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
        unregisterCurrentHotKey()

        guard installEventHandlerIfNeeded() else {
            state = .conflict(shortcutLabel: Self.primaryShortcutLabel)
            MaccarLogger.shared.error("HotKey", "Failed to install Carbon event handler for global shortcut.")
            return
        }

        let primaryModifiers = UInt32(controlKey | optionKey | cmdKey)
        let primaryStatus = registerCarbonHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: primaryModifiers)
        if primaryStatus == noErr {
            state = .registered(shortcutLabel: Self.primaryShortcutLabel)
            MaccarLogger.shared.info("HotKey", "Registered global shortcut \(Self.primaryShortcutLabel) for Reconnect.")
            return
        }

        if primaryStatus == OSStatus(eventHotKeyExistsErr) {
            registerFallbackHotKey()
            return
        }

        state = .conflict(shortcutLabel: Self.primaryShortcutLabel)
        MaccarLogger.shared.warning(
            "HotKey",
            "Global shortcut \(Self.primaryShortcutLabel) could not be registered (OSStatus: \(primaryStatus))."
        )
    }

    private func registerFallbackHotKey() {
        MaccarLogger.shared.warning(
            "HotKey",
            "Primary global shortcut \(Self.primaryShortcutLabel) is already claimed by another app; trying \(Self.fallbackShortcutLabel)."
        )
        let fallbackModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let fallbackStatus = registerCarbonHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: fallbackModifiers)
        if fallbackStatus == noErr {
            state = .registered(shortcutLabel: Self.fallbackShortcutLabel)
            MaccarLogger.shared.info("HotKey", "Registered fallback global shortcut \(Self.fallbackShortcutLabel) for Reconnect.")
            return
        }

        state = .conflict(shortcutLabel: Self.primaryShortcutLabel)
        MaccarLogger.shared.warning(
            "HotKey",
            "Global shortcut registration conflicted for both \(Self.primaryShortcutLabel) and \(Self.fallbackShortcutLabel) (OSStatus: \(fallbackStatus))."
        )
    }

    public func unregister() {
        unregisterCurrentHotKey()
        state = .disabled
        MaccarLogger.shared.info("HotKey", "Unregistered global shortcut.")
    }

    public func syncWithSettings(onTrigger: (@MainActor () -> Void)? = nil) {
        if let onTrigger {
            self.onTrigger = onTrigger
        }

        guard MaccarSettings.shared.globalShortcutEnabled else {
            unregister()
            return
        }

        let handler = self.onTrigger ?? {}
        register(onTrigger: handler)
    }

    fileprivate func handleTriggered() {
        MaccarLogger.shared.info("HotKey", "Global shortcut \(currentShortcutLabel) triggered Reconnect.")
        onTrigger?()
    }

    private func unregisterCurrentHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil {
            return true
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            maccarHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &handlerRef
        )

        guard status == noErr, let handlerRef else {
            return false
        }

        eventHandlerRef = handlerRef
        return true
    }

    private func registerCarbonHotKey(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        let hotKeyID = EventHotKeyID(
            signature: kMaccarHotKeySignature,
            id: kMaccarReconnectHotKeyID
        )
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )

        if status == noErr, let newRef {
            hotKeyRef = newRef
        }
        return status
    }
}

private func maccarHotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    _ = nextHandler
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr,
          hotKeyID.signature == kMaccarHotKeySignature,
          hotKeyID.id == kMaccarReconnectHotKeyID
    else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        manager.handleTriggered()
    }
    return noErr
}
