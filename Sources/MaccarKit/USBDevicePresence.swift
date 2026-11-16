import Foundation
import IOKit
import IOKit.usb

/// The live answer to "is an iPad plugged in right now?".
///
/// Uses `IOServiceGetMatchingServices` with the same unfiltered dictionary the attach monitor
/// now uses. A broad `IOUSBHostDevice` query is deliberate: adding an `"idVendor"` property
/// filter matches zero services on macOS 14/15 (proven in `USBDeviceAttachMonitorTests`), and
/// the subsequent `isIPadUSBService` check is cheap enough to run per tick.
///
/// This is read on the watcher's serial work queue, never on the main thread.
public struct SystemUSBDevicePresence: USBDevicePresenceChecking {
    public init() {}

    public func isIPadAttached() -> Bool {
        guard let matching = USBDeviceAttachMonitor.matchingDictionary() else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            // Fail closed: reporting "absent" suppresses a connect. Reporting "present" on an
            // IOKit failure would issue connects for a device we cannot see, which is the bug
            // this gate exists to prevent.
            return false
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if USBDeviceAttachMonitor.isIPadService(service) { return true }
        }
        return false
    }
}
