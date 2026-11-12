import Foundation
import IOKit
import IOKit.usb
import os

internal protocol USBAttachMonitoring: Sendable {
    func start()
    func stop()
}

internal final class USBDeviceAttachMonitor: USBAttachMonitoring, @unchecked Sendable {
    private static let appleVendorID = 0x05AC
    private static let usbProductNameProperty = "USB Product Name"
    private static let iPadProductToken = "ipad"

    private final class WeakMonitorBox: @unchecked Sendable {
        weak var monitor: USBDeviceAttachMonitor?
        init(_ monitor: USBDeviceAttachMonitor) { self.monitor = monitor }
    }

    private struct State: Sendable {
        var isStarted: Bool = false
        var iterator: io_iterator_t = 0
        var portBits: UInt = 0
        var contextBits: UInt = 0
    }

    private let queue: DispatchQueue
    private let onIPadAttached: @Sendable () -> Void
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    internal init(queue: DispatchQueue, onIPadAttached: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.onIPadAttached = onIPadAttached
    }

    deinit { stop() }

    internal func start() {
        guard stateLock.withLock({ !$0.isStarted }) else { return }

        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else {
            MaccarLogger.shared.warning("USBDeviceAttachMonitor", "Failed to create IOUSBHostDevice matching dictionary.")
            return
        }
        matching["idVendor"] = NSNumber(value: Self.appleVendorID)

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            MaccarLogger.shared.warning("USBDeviceAttachMonitor", "Failed to create IONotificationPort.")
            return
        }
        IONotificationPortSetDispatchQueue(port, queue)

        let contextPtr = Unmanaged.passRetained(WeakMonitorBox(self)).toOpaque()
        var iterator: io_iterator_t = 0
        let status = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matching, Self.matchingCallback, contextPtr, &iterator
        )
        guard status == KERN_SUCCESS else {
            Self.rollbackRegistration(contextPtr: contextPtr, iterator: iterator, port: port)
            MaccarLogger.shared.warning("USBDeviceAttachMonitor", "IOServiceAddMatchingNotification failed with status \(status).")
            return
        }

        let registeredIterator = iterator
        let portBits = UInt(bitPattern: port)
        let contextBits = UInt(bitPattern: contextPtr)
        let committed = stateLock.withLock { state -> Bool in
            guard !state.isStarted else { return false }
            state.isStarted = true
            state.iterator = registeredIterator
            state.portBits = portBits
            state.contextBits = contextBits
            return true
        }
        guard committed else {
            Self.rollbackRegistration(contextPtr: contextPtr, iterator: registeredIterator, port: port)
            return
        }

        drainIterator(registeredIterator, notifyAttach: false)
    }

    internal func stop() {
        let extracted: (iterator: io_iterator_t, portBits: UInt, contextBits: UInt)? = stateLock.withLock { state in
            guard state.isStarted else { return nil }
            let snapshot = (state.iterator, state.portBits, state.contextBits)
            state.isStarted = false
            state.iterator = 0
            state.portBits = 0
            state.contextBits = 0
            return snapshot
        }
        guard let extracted else { return }

        if extracted.iterator != 0 { IOObjectRelease(extracted.iterator) }
        if let port = OpaquePointer(bitPattern: extracted.portBits) {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
        }
        let contextBits = extracted.contextBits
        if contextBits != 0 {
            queue.async {
                if let rawCtx = UnsafeMutableRawPointer(bitPattern: contextBits) {
                    Unmanaged<WeakMonitorBox>.fromOpaque(rawCtx).release()
                }
            }
        }
    }

    private static let matchingCallback: IOServiceMatchingCallback = { refCon, iterator in
        guard let refCon else { return }
        let box = Unmanaged<WeakMonitorBox>.fromOpaque(refCon).takeUnretainedValue()
        box.monitor?.drainIterator(iterator, notifyAttach: true)
    }

    private static func rollbackRegistration(
        contextPtr: UnsafeMutableRawPointer,
        iterator: io_iterator_t,
        port: IONotificationPortRef
    ) {
        if iterator != 0 { IOObjectRelease(iterator) }
        IONotificationPortSetDispatchQueue(port, nil)
        IONotificationPortDestroy(port)
        Unmanaged<WeakMonitorBox>.fromOpaque(contextPtr).release()
    }

    private func drainIterator(_ iterator: io_iterator_t, notifyAttach: Bool) {
        guard stateLock.withLock({ $0.isStarted }) else { return }
        var sawIPad = false
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if Self.isIPadUSBService(service) { sawIPad = true }
        }
        if notifyAttach && sawIPad {
            MaccarLogger.shared.info("USBDeviceAttachMonitor", "Detected USB attachment of Apple iPad.")
            onIPadAttached()
        }
    }

    private static func isIPadUSBService(_ service: io_registry_entry_t) -> Bool {
        var nameBuffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        let rawName: String
        if let product = IORegistryEntryCreateCFProperty(
            service, usbProductNameProperty as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String {
            rawName = product
        } else if IORegistryEntryGetName(service, &nameBuffer) == KERN_SUCCESS {
            rawName = nameBuffer.withUnsafeBytes { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        } else {
            rawName = ""
        }
        return rawName.range(of: iPadProductToken, options: .caseInsensitive) != nil
    }
}
